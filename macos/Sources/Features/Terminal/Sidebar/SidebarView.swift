import SwiftUI

/// The vertical tab sidebar. Deliberately minimal styling for now — this is
/// the skeleton that the real Phanttom design will be applied to.
struct SidebarView: View {
    @ObservedObject var tabManager: SidebarTabManager

    let onNewTab: () -> Void

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
        .background(Color(nsColor: .windowBackgroundColor))
    }
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
