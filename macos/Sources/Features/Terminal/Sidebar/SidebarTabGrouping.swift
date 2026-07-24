import AppKit
import SwiftUI

/// The sidebar's project-grouping policy, kept out of the view shell:
/// `SidebarView` only chooses flat vs grouped and renders what this
/// produces.
enum SidebarTabGroup: Identifiable {
    /// The tabs of one project. `id` is the project root path — which is
    /// also the working directory the group header's "+" opens new tabs
    /// in, and the key collapse state is stored under.
    case project(id: String, title: String, tabs: [SidebarTabManager.TabItem])

    /// Tabs whose pwd isn't known yet (a brand-new surface before shell
    /// integration reports). Rendered header-less at the end of the list;
    /// never collapsible. At most one of these exists.
    case pending(tabs: [SidebarTabManager.TabItem])

    var id: String {
        switch self {
        case .project(let id, _, _): return id
        // Project ids are absolute paths, so a bare word can't collide.
        case .pending: return "pending"
        }
    }

    /// Partition tabs by project — the repo toplevel of the tab's pwd
    /// (worktrees resolve to their parent repo), else the pwd itself for
    /// non-git directories. Within each group, tab order follows the input
    /// (native `tabbedWindows` order). Group order prefers
    /// `preferringOrder` (persisted drag order), then first-appearance for
    /// roots not yet recorded. The home directory titles as "~".
    /// Callers pass order explicitly so this stays a pure grouping API
    /// (no singleton / MainActor coupling).
    static func groups(
        from tabs: [SidebarTabManager.TabItem],
        preferringOrder: [String]
    ) -> [SidebarTabGroup] {
        var appearance: [String] = []
        var byRoot: [String: [SidebarTabManager.TabItem]] = [:]
        var pending: [SidebarTabManager.TabItem] = []
        for tab in tabs {
            if let root = projectKey(for: tab) {
                if byRoot[root] == nil { appearance.append(root) }
                byRoot[root, default: []].append(tab)
            } else {
                pending.append(tab)
            }
        }
        let orderedRoots = ProjectGroupOrderStore.merge(
            order: preferringOrder,
            appearing: appearance)
        // Canonicalize home the same way keys are so trailing-slash / `.`
        // / `..` variants compare equal (falls back to the raw path, which
        // never happens for a real home directory).
        let home = normalizedRoot(NSHomeDirectory()) ?? NSHomeDirectory()
        var groups = orderedRoots.map { root in
            SidebarTabGroup.project(
                id: root,
                title: root == home ? "~" : (root as NSString).lastPathComponent,
                tabs: byRoot[root] ?? []
            )
        }
        if !pending.isEmpty {
            groups.append(.pending(tabs: pending))
        }
        return groups
    }

    /// Project-group key for same-group tab drag constraints: repo root
    /// when known, else pwd. nil only for the header-less pending bucket.
    static func projectKey(for tab: SidebarTabManager.TabItem) -> String? {
        normalizedRoot(tab.git?.projectRoot ?? tab.directory)
    }

    /// Canonicalize a pwd for use as a grouping key/id. Trims whitespace and
    /// treats an empty (or whitespace-only) path as nil so such tabs fall into
    /// the header-less pending bucket instead of forming a bogus empty group.
    /// Standardizes the path (removes `.`/`..` and any trailing slash) so
    /// trailing-slash variants of one project don't split into two groups.
    /// Symlinks are intentionally left unresolved to match how pwd is reported
    /// elsewhere; already-clean absolute paths are returned unchanged.
    private static func normalizedRoot(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}

/// Shared leading column for project-header folders and tab status markers
/// so they stack on one vertical axis. Also locks project-name and tab-title
/// text to the same left edge:
/// `padding + width + contentSpacing` (12 + 16 + 8 = 36).
enum SidebarLeadingColumn {
    static let padding: CGFloat = 12
    static let width: CGFloat = 16
    static let contentSpacing: CGFloat = 8
}

/// Shared trailing gutter for the project-header "+" and tab-row close "X"
/// so their centers share one vertical axis:
/// `padding + slot/2` (12 + 8 = 20) from the row's right edge.
enum SidebarTrailingColumn {
    static let padding: CGFloat = 12
    static let slot: CGFloat = 16
}

/// Section header for a project group: folder glyph + repo folder name
/// (click to collapse/expand), and a trailing "+" that opens a new tab in
/// the project's directory (visible whether the group is collapsed or not).
/// Matches the Figma chrome (16px folder, 12pt Inter regular @ 65%, 12px
/// plus). On hover the folder swaps to a disclosure chevron so
/// expand/collapse is obvious. The leading glyph sits in the same column
/// as the tab status dots below.
struct ProjectHeader: View {
    let name: String
    let isCollapsed: Bool
    /// Off during reorder drag / settle (same as tab rows).
    var hoverEnabled: Bool = true
    let onToggle: () -> Void
    let onNewTab: () -> Void

