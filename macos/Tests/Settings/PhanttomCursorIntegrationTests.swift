import Foundation
import Testing
@testable import Ghostty

/// Tests for the Cursor Agent CLI integration merge engine and file I/O.
@Suite
struct PhanttomCursorIntegrationTests {
    // MARK: - Pure merge (hooks.json)

    @Test func installHooksIntoEmptyDoc() {
        let result = PhanttomCursorIntegration.installHooks(into: [:])
        assertDesiredHooksPresent(in: result)
        #expect(result["version"] as? Int == 1)
    }

    @Test func installPreservesForeignHooksAndUnknownKeys() {
        let input: [String: Any] = [
            "version": 1,
            "keep": true,
            "hooks": [
                "beforeSubmitPrompt": [
                    ["command": "echo foreign-prompt"] as [String: Any],
                ] as [[String: Any]],
                "stop": [
                    ["command": "echo foreign-stop"] as [String: Any],
                ] as [[String: Any]],
            ] as [String: Any],
        ]

        let result = PhanttomCursorIntegration.installHooks(into: input)
        #expect(result["keep"] as? Bool == true)

        let hooks = result["hooks"] as? [String: Any] ?? [:]
        let prompt = hooks["beforeSubmitPrompt"] as? [[String: Any]] ?? []
        #expect(prompt.contains { ($0["command"] as? String) == "echo foreign-prompt" })

        let stop = hooks["stop"] as? [[String: Any]] ?? []
        let stopCmds = stop.compactMap { $0["command"] as? String }
        #expect(stopCmds.contains("echo foreign-stop"))
        #expect(stopCmds.contains(where: { $0.contains("phanttom-hook.sh") }))

        assertDesiredHooksPresent(in: result)
    }

