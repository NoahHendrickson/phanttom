import AppKit
import GhosttyKit

/// Installs and maintains Phanttom's Claude Code hooks in the user's
/// `~/.claude/settings.json`, so agent tabs get pixel rain, first-prompt
/// naming, and agent-cwd (worktree) tracking without any manual setup.
///
/// Consent model: first launch shows a one-time dialog. Once enabled, the
/// hooks are re-synced on every launch, so protocol fixes ship with app
/// updates (e.g. the /dev/tty → CLAUDE_PID tty resolution). Declining, or
/// turning the Phanttom Settings toggle off, removes only Phanttom's own
/// entries and never asks again.
///
/// Ownership: an installed hook is recognized as Phanttom's by its
/// escape-sequence payload (OSC 9;4 progress, the ❯+U+2063 title marker, or
/// the OSC 7 `file://localhost` cwd report) — the signatures documented in
/// PHANTTOM.md. Legacy variants match too and are replaced by the current
/// commands. Everything else in the file is preserved, though a rewrite
/// normalizes JSON formatting and key order (JSONSerialization).
///
/// Safety: a settings file that exists but doesn't parse as a JSON object is
/// never touched. Before the first modifying write, the original is backed up
/// to `settings.json.bak-phanttom` (kept, never overwritten).
@MainActor
final class PhanttomClaudeIntegration: ObservableObject {
    static let shared = PhanttomClaudeIntegration()

    /// Mirrors the persisted consent state for the settings toggle. Flipping
    /// it installs or removes the hooks immediately.
    @Published var enabled: Bool {
        didSet {
            guard loaded, enabled != oldValue else { return }
            UserDefaults.standard.set(
                enabled ? State.enabled.rawValue : State.disabled.rawValue,
                forKey: Self.stateKey)
            if enabled { syncHooks() } else { removeHooks() }
        }
    }

    private enum State: String {
        case enabled
        case disabled
    }

    private static let stateKey = "PhanttomClaudeHooks"
    private var loaded = false

    private init() {
        enabled = UserDefaults.standard.string(forKey: Self.stateKey)
            == State.enabled.rawValue
        loaded = true
    }

