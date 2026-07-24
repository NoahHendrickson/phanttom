import SwiftUI

/// Persisted display order for sidebar project groups, keyed by project root
/// path. Process-global like `ProjectCollapseStore` — every window in a tab
/// group hosts its own SidebarView, so instance state would desync. Grouping
/// itself stays presentation-only; this only overrides first-appearance order.
@MainActor
final class ProjectGroupOrderStore: ObservableObject {
    static let shared = ProjectGroupOrderStore()

    @Published private(set) var order: [String]

    private static let key = "PhanttomProjectGroupOrder"

    private init() {
        order = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    /// Merge a saved order with the roots currently appearing: saved keys
    /// keep their relative order, then first-seen unknowns append in
    /// `appearing` order. Roots absent from `appearing` are skipped (kept
    /// in storage until the next explicit move so a closed project can
    /// return to its old slot). Pure — safe to call off the main actor.
    nonisolated static func merge(order: [String], appearing: [String]) -> [String] {
        var remaining = Set(appearing)
        var result: [String] = []
        result.reserveCapacity(appearing.count)
        for id in order {
            if remaining.remove(id) != nil {
                result.append(id)
            }
        }
        for id in appearing where remaining.contains(id) {
            result.append(id)
            remaining.remove(id)
        }
        return result
    }

    /// Reorder `sourceID` immediately before or after `targetID` among the
    /// currently visible project roots. Persists the resulting visible
    /// sequence (unknowns get locked into their slot once the user reorders).
    func move(
        _ sourceID: String,
        relativeTo targetID: String,
        edge: SidebarDragReorder.Edge,
        visibleIDs: [String]
    ) {
        guard sourceID != targetID else { return }
        var list = Self.merge(order: order, appearing: visibleIDs)
        guard let from = list.firstIndex(of: sourceID),
              let to = list.firstIndex(of: targetID),
              from != to
        else { return }

        switch edge {
        case .before where from == to - 1: return
        case .after where from == to + 1: return
        default: break
        }

        list.remove(at: from)
        guard let newTo = list.firstIndex(of: targetID) else { return }
        switch edge {
        case .before: list.insert(sourceID, at: newTo)
        case .after: list.insert(sourceID, at: newTo + 1)
        }
        order = list
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(order, forKey: Self.key)
    }
}