    @Test func uninstallRemovesOursKeepsForeign() {
        let installed = PhanttomCursorIntegration.installHooks(into: [
            "hooks": [
                "sessionStart": [
                    ["command": "echo foreign-start"] as [String: Any],
                ] as [[String: Any]],
            ] as [String: Any],
        ])
        let stripped = PhanttomCursorIntegration.uninstallHooks(from: installed)
        let hooks = stripped["hooks"] as? [String: Any] ?? [:]
        let start = hooks["sessionStart"] as? [[String: Any]] ?? []
        #expect(start.count == 1)
        #expect(start[0]["command"] as? String == "echo foreign-start")
        for desired in PhanttomCursorIntegration.desiredHooks {
            let entries = hooks[desired.event] as? [[String: Any]] ?? []
            #expect(!entries.contains {
                ($0["command"] as? String)?.contains("phanttom-hook.sh") == true
            })
        }
    }

    // MARK: - Pure merge (cli-config statusLine)

    @Test func installStatusLineIntoAbsentConfig() {
        let plan = PhanttomCursorIntegration.installStatusLine(
            into: [:],
            priorOriginalCommand: nil,
            priorOriginalObject: nil
        )
        #expect(plan.cliConfig["version"] as? Int == 1)
        let cmd = (plan.cliConfig["statusLine"] as? [String: Any])?["command"] as? String
        #expect(cmd?.contains("phanttom-hook.sh") == true)
        #expect(plan.originalStatusLineCommand == nil)
    }

    @Test func installStatusLineStashesForeignAndUninstallRestores() {
        let prior: [String: Any] = [
            "version": 1,
            "editor": ["vimMode": false] as [String: Any],
            "statusLine": [
                "type": "command",
                "command": "echo my-status",
                "padding": 2,
            ] as [String: Any],
        ]
        let plan = PhanttomCursorIntegration.installStatusLine(
            into: prior,
            priorOriginalCommand: nil,
            priorOriginalObject: nil
        )
        #expect(plan.originalStatusLineCommand == "echo my-status")
        #expect(plan.originalStatusLineObject?["padding"] as? Int == 2)
        #expect(
            (plan.cliConfig["statusLine"] as? [String: Any])?["command"] as? String
                == PhanttomCursorIntegration.desiredStatusLine["command"]
        )

        let restored = PhanttomCursorIntegration.uninstallStatusLine(
            from: plan.cliConfig,
            originalCommand: plan.originalStatusLineCommand,
            originalObject: plan.originalStatusLineObject
        )
        #expect((restored["statusLine"] as? [String: Any])?["command"] as? String
            == "echo my-status")
        #expect((restored["statusLine"] as? [String: Any])?["padding"] as? Int == 2)
        #expect((restored["editor"] as? [String: Any])?["vimMode"] as? Bool == false)
    }

    @Test func statusCompleteCurrentAndOutdated() {
        let hooks = PhanttomCursorIntegration.installHooks(into: [:])
        let plan = PhanttomCursorIntegration.installStatusLine(
            into: [:], priorOriginalCommand: nil, priorOriginalObject: nil)
        #expect(PhanttomCursorIntegration.status(
            of: hooks,
            cliConfig: plan.cliConfig,
            scriptText: PhanttomCursorIntegration.hookScript
        ) == .installedCurrent)

        let oldScript = PhanttomCursorIntegration.hookScript.replacingOccurrences(
            of: "# phanttom-hook v\(PhanttomCursorIntegration.payloadVersion)",
            with: "# phanttom-hook v0"
        )
        #expect(PhanttomCursorIntegration.status(
            of: hooks, cliConfig: plan.cliConfig, scriptText: oldScript
        ) == .installedOutdated(installedVersion: 0))
    }

    @Test func hookScriptGuardsCursorAgentAndKindToken() {
        let script = PhanttomCursorIntegration.hookScript
        #expect(script.contains("CURSOR_AGENT"))
        #expect(script.contains(".cursor"))
        #expect(script.contains("PHANTTOM_TTY"))
        #expect(!script.contains("t=/dev/tty;;"))
    }

    // MARK: - File I/O

    @Test func performInstallAndUninstallRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phanttom-cursor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = PhanttomCursorIntegration.Paths(baseDir: root)
        // Absent hooks/cli-config are fine — install creates them.
        let foreignHooks: [String: Any] = [
            "version": 1,
            "hooks": [
                "stop": [["command": "echo keep-me"] as [String: Any]],
            ] as [String: Any],
        ]
        try PhanttomCursorIntegration.writeJSONObject(foreignHooks, to: paths.hooks)
        try PhanttomCursorIntegration.writeJSONObject(
            [
                "version": 1,
                "statusLine": [
                    "type": "command",
                    "command": "echo prior-status",
                ] as [String: Any],
            ] as [String: Any],
            to: paths.cliConfig
        )

        let installed = PhanttomCursorIntegration.performInstall(paths: paths)
        #expect(installed.error == nil)
        #expect(installed.status == .installedCurrent)
        #expect(FileManager.default.fileExists(atPath: paths.script.path))

        let hooksAfter = try PhanttomCursorIntegration.readJSONObject(
            at: paths.hooks, absentAsEmpty: false)
        let stop = (hooksAfter["hooks"] as? [String: Any])?["stop"] as? [[String: Any]] ?? []
        let stopCmds = stop.compactMap { $0["command"] as? String }
        #expect(stopCmds.contains("echo keep-me"))
        #expect(stopCmds.contains(where: { $0.contains("phanttom-hook.sh") }))

        let uninstalled = PhanttomCursorIntegration.performUninstall(paths: paths)
        #expect(uninstalled.error == nil)
        #expect(uninstalled.status == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: paths.script.path))

        let hooksFinal = try PhanttomCursorIntegration.readJSONObject(
            at: paths.hooks, absentAsEmpty: false)
        let stopFinal = (hooksFinal["hooks"] as? [String: Any])?["stop"] as? [[String: Any]] ?? []
        #expect(stopFinal.count == 1)
        #expect(stopFinal[0]["command"] as? String == "echo keep-me")

        let cliFinal = try PhanttomCursorIntegration.readJSONObject(
            at: paths.cliConfig, absentAsEmpty: false)
        #expect((cliFinal["statusLine"] as? [String: Any])?["command"] as? String
            == "echo prior-status")
    }

    @Test func currentStatusMissingDirectory() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phanttom-cursor-missing-\(UUID().uuidString)")
        let paths = PhanttomCursorIntegration.Paths(baseDir: root)
        let result = PhanttomCursorIntegration.currentStatus(paths: paths)
        #expect(result.error == .cursorNotFound)
        #expect(result.status == .notInstalled)
    }

    @Test func corruptHooksAbortInstall() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phanttom-cursor-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = PhanttomCursorIntegration.Paths(baseDir: root)
        try Data("[1,2,3]".utf8).write(to: paths.hooks)
        let result = PhanttomCursorIntegration.performInstall(paths: paths)
        #expect(result.error == .hooksCorrupt)
    }

    @Test func installRepairsNonArrayEventValue() {
        // A schema-invalid (non-array) event value can't be merged, so install
        // replaces it with a fresh array carrying our dispatch. Skipping it
        // would pin `hasCompleteDispatch` false forever — and since auto-sync
        // installs on every launch, that means reinstalling (and backing up
        // hooks.json + cli-config.json) on every launch, forever.
        let result = PhanttomCursorIntegration.installHooks(
            into: ["hooks": ["stop": "oops"] as [String: Any]])
        let stop = (result["hooks"] as? [String: Any])?["stop"]
        #expect(stop as? String == nil)
        assertDesiredHooksPresent(in: result)

        let plan = PhanttomCursorIntegration.installStatusLine(
            into: [:], priorOriginalCommand: nil, priorOriginalObject: nil)
        #expect(PhanttomCursorIntegration.hasCompleteDispatch(
            in: result, cliConfig: plan.cliConfig))
    }

    @Test func nonObjectHookElementsSurviveInstallAndUninstall() {
        // A stray non-object element in a user's hooks array is data we don't
        // understand, not data we may delete. It must round-trip both ways.
        let input: [String: Any] = [
            "hooks": [
                "stop": [
                    "stray-string",
                    ["command": "echo foreign"] as [String: Any],
                ] as [Any],
            ] as [String: Any],
        ]

        let installed = PhanttomCursorIntegration.installHooks(into: input)
        let afterInstall = (installed["hooks"] as? [String: Any])?["stop"] as? [Any] ?? []
        #expect(afterInstall.contains { $0 as? String == "stray-string" })

        let removed = PhanttomCursorIntegration.uninstallHooks(from: installed)
        let afterUninstall = (removed["hooks"] as? [String: Any])?["stop"] as? [Any] ?? []
        #expect(afterUninstall.contains { $0 as? String == "stray-string" })
        #expect(afterUninstall.contains {
            ($0 as? [String: Any])?["command"] as? String == "echo foreign"
        })
        #expect(!afterUninstall.contains {
            guard let cmd = ($0 as? [String: Any])?["command"] as? String else { return false }
            return cmd.contains(PhanttomCursorIntegration.hookScriptName)
        })
    }

    // MARK: - Auto-install opt-out (shared across builds)

    @Test func optOutMarkerIsSharedAcrossBuilds() throws {
        // `UserDefaults.standard` is scoped to the bundle id, so the Debug and
        // release builds cannot see each other's opt-out — but they
        // auto-install into the same ~/.cursor. Two Paths over one base dir
        // stand in for the two builds here.
        let root = try makeTempCursorDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let debugBuild = PhanttomCursorIntegration.Paths(baseDir: root)
        let releaseBuild = PhanttomCursorIntegration.Paths(baseDir: root)

        #expect(!PhanttomCursorIntegration.isAutoInstallDisabled(paths: debugBuild))

        // Remove… in one build must stop the other from reinstalling.
        PhanttomCursorIntegration.setAutoInstallDisabled(true, paths: debugBuild)
        #expect(PhanttomCursorIntegration.isAutoInstallDisabled(paths: releaseBuild))

        // …and Set Up in either build lifts it for both.
        PhanttomCursorIntegration.setAutoInstallDisabled(false, paths: releaseBuild)
        #expect(!PhanttomCursorIntegration.isAutoInstallDisabled(paths: debugBuild))
    }

    @Test func optOutSurvivesUninstall() throws {
        // Remove… writes the marker and then runs the uninstall. If uninstall
        // swept the marker with the rest of our artifacts (it deletes the
        // state file next to it), the next launch would reinstall everything
        // the user just removed.
        let root = try makeTempCursorDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PhanttomCursorIntegration.Paths(baseDir: root)

        #expect(PhanttomCursorIntegration.performInstall(paths: paths).error == nil)
        PhanttomCursorIntegration.setAutoInstallDisabled(true, paths: paths)

        #expect(PhanttomCursorIntegration.performUninstall(paths: paths).error == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.script.path))
        #expect(!FileManager.default.fileExists(atPath: paths.state.path))
        #expect(PhanttomCursorIntegration.isAutoInstallDisabled(paths: paths))
    }

    // MARK: - Helpers

    private func makeTempCursorDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phanttom-cursor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func assertDesiredHooksPresent(in doc: [String: Any]) {
        let hooks = doc["hooks"] as? [String: Any] ?? [:]
        for desired in PhanttomCursorIntegration.desiredHooks {
            let entries = hooks[desired.event] as? [[String: Any]] ?? []
            #expect(entries.contains { ($0["command"] as? String) == desired.command })
        }
    }
}
