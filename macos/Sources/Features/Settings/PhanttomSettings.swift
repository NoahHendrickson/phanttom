import SwiftUI
import GhosttyKit

/// Phanttom's user-adjustable appearance settings.
///
/// Terminal-rendering settings (background color/opacity/blur) are applied by
/// writing a managed config fragment (`phanttom.conf`, next to the user's main
/// Ghostty config) and asking libghostty to reload — the same pipeline as
/// hand-edited config, so everything live-reloads and stays overridable. The
/// user's own config file is touched exactly once, to add an optional include
/// of the fragment.
///
/// Sidebar settings never touch libghostty (the sidebar is pure Swift); they
/// persist in UserDefaults and apply instantly through SwiftUI.
@MainActor
final class PhanttomSettings: ObservableObject {
    static let shared = PhanttomSettings()

    /// Set when the settings window opens; used to trigger config reloads.
    weak var ghosttyApp: Ghostty.App?

    // MARK: - Terminal background (applied via config fragment)

    @Published var overrideBackground: Bool {
        didSet { persist(); scheduleApply() }
    }

    @Published var backgroundColor: Color {
        didSet { persist(); scheduleApply() }
    }

    /// 0.1 ... 1.0
    @Published var backgroundOpacity: Double {
        didSet { persist(); scheduleApply() }
    }

    /// Blur radius, 0 = off.
    @Published var backgroundBlur: Double {
        didSet { persist(); scheduleApply() }
    }

    // MARK: - Font (applied via config fragment)

    @Published var overrideFontSize: Bool {
        didSet { persist(); scheduleApply() }
    }

    /// Font size in points. Ghostty's default is 13.
    @Published var fontSize: Double {
        didSet { persist(); scheduleApply() }
    }

    // MARK: - Sidebar (applied instantly, app-side only)

