import Foundation
import GhosttyKit

/// Installs / updates / removes Phanttom's Claude Code hooks + statusline
/// wrapper in the user's `~/.claude/settings.json`.
///
/// Payload (hook script text and dispatch commands) is embedded as Swift
/// string constants — no bundle resources — so it's versioned with the app
/// and unit-testable. Settings.json is read-modify-written with
/// `JSONSerialization` dictionaries so unknown keys round-trip.
enum PhanttomClaudeIntegration {
    /// Bump on any change to `hookScript` text or `desiredHooks` /
    /// `desiredStatusLine`. Drives the Settings "Update available" state.
    /// v5: marker wire format includes a `.claude` kind token so Cursor/Codex
    /// can share the same OSC parser without colliding with legacy prompts.
    /// v6: the `notification` branch emitted a literal ASCII "007" into the
    /// tty instead of a BEL byte — one backslash short, so `printf` saw
    /// `\\007` (escaped backslash + digits) rather than `\\` + `\007`. The
    /// stray text landed in whatever was reading the tty. Now split into two
    /// printfs so no BEL escape ever sits next to the ST backslash.
    /// Existing installs see Settings "Update available" / silent launch repair.
    /// v7 (privacy hardening, three changes):
    /// - The hooks live in `~/.claude`, which EVERY Claude Code session on the
    ///   machine reads, so they used to write the marker title — carrying the
    ///   user's prompt text — into iTerm / VS Code / tmux titles too. Emitting
    ///   is now gated on the session actually running in a Ghostty/Phanttom
    ///   terminal.
    /// - Only the FIRST prompt of a session is put in the title. The app only
    ///   ever consumed the first one (auto-name locks); every later emission
    ///   was prompt text in the macOS window title — visible to screen
    ///   recording, Accessibility clients, and screenshots — for nothing.
    /// - Per-session scratch state moved from `${TMPDIR:-/tmp}` to a 0700
    ///   directory under `~/.claude`. With `TMPDIR` unset the old path was
    ///   world-writable and guessable, so a pre-planted symlink could redirect
    ///   the write into any file the user could write.
    static let payloadVersion = 7

    static let hookScriptName = "phanttom-hook.sh"
    static let stateFileName = "phanttom-integration.json"
    static let settingsFileName = "settings.json"
    static let originalStatusLineKey = "phanttomOriginalStatusLine"
    /// Full original `statusLine` object (not just its `command`), stashed so
    /// sibling keys like `padding` survive a Set Up → Remove round-trip. The
    /// string `originalStatusLineKey` above stays authoritative for the hook's
    /// runtime statusline chaining and for back-compat.
    static let originalStatusLineObjectKey = "phanttomOriginalStatusLineObject"
    /// Pre-marker UserDefaults opt-out. Consumed once by
    /// `migrateOptOutFromDefaults`; never written anymore.
    static let autoInstallDisabledKey = "PhanttomClaudeAutoInstallDisabled"
    /// Pre-auto-install "one prompt, ever" key. Consumed by
    /// `migrateConsent`; never written anymore.
    static let setupPromptedKey = "PhanttomClaudeSetupPrompted"
    /// PR #15 consent key ("enabled"/"disabled"). Consumed by
    /// `migrateConsent`; never written anymore.
    static let legacyConsentKey = "PhanttomClaudeHooks"

    // MARK: - Status

    enum IntegrationStatus: Equatable {
        case notInstalled
        case installedCurrent
        case installedOutdated(installedVersion: Int)
        case legacyInline
    }

    /// Outcome of the one-shot migration from the pre-auto-install consent
    /// keys (`setupPromptedKey`, PR #15 `legacyConsentKey`) to the shared
    /// opt-out marker.
    enum ConsentMigration: Equatable {
        /// Consume the old keys; auto-install proceeds.
        case autoInstall
        /// Consume the old keys; a prior decline / Remove becomes the opt-out.
        case disableAutoInstall
        /// Status unreadable — keep the old keys and retry next launch.
        case retryLater
    }

