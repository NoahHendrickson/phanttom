import AppKit

/// The window content view when the sidebar is enabled: a thin-divider split
/// of [sidebar | terminal]. Owns its own delegate duties (width constraints,
/// persistence) so `TerminalController` stays lean.
final class SidebarSplitView: NSSplitView, NSSplitViewDelegate {
    private static let widthDefaultsKey = "PhanttomSidebarWidth"
    private static let collapsedDefaultsKey = "PhanttomSidebarCollapsed"
    /// Posted (object: the originating split view) whenever the shared
    /// width/collapse state changes, so sibling tab windows re-apply it while
    /// still hidden instead of visibly resizing when they become main.
    private static let stateDidChange = Notification.Name("PhanttomSidebarStateDidChange")
    private static let minWidth: CGFloat = 160
    private static let maxWidth: CGFloat = 360
    private static let defaultWidth: CGFloat = 271
    /// The width the terminal pane is guaranteed to keep when the window is
    /// too narrow to show the full sidebar: below this the sidebar yields
    /// (down to `minWidth`) rather than crushing the terminal.
    private static let terminalMinWidth: CGFloat = 200

    private let sidebar: NSView
    /// Exposed so BaseTerminalController.terminalViewContainer can route
    /// through the split (upstream casts contentView directly).
    let terminalContainer: TerminalViewContainer
    private var didRestoreWidth = false

    /// Fired whenever the sidebar's effective width changes (divider drags,
    /// collapse/expand). Reports 0 while collapsed. The titlebar zone uses
    /// this to keep its color split aligned with the divider.
    var onSidebarWidthChange: ((CGFloat) -> Void)?

    private(set) var isSidebarCollapsed =
        UserDefaults.standard.bool(forKey: SidebarSplitView.collapsedDefaultsKey)

    /// The width of the sidebar pane as the titlebar sees it: everything left
    /// of the divider's right edge, 0 when collapsed.
    var currentSidebarWidth: CGFloat {
        sidebar.frame.width < 1 ? 0 : sidebar.frame.width + dividerThickness
    }

