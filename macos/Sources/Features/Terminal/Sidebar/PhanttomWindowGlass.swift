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
    /// Phanttom: sidebar glass = real window transparency plus a real blur
    /// radius. The terminal surface paints its own background, so the
    /// transparency only shows through the sidebar's translucent pixels.
    /// Called at the end of syncAppearance so upstream's opacity handling
    /// runs first (and naturally restores the opaque state when glass is
    /// off or the sidebar is absent).
    func syncPhanttomSidebarGlass() {
        guard sidebarActive else { return }
        let settings = PhanttomSettings.shared
        guard settings.sidebarGlass else { return }

        if isOpaque {
            isOpaque = false
            // Matches upstream's transparency branch (not .clear on purpose).
            backgroundColor = .white.withAlphaComponent(0.001)
        }

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
            syncPhanttomSidebarGlass()
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