    /// Pure decision for migrating old consent state. `legacyValue` is the
    /// PR #15 string ("enabled"/"disabled"), `promptedKeySet` the old
    /// "one prompt, ever" bool.
    nonisolated static func migrateConsent(
        legacyValue: String?,
        promptedKeySet: Bool,
        status: IntegrationStatus,
        statusError: ActionError?
    ) -> ConsentMigration {
        // PR #15's explicit "disabled" is an opt-out regardless of status.
        if legacyValue == "disabled" { return .disableAutoInstall }
        guard legacyValue != nil || promptedKeySet else { return .autoInstall }
        // Neither old key recorded a positive answer reliably: the prompted
        // key was set on "Set Up", "Not Now", and "Open Settings" alike, and
        // PR #15's "enabled" deliberately never reinstalled after an explicit
        // Remove. `.notInstalled` under either key therefore means the user
        // declined or removed the hooks — opt-outs auto-install must not
        // override. Any installed/legacy state means they wanted the hooks.
        if statusError != nil { return .retryLater }
        return status == .notInstalled ? .disableAutoInstall : .autoInstall
    }

    enum ActionError: Error, Equatable {
        case claudeNotFound
        case settingsCorrupt
        case writeFailed(String)
    }

    // MARK: - Desired state

    static let desiredHooks: [(event: String, matcher: String?, command: String)] = [
        ("UserPromptSubmit", nil, dispatch("prompt-submit")),
        ("SessionStart", nil, dispatch("session-start")),
        ("PostToolUse", "EnterWorktree|ExitWorktree", dispatch("post-tool-use")),
        ("Stop", nil, dispatch("stop")),
        // Re-arm rain if Stop cleared before background_tasks were registered.
        ("SubagentStart", nil, dispatch("subagent-start")),
        ("Notification", nil, dispatch("notification")),
    ]

    static let desiredStatusLine: [String: String] = [
        "type": "command",
        "command": dispatch("statusline"),
    ]

    nonisolated private static func dispatch(_ subcommand: String) -> String {
        "sh \"$HOME/.claude/\(hookScriptName)\" \(subcommand)"
    }

    // MARK: - Ownership

    /// Distinctive markers for the 2026-07 hand-installed / PR #15 inline
    /// hooks. Bare OSC 9;4 / OSC 7 alone are NOT ownership proofs — those are
    /// generic terminal sequences and would false-positive on foreign hooks.
    nonisolated static func isOurs(command: String) -> Bool {
        if command.contains(hookScriptName) { return true }
        if command.contains("statusline-phanttom.sh") { return true }
        // Title / model marker: ❯ + U+2063 as shell `\xNN` escapes after JSON parse.
        if command.contains("\\xe2\\x9d\\xaf\\xe2\\x81\\xa3") { return true }
        // Legacy inline rain/cwd/stop/notification all resolve tty via CLAUDE_PID
        // before emitting — foreign OSC hooks won't share that pairing.
        let hasClaudeTty = command.contains("CLAUDE_PID") && command.contains("ps -o tty=")
        if hasClaudeTty,
           command.contains("]9;4;") || command.contains("file://localhost") {
            return true
        }
        return false
    }

    nonisolated static func isLegacy(command: String) -> Bool {
        !command.contains(hookScriptName) && isOurs(command: command)
    }

    // MARK: - Pure merge core (no I/O)

    /// Strip every phanttom-owned hook entry; drop empty events (and `hooks`
    /// itself when empty, unless `keepEmptyHooksObject`).
    nonisolated static func removeOwnedHooks(
        from settings: [String: Any],
        keepEmptyHooksObject: Bool = false
    ) -> [String: Any] {
        var result = deepCopy(settings)
        guard var hooksObj = result["hooks"] as? [String: Any] else { return result }

        for (event, value) in hooksObj {
            // Iterate the ORIGINAL array so foreign non-object elements (stray
            // strings/numbers) and objects we don't own round-trip untouched —
            // only Phanttom-owned object entries are removed.
            guard let elements = value as? [Any] else { continue }
            var kept: [Any] = []
            for element in elements {
                guard var entry = element as? [String: Any] else {
                    // Not an object entry — preserve it verbatim.
                    kept.append(element)
                    continue
                }
                guard let inner = entry["hooks"] as? [Any] else {
                    // No inner hooks array to inspect — leave the entry as-is.
                    kept.append(entry)
                    continue
                }
                // Filter phanttom-owned commands *individually* so a foreign
                // command sharing an entry with ours survives.
                let filtered = inner.filter { hook in
                    guard let cmd = (hook as? [String: Any])?["command"] as? String
                    else { return true }
                    return !isOurs(command: cmd)
                }
                if filtered.isEmpty { continue }
                entry["hooks"] = filtered
                kept.append(entry)
            }
            if kept.isEmpty {
                hooksObj.removeValue(forKey: event)
            } else {
                hooksObj[event] = kept
            }
        }
        if hooksObj.isEmpty && !keepEmptyHooksObject {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = hooksObj
        }
        return result
    }

