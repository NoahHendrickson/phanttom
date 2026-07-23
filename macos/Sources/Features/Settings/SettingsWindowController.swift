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
        window.contentView = NSHostingView(rootView: PhanttomSettingsView())
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var didCenter = false

    func show(ghostty: Ghostty.App) {
        guard let window else { return }

        PhanttomSettings.shared.ghosttyApp = ghostty

        if !didCenter {
            didCenter = true
            // Size to the SwiftUI content before centering so we don't
            // center a zero-size frame.
            if let fitting = window.contentView?.fittingSize, fitting != .zero {
                window.setContentSize(fitting)
            }
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
