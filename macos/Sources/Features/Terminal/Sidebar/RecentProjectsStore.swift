import Foundation
import SwiftUI

/// MRU list of project roots the user has opened in sidebar tabs. Still
/// recorded when opening from the home group's Developer picker (and when
/// tabs resolve a grouping key); process-global and persisted.
@MainActor
final class RecentProjectsStore: ObservableObject {
    static let shared = RecentProjectsStore()

    static let maxCount = 10

    @Published private(set) var paths: [String]

    private static let key = "PhanttomRecentProjects"

    private init() {
        paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    /// Paths still on disk, in MRU order — what the home-header menu shows.
    var existingPaths: [String] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Record a project root (git toplevel or non-git grouping directory).
    /// Home itself is excluded — opening there is what the plain "+" does.
    func record(_ path: String) {
        guard !path.isEmpty, path != NSHomeDirectory() else { return }
        var next = paths.filter { $0 != path }
        next.insert(path, at: 0)
        if next.count > Self.maxCount {
            next = Array(next.prefix(Self.maxCount))
        }
        guard next != paths else { return }
        paths = next
        UserDefaults.standard.set(paths, forKey: Self.key)
    }

    /// Sidebar group title style: last path component (home would be "~",
    /// but home is never stored).
    static func displayName(for path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
