import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted whenever tab group membership may have changed (new tab, close,
    /// reorder). Posted from `TerminalController.relabelTabs`, which upstream
    /// already invokes on every membership change.
    static let phanttomSidebarTabsDidChange = Notification.Name("phanttomSidebarTabsDidChange")
}

/// Observes the tab group of a window and publishes tab metadata for the
/// sidebar. Event-driven: membership changes arrive via
/// `.phanttomSidebarTabsDidChange` (piggybacking on `relabelTabs`), title and
/// pwd changes via KVO on each tab window, progress reports via Combine on
/// each surface, and selection changes via key-window notifications. No
/// polling.
@MainActor
final class SidebarTabManager: ObservableObject {
    /// What is running in the tab, detected from the surface title. Drives
    /// which row style and icon the sidebar shows.
    enum TabKind: Equatable {
        case terminal
        case claude
        case codex
    }

    /// Activity state shown on the trailing edge of the tab row.
    enum TabStatus: Equatable {
        /// Nothing to report.
        case idle
        /// The tab's program reported progress (OSC 9;4) — animated sparkle.
        case working
        /// Work finished while the tab was unselected — blue square.
        case done
        /// Bell rang while the tab was unselected — yellow square.
        case attention
    }

    struct TabItem: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let customTitle: String?
        let autoTitle: String?
        let directory: String?
        let gitBranch: String?
        let kind: TabKind
        let status: TabStatus
        let isSelected: Bool
        let window: NSWindow

        /// What the sidebar shows: the user's custom name, else the
        /// prompt-derived auto name, else the surface title with leading
        /// decoration glyphs stripped (agents like Claude Code prefix their
        /// own "✳", which doubles our icon).
        var displayTitle: String {
            if let customTitle, !customTitle.isEmpty { return customTitle }
            if let autoTitle, !autoTitle.isEmpty { return autoTitle }
            guard kind != .terminal else { return title }
            var s = Substring(title)
            while let first = s.unicodeScalars.first,
                  !CharacterSet.alphanumerics.contains(first) {
                s = s.dropFirst()
            }
            let cleaned = s.trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? title : cleaned
        }

        /// The last path component of the pwd, "/name" style per the design.
        var directoryName: String? {
            directory.map { "/" + ($0 as NSString).lastPathComponent }
        }

        /// Full pwd with ~ abbreviation, for compact terminal rows.
        var abbreviatedDirectory: String? {
            directory.map { ($0 as NSString).abbreviatingWithTildeInPath }
        }

