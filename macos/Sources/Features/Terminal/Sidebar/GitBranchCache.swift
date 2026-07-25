import AppKit

/// The process-global pwd → git metadata (branch + project root + worktree)
/// mapping shown in sidebar rows.
///
/// One store, readable synchronously on the main actor: the accessors are
/// peeks that return the last resolved value immediately and — at most once
/// per revalidate interval, deduped while in flight — kick a detached
/// filesystem resolve so the UI path never walks `.git/HEAD`. When a
/// resolved value changes, it posts `.phanttomSidebarTabsDidChange`, which
/// every sidebar manager already observes, so `git checkout` shows up
/// within seconds in every window with that pwd.
@MainActor
final class GitBranchCache {
    static let shared = GitBranchCache()

    /// What one filesystem resolve learns about a pwd. `projectRoot` is the
    /// repository's top-level directory, with linked worktrees resolved to
    /// the repository they belong to — the sidebar's "project" identity, so
    /// a worktree tab groups with its parent repo's tabs. `isWorktree`
    /// distinguishes those linked-worktree checkouts; the sidebar's branch
    /// glyph reacts to it.
    struct Resolved: Equatable {
        var branch: String?
        var projectRoot: String?
        /// True when the pwd lives in a linked git worktree (`.git` is a
        /// file whose `gitdir:` points under `<repo>/.git/worktrees/`).
        var isWorktree: Bool = false
        /// True when the repository declares a remote hosted on github.com.
        /// Gates the `gh`-backed PR lookup: without this, opening a tab in
        /// any git directory — a repo you just cloned to look at, a vendored
        /// checkout, a non-GitHub repo — spawns `gh` there and makes an
        /// authenticated request that can only ever come back empty.
        var hasGitHubRemote: Bool = false
    }

    /// pwd → last resolved metadata. A stored empty value means "resolved:
    /// not a git pwd" — distinct from no entry, so always write through
    /// `updateValue` semantics (the throttle relies on the key existing).
    private var resolved: [String: Resolved] = [:]
    private var lastResolvedAt: [String: ContinuousClock.Instant] = [:]
    private var inFlight: Set<String> = []
    private let revalidateInterval: Duration = .seconds(2)

    /// The last known metadata for `pwd`, immediately — one call per cache
    /// entry; callers pick the fields they need from the snapshot.
    /// Schedules a background (re)resolve when the value is stale and none
    /// is already running.
    ///
    /// Returns nil while the pwd has never finished a resolve (including
    /// after a prune evicted it) — "unknown" is distinct from "resolved:
    /// not a git pwd", so callers can hold their last known value instead
    /// of regrouping rows through a wrong interim state.
    func metadata(at pwd: String) -> Resolved? {
        let now = ContinuousClock.now
        let fresh = lastResolvedAt[pwd].map { now - $0 < revalidateInterval } ?? false
        if !fresh, !inFlight.contains(pwd) {
            inFlight.insert(pwd)
            prune(now: now)
            Task.detached(priority: .utility) { [weak self] in
                let value = Self.readMetadata(at: pwd)
                await self?.finishResolve(pwd: pwd, value: value)
            }
        }
        return resolved[pwd]
    }

    private func finishResolve(pwd: String, value: Resolved) {
        inFlight.remove(pwd)
        lastResolvedAt[pwd] = ContinuousClock.now
        let changed = (resolved[pwd] ?? Resolved()) != value
        resolved[pwd] = value
        if changed {
            NotificationCenter.default.post(
                name: .phanttomSidebarTabsDidChange, object: nil)
        }
    }

    /// Keep the mapping from accumulating dead pwds.
    private func prune(now: ContinuousClock.Instant) {
        guard resolved.count > 32 else { return }
        for (pwd, at) in lastResolvedAt where now - at > .seconds(60) {
            guard !inFlight.contains(pwd) else { continue }
            resolved.removeValue(forKey: pwd)
            lastResolvedAt.removeValue(forKey: pwd)
        }
    }

