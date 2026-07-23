import Foundation
import Testing
@testable import Ghostty

/// Pure path tests for the running-app source checkout cue. No Bundle.main
/// dependency — callers feed explicit bundle paths.
@Suite
struct RunningAppSourceTests {
    @Test func stripsDebugBundle() {
        let path = "/Users/me/phanttom/macos/build/Debug/Ghostty.app"
        #expect(RunningAppSource.sourceRoot(fromBundlePath: path) == "/Users/me/phanttom")
    }

    @Test func stripsReleaseAndReleaseLocal() {
        #expect(
            RunningAppSource.sourceRoot(
                fromBundlePath: "/tmp/src/macos/build/Release/Ghostty.app"
            ) == "/tmp/src"
        )
        #expect(
            RunningAppSource.sourceRoot(
                fromBundlePath: "/tmp/src/macos/build/ReleaseLocal/Ghostty.app"
            ) == "/tmp/src"
        )
    }

    @Test func rejectsInstalledAndUnknownShapes() {
        #expect(RunningAppSource.sourceRoot(fromBundlePath: "/Applications/Ghostty.app") == nil)
        #expect(RunningAppSource.sourceRoot(fromBundlePath: "/tmp/Ghostty.app") == nil)
        #expect(
            RunningAppSource.sourceRoot(
                fromBundlePath: "/Users/me/phanttom/macos/build/Profiling/Ghostty.app"
            ) == nil
        )
        #expect(
            RunningAppSource.sourceRoot(
                fromBundlePath: "/Users/me/phanttom/zig-out/Ghostty.app"
            ) == nil
        )
    }

    @Test func matchesCheckoutRootAndSubdirectories() {
        let root = "/Users/me/phanttom"
        #expect(RunningAppSource.matches(directory: root, sourceRoot: root))
        #expect(RunningAppSource.matches(directory: root + "/macos", sourceRoot: root))
        #expect(RunningAppSource.matches(
            directory: root + "/macos/Sources/Features",
            sourceRoot: root
        ))
    }

    @Test func rejectsPathBoundaryAndSiblingCheckouts() {
        let root = "/Users/me/phanttom"
        #expect(!RunningAppSource.matches(directory: "/Users/me/phanttom-fork", sourceRoot: root))
        #expect(!RunningAppSource.matches(directory: "/Users/me/other", sourceRoot: root))
        #expect(!RunningAppSource.matches(directory: "/Users/me", sourceRoot: root))
    }

    @Test func worktreeDirectoryDoesNotMatchMainSourceRoot() {
        // Matching is on directory, not collapsed projectRoot — a tab in
        // the main checkout must not light up when the running app was
        // built from a linked worktree (and vice versa).
        #expect(!RunningAppSource.matches(
            directory: "/Users/me/phanttom",
            sourceRoot: "/Users/me/wt-feature"
        ))
        #expect(RunningAppSource.matches(
            directory: "/Users/me/wt-feature/macos",
            sourceRoot: "/Users/me/wt-feature"
        ))
    }
}
