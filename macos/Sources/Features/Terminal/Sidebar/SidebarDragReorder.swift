import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Sidebar tab drag payload: the tab window's `windowNumber` as UTF-8 text.
    static let phanttomSidebarTab = UTType(exportedAs: "com.mitchellh.ghostty.phanttomSidebarTab")

    /// Sidebar project-group drag payload: the project root path as UTF-8 text.
    static let phanttomSidebarGroup = UTType(exportedAs: "com.mitchellh.ghostty.phanttomSidebarGroup")
}

/// Hover suppression for sidebar reorder drags. Row `onHover` still fires
/// under the drag cursor (and especially on mouse-up), which paints a second
/// highlight while the dragged row settles — suppress for the drag and a
/// short beat after release.
@MainActor
final class SidebarDragHover: ObservableObject {
    static let shared = SidebarDragHover()

    @Published private(set) var suppressesHover = false

    private var mouseUpMonitor: Any?
    private var settleWork: DispatchWorkItem?

    /// Call when a sidebar reorder drag begins.
    func begin() {
        settleWork?.cancel()
        settleWork = nil
        suppressesHover = true
        installMouseUpMonitor()
    }

    /// Keep hover off through the settle animation, then re-enable.
    func endAfterSettle(_ duration: TimeInterval = 0.18) {
        removeMouseUpMonitor()
        settleWork?.cancel()
        suppressesHover = true
        let work = DispatchWorkItem { [weak self] in
            self?.suppressesHover = false
            self?.settleWork = nil
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func installMouseUpMonitor() {
        removeMouseUpMonitor()
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            // Defer so `performDrop` on the same mouse-up runs first.
            DispatchQueue.main.async {
                self?.endAfterSettle()
            }
            return event
        }
    }

    private func removeMouseUpMonitor() {
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
    }
}

enum SidebarDragReorder {
    enum Edge: Equatable {
        case before
        case after
    }

    /// Active insertion highlight while a sidebar reorder drag is over a row.
    enum Highlight: Equatable {
        case tab(windowNumber: Int, edge: Edge)
        case group(id: String, edge: Edge)
    }

    /// Snappy settle after release — reorder should feel immediate, not like
    /// the slower insert/remove spring used elsewhere in the sidebar.
    static let settleAnimation: Animation = .easeOut(duration: 0.14)

    /// Process-local drag payload. `NSItemProvider.loadDataRepresentation`
    /// is always async (even for same-process data) and adds a visible beat
    /// between mouse-up and the list updating; this lets `performDrop` run
    /// the reorder on the same event turn as the release.
    private static var activeTabWindowNumber: Int?
    private static var activeGroupID: String?

    @MainActor
    static func tabProvider(windowNumber: Int) -> NSItemProvider {
        SidebarDragHover.shared.begin()
        activeTabWindowNumber = windowNumber
        activeGroupID = nil
        return provider(utf8: String(windowNumber), type: .phanttomSidebarTab)
    }

    @MainActor
    static func groupProvider(projectRoot: String) -> NSItemProvider {
        SidebarDragHover.shared.begin()
        activeGroupID = projectRoot
        activeTabWindowNumber = nil
        return provider(utf8: projectRoot, type: .phanttomSidebarGroup)
    }

    /// Load a UTF-8 string payload. Prefers the process-local session
    /// (synchronous on the main queue); falls back to the provider.
    static func loadString(
        from providers: [NSItemProvider],
        type: UTType,
        completion: @escaping (String) -> Void
    ) -> Bool {
        if let sync = syncPayload(for: type) {
            deliver(sync, completion: completion)
            return true
        }

        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(type.identifier)
        }) else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let string = String(data: data, encoding: .utf8), !string.isEmpty
            else { return }
            deliver(string, completion: completion)
        }
        return true
    }

    private static func syncPayload(for type: UTType) -> String? {
        if type == .phanttomSidebarTab {
            guard let n = activeTabWindowNumber else { return nil }
            activeTabWindowNumber = nil
            return String(n)
        }
        if type == .phanttomSidebarGroup {
            guard let id = activeGroupID else { return nil }
            activeGroupID = nil
            return id
        }
        return nil
    }

    private static func deliver(_ string: String, completion: @escaping (String) -> Void) {
        if Thread.isMainThread {
            completion(string)
        } else {
            DispatchQueue.main.async { completion(string) }
        }
    }

    private static func provider(utf8: String, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(utf8.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

/// Thin insertion line shown above/below a row while it is the drop target.
struct SidebarInsertionLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.55))
            .frame(height: 2)
            .clipShape(Capsule())
    }
}

/// Reference gate so `DropDelegate` (a struct) can remember that
/// `performDrop` already ran. SwiftUI sends `dropUpdated` after
/// `performDrop`; without this the insertion line comes back.
final class SidebarDropGate {
    var isLive = false
}

/// Drop target that proposes `.move` (no green "+" copy badge) and reports
/// before/after based on the cursor's Y within the row.
///
/// Validation is type-only — sync payload identity is not available reliably
/// during `validateDrop` on macOS, so same-project and self checks happen in
/// `performDrop` after the async load.
struct SidebarReorderDropDelegate: DropDelegate {
    let type: UTType
    let rowHeight: CGFloat
    let gate: SidebarDropGate
    let onHighlight: (SidebarDragReorder.Edge?) -> Void
    let onPerform: (NSItemProvider, SidebarDragReorder.Edge) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [type])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else {
            onHighlight(nil)
            return
        }
        gate.isLive = true
        onHighlight(edge(at: info.location))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // performDrop already ran — SwiftUI still delivers dropUpdated; do
        // not resurrect the insertion line (same guard as SplitDropDelegate).
        guard gate.isLive, validateDrop(info: info) else {
            onHighlight(nil)
            return DropProposal(operation: .forbidden)
        }
        onHighlight(edge(at: info.location))
        // `.move` — not `.copy` — so macOS does not show the green "+" badge.
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onHighlight(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let edge = edge(at: info.location)
        gate.isLive = false
        onHighlight(nil)
        guard validateDrop(info: info),
              let provider = info.itemProviders(for: [type]).first
        else { return false }
        return onPerform(provider, edge)
    }

    private func edge(at point: CGPoint) -> SidebarDragReorder.Edge {
        let height = max(rowHeight, 1)
        return point.y < height * 0.5 ? .before : .after
    }
}
