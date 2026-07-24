import SwiftUI

/// The vertical tab sidebar: compact rows for plain terminal tabs, two-line
/// cards for agent tabs (Claude/Codex). Both row styles lead with the status
/// indicator (animated pixel rain while working, status dots / PR icons)
/// so the marks form one column down the list. Agent cards put the close
/// button inline on the title row and anchor the agent icon + model name at
/// the bottom-right beside the git branch line. Chrome colors and metrics
/// match the Figma design (solid `#161917`, no glass).
struct SidebarView: View {
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
                VStack(alignment: .leading, spacing: 20) {
                    if grouped {
                        ForEach(groups) { group in
                            switch group {
                            case .project(let id, let title, let groupTabs):
                                projectBlock(
                                    id: id,
                                    title: title,
                                    groupTabs: groupTabs)
                            case .pending(let pendingTabs):
                                VStack(spacing: 4) {
                                    ForEach(pendingTabs) { tab in
                                        tabRow(tab)
                                    }
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 4) {
                            ForEach(tabManager.tabs) { tab in
                                tabRow(tab)
                            }
                        }
                    }

                    // Full-width row trailing the last tab; project-neutral —
                    // always opens in home (~), not the focused project.
                    // Expand that group first so a row into a collapsed ~
                    // doesn't appear and instantly vanish.
                    NewTabRow {
                        collapseStore.expand(NSHomeDirectory())
                        onNewTab(NSHomeDirectory(), nil)
                    }
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
                    .fill(Color.white.opacity(0.08))
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
        .background(PhanttomSettings.sidebarBackground.ignoresSafeArea())
    }

    @ViewBuilder
    private func projectBlock(
        id: String,
        title: String,
        groupTabs: [SidebarTabManager.TabItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProjectHeader(
                name: title,
                isCollapsed: collapseStore.isCollapsed(id),
                // Developer-folder picker is home-only — other project
                // groups already have a dedicated "+" for their own root.
                showDeveloperFolders: id == NSHomeDirectory(),
                onToggle: {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                        collapseStore.toggle(id)
                    }
                },
                onNewTab: {
                    collapseStore.expand(id)
                    onNewTab(id, groupTabs.first?.window)
                },
                onOpenProject: { path in
                    collapseStore.expand(path)
                    let insertBefore = tabManager.tabs.first { tab in
                        (tab.git?.projectRoot ?? tab.directory) == path
                    }?.window
                    onNewTab(path, insertBefore)
                }
            )
            .transition(.phanttomTabRow)
            if !collapseStore.isCollapsed(id) {
                VStack(spacing: 4) {
                    ForEach(groupTabs) { tab in
                        tabRow(tab)
                    }
                }
            }
        }
    }

    /// One tab row — shared between the flat and the grouped layout so the
    /// row identity (and thus its insert/remove transition) is the same in
    /// both.
    private func tabRow(_ tab: SidebarTabManager.TabItem) -> some View {
        SidebarTabRow(
            tab: tab,
            onSelect: { tabManager.select(tab) },
            onClose: { tabManager.close(tab) },
            onRename: { tabManager.rename(tab, to: $0) }
        )
        .transition(.phanttomTabRow)
    }
}

/// Bottom-of-list "New tab" control. Always seeds home (`~`), matching ⌘T's
/// typical landing when no project context is chosen.
private struct NewTabRow: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarLeadingColumn.contentSpacing) {
                Image("PhanttomPlus")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .frame(
                        width: SidebarLeadingColumn.width,
                        height: SidebarLeadingColumn.width)
                Text("New tab")
                    .font(SidebarFont.font(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(isHovering ? 0.95 : 0.55))
            .padding(.vertical, 8)
            .padding(.leading, SidebarLeadingColumn.padding)
            .padding(.trailing, SidebarTrailingColumn.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(isHovering ? 0.04 : 0))
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
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String?) -> Void

    private let titleSize: Double = 12
    private let subtitleSize: Double = 10
    /// Same slot as `SidebarTrailingColumn.slot` / project-header Plus so
    /// close X and Plus share a center-x (`padding + slot/2`).
    private let closeSlot: CGFloat = SidebarTrailingColumn.slot

    @State private var isHovering = false
    @State private var isHoveringClose = false
    @State private var isEditing = false
    @State private var draft = ""
    @State private var draftOriginal = ""
    @FocusState private var editFocused: Bool

    private var rowBackground: Color {
        if tab.isSelected || isHovering { return Color.white.opacity(0.04) }
        return Color.clear
    }

