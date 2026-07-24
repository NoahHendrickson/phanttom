import Testing
import Foundation
@testable import Ghostty

/// Geometry behind sidebar tab/group reorder. The cases that matter most are
/// the ones the old per-row drop delegate got wrong: cursor positions in the
/// gutters between rows, past the ends of the list, and over targets the drop
/// would ultimately refuse.
struct SidebarReorderGeometryTests {
    private typealias Geometry = SidebarReorderGeometry
    private typealias Slot = SidebarReorderGeometry.Slot
    private typealias SlotID = SidebarReorderGeometry.SlotID

    /// Four 32pt tab rows stacked with the sidebar's real 4pt spacing:
    /// 0...32, 36...68, 72...104, 108...140.
    private static let rowHeight: CGFloat = 32
    private static let rowSpacing: CGFloat = 4

    private func tabs(_ count: Int, group: String? = "/proj") -> [Slot] {
        (0..<count).map { index in
            Slot(
                id: .tab(windowNumber: index),
                group: group,
                frame: CGRect(
                    x: 0,
                    y: CGFloat(index) * (Self.rowHeight + Self.rowSpacing),
                    width: 200,
                    height: Self.rowHeight))
        }
    }

    // MARK: - Boundaries

    @Test func interiorBoundariesSitInTheGutterMidpoint() {
        let bounds = Geometry.boundaries(of: tabs(4))
        // 4 slots -> 5 boundaries. Interior ones bisect each 4pt gap.
        #expect(bounds.count == 5)
        #expect(bounds[1] == 34)
        #expect(bounds[2] == 70)
        #expect(bounds[3] == 106)
    }

    @Test func outerBoundariesSitBeyondTheEnds() {
        let bounds = Geometry.boundaries(of: tabs(4), endPad: 6)
        #expect(bounds.first == -6)
        #expect(bounds.last == 146)
    }

    @Test func emptyListHasNoBoundaries() {
        #expect(Geometry.boundaries(of: []).isEmpty)
    }

    @Test func singleSlotStillHasBothBoundaries() {
        let bounds = Geometry.boundaries(of: tabs(1), endPad: 6)
        #expect(bounds == [-6, 38])
    }

    // MARK: - Insertion targeting
    // Every cursor position must resolve. The old delegate returned nothing
    // in the gutters, which is what made drops feel pixel-perfect.

    @Test func cursorInAGutterResolvesToThatGutter() {
        let bounds = Geometry.boundaries(of: tabs(4))
        // y = 34 is the exact centre of the 32...36 gap between rows 0 and 1.
        #expect(Geometry.insertion(cursorY: 34, boundaries: bounds, current: nil) == 1)
    }

    @Test func cursorPastTheEndResolvesToTheLastBoundary() {
        let bounds = Geometry.boundaries(of: tabs(4))
        #expect(Geometry.insertion(cursorY: 900, boundaries: bounds, current: nil) == 4)
    }

    @Test func cursorAboveTheListResolvesToTheFirstBoundary() {
        let bounds = Geometry.boundaries(of: tabs(4))
        #expect(Geometry.insertion(cursorY: -900, boundaries: bounds, current: nil) == 0)
    }

    @Test func cursorInAWideGroupGapStillResolves() {
        // Two group headers 16pt tall separated by the sidebar's 20pt group
        // spacing: 0...16 and 36...52. The whole gap used to be dead space.
        let headers = [
            Slot(id: .group(id: "a"), group: nil,
                 frame: CGRect(x: 0, y: 0, width: 200, height: 16)),
            Slot(id: .group(id: "b"), group: nil,
                 frame: CGRect(x: 0, y: 36, width: 200, height: 16)),
        ]
        let bounds = Geometry.boundaries(of: headers)
        for y in stride(from: CGFloat(17), through: 35, by: 1) {
            #expect(Geometry.insertion(cursorY: y, boundaries: bounds, current: nil) == 1)
        }
    }

    @Test func emptyBoundariesTargetNothing() {
        #expect(Geometry.insertion(cursorY: 10, boundaries: [], current: nil) == nil)
    }

    // MARK: - Hysteresis

    @Test func jitterAroundABoundaryDoesNotFlipTheTarget() {
        let bounds = Geometry.boundaries(of: tabs(4))
        // Boundaries 1 and 2 are at 34 and 70; their midpoint is 52. Walk a
        // cursor back and forth across it by less than the hysteresis and the
        // target must stay put.
        var current: Int? = 1
        for y in [CGFloat(51), 53, 51, 53, 52] {
            current = Geometry.insertion(cursorY: y, boundaries: bounds, current: current)
            #expect(current == 1)
        }
    }

