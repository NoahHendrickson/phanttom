import AppKit
import SwiftUI

/// Hosts the Phanttom settings window. One shared instance; the window is
/// created lazily and survives close (hidden, not released).
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Phanttom Settings"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(ghostty: Ghostty.App) {
        guard let window else { return }

        PhanttomSettings.shared.ghosttyApp = ghostty

        if window.contentView == nil || !(window.contentView is NSHostingView<SettingsView>) {
            window.contentView = NSHostingView(rootView: SettingsView(ghostty: ghostty))
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
