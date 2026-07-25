import Foundation
import Testing
@testable import Ghostty

/// Tests for the agent-agnostic file layer every integration shares.
///
/// These guarantees are asserted here rather than in each agent's suite
/// because they belong to `PhanttomIntegrationSupport`: `settings.json`,
/// `hooks.json`, and `cli-config.json` all go through the same writer and
/// backup path, and all three can carry credentials.
@Suite
struct PhanttomIntegrationSupportTests {
    // MARK: - Mode preservation

    @Test func writeJSONObjectKeepsTheExistingMode() throws {
        // An atomic write replaces the file. A user who chmodded their agent
        // config to 0600 must not get a 0644 copy back because we rewrote it.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")

        try PhanttomIntegrationSupport.writeJSONObject(["a": 1], to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)

        try PhanttomIntegrationSupport.writeJSONObject(["a": 2], to: url)

        #expect(try mode(of: url) == 0o600)
        let reread = try PhanttomIntegrationSupport.readJSONObject(
            at: url, absentAsEmpty: false)
        #expect(reread["a"] as? Int == 2)
    }

    @Test func writeJSONObjectCreatesAbsentFiles() throws {
        // No prior file means no prior mode to restore — the write must still
        // succeed rather than trip over the missing attributes.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cli-config.json")

        try PhanttomIntegrationSupport.writeJSONObject(["version": 1], to: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Backups

    @Test func backupsAreNotWorldReadable() throws {
        // `copyItem` inherits the source mode, so a world-readable config
        // would leave a world-readable snapshot of a file that can hold an
        // API key. Tightened unconditionally.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hooks.json")
        try PhanttomIntegrationSupport.writeJSONObject(["a": 1], to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: url.path)

        try PhanttomIntegrationSupport.backupFile(at: url, prefix: "hooks.json.bak-phanttom-")

        let backups = try names(in: dir, prefix: "hooks.json.bak-phanttom-")
        let backup = try #require(backups.first)
        #expect(try mode(of: dir.appendingPathComponent(backup)) == 0o600)
    }

    @Test func removeBackupsDeletesOnlyOurSnapshots() throws {
        // Called on uninstall: a credential the user has since deleted from
        // their config must not live on in a file we created. Everything else
        // in the directory is untouchable.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = "settings.json.bak-phanttom-"
        for name in ["\(prefix)20260101-120000", "\(prefix)20260102-120000",
                     "settings.json", "settings.json.bak-mine"] {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
        }

        PhanttomIntegrationSupport.removeBackups(in: dir, prefix: prefix)

        #expect(try names(in: dir, prefix: prefix).isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("settings.json").path))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("settings.json.bak-mine").path))
    }

    // MARK: - Shared hook prelude

    @Test func hookPreludeIsTheSameGuardForEveryAgent() {
        // The emit guard and the scratch directory are one decision for all
        // agents; only the config directory differs. Kept in one place so the
        // next tweak can't fork between the two payloads.
        let claude = PhanttomIntegrationSupport.hookPrelude(agentDirName: ".claude")
        let cursor = PhanttomIntegrationSupport.hookPrelude(agentDirName: ".cursor")

        let onlyDifference = claude.replacingOccurrences(
            of: "/.claude/", with: "/.cursor/")
        #expect(onlyDifference == cursor)

        for prelude in [claude, cursor] {
            #expect(prelude.contains("phanttom_terminal()"))
            #expect(prelude.contains("TERM_PROGRAM:-"))
            #expect(prelude.contains("chmod 700"))
            // The expansion that used to build a guessable /tmp path.
            #expect(!prelude.contains("${TMPDIR"))
        }
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phanttom-support-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
    }

    private func names(in dir: URL, prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(prefix) }
    }
}
