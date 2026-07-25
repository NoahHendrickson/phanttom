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
        #expect(resolved.projectRoot == root)
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
        #expect(resolved.projectRoot == repo)
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
        #expect(resolved.projectRoot == module)
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
        // Raw gitdir contains ".git/worktrees/" then `../..`, but lexical
        // folding resolves to .git/modules/<name> — not a worktree. The
        // decoy dir must exist on disk (POSIX resolves `..` component by
        // component, so HEAD would be unreadable through a missing decoy);
        // the worktree *verdict* stays purely lexical either way.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let module = (root as NSString).appendingPathComponent("vendor/lib")
        try FileManager.default.createDirectory(atPath: module, withIntermediateDirectories: true)

        let moduleGitdir = (root as NSString).appendingPathComponent(".git/modules/lib")
        try write(at: moduleGitdir, relative: "HEAD", contents: "ref: refs/heads/main\n")
        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent(".git/worktrees/decoy"),
            withIntermediateDirectories: true)
        let sneakyGitdir = (root as NSString)
            .appendingPathComponent(".git/worktrees/decoy/../../modules/lib")
        try write(
            at: module,
            relative: ".git",
            contents: "gitdir: \(sneakyGitdir)\n"
        )

        let resolved = GitBranchCache.readMetadata(at: module)
        #expect(resolved.branch == "main")
        #expect(resolved.projectRoot == module)
        #expect(resolved.isWorktree == false)
    }

    @Test func unreadableWorktreeHeadIsNotReportedAsWorktree() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let worktree = (root as NSString).appendingPathComponent("wt")
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let gitdir = (root as NSString).appendingPathComponent(".git/worktrees/wt")
        // Create the gitdir directory but leave HEAD missing/unreadable.
        try FileManager.default.createDirectory(atPath: gitdir, withIntermediateDirectories: true)
        try write(at: worktree, relative: ".git", contents: "gitdir: \(gitdir)\n")

        let resolved = GitBranchCache.readMetadata(at: worktree)
        #expect(resolved.branch == nil)
        #expect(resolved.isWorktree == false)
    }

    @Test func crlfGitFileIsTrimmed() throws {
        // A `.git` file written with CRLF line endings leaves a trailing `\r`
        // on the gitdir path unless trimmed with a CR-inclusive set; that
        // stray `\r` would make HEAD unreadable and corrupt projectRoot.
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
            contents: "gitdir: \(gitdir)\r\n"
        )

        let resolved = GitBranchCache.readMetadata(at: worktree)
        #expect(resolved.branch == "feature")
        #expect(resolved.projectRoot == repo)
        #expect(resolved.isWorktree == true)
    }

    @Test func worktreeProjectRootIsNormalized() throws {
        // The gitdir routes through a `.` segment before `/.git/worktrees/`.
        // The worktree verdict is lexical; projectRoot must be derived from
        // the same normalized string (and standardized) so it string-equals
        // the parent repo's pwd used for grouping — not `<repo>/.`.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let repo = (root as NSString).appendingPathComponent("repo")
        let worktree = (root as NSString).appendingPathComponent("wt-feature")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)

        // On-disk gitdir (POSIX resolves `.` so HEAD stays readable)…
        let gitdir = (repo as NSString)
            .appendingPathComponent(".git/worktrees/wt-feature")
        try write(at: gitdir, relative: "HEAD", contents: "ref: refs/heads/feature\n")
        // …but the recorded path carries a `.` segment (built by explicit
        // concatenation so the `.` isn't collapsed before readMetadata sees
        // it).
        let unnormalizedGitdir = repo + "/./.git/worktrees/wt-feature"
        try write(
            at: worktree,
            relative: ".git",
            contents: "gitdir: \(unnormalizedGitdir)\n"
        )

        let resolved = GitBranchCache.readMetadata(at: worktree)
        #expect(resolved.branch == "feature")
        #expect(resolved.projectRoot == repo)
        #expect(resolved.isWorktree == true)
    }

    @Test func isLinkedWorktreeGitdirUsesPathComponents() {
        #expect(GitBranchCache.isLinkedWorktreeGitdir(
            "/repo/.git/worktrees/feature") == true)
        #expect(GitBranchCache.isLinkedWorktreeGitdir(
            "/repo/.git/modules/lib") == false)
        #expect(GitBranchCache.isLinkedWorktreeGitdir(
            "/repo/.git/worktrees") == false)
        // Raw string contains "/.git/worktrees/" but folds away lexically.
        #expect(GitBranchCache.isLinkedWorktreeGitdir(
            "/repo/.git/worktrees/x/../../modules/lib") == false)
        #expect(GitBranchCache.isLinkedWorktreeGitdir(
            "/repo/.git/worktrees_backup/x") == false)
        // Ancestor dir named `.git` must not steal the anchor.
        #expect(GitBranchCache.isLinkedWorktreeGitdir(
            "/home/user/.git/backups/repo/.git/worktrees/feature") == true)
        #expect(GitBranchCache.isLinkedWorktreeGitdir(
            "/home/user/.git/backups/repo/.git/modules/lib") == false)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phanttom-git-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    // MARK: - GitHub remote detection (gates the gh-backed PR lookup)

    @Test func gitHubRemoteIsDetectedFromConfigText() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try write(at: root, relative: ".git/HEAD", contents: "ref: refs/heads/main\n")
        try write(at: root, relative: ".git/config", contents: """
            [core]
            \tbare = false
            [remote "origin"]
            \turl = git@github.com:me/repo.git
            \tfetch = +refs/heads/*:refs/remotes/origin/*
            """)

        #expect(GitBranchCache.readMetadata(at: root).hasGitHubRemote)
    }

    @Test func nonGitHubRemotesDoNotQualify() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try write(at: root, relative: ".git/HEAD", contents: "ref: refs/heads/main\n")
        try write(at: root, relative: ".git/config", contents: """
            [remote "origin"]
            \turl = https://gitlab.com/me/repo.git
            [remote "mirror"]
            \turl = https://evil-github.com/me/repo.git
            """)

        #expect(!GitBranchCache.readMetadata(at: root).hasGitHubRemote)
        // A github.com URL outside any [remote] section is not a remote.
        #expect(!GitBranchCache.isGitHubRemote("https://github.com.example.net/x"))
        #expect(GitBranchCache.isGitHubRemote("ssh://git@github.com:22/me/repo.git"))
        #expect(GitBranchCache.isGitHubRemote("github.com:me/repo.git"))
    }

    @Test func worktreeReadsTheParentRepoConfig() throws {
        // A linked worktree has no config of its own — its remotes live in
        // the common dir it shares with the repository.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let repo = (root as NSString).appendingPathComponent("repo")
        let worktree = (root as NSString).appendingPathComponent("wt-feature")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)

        let gitdir = (repo as NSString)
            .appendingPathComponent(".git/worktrees/wt-feature")
        try write(at: gitdir, relative: "HEAD", contents: "ref: refs/heads/feature\n")
        try write(at: worktree, relative: ".git", contents: "gitdir: \(gitdir)\n")
        try write(at: repo, relative: ".git/config", contents: """
            [remote "origin"]
            \turl = https://github.com/me/repo.git
            """)

        #expect(GitBranchCache.readMetadata(at: worktree).hasGitHubRemote)
    }

    private func write(at root: String, relative: String, contents: String) throws {
        let path = (root as NSString).appendingPathComponent(relative)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
