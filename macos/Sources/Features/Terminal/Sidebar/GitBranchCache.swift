import AppKit

/// The process-global pwd → git metadata (branch + worktree) mapping shown
/// in sidebar rows.
///
/// One store, readable synchronously on the main actor: `branch(at:)` is a
/// peek that returns the last resolved value immediately and — at most once
/// per revalidate interval, deduped while in flight — kicks a detached
/// filesystem resolve so the UI path never walks `.git/HEAD`. When a
/// resolved value changes, it posts `.phanttomSidebarTabsDidChange`, which
/// every sidebar manager already observes, so `git checkout` shows up
/// within seconds in every window with that pwd.
@MainActor
final class GitBranchCache {
    static let shared = GitBranchCache()

    /// What one filesystem resolve learns about a pwd. `isWorktree` is kept
    /// on the resolve result (and covered by tests) so a future worktree
    /// icon can read it without rediscovering linked worktrees; the sidebar
    /// does not consume it yet.
    struct Resolved: Equatable {
        var branch: String?
        /// True when the pwd lives in a linked git worktree (`.git` is a
        /// file whose `gitdir:` points under `<repo>/.git/worktrees/`).
        var isWorktree: Bool = false
    }

    /// pwd → last resolved metadata. A stored empty value means "resolved:
    /// not a git pwd" — distinct from no entry, so always write through
    /// `updateValue` semantics (the throttle relies on the key existing).
    private var resolved: [String: Resolved] = [:]
    private var lastResolvedAt: [String: ContinuousClock.Instant] = [:]
    private var inFlight: Set<String> = []
    private let revalidateInterval: Duration = .seconds(2)

    /// The last known branch for `pwd`, immediately. Schedules a background
    /// (re)resolve when the value is stale and none is already running.
    func branch(at pwd: String) -> String? {
        peek(at: pwd).branch
    }

    /// Return the cached value and schedule a background (re)resolve when
    /// it's stale and none is already running.
    private func peek(at pwd: String) -> Resolved {
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
        return resolved[pwd] ?? Resolved()
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
                var isWorktree = false
                if isDir.boolValue {
                    headPath = (gitPath as NSString).appendingPathComponent("HEAD")
                } else if let contents = try? String(contentsOfFile: gitPath, encoding: .utf8),
                          let gitdirLine = contents
                            .split(separator: "\n")
                            .first(where: { $0.hasPrefix("gitdir: ") }) {
                    let gitdir = String(gitdirLine.dropFirst("gitdir: ".count))
                        .trimmingCharacters(in: .whitespaces)
                    let gitdirResolved = (gitdir as NSString).isAbsolutePath
                        ? gitdir
                        : (dir as NSString).appendingPathComponent(gitdir)
                    headPath = (gitdirResolved as NSString).appendingPathComponent("HEAD")
                    // Linked worktrees point at <repo>/.git/worktrees/<name>.
                    // Submodules use .git/modules/<name> and are not worktrees.
                    isWorktree = isLinkedWorktreeGitdir(gitdirResolved)
                } else {
                    return Resolved()
                }
                guard let head = try? String(contentsOfFile: headPath, encoding: .utf8)
                else { return Resolved(branch: nil, isWorktree: isWorktree) }
                let prefix = "ref: refs/heads/"
                let branch: String? = head.hasPrefix(prefix)
                    ? head.dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil // detached HEAD
                return Resolved(branch: branch, isWorktree: isWorktree)
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return Resolved()
    }

    /// True when `gitdir` is a linked worktree git dir:
    /// `<repo>/.git/worktrees/<name>` (after path standardization).
    nonisolated static func isLinkedWorktreeGitdir(_ gitdir: String) -> Bool {
        let components = (gitdir as NSString).standardizingPath.pathComponents
        guard let gitIdx = components.firstIndex(of: ".git") else { return false }
        return gitIdx + 2 < components.count
            && components[gitIdx + 1] == "worktrees"
            && components[gitIdx + 2] != "."
            && components[gitIdx + 2] != ".."
    }
}
