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
///
/// Cross-window state (names, kind, done/attention status) lives on
/// `TerminalWindow`, never here: every window in a group has its own manager,
/// so instance state would desync between sidebars (see PHANTTOM.md).
@MainActor
final class SidebarTabManager: ObservableObject {
    /// The per-window model (kind, status, auto-name) is `PhanttomTabState`,
    /// stored on `TerminalWindow`; these are the sidebar-facing names.
    typealias TabKind = PhanttomTabState.Kind
    typealias TabStatus = PhanttomTabState.Status

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

    /// Identities currently observed; KVO/Combine subscriptions are only
    /// rebuilt when the window or surface set actually changes.
    private var subscribedWindowIDs: Set<ObjectIdentifier> = []
    private var subscribedSurfaceIDs: Set<ObjectIdentifier> = []

    private var refreshScheduled = false

    init(window: NSWindow) {
        self.window = window

        let center = NotificationCenter.default

        // Membership changes are rare and can affect any group; always react.
        notificationObservers.append(center.addObserver(
            forName: .phanttomSidebarTabsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleRefresh() }
        })

        // didBecomeKey refreshes synchronously, in the notification's own
        // runloop turn. A brand-new tab's window becomes key in the same
        // turn its first frame is committed, and the manager's initial
        // refresh ran back before the window joined its tab group (upstream
        // adds it after windowDidLoad) — so deferring even one turn ships
        // that first frame with a sidebar showing only the new tab, a
        // visible whole-list flash. By key time the group is settled, so
        // refreshing in place is safe and lands in the same frame.
        notificationObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let affected = notification.object as? NSWindow,
                      self.isInGroup(affected) else { return }
                self.refresh()
            }
        })

        // Resign-key/close events fire app-wide for every window; only
        // windows in this manager's group can change what this sidebar
        // shows. These must NOT refresh synchronously: at willClose
        // delivery the closing window is still in the tab group, so the
        // shrunken membership only exists a turn later.
        let filtered: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ]
        for name in filtered {
            notificationObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let affected = notification.object as? NSWindow
                DispatchQueue.main.async {
                    guard let self, let affected, self.isInGroup(affected) else { return }
                    self.scheduleRefresh()
                }
            })
        }

        // Bell while unselected marks attention — stored on the window,
        // judged against the bell window's OWN group (a bell in a visible
        // selected tab was already seen, even if that tab is in another
        // group).
        notificationObservers.append(center.addObserver(
            forName: .terminalWindowBellDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let controller = notification.object as? BaseTerminalController
            let hasBell = notification.userInfo?[
                Notification.Name.terminalWindowHasBellKey] as? Bool ?? false
            DispatchQueue.main.async {
                guard let self, let bellWindow = controller?.window else { return }
                if hasBell,
                   let bellTerminal = bellWindow as? TerminalWindow,
                   bellWindow !== (bellWindow.tabGroup?.selectedWindow ?? bellWindow) {
                    bellTerminal.phanttomTabState.noteBell()
                }
                guard self.isInGroup(bellWindow) else { return }
                self.scheduleRefresh()
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

    /// Set (or clear, with nil/empty) a user-assigned tab name. Uses
    /// upstream's `titleOverride`, so the sidebar, titlebar, command
    /// palette, and window restoration all share one rename store. The
    /// override's didSet keeps the auto-name in sync (every writer path,
    /// not just this one).
    func rename(_ tab: TabItem, to name: String?) {
        guard let controller = tab.window.windowController as? BaseTerminalController
        else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        controller.titleOverride = (trimmed?.isEmpty ?? true) ? nil : trimmed
        NotificationCenter.default.post(name: .phanttomSidebarTabsDidChange, object: tab.window)
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

    /// Coalesce event bursts (key change + title KVO + progress in the same
    /// turn) into a single refresh on the next runloop turn — which is also
    /// the turn AppKit needs to settle tab group state after membership
    /// notifications.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        guard let window else { return }

        // Note: native tab bar hiding lives in TerminalWindow.sidebarActive
        // (the tab bar accessory is hidden as AppKit adds it). Never toggle
        // the tab bar from here — AppKit force-shows it for 2+ tab groups,
        // so toggling loops forever.

        let tabWindows = window.tabbedWindows ?? [window]
        let selected = window.tabGroup?.selectedWindow ?? window

        var newTabs: [TabItem] = []

        for w in tabWindows {
            let id = ObjectIdentifier(w)
            let controller = w.windowController as? BaseTerminalController
            let surface = controller?.focusedSurface
            let pwd = surface?.pwd ?? w.representedURL?.path
            let isSelected = w === selected

            // Working = any surface in the window reports progress; agents
            // can run in a non-focused split.
            let surfaces = controller.map { Array($0.surfaceTree) } ?? []
            let isWorking = surfaces.contains { $0.progressReport != nil }

            // Step the window's tab state, then read it into the snapshot.
            // The state lives on the window, so whichever manager refreshes
            // first records a transition and the rest agree. Identity is
            // judged from every split's title (the window title only
            // mirrors the focused one).
            let state = (w as? TerminalWindow)?.phanttomTabState
            state?.update(
                titles: surfaces.isEmpty ? [w.title] : surfaces.map(\.title),
                isWorking: isWorking,
                isSelected: isSelected
            )

            newTabs.append(TabItem(
                id: id,
                title: w.title,
                customTitle: controller?.titleOverride,
                autoTitle: state?.autoTitle,
                directory: pwd,
                gitBranch: pwd.flatMap { GitBranchCache.shared.branch(at: $0) },
                kind: state?.kind ?? .terminal,
                status: state?.status ?? .idle,
                isSelected: isSelected,
                window: w
            ))
        }

        if newTabs != tabs {
            // Animate removals and in-place changes so a closing tab
            // collapses and the rows below slide up into the gap. Never
            // animate insertions: a new tab opens a new window with a
            // brand-new sidebar whose list populates all at once, so
            // animating inserts unfolds the entire list — it reads as a
            // full re-render, not "one tab was added".
            let oldIDs = Set(tabs.map(\.id))
            let inserted = newTabs.contains { !oldIDs.contains($0.id) }
            if inserted || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                tabs = newTabs
            } else {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                    tabs = newTabs
                }
            }
        }

        let selectedSurface = (selected.windowController as? BaseTerminalController)?.focusedSurface
        let liveBackground = selectedSurface?.backgroundColor
        if liveBackground != terminalBackground { terminalBackground = liveBackground }

        resubscribeIfNeeded(tabWindows: tabWindows)
    }

    /// Rebuild KVO/Combine subscriptions only when the observed set of
    /// windows or surfaces actually changed (membership, new split, etc.).
    private func resubscribeIfNeeded(tabWindows: [NSWindow]) {
        let surfaces = tabWindows.flatMap { w -> [Ghostty.SurfaceView] in
            guard let controller = w.windowController as? BaseTerminalController
            else { return [] }
            return Array(controller.surfaceTree)
        }
        let windowIDs = Set(tabWindows.map(ObjectIdentifier.init))
        let surfaceIDs = Set(surfaces.map(ObjectIdentifier.init))
        guard windowIDs != subscribedWindowIDs || surfaceIDs != subscribedSurfaceIDs
        else { return }
        subscribedWindowIDs = windowIDs
        subscribedSurfaceIDs = surfaceIDs

        // KVO for title/pwd changes on the current membership.
        windowObservations = tabWindows.flatMap { w in
            [
                w.observe(\.title) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.scheduleRefresh() }
                },
                w.observe(\.representedURL) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.scheduleRefresh() }
                },
            ]
        }

        // Progress reports and background of every surface in the group —
        // not just the focused one, so background splits still report.
        surfaceCancellables = surfaces.flatMap { surface -> [AnyCancellable] in
            [
                surface.$progressReport
                    .dropFirst()
                    .removeDuplicates { $0 == nil && $1 == nil }
                    .sink { [weak self] _ in
                        DispatchQueue.main.async { self?.scheduleRefresh() }
                    },
                surface.$backgroundColor
                    .dropFirst()
                    .removeDuplicates()
                    .sink { [weak self] _ in
                        DispatchQueue.main.async { self?.scheduleRefresh() }
                    },
            ]
        }
    }

    private func isInGroup(_ w: NSWindow) -> Bool {
        guard let window else { return false }
        if w === window { return true }
        return window.tabbedWindows?.contains { $0 === w } ?? false
    }

}