    @Test func aDecisiveMoveStillFlipsTheTarget() {
        let bounds = Geometry.boundaries(of: tabs(4))
        #expect(Geometry.insertion(cursorY: 70, boundaries: bounds, current: 1) == 2)
    }

    @Test func staleCurrentIndexIsIgnored() {
        let bounds = Geometry.boundaries(of: tabs(4))
        // `current` left over from a longer list must not be trusted.
        #expect(Geometry.insertion(cursorY: 34, boundaries: bounds, current: 99) == 1)
    }

    // MARK: - Eligibility
    // Filtering here is what stops the sidebar offering a target it will then
    // silently refuse — the old delegate validated type only.

    @Test func constrainedTabDragExcludesOtherProjects() {
        let slots = tabs(2, group: "/a") + [
            Slot(id: .tab(windowNumber: 9), group: "/b",
                 frame: CGRect(x: 0, y: 200, width: 200, height: 32)),
        ]
        let eligible = Geometry.eligible(
            for: .tab(windowNumber: 0), in: slots, constrainToProject: true)
        #expect(eligible.count == 2)
        #expect(!eligible.contains { $0.id == .tab(windowNumber: 9) })
    }

    @Test func unconstrainedTabDragSeesEveryTab() {
        let slots = tabs(2, group: "/a") + [
            Slot(id: .tab(windowNumber: 9), group: "/b",
                 frame: CGRect(x: 0, y: 200, width: 200, height: 32)),
        ]
        let eligible = Geometry.eligible(
            for: .tab(windowNumber: 0), in: slots, constrainToProject: false)
        #expect(eligible.count == 3)
    }

    @Test func pendingTabsReorderAmongThemselves() {
        // The pending bucket shares a nil project key.
        let slots = tabs(2, group: nil) + tabs(1, group: "/a")
        let eligible = Geometry.eligible(
            for: .tab(windowNumber: 0), in: slots, constrainToProject: true)
        #expect(eligible.allSatisfy { $0.group == nil })
    }

    @Test func groupDragNeverTargetsTabs() {
        let slots = [
            Slot(id: .group(id: "a"), group: nil,
                 frame: CGRect(x: 0, y: 0, width: 200, height: 16)),
        ] + tabs(3)
        let eligible = Geometry.eligible(
            for: .group(id: "a"), in: slots, constrainToProject: true)
        #expect(eligible.count == 1)
        #expect(eligible[0].id == .group(id: "a"))
    }

    /// A group's slot spans its whole block — header plus tabs — so dragging
    /// a project carries its tabs with it. Blocks therefore vary wildly in
    /// height: a collapsed project is a bare 16pt header, an expanded one
    /// with three tabs is well over 100pt.
    @Test func groupSlotsSpanWholeBlocksOfVaryingHeight() {
        // Expanded (16 header + 8 + three 32pt rows on a 36pt pitch = 132),
        // then collapsed, then expanded with one tab. 20pt between blocks.
        let slots = [
            Slot(id: .group(id: "a"), group: nil,
                 frame: CGRect(x: 0, y: 0, width: 200, height: 132)),
            Slot(id: .group(id: "b"), group: nil,
                 frame: CGRect(x: 0, y: 152, width: 200, height: 16)),
            Slot(id: .group(id: "c"), group: nil,
                 frame: CGRect(x: 0, y: 188, width: 200, height: 56)),
        ]
        let eligible = Geometry.eligible(
            for: .group(id: "b"), in: slots, constrainToProject: true)
        #expect(eligible.count == 3)

        // Boundaries bisect the 20pt gutters between blocks, not the rows
        // inside them.
        let bounds = Geometry.boundaries(of: eligible)
        #expect(bounds.count == 4)
        #expect(bounds[1] == 142)
        #expect(bounds[2] == 178)

        // A cursor anywhere inside the tall first block still targets a
        // boundary outside it — never a position among its tabs.
        #expect(Geometry.insertion(cursorY: 60, boundaries: bounds, current: nil) == 0)
    }

    /// Everything a dragged block passes shifts by *that block's* height, so
    /// moving a fat project opens a fat gap and moving a collapsed one opens
    /// a thin gap.
    @Test func blocksDisplaceByTheDraggedBlocksOwnHeight() {
        let fat = Geometry.displacement(
            index: 1, source: 0, insertion: 3, draggedHeight: 132, gap: 20)
        let thin = Geometry.displacement(
            index: 1, source: 0, insertion: 3, draggedHeight: 16, gap: 20)
        #expect(fat == -152)
        #expect(thin == -36)
    }

