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

    /// Pin a project root to the front of the saved display order. Used by
    /// the Sessions header (+ / ~/Developer) so a newly opened project
    /// isn't stuck at the bottom behind first-appearance appends.
    func bringToFront(_ id: String) {
        let key = URL(fileURLWithPath: id).standardizedFileURL.path
        var next = order.filter { $0 != key && $0 != id }
        next.insert(key, at: 0)
        guard next != order else { return }
        order = next
        persist()
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
    /// currently visible project roots, then splice that new visible sequence
    /// back into the full stored order. Roots absent from `visibleIDs` (closed
    /// projects) are preserved in storage at their existing slots so reopening
    /// one returns it to its old position — honoring `merge`'s contract rather
    /// than persisting only the visible list. First-seen unknowns get locked
    /// into their slot once the user reorders.
    func move(
        _ sourceID: String,
        relativeTo targetID: String,
        edge: SidebarDragReorder.Edge,
        visibleIDs: [String]
    ) {
        guard sourceID != targetID else { return }

        // Compute the reordered *visible* sequence exactly as displayed.
        var visible = Self.merge(order: order, appearing: visibleIDs)
        guard let from = visible.firstIndex(of: sourceID),
              let to = visible.firstIndex(of: targetID),
              from != to
        else { return }

        // Already in the requested slot — nothing to do.
        switch edge {
        case .before where from == to - 1: return
        case .after where from == to + 1: return
        default: break
        }

        visible.remove(at: from)
        guard let newTo = visible.firstIndex(of: targetID) else { return }
        switch edge {
        case .before: visible.insert(sourceID, at: newTo)
        case .after: visible.insert(sourceID, at: newTo + 1)
        }

        // Splice `visible` back into the full stored order: keep every stored
        // id, appending any brand-new visible ids, then refill the slots
        // occupied by visible ids with the reordered sequence. Closed ids stay
        // anchored at their absolute positions between their visible neighbors.
        let visibleSet = Set(visibleIDs)
        var full = order
        for id in visibleIDs where !full.contains(id) {
            full.append(id)
        }
        var nextVisible = visible.makeIterator()
        order = full.map { id in
            visibleSet.contains(id) ? (nextVisible.next() ?? id) : id
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(order, forKey: Self.key)
    }
}
