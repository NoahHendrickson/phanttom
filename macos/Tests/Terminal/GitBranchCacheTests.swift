import Foundation
import Testing
@testable import Ghostty

/// Filesystem fixtures for `GitBranchCache.readMetadata`: main repo vs
/// linked worktree vs submodule-shaped gitdir (not a worktree).
@Suite
struct GitBranchCacheTests {
    @Test func mainRepoIsNotAWorktree() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try write(at: root, relative: ".git/HEAD", contents: "ref: refs/heads/main\n")

        let resolved = GitBranchCache.readMetadata(at: root)
        #expect(resolved.branch == "main")
        #expect(resolved.isWorktree == false)
    }

    @Test func linkedWorktreeIsDetected() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let repo = (root as NSString).appendingPathComponent("repo")
        let worktree = (root as NSString).appendingPathComponent("wt-feature")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)

        let gitdir = (repo as NSString)
            .appendingPathComponent(".git/worktrees/wt-feature")
        try write(at: gitdir, relative: "HEAD", contents: "ref: refs/heads/feature\n")
        try write(
            at: worktree,
            relative: ".git",
            contents: "gitdir: \(gitdir)\n"
        )

        let resolved = GitBranchCache.readMetadata(at: worktree)
        #expect(resolved.branch == "feature")
        #expect(resolved.isWorktree == true)
    }

    @Test func submoduleGitdirIsNotAWorktree() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let module = (root as NSString).appendingPathComponent("vendor/lib")
        try FileManager.default.createDirectory(atPath: module, withIntermediateDirectories: true)

        let gitdir = (root as NSString).appendingPathComponent(".git/modules/lib")
        try write(at: gitdir, relative: "HEAD", contents: "ref: refs/heads/main\n")
        try write(
            at: module,
            relative: ".git",
            contents: "gitdir: \(gitdir)\n"
        )

        let resolved = GitBranchCache.readMetadata(at: module)
        #expect(resolved.branch == "main")
        #expect(resolved.isWorktree == false)
    }

    @Test func nestedPwdWalksUpToGit() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try write(at: root, relative: ".git/HEAD", contents: "ref: refs/heads/dev\n")
        let nested = (root as NSString).appendingPathComponent("src/app")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)

        let resolved = GitBranchCache.readMetadata(at: nested)
        #expect(resolved.branch == "dev")
        #expect(resolved.isWorktree == false)
    }

    @Test func gitdirWithDotDotThroughWorktreesIsNotAWorktree() throws {
        // Substring ".git/worktrees/" appears in the raw gitdir line, but
        // after path standardization it resolves to .git/modules/<name>.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let module = (root as NSString).appendingPathComponent("vendor/lib")
        try FileManager.default.createDirectory(atPath: module, withIntermediateDirectories: true)

        let moduleGitdir = (root as NSString).appendingPathComponent(".git/modules/lib")
        try write(at: moduleGitdir, relative: "HEAD", contents: "ref: refs/heads/main\n")
        // Also create the decoy worktrees segment the .. path walks through.
        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent(".git/worktrees/decoy"),
            withIntermediateDirectories: true
        )
        let sneakyGitdir = (root as NSString)
            .appendingPathComponent(".git/worktrees/decoy/../../modules/lib")
        try write(
            at: module,
            relative: ".git",
            contents: "gitdir: \(sneakyGitdir)\n"
        )

        let resolved = GitBranchCache.readMetadata(at: module)
        #expect(resolved.branch == "main")
        #expect(resolved.isWorktree == false)
    }

    @Test func isLinkedWorktreeGitdirUsesPathComponents() {
        #expect(GitBranchCache.isLinkedWorktreeGitdir(
            "/repo/.git/worktrees/feature") == true)
        #expect(GitBranchCache.isLinkedWorktreeGitdir(
            "/repo/.git/modules/lib") == false)
        #expect(GitBranchCache.isLinkedWorktreeGitdir(
            "/repo/.git/worktrees") == false)
        // Raw string contains "/.git/worktrees/" but standardizes away.
        #expect(GitBranchCache.isLinkedWorktreeGitdir(
            "/repo/.git/worktrees/x/../../modules/lib") == false)
        #expect(GitBranchCache.isLinkedWorktreeGitdir(
            "/repo/.git/worktrees_backup/x") == false)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phanttom-git-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func write(at root: String, relative: String, contents: String) throws {
        let path = (root as NSString).appendingPathComponent(relative)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
