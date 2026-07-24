import AppKit
import SwiftUI

/// Coordinate space the sidebar's reorder geometry is expressed in. Row
/// frames and the drag gesture's location must share one space or the
/// boundary math is comparing unrelated numbers.
///
/// Spelled `.coordinateSpace(name:)` at the call site — the
/// `.coordinateSpace(.named(_:))` form is macOS 14+ and this app targets 13.1.
enum SidebarReorderSpace {
    static let name = "phanttomSidebarContent"
}

/// Hands the controller the `NSScrollView` backing SwiftUI's `ScrollView` so
/// a drag can scroll the list at its edges — SwiftUI has no continuous scroll
/// API on macOS 13 (`ScrollViewReader` only jumps to an anchored element).
///
/// Zero-sized and purely observational. If the lookup ever fails, auto-scroll
/// quietly does not happen and everything else still works.
struct SidebarScrollViewProbe: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Deferred: the view isn't in the hierarchy yet, so it has no
        // enclosing scroll view to find until the next turn.
        DispatchQueue.main.async { onResolve(view.enclosingScrollView) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// How rows publish their extent up to the controller.
struct SidebarSlotsKey: PreferenceKey {
    static var defaultValue: [SidebarReorderGeometry.Slot] = []

    static func reduce(
        value: inout [SidebarReorderGeometry.Slot],
        nextValue: () -> [SidebarReorderGeometry.Slot]
    ) {
        value += nextValue()
    }
}

/// Drives sidebar tab/group reorder: owns the live drag, resolves where it
/// would land, and hands back a reorder in the terms the existing stores
/// already speak.
///
/// One per window, injected as a plain `let`. **`SidebarView` must not
/// observe it.** Only the per-row `SidebarReorderSlot` wrapper does, so a
/// drag re-applies offsets to already-built rows instead of re-running
/// `SidebarView.body` — which would re-partition every project group and
/// rebuild every row on each mouse move, the way the old `.onDrop` path did.
@MainActor
final class SidebarReorderController: ObservableObject {
    typealias Slot = SidebarReorderGeometry.Slot
    typealias SlotID = SidebarReorderGeometry.SlotID

    /// A finished drag, phrased for `SidebarTabManager.reorder` /
    /// `ProjectGroupOrderStore.move`.
    struct Commit: Equatable {
        let dragged: SlotID
        let anchor: SlotID
        let edge: SidebarDragReorder.Edge
    }

    struct Session: Equatable {
        let dragged: SlotID
        let sourceIndex: Int
        /// The dragged row's own height and the gutter beside it — together,
        /// the space every passed-over row has to absorb.
        let draggedHeight: CGFloat
        let gap: CGFloat
        /// How far the dragged row has been pulled from its origin.
        var offset: CGFloat
        /// Boundary index the drop would use.
        var insertion: Int
        /// The drag is over and the row is gliding from where it was released
        /// into its slot. The model has already been reordered by this point;
        /// `offset` is now the leftover distance being animated away.
        var isSettling = false
    }

    @Published private(set) var session: Session?

    /// Live row extents, rewritten by the preference sink each layout pass.
    /// Deliberately **not** `@Published`: this is written at layout rate and
    /// nothing should re-render because of it.
    private var slots: [Slot] = []

    /// The targetable subset, frozen when the drag starts. Freezing matters:
    /// the dragged row and the rows parting around it are offset while a drag
    /// is live, so re-reading their frames would feed the displaced layout
    /// back into the boundary math and make the target oscillate.
    private var eligible: [Slot] = []
    private var boundaries: [CGFloat] = []

    /// Escape-to-cancel and the safety net for a drag that never gets its
    /// `onEnded`. AppKit drag-and-drop supplied both for free; a raw
    /// `DragGesture` supplies neither, and a lost end would strand the
    /// dragged row permanently off-position.
    private var escapeMonitor: Any?
    private var mouseUpMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// Pending teardown of the post-drop glide.
    private var settleWork: DispatchWorkItem?

    var isDragging: Bool { session != nil }

    /// True from the moment a drag actually starts until one runloop turn
    /// after it ends, so the row's select tap can tell a click from a drag.
    ///
    /// Raised inside `begin`, which runs off a mouse-*moved* event and
    /// therefore strictly precedes the mouse-up the tap fires on. Lowered a
    /// turn later rather than inline because SwiftUI does not document
    /// whether `TapGesture.onEnded` or `DragGesture.onEnded` runs first.
    /// Plain stored state — reading it must not subscribe anyone.
    private(set) var didDrag = false

    // MARK: - Layout intake

    func replaceSlots(_ incoming: [Slot]) {
        // Always accepted, never frozen. A live drag reads the `eligible`
        // snapshot instead, so churn here is harmless — whereas ignoring
        // updates during a drag would leave these holding pre-drop positions
        // afterwards, since the reorder's own layout pass is the last one
        // that fires. Sorted rather than trusting preference-collection
        // order, which is not a documented guarantee.
        slots = incoming.sorted { $0.minY < $1.minY }
    }

    // MARK: - Drag lifecycle

    /// Returns false when the drag can't go anywhere (an only child, or a row
    /// whose frame hasn't been reported yet), so the caller can leave the
    /// row alone rather than starting a drag that can only be a no-op.
    @discardableResult
    func begin(_ id: SlotID, constrainToProject: Bool) -> Bool {
        // Grabbing a row mid-glide cuts the glide short rather than fighting
        // it — the new drag owns the offsets from here.
        endSettle()
        let list = SidebarReorderGeometry.eligible(
            for: id, in: slots, constrainToProject: constrainToProject)
        guard list.count > 1,
              let sourceIndex = list.firstIndex(where: { $0.id == id })
        else { return false }

        eligible = list
        boundaries = SidebarReorderGeometry.boundaries(of: list)
        // Derive the gutter from the layout instead of hardcoding it — tab
        // rows sit 4pt apart, group headers 20pt.
        let gap = max(list[1].minY - list[0].maxY, 0)
        session = Session(
            dragged: id,
            sourceIndex: sourceIndex,
            draggedHeight: list[sourceIndex].frame.height,
            gap: gap,
            offset: 0,
            insertion: sourceIndex)
        didDrag = true
        SidebarDragHover.shared.begin()
        installGuards()
        startAutoScroll()
        return true
    }

    private func installGuards() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            DispatchQueue.main.async { self?.cancel() }
            // Swallow it — Escape during a reorder shouldn't also reach the
            // terminal underneath.
            return nil
        }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            // Deferred so the gesture's own `onEnded` — which rides this same
            // mouse-up — commits first. If it did, this finds no session and
            // does nothing; if it never arrives, this is what unsticks us.
            DispatchQueue.main.async { self?.cancel() }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    private func removeGuards() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        escapeMonitor = nil
        mouseUpMonitor = nil
        resignObserver = nil
    }

    func update(cursorY: CGFloat, offset: CGFloat) {
        guard var session, !session.isSettling else { return }
        // Remember where the pointer is on *screen*, not in the content: it
        // is the content that moves during auto-scroll, and the edge test has
        // to stay in viewport terms.
        lastViewportY = cursorY - scrollOffset
        session.offset = offset
        session.insertion = SidebarReorderGeometry.insertion(
            cursorY: cursorY,
            boundaries: boundaries,
            current: session.insertion) ?? session.insertion
        // Session is Equatable, so a move that changes neither the offset nor
        // the target publishes nothing.
        self.session = session
    }

    // MARK: - Edge auto-scroll

    /// Resolved from the view hierarchy by `SidebarScrollViewProbe`. Reaching
    /// for SwiftUI's backing scroll view is an implementation detail, so
    /// every use is optional and the feature simply doesn't exist when it
    /// can't be found.
    weak var scrollView: NSScrollView?

    private var autoScrollTimer: Timer?
    private var lastViewportY: CGFloat = 0

    private var scrollOffset: CGFloat {
        scrollView?.contentView.bounds.origin.y ?? 0
    }

    /// Distance from an edge at which scrolling kicks in, and the fastest it
    /// will go (points per second) once the pointer is hard against it.
    private static let autoScrollZone: CGFloat = 24
    private static let autoScrollMaxSpeed: CGFloat = 900

    private func startAutoScroll() {
        autoScrollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoScrollTick() }
        }
        // Common modes so it keeps ticking while the mouse is held down.
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    private func autoScrollTick() {
        guard var session, let scrollView else { return }
        let clip = scrollView.contentView
        let viewportHeight = clip.bounds.height
        let zone = Self.autoScrollZone

        // Ramp with depth into the edge zone so it creeps at the boundary and
        // races when the pointer is pinned to the edge.
        var velocity: CGFloat = 0
        if lastViewportY < zone {
            velocity = -Self.autoScrollMaxSpeed * (1 - max(lastViewportY, 0) / zone)
        } else if lastViewportY > viewportHeight - zone {
            let depth = max(viewportHeight - lastViewportY, 0)
            velocity = Self.autoScrollMaxSpeed * (1 - depth / zone)
        }
        guard velocity != 0 else { return }

        let documentHeight = scrollView.documentView?.bounds.height ?? viewportHeight
        let limit = max(documentHeight - viewportHeight, 0)
        let current = clip.bounds.origin.y
        let next = min(max(current + velocity / 60, 0), limit)
        let delta = next - current
        guard delta != 0 else { return }

        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: next))
        scrollView.reflectScrolledClipView(clip)

        // The pointer hasn't moved, so `onChanged` will not fire — this tick
        // owns keeping up. The dragged row has to travel with the cursor
        // rather than the content, and the target has to be re-derived
        // against the content position now under the pointer.
        session.offset += delta
        session.insertion = SidebarReorderGeometry.insertion(
            cursorY: lastViewportY + next,
            boundaries: boundaries,
            current: session.insertion) ?? session.insertion
        self.session = session
    }

    /// Ends the drag and glides the row from where it was released into its
    /// slot.
    ///
    /// Reordering the model teleports the row to its new slot, so this
    /// immediately offsets it back by that exact distance — visually nothing
    /// moves, the row is still under the cursor — and *then* animates that
    /// offset away. Both the reorder and the compensating offset go in one
    /// animation-free transaction so no frame can show the row anywhere but
    /// where it was dropped.
    func finish(_ apply: (Commit) -> Void) {
        guard let session else { clear(); return }
        let commit = pendingCommit()
        let residual = settleResidual(session, moved: commit != nil)

        // The drag proper is over: monitors and auto-scroll go now, so a
        // stray mouse-up or Escape during the glide can't tear it down.
        endDragProper()

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let commit { apply(commit) }
            self.session?.offset = residual
            self.session?.isSettling = true
        }

        withAnimation(SidebarDragReorder.dropSettle) {
            self.session?.offset = 0
        }

        let work = DispatchWorkItem { [weak self] in self?.endSettle() }
        settleWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SidebarDragReorder.dropSettleDuration,
            execute: work)
    }

    /// How far the released row is from the slot the reorder just put it in —
    /// i.e. how much to offset it by so it appears not to have moved.
    ///
    /// Derived from the frames frozen at drag start. Every row the dragged one
    /// passed shifts by its footprint, so the slot it lands in is a fixed
    /// distance from a known neighbour: below the source it opens up right
    /// after the row now preceding it, above the source it takes that row's
    /// old top edge.
    private func settleResidual(_ session: Session, moved: Bool) -> CGFloat {
        guard eligible.indices.contains(session.sourceIndex) else { return session.offset }
        // No reorder happened, so the slot is the one it started in and the
        // whole drag offset is what has to be animated away.
        guard moved else { return session.offset }

        guard let landedMinY = SidebarReorderGeometry.landingMinY(
            source: session.sourceIndex,
            insertion: session.insertion,
            slots: eligible,
            draggedHeight: session.draggedHeight)
        else { return session.offset }
        let visualY = eligible[session.sourceIndex].minY + session.offset
        return visualY - landedMinY
    }

    private func pendingCommit() -> Commit? {
        guard let session,
              let anchor = SidebarReorderGeometry.anchor(
                for: session.insertion,
                source: session.sourceIndex,
                count: eligible.count)
        else { return nil }
        return Commit(
            dragged: session.dragged,
            anchor: eligible[anchor.index].id,
            edge: anchor.edge)
    }

    /// Abandon the drag with no reorder — Escape, a lost mouse-up, the window
    /// resigning key, or the dragged row disappearing mid-drag.
    func cancel() {
        guard session != nil else { return }
        clear()
    }

    /// Drop the drag if the row being dragged is no longer in the list (its
    /// tab closed while the mouse was down).
    func cancelIfDraggedIsMissing(among present: Set<SlotID>) {
        // Not during the glide: committing the reorder changes the tab list,
        // which fires this check on the same turn — it must not cut short the
        // animation it just triggered.
        guard let session, !session.isSettling,
              !present.contains(session.dragged)
        else { return }
        clear()
    }

    /// Everything that must stop the moment the mouse comes up, whether or not
    /// a settle animation follows.
    private func endDragProper() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        removeGuards()
        // One turn, not a timed window: long enough to outlive the select tap
        // riding the same mouse-up, short enough that the next real click
        // lands. The old path guessed 0.35s and swallowed genuine clicks.
        // Deliberately not tied to the settle — a click during the glide
        // should still work.
        DispatchQueue.main.async { [weak self] in
            self?.didDrag = false
        }
    }

    /// Drops the settle state once the glide is done. Hover comes back here
    /// rather than at mouse-up so rows don't light up under the cursor while
    /// the list is still moving.
    private func endSettle() {
        settleWork?.cancel()
        settleWork = nil
        guard session != nil else { return }
        session = nil
        eligible = []
        boundaries = []
        SidebarDragHover.shared.end()
    }

    private func clear() {
        endDragProper()
        endSettle()
    }

    // MARK: - Per-row rendering

    /// Whether this row is the one under the cursor's control, so it can be
    /// raised above its siblings. Stays true through the glide so the
    /// released row travels over its neighbours rather than under them.
    func isDragging(_ id: SlotID) -> Bool {
        session?.dragged == id
    }

    /// How this row's offset should animate. All the policy in one place:
    /// while dragging, the rows parting animate and the dragged row tracks
    /// the cursor 1:1; while settling, only the released row animates, gliding
    /// into its slot; with no session, nothing animates at all.
    func animation(for id: SlotID, reduceMotion: Bool) -> Animation? {
        guard let session, !reduceMotion else { return nil }
        if session.isSettling {
            return session.dragged == id ? SidebarDragReorder.dropSettle : nil
        }
        return session.dragged == id ? nil : SidebarDragReorder.gapAnimation
    }

    /// How far this row should be drawn from where it was laid out: the
    /// dragged row tracks the cursor, everything it passes slides aside to
    /// open the gap it will land in.
    func displacement(for id: SlotID) -> CGFloat {
        guard let session else { return 0 }
        if id == session.dragged { return session.offset }
        // Once the glide starts the model has already reordered, so every
        // other row is exactly where it belongs — holding the gap open past
        // that point would double the shift.
        guard !session.isSettling else { return 0 }
        guard let index = eligible.firstIndex(where: { $0.id == id }) else { return 0 }
        return SidebarReorderGeometry.displacement(
            index: index,
            source: session.sourceIndex,
            insertion: session.insertion,
            draggedHeight: session.draggedHeight,
            gap: session.gap)
    }
}