    nonisolated static func install(into settings: [String: Any]) -> [String: Any] {
        var result = removeOwnedHooks(from: settings, keepEmptyHooksObject: true)
        var hooksObj = (result["hooks"] as? [String: Any]) ?? [:]

        for desired in desiredHooks {
            let existing = hooksObj[desired.event]
            // Append to the ORIGINAL array so foreign entries (objects we don't
            // own AND non-object elements) survive. A non-array value at a hooks
            // event is invalid per Claude Code's schema and can't be merged;
            // replacing it with a fresh array is the only way to install our
            // dispatch. Skipping it (the old behavior) left `hasCompleteDispatch`
            // permanently false, so install re-ran every launch and Settings was
            // stuck showing "Update available".
            var entries: [Any] = (existing as? [Any]) ?? []
            var entry: [String: Any] = [
                "hooks": [
                    ["type": "command", "command": desired.command] as [String: Any],
                ] as [[String: Any]],
            ]
            if let matcher = desired.matcher {
                entry["matcher"] = matcher
            }
            entries.append(entry)
            hooksObj[desired.event] = entries
        }
        result["hooks"] = hooksObj

        if let existing = result["statusLine"] as? [String: Any],
           let cmd = existing["command"] as? String,
           !isOurs(command: cmd),
           result[originalStatusLineKey] == nil {
            result[originalStatusLineKey] = cmd
            // Stash the whole object so sibling keys (e.g. `padding`) restore.
            result[originalStatusLineObjectKey] = existing
        }
        result["statusLine"] = desiredStatusLine as [String: Any]

        return result
    }

    nonisolated static func uninstall(from settings: [String: Any]) -> [String: Any] {
        var result = removeOwnedHooks(from: settings)

        if let stashedObject = result[originalStatusLineObjectKey] as? [String: Any] {
            // Lossless restore of the user's original statusLine (incl. padding).
            result["statusLine"] = stashedObject
        } else if let stashed = result[originalStatusLineKey] as? String {
            result["statusLine"] = [
                "type": "command",
                "command": stashed,
            ] as [String: Any]
        } else if let existing = result["statusLine"] as? [String: Any],
                  let cmd = existing["command"] as? String,
                  isOurs(command: cmd) {
            result.removeValue(forKey: "statusLine")
        }
        result.removeValue(forKey: originalStatusLineKey)
        result.removeValue(forKey: originalStatusLineObjectKey)

        return result
    }

    nonisolated static func hasCompleteDispatch(in settings: [String: Any]) -> Bool {
        let hooksObj = settings["hooks"] as? [String: Any] ?? [:]
        let hooksComplete = desiredHooks.allSatisfy { desired in
            guard let entries = asEntryArray(hooksObj[desired.event] as Any?) else {
                return false
            }
            return entries.contains { entry in
                commands(in: entry).contains(desired.command)
            }
        }
        let statusCmd = (settings["statusLine"] as? [String: Any])?["command"] as? String
        let statuslineOurs = statusCmd?.contains(hookScriptName) == true
        return hooksComplete && statuslineOurs
    }

    nonisolated static func hasPartialDispatch(in settings: [String: Any]) -> Bool {
        let hooksObj = settings["hooks"] as? [String: Any] ?? [:]
        let anyHook = desiredHooks.contains { desired in
            guard let entries = asEntryArray(hooksObj[desired.event] as Any?) else {
                return false
            }
            return entries.contains { entry in
                commands(in: entry).contains(where: { $0.contains(hookScriptName) })
            }
        }
        let statusCmd = (settings["statusLine"] as? [String: Any])?["command"] as? String
        let statuslineOurs = statusCmd?.contains(hookScriptName) == true
        return anyHook || statuslineOurs
    }

