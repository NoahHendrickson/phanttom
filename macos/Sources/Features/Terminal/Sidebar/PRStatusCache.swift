import AppKit

/// The process-global (pwd, branch) → GitHub PR state shown as sidebar
/// status dots (green = open PR, purple = merged PR).
///
/// Same peek-then-revalidate shape as `GitBranchCache`, but backed by the
/// `gh` CLI, which talks to the network — so the revalidate interval is
/// much longer and a watchdog terminates hung processes. Missing gh,
/// missing auth, a non-GitHub remote, or no PR for the branch all resolve
/// to nil (no dot).
@MainActor
final class PRStatusCache {
    enum PRState: String {
        case open = "OPEN"
        case merged = "MERGED"
    }

    static let shared = PRStatusCache()

    /// (pwd + "\0" + branch) → last resolved state. A stored nil means
    /// "resolved: no PR" — distinct from no entry, so always write through
    /// `updateValue` (subscript-assigning nil would remove the key and
    /// defeat the throttle).
    private var states: [String: PRState?] = [:]
    private var lastResolvedAt: [String: ContinuousClock.Instant] = [:]
    private var inFlight: Set<String> = []
    private let revalidateInterval: Duration = .seconds(60)

    /// The last known PR state for `branch` in `pwd`, immediately.
    /// Schedules a background (re)resolve when the value is stale and none
    /// is already running. Keyed on the branch too, so a checkout flips to
    /// the other branch's cached state without waiting out the throttle.
    func state(at pwd: String, branch: String) -> PRState? {
        let key = pwd + "\0" + branch
        let now = ContinuousClock.now
        let fresh = lastResolvedAt[key].map { now - $0 < revalidateInterval } ?? false
        if !fresh, !inFlight.contains(key) {
            inFlight.insert(key)
            prune(now: now)
            Task.detached(priority: .utility) { [weak self] in
                let resolved = Self.queryState(pwd: pwd, branch: branch)
                await self?.finishResolve(key: key, resolved: resolved)
            }
        }
        return states[key] ?? nil
    }

    private func finishResolve(key: String, resolved: PRState?) {
        inFlight.remove(key)
        lastResolvedAt[key] = ContinuousClock.now
        let changed = (states[key] ?? nil) != resolved
        states.updateValue(resolved, forKey: key)
        if changed {
            NotificationCenter.default.post(
                name: .phanttomSidebarTabsDidChange, object: nil)
        }
    }

    /// Keep the mapping from accumulating dead pwd/branch pairs.
    private func prune(now: ContinuousClock.Instant) {
        guard states.count > 32 else { return }
        for (key, at) in lastResolvedAt where now - at > .seconds(300) {
            guard !inFlight.contains(key) else { continue }
            states.removeValue(forKey: key)
            lastResolvedAt.removeValue(forKey: key)
        }
    }

    /// GUI apps don't inherit a shell PATH, so gh is probed at the usual
    /// install locations.
    nonisolated private static let ghPath: String? = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Ask gh for the PR whose head is `branch`. Runs detached — never on
    /// the main actor. CLOSED-without-merge PRs also resolve to nil; the
    /// sidebar only surfaces open and merged.
    nonisolated static func queryState(pwd: String, branch: String) -> PRState? {
        guard let gh = ghPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["pr", "view", branch, "--json", "state", "-q", ".state"]
        process.currentDirectoryURL = URL(fileURLWithPath: pwd, isDirectory: true)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // gh talks to the network; don't let a hung call pin this key's
        // in-flight slot forever.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return PRState(rawValue: raw)
    }
}
