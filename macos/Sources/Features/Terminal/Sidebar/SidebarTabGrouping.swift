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
            if let root = tab.git?.projectRoot ?? tab.directory {
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
/// (click to collapse/expand), and a "+" on the trailing edge when expanded
/// that opens a new tab in the project's directory. Matches the Figma
/// chrome (16px folder, 12pt Inter regular @ 65%, 12px plus). On hover the folder swaps
/// to a disclosure chevron so expand/collapse is obvious. The leading
/// glyph sits in the same column as the tab status dots below.
///
/// The home group (`~`) also shows a folder-plus menu immediately left of
/// "+" listing top-level folders in `~/Developer`.
struct ProjectHeader: View {
    let name: String
    let isCollapsed: Bool
    /// Home group only — `~/Developer` folder picker beside "+".
    var showDeveloperFolders: Bool = false
    let onToggle: () -> Void
    let onNewTab: () -> Void
    var onOpenProject: (String) -> Void = { _ in }

    @State private var isHovering = false
    @State private var isHoveringToggle = false
    @State private var isHoveringPlus = false
    @State private var isHoveringDeveloper = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: SidebarLeadingColumn.contentSpacing) {
                    // Idle: folder / open-folder. Hover: disclosure chevron
                    // pointing the direction the next click will go.
                    Group {
                        if isHoveringToggle {
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
                .foregroundStyle(Color.white.opacity(isHovering ? 0.8 : 0.65))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand" : "Collapse")
            .onHover { isHoveringToggle = $0 }
            .backport.pointerStyle(.link)

            if !isCollapsed {
                HStack(spacing: 4) {
                    if showDeveloperFolders {
                        developerFoldersMenu
                    }
                    Button(action: onNewTab) {
                        Image("PhanttomPlus")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                            .foregroundStyle(Color.white.opacity(
                                isHoveringPlus ? 0.95 : (isHovering ? 0.65 : 0.5)))
                            .frame(
                                width: SidebarTrailingColumn.slot,
                                height: SidebarTrailingColumn.slot)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New Tab in \(name)")
                    .onHover { isHoveringPlus = $0 }
                    .backport.pointerStyle(.link)
                }
            }
        }
        // Same leading inset as tab rows so the folder shares the status
        // column's left edge; trailing matches the tab close/model gutter.
        .padding(.leading, SidebarLeadingColumn.padding)
        .padding(.trailing, SidebarTrailingColumn.padding)
        .frame(height: 16)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var developerFoldersMenu: some View {
        if #available(macOS 14, *) {
            developerFoldersMenuContent.menuIndicator(.hidden)
        } else {
            developerFoldersMenuContent
        }
    }

    private var developerFoldersMenuContent: some View {
        Menu {
            let items = Self.developerFolders()
            if items.isEmpty {
                Button("No folders in ~/Developer") {}
                    .disabled(true)
            } else {
                ForEach(items, id: \.self) { path in
                    Button {
                        onOpenProject(path)
                    } label: {
                        Label {
                            Text((path as NSString).lastPathComponent)
                        } icon: {
                            Image("PhanttomFolder")
                        }
                    }
                }
            }
        } label: {
            // Menu/NSPopUpButton ignores Image.frame — clear slot + overlay
            // so we own the glyph size. Match group-header folders (16pt).
            Color.clear
                .frame(
                    width: SidebarTrailingColumn.slot,
                    height: SidebarTrailingColumn.slot)
                .overlay {
                    Image("PhanttomFolderPlus")
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: SidebarLeadingColumn.width,
                            height: SidebarLeadingColumn.width)
                        .foregroundStyle(Color.white.opacity(
                            isHoveringDeveloper ? 0.95 : 0.65))
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .controlSize(.mini)
        .fixedSize()
        .help("Open Project from ~/Developer")
        .onHover { isHoveringDeveloper = $0 }
        .backport.pointerStyle(.link)
    }

    /// Top-level directories under `~/Developer`, A–Z. Recomputed when the
    /// menu content is built (on open), so newly created folders show up
    /// without a separate refresh path.
    private static func developerFolders() -> [String] {
        let root = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Developer")
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
    }
}
