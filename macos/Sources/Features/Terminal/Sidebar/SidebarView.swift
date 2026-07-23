import SwiftUI

/// The vertical tab sidebar: compact rows for plain terminal tabs, two-line
/// cards for agent tabs (Claude/Codex). Agent cards lead with the status
/// indicator (animated pixel rain while working, glowing "done"/"attention"
/// dots), put the close button inline on the title row, and anchor the agent
/// icon + model name at the bottom-right beside the git branch line (the
/// project group header already names the directory). Terminal rows keep
/// their trailing status/close slot.
struct SidebarView: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var tabManager: SidebarTabManager
    /// The app-wide Sparkle update state, so "update available" is one click
    /// away in the sidebar footer (Cursor-style) rather than only in the
    /// titlebar accessory.
    @ObservedObject var updateModel: UpdateViewModel
    @ObservedObject private var settings = PhanttomSettings.shared
    @ObservedObject private var collapseStore = ProjectCollapseStore.shared

    /// Create a new tab in the given working directory. The second argument
    /// is the window to insert the new tab before in the native tab order —
    /// a group's "+" passes its first tab so the new one lands at the top of
    /// that group; nil appends at the default position.
    let onNewTab: (String, NSWindow?) -> Void

    /// The sidebar's base color per style: system, custom, or derived from
    /// the terminal theme (nudged so the split still reads). Prefer the
    /// selected surface's live background for the terminal input — the
    /// app-level config getter can lag or miss overrides (e.g. phanttom.conf).
    private var resolvedBase: OSColor {
        let terminal = OSColor(tabManager.terminalBackground ?? ghostty.config.backgroundColor)
        return settings.resolvedSidebarColor(terminalBackground: terminal)
    }

    private var baseColor: Color {
        Color(nsColor: resolvedBase)
    }

    /// Foreground derived from the base color's lightness so light sidebar
    /// styles (System in light mode, light terminal themes) stay legible.
    private var foreground: Color {
        resolvedBase.isLightColor ? .black : .white
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
        // Partition once per body evaluation (the policy lives in
        // SidebarTabGroup; the view only decides flat vs grouped and
        // renders). Grouping is presentation-only; headers need at least
        // one project group — an all-unknown-pwd list has nothing to label.
        let groups = SidebarTabGroup.groups(from: tabManager.tabs)
        let grouped = settings.sidebarGroupByProject && groups.contains {
            if case .project = $0 { return true } else { return false }
        }
        VStack(spacing: 0) {
            ScrollView {
                // Plain VStack, not LazyVStack: removal transitions are
                // unreliable inside lazy containers on macOS 13, and a tab
                // list is small enough that laziness buys nothing.
                VStack(spacing: 10) {
                    if grouped {
                        ForEach(groups) { group in
                            switch group {
                            case .project(let id, let title, let groupTabs):
                                ProjectHeader(
                                    name: title,
                                    isCollapsed: collapseStore.isCollapsed(id),
                                    foreground: foreground,
                                    fontSize: settings.sidebarFontSize,
                                    onToggle: {
                                        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                                            collapseStore.toggle(id)
                                        }
                                    },
                                    onNewTab: {
                                        collapseStore.expand(id)
                                        onNewTab(id, groupTabs.first?.window)
                                    }
                                )
                                .transition(.phanttomTabRow)
                                if !collapseStore.isCollapsed(id) {
                                    ForEach(groupTabs) { tab in
                                        tabRow(tab)
                                    }
                                }
                            case .pending(let pendingTabs):
                                ForEach(pendingTabs) { tab in
                                    tabRow(tab)
                                }
                            }
                        }
                    } else {
                        ForEach(tabManager.tabs) { tab in
                            tabRow(tab)
                        }
                    }

                    // Full-width row-style button trailing the last tab; it
                    // rides the same layout animation, so it slides as tabs
                    // come and go.
                    NewTabRow(
                        foreground: foreground,
                        fontSize: settings.sidebarFontSize,
                        // The bottom "New tab" is project-neutral: it always
                        // opens in the home directory (and thus the "~"
                        // group), not whatever project happens to be focused.
                        // Expand that group first — a row created into a
                        // collapsed group would appear and instantly vanish.
                        action: {
                            collapseStore.expand(NSHomeDirectory())
                            onNewTab(NSHomeDirectory(), nil)
                        }
                    )
                }
                .padding(8)
                // Whether a tab change animates is decided at the publish
                // site (SidebarTabManager.refresh): removals and single-row
                // inserts animate; bulk population and Reduce Motion stay
                // instant.
            }

            // UpdatePill renders nothing when idle; the outer `if` also drops
            // the divider and padding so the footer doesn't grow an empty gap.
            if !updateModel.state.isIdle {
                Rectangle()
                    .fill(foreground.opacity(0.08))
                    .frame(height: 1)

                HStack {
                    UpdatePill(model: updateModel)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 19)
                .padding(.vertical, 17)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
    }

    /// One tab row — shared between the flat and the grouped layout so the
    /// row identity (and thus its insert/remove transition) is the same in
    /// both.
    private func tabRow(_ tab: SidebarTabManager.TabItem) -> some View {
        SidebarTabRow(
            tab: tab,
            foreground: foreground,
            fontSize: settings.sidebarFontSize,
            onSelect: { tabManager.select(tab) },
            onClose: { tabManager.close(tab) },
            onRename: { tabManager.rename(tab, to: $0) }
        )
        .transition(.phanttomTabRow)
    }
}

