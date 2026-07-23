import AppKit
import Combine
import SwiftUI
import GhosttyKit

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
    ///
    /// Runs once per window (windowDidLoad): a live config reload that
    /// switches titlebar style only affects windows created afterwards.
    /// Accepted limitation — see PHANTTOM.md.
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
            // The app-wide Sparkle state; the fallback only exists so previews
            // and tests without an AppDelegate get an inert (idle) model.
            updateModel: (NSApp.delegate as? AppDelegate)?.updateViewModel ?? UpdateViewModel(),
            onNewTab: { [weak self] workingDirectory, insertBefore in
                guard let self else { return }
                guard let workingDirectory else {
                    self.newTab(nil)
                    return
                }
                // Start from the parent surface's inherited tab config (what
                // the plain ⌘T path uses — font size etc. carry over) and
                // swap in the explicit working directory.
                var config: Ghostty.SurfaceConfiguration
                if let surface = self.focusedSurface?.surface {
                    config = Ghostty.SurfaceConfiguration(
                        from: ghostty_surface_inherited_config(
                            surface, GHOSTTY_SURFACE_CONTEXT_TAB))
                } else {
                    config = Ghostty.SurfaceConfiguration()
                }
                config.workingDirectory = workingDirectory
                let controller = TerminalController.newTab(
                    self.ghostty, from: self.window, withBaseConfig: config)
                // Seed the sidebar grouping so the new row lands in its
                // project group on the very first frame — the shell won't
                // report a real pwd for another beat.
                guard let newWindow = controller?.window else { return }
                (newWindow as? TerminalWindow)?
                    .phanttomTabState.seedDirectory = workingDirectory
                // A group's "+" puts the new tab at the TOP of its group:
                // reposition in the real (native) tab order, before the
                // group's first window, so the sidebar, ⌘1-9, and ctrl-tab
                // all agree. Runs before the deferred presentation, so
                // there's no visible shuffle.
                if let insertBefore, insertBefore !== newWindow,
                   let tabGroup = insertBefore.tabGroup,
                   tabGroup.windows.contains(newWindow) {
                    tabGroup.removeWindow(newWindow)
                    insertBefore.addTabbedWindowSafely(newWindow, ordered: .below)
                }
            }
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
    /// Phanttom: a brand-new surface's title is the "👻" placeholder until
    /// shell integration reports a real one, so every new tab pops
    /// 👻-then-real-title into the titlebar and sidebar row within a second —
    /// which reads as a glitchy flash. With the sidebar active, show nothing
    /// instead: the titlebar stays quiet until the real title arrives, and
    /// the sidebar row falls back to its "Terminal" label on empty.
    func phanttomDisplayTitle(_ title: String) -> String {
        guard (window as? TerminalWindow)?.sidebarActive == true else { return title }
        return title == "👻" ? "" : title
    }

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
