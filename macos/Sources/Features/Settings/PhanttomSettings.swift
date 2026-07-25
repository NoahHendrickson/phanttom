import AppKit
import SwiftUI
import GhosttyKit

/// Phanttom's user-adjustable settings plus locked chrome tokens.
///
/// Terminal background is opinionated (Figma `#101211`): written into a
/// managed config fragment (`phanttom.conf`) on launch, then reloaded via
/// libghostty. Font-size override and quit→reopen window restore remain
/// optional. Sidebar grouping is the only sidebar preference — appearance
/// is hardcoded from `Chrome` below.
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

    /// Show each idle tab's branch as a GitHub PR dot (open / merged).
    ///
    /// On by default — it is one of the reasons to run this fork — but it is
    /// the only thing in Phanttom that talks to the network, so it must be
    /// switchable and it must say so: resolving it shells out to the `gh` CLI
    /// with the user's GitHub credentials, from the tab's own working
    /// directory, and revalidates every 60s per (directory, branch). The
    /// query is narrowed to rows that actually render the icon (`.idle`) and
    /// to repositories with a github.com remote, so it is not made from
    /// arbitrary directories, and the Settings footer states plainly what it
    /// does.
    @Published var showPullRequestStatus: Bool {
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
        static let showPullRequestStatus = "PhanttomShowPullRequestStatus"
        static let restoreWindowsOnQuit = "PhanttomRestoreWindowsOnQuit"
        /// Explicit lifecycle of the managed `config-file = ?phanttom.conf`
        /// include, persisted as an `IncludeState` raw value. Replaces the
        /// earlier inference from the notice flag plus include-absence, which
        /// could misread a never-installed setup (e.g. an older build that
        /// burned the notice before a failed apply) as a deliberate opt-out.
        static let includeState = "PhanttomIncludeState"
    }

    /// Lifecycle of the managed include line.
    /// - `unset`: never successfully added — the next apply adds it.
    /// - `installed`: added and observed present; if it later goes missing the
    ///   user removed it, so we transition to `optedOut`.
    /// - `optedOut`: the user deleted the include — the documented escape
    ///   hatch, honored permanently (never re-added).
    private enum IncludeState: String {
        case unset, installed, optedOut
    }

    private var includeState: IncludeState {
        get {
            IncludeState(
                rawValue: UserDefaults.standard.string(forKey: Keys.includeState) ?? ""
            ) ?? .unset
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.includeState) }
    }

    private var loaded = false

    private init() {
        let defaults = UserDefaults.standard
        overrideFontSize = defaults.bool(forKey: Keys.overrideFontSize)
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 13
        sidebarGroupByProject = defaults.object(forKey: Keys.sidebarGroupByProject) as? Bool ?? true
        showPullRequestStatus =
            defaults.object(forKey: Keys.showPullRequestStatus) as? Bool ?? true
        restoreWindowsOnQuit = defaults.bool(forKey: Keys.restoreWindowsOnQuit)
        loaded = true
    }

    /// Wire the Ghostty app and apply the locked chrome fragment silently.
    func setupOnLaunch(ghostty: Ghostty.App) {
        ghosttyApp = ghostty
        // Ghostty.app is the XCTest host — never mutate the user's config
        // during tests.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        apply()
    }

    private func persist() {
        guard loaded else { return }
        let defaults = UserDefaults.standard
        defaults.set(overrideFontSize, forKey: Keys.overrideFontSize)
        defaults.set(fontSize, forKey: Keys.fontSize)
        defaults.set(sidebarGroupByProject, forKey: Keys.sidebarGroupByProject)
        defaults.set(showPullRequestStatus, forKey: Keys.showPullRequestStatus)
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

    /// Write the managed fragment and ensure the include, then reload config
    /// if anything actually changed. Returns `true` when the config is in its
    /// desired state (whether or not a write was needed) and `false` when the
    /// attempt failed (no config path, or a write threw) — callers gate the
    /// one-time notice flag on this so a failed apply is retried next launch.
    @discardableResult
    func apply() -> Bool {
        // ghostty_config_open_path returns an empty string on failure; bail
        // rather than resolving config paths relative to the process cwd.
        // Snapshot once so every step below operates on the exact path the
        // guard validated — the getter re-invokes the C call each access.
        let mainConfigPath = self.mainConfigPath
        guard !mainConfigPath.isEmpty else {
            Ghostty.logger.warning("phanttom settings: no config path available; not applying")
            return false
        }
        let changed: Bool
        do {
            // Evaluate both writers (don't short-circuit): the fragment and the
            // include are independent, and either changing warrants a reload.
            let fragmentChanged = try writeFragment(mainConfigPath: mainConfigPath)
            let includeChanged = try ensureIncluded(mainConfigPath: mainConfigPath)
            changed = fragmentChanged || includeChanged
        } catch {
            Ghostty.logger.warning("phanttom settings: failed to write config fragment: \(error)")
            return false
        }
        // Skip the reload when nothing changed — the silent apply runs every
        // launch and would otherwise reload config on identical content.
        if changed {
            ghosttyApp?.reloadConfig()
        }
        return true
    }

    private var mainConfigPath: String {
        Ghostty.AllocatedString(ghostty_config_open_path()).string
    }

    /// Write the managed `phanttom.conf`. Returns `true` if the file was
    /// (re)written and `false` if it was already byte-identical to the
    /// intended content and left untouched.
    private func writeFragment(mainConfigPath: String) throws -> Bool {
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
        let contents = lines.joined(separator: "\n") + "\n"
        let fragmentURL = configDirectory.appendingPathComponent("phanttom.conf")

        // Content-diff before writing: the silent apply runs every launch, so
        // skip the atomic write (and report "no change") when the on-disk
        // fragment already matches the intended bytes exactly.
        if let existing = try? String(contentsOf: fragmentURL, encoding: .utf8),
            existing == contents {
            return false
        }

        try FileManager.default.createDirectory(
            at: configDirectory, withIntermediateDirectories: true)
        try contents.write(to: fragmentURL, atomically: true, encoding: .utf8)
        return true
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
    /// Returns `true` if the include line was appended this call, `false`
    /// otherwise (already present, opted out, or intentionally not re-added).
    private func ensureIncluded(mainConfigPath: String) throws -> Bool {
        // Opted out: the user deleted the include (the documented escape
        // hatch). Never read or touch their config for this again — this is
        // what makes opt-out stick across launches and font-size changes.
        if includeState == .optedOut { return false }

        let mainURL = URL(fileURLWithPath: mainConfigPath).resolvingSymlinksInPath()
        let exists = FileManager.default.fileExists(atPath: mainURL.path)

        var existing = ""
        if exists {
            existing = try String(contentsOf: mainURL, encoding: .utf8)
        }

        // Only an *active* (uncommented) include directive counts as "already
        // present". A commented-out or otherwise textual mention of
        // phanttom.conf must not be mistaken for a live include (which would
        // wrongly suppress a real one), so parse line-by-line and ignore
        // comment lines rather than doing a blanket substring match.
        let present = hasActiveInclude(existing)

        if includeState == .installed {
            // We added the include before and observed it present. If it's
            // still there, nothing to do; if it's gone the user removed it, so
            // record the durable opt-out and never re-add.
            if !present { includeState = .optedOut }
            return false
        }

        // includeState == .unset: never successfully installed. If the include
        // is already present (added out-of-band, or a config carried over from
        // an older build), adopt it as installed without rewriting. Otherwise
        // append it now. Because the default is `unset`, a stale setup that
        // never actually wrote the include is treated as a first-ever install
        // rather than a phantom opt-out.
        if present {
            includeState = .installed
            return false
        }

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
        includeState = .installed
        return true
    }

    /// True when `contents` has a live (uncommented) include of our fragment.
    /// Lines whose first non-whitespace character is `#` are comments and are
    /// ignored, so a commented-out reference never blocks a real include.
    private func hasActiveInclude(_ contents: String) -> Bool {
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.contains("phanttom.conf") { return true }
        }
        return false
    }
}
