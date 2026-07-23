import AppKit

/// The window content view when the sidebar is enabled: a thin-divider split
/// of [sidebar | terminal]. Owns its own delegate duties (width constraints,
/// persistence) so `TerminalController` stays lean.
final class SidebarSplitView: NSSplitView, NSSplitViewDelegate {
    private static let widthDefaultsKey = "PhanttomSidebarWidth"
    private static let minWidth: CGFloat = 160
    private static let maxWidth: CGFloat = 360
    private static let defaultWidth: CGFloat = 220

    private let sidebar: NSView
    private let terminalContainer: TerminalViewContainer
    private var didRestoreWidth = false

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
        setPosition(savedSidebarWidth, ofDividerAt: 0)
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
            width: terminal.width + sidebar.frame.width + dividerThickness,
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

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard didRestoreWidth, sidebar.frame.width >= Self.minWidth else { return }
        UserDefaults.standard.set(sidebar.frame.width, forKey: Self.widthDefaultsKey)
    }
}