    /// Read git metadata by walking up from the directory to the nearest
    /// `.git`. Supports worktrees, where `.git` is a file pointing at the
    /// real git dir. Runs detached — never on the main actor.
    nonisolated static func readMetadata(at pwd: String) -> Resolved {
        var dir = pwd
        while dir != "/", !dir.isEmpty {
            let gitPath = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) {
                let headPath: String
                // Where this checkout's remotes are declared. For a linked
                // worktree that is the parent repo's config (worktrees share
                // the common dir), which is also where its remotes live.
                let configPath: String
                var projectRoot = dir
                var isWorktree = false
                if isDir.boolValue {
                    headPath = (gitPath as NSString).appendingPathComponent("HEAD")
                    configPath = (gitPath as NSString).appendingPathComponent("config")
                } else if let contents = try? String(contentsOfFile: gitPath, encoding: .utf8),
                          let gitdirLine = contents
                            .split(separator: "\n")
                            .first(where: { $0.hasPrefix("gitdir: ") }) {
                    let gitdir = String(gitdirLine.dropFirst("gitdir: ".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let gitdirResolved = (gitdir as NSString).isAbsolutePath
                        ? gitdir
                        : (dir as NSString).appendingPathComponent(gitdir)
                    headPath = (gitdirResolved as NSString).appendingPathComponent("HEAD")
                    // Normalize the resolved gitdir once (`..`/`.` folded, no
                    // filesystem touch) so the worktree verdict below and the
                    // projectRoot strip read the *same* string and can't
                    // disagree — otherwise a `.`/`..` segment could leave the
                    // verdict lexical but the projectRoot unnormalized.
                    let normalizedGitdir = NSString.path(
                        withComponents: lexicallyNormalizedPathComponents(gitdirResolved))
                    // A linked worktree's gitdir lives at
                    // <repo>/.git/worktrees/<name>; its project is <repo>,
                    // so worktree tabs group with the repository they came
                    // from. Anything else (e.g. a submodule's
                    // .git/modules/<name>) keeps the worktree dir itself. A
                    // gitdir that merely routes *through* a worktrees path
                    // doesn't count (the fold above collapses it).
                    isWorktree = isLinkedWorktreeGitdir(normalizedGitdir)
                    if isWorktree,
                       let range = normalizedGitdir.range(of: "/.git/worktrees/") {
                        // Standardize so this string-equals the parent repo's
                        // pwd used for project grouping.
                        projectRoot = URL(
                            fileURLWithPath: String(normalizedGitdir[..<range.lowerBound])
                        ).standardizedFileURL.path
                    }
                    configPath = isWorktree
                        ? ((projectRoot as NSString)
                            .appendingPathComponent(".git") as NSString)
                            .appendingPathComponent("config")
                        : (normalizedGitdir as NSString)
                            .appendingPathComponent("config")
                } else {
                    return Resolved()
                }
                let hasGitHubRemote = configHasGitHubRemote(atPath: configPath)
                // Unreadable HEAD: no usable checkout — keep the project
                // identity for grouping, but don't claim worktree (a future
                // glyph shouldn't badge a broken dir).
                guard let head = try? String(contentsOfFile: headPath, encoding: .utf8)
                else {
                    return Resolved(
                        branch: nil,
                        projectRoot: projectRoot,
                        hasGitHubRemote: hasGitHubRemote)
                }
                let prefix = "ref: refs/heads/"
                let branch: String? = head.hasPrefix(prefix)
                    ? head.dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil // detached HEAD
                return Resolved(
                    branch: branch,
                    projectRoot: projectRoot,
                    isWorktree: isWorktree,
                    hasGitHubRemote: hasGitHubRemote)
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return Resolved()
    }

    /// True when the git config at `path` declares at least one remote on
    /// github.com. Text-only: the file is read, never executed, and no git
    /// subprocess runs in the repository to answer this.
    nonisolated static func configHasGitHubRemote(atPath path: String) -> Bool {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8)
        else { return false }
        var inRemoteSection = false
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inRemoteSection = line.lowercased().hasPrefix("[remote")
                continue
            }
            guard inRemoteSection, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "url" || key == "pushurl" else { continue }
            if isGitHubRemote(String(line[line.index(after: eq)...])) { return true }
        }
        return false
    }

    /// Whether a remote URL points at github.com — matched on the host, so
    /// `evil-github.com` and `github.com.example.net` do not qualify.
    nonisolated static func isGitHubRemote(_ url: String) -> Bool {
        let s = url.trimmingCharacters(in: .whitespaces).lowercased()
        for marker in [
            "://github.com/", "://github.com:", "@github.com/", "@github.com:",
        ] where s.contains(marker) {
            return true
        }
        return s.hasPrefix("github.com:") || s.hasPrefix("github.com/")
    }

    /// True when `gitdir` is a linked worktree git dir:
    /// `<repo>/.git/worktrees/<name>` after purely lexical `..` / `.` folding
    /// (no filesystem touch — unlike `standardizingPath`).
    nonisolated static func isLinkedWorktreeGitdir(_ gitdir: String) -> Bool {
        let components = lexicallyNormalizedPathComponents(gitdir)
        // Anchor on the last `.git` so an ancestor directory literally named
        // `.git` (e.g. `~/.git/backups/repo/.git/worktrees/…`) doesn't win.
        guard let gitIdx = components.lastIndex(of: ".git") else { return false }
        return gitIdx + 2 < components.count
            && components[gitIdx + 1] == "worktrees"
            && components[gitIdx + 2] != "."
            && components[gitIdx + 2] != ".."
    }

    /// Collapse `.` / `..` in a path without consulting the filesystem.
    nonisolated static func lexicallyNormalizedPathComponents(_ path: String) -> [String] {
        var stack: [String] = []
        for component in (path as NSString).pathComponents {
            if component == "." { continue }
            if component == ".." {
                if stack.last != nil, stack.last != "/" {
                    stack.removeLast()
                }
                continue
            }
            stack.append(component)
        }
        return stack
    }
}