    nonisolated static func status(
        of settings: [String: Any],
        scriptText: String?
    ) -> IntegrationStatus {
        let hooksObj = settings["hooks"] as? [String: Any] ?? [:]
        var allCommands: [String] = []
        for (_, value) in hooksObj {
            guard let entries = asEntryArray(value) else { continue }
            for entry in entries {
                allCommands.append(contentsOf: commands(in: entry))
            }
        }
        if let statusCmd = (settings["statusLine"] as? [String: Any])?["command"] as? String {
            allCommands.append(statusCmd)
        }

        let hasLegacy = allCommands.contains(where: isLegacy(command:))

        if hasCompleteDispatch(in: settings) {
            let installed = parseScriptVersion(scriptText)
            if let installed, installed >= payloadVersion {
                return .installedCurrent
            }
            return .installedOutdated(installedVersion: installed ?? 0)
        }
        // Partial dispatch (interrupted install) → Update can repair.
        if hasPartialDispatch(in: settings) {
            return .installedOutdated(installedVersion: parseScriptVersion(scriptText) ?? 0)
        }
        if hasLegacy {
            return .legacyInline
        }
        return .notInstalled
    }

    nonisolated static func parseScriptVersion(_ text: String?) -> Int? {
        PhanttomIntegrationSupport.parseScriptVersion(text)
    }

    // MARK: - File I/O

    struct Paths {
        let baseDir: URL
        var settings: URL { baseDir.appendingPathComponent(settingsFileName) }
        var script: URL { baseDir.appendingPathComponent(hookScriptName) }
        var state: URL { baseDir.appendingPathComponent(stateFileName) }
        /// The hook script's private 0700 scratch directory — see
        /// `PhanttomIntegrationSupport.sessionStateDirName`.
        var sessionState: URL {
            baseDir.appendingPathComponent(
                PhanttomIntegrationSupport.sessionStateDirName)
        }

        static var `default`: Paths {
            Paths(baseDir: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude"))
        }
    }

    struct ActionResult {
        let status: IntegrationStatus
        let error: ActionError?
        /// Human-readable status for the Settings caption.
        let message: String
    }

    // MARK: - Auto-install opt-out

    /// Whether an explicit Remove… has switched launch-time auto-install off.
    /// Shared across builds — see
    /// `PhanttomIntegrationSupport.optOutFileName`.
    nonisolated static func isAutoInstallDisabled(paths: Paths = .default) -> Bool {
        PhanttomIntegrationSupport.isAutoInstallDisabled(in: paths.baseDir)
    }

    /// Record (or lift) the opt-out. Writing is best-effort: if `~/.claude`
    /// is missing there is nothing to auto-install into anyway, and the next
    /// Remove… once it exists will record the decision.
    nonisolated static func setAutoInstallDisabled(
        _ disabled: Bool,
        paths: Paths = .default
    ) {
        PhanttomIntegrationSupport.setAutoInstallDisabled(disabled, in: paths.baseDir)
    }

    /// Whether the user has already answered the "install these hooks?"
    /// question for this `~/.claude`. Shared across builds, like the opt-out
    /// — see `PhanttomIntegrationSupport.consentFileName`.
    nonisolated static func hasAskedAutoInstall(paths: Paths = .default) -> Bool {
        PhanttomIntegrationSupport.hasAskedAutoInstall(in: paths.baseDir)
    }

    /// Record that the question has been answered (either way).
    nonisolated static func setAskedAutoInstall(
        _ asked: Bool,
        paths: Paths = .default
    ) {
        PhanttomIntegrationSupport.setAskedAutoInstall(asked, in: paths.baseDir)
    }

    /// One-shot move of the pre-marker UserDefaults opt-out into the shared
    /// marker file. Returns `true` once the key has been dealt with so the
    /// caller can clear it. Defers (returns `false`) while `~/.claude` is
    /// absent, so an opt-out is never dropped on the floor.
    nonisolated static func migrateOptOutFromDefaults(
        wasDisabled: Bool,
        paths: Paths = .default
    ) -> Bool {
        guard claudeDirectoryExists(paths: paths) else { return false }
        if wasDisabled { setAutoInstallDisabled(true, paths: paths) }
        return true
    }

