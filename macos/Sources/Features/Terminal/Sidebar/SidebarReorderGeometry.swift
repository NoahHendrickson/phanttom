import CoreGraphics

/// Pure geometry for sidebar reorder: which gap the cursor is proposing, and
/// how that maps onto the existing reorder APIs.
///
/// The old per-row `DropDelegate` asked each row "is the cursor in my top or
/// bottom half?", which left every gutter between rows unowned — the 4pt gap
/// between tab rows, the 8pt header→rows gap, and the 20pt gap between groups
/// were all dead space where the insertion feedback vanished. Here the whole
/// list is modelled at once as a list of *boundaries*, so every cursor
/// position resolves to exactly one target and dead zones are structurally
/// impossible.
///
/// Deliberately free of SwiftUI, AppKit and the main actor so it can be
/// tested directly (see `SidebarReorderGeometryTests`).
enum SidebarReorderGeometry {
    /// Identity of one draggable thing in the sidebar.
    enum SlotID: Hashable {
        case tab(windowNumber: Int)
        case group(id: String)

        /// Tabs and groups drag in separate universes — a tab can never land
        /// in the group order and vice versa.
        var isTab: Bool {
            if case .tab = self { return true }
            return false
        }
    }

    /// One draggable row's extent in the sidebar's named coordinate space.
    struct Slot: Equatable {
        let id: SlotID
        /// The project this slot belongs to, or nil for the pending bucket
        /// and for group headers. Tabs may only reorder within their own
        /// project — grouping follows cwd/git root, so a drop cannot
        /// reassign one — and carrying the key here lets an ineligible
        /// target be filtered out *before* it can be highlighted, rather
        /// than being accepted and then silently refused at drop time.
        let group: String?
        let frame: CGRect

        var minY: CGFloat { frame.minY }
        var maxY: CGFloat { frame.maxY }
    }

    /// The slots a drag of `dragged` is allowed to target, in list order.
    ///
    /// Includes the dragged slot itself: the boundary math describes the
    /// *undisturbed* layout, so the row being dragged still occupies its
    /// original space.
    static func eligible(
        for dragged: SlotID,
        in slots: [Slot],
        constrainToProject: Bool
    ) -> [Slot] {
        let draggedGroup = slots.first { $0.id == dragged }?.group
        return slots.filter { slot in
            guard slot.id.isTab == dragged.isTab else { return false }
            guard constrainToProject, dragged.isTab else { return true }
            return slot.group == draggedGroup
        }
    }

    /// Boundary positions for `slots` — one more than the number of slots,
    /// indexed so boundary `i` means "immediately before slot `i`" and the
    /// last means "after everything".
    ///
    /// Interior boundaries sit at the midpoint of the gutter between
    /// neighbours, so a cursor in a gap resolves to the boundary it visually
    /// straddles. The outer two sit `endPad` past the ends so "above the
    /// first row" and "below the last row" stay reachable instead of
    /// clamping awkwardly onto the first/last row's own span.
    ///
    /// Returns empty for an empty list — there is nothing to target.
    static func boundaries(of slots: [Slot], endPad: CGFloat = 6) -> [CGFloat] {
        guard let first = slots.first, let last = slots.last else { return [] }
        var result: [CGFloat] = []
        result.reserveCapacity(slots.count + 1)
        result.append(first.minY - endPad)
        for (above, below) in zip(slots, slots.dropFirst()) {
            result.append((above.maxY + below.minY) / 2)
        }
        result.append(last.maxY + endPad)
        return result
    }

