import AppKit
import SwiftUI

// Reorder chrome for sidebar rows and project blocks: the per-slot wrapper
// that reports geometry and draws displacement, and the drag gesture rows
// attach to. Kept out of SidebarView so the view file stays about the view.

/// Per-row reorder chrome: publishes the row's extent for the boundary math,
/// and draws it displaced while a drag is in flight.
///
/// This is the only part of the sidebar that observes the controller. Its
/// body re-evaluating is cheap — `content` is already built, so a drag frame
/// just re-applies an offset rather than rebuilding the row.
struct SidebarReorderSlot: ViewModifier {
    let id: SidebarReorderGeometry.SlotID
    let group: String?
    @ObservedObject var controller: SidebarReorderController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let isDragged = controller.isDragging(id)
        let displacement = controller.displacement(for: id)
        let animation = controller.animation(for: id, reduceMotion: reduceMotion)
        return content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SidebarSlotsKey.self,
                        value: [SidebarReorderGeometry.Slot(
                            id: id,
                            group: group,
                            frame: proxy.frame(in: .named(SidebarReorderSpace.name)))])
                }
            )
            .offset(y: displacement)
            // Policy lives on the controller — it is the only thing that
            // knows whether this is a live drag or the post-drop glide.
            // Duplicating it here previously passed nil during the settle,
            // which silently overrode finish()'s withAnimation and meant the
            // glide never ran.
            .animation(animation, value: displacement)
            .zIndex(isDragged ? 1 : 0)
    }
}

/// What a row needs to run a reorder drag. Bundled so rows take one
/// parameter instead of four.
struct SidebarReorderHandle {
    let id: SidebarReorderGeometry.SlotID
    let controller: SidebarReorderController
    let constrainToProject: Bool
    /// Returns whether the reorder was actually applied — see
    /// `SidebarReorderController.finish`.
    let onCommit: (SidebarReorderController.Commit) -> Bool
    /// Single-step move for the row's menu — the reorder path that doesn't
    /// need a mouse.
    let canStep: (_ up: Bool) -> Bool
    let step: (_ up: Bool) -> Void
}

extension View {
    /// Attach the reorder drag. Must be applied *inside* the row, where
    /// `isEnabled` can see whether an inline rename is in progress.
    func sidebarReorderDrag(
        _ handle: SidebarReorderHandle,
        isEnabled: Bool = true
    ) -> some View {
        modifier(SidebarReorderDrag(handle: handle, isEnabled: isEnabled))
    }
}

struct SidebarReorderDrag: ViewModifier {
    let handle: SidebarReorderHandle
    let isEnabled: Bool

    @State private var active = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            // Simultaneous, not exclusive: an exclusive gesture would let the
            // row's descendant double-tap claim the mouse sequence and the
            // drag would never start — the same reason the select/rename taps
            // are simultaneous.
            DragGesture(
                minimumDistance: 4,
                coordinateSpace: .named(SidebarReorderSpace.name)
            )
            .onChanged { value in
                if !active {
                    active = handle.controller.begin(
                        handle.id,
                        constrainToProject: handle.constrainToProject)
                    guard active else { return }
                }
                handle.controller.update(
                    cursorY: value.location.y,
                    offset: value.translation.height)
            }
            .onEnded { _ in
                guard active else { return }
                active = false
                handle.controller.finish(handle.onCommit)
            },
            // `.subviews` disables the drag on this row while leaving
            // descendants live, so drag-to-select inside the rename field
            // still works. A conditional `if` around the modifier would
            // change structural identity mid-edit and can drop @FocusState.
            including: isEnabled ? .all : .subviews)
    }
}