    // MARK: - No-ops

    @Test func droppingAtEitherOwnBoundaryChangesNothing() {
        #expect(Geometry.isNoOp(source: 2, insertion: 2))
        #expect(Geometry.isNoOp(source: 2, insertion: 3))
        #expect(!Geometry.isNoOp(source: 2, insertion: 1))
        #expect(!Geometry.isNoOp(source: 2, insertion: 4))
    }

    @Test func noOpYieldsNoAnchor() {
        #expect(Geometry.anchor(for: 2, source: 2, count: 5) == nil)
        #expect(Geometry.anchor(for: 3, source: 2, count: 5) == nil)
    }

    @Test func outOfRangeYieldsNoAnchor() {
        #expect(Geometry.anchor(for: 9, source: 0, count: 5) == nil)
        #expect(Geometry.anchor(for: 1, source: 9, count: 5) == nil)
        #expect(Geometry.anchor(for: 0, source: 0, count: 0) == nil)
    }

    // MARK: - Anchor conversion
    // The index model has to come back out as the (anchor, edge) pair
    // SidebarTabManager.reorder and ProjectGroupOrderStore.move already speak.

    @Test func draggingDownAnchorsAfterThePrecedingRow() {
        let anchor = Geometry.anchor(for: 3, source: 0, count: 5)
        #expect(anchor?.index == 2)
        #expect(anchor?.edge == .after)
    }

    @Test func draggingUpAnchorsBeforeTheTargetRow() {
        let anchor = Geometry.anchor(for: 1, source: 4, count: 5)
        #expect(anchor?.index == 1)
        #expect(anchor?.edge == .before)
    }

    @Test func anchorNeverPointsAtTheDraggedRow() {
        for source in 0..<5 {
            for insertion in 0...5 {
                guard let anchor = Geometry.anchor(
                    for: insertion, source: source, count: 5) else { continue }
                #expect(anchor.index != source)
            }
        }
    }

    /// Replays `anchor` through the same remove-then-insert-relative-to-target
    /// sequence `ProjectGroupOrderStore.move` performs, so the index model is
    /// checked against real reorder semantics rather than against itself.
    private func applyMove(_ items: [String], source: Int, insertion: Int) -> [String] {
        guard let anchor = Geometry.anchor(
            for: insertion, source: source, count: items.count)
        else { return items }
        let target = items[anchor.index]
        var result = items
        let moved = result.remove(at: source)
        guard let at = result.firstIndex(of: target) else { return items }
        result.insert(moved, at: anchor.edge == .before ? at : at + 1)
        return result
    }

    @Test func moveRoundTripsToTheExpectedOrder() {
        let items = ["A", "B", "C", "D", "E"]
        #expect(applyMove(items, source: 0, insertion: 3) == ["B", "C", "A", "D", "E"])
        #expect(applyMove(items, source: 4, insertion: 1) == ["A", "E", "B", "C", "D"])
        #expect(applyMove(items, source: 2, insertion: 0) == ["C", "A", "B", "D", "E"])
        #expect(applyMove(items, source: 2, insertion: 5) == ["A", "B", "D", "E", "C"])
        // Both no-op boundaries leave the sequence untouched.
        #expect(applyMove(items, source: 2, insertion: 2) == items)
        #expect(applyMove(items, source: 2, insertion: 3) == items)
    }

    @Test func everyMovePreservesMembership() {
        let items = ["A", "B", "C", "D", "E"]
        for source in items.indices {
            for insertion in 0...items.count {
                let moved = applyMove(items, source: source, insertion: insertion)
                #expect(moved.count == items.count)
                #expect(Set(moved) == Set(items))
            }
        }
    }

    // MARK: - Displacement (the live gap)

    @Test func draggingDownSlidesThePassedRowsUp() {
        let step = Self.rowHeight + Self.rowSpacing
        // [A,B,C,D,E], A dropped between C and D: B and C slide up one step.
        #expect(displacement(index: 1, source: 0, insertion: 3) == -step)
        #expect(displacement(index: 2, source: 0, insertion: 3) == -step)
        #expect(displacement(index: 3, source: 0, insertion: 3) == 0)
        #expect(displacement(index: 4, source: 0, insertion: 3) == 0)
    }

    @Test func draggingUpSlidesThePassedRowsDown() {
        let step = Self.rowHeight + Self.rowSpacing
        // [A,B,C,D,E], E dropped between A and B: B, C and D slide down.
        #expect(displacement(index: 0, source: 4, insertion: 1) == 0)
        #expect(displacement(index: 1, source: 4, insertion: 1) == step)
        #expect(displacement(index: 2, source: 4, insertion: 1) == step)
        #expect(displacement(index: 3, source: 4, insertion: 1) == step)
    }

