import Foundation

/// Derives the checkout that produced the currently running Ghostty.app
/// (local `macos/build/<Config>/` layouts only) and matches tab pwds against
/// it. Fail-closed for installed apps (`/Applications/…`): no source root,
/// no sidebar cue. See docs/plans/running-app-source-tab.md.
enum RunningAppSource {
    /// Xcode / `macos/build.nu` configurations that land under
    /// `<checkout>/macos/build/<Config>/Ghostty.app`.
    private static let buildConfigs: Set<String> = [
        "Debug", "Release", "ReleaseLocal",
    ]

    /// Checkout root for the running binary, or nil when the bundle path
    /// isn't a local build tree. Resolved once — the process doesn't move.
    static let currentSourceRoot: String? = sourceRoot(
        fromBundlePath: Bundle.main.bundleURL.path
    )

    /// Absolute, symlink-resolved, standardized path. One normalize step
    /// for both bundle stripping and containment checks.
    private static func normalizedPath(_ path: String) -> String {
        (URL(fileURLWithPath: path).resolvingSymlinksInPath().path as NSString)
            .standardizingPath
    }

    /// Strip a checkout-shaped bundle path down to its source root.
    /// Returns nil for anything that isn't
    /// `…/macos/build/{Debug|Release|ReleaseLocal}/Ghostty.app`.
    static func sourceRoot(fromBundlePath path: String) -> String? {
        let components = (normalizedPath(path) as NSString).pathComponents
        // Need at least /macos/build/<Config>/Ghostty.app (5 components when
        // rooted at "/", more with a real checkout prefix).
        guard components.count >= 5,
              components[components.count - 1] == "Ghostty.app",
              buildConfigs.contains(components[components.count - 2]),
              components[components.count - 3] == "build",
              components[components.count - 4] == "macos"
        else { return nil }
        return NSString.path(withComponents: Array(components.dropLast(4)))
    }

    /// True when `directory` is under the running app's source checkout.
    static func matchesCurrent(directory: String) -> Bool {
        guard let root = currentSourceRoot else { return false }
        return matches(directory: directory, sourceRoot: root)
    }

    /// True when `directory` is the source root or a path inside it.
    /// Boundary-safe: `/foo` does not match `/foobar`.
    static func matches(directory: String, sourceRoot: String) -> Bool {
        let dir = normalizedPath(directory)
        let root = normalizedPath(sourceRoot)
        if dir == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return dir.hasPrefix(prefix)
    }
}