    init(sidebar: NSView, terminal: TerminalViewContainer) {
        self.sidebar = sidebar
        self.terminalContainer = terminal
        super.init(frame: .zero)

        isVertical = true
        dividerStyle = .thin
        delegate = self

        addSubview(sidebar)
        addSubview(terminal)

        // The sidebar holds its width; the terminal absorbs window resizes.
        setHoldingPriority(.init(260), forSubviewAt: 0)
        setHoldingPriority(.init(250), forSubviewAt: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var savedSidebarWidth: CGFloat {
        let saved = UserDefaults.standard.double(forKey: Self.widthDefaultsKey)
        guard saved > 0 else { return Self.defaultWidth }
        return min(max(saved, Self.minWidth), Self.maxWidth)
    }

    /// The chosen sidebar width clamped to what the current window can show
    /// without crushing the terminal below `terminalMinWidth`. Returns the
    /// desired width untouched before the window has a real size (the first
    /// real layout re-fits it via resizeSubviews).
    private func fittedWidth(_ desired: CGFloat) -> CGFloat {
        guard bounds.width > 1 else { return desired }
        let maxFit = bounds.width - dividerThickness - Self.terminalMinWidth
        return min(max(desired, Self.minWidth), max(Self.minWidth, maxFit))
    }

    /// Re-applies the shared persisted state when this window becomes main.
    private var becomeMainObserver: NSObjectProtocol?
    /// Re-applies the shared persisted state when a sibling split changes it.
    private var siblingStateObserver: NSObjectProtocol?

    deinit {
        if let becomeMainObserver {
            NotificationCenter.default.removeObserver(becomeMainObserver)
        }
        if let siblingStateObserver {
            NotificationCenter.default.removeObserver(siblingStateObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let becomeMainObserver {
            NotificationCenter.default.removeObserver(becomeMainObserver)
            self.becomeMainObserver = nil
        }
        if let siblingStateObserver {
            NotificationCenter.default.removeObserver(siblingStateObserver)
            self.siblingStateObserver = nil
        }
        guard let window else { return }

        // Tabs are sibling windows, each with its own split view, while the
        // width/collapse state is shared (persisted). Apply a sibling's
        // change immediately — while this window is still hidden — so
        // switching tabs never shows the terminal resizing to catch up.
        siblingStateObserver = NotificationCenter.default.addObserver(
            forName: Self.stateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, (notification.object as? SidebarSplitView) !== self else { return }
            self.syncSharedSidebarState()
        }

        // Fallback for anything the broadcast missed (e.g. state persisted
        // before this split existed).
        becomeMainObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.syncSharedSidebarState()
        }

        guard !didRestoreWidth else { return }
        didRestoreWidth = true
        layoutSubtreeIfNeeded()
        setPosition(isSidebarCollapsed ? 0 : fittedWidth(savedSidebarWidth), ofDividerAt: 0)
    }

    /// True while applying a sibling's state, so the apply itself doesn't
    /// re-broadcast and echo back to the originator mid-animation.
    private var isApplyingSharedState = false

    private func syncSharedSidebarState() {
        isApplyingSharedState = true
        defer { isApplyingSharedState = false }
        let collapsed = UserDefaults.standard.bool(forKey: Self.collapsedDefaultsKey)
        if collapsed != isSidebarCollapsed {
            // Applies the shared width too when expanding.
            setSidebarCollapsed(collapsed, animated: false)
            return
        }
        guard !isSidebarCollapsed, toggleAnimationTimer == nil else { return }
        let width = fittedWidth(savedSidebarWidth)
        guard abs(sidebar.frame.width - width) > 0.5 else { return }
        setPosition(width, ofDividerAt: 0)
        layoutSubtreeIfNeeded()
        onSidebarWidthChange?(currentSidebarWidth)
    }

    /// Drives the collapse/expand slide; see setSidebarCollapsed.
    private var toggleAnimationTimer: Timer?

    /// Collapse or expand the sidebar by moving the divider (a hidden-subview
    /// collapse fights the SwiftUI hosting view's layout constraints).
    /// Expanding restores the last user-chosen width.
    ///
    /// The slide steps plain setPosition calls from a timer instead of using
    /// an implicit-animation group: with Auto-Layout-backed subviews the
    /// split view defers implicitly-animated frame changes past the group,
    /// so the delegate only ever hears the pre-toggle width and the divider
    /// is never redrawn (leaving a stale line at the old position). Stepping
    /// keeps every frame on the same synchronous path as a user divider
    /// drag: real frames, correct delegate callbacks, and the divider drawn
    /// and hidden on time.
    func setSidebarCollapsed(_ collapsed: Bool, animated: Bool = true) {
        guard collapsed != isSidebarCollapsed else { return }
        isSidebarCollapsed = collapsed
        UserDefaults.standard.set(collapsed, forKey: Self.collapsedDefaultsKey)
        // Siblings jump straight to the final state; only this window slides.
        if !isApplyingSharedState {
            NotificationCenter.default.post(name: Self.stateDidChange, object: self)
        }

        toggleAnimationTimer?.invalidate()
        toggleAnimationTimer = nil

        let start = sidebar.frame.width
        let target = collapsed ? 0 : fittedWidth(savedSidebarWidth)
        guard animated, window != nil, start != target else {
            setPosition(target, ofDividerAt: 0)
            layoutSubtreeIfNeeded()
            onSidebarWidthChange?(currentSidebarWidth)
            return
        }

        let duration = 0.18
        let startTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let t = min((CACurrentMediaTime() - startTime) / duration, 1)
            let eased = t * t * (3 - 2 * t) // smoothstep, ≈ ease-in-ease-out
            self.setPosition(start + (target - start) * eased, ofDividerAt: 0)
            self.layoutSubtreeIfNeeded()
            self.onSidebarWidthChange?(self.currentSidebarWidth)
            if t >= 1 {
                timer.invalidate()
                self.toggleAnimationTimer = nil
            }
        }
        toggleAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func toggleSidebar(animated: Bool = true) {
        setSidebarCollapsed(!isSidebarCollapsed, animated: animated)
    }

    /// Re-pin the sidebar to its chosen width on every window-frame change.
    ///
    /// Default split-view behavior only holds the sidebar's width via holding
    /// priority: shrinking the window past the point where the terminal is
    /// exhausted squeezes the sidebar, and growing back hands all the room to
    /// the terminal — so the sidebar stays stuck narrow (the shrink-then-grow
    /// drift). Enforcing `fittedWidth(savedSidebarWidth)` here makes the
    /// sidebar a genuinely fixed-width pane: it recovers to the chosen width
    /// as soon as there's room and yields (to keep the terminal usable) only
    /// while the window is too narrow.
    ///
    /// Only fires for frame changes (window resize), never for divider drags
    /// or the collapse slide (those move the divider, not our frame), but the
    /// guards below are belt-and-suspenders. The setPosition call can't
    /// recurse into here — it repositions the divider without changing our
    /// frame — and the diff check stops it from fighting an already-fit width.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard didRestoreWidth, !isSidebarCollapsed,
              toggleAnimationTimer == nil, !isDraggingDivider,
              bounds.width > 1 else { return }
        let target = fittedWidth(savedSidebarWidth)
        guard abs(sidebar.frame.width - target) > 0.5 else { return }
        setPosition(target, ofDividerAt: 0)
    }

    /// Forward the terminal's intrinsic size (plus our chrome) so the
    /// `window-width`/`window-height` default-size logic keeps working with us
    /// as the window's content view.
    override var intrinsicContentSize: NSSize {
        let terminal = terminalContainer.intrinsicContentSize
        guard terminal.width != NSView.noIntrinsicMetric,
              terminal.height != NSView.noIntrinsicMetric
        else { return terminal }
        return NSSize(
            width: terminal.width + currentSidebarWidth,
            height: terminal.height
        )
    }

    /// A separator between the sidebar and the terminal (hidden with the
    /// divider while collapsed). A semi-opaque mid gray rather than
    /// translucent white: over dark backgrounds it reads as the same subtle
    /// light hairline (≈ the old white 12%), but over a bright or colorful
    /// backdrop — the desktop showing through window glass — it anchors to
    /// a muted dark line instead of vanishing into the blur. Keep in sync
    /// with the titlebar zone's fallback (PhanttomTitlebarZone).
    override var dividerColor: NSColor {
        NSColor(white: 0.35, alpha: 0.4)
    }

    // MARK: - NSSplitViewDelegate

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        // No minimum while the toggle slide runs, so the expand animation can
        // sweep 0 → width instead of popping to the minimum on its first step.
        (isSidebarCollapsed || toggleAnimationTimer != nil) ? 0 : Self.minWidth
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        Self.maxWidth
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        sidebar.frame.width < 1
    }

    /// True while the user is dragging the divider — this delegate method is
    /// only invoked for interactive drags, never for programmatic position
    /// changes, so it positively identifies the one resize source whose
    /// width is a deliberate user choice. Cleared on the next runloop turn
    /// (after the drag step's resize callbacks have run).
    private var isDraggingDivider = false

    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if !isDraggingDivider {
            isDraggingDivider = true
            DispatchQueue.main.async { [weak self] in self?.isDraggingDivider = false }
        }
        return proposedPosition
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        onSidebarWidthChange?(currentSidebarWidth)
        guard didRestoreWidth, !isSidebarCollapsed, sidebar.frame.width >= Self.minWidth else { return }
        // Only a divider drag persists its width. Every other resize source
        // is transient — the collapse/expand slide, window live-resize, and
        // programmatic frame changes (fullscreen transitions, zoom, Stage
        // Manager / Split View tiling) where autolayout can squeeze the
        // sidebar — and must not overwrite the user's chosen width.
        guard isDraggingDivider, toggleAnimationTimer == nil else { return }
        UserDefaults.standard.set(sidebar.frame.width, forKey: Self.widthDefaultsKey)
        NotificationCenter.default.post(name: Self.stateDidChange, object: self)
    }
}