    nonisolated static func claudeDirectoryExists(paths: Paths = .default) -> Bool {
        PhanttomIntegrationSupport.directoryExists(at: paths.baseDir)
    }

    nonisolated static func currentStatus(paths: Paths = .default) -> ActionResult {
        guard claudeDirectoryExists(paths: paths) else {
            return ActionResult(
                status: .notInstalled,
                error: .claudeNotFound,
                message: "Claude Code not found (~/.claude missing)"
            )
        }
        let settings: [String: Any]
        if FileManager.default.fileExists(atPath: paths.settings.path) {
            do {
                settings = try readSettings(at: paths.settings)
            } catch {
                Ghostty.logger.warning(
                    "phanttom claude integration: settings.json unreadable: \(error)"
                )
                return ActionResult(
                    status: .notInstalled,
                    error: .settingsCorrupt,
                    message: "Could not read settings.json — fix or restore a backup before continuing"
                )
            }
        } else {
            settings = [:]
        }
        let scriptText = try? String(contentsOf: paths.script, encoding: .utf8)
        let st = status(of: settings, scriptText: scriptText)
        return ActionResult(status: st, error: nil, message: statusCaption(st))
    }

    nonisolated static func statusCaption(_ status: IntegrationStatus) -> String {
        switch status {
        case .notInstalled:
            return "Not set up"
        case .installedCurrent:
            return "Active (v \(payloadVersion))"
        case .installedOutdated(let installed):
            return "Update available (v \(installed) → \(payloadVersion))"
        case .legacyInline:
            return "Legacy setup detected — update to migrate"
        }
    }

    @discardableResult
    nonisolated static func performInstall(paths: Paths = .default) -> ActionResult {
        do {
            return try applyInstall(paths: paths)
        } catch let err as ActionError {
            Ghostty.logger.warning(
                "phanttom claude integration: install failed: \(errorMessage(err))"
            )
            return ActionResult(
                status: currentStatus(paths: paths).status,
                error: err,
                message: errorMessage(err)
            )
        } catch {
            Ghostty.logger.warning(
                "phanttom claude integration: install failed: \(error)"
            )
            return ActionResult(
                status: currentStatus(paths: paths).status,
                error: .writeFailed(error.localizedDescription),
                message: error.localizedDescription
            )
        }
    }

    @discardableResult
    nonisolated static func performUninstall(paths: Paths = .default) -> ActionResult {
        do {
            return try applyUninstall(paths: paths)
        } catch let err as ActionError {
            Ghostty.logger.warning(
                "phanttom claude integration: uninstall failed: \(errorMessage(err))"
            )
            return ActionResult(
                status: currentStatus(paths: paths).status,
                error: err,
                message: errorMessage(err)
            )
        } catch {
            Ghostty.logger.warning(
                "phanttom claude integration: uninstall failed: \(error)"
            )
            return ActionResult(
                status: currentStatus(paths: paths).status,
                error: .writeFailed(error.localizedDescription),
                message: error.localizedDescription
            )
        }
    }

    nonisolated private static func errorMessage(_ err: ActionError) -> String {
        switch err {
        case .claudeNotFound:
            return "Claude Code not found (~/.claude missing)"
        case .settingsCorrupt:
            return "settings.json is not valid JSON — aborted without changes"
        case .writeFailed(let detail):
            return "Write failed: \(detail)"
        }
    }

