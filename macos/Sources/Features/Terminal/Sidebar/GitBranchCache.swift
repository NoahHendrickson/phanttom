import Foundation

/// Cached `.git/HEAD` branch lookups keyed by working directory. Resolves
/// off the main actor so sidebar refresh never does synchronous filesystem
/// walks on the UI path. Always revalidates (throttled) so `git checkout`
/// is reflected; callers must still guard completions against a stale pwd.
actor GitBranchCache {
    static let shared = GitBranchCache()

    private var cache: [String: String?] = [:]
    private var lastResolvedAt: [String: ContinuousClock.Instant] = [:]
    private let revalidateInterval: Duration = .seconds(2)

    /// Resolve the branch for `pwd`. Publishes a cached value immediately
    /// when it differs from `known`, then re-reads `.git/HEAD` (unless a
    /// recent resolve is still fresh and `force` is false).
    func branch(
        at pwd: String,
        known: String?,
        force: Bool = false,
        onUpdate: @MainActor @Sendable (String?) -> Void
    ) async -> String? {
        if let cached = cache[pwd], cached != known {
            await onUpdate(cached)
        }

        let now = ContinuousClock.now
        if !force,
           let cached = cache[pwd],
           let last = lastResolvedAt[pwd],
           now - last < revalidateInterval {
            return cached
        }

        let resolved = Self.readBranch(at: pwd)
        cache[pwd] = resolved
        lastResolvedAt[pwd] = now
        if resolved != known {
            await onUpdate(resolved)
        }
        return resolved
    }

    /// Drop a directory from the cache (pwd change or window left the group).
    func invalidate(_ pwd: String) {
        cache.removeValue(forKey: pwd)
        lastResolvedAt.removeValue(forKey: pwd)
    }

    /// Read the git branch from `.git/HEAD`, walking up from the directory.
    nonisolated static func readBranch(at pwd: String) -> String? {
        var dir = pwd
        while dir != "/", !dir.isEmpty {
            let headPath = (dir as NSString).appendingPathComponent(".git/HEAD")
            if let contents = try? String(contentsOfFile: headPath, encoding: .utf8) {
                let prefix = "ref: refs/heads/"
                if contents.hasPrefix(prefix) {
                    return contents.dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil // detached HEAD
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}
