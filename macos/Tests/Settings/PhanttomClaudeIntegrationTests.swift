import Foundation
import Testing
@testable import Ghostty

/// Tests for the Claude Code integration merge engine and file I/O.
/// Pure merge tests never touch disk; I/O tests use an injected temp HOME.
@Suite
struct PhanttomClaudeIntegrationTests {
    // MARK: - Pure merge

    @Test func installIntoEmptySettings() {
        let result = PhanttomClaudeIntegration.install(into: [:])
        assertDesiredPresent(in: result)
        #expect(result[PhanttomClaudeIntegration.originalStatusLineKey] == nil)
    }

    @Test func installPreservesForeignHooksEventsAndUnknownKeys() {
        let foreignHook: [String: Any] = [
            "hooks": [
                ["type": "command", "command": "echo foreign-prompt"] as [String: Any],
            ] as [[String: Any]],
        ]
        let foreignEvent: [String: Any] = [
            "hooks": [
                ["type": "command", "command": "echo foreign-pre"] as [String: Any],
            ] as [[String: Any]],
        ]
        let input: [String: Any] = [
            "model": "sonnet",
            "theme": "dark",
            "nested": ["keep": true] as [String: Any],
            "hooks": [
                "UserPromptSubmit": [foreignHook] as [[String: Any]],
                "PreToolUse": [foreignEvent] as [[String: Any]],
            ] as [String: Any],
        ]

        let result = PhanttomClaudeIntegration.install(into: input)

        #expect(result["model"] as? String == "sonnet")
        #expect(result["theme"] as? String == "dark")
        #expect((result["nested"] as? [String: Any])?["keep"] as? Bool == true)

        let hooks = result["hooks"] as? [String: Any]
        let promptEntries = hooks?["UserPromptSubmit"] as? [[String: Any]] ?? []
        let promptCommands = promptEntries.flatMap(commands(in:))
        #expect(promptCommands.contains("echo foreign-prompt"))
        #expect(promptCommands.contains(where: { $0.contains("phanttom-hook.sh") }))

        let preEntries = hooks?["PreToolUse"] as? [[String: Any]] ?? []
        #expect(commands(in: preEntries[0]).contains("echo foreign-pre"))

        assertDesiredPresent(in: result)
    }

