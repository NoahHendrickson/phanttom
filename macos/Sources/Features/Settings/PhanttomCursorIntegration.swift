import Foundation
import GhosttyKit

/// Installs / updates / removes Phanttom's Cursor Agent CLI hooks +
/// statusline wrapper under `~/.cursor/`.
///
/// Cursor splits config across two files:
/// - `hooks.json` — lifecycle hooks (`sessionStart`, `preToolUse`, …)
/// - `cli-config.json` — `statusLine` command (often absent until we add it)
///
/// Payload is embedded as Swift string constants (same pattern as
/// `PhanttomClaudeIntegration`) so it versions with the app and is
/// unit-testable. JSON is read-modify-written with `JSONSerialization`
/// dictionaries so unknown keys round-trip.
enum PhanttomCursorIntegration {
    /// Bump on any change to `hookScript` text or `desiredHooks` /
    /// `desiredStatusLine`. Drives the Settings "Update available" state.
    static let payloadVersion = 1

    static let hookScriptName = "phanttom-hook.sh"
    static let stateFileName = "phanttom-integration.json"
    static let hooksFileName = "hooks.json"
    static let cliConfigFileName = "cli-config.json"

    // MARK: - Status

    enum IntegrationStatus: Equatable {
        case notInstalled
        case installedCurrent
        case installedOutdated(installedVersion: Int)
    }

    enum ActionError: Error, Equatable {
        case cursorNotFound
        case hooksCorrupt
        case cliConfigCorrupt
        case writeFailed(String)
    }

    // MARK: - Desired state

    /// Cursor Agent CLI hook events (camelCase). Flat `{ "command": ... }`
    /// entries — not Claude Code's nested matcher/`hooks` array shape.
    ///
    /// `beforeSubmitPrompt` is intentionally omitted until confirmed to fire
    /// on interactive CLI sessions (print-mode spikes did not see it).
    static let desiredHooks: [(event: String, command: String)] = [
        ("sessionStart", dispatch("session-start")),
        ("preToolUse", dispatch("pre-tool-use")),
        ("afterAgentThought", dispatch("model-update")),
        ("postToolUse", dispatch("model-update")),
        ("stop", dispatch("stop")),
    ]

    static let desiredStatusLine: [String: String] = [
        "type": "command",
        "command": dispatch("statusline"),
    ]

    nonisolated private static func dispatch(_ subcommand: String) -> String {
        "sh \"$HOME/.cursor/\(hookScriptName)\" \(subcommand)"
    }

