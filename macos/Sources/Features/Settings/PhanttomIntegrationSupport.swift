import Foundation

/// Agent-agnostic plumbing shared by the hook installers
/// (`PhanttomClaudeIntegration`, `PhanttomCursorIntegration`).
///
/// Only the parts that are genuinely identical across agents live here: JSON
/// read/write, timestamped backups and their pruning, the versioned hook
/// script payload, and the auto-install opt-out marker. Each integration
/// keeps its own desired-state merge logic, hook script text, config file
/// layout, and status / error vocabulary — those differ for real reasons
/// (Claude has one `settings.json` with nested matcher entries; Cursor splits
/// flat hooks across `hooks.json` + `cli-config.json`), and collapsing them
/// would mean inventing a union type that fits neither.
///
/// Adding a third agent should mean a new merge core plus a new hook script,
/// not another copy of the file layer.
enum PhanttomIntegrationSupport {
    /// Low-level failure from the shared file layer. Each integration maps
    /// these onto its own `ActionError` so Settings keeps agent-specific
    /// wording ("settings.json is not valid JSON", "hooks.json …").
    enum IOError: Error, Equatable {
        /// Present but unparseable, or parsed to something other than an
        /// object.
        case notAnObject(String)
        /// Absent, and the caller required it to exist.
        case missing(String)
        case writeFailed(String)
    }

    // MARK: - Opt-out marker

    /// Written by an explicit Remove… in Settings and deleted by Set Up /
    /// Update. While it exists, launch-time auto-install stays off.
    ///
    /// A file beside the config it governs, not a UserDefaults key:
    /// `UserDefaults.standard` is scoped to the bundle identifier, so the
    /// Debug build (`com.mitchellh.ghostty.debug`) and the release build
    /// (`com.mitchellh.ghostty`) have separate domains while auto-installing
    /// into the *same* `~/.claude` / `~/.cursor`. A defaults-backed opt-out
    /// set in one build was invisible to the other, which silently
    /// reinstalled the hooks. The decision belongs with the resource it
    /// governs.
    ///
    /// Deliberately NOT a field in either integration's state file — uninstall
    /// deletes those, and Remove… runs the uninstall right after recording the
    /// opt-out.
    static let optOutFileName = ".phanttom-no-autoinstall"

