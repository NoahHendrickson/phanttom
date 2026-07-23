import SwiftUI

/// Collapsed/expanded state for sidebar project groups, keyed by group id
/// (the project root path). Process-global because every window in a tab
/// group hosts its own SidebarView — a collapse must read the same from
/// every sidebar — and persisted so it survives relaunch.
@MainActor
final class ProjectCollapseStore: ObservableObject {
    static let shared = ProjectCollapseStore()

    @Published private(set) var collapsed: Set<String>

    private static let key = "PhanttomCollapsedProjectGroups"

    private init() {
        collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func isCollapsed(_ id: String) -> Bool {
        collapsed.contains(id)
    }

    func toggle(_ id: String) {
        if !collapsed.insert(id).inserted { collapsed.remove(id) }
        persist()
    }

    /// Make sure a group is expanded — used when a tab is created into it,
    /// so the new row doesn't land invisibly in a collapsed group.
    func expand(_ id: String) {
        guard collapsed.remove(id) != nil else { return }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(collapsed.sorted(), forKey: Self.key)
    }
}
