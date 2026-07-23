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
    private let terminalContainer: TerminalViewContainer
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
        sidebar.isHidden ? 0 : sidebar.frame.width + dividerThickness
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didRestoreWidth else { return }
        didRestoreWidth = true
        layoutSubtreeIfNeeded()
        if isSidebarCollapsed {
            sidebar.isHidden = true
            adjustSubviews()
        } else {
            setPosition(savedSidebarWidth, ofDividerAt: 0)
        }
    }

    /// Collapse or expand the sidebar. Expanding restores the last
    /// user-chosen width.
    func setSidebarCollapsed(_ collapsed: Bool, animated: Bool = true) {
        guard collapsed != isSidebarCollapsed else { return }
        isSidebarCollapsed = collapsed
        UserDefaults.standard.set(collapsed, forKey: Self.collapsedDefaultsKey)

        let apply = {
            self.sidebar.isHidden = collapsed
            self.adjustSubviews()
            if !collapsed {
                self.setPosition(self.savedSidebarWidth, ofDividerAt: 0)
            }
            self.layoutSubtreeIfNeeded()
            self.onSidebarWidthChange?(self.currentSidebarWidth)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = .init(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
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

    // MARK: - NSSplitViewDelegate

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        Self.minWidth
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        Self.maxWidth
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === sidebar
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        sidebar.isHidden
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        onSidebarWidthChange?(currentSidebarWidth)
        guard didRestoreWidth, !sidebar.isHidden, sidebar.frame.width >= Self.minWidth else { return }
        UserDefaults.standard.set(sidebar.frame.width, forKey: Self.widthDefaultsKey)
    }
}
