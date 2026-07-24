import AppKit
import SwiftUI
import GhosttyKit

/// Phanttom's user-adjustable settings plus locked chrome tokens.
///
/// Terminal background is opinionated (Figma `#101211`): written into a
/// managed config fragment (`phanttom.conf`) after a one-time notice on
/// first launch, then reloaded via libghostty. Font-size override and
/// quit→reopen window restore remain optional. Sidebar grouping is the
/// only sidebar preference — appearance is hardcoded from `Chrome` below.
@MainActor
final class PhanttomSettings: ObservableObject {
    static let shared = PhanttomSettings()

    /// Single source for locked Figma chrome — sRGB components in 0…1.
    /// Every `Color` / `NSColor` / `phanttom.conf` hex derives from here.
    enum Chrome {
        struct RGB: Equatable {
            let r: Double
            let g: Double
            let b: Double

            var color: Color { Color(red: r, green: g, blue: b) }

            var nsColor: NSColor {
                NSColor(red: r, green: g, blue: b, alpha: 1)
            }

            /// Lowercase `#rrggbb` for Ghostty config fragments.
            var hex: String {
                String(
                    format: "#%02x%02x%02x",
                    Int(round(r * 255)),
                    Int(round(g * 255)),
                    Int(round(b * 255)))
            }

            static func byte(_ r: Int, _ g: Int, _ b: Int) -> RGB {
                RGB(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255)
            }
        }

        static let sidebar = RGB.byte(0x16, 0x19, 0x17)
        static let terminal = RGB.byte(0x10, 0x12, 0x11)
        static let divider = RGB.byte(0x2D, 0x2E, 0x2E)
        static let working = RGB.byte(0x24, 0xFE, 0x8A)
        static let done = RGB.byte(0x3A, 0x89, 0xD8)
        static let attention = RGB.byte(0xF5, 0xCC, 0x64)
    }

    static var sidebarBackground: Color { Chrome.sidebar.color }
    static var sidebarBackgroundNS: NSColor { Chrome.sidebar.nsColor }
    static var terminalBackgroundNS: NSColor { Chrome.terminal.nsColor }
    static var dividerColorNS: NSColor { Chrome.divider.nsColor }
    static var workingIndicatorColor: Color { Chrome.working.color }
    static var doneStatusColor: Color { Chrome.done.color }
    static var attentionStatusColor: Color { Chrome.attention.color }

    /// Set when the app (or settings window) is ready; used to trigger config reloads.
    weak var ghosttyApp: Ghostty.App?

    // MARK: - Font (applied via config fragment)

    @Published var overrideFontSize: Bool {
        didSet { persist(); scheduleApply() }
    }

    /// Font size in points. Ghostty's default is 13.
    @Published var fontSize: Double {
        didSet { persist(); scheduleApply() }
    }

    // MARK: - Sidebar (behavioral only)

    /// Group sidebar tabs under a header per project (git repo toplevel,
    /// with worktrees folded into their parent repo; non-git tabs group by
    /// pwd). Headers render whenever grouping is on and at least one tab
    /// has a known directory — including a single-project list, since the
    /// header carries the collapse control and the per-project "+". Also
    /// switchable from the titlebar grouping menu. The partition itself
    /// lives in `SidebarTabGroup`.
    @Published var sidebarGroupByProject: Bool {
        didSet { persist() }
    }

    // MARK: - Session restore (via config fragment)

    /// When on, writes `window-save-state = always` into `phanttom.conf` so
    /// intentional quit (Cmd-Q) keeps window layout for the next launch.
    /// Off (default) omits the key so Ghostty's `default` applies — crash /
    /// force-quit still restore; normal quit usually does not. Opt-in only;
    /// does not change the fork's shipped Ghostty default.
    @Published var restoreWindowsOnQuit: Bool {
        didSet { persist(); scheduleApply() }
    }

    // MARK: - Persistence

    private enum Keys {
        static let overrideFontSize = "PhanttomOverrideFontSize"
        static let fontSize = "PhanttomFontSize"
        static let sidebarGroupByProject = "PhanttomSidebarGroupByProject"
        static let restoreWindowsOnQuit = "PhanttomRestoreWindowsOnQuit"
        /// One-time notice before the first locked-chrome write.
        static let lockedChromeNoticeShown = "PhanttomLockedChromeNoticeShown"
    }

    private var loaded = false

    private init() {
        let defaults = UserDefaults.standard
        overrideFontSize = defaults.bool(forKey: Keys.overrideFontSize)
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 13
        sidebarGroupByProject = defaults.object(forKey: Keys.sidebarGroupByProject) as? Bool ?? true
        restoreWindowsOnQuit = defaults.bool(forKey: Keys.restoreWindowsOnQuit)
        loaded = true
    }

