import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted whenever tab group membership may have changed (new tab, close,
    /// reorder). Posted from `TerminalController.relabelTabs`, which upstream
    /// already invokes on every membership change.
    static let phanttomSidebarTabsDidChange = Notification.Name("phanttomSidebarTabsDidChange")

    /// Posted once when a sidebar reorder finishes mutating the tab group, so
    /// every window's sidebar rebuilds exactly once instead of once per
    /// `makeKey()` inside the shuffle.
    static let phanttomSidebarReorderDidFinish = Notification.Name("phanttomSidebarReorderDidFinish")
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
        /// The resolved git metadata for the tab's pwd — branch,
        /// `projectRoot` (the grouping key; worktrees resolve to their
        /// parent repo), and the linked-worktree flag — as one snapshot,
        /// so the fields can never disagree mid-resolve. nil while the pwd
        /// has never finished a resolve.
        let git: GitBranchCache.Resolved?
        let prState: PRStatusCache.PRState?
        let kind: TabKind
        /// Display name of the agent session's model ("Fable 5"), pretty-
        /// printed from the raw id in `PhanttomTabState` at snapshot time.
        /// nil until the hook has seen an assistant turn (or for non-Claude
        /// tabs).
        let model: String?
        /// State-owned title when custom/auto are absent (marker prompt, or
        /// kind label for a model-only marker). Nil means fall through to
        /// glyph-stripping the surface title.
        let titleFallback: String?
        let status: TabStatus
        let isSelected: Bool
        let window: NSWindow

        /// What the sidebar shows: the user's custom name, else the
        /// prompt-derived auto name, else the state's presentation
        /// fallback, else the surface title with leading decoration glyphs
        /// stripped (agents like Claude Code prefix their own "✳", which
        /// doubles our icon). Marker-protocol parsing stays in
        /// `PhanttomTabState` — this path has no U+2063 awareness.
        var displayTitle: String {
            if let customTitle, !customTitle.isEmpty { return customTitle }
            if let autoTitle, !autoTitle.isEmpty { return autoTitle }
            if let titleFallback, !titleFallback.isEmpty { return titleFallback }
            guard kind != .terminal else { return title }
            var s = Substring(title)
            while let first = s.unicodeScalars.first,
                  !CharacterSet.alphanumerics.contains(first) {
                s = s.dropFirst()
            }
            let cleaned = s.trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? title : cleaned
        }

        /// The pwd's display leaf for the agent card subtitle when the
        /// directory has no git branch: last path component, home as "~".
        var directoryLeaf: String? {
            directory.map {
                (($0 as NSString).abbreviatingWithTildeInPath as NSString).lastPathComponent
            }
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

    /// True while our own window's row is being held out of a fresh list so
    /// its insertion can animate on-screen (see the staged publish in
    /// refresh). Every publish keeps filtering the row until the delayed
    /// release, because the release must not race the sync refreshes that
    /// ride window presentation — those can run before the first frame.
    private var unfoldPending = false

    /// Schedule the animated unfold of the held-back own row, a couple of
    /// frames after the window's first on-screen frame so the user actually
    /// sees it grow in. No-op unless a row is held.
    private func releaseUnfoldIfNeeded() {
        guard unfoldPending else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self, self.unfoldPending else { return }
            self.unfoldPending = false
            self.refresh()
        }
    }

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

        // The single refresh a reorder is allowed. Synchronous, like
        // didBecomeKey below and for the same reason: the reordered list has
        // to land in the frame the mouse came up on, not a turn later.
        notificationObservers.append(center.addObserver(
            forName: .phanttomSidebarReorderDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
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
                // A reorder calls makeKey() to put selection back, and this
                // notification is app-wide — so without this guard a single
                // drop costs one synchronous whole-list rebuild per window in
                // the group. The reorder posts one refresh for everyone when
                // it unwinds instead.
                guard !Self.isReordering else { return }
                self.refresh()
                // Our own window's first key moment is also its first
                // on-screen frame — the cue that a held-back row (see the
                // staged publish in refresh) can now unfold where the user
                // will actually see it.
                if affected === self.window { self.releaseUnfoldIfNeeded() }
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

    /// Depth of an in-flight reorder, process-wide because the refreshes being
    /// suppressed fire on *other* windows' managers.
    private static var reorderDepth = 0

    static var isReordering: Bool { reorderDepth > 0 }

    /// Whether the single post-reorder refresh should animate. False for a
    /// drag, where the rows already parted to show the final arrangement;
    /// true for menu/keyboard moves, where the list has to show what changed.
    /// Read by `refresh` during the finish notification, by which point the
    /// depth is already back to 0 — so `isReordering` can't carry this.
    private static var reorderWantsAnimation = true

    /// Runs `body` with reorder-driven key-change refreshes suppressed, then
    /// tells every sidebar to refresh once. `defer`-balanced so an early
    /// return inside can't wedge the app into a permanently stale sidebar.
    private static func withReorderSuppression(
        animated: Bool,
        _ body: () -> Void
    ) {
        reorderDepth += 1
        defer {
            reorderDepth -= 1
            if reorderDepth == 0 {
                reorderWantsAnimation = animated
                NotificationCenter.default.post(
                    name: .phanttomSidebarReorderDidFinish, object: nil)
                reorderWantsAnimation = true
            }
        }
        body()
    }

    /// Reorder `tab` immediately before or after `target` in the native tab
    /// group. `.before` → `ordered: .below`, `.after` → `ordered: .above`
    /// (AppKit tab-group placement). Preserves whichever tab was selected
    /// before the move — `removeWindow`/`addTabbedWindow` otherwise steals
    /// selection (often onto the moved window). Same contract as keyboard
    /// move-tab otherwise; every sidebar refreshes once when this unwinds,
    /// via `.phanttomSidebarReorderDidFinish`.
    ///
    /// `animated` is false when a sidebar drag drove this: the rows have
    /// already parted to show the result, so the publish only has to swap the
    /// real order in underneath.
    func reorder(
        _ tab: TabItem,
        relativeTo target: TabItem,
        edge: SidebarDragReorder.Edge,
        animated: Bool = true
    ) {
        guard tab.id != target.id else { return }
        let moved = tab.window
        let anchor = target.window
        guard let tabGroup = moved.tabGroup,
              tabGroup === anchor.tabGroup,
              tabGroup.windows.contains(moved),
              tabGroup.windows.contains(anchor)
        else { return }

        let windows = tabGroup.windows
        guard let from = windows.firstIndex(where: { $0 === moved }),
              let to = windows.firstIndex(where: { $0 === anchor })
        else { return }

        // Already in the requested slot — nothing to do.
        switch edge {
        case .before where from == to - 1: return
        case .after where from == to + 1: return
        default: break
        }

        let ordered: NSWindow.OrderingMode = edge == .after ? .above : .below
        // Capture before removeWindow — AppKit often retargets selection
        // during the shuffle (to the moved window or a neighbor).
        let selected = tabGroup.selectedWindow

        // Match TerminalController.onMoveTab's Tahoe titlebar-tab workaround:
        // synchronous re-add glitches the native tab strip on macOS 26+.
        if #available(macOS 26, *) {
            if moved is TitlebarTabsTahoeTerminalWindow {
                Self.withReorderSuppression(animated: animated) {
                    tabGroup.removeWindow(moved)
                    anchor.addTabbedWindowSafely(moved, ordered: ordered)
                    // Sync restore for the sidebar snapshot; async again after
                    // AppKit settles (Tahoe titlebar-tabs glitch workaround).
                    Self.restoreSelection(selected, in: tabGroup)
                }
                // Deliberately outside the suppression: the depth is already
                // back to 0 by the time this runs, and this pass has to be
                // allowed to publish.
                DispatchQueue.main.async {
                    Self.restoreSelection(selected, in: tabGroup)
                }
                return
            }
        }

        Self.withReorderSuppression(animated: animated) {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            tabGroup.removeWindow(moved)
            anchor.addTabbedWindowSafely(moved, ordered: ordered)
            Self.restoreSelection(selected, in: tabGroup)
            NSAnimationContext.endGrouping()
        }
    }

    /// Put `window` back as the tab group's selected/key window when it is
    /// still a member. Uses `makeKey()` (not `makeKeyAndOrderFront`) to
    /// avoid an extra z-order flash on top of the tab shuffle.
    private static func restoreSelection(_ window: NSWindow?, in tabGroup: NSWindowTabGroup) {
        guard let window, tabGroup.windows.contains(where: { $0 === window }) else { return }
        tabGroup.selectedWindow = window
        window.makeKey()
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
            let state = (w as? TerminalWindow)?.phanttomTabState
            // The seed is the directory a sidebar "+" created this tab
            // into — a stand-in until shell integration reports the real
            // pwd, so the row groups correctly from its very first frame.
            if surface?.pwd != nil { state?.seedDirectory = nil }
            let pwd = surface?.pwd ?? w.representedURL?.path ?? state?.seedDirectory
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
            state?.update(
                titles: surfaces.isEmpty ? [w.title] : surfaces.map(\.title),
                isWorking: isWorking,
                isSelected: isSelected
            )

            // Definitive resolves update the window's sticky metadata;
            // unknown gaps (resolve in flight, cache entry pruned) keep the
            // last known value so group identity never flaps through an
            // interim state. Windows without tab state (non-TerminalWindow)
            // just read the cache directly.
            let freshMeta = pwd.flatMap { GitBranchCache.shared.metadata(at: $0) }
            if let freshMeta, let state {
                state.lastGitMetadata = freshMeta
            }
            let gitMeta = state?.lastGitMetadata ?? freshMeta
            var prState: PRStatusCache.PRState?
            if let pwd, let branch = gitMeta?.branch {
                prState = PRStatusCache.shared.state(at: pwd, branch: branch)
            }

            newTabs.append(TabItem(
                id: id,
                title: w.title,
                customTitle: controller?.titleOverride,
                autoTitle: state?.autoTitle,
                directory: pwd,
                git: gitMeta,
                prState: prState,
                kind: state?.kind ?? .terminal,
                model: state?.model.map { PhanttomTabState.modelDisplayName($0) },
                titleFallback: state?.titleFallback,
                status: state?.status ?? .idle,
                isSelected: isSelected,
                window: w
            ))
        }

        if newTabs != tabs {
            // Animate removals, in-place changes, and SINGLE-row inserts —
            // a closing tab collapses (rows slide up into the gap) and a
            // newly created tab unfolds downward. Bulk inserts stay instant:
            // a fresh sidebar populating its whole list at once would read
            // as a full re-render, not "one tab was added".
            //
            // The new-tab case needs a staged publish to look right: a new
            // tab is a new WINDOW with a brand-new (empty) sidebar, so from
            // this manager's view the whole list is a bulk insert. When that
            // fresh list is our own window joining an existing group, first
            // publish the pre-existing rows instantly (matching what the
            // previous window's sidebar showed, so the window swap is
            // seamless), then re-refresh next turn — which becomes the
            // animated single insert of our own row.
            let oldIDs = Set(tabs.map(\.id))
            let insertedIDs = newTabs.map(\.id).filter { !oldIDs.contains($0) }
            let ownID = ObjectIdentifier(window)

            // A fresh sidebar catching up to an existing group: pre-existing
            // rows arrive as inserts against a list that's empty or holds
            // only our own row — the manager's very first refresh can run
            // before the window joins its group, so the own row may already
            // be published (and thus not part of the insert). With a single
            // foreign insert this shape is ambiguous: it also matches an
            // established lone tab watching a brand-new tab arrive. Position
            // breaks the tie — a new tab always joins AFTER its parent, so a
            // pre-existing row materializes above our own row, a genuinely
            // new tab below.
            let isCatchingUp: Bool = {
                guard tabs.allSatisfy({ $0.id == ownID }),
                      let ownIndex = newTabs.firstIndex(where: { $0.id == ownID })
                else { return false }
                let ownState = (window as? TerminalWindow)?.phanttomTabState
                // Sidebar-created windows mark themselves — deterministic,
                // and covers a group "+" inserting our brand-new row ABOVE
                // the pre-existing rows, where the position heuristic below
                // would read the shape backwards.
                if ownState?.pendingSidebarCatchUp == true { return true }
                // Only a window created moments ago can be catching up at
                // all. Without this gate, an ESTABLISHED lone tab watching
                // a sibling get inserted above it (its own group's "+")
                // matches the position heuristic and stages its own row
                // away — a tab that was open the whole time vanishes for
                // the fallback timer's full two seconds.
                guard let ownState,
                      ContinuousClock.now - ownState.createdAt < .seconds(2)
                else { return false }
                let foreign = newTabs.enumerated().filter {
                    $0.element.id != ownID && !oldIDs.contains($0.element.id)
                }
                if foreign.count > 1 { return true }
                guard let only = foreign.first else { return false }
                // Native flows always join a new tab AFTER its parent, so
                // for young windows position still breaks the tie: a
                // pre-existing row materializes above our own row, a
                // genuinely new tab below.
                return only.offset < ownIndex
            }()

            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                tabs = newTabs
            } else if unfoldPending {
                // Our own row is staged for an animated unfold; keep holding
                // it back so an interleaved refresh (didBecomeKey runs one
                // synchronously during presentation) can't publish it early
                // and off-screen.
                let held = newTabs.filter { $0.id != ownID }
                if held != tabs { tabs = held }
            } else if isCatchingUp {
                unfoldPending = true
                tabs = newTabs.filter { $0.id != ownID }
                // Released a beat after the window's first on-screen frame,
                // not on a fixed delay from here: presentation is itself
                // deferred (TerminalController.newTab), so a timer from this
                // point can elapse while the window is still off-screen and
                // the unfold would play unseen. didBecomeKey is the
                // on-screen cue; the timer below is only a fallback for
                // windows that never front (a restored background window
                // keeps its full list correct even if never clicked).
                if window.isKeyWindow {
                    releaseUnfoldIfNeeded()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
                        guard let self, self.unfoldPending else { return }
                        self.unfoldPending = false
                        self.refresh()
                    }
                }
            } else if insertedIDs.count == 1, !tabs.isEmpty {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                    tabs = newTabs
                }
            } else if !insertedIDs.isEmpty {
                tabs = newTabs
            } else if oldIDs != Set(newTabs.map(\.id)) {
                // Removal — animate the collapse.
                withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                    tabs = newTabs
                }
            } else if tabs.map(\.id) != newTabs.map(\.id) {
                // Same membership, new order. When this is the tail of a
                // sidebar drag it must be instant: the rows already parted to
                // show this exact arrangement, so animating would re-animate
                // a list that is visually already correct — which is what
                // used to read as the row floating before it settled. A
                // reorder from anywhere else (the keyboard move-tab command)
                // still gets the snappy settle.
                if Self.reorderWantsAnimation {
                    withAnimation(SidebarDragReorder.settleAnimation) {
                        tabs = newTabs
                    }
                } else {
                    tabs = newTabs
                }
            } else {
                // In-place field updates only (selection, title, status) —
                // instant so a selection change doesn't reshuffle the list.
                tabs = newTabs
            }
        }

        // The catch-up question is settled once this manager has processed a
        // list containing rows other than its own; retire the creation flag
        // so it can't leak into a later, genuinely ambiguous shape.
        if let ownState = (window as? TerminalWindow)?.phanttomTabState,
           ownState.pendingSidebarCatchUp,
           newTabs.contains(where: { $0.id != ObjectIdentifier(window) }) {
            ownState.pendingSidebarCatchUp = false
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

        // Progress reports, title, and background of every surface in the
        // group — not just the focused one, so background splits still report.
        // Tab identity is computed from every split's title (refresh reads
        // surfaces.map(\.title)); window.title mirrors only the focused split,
        // so a background split's title change would otherwise fire no refresh.
        surfaceCancellables = surfaces.flatMap { surface -> [AnyCancellable] in
            [
                surface.$title
                    .dropFirst()
                    .removeDuplicates()
                    .sink { [weak self] _ in
                        DispatchQueue.main.async { self?.scheduleRefresh() }
                    },
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
