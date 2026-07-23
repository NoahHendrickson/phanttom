import AppKit

/// The window content view when the sidebar is enabled: a thin-divider split
/// of [sidebar | terminal]. Owns its own delegate duties (width constraints,
/// persistence) so `TerminalController` stays lean.
final class SidebarSplitView: NSSplitView, NSSplitViewDelegate {
    private static let widthDefaultsKey = "PhanttomSidebarWidth"
    private static let collapsedDefaultsKey = "PhanttomSidebarCollapsed"
    private static let minWidth: CGFloat = 160
    private static let maxWidth: CGFloat = 360
    private static let defaultWidth: CGFloat = 271

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

    /// Re-applies the shared persisted state when this window becomes main.
    private var becomeMainObserver: NSObjectProtocol?

    deinit {
        if let becomeMainObserver {
            NotificationCenter.default.removeObserver(becomeMainObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let becomeMainObserver {
            NotificationCenter.default.removeObserver(becomeMainObserver)
            self.becomeMainObserver = nil
        }
        guard let window else { return }

        // Tabs are sibling windows, each with its own split view, while the
        // width/collapse state is shared (persisted). Re-apply it whenever
        // this window is selected so the sidebar keeps one width across tabs
        // instead of whatever this window had when it was last visible.
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
        setPosition(isSidebarCollapsed ? 0 : savedSidebarWidth, ofDividerAt: 0)
    }

    private func syncSharedSidebarState() {
        let collapsed = UserDefaults.standard.bool(forKey: Self.collapsedDefaultsKey)
        if collapsed != isSidebarCollapsed {
            // Applies the shared width too when expanding.
            setSidebarCollapsed(collapsed, animated: false)
            return
        }
        guard !isSidebarCollapsed else { return }
        let width = savedSidebarWidth
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

        toggleAnimationTimer?.invalidate()
        toggleAnimationTimer = nil

        let start = sidebar.frame.width
        let target = collapsed ? 0 : savedSidebarWidth
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

    /// A light separator between the sidebar and the terminal (hidden with
    /// the divider while collapsed). Matches the sidebar's hairline styling.
    override var dividerColor: NSColor {
        .white.withAlphaComponent(0.12)
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

    func splitViewDidResizeSubviews(_ notification: Notification) {
        onSidebarWidthChange?(currentSidebarWidth)
        guard didRestoreWidth, !isSidebarCollapsed, sidebar.frame.width >= Self.minWidth else { return }
        // Only persist deliberate widths: skip the collapse/expand animation
        // frames (interrupting the slide would save a mid-animation width)
        // and window live-resizes (autolayout can squeeze the sidebar, which
        // must not overwrite the user's chosen width for every window).
        guard toggleAnimationTimer == nil, window?.inLiveResize != true else { return }
        UserDefaults.standard.set(sidebar.frame.width, forKey: Self.widthDefaultsKey)
    }
}
