import AppKit

extension TerminalWindow {
    /// Phanttom's single hook at the end of upstream's syncAppearance —
    /// keeps the upstream edit to one line so merges stay cheap, and keeps
    /// the titlebar zone deferred past subclass repaints in fork-owned code.
    func phanttomSyncAppearanceDidRun(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
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
}