    @Test func theDraggedRowItselfNeverDisplaces() {
        #expect(displacement(index: 0, source: 0, insertion: 3) == 0)
        #expect(displacement(index: 4, source: 4, insertion: 1) == 0)
    }

    @Test func noOpOpensNoGap() {
        for index in 0..<5 {
            #expect(displacement(index: index, source: 2, insertion: 2) == 0)
            #expect(displacement(index: index, source: 2, insertion: 3) == 0)
        }
    }

    // MARK: - Landing position (the post-drop glide)
    // Rows are 32pt on a 36pt pitch: 0...32, 36...68, 72...104, 108...140.
    // If this is off by even a few points the released row visibly jumps
    // before it glides, which is exactly the artifact the glide exists to
    // remove.

    @Test func landingBelowOriginSitsAfterTheRowThatNowPrecedesIt() {
        // [A,B,C,D] with A dropped between C and D → B, C shift up, A takes
        // the third slot at y=72.
        let landing = Geometry.landingMinY(
            source: 0, insertion: 3, slots: tabs(4), draggedHeight: Self.rowHeight)
        #expect(landing == 72)
    }

    @Test func landingAboveOriginTakesThatRowsOldTop() {
        // [A,B,C,D] with D dropped between A and B → D takes B's old top.
        let landing = Geometry.landingMinY(
            source: 3, insertion: 1, slots: tabs(4), draggedHeight: Self.rowHeight)
        #expect(landing == 36)
    }

    @Test func landingAtTheEndsResolves() {
        #expect(Geometry.landingMinY(
            source: 2, insertion: 0, slots: tabs(4),
            draggedHeight: Self.rowHeight) == 0)
        #expect(Geometry.landingMinY(
            source: 0, insertion: 4, slots: tabs(4),
            draggedHeight: Self.rowHeight) == 108)
    }

    @Test func landingIsNilForANonMove() {
        #expect(Geometry.landingMinY(
            source: 2, insertion: 2, slots: tabs(4),
            draggedHeight: Self.rowHeight) == nil)
        #expect(Geometry.landingMinY(
            source: 2, insertion: 3, slots: tabs(4),
            draggedHeight: Self.rowHeight) == nil)
    }

    /// The glide has to end exactly where the reordered list actually puts the
    /// row — otherwise it finishes slightly off and snaps. Checked against a
    /// layout re-derived from scratch rather than against the same formula.
    @Test func landingMatchesWhereTheReorderedRowActuallySits() {
        let count = 4
        let pitch = Self.rowHeight + Self.rowSpacing
        let slots = tabs(count)
        for source in 0..<count {
            for insertion in 0...count where !Geometry.isNoOp(
                source: source, insertion: insertion) {
                guard let landing = Geometry.landingMinY(
                    source: source,
                    insertion: insertion,
                    slots: slots,
                    draggedHeight: Self.rowHeight)
                else {
                    Issue.record("no landing for \(source)→\(insertion)")
                    continue
                }
                // Apply the move to a plain array and lay the result out
                // fresh at the same pitch.
                var order = Array(0..<count)
                let moved = order.remove(at: source)
                // Removing the source shifts every later boundary down one.
                order.insert(moved, at: insertion < source ? insertion : insertion - 1)
                guard let landedIndex = order.firstIndex(of: source) else {
                    Issue.record("lost the row for \(source)→\(insertion)")
                    continue
                }
                #expect(
                    landing == CGFloat(landedIndex) * pitch,
                    "\(source)→\(insertion): landing \(landing) but row sits at index \(landedIndex)")
            }
        }
    }

    private func displacement(index: Int, source: Int, insertion: Int) -> CGFloat {
        Geometry.displacement(
            index: index,
            source: source,
            insertion: insertion,
            draggedHeight: Self.rowHeight,
            gap: Self.rowSpacing)
    }

    /// Rows vary in height, so the gap that opens must track the dragged
    /// row's footprint rather than the footprint of whatever it passes.
    @Test func gapMatchesTheDraggedRowNotThePassedRows() {
        let tall = Geometry.displacement(
            index: 1, source: 0, insertion: 3, draggedHeight: 56, gap: 4)
        let short = Geometry.displacement(
            index: 1, source: 0, insertion: 3, draggedHeight: 32, gap: 4)
        #expect(tall == -60)
        #expect(short == -36)
    }
}