    /// Versioned helper installed at `~/.cursor/phanttom-hook.sh`.
    ///
    /// Any edit to this text must bump `payloadVersion`.
    static var hookScript: String {
        """
        #!/bin/sh
        # phanttom-hook v\(payloadVersion)
        # Managed by Phanttom — do not edit; overwritten on Update.
        # No `set -e`: hook processes must never fail the Cursor Agent call.

        STATE="${HOME}/.cursor/phanttom-integration.json"

        # IDE Agent Chat shares ~/.cursor/hooks.json but does not set this.
        if [ "${CURSOR_AGENT:-}" != "1" ]; then
          case "${1:-}" in
            session-start) printf '%s\\n' '{}' ;;
            *) printf '%s\\n' '{}' ;;
          esac
          exit 0
        fi

        resolve_tty() {
          # Prefer path stashed by session-start (env injection).
          if [ -n "${PHANTTOM_TTY:-}" ] && [ -e "${PHANTTOM_TTY}" ]; then
            printf "%s" "${PHANTTOM_TTY}"
            return 0
          fi
          # Hook processes themselves often have no controlling tty (`??`).
          # Walk ancestors for a real pty — never fall back to bare /dev/tty
          # (that path is known-broken for hooks and can hit the wrong device
          # when IDE hooks somehow slip through).
          p=${PPID}
          i=0
          while [ "$i" -lt 12 ] && [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ]; do
            t=$(ps -o tty= -p "$p" 2>/dev/null | tr -d " ")
            case "$t" in
              ""|"?"|"??") ;;
              *) printf "/dev/%s" "$t"; return 0 ;;
            esac
            p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d " ")
            i=$((i + 1))
          done
          printf ""
        }

        json_get() {
          path="$1"
          if command -v jq >/dev/null 2>&1; then
            case "$path" in
              model) jq -r ".model // empty" 2>/dev/null ;;
              model_id) jq -r ".model_id // empty" 2>/dev/null ;;
              model.id) jq -r ".model.id // empty" 2>/dev/null ;;
              model.display_name) jq -r ".model.display_name // empty" 2>/dev/null ;;
              prompt) jq -r ".prompt // empty" 2>/dev/null ;;
              cwd) jq -r ".cwd // empty" 2>/dev/null ;;
              session_id) jq -r ".session_id // .conversation_id // empty" 2>/dev/null ;;
              workspace_roots.0) jq -r ".workspace_roots[0] // empty" 2>/dev/null ;;
              *) jq -r ".$path // empty" 2>/dev/null ;;
            esac
          else
            /usr/bin/perl -MJSON::PP -0777 -e '
              my $path = shift @ARGV;
              my $raw = do { local $/; <STDIN> };
              my $j = eval { decode_json($raw) };
              exit 0 unless $j;
              if ($path eq "workspace_roots.0") {
                my $wr = $j->{workspace_roots};
                exit 0 unless ref($wr) eq "ARRAY" && @$wr;
                my $v = $wr->[0];
                exit 0 if !defined $v || ref($v);
                print $v;
                exit 0;
              }
              if ($path eq "session_id") {
                for my $k (qw(session_id conversation_id)) {
                  next unless defined $j->{$k} && !ref($j->{$k});
                  print $j->{$k};
                  exit 0;
                }
                exit 0;
              }
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

        uri_encode_path() {
          p="$1"
          if command -v jq >/dev/null 2>&1; then
            printf "%s" "$p" | jq -Rr "@uri" 2>/dev/null | sed "s|%2F|/|g"
          else
            printf "%s" "$p" | /usr/bin/perl -0777 -e '
              my $s = do { local $/; <STDIN> };
              utf8::encode($s);
              $s =~ s/([^A-Za-z0-9\\-_.~\\/])/sprintf("%%%02X", ord($1))/ge;
              $s =~ s/%2F/\\//gi;
              print $s;
            ' 2>/dev/null
          fi
        }

        resolve_cwd() {
          j="$1"
          d=$(printf "%s" "$j" | json_get cwd)
          case "$d" in ""|"."|"null") d="" ;; esac
          if [ -z "$d" ]; then
            d=$(printf "%s" "$j" | json_get workspace_roots.0)
          fi
          if [ -z "$d" ]; then
            d="${CURSOR_PROJECT_DIR:-}"
          fi
          printf "%s" "$d"
        }

        emit_osc74() {
          t=$(resolve_tty)
          [ -n "$t" ] || return 0
          printf "\\033]9;4;%s;0\\033\\\\" "$1" > "$t" 2>/dev/null || true
        }

        emit_osc7_path() {
          d="$1"
          [ -n "$d" ] || return 0
          enc=$(uri_encode_path "$d")
          [ -n "$enc" ] || return 0
          t=$(resolve_tty)
          [ -n "$t" ] || return 0
          printf "\\033]7;file://localhost%s\\033\\\\" "$enc" > "$t" 2>/dev/null || true
        }

        pick_model() {
          j="$1"
          m=$(printf "%s" "$j" | json_get model_id)
          if [ -z "$m" ]; then
            m=$(printf "%s" "$j" | json_get model.id)
          fi
          if [ -z "$m" ]; then
            m=$(printf "%s" "$j" | json_get model.display_name)
          fi
          if [ -z "$m" ]; then
            m=$(printf "%s" "$j" | json_get model)
          fi
          # Skip nested/object leftovers that slipped through as the literal
          # string "null".
          case "$m" in ""|"null") m="" ;; esac
          printf "%s" "$m" | LC_ALL=C tr -d "[:cntrl:]"
        }

        # Model-only marker: ❯⁣.cursor⁣⁣<model>
        emit_model_marker() {
          m="$1"
          [ -n "$m" ] || return 0
          sid="$2"
          c="${TMPDIR:-/tmp}/phanttom-cursor-model-${sid:-unknown}-$$"
          # Prefer stable cache key when session id is known.
          if [ -n "$sid" ]; then
            c="${TMPDIR:-/tmp}/phanttom-cursor-model-${sid}"
          fi
          if [ "$(cat "$c" 2>/dev/null || true)" = "$m" ]; then
            return 0
          fi
          # Resolve the tty BEFORE recording the model as emitted. Caching
          # first would mark this model delivered even when there was no tty
          # to write to, and every later hook would then skip the marker —
          # the badge would never appear for the rest of the session.
          t=$(resolve_tty)
          [ -n "$t" ] || return 0
          printf "%s" "$m" > "$c" 2>/dev/null || true
          printf "\\033]2;\\xe2\\x9d\\xaf\\xe2\\x81\\xa3.cursor\\xe2\\x81\\xa3\\xe2\\x81\\xa3%s\\007" "$m" > "$t" 2>/dev/null || true
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
          name=$(pick_model "$j")
          cwd=$(resolve_cwd "$j")
          leaf=$(printf "%s" "$cwd" | sed "s|.*/||")
          if [ -n "$name" ] && [ -n "$leaf" ]; then
            printf "%s · %s\\n" "$name" "$leaf"
          elif [ -n "$name" ]; then
            printf "%s\\n" "$name"
          elif [ -n "$leaf" ]; then
            printf "%s\\n" "$leaf"
          fi
        }

        respond_empty() { printf '%s\\n' '{}'; }

        cmd="${1:-}"
        case "$cmd" in
          session-start)
            j=$(cat)
            m=$(pick_model "$j")
            sid=$(printf "%s" "$j" | json_get session_id)
            d=$(resolve_cwd "$j")
            tty=$(resolve_tty)
            emit_model_marker "$m" "$sid"
            emit_osc7_path "$d"
            # Stash tty for later hooks via sessionStart env injection.
            if [ -n "$tty" ]; then
              if command -v jq >/dev/null 2>&1; then
                jq -n --arg t "$tty" '{env:{PHANTTOM_TTY:$t}}'
              else
                /usr/bin/perl -MJSON::PP -e '
                  print encode_json({ env => { PHANTTOM_TTY => $ARGV[0] } });
                ' "$tty"
                printf '\\n'
              fi
            else
              respond_empty
            fi
            ;;
          pre-tool-use)
            j=$(cat)
            emit_osc74 3
            m=$(pick_model "$j")
            sid=$(printf "%s" "$j" | json_get session_id)
            emit_model_marker "$m" "$sid"
            d=$(resolve_cwd "$j")
            emit_osc7_path "$d"
            respond_empty
            ;;
          model-update)
            j=$(cat)
            m=$(pick_model "$j")
            sid=$(printf "%s" "$j" | json_get session_id)
            emit_model_marker "$m" "$sid"
            respond_empty
            ;;
          stop)
            # Always clear — Cursor stop has no Claude-style background_tasks.
            cat >/dev/null
            emit_osc74 0
            respond_empty
            ;;
          statusline)
            j=$(cat)
            m=$(pick_model "$j")
            sid=$(printf "%s" "$j" | json_get session_id)
            emit_model_marker "$m" "$sid"
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

    nonisolated static func isOurs(command: String) -> Bool {
        command.contains(hookScriptName)
    }

    // MARK: - Pure merge core (hooks.json)

    /// Strip phanttom-owned flat hook commands; drop empty events (and
    /// `hooks` itself when empty, unless `keepEmptyHooksObject`).
    nonisolated static func removeOwnedHooks(
        from hooksDoc: [String: Any],
        keepEmptyHooksObject: Bool = false
    ) -> [String: Any] {
        var result = deepCopy(hooksDoc)
        guard var hooksObj = result["hooks"] as? [String: Any] else { return result }

        for (event, value) in hooksObj {
            // Iterate the ORIGINAL array so foreign non-object elements
            // (stray strings/numbers) round-trip untouched — `asCommandArray`
            // compactMaps them away, which would silently delete user data.
            // Only Phanttom-owned command entries are removed.
            guard let elements = value as? [Any] else { continue }
            let kept = elements.filter { element in
                guard let entry = element as? [String: Any],
                      let cmd = entry["command"] as? String
                else { return true }
                return !isOurs(command: cmd)
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

    nonisolated static func installHooks(into hooksDoc: [String: Any]) -> [String: Any] {
        var result = removeOwnedHooks(from: hooksDoc, keepEmptyHooksObject: true)
        if result["version"] == nil {
            result["version"] = 1
        }
        var hooksObj = (result["hooks"] as? [String: Any]) ?? [:]

        for desired in desiredHooks {
            let existing = hooksObj[desired.event]
            // Append to the ORIGINAL array so foreign entries (objects we
            // don't own AND non-object elements) survive. A non-array value
            // at a hooks event is invalid per Cursor's schema and can't be
            // merged; replacing it with a fresh array is the only way to
            // install our dispatch. Skipping it would leave
            // `hasCompleteDispatch` permanently false — and because
            // auto-sync installs on every launch, that means reinstalling
            // (and backing up both config files) forever.
            var entries: [Any] = (existing as? [Any]) ?? []
            entries.append(["command": desired.command] as [String: Any])
            hooksObj[desired.event] = entries
        }
        result["hooks"] = hooksObj
        return result
    }

    nonisolated static func uninstallHooks(from hooksDoc: [String: Any]) -> [String: Any] {
        removeOwnedHooks(from: hooksDoc)
    }

    // MARK: - Pure merge core (cli-config.json statusLine)

    struct StatusLinePlan {
        let cliConfig: [String: Any]
        /// Command string to stash in phanttom-integration.json (empty if none).
        let originalStatusLineCommand: String?
        /// Full original statusLine object for lossless restore.
        let originalStatusLineObject: [String: Any]?
    }

    nonisolated static func installStatusLine(
        into cliConfig: [String: Any],
        priorOriginalCommand: String?,
        priorOriginalObject: [String: Any]?
    ) -> StatusLinePlan {
        var result = deepCopy(cliConfig)
        if result["version"] == nil {
            result["version"] = 1
        }

        var originalCmd = priorOriginalCommand
        var originalObj = priorOriginalObject

        if let existing = result["statusLine"] as? [String: Any],
           let cmd = existing["command"] as? String,
           !isOurs(command: cmd) {
            if originalCmd == nil {
                originalCmd = cmd
                originalObj = existing
            }
        }

        result["statusLine"] = desiredStatusLine as [String: Any]
        return StatusLinePlan(
            cliConfig: result,
            originalStatusLineCommand: originalCmd,
            originalStatusLineObject: originalObj
        )
    }

    nonisolated static func uninstallStatusLine(
        from cliConfig: [String: Any],
        originalCommand: String?,
        originalObject: [String: Any]?
    ) -> [String: Any] {
        var result = deepCopy(cliConfig)
        if let originalObject {
            result["statusLine"] = originalObject
        } else if let originalCommand {
            result["statusLine"] = [
                "type": "command",
                "command": originalCommand,
            ] as [String: Any]
        } else if let existing = result["statusLine"] as? [String: Any],
                  let cmd = existing["command"] as? String,
                  isOurs(command: cmd) {
            result.removeValue(forKey: "statusLine")
        }
        return result
    }

    nonisolated static func hasCompleteDispatch(
        in hooksDoc: [String: Any],
        cliConfig: [String: Any]
    ) -> Bool {
        let hooksObj = hooksDoc["hooks"] as? [String: Any] ?? [:]
        let hooksComplete = desiredHooks.allSatisfy { desired in
            guard let entries = asCommandArray(hooksObj[desired.event]) else {
                return false
            }
            return entries.contains { ($0["command"] as? String) == desired.command }
        }
        let statusCmd = (cliConfig["statusLine"] as? [String: Any])?["command"] as? String
        let statuslineOurs = statusCmd?.contains(hookScriptName) == true
        return hooksComplete && statuslineOurs
    }

    nonisolated static func hasPartialDispatch(
        in hooksDoc: [String: Any],
        cliConfig: [String: Any]
    ) -> Bool {
        let hooksObj = hooksDoc["hooks"] as? [String: Any] ?? [:]
        let anyHook = desiredHooks.contains { desired in
            guard let entries = asCommandArray(hooksObj[desired.event]) else {
                return false
            }
            return entries.contains {
                ($0["command"] as? String)?.contains(hookScriptName) == true
            }
        }
        let statusCmd = (cliConfig["statusLine"] as? [String: Any])?["command"] as? String
        let statuslineOurs = statusCmd?.contains(hookScriptName) == true
        return anyHook || statuslineOurs
    }

    nonisolated static func status(
        of hooksDoc: [String: Any],
        cliConfig: [String: Any],
        scriptText: String?
    ) -> IntegrationStatus {
        if hasCompleteDispatch(in: hooksDoc, cliConfig: cliConfig) {
            let installed = parseScriptVersion(scriptText)
            if let installed, installed >= payloadVersion {
                return .installedCurrent
            }
            return .installedOutdated(installedVersion: installed ?? 0)
        }
        if hasPartialDispatch(in: hooksDoc, cliConfig: cliConfig) {
            return .installedOutdated(installedVersion: parseScriptVersion(scriptText) ?? 0)
        }
        return .notInstalled
    }

    nonisolated static func parseScriptVersion(_ text: String?) -> Int? {
        PhanttomIntegrationSupport.parseScriptVersion(text)
    }

    // MARK: - File I/O

    struct Paths {
        let baseDir: URL
        var hooks: URL { baseDir.appendingPathComponent(hooksFileName) }
        var cliConfig: URL { baseDir.appendingPathComponent(cliConfigFileName) }
        var script: URL { baseDir.appendingPathComponent(hookScriptName) }
        var state: URL { baseDir.appendingPathComponent(stateFileName) }

        static var `default`: Paths {
            Paths(baseDir: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cursor"))
        }
    }

    struct ActionResult {
        let status: IntegrationStatus
        let error: ActionError?
        let message: String
    }

    // MARK: - Auto-install opt-out

    /// Whether an explicit Remove… has switched launch-time auto-install off.
    /// Shared across builds — see
    /// `PhanttomIntegrationSupport.optOutFileName`.
    nonisolated static func isAutoInstallDisabled(paths: Paths = .default) -> Bool {
        PhanttomIntegrationSupport.isAutoInstallDisabled(in: paths.baseDir)
    }

    /// Record (or lift) the opt-out. Writing is best-effort: if `~/.cursor`
    /// is missing there is nothing to auto-install into anyway, and the next
    /// Remove… once it exists will record the decision.
    nonisolated static func setAutoInstallDisabled(
        _ disabled: Bool,
        paths: Paths = .default
    ) {
        PhanttomIntegrationSupport.setAutoInstallDisabled(disabled, in: paths.baseDir)
    }

    nonisolated static func cursorDirectoryExists(paths: Paths = .default) -> Bool {
        PhanttomIntegrationSupport.directoryExists(at: paths.baseDir)
    }

    nonisolated static func currentStatus(paths: Paths = .default) -> ActionResult {
        guard cursorDirectoryExists(paths: paths) else {
            return ActionResult(
                status: .notInstalled,
                error: .cursorNotFound,
                message: "Cursor Agent not found (~/.cursor missing)"
            )
        }

        let hooksDoc: [String: Any]
        do {
            hooksDoc = try readJSONObject(at: paths.hooks, absentAsEmpty: true)
        } catch {
            return ActionResult(
                status: .notInstalled,
                error: .hooksCorrupt,
                message: "Could not read hooks.json — fix or restore a backup before continuing"
            )
        }

        let cliConfig: [String: Any]
        do {
            cliConfig = try readJSONObject(at: paths.cliConfig, absentAsEmpty: true)
        } catch {
            return ActionResult(
                status: .notInstalled,
                error: .cliConfigCorrupt,
                message: "Could not read cli-config.json — fix or restore a backup before continuing"
            )
        }

        let scriptText = try? String(contentsOf: paths.script, encoding: .utf8)
        let st = status(of: hooksDoc, cliConfig: cliConfig, scriptText: scriptText)
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
        }
    }

    @discardableResult
    nonisolated static func performInstall(paths: Paths = .default) -> ActionResult {
        do {
            return try applyInstall(paths: paths)
        } catch let err as ActionError {
            Ghostty.logger.warning(
                "phanttom cursor integration: install failed: \(errorMessage(err))"
            )
            return ActionResult(
                status: currentStatus(paths: paths).status,
                error: err,
                message: errorMessage(err)
            )
        } catch {
            Ghostty.logger.warning(
                "phanttom cursor integration: install failed: \(error)"
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
                "phanttom cursor integration: uninstall failed: \(errorMessage(err))"
            )
            return ActionResult(
                status: currentStatus(paths: paths).status,
                error: err,
                message: errorMessage(err)
            )
        } catch {
            Ghostty.logger.warning(
                "phanttom cursor integration: uninstall failed: \(error)"
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
        case .cursorNotFound:
            return "Cursor Agent not found (~/.cursor missing)"
        case .hooksCorrupt:
            return "hooks.json is not valid JSON — aborted without changes"
        case .cliConfigCorrupt:
            return "cli-config.json is not valid JSON — aborted without changes"
        case .writeFailed(let detail):
            return "Write failed: \(detail)"
        }
    }

    nonisolated private static func applyInstall(paths: Paths) throws -> ActionResult {
        guard cursorDirectoryExists(paths: paths) else {
            throw ActionError.cursorNotFound
        }

        let fm = FileManager.default
        let hooksExists = fm.fileExists(atPath: paths.hooks.path)
        let cliExists = fm.fileExists(atPath: paths.cliConfig.path)

        let onDiskHooks: [String: Any]
        do {
            onDiskHooks = try readJSONObject(at: paths.hooks, absentAsEmpty: true)
        } catch {
            throw ActionError.hooksCorrupt
        }
        let onDiskCli: [String: Any]
        do {
            onDiskCli = try readJSONObject(at: paths.cliConfig, absentAsEmpty: true)
        } catch {
            throw ActionError.cliConfigCorrupt
        }

        let priorState = (try? readState(at: paths.state)) ?? [:]
        let priorOriginalCmd = priorState["originalStatusLine"] as? String
        let priorOriginalObj = priorState["originalStatusLineObject"] as? [String: Any]

        let nextHooks = installHooks(into: onDiskHooks)
        let plan = installStatusLine(
            into: onDiskCli,
            priorOriginalCommand: priorOriginalCmd,
            priorOriginalObject: priorOriginalObj
        )

        try writeScript(paths: paths)
        try writeState(
            paths: paths,
            originalCommand: plan.originalStatusLineCommand,
            originalObject: plan.originalStatusLineObject
        )

        if !hooksExists || !jsonEqual(nextHooks, onDiskHooks) {
            if hooksExists {
                try backupFile(at: paths.hooks, prefix: "hooks.json.bak-phanttom-")
            }
            try writeJSONObject(nextHooks, to: paths.hooks)
        }
        if !cliExists || !jsonEqual(plan.cliConfig, onDiskCli) {
            if cliExists {
                try backupFile(at: paths.cliConfig, prefix: "cli-config.json.bak-phanttom-")
            }
            try writeJSONObject(plan.cliConfig, to: paths.cliConfig)
        }

        return currentStatus(paths: paths)
    }

    nonisolated private static func applyUninstall(paths: Paths) throws -> ActionResult {
        guard cursorDirectoryExists(paths: paths) else {
            throw ActionError.cursorNotFound
        }

        let fm = FileManager.default
        let priorState = (try? readState(at: paths.state)) ?? [:]
        let originalCmd = priorState["originalStatusLine"] as? String
        let originalObj = priorState["originalStatusLineObject"] as? [String: Any]

        if fm.fileExists(atPath: paths.hooks.path) {
            let hooksDoc: [String: Any]
            do {
                hooksDoc = try readJSONObject(at: paths.hooks, absentAsEmpty: false)
            } catch {
                throw ActionError.hooksCorrupt
            }
            try backupFile(at: paths.hooks, prefix: "hooks.json.bak-phanttom-")
            let next = uninstallHooks(from: hooksDoc)
            try writeJSONObject(next, to: paths.hooks)
        }

        if fm.fileExists(atPath: paths.cliConfig.path) {
            let cliConfig: [String: Any]
            do {
                cliConfig = try readJSONObject(at: paths.cliConfig, absentAsEmpty: false)
            } catch {
                throw ActionError.cliConfigCorrupt
            }
            try backupFile(at: paths.cliConfig, prefix: "cli-config.json.bak-phanttom-")
            let next = uninstallStatusLine(
                from: cliConfig,
                originalCommand: originalCmd,
                originalObject: originalObj
            )
            try writeJSONObject(next, to: paths.cliConfig)
        }

        try? fm.removeItem(at: paths.script)
        try? fm.removeItem(at: paths.state)

        return currentStatus(paths: paths)
    }

    nonisolated static func readJSONObject(
        at url: URL,
        absentAsEmpty: Bool
    ) throws -> [String: Any] {
        do {
            return try PhanttomIntegrationSupport.readJSONObject(
                at: url, absentAsEmpty: absentAsEmpty)
        } catch let err as PhanttomIntegrationSupport.IOError {
            throw ActionError.writeFailed(detail(err))
        }
    }

    nonisolated static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        do {
            try PhanttomIntegrationSupport.writeJSONObject(object, to: url)
        } catch let err as PhanttomIntegrationSupport.IOError {
            throw ActionError.writeFailed(detail(err))
        }
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

    nonisolated static func backupFile(at url: URL, prefix: String) throws {
        try PhanttomIntegrationSupport.backupFile(at: url, prefix: prefix)
    }

    nonisolated static func pruneBackups(in directory: URL, prefix: String, keeping max: Int) {
        PhanttomIntegrationSupport.pruneBackups(
            in: directory, prefix: prefix, keeping: max)
    }

    nonisolated private static func writeScript(paths: Paths) throws {
        try PhanttomIntegrationSupport.writeScript(hookScript, to: paths.script)
    }

    nonisolated private static func writeState(
        paths: Paths,
        originalCommand: String?,
        originalObject: [String: Any]?
    ) throws {
        var state: [String: Any] = [
            "version": payloadVersion,
            "originalStatusLine": originalCommand ?? "",
        ]
        if let originalObject {
            state["originalStatusLineObject"] = originalObject
        }
        try writeJSONObject(state, to: paths.state)
    }

    nonisolated private static func readState(at url: URL) throws -> [String: Any] {
        try readJSONObject(at: url, absentAsEmpty: false)
    }

    // MARK: - Dictionary helpers

    nonisolated private static func jsonEqual(
        _ a: [String: Any], _ b: [String: Any]
    ) -> Bool {
        PhanttomIntegrationSupport.jsonEqual(a, b)
    }

    nonisolated private static func deepCopy(_ object: [String: Any]) -> [String: Any] {
        PhanttomIntegrationSupport.deepCopy(object)
    }

    /// Cursor hooks.json events are flat arrays of `{ "command": "..." }`.
    nonisolated private static func asCommandArray(_ value: Any?) -> [[String: Any]]? {
        guard let value else { return nil }
        if let typed = value as? [[String: Any]] { return typed }
        guard let arr = value as? [Any] else { return nil }
        return arr.compactMap { $0 as? [String: Any] }
    }
}
