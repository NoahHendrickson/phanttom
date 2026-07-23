import Foundation

/// Cached `.git/HEAD` branch lookups keyed by working directory. Resolves
/// off the main actor so sidebar refresh never does synchronous filesystem
/// walks on the UI path. Always revalidates (throttled) so `git checkout`
/// is reflected within seconds; callers guard completions against stale
/// pwds by re-reading their own state in `onUpdate`.
///
/// Shared across all windows' managers — the pwd → branch mapping is global.
actor GitBranchCache {
    static let shared = GitBranchCache()

    private var cache: [String: String?] = [:]
    private var lastResolvedAt: [String: ContinuousClock.Instant] = [:]
    private let revalidateInterval: Duration = .seconds(2)

    /// Resolve the branch for `pwd`. Publishes a cached value immediately
    /// when it differs from `known`, then re-reads `.git/HEAD` unless a
    /// recent resolve is still fresh. `onUpdate` runs on the main actor and
    /// only when the value differs from `known`.
    func branch(
        at pwd: String,
        known: String?,
        onUpdate: @MainActor @Sendable (String?) -> Void
    ) async {
        if let cached = cache[pwd], cached != known {
            await onUpdate(cached)
        }

        let now = ContinuousClock.now
        if cache[pwd] != nil,
           let last = lastResolvedAt[pwd],
           now - last < revalidateInterval {
            return
        }

        // Keep the cache from accumulating dead pwds.
        if cache.count > 32 {
            let stale = lastResolvedAt.filter { now - $0.value > .seconds(60) }.keys
            for pwd in stale {
                cache.removeValue(forKey: pwd)
                lastResolvedAt.removeValue(forKey: pwd)
            }
        }

        let resolved = Self.readBranch(at: pwd)
        cache[pwd] = resolved
        lastResolvedAt[pwd] = now
        if resolved != known {
            await onUpdate(resolved)
        }
    }

    /// Read the git branch from .git/HEAD, walking up from the directory.
    /// Supports worktrees, where `.git` is a file pointing at the real
    /// git dir.
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