    @State private var isHovering = false
    @State private var isHoveringToggle = false
    @State private var isHoveringPlus = false

    private var showHover: Bool { hoverEnabled && isHovering }
    private var showToggleHover: Bool { hoverEnabled && isHoveringToggle }
    private var showPlusHover: Bool { hoverEnabled && isHoveringPlus }

    var body: some View {
        HStack(spacing: 0) {
            // Not a Button: SwiftUI Buttons consume mouseDown and block the
            // parent's `.onDrag`, so group reorder could never start. Tap is
            // simultaneous so a drag from the name/folder still wins.
            HStack(spacing: SidebarLeadingColumn.contentSpacing) {
                // Idle: folder / open-folder. Hover: disclosure chevron
                // pointing the direction the next click will go.
                Group {
                    if showToggleHover {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    } else {
                        Image(isCollapsed ? "PhanttomFolder" : "PhanttomFolderOpen")
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(
                    width: SidebarLeadingColumn.width,
                    height: SidebarLeadingColumn.width)
                Text(name)
                    .font(SidebarFont.font(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(showHover ? 0.8 : 0.65))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(onToggle))
            .help(isCollapsed ? "Expand" : "Collapse")
            .onHover { hovering in
                guard hoverEnabled else {
                    isHoveringToggle = false
                    return
                }
                isHoveringToggle = hovering
            }
            .backport.pointerStyle(.link)

            Button(action: onNewTab) {
                Image("PhanttomPlus")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(Color.white.opacity(showPlusHover ? 0.95 : 0.55))
                    .frame(
                        width: SidebarTrailingColumn.slot,
                        height: SidebarTrailingColumn.slot)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(showPlusHover ? 0.14 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab in \(name)")
            .onHover { hovering in
                guard hoverEnabled else {
                    isHoveringPlus = false
                    return
                }
                isHoveringPlus = hovering
            }
            .backport.pointerStyle(.link)
        }
        // Same leading inset as tab rows so the folder shares the status
        // column's left edge; trailing matches the tab close/model gutter.
        .padding(.leading, SidebarLeadingColumn.padding)
        .padding(.trailing, SidebarTrailingColumn.padding)
        .frame(height: 16)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard hoverEnabled else {
                isHovering = false
                return
            }
            isHovering = hovering
        }
        .onChange(of: hoverEnabled) { enabled in
            if !enabled {
                isHovering = false
                isHoveringToggle = false
                isHoveringPlus = false
            }
        }
    }
}

/// "Open from ~/Developer" control. Uses AppKit so the glyph stays at 65%
/// white (SwiftUI `Menu` always paints its label opaque) and the popup can
/// use Inter at sidebar-readable size. Directory listing is capped and
/// loaded off the main thread (cache shared across windows). Lives on the
/// pinned Sessions header (left of "+"), not on project headers.
struct DeveloperFoldersButton: NSViewRepresentable {
    var onOpen: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpen: onOpen)
    }

    func makeNSView(context: Context) -> HoverTintButton {
        let button = HoverTintButton(frame: .zero)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.title = ""
        button.setButtonType(.momentaryChange)
        button.imageScaling = .scaleProportionallyDown
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.toolTip = "Open Project from ~/Developer"
        if let image = NSImage(named: "PhanttomFolderPlus") {
            image.isTemplate = true
            button.image = image
        }
        button.idleAlpha = 0.65
        button.hoverAlpha = 0.95
        button.contentTintColor = NSColor.white.withAlphaComponent(button.idleAlpha)
        // Warm the cache so the first click rarely waits on disk.
        DeveloperFoldersCache.shared.prefetch()
        return button
    }

    func updateNSView(_ button: HoverTintButton, context: Context) {
        context.coordinator.onOpen = onOpen
    }

    final class Coordinator: NSObject {
        var onOpen: (String) -> Void

        init(onOpen: @escaping (String) -> Void) {
            self.onOpen = onOpen
        }

        @objc func showMenu(_ sender: NSButton) {
            // NSButton actions aren't MainActor-isolated; hop so we can
            // touch the cache and pop the menu on the UI thread.
            Task { @MainActor in
                DeveloperFoldersCache.shared.paths { items in
                    self.popMenu(items, from: sender)
                }
            }
        }

        private func popMenu(_ items: [String], from sender: NSButton) {
            let menu = NSMenu()
            // Match sidebar chrome; system menu 13pt reads tiny next to
            // Inter 12pt headers, so bump to 14.
            menu.font = NSFont(name: "InterVariable", size: 14)
                ?? NSFont(name: "Inter Variable", size: 14)
                ?? .systemFont(ofSize: 14)

            if items.isEmpty {
                let empty = NSMenuItem(
                    title: "No folders in ~/Developer",
                    action: nil,
                    keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            } else {
                for path in items {
                    let name = (path as NSString).lastPathComponent
                    let item = NSMenuItem(
                        title: name,
                        action: #selector(open(_:)),
                        keyEquivalent: "")
                    item.target = self
                    item.representedObject = path
                    if let icon = NSImage(named: "PhanttomFolder") {
                        icon.isTemplate = true
                        item.image = icon
                    }
                    menu.addItem(item)
                }
            }
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 2),
                in: sender)
        }

        @objc func open(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            onOpen(path)
        }
    }
}

/// Off-main listing of top-level `~/Developer` folders. Caps entries so a
/// huge or network-mounted tree can't blow up the menu or hang the UI.
@MainActor
private final class DeveloperFoldersCache {
    static let shared = DeveloperFoldersCache()
    static let maxCount = 50
    /// Re-read from disk after this age so new folders show up without a
    /// dedicated refresh control.
    private static let staleAfter: TimeInterval = 30