        static func == (lhs: TabItem, rhs: TabItem) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title
                && lhs.customTitle == rhs.customTitle
                && lhs.autoTitle == rhs.autoTitle
                && lhs.directory == rhs.directory
                && lhs.gitBranch == rhs.gitBranch
                && lhs.kind == rhs.kind
                && lhs.status == rhs.status
                && lhs.isSelected == rhs.isSelected
        }
    }

    @Published private(set) var tabs: [TabItem] = []

    /// The live background color of the selected tab's surface — the source
    /// of truth for the sidebar's Match Terminal mode. Unlike the app-level
    /// config getter, this tracks theme, overrides, and runtime color
    /// changes exactly as rendered.
    @Published private(set) var terminalBackground: Color?

    private weak var window: NSWindow?
    private var notificationObservers: [NSObjectProtocol] = []
    private var windowObservations: [NSKeyValueObservation] = []
    private var surfaceCancellables: [AnyCancellable] = []

    /// Windows whose bell rang while unselected — cleared on selection.
    private var attentionWindows: Set<ObjectIdentifier> = []
    /// Windows whose progress finished while unselected — cleared on selection.
    private var doneWindows: Set<ObjectIdentifier> = []
    /// Windows that were reporting progress at last refresh, so we can detect
    /// the working → finished transition.
    private var workingWindows: Set<ObjectIdentifier> = []

    init(window: NSWindow) {
        self.window = window

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .phanttomSidebarTabsDidChange,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ]
        for name in names {
            notificationObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Wait a runloop turn: tab group state (membership, selection)
                // settles after these notifications fire.
                DispatchQueue.main.async { self?.refresh() }
            })
        }

        // Bell while unselected marks attention.
        notificationObservers.append(center.addObserver(
            forName: .terminalWindowBellDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let controller = notification.object as? BaseTerminalController,
                  let bellWindow = controller.window else { return }
            let hasBell = notification.userInfo?[
                Notification.Name.terminalWindowHasBellKey] as? Bool ?? false
            Task { @MainActor in
                if hasBell, bellWindow !== self.window?.tabGroup?.selectedWindow {
                    self.attentionWindows.insert(ObjectIdentifier(bellWindow))
                }
                self.refresh()
            }
        })

        refresh()
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Actions

    func select(_ tab: TabItem) {
        tab.window.makeKeyAndOrderFront(nil)
    }

    /// Set (or clear, with nil/empty) a user-assigned tab name. Stored on the
    /// window; the change notification refreshes every sidebar in the group.
    func rename(_ tab: TabItem, to name: String?) {
        guard let window = tab.window as? TerminalWindow else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        window.phanttomCustomTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        // Clearing the name also re-arms first-prompt auto-naming.
        if window.phanttomCustomTitle == nil { window.phanttomAutoTitle = nil }
        NotificationCenter.default.post(name: .phanttomSidebarTabsDidChange, object: window)
    }

    func close(_ tab: TabItem) {
        // Route through the controller so close confirmation logic applies.
        if let controller = tab.window.windowController as? TerminalController {
            controller.closeTab(nil)
        } else {
            tab.window.performClose(nil)
        }
    }

    // MARK: - Refresh

    func refresh() {
        guard let window else { return }

        // Note: native tab bar hiding lives in TerminalWindow.sidebarActive
        // (the tab bar accessory is hidden as AppKit adds it). Never toggle
        // the tab bar from here — AppKit force-shows it for 2+ tab groups,
        // so toggling loops forever.

        let tabWindows = window.tabbedWindows ?? [window]
        let selected = window.tabGroup?.selectedWindow ?? window

        var newTabs: [TabItem] = []
        var nowWorking: Set<ObjectIdentifier> = []

        for w in tabWindows {
            let id = ObjectIdentifier(w)
            let controller = w.windowController as? BaseTerminalController
            let surface = controller?.focusedSurface
            let pwd = surface?.pwd ?? w.representedURL?.path
            let isSelected = w === selected

            let isWorking = surface?.progressReport != nil
            if isWorking { nowWorking.insert(id) }

            // Working just ended on an unselected tab → done.
            if !isWorking, workingWindows.contains(id), !isSelected {
                doneWindows.insert(id)
            }
            // Selection clears both indicators.
            if isSelected {
                doneWindows.remove(id)
                attentionWindows.remove(id)
            }

            let status: TabStatus = isWorking ? .working
                : doneWindows.contains(id) ? .done
                : attentionWindows.contains(id) ? .attention
                : .idle

            let terminalWindow = w as? TerminalWindow
            let kind = Self.processTitle(w.title, window: terminalWindow)

            newTabs.append(TabItem(
                id: id,
                title: w.title,
                customTitle: terminalWindow?.phanttomCustomTitle,
                autoTitle: terminalWindow?.phanttomAutoTitle,
                directory: pwd,
                gitBranch: pwd.flatMap { Self.gitBranch(at: $0) },
                kind: kind,
                status: status,
                isSelected: isSelected,
                window: w
            ))
        }
        workingWindows = nowWorking

        if newTabs != tabs { tabs = newTabs }

        let selectedSurface = (selected.windowController as? BaseTerminalController)?.focusedSurface
        let liveBackground = selectedSurface?.backgroundColor
        if liveBackground != terminalBackground { terminalBackground = liveBackground }

        // Re-register KVO for title/pwd changes on the current membership.
        windowObservations = tabWindows.flatMap { w in
            [
                w.observe(\.title) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.refresh() }
                },
                w.observe(\.representedURL) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.refresh() }
                },
            ]
        }

        // Re-subscribe to each surface's progress reports and background.
        surfaceCancellables = tabWindows.flatMap { w -> [AnyCancellable] in
            guard let controller = w.windowController as? BaseTerminalController,
                  let surface = controller.focusedSurface else { return [] }
            return [
                surface.$progressReport
                    .dropFirst()
                    .removeDuplicates { $0 == nil && $1 == nil }
                    .sink { [weak self] _ in
                        DispatchQueue.main.async { self?.refresh() }
                    },
                surface.$backgroundColor
                    .dropFirst()
                    .removeDuplicates()
                    .sink { [weak self] _ in
                        DispatchQueue.main.async { self?.refresh() }
                    },
            ]
        }
    }

    // MARK: - Detection helpers

    /// Interpret a title update: detect the agent kind (sticky across
    /// decorated titles), and capture "❯ "-marked titles from the Claude
    /// Code UserPromptSubmit hook as the tab's auto-name. A plain title
    /// (shell integration reclaiming it) resets both.
    private static func processTitle(_ title: String, window: TerminalWindow?) -> TabKind {
        // Our hook's marker: store the prompt-derived auto name — but only
        // the session's FIRST prompt names the tab. It re-arms when the
        // shell reclaims the title (session over) or via Reset Name.
        if title.hasPrefix("❯") {
            let auto = title.dropFirst().trimmingCharacters(in: .whitespaces)
            if !auto.isEmpty, window?.phanttomAutoTitle == nil {
                window?.phanttomAutoTitle = auto
            }
            return window?.phanttomAgentKind ?? .claude
        }

        let t = title.lowercased()
        if t.contains("claude") {
            window?.phanttomAgentKind = .claude
            return .claude
        }
        if t.contains("codex") {
            window?.phanttomAgentKind = .codex
            return .codex
        }

        // Decorated titles (leading symbol glyph, e.g. Claude Code's "✳ …")
        // keep the previous agent kind; a plain title means the shell took
        // the tab back, so the agent session and its auto-name are over.
        if let first = title.unicodeScalars.first,
           !CharacterSet.alphanumerics.contains(first),
           let sticky = window?.phanttomAgentKind {
            return sticky
        }
        window?.phanttomAgentKind = nil
        window?.phanttomAutoTitle = nil
        return .terminal
    }

    /// Read the git branch from .git/HEAD, walking up from the directory.
    private static func gitBranch(at pwd: String) -> String? {
        var dir = pwd
        while dir != "/", !dir.isEmpty {
            let headPath = (dir as NSString).appendingPathComponent(".git/HEAD")
            if let contents = try? String(contentsOfFile: headPath, encoding: .utf8) {
                let prefix = "ref: refs/heads/"
                if contents.hasPrefix(prefix) {
                    return contents.dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil // detached HEAD
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}