    /// Script + state first, then settings.json — so a mid-write failure never
    /// leaves hooks pointing at a missing `phanttom-hook.sh`.
    nonisolated private static func applyInstall(paths: Paths) throws -> ActionResult {
        guard claudeDirectoryExists(paths: paths) else {
            throw ActionError.claudeNotFound
        }

        let fm = FileManager.default
        let settingsExists = fm.fileExists(atPath: paths.settings.path)
        var settings: [String: Any] = [:]
        if settingsExists {
            do {
                settings = try readSettings(at: paths.settings)
            } catch {
                throw ActionError.settingsCorrupt
            }
        }
        let onDisk = settings

        // Legacy statusline wrapper is "ours", so the pure merge won't stash
        // the user's real statusline. Recover the known chain target when
        // migrating the hand-installed 2026-07 setup.
        settings = prepareLegacyStatuslineStash(settings, paths: paths)
        let next = install(into: settings)

        try writeScript(paths: paths)
        try writeState(paths: paths, settings: next)
        // Only rewrite settings.json (and snapshot a backup) when it actually
        // changes. Repeated launch-time repair passes on a config that can
        // never reach `.installedCurrent` (e.g. a malformed non-array event
        // value) must not churn backups and prune away the pristine
        // pre-Phanttom snapshot.
        if !settingsExists || !jsonEqual(next, onDisk) {
            if settingsExists {
                try backupSettings(at: paths.settings)
            }
            try writeSettings(next, to: paths.settings)
        }
        removeLegacyStatuslineScript(paths: paths)

        return currentStatus(paths: paths)
    }

    nonisolated private static func applyUninstall(paths: Paths) throws -> ActionResult {
        guard claudeDirectoryExists(paths: paths) else {
            throw ActionError.claudeNotFound
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: paths.settings.path) {
            try? fm.removeItem(at: paths.script)
            try? fm.removeItem(at: paths.state)
            removeLegacyStatuslineScript(paths: paths)
            removeSessionState(paths: paths)
            removeBackups(paths: paths)
            return currentStatus(paths: paths)
        }

        let settings: [String: Any]
        do {
            settings = try readSettings(at: paths.settings)
        } catch {
            // settings.json won't parse, so we can't strip our hook entries
            // from it. Deleting the script anyway would leave those entries
            // pointing at a missing phanttom-hook.sh: the moment the user
            // hand-fixes their JSON, every hooked event starts failing with
            // "no such file" and Settings can offer no obvious repair. Leaving
            // both in place keeps settings.json and the filesystem consistent,
            // makes this a true no-op (as `errorMessage` already claims), and
            // leaves Remove working normally once the JSON is valid again.
            throw ActionError.settingsCorrupt
        }
        try backupSettings(at: paths.settings)

        // A legacy hand-installed user who clicks Remove without ever migrating
        // via Set Up has no stash, and their statusLine.command is our wrapper
        // (statusline-phanttom.sh) chaining to statusline-command.sh. Seed the
        // stash first — exactly as applyInstall does — so uninstall restores
        // their real chained statusline instead of deleting the key entirely
        // (matching the Remove alert's "restores your previous statusline"
        // promise). A no-op when a stash already exists or there's no wrapper.
        let prepared = prepareLegacyStatuslineStash(settings, paths: paths)
        let next = uninstall(from: prepared)
        try writeSettings(next, to: paths.settings)
        try? fm.removeItem(at: paths.script)
        try? fm.removeItem(at: paths.state)
        removeLegacyStatuslineScript(paths: paths)
        removeSessionState(paths: paths)
        // Only after the settings write succeeded: settings.json is back to
        // its pre-Phanttom shape, so the snapshots have done their job — and
        // keeping them means a credential the user has since removed from
        // settings.json survives indefinitely in a file we created without
        // telling them.
        removeBackups(paths: paths)

        return currentStatus(paths: paths)
    }

    /// Drop the hook script's private per-session scratch directory
    /// (`~/.claude/.phanttom-sessions`). Nothing else reads it, and it names
    /// the sessions that ran.
    nonisolated private static func removeSessionState(paths: Paths) {
        try? FileManager.default.removeItem(at: paths.sessionState)
    }

    nonisolated private static func removeBackups(paths: Paths) {
        PhanttomIntegrationSupport.removeBackups(
            in: paths.baseDir, prefix: backupPrefix)
    }