/// The "New tab" row at the end of the tab list: same metrics and hover
/// treatment as a terminal tab row, so it reads as "the next tab slot".
private struct NewTabRow: View {
    let foreground: Color
    let fontSize: Double
    let action: () -> Void

    @State private var isHovering = false

    private var iconSize: CGFloat { CGFloat(fontSize) + 2 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: max(6, fontSize - 2), weight: .medium))
                    .frame(width: iconSize, height: iconSize)
                Text("New tab")
                    .font(.system(size: fontSize))
                Spacer(minLength: 0)
            }
            .foregroundStyle(foreground.opacity(isHovering ? 1 : 0.7))
            .padding(.vertical, 8)
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(foreground.opacity(isHovering ? 0.04 : 0))
        )
        .onHover { isHovering = $0 }
        .backport.pointerStyle(.link)
        .help("New Tab (⌘T)")
    }
}

extension AnyTransition {
    /// Transition for sidebar tab rows: a fade with a slight top-anchored
    /// compression, so a closing tab reads as collapsing in place and a new
    /// tab as unfolding downward; the layout slide of the neighboring rows
    /// does the rest of the storytelling. Whether a given change animates at
    /// all is decided at the publish site (SidebarTabManager.refresh):
    /// removals and single-row inserts do, bulk population doesn't.
    static let phanttomTabRow: AnyTransition = .opacity
        .combined(with: .scale(scale: 0.92, anchor: .top))
}