    /// The boundary index nearest `cursorY`, or nil when there is nothing to
    /// target.
    ///
    /// `current` is held unless a rival boundary beats it by more than
    /// `hysteresis`, so a cursor resting near a midpoint doesn't flip-flop
    /// between two targets on sub-pixel jitter.
    static func insertion(
        cursorY: CGFloat,
        boundaries: [CGFloat],
        current: Int?,
        hysteresis: CGFloat = 4
    ) -> Int? {
        guard !boundaries.isEmpty else { return nil }

        var nearest = 0
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for (index, y) in boundaries.enumerated() {
            let distance = abs(cursorY - y)
            if distance < nearestDistance {
                nearestDistance = distance
                nearest = index
            }
        }

        guard let current,
              boundaries.indices.contains(current),
              current != nearest
        else { return nearest }

        let currentDistance = abs(cursorY - boundaries[current])
        return currentDistance - nearestDistance > hysteresis ? nearest : current
    }

    /// A move that changes nothing: dropping back at your own boundary, or
    /// at the one immediately after it. Both leave the sequence identical.
    static func isNoOp(source: Int, insertion: Int) -> Bool {
        insertion == source || insertion == source + 1
    }

    /// Convert a boundary index into the `(anchor, edge)` pair the existing
    /// reorder APIs speak — `SidebarTabManager.reorder(_:relativeTo:edge:)`
    /// and `ProjectGroupOrderStore.move(_:relativeTo:edge:visibleIDs:)`.
    ///
    /// Keeping the index model on this side of the boundary means neither of
    /// those has to change; in particular `reorder`'s macOS 26 titlebar-tab
    /// workaround stays exactly as it is.
    ///
    /// Returns nil for a no-op or an out-of-range request. `index` is into
    /// the same eligible list the boundaries came from.
    static func anchor(
        for insertion: Int,
        source: Int,
        count: Int
    ) -> (index: Int, edge: SidebarDragReorder.Edge)? {
        guard count > 0,
              (0..<count).contains(source),
              (0...count).contains(insertion),
              !isNoOp(source: source, insertion: insertion)
        else { return nil }

        // Below the source's own slot the boundary sits after the element
        // that precedes it, so step back one and anchor from the far side.
        return insertion < source
            ? (index: insertion, edge: .before)
            : (index: insertion - 1, edge: .after)
    }

    /// Where the dragged row's slot ends up once the reorder is applied, in
    /// the same coordinates as the pre-drag `slots`.
    ///
    /// Backs the post-drop glide: the difference between where the row was
    /// released and this is exactly how far it has to travel. Below its
    /// origin the row opens up right after whichever row now precedes it;
    /// above, it takes over that row's old top edge.
    static func landingMinY(
        source: Int,
        insertion: Int,
        slots: [Slot],
        draggedHeight: CGFloat
    ) -> CGFloat? {
        guard slots.indices.contains(source),
              !isNoOp(source: source, insertion: insertion),
              (0...slots.count).contains(insertion)
        else { return nil }
        return insertion < source
            ? slots[insertion].minY
            : slots[insertion - 1].maxY - draggedHeight
    }

    /// How far the slot at `index` shifts to open a gap at `insertion` while
    /// the slot at `source` is being dragged.
    ///
    /// The shift is always the *dragged* row's footprint, never the shifting
    /// row's — rows vary in height (a compact terminal row against a two-line
    /// agent card), but what every passed-over row has to absorb is the space
    /// the dragged row vacated.
    ///
    /// Drawn as a render-time offset rather than by splicing a spacer into
    /// the stack: an offset changes no layout, so it can't disturb the frames
    /// the boundary math reads, and it can't fire the rows'
    /// `.transition(.phanttomTabRow)` the way an insert would.
    static func displacement(
        index: Int,
        source: Int,
        insertion: Int,
        draggedHeight: CGFloat,
        gap: CGFloat
    ) -> CGFloat {
        guard !isNoOp(source: source, insertion: insertion) else { return 0 }
        let step = draggedHeight + gap
        // Dragging down: everything the source passes over slides up to fill
        // the space it left. Dragging up: they slide down.
        if insertion > source {
            return (source + 1...insertion - 1).contains(index) ? -step : 0
        }
        return (insertion..<source).contains(index) ? step : 0
    }
}