    /// Wire the Ghostty app. First launch shows a notice before writing the
    /// locked chrome fragment; later launches apply silently.
    func setupOnLaunch(ghostty: Ghostty.App) {
        ghosttyApp = ghostty
        // Ghostty.app is the XCTest host — never mutate the user's config
        // or pop a notice during tests.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        if UserDefaults.standard.bool(forKey: Keys.lockedChromeNoticeShown) {
            apply()
            return
        }
        // After the first window is up so the alert isn't buried.
        DispatchQueue.main.async { [weak self] in
            self?.presentLockedChromeNoticeThenApply()
        }
    }

    private func presentLockedChromeNoticeThenApply() {
        // Re-check: another window's launch path may have already shown it.
        guard !UserDefaults.standard.bool(forKey: Keys.lockedChromeNoticeShown) else {
            apply()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Phanttom locks the terminal background"
        alert.informativeText =
            "Phanttom sets the terminal background to \(Chrome.terminal.hex) "
            + "to match its sidebar chrome, via a managed phanttom.conf "
            + "include in your Ghostty config.\n\n"
            + "Your own config only gets a one-line include. Remove "
            + "`config-file = ?phanttom.conf` anytime to opt out."
        alert.addButton(withTitle: "Continue")
        _ = alert.runModal()
        UserDefaults.standard.set(true, forKey: Keys.lockedChromeNoticeShown)
        apply()
    }

    private func persist() {
        guard loaded else { return }
        let defaults = UserDefaults.standard
        defaults.set(overrideFontSize, forKey: Keys.overrideFontSize)
        defaults.set(fontSize, forKey: Keys.fontSize)
        defaults.set(sidebarGroupByProject, forKey: Keys.sidebarGroupByProject)
        defaults.set(restoreWindowsOnQuit, forKey: Keys.restoreWindowsOnQuit)
    }

    // MARK: - Applying terminal settings

    private var applyWork: DispatchWorkItem?

    /// Debounced so slider drags don't hammer config reloads.
    private func scheduleApply() {
        guard loaded else { return }
        applyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply() }
        applyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func apply() {
        // ghostty_config_open_path returns an empty string on failure; bail
        // rather than resolving config paths relative to the process cwd.
        // Snapshot once so every step below operates on the exact path the
        // guard validated — the getter re-invokes the C call each access.
        let mainConfigPath = self.mainConfigPath
        guard !mainConfigPath.isEmpty else {
            Ghostty.logger.warning("phanttom settings: no config path available; not applying")
            return
        }
        do {
            try writeFragment(mainConfigPath: mainConfigPath)
            try ensureIncluded(mainConfigPath: mainConfigPath)
        } catch {
            Ghostty.logger.warning("phanttom settings: failed to write config fragment: \(error)")
            return
        }
        ghosttyApp?.reloadConfig()
    }

    private var mainConfigPath: String {
        Ghostty.AllocatedString(ghostty_config_open_path()).string
    }

    private func writeFragment(mainConfigPath: String) throws {
        let configDirectory = URL(fileURLWithPath: mainConfigPath)
            .deletingLastPathComponent()
        var lines = [
            "# Managed by Phanttom — do not edit; changes are overwritten.",
            "# Remove the `config-file = ?phanttom.conf` line from your config to disable.",
            "background = \(Chrome.terminal.hex)",
            "background-opacity = 1",
            "background-blur = 0",
        ]
        if overrideFontSize {
            lines.append("font-size = \(String(format: "%g", fontSize))")
        }
        // Omit the key when off so a user's own window-save-state in the
        // main config is not overridden by phanttom.conf.
        if restoreWindowsOnQuit {
            lines.append("window-save-state = always")
        }
        try FileManager.default.createDirectory(
            at: configDirectory, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(
                to: configDirectory.appendingPathComponent("phanttom.conf"),
                atomically: true,
                encoding: .utf8)
    }

    /// Ensure the user's main config includes our fragment (optional include,
    /// so a missing fragment is never an error). Appends exactly once.
    ///
    /// Failure-safe: an existing-but-unreadable config aborts (a read error
    /// must never be mistaken for an empty file), and the include is appended
    /// through a file handle so a symlinked config (dotfiles setups) keeps
    /// its inode instead of being replaced by an atomic-write copy.
    ///
    /// The read-then-append dedup check races a concurrent external writer
    /// (no file locking); accepted, since the worst case is a duplicate
    /// include that Ghostty flags as a cycle diagnostic rather than breaking.
    private func ensureIncluded(mainConfigPath: String) throws {
        let mainURL = URL(fileURLWithPath: mainConfigPath).resolvingSymlinksInPath()
        let exists = FileManager.default.fileExists(atPath: mainURL.path)

        var existing = ""
        if exists {
            existing = try String(contentsOf: mainURL, encoding: .utf8)
        }
        guard !existing.contains("phanttom.conf") else { return }

        let separator = existing.isEmpty || existing.hasSuffix("\n")
            ? "" : "\n"
        let addition = separator
            + "\n# Phanttom: managed settings overrides (safe to remove)\n"
            + "config-file = ?phanttom.conf\n"

        if exists {
            let handle = try FileHandle(forWritingTo: mainURL)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(addition.utf8))
            } catch {
                try? handle.close()
                throw error
            }
            // Close explicitly and let it throw: some filesystems only
            // surface a delayed write-back failure at close(), and swallowing
            // it would reload config as if the append had succeeded.
            try handle.close()
        } else {
            try addition.write(to: mainURL, atomically: true, encoding: .utf8)
        }
    }
}
