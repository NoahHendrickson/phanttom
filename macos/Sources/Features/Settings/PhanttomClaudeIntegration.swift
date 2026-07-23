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
    static let payloadVersion = 1

    static let hookScriptName = "phanttom-hook.sh"
    static let stateFileName = "phanttom-integration.json"
    static let settingsFileName = "settings.json"
    static let originalStatusLineKey = "phanttomOriginalStatusLine"
    static let setupPromptedKey = "PhanttomClaudeSetupPrompted"

    // MARK: - Status

    enum IntegrationStatus: Equatable {
        case notInstalled
        case installedCurrent
        case installedOutdated(installedVersion: Int)
        case legacyInline
    }

    enum ActionError: Error, Equatable {
        case claudeNotFound
        case settingsUnreadable
        case settingsCorrupt
        case writeFailed(String)
    }

    // MARK: - Desired state

    static let desiredHooks: [(event: String, matcher: String?, command: String)] = [
        ("UserPromptSubmit", nil, dispatch("prompt-submit")),
        ("SessionStart", nil, dispatch("session-start")),
        ("PostToolUse", "EnterWorktree|ExitWorktree", dispatch("post-tool-use")),
        ("Stop", nil, dispatch("stop")),
        ("Notification", nil, dispatch("notification")),
    ]

    static let desiredStatusLine: [String: String] = [
        "type": "command",
        "command": dispatch("statusline"),
    ]

    nonisolated private static func dispatch(_ subcommand: String) -> String {
        "sh \"$HOME/.claude/\(hookScriptName)\" \(subcommand)"
    }

    /// Versioned helper installed at `~/.claude/phanttom-hook.sh`. Every hook
    /// and the statusline are thin dispatch calls into this file.
    ///
    /// Any edit to this text must bump `payloadVersion`.
    static var hookScript: String {
        """
        #!/bin/sh
        # phanttom-hook v\(payloadVersion)
        # Managed by Phanttom — do not edit; overwritten on Update.
        # No `set -e`: hook processes must never fail the Claude Code call.

        STATE="${HOME}/.claude/phanttom-integration.json"

        resolve_tty() {
          t=$(ps -o tty= -p "${CLAUDE_PID:-$PPID}" 2>/dev/null | tr -d " ")
          case "$t" in ""|"??") t=/dev/tty;; *) t=/dev/$t;; esac
          printf "%s" "$t"
        }

        # Prefer jq when present; else /usr/bin/perl + JSON::PP (ships with macOS).
        json_get() {
          path="$1"
          if command -v jq >/dev/null 2>&1; then
            case "$path" in
              prompt) jq -r ".prompt // empty" 2>/dev/null ;;
              cwd) jq -r ".cwd // empty" 2>/dev/null ;;
              transcript_path) jq -r ".transcript_path // empty" 2>/dev/null ;;
              session_id) jq -r ".session_id // empty" 2>/dev/null ;;
              model.id) jq -r ".model.id // empty" 2>/dev/null ;;
              model.display_name) jq -r ".model.display_name // empty" 2>/dev/null ;;
              *) jq -r ".$path // empty" 2>/dev/null ;;
            esac
          else
            /usr/bin/perl -MJSON::PP -0777 -e '
              my $path = shift @ARGV;
              my $raw = do { local $/; <STDIN> };
              my $j = eval { decode_json($raw) };
              exit 0 unless $j;
              my @p = split(/\\./, $path);
              my $cur = $j;
              for my $k (@p) {
                if (ref($cur) eq "HASH" && exists $cur->{$k}) { $cur = $cur->{$k}; }
                else { exit 0; }
              }
              exit 0 if !defined $cur || ref($cur);
              print $cur;
            ' "$path" 2>/dev/null
          fi
        }

        json_get_cwd_uri() {
          if command -v jq >/dev/null 2>&1; then
            jq -r ".cwd // empty | @uri" 2>/dev/null | sed "s|%2F|/|g"
          else
            /usr/bin/perl -MJSON::PP -0777 -e '
              my $raw = do { local $/; <STDIN> };
              my $j = eval { decode_json($raw) };
              exit 0 unless $j && defined $j->{cwd} && !ref($j->{cwd});
              my $s = $j->{cwd};
              $s =~ s/([^A-Za-z0-9\\-_.~\\/])/sprintf("%%%02X", ord($1))/ge;
              $s =~ s/%2F/\\//gi;
              print $s;
            ' 2>/dev/null
          fi
        }

        emit_osc74() {
          t=$(resolve_tty)
          printf "\\033]9;4;%s;0\\033\\\\" "$1" > "$t" 2>/dev/null || true
        }

        emit_osc7() {
          d=$(json_get_cwd_uri)
          [ -n "$d" ] || return 0
          t=$(resolve_tty)
          printf "\\033]7;file://localhost%s\\033\\\\" "$d" > "$t" 2>/dev/null || true
        }

        emit_prompt_title() {
          j="$1"
          p=$(printf "%s" "$j" | json_get prompt | tr "\\n" " " | cut -c1-56)
          tp=$(printf "%s" "$j" | json_get transcript_path)
          m=""
          if [ -n "$tp" ] && [ -f "$tp" ]; then
            if command -v jq >/dev/null 2>&1; then
              m=$(tail -n 200 "$tp" 2>/dev/null | jq -rs '[.[]? | select(.type=="assistant") | .message.model // empty | select(startswith("<") | not)] | last // empty' 2>/dev/null || true)
            else
              m=$(tail -n 200 "$tp" 2>/dev/null | /usr/bin/perl -MJSON::PP -0777 -e '
                my $last = "";
                local $/;
                my $raw = <STDIN>;
                for my $line (split(/\\n/, $raw)) {
                  next unless length $line;
                  my $o = eval { decode_json($line) };
                  next unless $o && ref($o) eq "HASH" && ($o->{type} // "") eq "assistant";
                  my $model = "";
                  if (ref($o->{message}) eq "HASH") { $model = $o->{message}{model} // ""; }
                  next if $model eq "" || ref($model) || $model =~ /^</;
                  $last = $model;
                }
                print $last;
              ' 2>/dev/null || true)
            fi
          fi
          [ -n "$p" ] || return 0
          t=$(resolve_tty)
          printf "\\033]2;\\xe2\\x9d\\xaf\\xe2\\x81\\xa3 %s\\xe2\\x81\\xa3%s\\007" "$p" "$m" > "$t" 2>/dev/null || true
        }

        emit_model_sideband() {
          j="$1"
          m=$(printf "%s" "$j" | json_get model.id)
          if [ -z "$m" ]; then
            m=$(printf "%s" "$j" | json_get model.display_name)
          fi
          sid=$(printf "%s" "$j" | json_get session_id)
          c="${TMPDIR:-/tmp}/phanttom-model-${sid:-unknown}-${CLAUDE_PID:-$PPID}"
          if [ -n "$m" ] && [ "$(cat "$c" 2>/dev/null || true)" != "$m" ]; then
            printf "%s" "$m" > "$c" 2>/dev/null || true
            t=$(resolve_tty)
            printf "\\033]2;\\xe2\\x9d\\xaf\\xe2\\x81\\xa3\\xe2\\x81\\xa3%s\\007" "$m" > "$t" 2>/dev/null || true
          fi
        }

        read_original_statusline() {
          if [ -f "$STATE" ]; then
            if command -v jq >/dev/null 2>&1; then
              jq -r ".originalStatusLine // empty" < "$STATE" 2>/dev/null || true
            else
              /usr/bin/perl -MJSON::PP -0777 -e '
                my $j = eval { decode_json(do { local $/; <STDIN> }) };
                exit 0 unless $j && defined $j->{originalStatusLine} && !ref($j->{originalStatusLine});
                print $j->{originalStatusLine};
              ' < "$STATE" 2>/dev/null || true
            fi
          fi
        }

        default_statusline() {
          j="$1"
          name=$(printf "%s" "$j" | json_get model.display_name)
          if [ -z "$name" ]; then
            name=$(printf "%s" "$j" | json_get model.id)
          fi
          cwd=$(printf "%s" "$j" | json_get cwd)
          leaf=$(printf "%s" "$cwd" | sed "s|.*/||")
          if [ -n "$name" ] && [ -n "$leaf" ]; then
            printf "%s · %s\\n" "$name" "$leaf"
          elif [ -n "$name" ]; then
            printf "%s\\n" "$name"
          elif [ -n "$leaf" ]; then
            printf "%s\\n" "$leaf"
          fi
        }

        cmd="${1:-}"
        case "$cmd" in
          prompt-submit)
            j=$(cat)
            emit_osc74 3
            emit_prompt_title "$j"
            printf "%s" "$j" | emit_osc7
            ;;
          session-start|post-tool-use)
            j=$(cat)
            printf "%s" "$j" | emit_osc7
            ;;
          stop)
            emit_osc74 0
            ;;
          notification)
            t=$(resolve_tty)
            printf "\\033]9;4;0;0\\033\\\\\\007" > "$t" 2>/dev/null || true
            ;;
          statusline)
            j=$(cat)
            emit_model_sideband "$j"
            orig=$(read_original_statusline)
            if [ -n "$orig" ]; then
              printf "%s" "$j" | sh -c "$orig"
            else
              default_statusline "$j"
            fi
            ;;
          *)
            echo "phanttom-hook: unknown command: $cmd" >&2
            exit 1
            ;;
        esac
        """
    }

    // MARK: - Ownership

    /// Substrings that identify the 2026-07 hand-installed inline hooks so
    /// install/update can remove them. After JSON parse, shell `\xNN` escapes
    /// remain as literal backslash-x sequences in the command string.
    nonisolated static let legacySignatures: [String] = [
        "]9;4;",
        "]7;file://localhost",
        "\\xe2\\x9d\\xaf\\xe2\\x81\\xa3",
        "statusline-phanttom.sh",
    ]

    nonisolated static func isOurs(command: String) -> Bool {
        if command.contains(hookScriptName) { return true }
        for sig in legacySignatures where command.contains(sig) {
            return true
        }
        return false
    }

    nonisolated static func isLegacy(command: String) -> Bool {
        !command.contains(hookScriptName) && isOurs(command: command)
    }

    // MARK: - Pure merge core (no I/O)

    nonisolated static func install(into settings: [String: Any]) -> [String: Any] {
        var result = deepCopy(settings)
        var hooksObj = (result["hooks"] as? [String: Any]) ?? [:]

        for (event, value) in hooksObj {
            guard var entries = asEntryArray(value) else { continue }
            entries.removeAll { entry in
                commands(in: entry).contains(where: isOurs(command:))
            }
            if entries.isEmpty {
                hooksObj.removeValue(forKey: event)
            } else {
                hooksObj[event] = entries
            }
        }

        for desired in desiredHooks {
            var entries = asEntryArray(hooksObj[desired.event] as Any?) ?? []
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
        }
        result["statusLine"] = desiredStatusLine as [String: Any]

        return result
    }

    nonisolated static func uninstall(from settings: [String: Any]) -> [String: Any] {
        var result = deepCopy(settings)

        if var hooksObj = result["hooks"] as? [String: Any] {
            for (event, value) in hooksObj {
                guard var entries = asEntryArray(value) else { continue }
                entries.removeAll { entry in
                    commands(in: entry).contains(where: isOurs(command:))
                }
                if entries.isEmpty {
                    hooksObj.removeValue(forKey: event)
                } else {
                    hooksObj[event] = entries
                }
            }
            if hooksObj.isEmpty {
                result.removeValue(forKey: "hooks")
            } else {
                result["hooks"] = hooksObj
            }
        }

        if let stashed = result[originalStatusLineKey] as? String {
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

        return result
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
        let hasDispatch = desiredHooks.allSatisfy { desired in
            guard let entries = asEntryArray(hooksObj[desired.event] as Any?) else {
                return false
            }
            return entries.contains { entry in
                commands(in: entry).contains(desired.command)
            }
        } && ((settings["statusLine"] as? [String: Any])?["command"] as? String)
            .map { $0.contains(hookScriptName) } ?? false

        if hasDispatch {
            let installed = parseScriptVersion(scriptText)
            if let installed, installed >= payloadVersion {
                return .installedCurrent
            }
            return .installedOutdated(installedVersion: installed ?? 0)
        }
        if hasLegacy {
            return .legacyInline
        }
        return .notInstalled
    }

    nonisolated static func parseScriptVersion(_ text: String?) -> Int? {
        guard let text else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# phanttom-hook v") else { continue }
            let suffix = trimmed.dropFirst("# phanttom-hook v".count)
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

    // MARK: - File I/O

    struct Paths {
        let baseDir: URL
        var settings: URL { baseDir.appendingPathComponent(settingsFileName) }
        var script: URL { baseDir.appendingPathComponent(hookScriptName) }
        var state: URL { baseDir.appendingPathComponent(stateFileName) }

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

    nonisolated static func claudeDirectoryExists(paths: Paths = .default) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: paths.baseDir.path, isDirectory: &isDir) && isDir.boolValue
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
            return try mutateSettings(paths: paths, uninstalling: false)
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
            return try mutateSettings(paths: paths, uninstalling: true)
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
        case .settingsUnreadable:
            return "Could not read settings.json"
        case .settingsCorrupt:
            return "settings.json is not valid JSON — aborted without changes"
        case .writeFailed(let detail):
            return "Write failed: \(detail)"
        }
    }

    nonisolated private static func mutateSettings(
        paths: Paths,
        uninstalling: Bool
    ) throws -> ActionResult {
        guard claudeDirectoryExists(paths: paths) else {
            throw ActionError.claudeNotFound
        }

        let fm = FileManager.default
        var settings: [String: Any]
        let settingsExisted = fm.fileExists(atPath: paths.settings.path)
        if settingsExisted {
            do {
                settings = try readSettings(at: paths.settings)
            } catch {
                throw ActionError.settingsCorrupt
            }
            try backupSettings(at: paths.settings)
        } else if uninstalling {
            try? fm.removeItem(at: paths.script)
            try? fm.removeItem(at: paths.state)
            removeLegacyStatuslineScript(paths: paths)
            return currentStatus(paths: paths)
        } else {
            settings = [:]
        }

        // Legacy statusline wrapper is "ours", so the pure merge won't stash
        // the user's real statusline. Recover the known chain target when
        // migrating the hand-installed 2026-07 setup.
        if !uninstalling {
            settings = prepareLegacyStatuslineStash(settings, paths: paths)
        }

        let next = uninstalling ? uninstall(from: settings) : install(into: settings)
        try writeSettings(next, to: paths.settings)

        if uninstalling {
            try? fm.removeItem(at: paths.script)
            try? fm.removeItem(at: paths.state)
            removeLegacyStatuslineScript(paths: paths)
        } else {
            try writeScript(paths: paths)
            try writeState(paths: paths, settings: next)
            removeLegacyStatuslineScript(paths: paths)
        }

        return currentStatus(paths: paths)
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

    nonisolated static func readSettings(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw ActionError.settingsCorrupt
        }
        return dict
    }

    nonisolated static func writeSettings(_ settings: [String: Any], to url: URL) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw ActionError.writeFailed(error.localizedDescription)
        }
        guard let check = try? JSONSerialization.jsonObject(with: data),
              check is [String: Any]
        else {
            throw ActionError.writeFailed("serialized settings failed re-parse")
        }
        var payload = data
        payload.append(contentsOf: "\n".utf8)
        do {
            try payload.write(to: url, options: .atomic)
        } catch {
            throw ActionError.writeFailed(error.localizedDescription)
        }
    }

    nonisolated static func backupSettings(at settingsURL: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let dir = settingsURL.deletingLastPathComponent()
        // Same-second install→uninstall (or rapid Updates) must not collide.
        var backupURL = dir.appendingPathComponent(
            "settings.json.bak-phanttom-\(stamp)")
        var n = 2
        while fm.fileExists(atPath: backupURL.path) {
            backupURL = dir.appendingPathComponent(
                "settings.json.bak-phanttom-\(stamp)-\(n)")
            n += 1
        }
        try fm.copyItem(at: settingsURL, to: backupURL)
        pruneBackups(in: dir, keeping: 5)
    }

    nonisolated static func pruneBackups(in directory: URL, keeping max: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let backups = items.filter {
            $0.lastPathComponent.hasPrefix("settings.json.bak-phanttom-")
        }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return da > db
        }
        for url in backups.dropFirst(max) {
            try? fm.removeItem(at: url)
        }
    }

    nonisolated private static func writeScript(paths: Paths) throws {
        let data = Data(hookScript.utf8)
        try data.write(to: paths.script, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: paths.script.path
        )
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

    nonisolated private static func deepCopy(_ settings: [String: Any]) -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(settings),
              let data = try? JSONSerialization.data(withJSONObject: settings),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return settings
        }
        return obj
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
