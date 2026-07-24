import AppKit
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
            tabManager: sidebarTabManager,
            // The app-wide Sparkle state; the fallback only exists so previews
            // and tests without an AppDelegate get an inert (idle) model.
            updateModel: (NSApp.delegate as? AppDelegate)?.updateViewModel ?? UpdateViewModel(),
            onNewTab: { [weak self] workingDirectory, insertBefore in
                self?.phanttomNewSidebarTab(
                    in: workingDirectory, before: insertBefore)
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
        // Sidebar toggle lives in the titlebar zone, immediately left of
        // the grouping button (see PhanttomTitlebarZone).

        return true
    }

    /// Create a tab from the sidebar (a group header's "+") — the one owner
    /// of the seed/catch-up/reorder contract:
    ///
    /// - Starts from the parent surface's inherited tab config (what the
    ///   plain ⌘T path uses, so font size etc. carry over) with the
    ///   explicit working directory swapped in.
    /// - Seeds the new window's tab state so the sidebar row lands in its
    ///   project group on the very first frame (the shell won't report a
    ///   real pwd for another beat) and marks it as catching up for the
    ///   insert animation classifier.
    /// - When `insertBefore` is given (a group's "+" passes the group's
    ///   first window), repositions the new tab in the real native tab
    ///   order so the sidebar, ⌘1-9, and ctrl-tab all agree it sits at the
    ///   top of its group. Runs before the deferred presentation, so
    ///   there's no visible shuffle.
    func phanttomNewSidebarTab(in workingDirectory: String, before insertBefore: NSWindow?) {
        var config: Ghostty.SurfaceConfiguration
        if let surface = focusedSurface?.surface {
            config = Ghostty.SurfaceConfiguration(
                from: ghostty_surface_inherited_config(
                    surface, GHOSTTY_SURFACE_CONTEXT_TAB))
        } else {
            config = Ghostty.SurfaceConfiguration()
        }
        config.workingDirectory = workingDirectory
        let controller = TerminalController.newTab(
            ghostty, from: window, withBaseConfig: config)
        guard let newWindow = controller?.window else { return }
        if let state = (newWindow as? TerminalWindow)?.phanttomTabState {
            state.seedDirectory = workingDirectory
            state.pendingSidebarCatchUp = true
        }
        if let insertBefore, insertBefore !== newWindow,
           let tabGroup = insertBefore.tabGroup,
           tabGroup.windows.contains(newWindow) {
            tabGroup.removeWindow(newWindow)
            insertBefore.addTabbedWindowSafely(newWindow, ordered: .below)
        }
    }

    @IBAction func togglePhanttomSidebar(_ sender: Any?) {
        (window?.contentView as? SidebarSplitView)?.toggleSidebar()
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