struct SidebarTabRow: View {
    let tab: SidebarTabManager.TabItem
    let foreground: Color
    let fontSize: Double
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String?) -> Void

    /// Secondary text and icons scale with the title so rows stay balanced.
    private var subtitleSize: Double { max(8, fontSize - 1) }
    private var iconSize: CGFloat { CGFloat(fontSize) + 2 }

    @State private var isHovering = false
    @State private var isHoveringClose = false
    @State private var isEditing = false
    @State private var draft = ""
    @State private var draftOriginal = ""
    @FocusState private var editFocused: Bool

    private var rowBackground: Color {
        if tab.isSelected { return foreground.opacity(0.08) }
        if isHovering { return foreground.opacity(0.04) }
        return Color.clear
    }

    var body: some View {
        // Select/rename gestures live on the label only — wrapping the close
        // button too would make X clicks also select (front) the tab, and
        // guarding on the X's hover state is fragile (onHover doesn't re-fire
        // when a row's frame shifts under a stationary cursor). Padding lives
        // on the children so the label's contentShape still covers the row
        // edge (not just the text).
        HStack(spacing: 0) {
            Group {
                switch tab.kind {
                case .terminal: terminalRow
                case .claude, .codex: agentRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
            // Double-tap as .gesture plus single-tap as .simultaneousGesture:
            // chained onTapGesture modifiers would delay the single tap by the
            // double-click disambiguation window (~300ms), which reads as tab-
            // switching lag. This way selection fires on the first click
            // immediately and a second click still starts a rename (Finder-style).
            .gesture(TapGesture(count: 2).onEnded(startRename))
            .simultaneousGesture(TapGesture().onEnded(onSelect))

            Group {
                switch tab.kind {
                case .terminal: trailing
                case .claude: agentTrailing(icon: "PhanttomClaude")
                case .codex: agentTrailing(icon: "PhanttomCodex")
                }
            }
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(rowBackground))
        // The idle trailing slot is Color.clear, which is not hit-testable —
        // without an explicit shape, hover dies over the far-right strip of
        // a non-hovered row (exactly where the X will appear).
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if !hovering { isHoveringClose = false }
        }
        .contextMenu {
            Button("Rename Tab…", action: startRename)
            if tab.customTitle != nil || tab.autoTitle != nil {
                Button("Reset Name") { onRename(nil) }
            }
            Divider()
            Button("Close Tab", action: onClose)
        }
        .help(tab.directory ?? tab.title)
    }

    private func startRename() {
        draft = tab.customTitle ?? tab.displayTitle
        draftOriginal = draft
        isEditing = true
        // Focus a turn later: the TextField doesn't exist yet in this
        // transaction, and a same-transaction focus write can be dropped
        // (macOS 13 especially).
        DispatchQueue.main.async { editFocused = true }
    }

    private func commitRename() {
        guard isEditing else { return }
        isEditing = false
        // An untouched draft is a cancel, not a rename: committing the
        // prefilled display title would freeze an ephemeral auto/derived
        // name into a permanent custom one.
        guard draft != draftOriginal || tab.customTitle != nil else { return }
        onRename(draft)
    }

    /// Inline name editor swapped in for the title while renaming.
    private var titleEditor: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize))
            .foregroundStyle(foreground)
            .focused($editFocused)
            .onSubmit(commitRename)
            .onChange(of: editFocused) { focused in
                if !focused { commitRename() }
            }
            .onExitCommand {
                isEditing = false
            }
    }

    /// Compact 29pt row: leading status slot (same position and metrics as
    /// the agent cards, so the idle/status dots line up down the whole
    /// list) + abbreviated path.
    private var terminalRow: some View {
        HStack(spacing: 8) {
            statusIndicator
                .frame(width: 15, height: iconSize)
            if isEditing {
                titleEditor
            } else {
                Text(tab.customTitle ?? tab.abbreviatedDirectory ?? (tab.title.isEmpty ? "Terminal" : tab.title))
                    .font(.system(size: fontSize))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(height: iconSize)
    }

    /// Two-line agent card: leading status slot, then title over
    /// directory + branch. The close button and agent icon live in the
    /// trailing column (`agentTrailing`), outside the select/rename gestures.
    private var agentRow: some View {
        HStack(spacing: 8) {
            // Fixed-width slot so titles stay put as status comes and goes.
            statusIndicator
                .frame(width: 15, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    titleEditor
                } else {
                    Text(tab.displayTitle.isEmpty ? "Terminal" : tab.displayTitle)
                        .font(.system(size: fontSize))
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Branch when there is one (worktree branches show like any
                // other — the branch name is the identity that matters, and
                // it is the agent's real checkout either way); outside a
                // repo, the directory leaf with a folder glyph so the line
                // is never empty. Full pwd stays in the row's help tooltip.
                if let branch = tab.git?.branch {
                    subtitleLabel(icon: "PhanttomGitBranch", text: branch)
                } else if let leaf = tab.directoryLeaf {
                    subtitleLabel(icon: "PhanttomFolder", text: leaf)
                }
            }
        }
    }

    /// One entry on the agent card's subtitle line: template glyph + text,
    /// same metrics for the branch and the no-repo directory fallback so
    /// the line doesn't shift when a directory becomes a checkout.
    private func subtitleLabel(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: subtitleSize, height: subtitleSize)
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(foreground.opacity(0.8))
        .font(.system(size: subtitleSize))
    }

    /// Status indicator: leading slot on agent cards, trailing slot on
    /// terminal rows. Agent activity wins; an otherwise-idle tab shows its
    /// branch's GitHub PR state (green = open, purple = merged), and a
    /// faint white dot when there's nothing else to say.
    @ViewBuilder private var statusIndicator: some View {
        switch tab.status {
        case .idle:
            switch tab.prState {
            case .open:
                statusDot(Color(red: 0x3F / 255, green: 0xB9 / 255, blue: 0x50 / 255))
            case .merged:
                statusDot(Color(red: 0xA3 / 255, green: 0x71 / 255, blue: 0xF7 / 255))
            case nil:
                // Faint presence mark — no glow, unlike done/attention dots.
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 8, height: 8)
            }
        case .working:
            PixelSparkleView()
        case .done:
            statusDot(Color(red: 0x2C / 255, green: 0x86 / 255, blue: 0xF4 / 255))
        case .attention:
            statusDot(Color(red: 0xF4 / 255, green: 0xBC / 255, blue: 0x2C / 255))
        }
    }

    private func statusDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.5), radius: 2)
    }

    /// Trailing column on agent cards: hover close button aligned with the
    /// title line, model label aligned with the subtitle line. With a known
    /// model the label is the bare brand mark + model name (per the design);
    /// until the hook has reported one (or for agents that never do, like
    /// Codex) it stays the chip-style agent icon alone.
    private func agentTrailing(icon: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Group {
                if isHovering {
                    closeButton(glyphSize: 8, slot: iconSize)
                } else {
                    Color.clear
                }
            }
            .frame(width: iconSize, height: iconSize)
            if let model = tab.model {
                HStack(spacing: 3) {
                    Image("PhanttomClaudeMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: CGFloat(subtitleSize) - 2,
                               height: CGFloat(subtitleSize) - 2)
                    Text(model)
                        .font(.system(size: subtitleSize))
                        .foregroundStyle(foreground.opacity(0.65))
                        .lineLimit(1)
                }
                .frame(height: iconSize)
            } else {
                Image(icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
            }
        }
    }

    /// Trailing edge of terminal rows: just the hover close button (status
    /// lives in the leading slot, mirroring agent cards). Fixed 18×18 slot
    /// so the X appearing never shifts row height or label width.
    @ViewBuilder private var trailing: some View {
        Group {
            if isHovering {
                closeButton(glyphSize: 8, slot: 16)
            } else {
                Color.clear
            }
        }
        .frame(width: 18, height: 18)
    }

    private func closeButton(glyphSize: Double, slot: CGFloat) -> some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: glyphSize, weight: .bold))
                .foregroundStyle(foreground.opacity(isHoveringClose ? 0.95 : 0.55))
                .frame(width: slot, height: slot)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(foreground.opacity(isHoveringClose ? 0.14 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close Tab")
        .onHover { isHoveringClose = $0 }
        .backport.pointerStyle(.link)
    }
}

/// The "working" indicator: pixel rain. Four columns of drops fall through a
/// 5-row grid, each column with its own speed and phase; the drop head is
/// bright with an exponential trail above it and a sharp falloff below.
/// Ported from the design's canvas reference ("Bare rain, 4 col").
struct PixelSparkleView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var settings = PhanttomSettings.shared

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
        let color = settings.sidebarWorkingColor
        return Group {
            if reduceMotion {
                Canvas { canvas, _ in Self.draw(t: 0.6, color: color, into: &canvas) }
            } else {
                TimelineView(.animation) { context in
                    Canvas { canvas, _ in
                        Self.draw(
                            t: context.date.timeIntervalSinceReferenceDate,
                            color: color,
                            into: &canvas)
                    }
                }
            }
        }
        .frame(width: 15, height: 18)
        .accessibilityLabel("Working")
    }

    private static func draw(t: Double, color: Color, into canvas: inout GraphicsContext) {
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
                    x: CGFloat(i) * pitch,
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

