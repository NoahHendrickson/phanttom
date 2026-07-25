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
    /// v2 (privacy hardening, mirroring Claude's v7): emit only when the
    /// session is running in a Ghostty/Phanttom terminal — `~/.cursor/hooks.json`
    /// is read by every Cursor Agent session on the machine — and move the
    /// per-session model cache out of `${TMPDIR:-/tmp}` (world-writable and
    /// guessable with TMPDIR unset) into a 0700 directory under `~/.cursor`.
    static let payloadVersion = 2

    static let hookScriptName = "phanttom-hook.sh"
    static let stateFileName = "phanttom-integration.json"
    static let hooksFileName = "hooks.json"
    static let cliConfigFileName = "cli-config.json"
    static let hooksBackupPrefix = "hooks.json.bak-phanttom-"
    static let cliConfigBackupPrefix = "cli-config.json.bak-phanttom-"

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
        /// The hook script's private 0700 scratch directory — see
        /// `PhanttomIntegrationSupport.sessionStateDirName`.
        var sessionState: URL {
            baseDir.appendingPathComponent(
                PhanttomIntegrationSupport.sessionStateDirName)
        }

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

    /// Whether the user has already answered the "install these hooks?"
    /// question for this `~/.cursor`. Shared across builds, like the opt-out
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
                try backupFile(at: paths.hooks, prefix: hooksBackupPrefix)
            }
            try writeJSONObject(nextHooks, to: paths.hooks)
        }
        if !cliExists || !jsonEqual(plan.cliConfig, onDiskCli) {
            if cliExists {
                try backupFile(at: paths.cliConfig, prefix: cliConfigBackupPrefix)
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
            try backupFile(at: paths.hooks, prefix: hooksBackupPrefix)
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
            try backupFile(at: paths.cliConfig, prefix: cliConfigBackupPrefix)
            let next = uninstallStatusLine(
                from: cliConfig,
                originalCommand: originalCmd,
                originalObject: originalObj
            )
            try writeJSONObject(next, to: paths.cliConfig)
        }

        try? fm.removeItem(at: paths.script)
        try? fm.removeItem(at: paths.state)
        // Private per-session scratch: nothing else reads it, and it names the
        // sessions that ran.
        try? fm.removeItem(at: paths.sessionState)
        // Only now that both configs are back to their pre-Phanttom shape:
        // keeping the snapshots past that point means a credential the user
        // has since deleted survives in a file we created without telling
        // them.
        PhanttomIntegrationSupport.removeBackups(
            in: paths.baseDir, prefix: hooksBackupPrefix)
        PhanttomIntegrationSupport.removeBackups(
            in: paths.baseDir, prefix: cliConfigBackupPrefix)

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
