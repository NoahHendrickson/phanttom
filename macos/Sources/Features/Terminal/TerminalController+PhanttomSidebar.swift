import AppKit
import Combine
import SwiftUI

extension TerminalController {
    /// Phanttom: wrap the terminal in a [sidebar | terminal] split view, wire
    /// glass settings, and add the titlebar collapse control. Returns the
    /// split view to install as `window.contentView`.
    func installPhanttomSidebar(terminalContainer: TerminalViewContainer) -> NSView {
        guard let window else { return terminalContainer }

        // The sidebar replaces the native tab bar (see TerminalWindow.sidebarActive).
        (window as? TerminalWindow)?.sidebarActive = true

        // One facade per window — retargets to the tab-group model when the
        // window joins its parent after windowDidLoad.
        let sidebarTabManager = SidebarTabManager(window: window)
        self.sidebarTabManager = sidebarTabManager

        let sidebarHost = NSHostingView(rootView: SidebarView(
            ghostty: ghostty,
            tabManager: sidebarTabManager,
            onNewTab: { [weak self] in self?.newTab(nil) }
        ))
        // Don't let SwiftUI's ideal size constrain the pane — the split view
        // owns the width, including collapsing it to zero.
        sidebarHost.sizingOptions = []

        let sidebarSplit = SidebarSplitView(sidebar: sidebarHost, terminal: terminalContainer)
        // Full sync (not just geometry): a sidebar toggle never runs
        // syncAppearance, so this is also what restores the zone colors after
        // the window style repaints the titlebar. Assigned before contentView
        // so the width restore in viewDidMoveToWindow isn't lost.
        sidebarSplit.onSidebarWidthChange = { [weak self] width in
            (self?.window as? TerminalWindow)?.syncPhanttomTitlebarZone(width: width)
        }

        addSidebarToggleAccessory(to: window)
        phanttomSettingsCancellable = PhanttomSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Next runloop turn so the changed value has landed.
                DispatchQueue.main.async {
                    (self?.window as? TerminalWindow)?.phanttomGlassSettingsChanged()
                }
            }

        return sidebarSplit
    }

    @IBAction func togglePhanttomSidebar(_ sender: Any?) {
        (window?.contentView as? SidebarSplitView)?.toggleSidebar()
    }

    /// The titlebar button that collapses/expands the sidebar, placed just
    /// right of the traffic lights (Cursor-style).
    fileprivate func addSidebarToggleAccessory(to window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        guard let image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: "Toggle Sidebar") else { return }

        let button = NSButton(image: image, target: self, action: #selector(togglePhanttomSidebar(_:)))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Toggle Sidebar (⌘B)"
        button.frame = NSRect(x: 8, y: 1, width: 20, height: 20)
        button.autoresizingMask = [.minYMargin, .maxYMargin]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 22))
        container.addSubview(button)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .left
        window.addTitlebarAccessoryViewController(accessory)
    }
}