    /// Called once from applicationDidFinishLaunching. First launch asks;
    /// afterwards an enabled integration re-syncs silently.
    func setupOnLaunch() {
        guard UserDefaults.standard.string(forKey: Self.stateKey) == nil else {
            if enabled { syncHooks() }
            return
        }
        // Let the first terminal window appear before asking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.presentConsent()
        }
    }

    private func presentConsent() {
        let alert = NSAlert()
        alert.messageText = "Enable Claude Code integration?"
        alert.informativeText =
            "Phanttom can show live Claude Code activity on its tabs: the "
            + "thinking animation, tab names from your first prompt, and "
            + "worktree-aware directory tracking.\n\n"
            + "This installs a few hooks into ~/.claude/settings.json (a "
            + "backup is kept, and only Phanttom's own entries are ever "
            + "touched). You can change this later in Phanttom Settings."
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        // Either answer resolves the ask-once state; the didSet persists it
        // and installs on consent. "Not Now" must persist explicitly since
        // `enabled` is already false and didSet won't fire.
        if response == .alertFirstButtonReturn {
            enabled = true
        } else {
            UserDefaults.standard.set(
                State.disabled.rawValue, forKey: Self.stateKey)
        }
    }

    // MARK: - The hooks (source of truth; PHANTTOM.md documents the protocol)

    /// Resolves the session's terminal device. Hooks can't just open
    /// /dev/tty: Claude Code (observed in 2.1.218) spawns hook processes
    /// without a controlling terminal, so that open fails silently. CLAUDE_PID
    /// (the claude process itself, exported to hooks) still has the tab's pty.
    private static let ttyResolve =
        #"t=$(ps -o tty= -p "${CLAUDE_PID:-0}" 2>/dev/null | tr -d " "); case "$t" in ""|"??") t=/dev/tty;; *) t=/dev/$t;; esac"#

    private static func hookCommand(_ body: String) -> String {
        "sh -c '\(ttyResolve); \(body); true'"
    }

    struct HookSpec {
        let event: String
        let matcher: String?
        let command: String
    }

    static let hookSpecs: [HookSpec] = {
        let rain = hookCommand(
            #"printf "\033]9;4;3;0\033\\\\" > "$t" 2>/dev/null"#)
        let clear = hookCommand(
            #"printf "\033]9;4;0;0\033\\\\" > "$t" 2>/dev/null"#)
        let bell = hookCommand(
            #"printf "\033]9;4;0;0\033\\\\\007" > "$t" 2>/dev/null"#)
        // Emits the marker title `❯⁣<prompt>⁣<model id>` (U+2063-separated)
        // that PhanttomTabState parses for first-prompt naming and the model
        // badge. The model id is the last assistant turn's in the session
        // transcript — empty on the first prompt, when no turn exists yet.
        let title =
            "sh -c '"
            + #"j=$(cat); "#
            + #"p=$(printf "%s" "$j" | jq -r ".prompt // empty" 2>/dev/null | tr "\n" " " | cut -c1-56); "#
            + #"m=$(tail -n 200 "$(printf "%s" "$j" | jq -r ".transcript_path // empty" 2>/dev/null)" 2>/dev/null | jq -rs "[.[]? | select(.type==\"assistant\") | .message.model // empty | select(startswith(\"<\") | not)] | last // empty" 2>/dev/null); "#
            + ttyResolve
            + #"; [ -n "$p" ] && printf "\033]2;\xe2\x9d\xaf\xe2\x81\xa3 %s\xe2\x81\xa3%s\007" "$p" "$m" > "$t" 2>/dev/null; true'"#
        let cwd =
            "sh -c '"
            + #"d=$(jq -r ".cwd // empty | @uri" 2>/dev/null | sed "s|%2F|/|g"); "#
            + ttyResolve
            + #"; [ -n "$d" ] && printf "\033]7;file://localhost%s\033\\\\" "$d" > "$t" 2>/dev/null; true'"#
        return [
            .init(event: "UserPromptSubmit", matcher: nil, command: rain),
            .init(event: "UserPromptSubmit", matcher: nil, command: title),
            .init(event: "UserPromptSubmit", matcher: nil, command: cwd),
            .init(event: "Stop", matcher: nil, command: clear),
            .init(event: "Notification", matcher: nil, command: bell),
            .init(event: "SessionStart", matcher: nil, command: cwd),
            .init(
                event: "PostToolUse", matcher: "EnterWorktree|ExitWorktree",
                command: cwd),
        ]
    }()

    /// A command containing any of these payloads is treated as Phanttom's,
    /// current or legacy. They're our emitted escape sequences, so a user's
    /// unrelated hook matching one is very unlikely (and documented).
    private static let ownershipSignatures = [
        "]9;4;3;0",
        "]9;4;0;0",
        #"\xe2\x9d\xaf\xe2\x81\xa3"#,
        "file://localhost",
    ]

    static func isPhanttomCommand(_ command: String) -> Bool {
        ownershipSignatures.contains { command.contains($0) }
    }

    // MARK: - Merge logic (pure, testable)

    /// Returns the settings dictionary with Phanttom's hooks installed:
    /// prior Phanttom entries (any version) removed, current ones appended.
    /// Returns nil when the input already matches, so callers can skip the
    /// write.
    static func merged(into root: [String: Any]) -> [String: Any]? {
        var result = strip(from: root, keepEmptyEvents: true)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for spec in hookSpecs {
            var entries = hooks[spec.event] as? [[String: Any]] ?? []
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": spec.command]]
            ]
            if let matcher = spec.matcher { entry["matcher"] = matcher }
            entries.append(entry)
            hooks[spec.event] = entries
        }
        result["hooks"] = hooks
        if NSDictionary(dictionary: result).isEqual(to: root) { return nil }
        return result
    }

    /// Returns the settings dictionary with every Phanttom-owned hook
    /// removed (entries left with no hooks are dropped; events left with no
    /// entries are dropped unless keepEmptyEvents). Non-Phanttom content is
    /// untouched.
    static func strip(
        from root: [String: Any], keepEmptyEvents: Bool = false
    ) -> [String: Any] {
        var result = root
        guard var hooks = root["hooks"] as? [String: Any] else { return result }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for entry in entries {
                guard let inner = entry["hooks"] as? [[String: Any]] else {
                    kept.append(entry)
                    continue
                }
                let remaining = inner.filter {
                    guard let command = $0["command"] as? String else {
                        return true
                    }
                    return !isPhanttomCommand(command)
                }
                if remaining.isEmpty && !inner.isEmpty { continue }
                var updated = entry
                updated["hooks"] = remaining
                kept.append(updated)
            }
            if kept.isEmpty && !keepEmptyEvents {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        result["hooks"] = hooks
        return result
    }

    // MARK: - File plumbing

    private var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    private func syncHooks() {
        applyTransform { Self.merged(into: $0) }
    }

    private func removeHooks() {
        applyTransform { root in
            let stripped = Self.strip(from: root)
            if NSDictionary(dictionary: stripped).isEqual(to: root) {
                return nil
            }
            return stripped
        }
    }

    /// Read → transform → (backup once) → atomic write. A transform
    /// returning nil means no change. Aborts, preserving the file, when the
    /// existing content isn't a JSON object.
    private func applyTransform(
        _ transform: ([String: Any]) -> [String: Any]?
    ) {
        let url = settingsURL
        let fm = FileManager.default
        var root: [String: Any] = [:]
        let exists = fm.fileExists(atPath: url.path)
        if exists {
            guard let data = try? Data(contentsOf: url),
                let parsed = try? JSONSerialization.jsonObject(with: data),
                let object = parsed as? [String: Any]
            else {
                Ghostty.logger.warning(
                    "phanttom claude hooks: \(url.path) is not a readable JSON object; leaving it alone")
                return
            }
            root = object
        }

        guard let updated = transform(root) else { return }

        do {
            if exists {
                let backup = url.deletingLastPathComponent()
                    .appendingPathComponent("settings.json.bak-phanttom")
                if !fm.fileExists(atPath: backup.path) {
                    try fm.copyItem(at: url, to: backup)
                }
            } else {
                try fm.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
            }
            let data = try JSONSerialization.data(
                withJSONObject: updated,
                options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            Ghostty.logger.info("phanttom claude hooks: updated \(url.path)")
        } catch {
            Ghostty.logger.warning(
                "phanttom claude hooks: failed to update \(url.path): \(error)")
        }
    }
}
