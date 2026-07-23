import AppKit

// The same undocumented API upstream uses for terminal background blur —
// see ghostty_set_window_background_blur in src/apprt/embedded.zig, which
// notes every terminal (including Terminal.app) uses it.
@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> UnsafeMutableRawPointer

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
private func CGSSetWindowBackgroundBlurRadius(
    _ connection: UnsafeMutableRawPointer,
    _ windowNumber: Int,
    _ radius: Int32
) -> Int32

extension TerminalWindow {
    /// Phanttom's single hook at the end of upstream's syncAppearance —
    /// keeps the upstream edit to one line so merges stay cheap, and keeps
    /// the ordering-sensitive parts (glass after the opacity branch, the
    /// titlebar zone deferred past subclass repaints) in fork-owned code.
    func phanttomSyncAppearanceDidRun(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // May re-open window transparency with its own blur radius (no-op
        // when the sidebar/glass is off, in native fullscreen, when opacity
        // is forced, or when the terminal's transparency owns the blur).
        syncPhanttomSidebarGlass(surfaceConfig)

        // Repaint the titlebar strip above the sidebar. Deferred because
        // subclass syncAppearance overrides run after this base hook and
        // repaint (or lose, when AppKit rebuilds the titlebar on tab
        // open/close) our zone views — but deferred with a runloop block,
        // NOT DispatchQueue.main.async: queued runloop blocks run after the
        // current event callout yet before Core Animation commits the frame,
        // so the repair lands in the same frame as the subclass repaint. An
        // async dispatch lands a pass later, which committed one frame of
        // full-width terminal color over the sidebar strip (visible blink
        // on every tab open/close).
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.syncPhanttomTitlebarZone()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        // Safety net for titlebar subviews AppKit replaces asynchronously
        // (e.g. tab bar teardown going 2 → 1 tabs); idempotent and cheap.
        DispatchQueue.main.async { [weak self] in
            self?.syncPhanttomTitlebarZone()
        }
    }

    /// Phanttom: sidebar glass = real window transparency plus a real blur
    /// radius. The terminal surface paints its own background, so the
    /// transparency only shows through the sidebar's translucent pixels.
    /// Called at the end of syncAppearance so upstream's opacity handling
    /// runs first (and naturally restores the opaque state when glass is
    /// off or the sidebar is absent).
    ///
    /// Respects the same exclusions as upstream's transparency branch: no
    /// transparency in native fullscreen or when the user forced an opaque
    /// background.
    ///
    /// Blur radius ownership: when the terminal itself is transparent,
    /// upstream just applied the user's configured blur and we never touch
    /// it. In every other case the radius is ours in BOTH directions — set
    /// while glass is in effect, zeroed otherwise — so no other path needs
    /// to undo it.
    func syncPhanttomSidebarGlass(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // Upstream sets the window blur only for real transparency; its
        // glass styles provide the material themselves (see syncAppearance).
        let upstreamOwnsBlur = surfaceConfig.backgroundOpacity < 1
            && !surfaceConfig.backgroundBlur.isGlassStyle
        guard !upstreamOwnsBlur else { return }

        let settings = PhanttomSettings.shared

        // Mirror upstream's exclusions (see syncAppearance): transparency in
        // native fullscreen turns the background gray and shows widgets, and
        // toggle-background-opacity must win over glass.
        let glassActive = sidebarActive
            && settings.sidebarGlass
            && !styleMask.contains(.fullScreen)
            && !(terminalController?.isBackgroundOpaque ?? false)

        if glassActive, isOpaque {
            isOpaque = false
            // Matches upstream's transparency branch (not .clear on purpose).
            backgroundColor = .white.withAlphaComponent(0.001)
        }

        // Zero when glass is off (upstream already restored the opaque
        // window) and when a terminal glass style supplies the material —
        // a CGS radius must not stack on top of it.
        let radius: Int32 = glassActive && !surfaceConfig.backgroundBlur.isGlassStyle
            ? Int32((settings.sidebarBlurAmount * 40).rounded())
            : 0
        CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(), windowNumber, radius)
    }

    /// Re-apply appearance when glass settings change at runtime. Upstream's
    /// syncAppearance restores the opaque window when glass turned off, and
    /// its trailing syncPhanttomSidebarGlass call settles the blur radius in
    /// both directions.
    func phanttomGlassSettingsChanged() {
        guard sidebarActive else { return }
        guard let surface = terminalController?.focusedSurface else {
            // No surface to drive syncAppearance. If glass just turned off,
            // restore an opaque window ourselves so it can't stay stuck
            // transparent; the next real syncAppearance corrects any drift.
            if !PhanttomSettings.shared.sidebarGlass, !isOpaque {
                isOpaque = true
                backgroundColor = (preferredBackgroundColor ?? backgroundColor)
                    .withAlphaComponent(1)
                CGSSetWindowBackgroundBlurRadius(
                    CGSDefaultConnectionForThread(), windowNumber, 0)
            }
            return
        }
        syncAppearance(surface.derivedConfig)
    }
}