    /// If the current statusline is the legacy phanttom wrapper, and we don't
    /// already have a stash, seed `phanttomOriginalStatusLine` from the
    /// chained `statusline-command.sh` when present.
    nonisolated static func prepareLegacyStatuslineStash(
        _ settings: [String: Any],
        paths: Paths
    ) -> [String: Any] {
        var result = deepCopy(settings)
        if result[originalStatusLineKey] != nil { return result }
        guard let cmd = (result["statusLine"] as? [String: Any])?["command"] as? String,
              cmd.contains("statusline-phanttom.sh")
        else { return result }

        let chained = paths.baseDir.appendingPathComponent("statusline-command.sh")
        if FileManager.default.fileExists(atPath: chained.path) {
            result[originalStatusLineKey] =
                "bash \"$HOME/.claude/statusline-command.sh\""
        }
        return result
    }

    nonisolated private static func removeLegacyStatuslineScript(paths: Paths) {
        let legacy = paths.baseDir.appendingPathComponent("statusline-phanttom.sh")
        try? FileManager.default.removeItem(at: legacy)
    }

    /// Timestamped backup prefix for `settings.json`. Also the prune filter —
    /// only our own snapshots are ever considered for deletion.
    static let backupPrefix = "settings.json.bak-phanttom-"

    /// Every call site collapses any read failure into `.settingsCorrupt`
    /// (an unreadable settings.json is unrecoverable the same way whether it
    /// is absent, unparseable, or a JSON array), so the shared layer's finer
    /// `IOError` cases are flattened here rather than widening `ActionError`.
    nonisolated static func readSettings(at url: URL) throws -> [String: Any] {
        do {
            return try PhanttomIntegrationSupport.readJSONObject(
                at: url, absentAsEmpty: false)
        } catch {
            throw ActionError.settingsCorrupt
        }
    }

    nonisolated static func writeSettings(_ settings: [String: Any], to url: URL) throws {
        do {
            try PhanttomIntegrationSupport.writeJSONObject(settings, to: url)
        } catch let err as PhanttomIntegrationSupport.IOError {
            throw ActionError.writeFailed(Self.detail(err))
        }
    }

    nonisolated static func backupSettings(at settingsURL: URL) throws {
        try PhanttomIntegrationSupport.backupFile(at: settingsURL, prefix: backupPrefix)
    }

    nonisolated static func pruneBackups(in directory: URL, keeping max: Int) {
        PhanttomIntegrationSupport.pruneBackups(
            in: directory, prefix: backupPrefix, keeping: max)
    }

    nonisolated private static func detail(
        _ err: PhanttomIntegrationSupport.IOError
    ) -> String {
        switch err {
        case .writeFailed(let d): return d
        case .notAnObject(let name): return "\(name) is not a JSON object"
        case .missing(let name): return "missing \(name)"
        }
    }

    nonisolated private static func writeScript(paths: Paths) throws {
        try PhanttomIntegrationSupport.writeScript(hookScript, to: paths.script)
    }

    nonisolated private static func writeState(
        paths: Paths,
        settings: [String: Any]
    ) throws {
        let original = settings[originalStatusLineKey] as? String ?? ""
        let state: [String: Any] = [
            "version": payloadVersion,
            "originalStatusLine": original,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        var payload = data
        payload.append(contentsOf: "\n".utf8)
        try payload.write(to: paths.state, options: .atomic)
    }

    // MARK: - Dictionary helpers

    /// Structural JSON equality (key order independent). Returns false if
    /// either side isn't a serializable JSON object, so callers fall back to
    /// writing rather than skipping a needed update.
    nonisolated private static func jsonEqual(
        _ a: [String: Any], _ b: [String: Any]
    ) -> Bool {
        PhanttomIntegrationSupport.jsonEqual(a, b)
    }

    nonisolated private static func deepCopy(_ settings: [String: Any]) -> [String: Any] {
        PhanttomIntegrationSupport.deepCopy(settings)
    }

    nonisolated private static func asEntryArray(_ value: Any?) -> [[String: Any]]? {
        guard let value else { return nil }
        if let typed = value as? [[String: Any]] { return typed }
        guard let arr = value as? [Any] else { return nil }
        return arr.compactMap { $0 as? [String: Any] }
    }

    nonisolated private static func commands(in entry: [String: Any]) -> [String] {
        guard let hooks = entry["hooks"] as? [Any] else { return [] }
        return hooks.compactMap { hook in
            (hook as? [String: Any])?["command"] as? String
        }
    }
}