    @Test func installRemovesLegacyInlineHooks() {
        // Real 2026-07 / PR #15 shape: CLAUDE_PID tty resolve + OSC payload.
        let legacyRain =
            #"sh -c 't=$(ps -o tty= -p "${CLAUDE_PID:-0}" 2>/dev/null | tr -d " "); case "$t" in ""|"??") t=/dev/tty;; *) t=/dev/$t;; esac; printf "\033]9;4;3;0\033\\" > "$t" 2>/dev/null; true'"#
        let legacyTitle =
            #"sh -c 'printf "\xe2\x9d\xaf\xe2\x81\xa3 prompt\007"'"#
        let legacyCwd =
            #"sh -c 't=$(ps -o tty= -p "${CLAUDE_PID:-0}"); printf "\033]7;file://localhost/tmp\033\\" > "$t"; true'"#
        let input: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    entry(command: legacyRain),
                    entry(command: legacyTitle),
                    entry(command: legacyCwd),
                ] as [[String: Any]],
                "Stop": [entry(command: legacyRain.replacingOccurrences(
                    of: "]9;4;3;", with: "]9;4;0;"))] as [[String: Any]],
            ] as [String: Any],
            "statusLine": [
                "type": "command",
                "command": "sh \"$HOME/.claude/statusline-phanttom.sh\"",
            ] as [String: Any],
        ]

        let result = PhanttomClaudeIntegration.install(into: input)
        let hooks = result["hooks"] as? [String: Any] ?? [:]
        var all: [String] = []
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            all.append(contentsOf: entries.flatMap(commands(in:)))
        }
        #expect(!all.contains(where: { $0.contains("CLAUDE_PID") && !$0.contains("phanttom-hook.sh") }))
        #expect(!all.contains(where: { $0.contains("statusline-phanttom.sh") }))
        assertDesiredPresent(in: result)
        #expect(PhanttomClaudeIntegration.status(
            of: result, scriptText: PhanttomClaudeIntegration.hookScript
        ) == .installedCurrent)
    }

    @Test func foreignOscHooksSurviveInstallAndUninstall() {
        // Bare OSC 9;4 must NOT be treated as Phanttom-owned.
        let foreign =
            #"sh -c 'printf "\033]9;4;3;0\033\\" > /dev/tty'"#
        let input: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [entry(command: foreign)] as [[String: Any]],
            ] as [String: Any],
        ]
        #expect(!PhanttomClaudeIntegration.isOurs(command: foreign))

        let installed = PhanttomClaudeIntegration.install(into: input)
        let prompt = (installed["hooks"] as? [String: Any])?["UserPromptSubmit"]
            as? [[String: Any]] ?? []
        let cmds = prompt.flatMap(commands(in:))
        #expect(cmds.contains(foreign))
        #expect(cmds.contains(where: { $0.contains("phanttom-hook.sh") }))

        let uninstalled = PhanttomClaudeIntegration.uninstall(from: installed)
        let after = (uninstalled["hooks"] as? [String: Any])?["UserPromptSubmit"]
            as? [[String: Any]] ?? []
        #expect(after.flatMap(commands(in:)).contains(foreign))
        #expect(!after.flatMap(commands(in:)).contains(where: {
            $0.contains("phanttom-hook.sh")
        }))
    }

    @Test func installIsIdempotent() {
        let once = PhanttomClaudeIntegration.install(into: ["keep": 1])
        let twice = PhanttomClaudeIntegration.install(into: once)
        #expect(jsonEqual(once, twice))
    }

    @Test func installIsIdempotentWithStashedStatusline() {
        // The real Update flow re-runs install() on settings that already
        // carry our statusLine + the stashed original. The second pass must
        // preserve the stash rather than re-stashing our own command.
        let input: [String: Any] = [
            "statusLine": [
                "type": "command",
                "command": "echo user-status",
            ] as [String: Any],
        ]
        let once = PhanttomClaudeIntegration.install(into: input)
        let twice = PhanttomClaudeIntegration.install(into: once)
        #expect(
            twice[PhanttomClaudeIntegration.originalStatusLineKey] as? String
                == "echo user-status"
        )
        #expect(jsonEqual(once, twice))
    }

    @Test func stripKeepsUserHookSharingAnEntryWithOurs() {
        // A single matcher entry holding BOTH a foreign command and a phanttom
        // command: uninstall must drop only ours and keep the foreign one.
        let mixedEntry: [String: Any] = [
            "hooks": [
                ["type": "command", "command": "echo user-cleanup"] as [String: Any],
                ["type": "command",
                 "command": PhanttomClaudeIntegration.desiredHooks[3].command] as [String: Any],
            ] as [[String: Any]],
        ]
        let input: [String: Any] = [
            "hooks": ["Stop": [mixedEntry] as [[String: Any]]] as [String: Any],
        ]

        let stripped = PhanttomClaudeIntegration.uninstall(from: input)
        let stopEntries = (stripped["hooks"] as? [String: Any])?["Stop"]
            as? [[String: Any]] ?? []
        let cmds = stopEntries.flatMap(commands(in:))
        #expect(cmds.contains("echo user-cleanup"))
        #expect(!cmds.contains(where: { $0.contains("phanttom-hook.sh") }))
    }

    @Test func statuslineObjectSiblingKeysSurviveRoundTrip() {
        // Extra keys on the user's statusLine object (e.g. padding) must
        // round-trip through Set Up → Remove, not just the command string.
        let input: [String: Any] = [
            "statusLine": [
                "type": "command",
                "command": "echo my-status",
                "padding": 0,
            ] as [String: Any],
        ]
        let installed = PhanttomClaudeIntegration.install(into: input)
        #expect(
            (installed["statusLine"] as? [String: Any])?["command"] as? String
                == PhanttomClaudeIntegration.desiredStatusLine["command"]
        )

        let restored = PhanttomClaudeIntegration.uninstall(from: installed)
        let statusLine = restored["statusLine"] as? [String: Any]
        #expect(statusLine?["command"] as? String == "echo my-status")
        #expect(statusLine?["padding"] as? Int == 0)
        #expect(restored[PhanttomClaudeIntegration.originalStatusLineObjectKey] == nil)
    }

    @Test func installRepairsNonArrayEventValue() {
        // A schema-invalid (non-array) event value can't be merged, so install
        // replaces it with a fresh array carrying our dispatch rather than
        // skipping it forever. Skipping used to leave `hasCompleteDispatch`
        // permanently false, pinning status at "outdated" and re-running
        // install every launch. After repair the integration reaches
        // "current". (The unmergeable "oops" value is necessarily dropped.)
        let input: [String: Any] = [
            "hooks": ["Stop": "oops"] as [String: Any],
        ]
        let result = PhanttomClaudeIntegration.install(into: input)
        let stop = (result["hooks"] as? [String: Any])?["Stop"]
        #expect(stop as? String == nil)
        #expect(stop is [Any])
        #expect(PhanttomClaudeIntegration.status(
            of: result, scriptText: PhanttomClaudeIntegration.hookScript
        ) == .installedCurrent)
    }

    @Test func statuslineStashAndRestore() {
        let input: [String: Any] = [
            "statusLine": [
                "type": "command",
                "command": "bash \"$HOME/.claude/statusline-command.sh\"",
            ] as [String: Any],
        ]
        let installed = PhanttomClaudeIntegration.install(into: input)
        #expect(
            installed[PhanttomClaudeIntegration.originalStatusLineKey] as? String
                == "bash \"$HOME/.claude/statusline-command.sh\""
        )
        #expect(
            (installed["statusLine"] as? [String: Any])?["command"] as? String
                == PhanttomClaudeIntegration.desiredStatusLine["command"]
        )

        let uninstalled = PhanttomClaudeIntegration.uninstall(from: installed)
        #expect(
            (uninstalled["statusLine"] as? [String: Any])?["command"] as? String
                == "bash \"$HOME/.claude/statusline-command.sh\""
        )
        #expect(uninstalled[PhanttomClaudeIntegration.originalStatusLineKey] == nil)
        #expect(uninstalled["hooks"] == nil)
    }

    @Test func uninstallNeverInstalledIsNoOp() {
        let input: [String: Any] = [
            "model": "opus",
            "hooks": [
                "PreToolUse": [entry(command: "echo hi")] as [[String: Any]],
            ] as [String: Any],
        ]
        let result = PhanttomClaudeIntegration.uninstall(from: input)
        #expect(jsonEqual(input, result))
    }

    @Test func statusDetectsCurrentVsOutdated() {
        let installed = PhanttomClaudeIntegration.install(into: [:])
        #expect(PhanttomClaudeIntegration.status(
            of: installed, scriptText: PhanttomClaudeIntegration.hookScript
        ) == .installedCurrent)

        let oldScript = PhanttomClaudeIntegration.hookScript
            .replacingOccurrences(
                of: "# phanttom-hook v\(PhanttomClaudeIntegration.payloadVersion)",
                with: "# phanttom-hook v0"
            )
        #expect(PhanttomClaudeIntegration.status(
            of: installed, scriptText: oldScript
        ) == .installedOutdated(installedVersion: 0))

        #expect(PhanttomClaudeIntegration.status(
            of: [:], scriptText: nil
        ) == .notInstalled)
    }

    @Test func statusDetectsLegacyInline() {
        let legacyCmd =
            #"sh -c 't=$(ps -o tty= -p "${CLAUDE_PID:-0}"); printf "\033]9;4;0;0\033\\" > "$t"'"#
        let legacy: [String: Any] = [
            "hooks": [
                "Stop": [entry(command: legacyCmd)] as [[String: Any]],
            ] as [String: Any],
        ]
        #expect(PhanttomClaudeIntegration.status(of: legacy, scriptText: nil)
            == .legacyInline)
    }

    /// Stop must inspect Claude's background_tasks so rain survives a
    /// main-agent pause while subagents (or other background work) run.
    @Test func hookScriptEmitsKindTokenMarkers() {
        let script = PhanttomClaudeIntegration.hookScript
        #expect(script.contains(".claude"))
        #expect(script.contains("# phanttom-hook v\(PhanttomClaudeIntegration.payloadVersion)"))
    }

    @Test func stopSpecChecksBackgroundTasks() {
        let script = PhanttomClaudeIntegration.hookScript
        #expect(script.contains("json_background_tasks_len"))
        #expect(script.contains("background_tasks"))
        let stop = PhanttomClaudeIntegration.desiredHooks
            .first { $0.event == "Stop" }
        #expect(stop?.command.contains("phanttom-hook.sh\" stop") == true)
        // Both re-arm (state 3) and clear (state 0) paths present in stop).
        if let stopBody = Self.caseBody(of: "stop)", in: script) {
            #expect(stopBody.contains("emit_osc74 3"))
            #expect(stopBody.contains("emit_osc74 0"))
        } else {
            Issue.record("missing stop) case in hookScript")
        }
    }

    /// The body of one `case` arm in `hookScript`: everything from `label`
    /// up to its terminating `;;`. Slicing on the real delimiter rather than
    /// a fixed character count keeps these assertions correct when the arm's
    /// comments or logic grow.
    private static func caseBody(of label: String, in script: String) -> String? {
        guard let start = script.range(of: label) else { return nil }
        let rest = script[start.lowerBound...]
        guard let end = rest.range(of: ";;") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    @Test func subagentStartSpecEmitsRain() {
        let start = PhanttomClaudeIntegration.desiredHooks
            .first { $0.event == "SubagentStart" }
        #expect(start?.command.contains("subagent-start") == true)
        let script = PhanttomClaudeIntegration.hookScript
        #expect(script.contains("subagent-start)"))
        if let body = Self.caseBody(of: "subagent-start)", in: script) {
            #expect(body.contains("emit_osc74 3"))
            #expect(!body.contains("emit_osc74 0"))
        } else {
            Issue.record("missing subagent-start) case in hookScript")
        }
    }

    @Test func consentMigrationFreshUserAutoInstalls() {
        // No old keys → nothing to migrate, auto-install proceeds.
        #expect(PhanttomClaudeIntegration.migrateConsent(
            legacyValue: nil, promptedKeySet: false,
            status: .notInstalled, statusError: nil) == .autoInstall)
    }

    @Test func consentMigrationHonorsPriorDeclineOrRemove() {
        // Prompted + notInstalled = declined "Not Now" or removed → opt-out.
        #expect(PhanttomClaudeIntegration.migrateConsent(
            legacyValue: nil, promptedKeySet: true,
            status: .notInstalled, statusError: nil) == .disableAutoInstall)
        // PR #15 explicit disable is an opt-out regardless of status.
        #expect(PhanttomClaudeIntegration.migrateConsent(
            legacyValue: "disabled", promptedKeySet: false,
            status: .installedCurrent, statusError: nil) == .disableAutoInstall)
        // PR #15 "enabled" never reinstalled after an explicit Remove.
        #expect(PhanttomClaudeIntegration.migrateConsent(
            legacyValue: "enabled", promptedKeySet: false,
            status: .notInstalled, statusError: nil) == .disableAutoInstall)
    }

    @Test func consentMigrationKeepsSyncingInstalledUsers() {
        #expect(PhanttomClaudeIntegration.migrateConsent(
            legacyValue: nil, promptedKeySet: true,
            status: .installedCurrent, statusError: nil) == .autoInstall)
        #expect(PhanttomClaudeIntegration.migrateConsent(
            legacyValue: nil, promptedKeySet: true,
            status: .installedOutdated(installedVersion: 1),
            statusError: nil) == .autoInstall)
        #expect(PhanttomClaudeIntegration.migrateConsent(
            legacyValue: "enabled", promptedKeySet: false,
            status: .legacyInline, statusError: nil) == .autoInstall)
    }

    @Test func consentMigrationRetriesWhenStatusUnreadable() {
        // Can't tell decline from breakage → keep keys, decide next launch.
        #expect(PhanttomClaudeIntegration.migrateConsent(
            legacyValue: nil, promptedKeySet: true,
            status: .notInstalled, statusError: .claudeNotFound) == .retryLater)
        #expect(PhanttomClaudeIntegration.migrateConsent(
            legacyValue: "enabled", promptedKeySet: false,
            status: .notInstalled, statusError: .settingsCorrupt) == .retryLater)
    }

    // MARK: - File I/O (temp base dir)

    @Test func installWritesScriptStateAndBackup() throws {
        let dir = try makeTempClaudeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let paths = PhanttomClaudeIntegration.Paths(
            baseDir: URL(fileURLWithPath: dir))

        let prior: [String: Any] = [
            "model": "sonnet",
            "statusLine": [
                "type": "command",
                "command": "echo my-status",
            ] as [String: Any],
        ]
        try PhanttomClaudeIntegration.writeSettings(prior, to: paths.settings)

        let result = PhanttomClaudeIntegration.performInstall(paths: paths)
        #expect(result.error == nil)
        #expect(result.status == .installedCurrent)

        let settings = try PhanttomClaudeIntegration.readSettings(at: paths.settings)
        #expect(settings["model"] as? String == "sonnet")
        assertDesiredPresent(in: settings)

        let script = try String(contentsOf: paths.script, encoding: .utf8)
        #expect(script.contains("# phanttom-hook v"))
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.script.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms & 0o777 == 0o755)

        let stateData = try Data(contentsOf: paths.state)
        let state = try JSONSerialization.jsonObject(with: stateData) as? [String: Any]
        #expect(state?["originalStatusLine"] as? String == "echo my-status")

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix("settings.json.bak-phanttom-") }
        #expect(backups.count == 1)
    }

    @Test func backupPrunesToFiveNewestPlusPristineOldest() throws {
        let dir = try makeTempClaudeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let paths = PhanttomClaudeIntegration.Paths(
            baseDir: URL(fileURLWithPath: dir))
        try PhanttomClaudeIntegration.writeSettings([:], to: paths.settings)

        var names: [String] = []
        for i in 0..<7 {
            let name = String(format: "settings.json.bak-phanttom-2026010%d-120000", i)
            names.append(name)
            let url = paths.baseDir.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            // Distinct mtimes so prune sort is stable (i=0 is the oldest).
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(i))],
                ofItemAtPath: url.path
            )
        }
        PhanttomClaudeIntegration.pruneBackups(in: paths.baseDir, keeping: 5)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix("settings.json.bak-phanttom-") }
        // 5 newest + the single oldest (pristine pre-Phanttom) snapshot.
        #expect(backups.count == 6)
        #expect(backups.contains(names[0]), "pristine oldest backup must survive prune")
        #expect(!backups.contains(names[1]), "second-oldest is pruned, not protected")
    }

    @Test func corruptSettingsAbortsUntouched() throws {
        let dir = try makeTempClaudeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let paths = PhanttomClaudeIntegration.Paths(
            baseDir: URL(fileURLWithPath: dir))
        let corrupt = "{ not json"
        try corrupt.write(to: paths.settings, atomically: true, encoding: .utf8)

        let result = PhanttomClaudeIntegration.performInstall(paths: paths)
        #expect(result.error == .settingsCorrupt)
        let after = try String(contentsOf: paths.settings, encoding: .utf8)
        #expect(after == corrupt)
        #expect(!FileManager.default.fileExists(atPath: paths.script.path))
    }

    @Test func uninstallOnCorruptSettingsChangesNothing() throws {
        // settings.json can't be parsed, so our hook entries can't be stripped
        // from it. Removing the script anyway would leave those entries
        // pointing at a missing phanttom-hook.sh the moment the user fixes
        // their JSON by hand — so Remove must be a true no-op here.
        let dir = try makeTempClaudeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let paths = PhanttomClaudeIntegration.Paths(
            baseDir: URL(fileURLWithPath: dir))

        try PhanttomClaudeIntegration.writeSettings([:], to: paths.settings)
        _ = PhanttomClaudeIntegration.performInstall(paths: paths)
        #expect(FileManager.default.fileExists(atPath: paths.script.path))

        let corrupt = "{ not json"
        try corrupt.write(to: paths.settings, atomically: true, encoding: .utf8)

        let result = PhanttomClaudeIntegration.performUninstall(paths: paths)
        #expect(result.error == .settingsCorrupt)
        // Both sides untouched: the hooks still reference a script that exists.
        #expect(try String(contentsOf: paths.settings, encoding: .utf8) == corrupt)
        #expect(FileManager.default.fileExists(atPath: paths.script.path))
        #expect(FileManager.default.fileExists(atPath: paths.state.path))

        // And Remove works normally once the JSON parses again.
        try PhanttomClaudeIntegration.writeSettings([:], to: paths.settings)
        #expect(PhanttomClaudeIntegration.performUninstall(paths: paths).error == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.script.path))
    }

    @Test func uninstallRestoresStatuslineAndRemovesFiles() throws {
        let dir = try makeTempClaudeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let paths = PhanttomClaudeIntegration.Paths(
            baseDir: URL(fileURLWithPath: dir))

        try PhanttomClaudeIntegration.writeSettings([
            "statusLine": [
                "type": "command",
                "command": "echo original",
            ] as [String: Any],
            "hooks": [
                "PreToolUse": [entry(command: "echo keep")] as [[String: Any]],
            ] as [String: Any],
        ], to: paths.settings)

        _ = PhanttomClaudeIntegration.performInstall(paths: paths)
        #expect(FileManager.default.fileExists(atPath: paths.script.path))

        let result = PhanttomClaudeIntegration.performUninstall(paths: paths)
        #expect(result.error == nil)
        #expect(result.status == .notInstalled)

        let settings = try PhanttomClaudeIntegration.readSettings(at: paths.settings)
        #expect(
            (settings["statusLine"] as? [String: Any])?["command"] as? String
                == "echo original"
        )
        let pre = (settings["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        #expect(pre.map { commands(in: $0[0]).contains("echo keep") } == true)
        #expect(!FileManager.default.fileExists(atPath: paths.script.path))
        #expect(!FileManager.default.fileExists(atPath: paths.state.path))
    }

    @Test func nonArrayEventRepairInstallsWithoutChurningBackups() throws {
        let dir = try makeTempClaudeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let paths = PhanttomClaudeIntegration.Paths(
            baseDir: URL(fileURLWithPath: dir))
        // A malformed (non-array) value on a desired event is repaired by
        // install (replaced with a fresh array carrying our dispatch), so the
        // first pass reaches `.installedCurrent` instead of looping forever.
        try PhanttomClaudeIntegration.writeSettings(
            ["hooks": ["Stop": "oops"] as [String: Any]], to: paths.settings)

        let first = PhanttomClaudeIntegration.performInstall(paths: paths)
        #expect(first.status == .installedCurrent)
        #expect(try backupCount(in: dir) == 1)

        // Re-running is idempotent: the config is already at its fixed point,
        // so no further backups (or writes) should occur.
        for _ in 0..<4 { _ = PhanttomClaudeIntegration.performInstall(paths: paths) }
        #expect(try backupCount(in: dir) == 1)
    }

    @Test func migratesLegacyStatuslineWrapper() throws {
        let dir = try makeTempClaudeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let paths = PhanttomClaudeIntegration.Paths(
            baseDir: URL(fileURLWithPath: dir))
        // Legacy hand-install: statusLine points at the phanttom wrapper, which
        // chained to the user's real statusline-command.sh on disk.
        try PhanttomClaudeIntegration.writeSettings([
            "statusLine": [
                "type": "command",
                "command": "sh \"$HOME/.claude/statusline-phanttom.sh\"",
            ] as [String: Any],
        ], to: paths.settings)
        let chained = paths.baseDir.appendingPathComponent("statusline-command.sh")
        try Data("#!/bin/bash\necho hi\n".utf8).write(to: chained)
        let legacyWrapper = paths.baseDir
            .appendingPathComponent("statusline-phanttom.sh")
        try Data("#!/bin/sh\n".utf8).write(to: legacyWrapper)

        let result = PhanttomClaudeIntegration.performInstall(paths: paths)
        #expect(result.error == nil)

        // The user's real statusline is recovered into the persisted state so
        // the hook chains to it and Remove can restore it.
        let stateData = try Data(contentsOf: paths.state)
        let state = try JSONSerialization.jsonObject(with: stateData) as? [String: Any]
        #expect(state?["originalStatusLine"] as? String
            == "bash \"$HOME/.claude/statusline-command.sh\"")
        // Legacy wrapper script is deleted as part of migration.
        #expect(!FileManager.default.fileExists(atPath: legacyWrapper.path))
    }

    @Test func missingClaudeDirReportsNotFound() {
        let paths = PhanttomClaudeIntegration.Paths(
            baseDir: URL(fileURLWithPath: "/tmp/phanttom-no-such-\(UUID().uuidString)"))
        let result = PhanttomClaudeIntegration.currentStatus(paths: paths)
        #expect(result.error == .claudeNotFound)
        #expect(result.message.contains("~/.claude missing"))
    }

    /// Opt-in: `PHANTTOM_MIGRATE_CLAUDE=1 xcodebuild test …PhanttomClaudeIntegrationTests`
    /// runs install against the real `~/.claude` (Phase 4 / ops escape hatch).
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["PHANTTOM_MIGRATE_CLAUDE"] == "1")
    )
    func migrateRealClaudeHome() {
        let before = PhanttomClaudeIntegration.currentStatus()
        #expect(before.error != .claudeNotFound)
        let result = PhanttomClaudeIntegration.performInstall()
        #expect(result.error == nil)
        #expect(result.status == .installedCurrent)
    }

    // MARK: - Helpers

    private func makeTempClaudeDir() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phanttom-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func backupCount(in dir: String) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix("settings.json.bak-phanttom-") }
            .count
    }

    private func entry(command: String, matcher: String? = nil) -> [String: Any] {
        var e: [String: Any] = [
            "hooks": [
                ["type": "command", "command": command] as [String: Any],
            ] as [[String: Any]],
        ]
        if let matcher { e["matcher"] = matcher }
        return e
    }

    private func commands(in entry: [String: Any]) -> [String] {
        guard let hooks = entry["hooks"] as? [Any] else { return [] }
        return hooks.compactMap { ($0 as? [String: Any])?["command"] as? String }
    }

    private func assertDesiredPresent(in settings: [String: Any]) {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        for desired in PhanttomClaudeIntegration.desiredHooks {
            let entries = hooks[desired.event] as? [[String: Any]] ?? []
            let found = entries.contains { entry in
                let cmds = commands(in: entry)
                let matcherOK: Bool
                if let m = desired.matcher {
                    matcherOK = entry["matcher"] as? String == m
                } else {
                    matcherOK = entry["matcher"] == nil
                }
                return matcherOK && cmds.contains(desired.command)
            }
            #expect(found, "missing desired hook for \(desired.event)")
        }
        #expect(
            (settings["statusLine"] as? [String: Any])?["command"] as? String
                == PhanttomClaudeIntegration.desiredStatusLine["command"]
        )
    }

    private func jsonEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let opts: JSONSerialization.WritingOptions = [.sortedKeys]
        guard let da = try? JSONSerialization.data(withJSONObject: a, options: opts),
              let db = try? JSONSerialization.data(withJSONObject: b, options: opts)
        else { return false }
        return da == db
    }
}
