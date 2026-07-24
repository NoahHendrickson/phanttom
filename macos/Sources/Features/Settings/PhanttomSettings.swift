import SwiftUI
import GhosttyKit

/// Phanttom's user-adjustable settings plus locked chrome tokens.
///
/// Terminal background is opinionated (Figma `#101211`): always written into
/// a managed config fragment (`phanttom.conf`) and reloaded via libghostty.
/// Font-size override remains optional. Sidebar grouping is the only
/// sidebar preference — appearance is hardcoded in the views.
@MainActor
final class PhanttomSettings: ObservableObject {
    static let shared = PhanttomSettings()

    /// Figma chrome — sidebar left pane / terminal right pane / divider.
    static let sidebarBackground = Color(red: 0x16 / 255, green: 0x19 / 255, blue: 0x17 / 255)
    static let terminalBackground = Color(red: 0x10 / 255, green: 0x12 / 255, blue: 0x11 / 255)
    static let dividerColor = Color(red: 0x2D / 255, green: 0x2E / 255, blue: 0x2E / 255)
    static let workingIndicatorColor = Color(red: 0x24 / 255, green: 0xFE / 255, blue: 0x8A / 255)

    static var sidebarBackgroundNS: NSColor {
        NSColor(red: 0x16 / 255, green: 0x19 / 255, blue: 0x17 / 255, alpha: 1)
    }

    static var terminalBackgroundNS: NSColor {
        NSColor(red: 0x10 / 255, green: 0x12 / 255, blue: 0x11 / 255, alpha: 1)
    }

    static var dividerColorNS: NSColor {
        NSColor(red: 0x2D / 255, green: 0x2E / 255, blue: 0x2E / 255, alpha: 1)
    }

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

    // MARK: - Persistence

    private enum Keys {
        static let overrideFontSize = "PhanttomOverrideFontSize"
        static let fontSize = "PhanttomFontSize"
        static let sidebarGroupByProject = "PhanttomSidebarGroupByProject"
    }

    private var loaded = false

    private init() {
        let defaults = UserDefaults.standard
        overrideFontSize = defaults.bool(forKey: Keys.overrideFontSize)
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 13
        sidebarGroupByProject = defaults.object(forKey: Keys.sidebarGroupByProject) as? Bool ?? true
        loaded = true
    }

    /// Wire the Ghostty app and write the locked chrome fragment on launch.
    func setupOnLaunch(ghostty: Ghostty.App) {
        ghosttyApp = ghostty
        apply()
    }

    private func persist() {
        guard loaded else { return }
        let defaults = UserDefaults.standard
        defaults.set(overrideFontSize, forKey: Keys.overrideFontSize)
        defaults.set(fontSize, forKey: Keys.fontSize)
        defaults.set(sidebarGroupByProject, forKey: Keys.sidebarGroupByProject)
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
            "background = #101211",
            "background-opacity = 1",
            "background-blur = 0",
        ]
        if overrideFontSize {
            lines.append("font-size = \(String(format: "%g", fontSize))")
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

    // MARK: - Hex helpers

    static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return String(
            format: "#%02x%02x%02x",
            Int(round(ns.redComponent * 255)),
            Int(round(ns.greenComponent * 255)),
            Int(round(ns.blueComponent * 255))
        )
    }

    static func color(fromHex hex: String?) -> Color? {
        guard var hex else { return nil }
        hex = hex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
