import SwiftUI

/// The vertical tab sidebar, implementing the first Phanttom design pass:
/// compact rows for plain terminal tabs, two-line cards for agent tabs
/// (Claude/Codex) with directory + git branch, and trailing status
/// indicators (animated pixel sparkle while working, blue "done" and yellow
/// "attention" squares).
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
            // Prefer the selected surface's live background — the app-level
            // config getter can lag or miss overrides (e.g. phanttom.conf).
            let base = OSColor(tabManager.terminalBackground ?? ghostty.config.backgroundColor)
            let nudged = base.isLightColor ? base.darken(by: 0.06) : base.darken(by: 0.25)
            return Color(nsColor: nudged)
        }
    }

    /// The sidebar background: base color at the configured opacity. When
    /// glass is on, the window itself is transparent behind the sidebar
    /// (see PhanttomWindowGlass) — so translucent pixels here reveal a
    /// genuinely blurred (or clear, at 0) view of what's behind the window.
    @ViewBuilder private var background: some View {
        baseColor
            .opacity(settings.sidebarOpacity)
            .ignoresSafeArea()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(tabManager.tabs) { tab in
                        SidebarTabRow(
                            tab: tab,
                            onSelect: { tabManager.select(tab) },
                            onClose: { tabManager.close(tab) },
                            onRename: { tabManager.rename(tab, to: $0) }
                        )
                    }
                }
                .padding(8)
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            Button(action: onNewTab) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                    Text("New tab")
                        .font(.system(size: 11))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 19)
            .padding(.vertical, 17)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
    }
}

struct SidebarTabRow: View {
    let tab: SidebarTabManager.TabItem
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String?) -> Void

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var editFocused: Bool

    private var rowBackground: Color {
        if tab.isSelected { return Color.white.opacity(0.08) }
        if isHovering { return Color.white.opacity(0.04) }
        return Color.clear
    }

    var body: some View {
        Group {
            switch tab.kind {
            case .terminal: terminalRow
            case .claude: agentRow(icon: "PhanttomClaude")
            case .codex: agentRow(icon: "PhanttomCodex")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(rowBackground))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: startRename)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename Tab…", action: startRename)
            if tab.customTitle != nil {
                Button("Reset Name") { onRename(nil) }
            }
            Divider()
            Button("Close Tab", action: onClose)
        }
        .help(tab.directory ?? tab.title)
    }

    private func startRename() {
        draft = tab.customTitle ?? tab.displayTitle
        isEditing = true
        editFocused = true
    }

    private func commitRename() {
        guard isEditing else { return }
        isEditing = false
        onRename(draft)
    }

    /// Inline name editor swapped in for the title while renaming.
    private var titleEditor: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.white)
            .focused($editFocused)
            .onSubmit(commitRename)
            .onChange(of: editFocused) { focused in
                if !focused { commitRename() }
            }
            .onExitCommand {
                isEditing = false
            }
    }

    /// Compact 29pt row: terminal chip + abbreviated path.
    private var terminalRow: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.12))
                .frame(width: 13, height: 13)
                .overlay(
                    Image(systemName: "apple.terminal.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                )
            if isEditing {
                titleEditor
            } else {
                Text(tab.customTitle ?? tab.abbreviatedDirectory ?? (tab.title.isEmpty ? "Terminal" : tab.title))
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            trailing
        }
        .frame(height: 13)
    }

    /// Two-line 45pt card: agent icon + title, then directory + branch.
    private func agentRow(icon: String) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(icon)
                        .resizable()
                        .frame(width: 13, height: 13)
                    if isEditing {
                        titleEditor
                    } else {
                        Text(tab.displayTitle.isEmpty ? "Terminal" : tab.displayTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                HStack(spacing: 8) {
                    if let dir = tab.directoryName {
                        Text(dir)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let branch = tab.gitBranch {
                        Text(branch)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: 0)
            trailing
        }
    }

    /// Trailing edge: hover close button wins, then status indicator.
    @ViewBuilder private var trailing: some View {
        if isHovering {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .buttonStyle(.plain)
            .help("Close Tab")
        } else {
            switch tab.status {
            case .idle:
                EmptyView()
            case .working:
                PixelSparkleView()
            case .done:
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0x2C / 255, green: 0x86 / 255, blue: 0xF4 / 255))
                    .frame(width: 8, height: 8)
            case .attention:
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0xF4 / 255, green: 0xBC / 255, blue: 0x2C / 255))
                    .frame(width: 8, height: 8)
            }
        }
    }
}

/// The "working" indicator: pixel rain. Four columns of drops fall through a
/// 5-row grid, each column with its own speed and phase; the drop head is
/// bright with an exponential trail above it and a sharp falloff below.
/// Ported from the design's canvas reference ("Bare rain, 4 col").
struct PixelSparkleView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let color = Color(red: 0x7B / 255, green: 0x5E / 255, blue: 0xFF / 255)
    private static let rows = 5
    private static let cols = 4
    private static let pitch: CGFloat = 3.8
    private static let cell: CGFloat = 2.85

    /// Deterministic pseudo-random in [0, 1), same hash as the reference.
    private static func frac(_ n: Double) -> Double {
        let x = sin(n) * 43758.5453
        return x - floor(x)
    }

    var body: some View {
        Group {
            if reduceMotion {
                Canvas { canvas, _ in Self.draw(t: 0.6, into: &canvas) }
            } else {
                TimelineView(.animation) { context in
                    Canvas { canvas, _ in
                        Self.draw(t: context.date.timeIntervalSinceReferenceDate, into: &canvas)
                    }
                }
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel("Working")
    }

    private static func draw(t: Double, into canvas: inout GraphicsContext) {
        for i in 0..<cols {
            let speed = 2.5 + frac(Double(i) * 5.7) * 2.5
            let phase = frac(Double(i) * 9.1) * 7
            let head = (t * speed + phase)
                .truncatingRemainder(dividingBy: Double(rows + 3)) - 1.5
            for j in 0..<rows {
                let dy = head - Double(j)
                let alpha = dy >= 0 ? exp(-dy * 0.8) : exp(dy * 8)
                guard alpha >= 0.02 else { continue }
                let rect = CGRect(
                    x: (CGFloat(i) + 0.5) * pitch,
                    y: CGFloat(j) * pitch,
                    width: cell,
                    height: cell
                )
                canvas.fill(
                    Path(roundedRect: rect, cornerRadius: cell * 0.28),
                    with: .color(color.opacity(alpha))
                )
            }
        }
    }
}

