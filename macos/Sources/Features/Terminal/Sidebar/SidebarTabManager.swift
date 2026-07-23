import AppKit
import Combine

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
        let directory: String?
        let gitBranch: String?
        let kind: TabKind
        let status: TabStatus
        let isSelected: Bool
        let window: NSWindow

        /// What the sidebar shows: the user's custom name if set, otherwise
        /// the surface title with leading decoration glyphs stripped (agents
        /// like Claude Code prefix their own "✳", which doubles our icon).
        var displayTitle: String {
            if let customTitle, !customTitle.isEmpty { return customTitle }
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
                && lhs.directory == rhs.directory
                && lhs.gitBranch == rhs.gitBranch
                && lhs.kind == rhs.kind
                && lhs.status == rhs.status
                && lhs.isSelected == rhs.isSelected
        }
    }

    @Published private(set) var tabs: [TabItem] = []

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

            newTabs.append(TabItem(
                id: id,
                title: w.title,
                customTitle: (w as? TerminalWindow)?.phanttomCustomTitle,
                directory: pwd,
                gitBranch: pwd.flatMap { Self.gitBranch(at: $0) },
                kind: Self.kind(forTitle: w.title),
                status: status,
                isSelected: isSelected,
                window: w
            ))
        }
        workingWindows = nowWorking

        if newTabs != tabs { tabs = newTabs }

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

        // Re-subscribe to each surface's progress reports.
        surfaceCancellables = tabWindows.compactMap { w in
            guard let controller = w.windowController as? BaseTerminalController,
                  let surface = controller.focusedSurface else { return nil }
            return surface.$progressReport
                .dropFirst()
                .removeDuplicates { $0 == nil && $1 == nil }
                .sink { [weak self] _ in
                    DispatchQueue.main.async { self?.refresh() }
                }
        }
    }

    // MARK: - Detection helpers

    /// Detect what's running from the window/surface title. Cheap heuristic;
    /// a hooks-driven IPC can refine this later.
    private static func kind(forTitle title: String) -> TabKind {
        let t = title.lowercased()
        if t.contains("claude") { return .claude }
        if t.contains("codex") { return .codex }
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