    private var cached: [String]?
    private var cachedAt: Date?
    private var inFlight: [( [String]) -> Void] = []
    private var loading = false

    func prefetch() {
        paths { _ in }
    }

    /// Delivers paths on the main actor. Uses cache when fresh; otherwise
    /// loads on a background queue (coalescing concurrent callers).
    func paths(completion: @escaping ([String]) -> Void) {
        if let cached, let cachedAt,
           Date().timeIntervalSince(cachedAt) < Self.staleAfter {
            completion(cached)
            return
        }
        inFlight.append(completion)
        guard !loading else { return }
        loading = true
        let root = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Developer")
        let limit = Self.maxCount
        DispatchQueue.global(qos: .userInitiated).async {
            let paths = Self.load(root: root, limit: limit)
            DispatchQueue.main.async {
                self.cached = paths
                self.cachedAt = Date()
                self.loading = false
                let waiters = self.inFlight
                self.inFlight = []
                for waiter in waiters { waiter(paths) }
            }
        }
    }

    /// Top-level directories under `root`, A–Z, at most `limit`.
    nonisolated private static func load(root: String, limit: Int) -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.compactMap { url -> String? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            return isDir ? url.path : nil
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        .prefix(limit)
        .map { $0 }
    }
}

/// Borderless template button whose `contentTintColor` alpha tracks hover.
final class HoverTintButton: NSButton {
    var idleAlpha: CGFloat = 0.65
    var hoverAlpha: CGFloat = 0.95
    private var tracking: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: SidebarTrailingColumn.slot,
            height: SidebarTrailingColumn.slot)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = NSColor.white.withAlphaComponent(hoverAlpha)
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = NSColor.white.withAlphaComponent(idleAlpha)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