    enum SidebarStyle: String, CaseIterable, Identifiable {
        case matchTerminal
        case system
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .matchTerminal: return "Match Terminal"
            case .system: return "System"
            case .custom: return "Custom"
            }
        }
    }

    @Published var sidebarStyle: SidebarStyle {
        didSet { persist() }
    }

    @Published var sidebarColor: Color {
        didSet { persist() }
    }

    /// 0.1 ... 1.0 — how solid the sidebar's color layer is.
    @Published var sidebarOpacity: Double {
        didSet { persist() }
    }

    /// Behind-window glass material under the color layer (Finder-sidebar
    /// style blur, independent of the terminal's window-level blur).
    @Published var sidebarGlass: Bool {
        didSet { persist() }
    }

    /// 0.1 ... 1.0 — how strong the glass material reads. AppKit's material
    /// blur radius isn't publicly tunable, so this blends the frosted layer's
    /// visibility instead, which is what "less blurry" looks like.
    @Published var sidebarBlurAmount: Double {
        didSet { persist() }
    }

    /// Sidebar row title size in points; secondary text and icons scale from
    /// it. The design's baseline is 11.
    @Published var sidebarFontSize: Double {
        didSet { persist() }
    }

    /// Group sidebar tabs under a header per project (git repository, with
    /// worktrees folded into their parent repo). Headers only appear once
    /// tabs span more than one project.
    @Published var sidebarGroupByProject: Bool {
        didSet { persist() }
    }

    /// Color of the "working" (thinking) pixel-rain indicator.
    static let defaultWorkingColor = Color.white

    @Published var sidebarWorkingColor: Color {
        didSet { persist() }
    }

    /// The sidebar's base color per style, resolved to AppKit so both the
    /// SwiftUI sidebar and the window chrome (titlebar zone) derive from the
    /// same logic. `terminalBackground` feeds the `.matchTerminal` style.
    func resolvedSidebarColor(terminalBackground: OSColor?) -> OSColor {
        switch sidebarStyle {
        case .system:
            return .windowBackgroundColor
        case .custom:
            return OSColor(sidebarColor)
        case .matchTerminal:
            let base = terminalBackground ?? .windowBackgroundColor
            return base.isLightColor ? base.darken(by: 0.06) : base.darken(by: 0.25)
        }
    }

    // MARK: - Persistence

    private enum Keys {
        static let overrideBackground = "PhanttomOverrideBackground"
        static let backgroundColor = "PhanttomBackgroundColor"
        static let backgroundOpacity = "PhanttomBackgroundOpacity"
        static let backgroundBlur = "PhanttomBackgroundBlur"
        static let overrideFontSize = "PhanttomOverrideFontSize"
        static let fontSize = "PhanttomFontSize"
        static let sidebarStyle = "PhanttomSidebarStyle"
        static let sidebarColor = "PhanttomSidebarColor"
        static let sidebarOpacity = "PhanttomSidebarOpacity"
        static let sidebarGlass = "PhanttomSidebarGlass"
        static let sidebarBlurAmount = "PhanttomSidebarBlurAmount"
        static let sidebarFontSize = "PhanttomSidebarFontSize"
        static let sidebarGroupByProject = "PhanttomSidebarGroupByProject"
        static let sidebarWorkingColor = "PhanttomSidebarWorkingColor"
    }

    private var loaded = false

    private init() {
        let defaults = UserDefaults.standard
        overrideBackground = defaults.bool(forKey: Keys.overrideBackground)
        backgroundColor = Self.color(fromHex: defaults.string(forKey: Keys.backgroundColor)) ?? Color(red: 0.11, green: 0.11, blue: 0.13)
        backgroundOpacity = defaults.object(forKey: Keys.backgroundOpacity) as? Double ?? 1.0
        backgroundBlur = defaults.object(forKey: Keys.backgroundBlur) as? Double ?? 0
        overrideFontSize = defaults.bool(forKey: Keys.overrideFontSize)
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 13
        sidebarStyle = SidebarStyle(rawValue: defaults.string(forKey: Keys.sidebarStyle) ?? "") ?? .matchTerminal
        sidebarColor = Self.color(fromHex: defaults.string(forKey: Keys.sidebarColor)) ?? Color(red: 0.09, green: 0.09, blue: 0.11)
        sidebarOpacity = defaults.object(forKey: Keys.sidebarOpacity) as? Double ?? 1.0
        sidebarGlass = defaults.bool(forKey: Keys.sidebarGlass)
        sidebarBlurAmount = defaults.object(forKey: Keys.sidebarBlurAmount) as? Double ?? 1.0
        sidebarFontSize = defaults.object(forKey: Keys.sidebarFontSize) as? Double ?? 11
        sidebarGroupByProject = defaults.object(forKey: Keys.sidebarGroupByProject) as? Bool ?? true
        sidebarWorkingColor = Self.color(fromHex: defaults.string(forKey: Keys.sidebarWorkingColor)) ?? Self.defaultWorkingColor
        loaded = true
    }

    private func persist() {
        guard loaded else { return }
        let defaults = UserDefaults.standard
        defaults.set(overrideBackground, forKey: Keys.overrideBackground)
        defaults.set(Self.hex(from: backgroundColor), forKey: Keys.backgroundColor)
        defaults.set(backgroundOpacity, forKey: Keys.backgroundOpacity)
        defaults.set(backgroundBlur, forKey: Keys.backgroundBlur)
        defaults.set(overrideFontSize, forKey: Keys.overrideFontSize)
        defaults.set(fontSize, forKey: Keys.fontSize)
        defaults.set(sidebarStyle.rawValue, forKey: Keys.sidebarStyle)
        defaults.set(Self.hex(from: sidebarColor), forKey: Keys.sidebarColor)
        defaults.set(sidebarOpacity, forKey: Keys.sidebarOpacity)
        defaults.set(sidebarGlass, forKey: Keys.sidebarGlass)
        defaults.set(sidebarBlurAmount, forKey: Keys.sidebarBlurAmount)
        defaults.set(sidebarFontSize, forKey: Keys.sidebarFontSize)
        defaults.set(sidebarGroupByProject, forKey: Keys.sidebarGroupByProject)
        defaults.set(Self.hex(from: sidebarWorkingColor), forKey: Keys.sidebarWorkingColor)
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
            "# Managed by Phanttom Settings — do not edit; changes are overwritten.",
            "# Remove the `config-file = ?phanttom.conf` line from your config to disable.",
        ]
        if overrideBackground {
            lines.append("background = \(Self.hex(from: backgroundColor))")
            lines.append("background-opacity = \(String(format: "%.2f", backgroundOpacity))")
            lines.append("background-blur = \(Int(backgroundBlur))")
        }
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