    private var cornerRadius: CGFloat {
        tab.isSelected ? 12 : 8
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
            .padding(.leading, SidebarLeadingColumn.padding)
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
            .padding(.trailing, SidebarTrailingColumn.padding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: cornerRadius).fill(rowBackground))
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
            .font(SidebarFont.font(size: titleSize))
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

    /// Compact row: leading status slot + abbreviated path.
    private var terminalRow: some View {
        HStack(spacing: SidebarLeadingColumn.contentSpacing) {
            statusIndicator
                .frame(width: SidebarLeadingColumn.width, height: 13)
            if isEditing {
                titleEditor
            } else {
                Text(tab.customTitle ?? tab.abbreviatedDirectory ?? (tab.title.isEmpty ? "Terminal" : tab.title))
                    .font(SidebarFont.font(size: titleSize))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// Two-line agent card: leading status slot, then title over
    /// directory + branch. The close button and agent icon live in the
    /// trailing column (`agentTrailing`), outside the select/rename gestures.
    private var agentRow: some View {
        HStack(spacing: SidebarLeadingColumn.contentSpacing) {
            // Fixed-width slot so titles stay put as status comes and goes;
            // width matches the project-header folder column above.
            statusIndicator
                .frame(width: SidebarLeadingColumn.width, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    titleEditor
                } else {
                    Text(tab.displayTitle.isEmpty ? "Terminal" : tab.displayTitle)
                        .font(SidebarFont.font(size: titleSize))
                        .foregroundStyle(.white)
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
        HStack(spacing: 2) {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: 10, height: 10)
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Color.white.opacity(0.5))
        .font(SidebarFont.font(size: subtitleSize))
    }

    /// Status indicator: leading slot on both agent cards and terminal
    /// rows. Agent activity wins; an otherwise-idle tab shows its branch's
    /// GitHub PR state (PR icons), and a faint white dot when there's
    /// nothing else to say.
    @ViewBuilder private var statusIndicator: some View {
        switch tab.status {
        case .idle:
            switch tab.prState {
            case .open:
                Image("PhanttomGitPullRequestOpen")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
            case .merged:
                Image("PhanttomGitPullRequestMerged")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
            case nil:
                Circle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        case .working:
            PixelSparkleView()
        case .done:
            statusDot(PhanttomSettings.doneStatusColor)
        case .attention:
            statusDot(PhanttomSettings.attentionStatusColor)
        }
    }

    private func statusDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    /// Trailing column on agent cards: hover close button aligned with the
    /// title line, model label aligned with the subtitle line. With a known
    /// model the label is the bare brand mark + model name; until the hook
    /// has reported one it stays the chip-style `icon`.
    private func agentTrailing(icon: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Group {
                if isHovering {
                    closeButton
                } else {
                    Color.clear
                }
            }
            .frame(width: closeSlot, height: closeSlot)
            if let model = tab.model, let mark = brandMark(for: tab.kind) {
                HStack(spacing: 4) {
                    Image(mark)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 8, height: 8)
                    Text(model)
                        .font(SidebarFont.font(size: subtitleSize))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                }
                .frame(height: 13)
            } else {
                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
            }
        }
    }

    /// Bare brand mark for the model-label trailing slot. nil → chip `icon`.
    private func brandMark(for kind: SidebarTabManager.TabKind) -> String? {
        switch kind {
        case .claude: return "PhanttomClaudeMark"
        case .codex: return "PhanttomCodexMark"
        case .terminal: return nil
        }
    }

    /// Trailing edge of terminal rows: just the hover close button.
    @ViewBuilder private var trailing: some View {
        Group {
            if isHovering {
                closeButton
            } else {
                Color.clear
            }
        }
        .frame(width: closeSlot, height: closeSlot)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            // SF Symbol in the shared trailing slot (16pt); slightly larger
            // than the old 6pt/13pt Figma metrics so it reads at sidebar scale.
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white.opacity(isHoveringClose ? 0.95 : 0.55))
                .frame(width: closeSlot, height: closeSlot)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(isHoveringClose ? 0.14 : 0))
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
/// Ported from the design's canvas reference ("Bare rain, 4 col"). Color is
/// locked to Figma `#24FE8A`.
struct PixelSparkleView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rows = 5
    private static let cols = 4
    private static let pitch: CGFloat = 3.8
    private static let cell: CGFloat = 2.85
    private static let color = PhanttomSettings.workingIndicatorColor

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
                        Self.draw(
                            t: context.date.timeIntervalSinceReferenceDate,
                            into: &canvas)
                    }
                }
            }
        }
        .frame(width: SidebarLeadingColumn.width, height: 18)
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
