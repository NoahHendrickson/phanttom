import AppKit
import Combine
import SwiftUI

/// Phanttom's sidebar wiring for TerminalController, kept out of the upstream
/// file so windowDidLoad carries a single fork-owned call.
extension TerminalController {
    /// Wrap the terminal in a [sidebar | terminal] split view as the window's
    /// content view. The sidebar replaces the native tab bar (see
    /// TerminalWindow.sidebarActive).
    ///
    /// Returns false without installing when the config is incompatible —
    /// `macos-titlebar-style = tabs` relocates the tab bar accessory into the
    /// titlebar, and hiding that accessory leaves neither tabs nor a title —
    /// in which case the caller falls back to upstream's plain container.
    func phanttomInstallSidebar(
        in window: NSWindow,
        terminal container: TerminalViewContainer,
        config: Ghostty.Config
    ) -> Bool {
        guard config.macosTitlebarStyle != .tabs else { return false }

        (window as? TerminalWindow)?.sidebarActive = true
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
        let sidebarSplit = SidebarSplitView(sidebar: sidebarHost, terminal: container)
        // Full sync (not just geometry): a sidebar toggle never runs
        // syncAppearance, so this is also what restores the zone colors after
        // the window style repaints the titlebar. Assigned before contentView
        // so the width restore in viewDidMoveToWindow isn't lost.
        sidebarSplit.onSidebarWidthChange = { [weak self] width in
            (self?.window as? TerminalWindow)?.syncPhanttomTitlebarZone(width: width)
        }
        window.contentView = sidebarSplit
        addSidebarToggleAccessory(to: window)

        // Glass toggles/blur re-run the (heavier) glass + appearance path;
        // other sidebar appearance settings only need the titlebar zone
        // repainted. @Published emits on willSet, so defer a turn for the
        // changed value to land.
        let settings = PhanttomSettings.shared
        Publishers.CombineLatest(settings.$sidebarGlass, settings.$sidebarBlurAmount)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                DispatchQueue.main.async {
                    (self?.window as? TerminalWindow)?.phanttomGlassSettingsChanged()
                }
            }
            .store(in: &phanttomSettingsCancellables)
        Publishers.CombineLatest3(
            settings.$sidebarStyle, settings.$sidebarColor, settings.$sidebarOpacity)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    (self?.window as? TerminalWindow)?.syncPhanttomTitlebarZone()
                }
            }
            .store(in: &phanttomSettingsCancellables)

        return true
    }

    @IBAction func togglePhanttomSidebar(_ sender: Any?) {
        (window?.contentView as? SidebarSplitView)?.toggleSidebar()
    }

    /// The titlebar button that collapses/expands the sidebar, placed just
    /// right of the traffic lights (Cursor-style).
    private func addSidebarToggleAccessory(to window: NSWindow) {
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

extension BaseTerminalController {
    /// Phanttom: called from `titleOverride`'s didSet so EVERY writer — the
    /// sidebar rename, the ⌘-rename prompt, the native tab bar's inline
    /// editor — keeps the sidebar auto-name in sync. Clearing the override
    /// must also clear the auto-name: the sidebar falls back to the
    /// auto-name, so a clear that leaves it behind appears to do nothing.
    func phanttomTitleOverrideDidChange() {
        guard titleOverride == nil,
              let window = window as? TerminalWindow else { return }
        window.phanttomTabState.rearmAutoTitle()
    }
}
