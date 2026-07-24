import AppKit
import SwiftUI

/// Hover suppression for sidebar reorder drags. Row `onHover` still fires
/// under the drag cursor, which would paint a second highlight on top of the
/// row being dragged — suppress for the duration of the drag.
///
/// Process-global because every window in a tab group hosts its own
/// `SidebarView`; suppressing them all is harmless and avoids threading a
/// per-window flag through every row.
@MainActor
final class SidebarDragHover: ObservableObject {
    static let shared = SidebarDragHover()

    @Published private(set) var suppressesHover = false

    private var depth = 0

    func begin() {
        depth += 1
        suppressesHover = true
    }

    /// Ends immediately rather than after a settle delay. The old AppKit
    /// drop path had to guess how long the list would take to rearrange
    /// itself after release; the gap-based drag has already finished
    /// rearranging by the time the mouse comes up, so there is nothing to
    /// wait for.
    func end() {
        depth = max(depth - 1, 0)
        if depth == 0 { suppressesHover = false }
    }
}

enum SidebarDragReorder {
    enum Edge: Equatable {
        case before
        case after
    }

    /// Rows parting to open the drop gap. Fast and slightly springy so the
    /// list feels like it's getting out of the way rather than animating.
    static let gapAnimation: Animation = .spring(response: 0.22, dampingFraction: 0.86)

    /// The released row travelling from the cursor into its slot. Springy
    /// enough to read as motion rather than a cut, short enough that it never
    /// feels like waiting.
    static let dropSettle: Animation = .spring(response: 0.26, dampingFraction: 0.78)

    /// How long to hold the settle state before tearing it down. Generous
    /// against `dropSettle`'s spring tail on purpose: finishing late is
    /// invisible (the offset is already 0), finishing early would cut the
    /// animation short with a snap.
    static let dropSettleDuration: TimeInterval = 0.45

    /// Snappy settle for list changes that aren't a drag (a tab arriving or
    /// leaving while the sidebar is visible).
    static let settleAnimation: Animation = .easeOut(duration: 0.14)
}