    /// Whether an explicit Remove… has switched launch-time auto-install off
    /// for the agent rooted at `directory`.
    nonisolated static func isAutoInstallDisabled(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(optOutFileName).path)
    }

    /// Record (or lift) the opt-out. Writing is best-effort: if the agent's
    /// directory is missing there is nothing to auto-install into anyway, and
    /// the next Remove… once it exists will record the decision.
    nonisolated static func setAutoInstallDisabled(
        _ disabled: Bool,
        in directory: URL
    ) {
        let marker = directory.appendingPathComponent(optOutFileName)
        if disabled {
            try? Data().write(to: marker)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }

    // MARK: - Consent marker

    /// Written once the user has been asked whether to install this agent's
    /// hooks (or has been grandfathered in because the hooks were already
    /// installed). While it is absent, launch-time sync must ask before
    /// touching the agent's config.
    ///
    /// A file beside the config it governs for the same reason as
    /// `optOutFileName`: the answer is about `~/.claude` / `~/.cursor`, which
    /// every build shares, while `UserDefaults` is per bundle identifier. It
    /// is deliberately separate from the opt-out marker — "asked and said no"
    /// and "asked and said yes" must be distinguishable from "never asked",
    /// and Set Up (which clears the opt-out) must not un-ask the question.
    static let consentFileName = ".phanttom-autoinstall-asked"

    /// Whether the user has already answered the install question for the
    /// agent rooted at `directory`.
    nonisolated static func hasAskedAutoInstall(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(consentFileName).path)
    }

    /// Record that the question has been answered. Best-effort, like the
    /// opt-out: a missing agent directory means there was nothing to install
    /// into, and the question is asked again once it exists.
    nonisolated static func setAskedAutoInstall(_ asked: Bool, in directory: URL) {
        let marker = directory.appendingPathComponent(consentFileName)
        if asked {
            try? Data().write(to: marker)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }

    // MARK: - Directories

    nonisolated static func directoryExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - JSON documents

    /// Read a JSON object, treating an absent file as `[:]` when
    /// `absentAsEmpty` (the common "config not created yet" case).
    nonisolated static func readJSONObject(
        at url: URL,
        absentAsEmpty: Bool
    ) throws -> [String: Any] {
        if !FileManager.default.fileExists(atPath: url.path) {
            if absentAsEmpty { return [:] }
            throw IOError.missing(url.lastPathComponent)
        }
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw IOError.notAnObject(url.lastPathComponent)
        }
        return dict
    }

    /// Serialize and write atomically. The re-parse check is deliberate: a
    /// dictionary carrying a non-JSON value serializes lazily and would
    /// otherwise land as a truncated config file.
    ///
    /// An atomic write replaces the file rather than rewriting it in place,
    /// so the existing mode is captured first and re-applied afterwards: these
    /// are agent config files that can carry credentials (`env` blocks,
    /// `apiKeyHelper`), and a user who chmodded `settings.json` to 0600 must
    /// not silently get a 0644 copy back because Phanttom rewrote it.
    nonisolated static func writeJSONObject(
        _ object: [String: Any],
        to url: URL
    ) throws {
        let priorMode = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw IOError.writeFailed(error.localizedDescription)
        }
        guard let check = try? JSONSerialization.jsonObject(with: data),
              check is [String: Any]
        else {
            throw IOError.writeFailed("serialized JSON failed re-parse")
        }
        var payload = data
        payload.append(contentsOf: "\n".utf8)
        do {
            try payload.write(to: url, options: .atomic)
        } catch {
            throw IOError.writeFailed(error.localizedDescription)
        }
        if let priorMode {
            try? FileManager.default.setAttributes(
                [.posixPermissions: priorMode], ofItemAtPath: url.path)
        }
    }

    nonisolated static func jsonEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let opts: JSONSerialization.WritingOptions = [.sortedKeys]
        guard let da = try? JSONSerialization.data(withJSONObject: a, options: opts),
              let db = try? JSONSerialization.data(withJSONObject: b, options: opts)
        else { return false }
        return da == db
    }

    /// Value-semantics copy of a nested JSON dictionary. Returns the input
    /// unchanged when it isn't serializable — callers are merging user config
    /// and must not lose it to a round-trip failure.
    nonisolated static func deepCopy(_ object: [String: Any]) -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return object
        }
        return obj
    }

    // MARK: - Hook script payload

    /// Per-session scratch directory each agent's hook script keeps under its
    /// own config directory (`~/.claude/.phanttom-sessions`,
    /// `~/.cursor/.phanttom-sessions`): the last model emitted, and whether a
    /// tab has already spent its one naming prompt.
    ///
    /// Deliberately not `$TMPDIR`/`/tmp`: with `TMPDIR` unset that path is
    /// world-writable and its name guessable, so a planted symlink could
    /// redirect the writes. Created 0700 by `hookPrelude` below.
    static let sessionStateDirName = ".phanttom-sessions"

    /// The opening of every agent's `phanttom-hook.sh`: the emit guard and
    /// the private per-session scratch directory. Shared because it is
    /// genuinely the same decision for every agent — "is this session running
    /// in Phanttom, and where may I keep state" — unlike the emit logic
    /// below it, which differs per agent for real reasons (`CLAUDE_PID` vs
    /// `CURSOR_AGENT` + an ancestor tty walk) and stays in each script.
    ///
    /// Interpolated at column 0 of a script's multiline literal: Swift does
    /// not re-indent interpolated text, and shell does not care, but keeping
    /// it flush matches the rest of the emitted file.
    ///
    /// Editing this text changes both payloads — bump **both**
    /// `payloadVersion`s.
    nonisolated static func hookPrelude(agentDirName: String) -> String {
        """
        SESSION_DIR="${HOME}/\(agentDirName)/\(sessionStateDirName)"

        # These hooks live in the agent's config directory, so they run for
        # EVERY session of that agent on this machine — including ones started
        # from iTerm, VS Code, tmux or an ssh-in. Only Phanttom/Ghostty
        # understands the sequences we emit, and the marker title carries
        # prompt text, so stay silent everywhere else rather than rewriting a
        # foreign terminal's window title.
        phanttom_terminal() {
          [ "${TERM_PROGRAM:-}" = "ghostty" ] || [ -n "${GHOSTTY_RESOURCES_DIR:-}" ]
        }

        # Private per-session scratch. Under $HOME at 0700, never $TMPDIR or
        # /tmp: with TMPDIR unset that path is world-writable and its name
        # guessable, so a planted symlink could redirect these writes. Prints
        # nothing when the directory can't be created; callers treat that as
        # "no cache" and simply re-emit.
        session_dir() {
          if [ ! -d "$SESSION_DIR" ]; then
            mkdir -p "$SESSION_DIR" 2>/dev/null || return 0
            chmod 700 "$SESSION_DIR" 2>/dev/null || true
          fi
          printf "%s" "$SESSION_DIR"
        }

        # Sessions end without telling us, so sweep week-old scratch files.
        prune_sessions() {
          sdir=$(session_dir)
          [ -n "$sdir" ] || return 0
          find "$sdir" -type f -mtime +7 -exec rm -f {} + 2>/dev/null || true
        }
        """
    }

    /// Version stamped into the installed script by every integration's
    /// `hookScript` (`# phanttom-hook v<N>`). Drives the Settings "Update
    /// available" state.
    static let scriptVersionMarker = "# phanttom-hook v"

    nonisolated static func parseScriptVersion(_ text: String?) -> Int? {
        guard let text else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(scriptVersionMarker) else { continue }
            let suffix = trimmed.dropFirst(scriptVersionMarker.count)
                .trimmingCharacters(in: .whitespaces)
            var digits = ""
            for ch in suffix {
                guard ch.isNumber else { break }
                digits.append(ch)
            }
            if let n = Int(digits) { return n }
        }
        return nil
    }

    nonisolated static func writeScript(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Backups

    /// Snapshot `url` as `<prefix><timestamp>` beside itself, then prune.
    /// A no-op when the file doesn't exist.
    nonisolated static func backupFile(at url: URL, prefix: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let dir = url.deletingLastPathComponent()
        // Same-second install→uninstall (or rapid Updates) must not collide.
        var backupURL = dir.appendingPathComponent("\(prefix)\(stamp)")
        var n = 2
        while fm.fileExists(atPath: backupURL.path) {
            backupURL = dir.appendingPathComponent("\(prefix)\(stamp)-\(n)")
            n += 1
        }
        try fm.copyItem(at: url, to: backupURL)
        // `copyItem` inherits the source mode, which for a world-readable
        // settings.json means a world-readable snapshot of a file that can
        // contain credentials. Nothing but this process and the user ever
        // reads a backup, so tighten it unconditionally.
        try? fm.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        pruneBackups(in: dir, prefix: prefix, keeping: 5)
    }

    /// Delete every backup we made with `prefix`. Called after a *successful*
    /// uninstall, once the agent's config is back to its pre-Phanttom shape:
    /// keeping the snapshots past that point means a credential the user has
    /// since deleted from `settings.json` lives on indefinitely, in plaintext,
    /// in a file they never knew we created.
    nonisolated static func removeBackups(in directory: URL, prefix: String) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in items where url.lastPathComponent.hasPrefix(prefix) {
            guard isRegularFile(url) else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Every deletion in this file is name-matched inside the user's agent
    /// directory, and `removeItem` deletes a directory *and its contents*. A
    /// directory can't get that name by our own hand, but the cost of being
    /// wrong is someone's data, so nothing but a regular file is ever removed.
    nonisolated private static func isRegularFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && !isDir.boolValue
    }

    nonisolated static func pruneBackups(
        in directory: URL,
        prefix: String,
        keeping max: Int
    ) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let backups = items.filter {
            $0.lastPathComponent.hasPrefix(prefix)
        }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return da > db
        }
        // Keep the `max` newest plus the single oldest backup — that oldest
        // snapshot is the pristine pre-Phanttom copy and must never be pruned.
        let oldest = backups.last
        for url in backups.dropFirst(max) where url != oldest {
            guard isRegularFile(url) else { continue }
            try? fm.removeItem(at: url)
        }
    }
}
