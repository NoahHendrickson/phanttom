import Foundation

/// Cached `.git/HEAD` branch lookups keyed by working directory. Resolves
/// off the main actor so sidebar refresh never does synchronous filesystem
/// walks on the UI path.
actor GitBranchCache {
    static let shared = GitBranchCache()

    private var cache: [String: String?] = [:]

    /// Return a cached branch immediately, and kick a resolve if missing.
    /// `onUpdate` is invoked on the main actor only when the value changes
    /// from what the caller last knew (passed as `known`).
    func branch(
        at pwd: String,
        known: String?,
        onUpdate: @MainActor @Sendable (String?) -> Void
    ) async -> String? {
        if let cached = cache[pwd] {
            let value = cached
            if value != known {
                await onUpdate(value)
            }
            return value
        }

        let resolved = Self.readBranch(at: pwd)
        cache[pwd] = resolved
        if resolved != known {
            await onUpdate(resolved)
        }
        return resolved
    }

    /// Drop a directory from the cache (e.g. after membership leaves).
    func invalidate(_ pwd: String) {
        cache.removeValue(forKey: pwd)
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
