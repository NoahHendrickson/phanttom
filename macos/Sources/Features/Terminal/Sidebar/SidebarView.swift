import SwiftUI

/// The vertical tab sidebar. Deliberately minimal styling for now — this is
/// the skeleton that the real Phanttom design will be applied to.
struct SidebarView: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var tabManager: SidebarTabManager
    @ObservedObject private var settings = PhanttomSettings.shared

    let onNewTab: () -> Void

    /// The sidebar's base color per style: system, custom, or derived from
    /// the terminal theme (nudged so the split still reads).
    private var baseColor: Color {
        switch settings.sidebarStyle {
        case .system:
            return Color(nsColor: .windowBackgroundColor)
        case .custom:
            return settings.sidebarColor
        case .matchTerminal:
            let base = OSColor(ghostty.config.backgroundColor)
            let nudged = base.isLightColor ? base.darken(by: 0.06) : base.darken(by: 0.25)
            return Color(nsColor: nudged)
        }
    }

    /// Layered background: optional behind-window glass material with the
    /// base color over it at the configured opacity. Glass + low opacity =
    /// frosted sidebar; no glass + full opacity = flat color.
    @ViewBuilder private var background: some View {
        ZStack {
            if settings.sidebarGlass {
                SidebarGlassBackground()
            }
            baseColor.opacity(settings.sidebarOpacity)
        }
        .ignoresSafeArea()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(tabManager.tabs) { tab in
                        SidebarTabRow(
                            tab: tab,
                            onSelect: { tabManager.select(tab) },
                            onClose: { tabManager.close(tab) }
                        )
                    }
                }
                .padding(8)
            }

            Divider()

            Button(action: onNewTab) {
                Label("New Tab", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
    }
}

/// Behind-window blur for the sidebar (Finder-sidebar style). Independent of
/// the terminal's window-level `background-blur` — this blurs whatever is
/// behind the window in the sidebar's region only.
private struct SidebarGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct SidebarTabRow: View {
    let tab: SidebarTabManager.TabItem
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? "Terminal" : tab.title)
                    .font(.system(size: 12, weight: tab.isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let dir = tab.directoryName {
                    Text(dir)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(tab.isSelected
                      ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.35)
                      : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(tab.directory ?? tab.title)
    }
}
