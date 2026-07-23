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
    /// non-git directories — in first-appearance order so grouping never
    /// shuffles more than it must. The home directory titles as "~".
    static func groups(from tabs: [SidebarTabManager.TabItem]) -> [SidebarTabGroup] {
        var order: [String] = []
        var byRoot: [String: [SidebarTabManager.TabItem]] = [:]
        var pending: [SidebarTabManager.TabItem] = []
        for tab in tabs {
            if let root = tab.projectRoot ?? tab.directory {
                if byRoot[root] == nil { order.append(root) }
                byRoot[root, default: []].append(tab)
            } else {
                pending.append(tab)
            }
        }
        let home = NSHomeDirectory()
        var groups = order.map { root in
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
}

/// Section header for a project group: disclosure chevron + repo folder
/// name (click anywhere on that stretch to collapse/expand), and a "+"
/// button on the trailing edge that opens a new tab in the project's
/// directory. Small and dimmed, Finder-sidebar style.
struct ProjectHeader: View {
    let name: String
    let isCollapsed: Bool
    let foreground: Color
    let fontSize: Double
    let onToggle: () -> Void
    let onNewTab: () -> Void

    @State private var isHovering = false
    @State private var isHoveringPlus = false

    private var labelSize: Double { max(8, fontSize - 2) }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: max(6, fontSize - 4), weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text(name)
                        .font(.system(size: labelSize, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(foreground.opacity(isHovering ? 0.75 : 0.45))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand" : "Collapse")

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: max(6, fontSize - 3), weight: .semibold))
                    .foregroundStyle(foreground.opacity(
                        isHoveringPlus ? 0.95 : (isHovering ? 0.65 : 0.35)))
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(foreground.opacity(isHoveringPlus ? 0.14 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab in \(name)")
            .onHover { isHoveringPlus = $0 }
            .backport.pointerStyle(.link)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .onHover { isHovering = $0 }
    }
}
