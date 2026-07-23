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

        // Repaint the titlebar strip above the sidebar. Deferred a turn
        // because subclass syncAppearance overrides run after the base and
        // may recreate titlebar subviews.
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
    /// background. And when the terminal itself is transparent, the
    /// terminal's configured blur owns the window — we never overwrite it.
    func syncPhanttomSidebarGlass(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        guard sidebarActive else { return }
        let settings = PhanttomSettings.shared
        guard settings.sidebarGlass else { return }

        // Mirror upstream's exclusions (see syncAppearance): transparency in
        // native fullscreen turns the background gray and shows widgets, and
        // toggle-background-opacity must win over glass.
        let forceOpaque = terminalController?.isBackgroundOpaque ?? false
        guard !styleMask.contains(.fullScreen), !forceOpaque else { return }

        if isOpaque {
            isOpaque = false
            // Matches upstream's transparency branch (not .clear on purpose).
            backgroundColor = .white.withAlphaComponent(0.001)
        }

        // If the terminal is transparent (or using a glass style), upstream
        // just applied the user's configured blur — leave it alone.
        let terminalOwnsBlur = surfaceConfig.backgroundOpacity < 1
            || surfaceConfig.backgroundBlur.isGlassStyle
        guard !terminalOwnsBlur else { return }

        CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            windowNumber,
            Int32((settings.sidebarBlurAmount * 40).rounded())
        )
    }

    /// Re-apply appearance when glass settings change at runtime. Upstream's
    /// syncAppearance restores the opaque window when glass turned off, then
    /// re-enters syncPhanttomSidebarGlass when it's on.
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

        // Glass off: zero our radius unless the terminal's own transparency
        // owns the window blur.
        if !PhanttomSettings.shared.sidebarGlass,
           surface.derivedConfig.backgroundOpacity >= 1 {
            CGSSetWindowBackgroundBlurRadius(
                CGSDefaultConnectionForThread(), windowNumber, 0)
        }
    }
}
