import AppKit

/// The process-global pwd → git branch mapping shown in sidebar rows.
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

    /// pwd → last resolved branch. A stored nil means "resolved: not on a
    /// branch" (non-git pwd or detached HEAD) — distinct from no entry, so
    /// always write through `updateValue` (subscript-assigning nil would
    /// remove the key and defeat the throttle).
    private var branches: [String: String?] = [:]
    private var lastResolvedAt: [String: ContinuousClock.Instant] = [:]
    private var inFlight: Set<String> = []
    private let revalidateInterval: Duration = .seconds(2)

    /// The last known branch for `pwd`, immediately. Schedules a background
    /// (re)resolve when the value is stale and none is already running.
    func branch(at pwd: String) -> String? {
        let now = ContinuousClock.now
        let fresh = lastResolvedAt[pwd].map { now - $0 < revalidateInterval } ?? false
        if !fresh, !inFlight.contains(pwd) {
            inFlight.insert(pwd)
            prune(now: now)
            Task.detached(priority: .utility) { [weak self] in
                let resolved = Self.readBranch(at: pwd)
                await self?.finishResolve(pwd: pwd, resolved: resolved)
            }
        }
        return branches[pwd] ?? nil
    }

    private func finishResolve(pwd: String, resolved: String?) {
        inFlight.remove(pwd)
        lastResolvedAt[pwd] = ContinuousClock.now
        let changed = (branches[pwd] ?? nil) != resolved
        branches.updateValue(resolved, forKey: pwd)
        if changed {
            NotificationCenter.default.post(
                name: .phanttomSidebarTabsDidChange, object: nil)
        }
    }

    /// Keep the mapping from accumulating dead pwds.
    private func prune(now: ContinuousClock.Instant) {
        guard branches.count > 32 else { return }
        for (pwd, at) in lastResolvedAt where now - at > .seconds(60) {
            guard !inFlight.contains(pwd) else { continue }
            branches.removeValue(forKey: pwd)
            lastResolvedAt.removeValue(forKey: pwd)
        }
    }

    /// Read the git branch from .git/HEAD, walking up from the directory.
    /// Supports worktrees, where `.git` is a file pointing at the real
    /// git dir. Runs detached — never on the main actor.
    nonisolated static func readBranch(at pwd: String) -> String? {
        var dir = pwd
        while dir != "/", !dir.isEmpty {
            let gitPath = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) {
                let headPath: String
                if isDir.boolValue {
                    headPath = (gitPath as NSString).appendingPathComponent("HEAD")
                } else if let contents = try? String(contentsOfFile: gitPath, encoding: .utf8),
                          let gitdirLine = contents
                            .split(separator: "\n")
                            .first(where: { $0.hasPrefix("gitdir: ") }) {
                    let gitdir = String(gitdirLine.dropFirst("gitdir: ".count))
                        .trimmingCharacters(in: .whitespaces)
                    let resolved = (gitdir as NSString).isAbsolutePath
                        ? gitdir
                        : (dir as NSString).appendingPathComponent(gitdir)
                    headPath = (resolved as NSString).appendingPathComponent("HEAD")
                } else {
                    return nil
                }
                guard let head = try? String(contentsOfFile: headPath, encoding: .utf8)
                else { return nil }
                let prefix = "ref: refs/heads/"
                if head.hasPrefix(prefix) {
                    return head.dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil // detached HEAD
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}
