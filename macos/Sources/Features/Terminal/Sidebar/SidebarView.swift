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
    @ObservedObject private var groupOrderStore = ProjectGroupOrderStore.shared
    @ObservedObject private var dragHover = SidebarDragHover.shared
    /// Owns the live reorder drag. Held as `@State` rather than
    /// `@StateObject` deliberately: `@State` stores the reference without
    /// subscribing to it, so a drag re-renders only the per-row slot
    /// wrappers that do observe it — never this body, which would re-run the
    /// project partition and rebuild every row on each mouse move.
    @State private var reorder = SidebarReorderController()

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
        let groups = SidebarTabGroup.groups(
            from: tabManager.tabs,
            preferringOrder: groupOrderStore.order)
        let grouped = settings.sidebarGroupByProject && groups.contains {
            if case .project = $0 { return true } else { return false }
        }
        let projectIDs: [String] = groups.compactMap {
            if case .project(let id, _, _) = $0 { return id } else { return nil }
        }
        VStack(spacing: 0) {
            // Pinned above the tab list: "Sessions" label + ~/Developer
            // picker + new-tab (home), trailing controls matching project
            // headers.
            SessionsHeader(
                onNewTab: {
                    let home = NSHomeDirectory()
                    collapseStore.expand(home)
                    groupOrderStore.bringToFront(home)
                    onNewTab(home, insertBeforeWindow(forProject: home))
                },
                onOpenProject: { path in
                    collapseStore.expand(path)
                    groupOrderStore.bringToFront(path)
                    onNewTab(path, insertBeforeWindow(forProject: path))
                }
            )
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

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
                                    groupTabs: groupTabs,
                                    visibleProjectIDs: projectIDs)
                            case .pending(let pendingTabs):
                                VStack(spacing: 4) {
                                    ForEach(pendingTabs) { tab in
                                        // Pending tabs share a nil project key —
                                        // constrain so they reorder among themselves.
                                        tabRow(tab, constrainToProject: true)
                                    }
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 4) {
                            ForEach(tabManager.tabs) { tab in
                                tabRow(tab, constrainToProject: false)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .padding(.top, 4)
                // Whether a tab change animates is decided at the publish
                // site (SidebarTabManager.refresh): removals and single-row
                // inserts animate; bulk population and Reduce Motion stay
                // instant.
                //
                // Reorder geometry lives in this space: rows report their
                // frames here and the drag gesture reports its location
                // here, so the two are directly comparable. Declared on the
                // content (not the ScrollView) so scrolling moves rows and
                // cursor together.
                .coordinateSpace(name: SidebarReorderSpace.name)
                .background(
                    SidebarScrollViewProbe { scrollView in
                        reorder.scrollView = scrollView
                    }
                )
                .onPreferenceChange(SidebarSlotsKey.self) { slots in
                    // The closure is non-isolated under the Xcode 16+ SDK;
                    // preferences are delivered on the main thread (same
                    // pattern as the notification observers in
                    // SidebarTabManager).
                    MainActor.assumeIsolated {
                        reorder.replaceSlots(slots)
                    }
                }
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
        // A tab closing (or its project emptying) while the mouse is still
        // down would otherwise leave the drag anchored to a row that no
        // longer exists. Keyed on identity, not on the whole list, so an
        // ordinary title or progress update doesn't abandon a live drag.
        .onChange(of: tabManager.tabs) { newTabs in
            var present = Set<SidebarReorderGeometry.SlotID>()
            for tab in newTabs {
                present.insert(.tab(windowNumber: tab.window.windowNumber))
                if let key = SidebarTabGroup.projectKey(for: tab) {
                    present.insert(.group(id: key))
                }
            }
            reorder.cancelIfDraggedIsMissing(among: present)
        }
    }

    /// Window to insert a new Sessions-header tab before: first tab of that
    /// project (top of its group), else the first tab overall (top of the
    /// list). Matches project-header "+" behavior.
    private func insertBeforeWindow(forProject path: String) -> NSWindow? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        if let match = tabManager.tabs.first(where: {
            SidebarTabGroup.projectKey(for: $0) == target
        }) {
            return match.window
        }
        return tabManager.tabs.first?.window
    }

    @ViewBuilder
    private func projectBlock(
        id: String,
        title: String,
        groupTabs: [SidebarTabManager.TabItem],
        visibleProjectIDs: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProjectHeader(
                name: title,
                isCollapsed: collapseStore.isCollapsed(id),
                hoverEnabled: !dragHover.suppressesHover,
                onToggle: {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                        collapseStore.toggle(id)
                    }
                },
                onNewTab: {
                    collapseStore.expand(id)
                    onNewTab(id, groupTabs.first?.window)
                },
                reorder: SidebarReorderHandle(
                    id: .group(id: id),
                    controller: reorder,
                    // Group order is global; there is nothing to constrain to.
                    constrainToProject: false,
                    onCommit: { commit in
                        applyGroupReorder(commit, visibleIDs: visibleProjectIDs)
                    },
                    canStep: { up in
                        stepTarget(for: id, up: up, in: visibleProjectIDs) != nil
                    },
                    step: { up in
                        guard let target = stepTarget(
                            for: id, up: up, in: visibleProjectIDs) else { return }
                        withAnimation(SidebarDragReorder.settleAnimation) {
                            groupOrderStore.move(
                                id,
                                relativeTo: target,
                                edge: up ? .before : .after,
                                visibleIDs: visibleProjectIDs)
                        }
                    })
            )
            .transition(.phanttomTabRow)
            if !collapseStore.isCollapsed(id) {
                VStack(spacing: 4) {
                    ForEach(groupTabs) { tab in
                        tabRow(tab, constrainToProject: true)
                    }
                }
            }
        }
        // The group's slot is the whole block, not just its header. Dragging
        // a project moves the header and its tabs together, and the gap that
        // opens for it is the height of everything being moved — a header
        // sliding out from over its own stationary tabs reads as broken.
        // Collapsed, the block is just the header, so the slot shrinks with
        // it for free. The tab rows keep their own slots nested inside for
        // tab drags; a group drag filters those out, so their offsets stay
        // zero and they simply travel with the block.
        .modifier(SidebarReorderSlot(
            id: .group(id: id),
            group: nil,
            controller: reorder))
    }

    /// One tab row — shared between the flat and the grouped layout so the
    /// row identity (and thus its insert/remove transition) is the same in
    /// both. `constrainToProject` rejects cross-group drops when grouping
    /// is on (grouping follows cwd/git root, so a drop cannot reassign a
    /// tab's project).
    private func tabRow(
        _ tab: SidebarTabManager.TabItem,
        constrainToProject: Bool
    ) -> some View {
        let windowNumber = tab.window.windowNumber
        return SidebarTabRow(
            tab: tab,
            hoverEnabled: !dragHover.suppressesHover,
            onSelect: { selectUnlessDragging(tab) },
            onClose: { tabManager.close(tab) },
            onRename: { tabManager.rename(tab, to: $0) },
            reorder: SidebarReorderHandle(
                id: .tab(windowNumber: windowNumber),
                controller: reorder,
                constrainToProject: constrainToProject,
                onCommit: applyTabReorder,
                canStep: { up in
                    canMoveTab(tab, up: up, constrainToProject: constrainToProject)
                },
                step: { up in
                    moveTab(tab, up: up, constrainToProject: constrainToProject)
                })
        )
        .modifier(SidebarReorderSlot(
            id: .tab(windowNumber: windowNumber),
            // Grouping follows cwd/git root, so a drop can never reassign a
            // tab's project — this key is what keeps a drag from offering a
            // target in someone else's group.
            group: SidebarTabGroup.projectKey(for: tab),
            controller: reorder))
        .transition(.phanttomTabRow)
    }

    /// The neighbouring group one step up or down, or nil at either end.
    private func stepTarget(
        for id: String,
        up: Bool,
        in visibleIDs: [String]
    ) -> String? {
        guard let index = visibleIDs.firstIndex(of: id) else { return nil }
        let target = up ? index - 1 : index + 1
        guard visibleIDs.indices.contains(target) else { return nil }
        return visibleIDs[target]
    }

    /// Step a tab one slot within the list it can actually move in. Backs the
    /// row's Move Up/Down menu items, which are the only reorder path
    /// reachable without a mouse — SwiftUI's `.onDrag`/`.onDrop` never
    /// offered VoiceOver drag on macOS, so this closes a gap the old
    /// implementation had too.
    private func moveTab(
        _ tab: SidebarTabManager.TabItem,
        up: Bool,
        constrainToProject: Bool
    ) {
        let key = SidebarTabGroup.projectKey(for: tab)
        let siblings = constrainToProject
            ? tabManager.tabs.filter { SidebarTabGroup.projectKey(for: $0) == key }
            : tabManager.tabs
        guard let index = siblings.firstIndex(where: { $0.id == tab.id }) else { return }
        let target = up ? index - 1 : index + 1
        guard siblings.indices.contains(target) else { return }
        tabManager.reorder(
            tab, relativeTo: siblings[target], edge: up ? .before : .after)
    }

    private func canMoveTab(
        _ tab: SidebarTabManager.TabItem,
        up: Bool,
        constrainToProject: Bool
    ) -> Bool {
        let key = SidebarTabGroup.projectKey(for: tab)
        let siblings = constrainToProject
            ? tabManager.tabs.filter { SidebarTabGroup.projectKey(for: $0) == key }
            : tabManager.tabs
        guard let index = siblings.firstIndex(where: { $0.id == tab.id }) else { return false }
        return siblings.indices.contains(up ? index - 1 : index + 1)
    }

    /// The mouse-up that ends a drag also fires the row's simultaneous select
    /// tap. `didDrag` is raised on a mouse-*moved* event, so it is reliably
    /// set by the time this runs — no timed window needed.
    private func selectUnlessDragging(_ tab: SidebarTabManager.TabItem) {
        guard !reorder.didDrag else { return }
        tabManager.select(tab)
    }

    /// Returns whether the reorder was applied. The anchor comes from the
    /// slot list frozen at drag start, so it can name a tab that has since
    /// closed — reporting that honestly lets the drop glide home instead of
    /// into a slot the list never took.
    @discardableResult
    private func applyTabReorder(_ commit: SidebarReorderController.Commit) -> Bool {
        guard case .tab(let sourceNumber) = commit.dragged,
              case .tab(let anchorNumber) = commit.anchor,
              let source = tabManager.tabs.first(where: {
                  $0.window.windowNumber == sourceNumber
              }),
              let anchor = tabManager.tabs.first(where: {
                  $0.window.windowNumber == anchorNumber
              })
        else { return false }
        // No animation: the rows already parted to show this exact
        // arrangement while dragging, so the commit only has to swap the
        // real order in underneath. Animating here is what used to read as
        // the row floating before it settled.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // reorder() posts .phanttomSidebarReorderDidFinish as it unwinds,
            // which refreshes every window's sidebar once, synchronously — so
            // the list is current before this returns without needing an
            // explicit refresh here.
            tabManager.reorder(
                source, relativeTo: anchor, edge: commit.edge, animated: false)
        }
        return true
    }

    /// Returns whether the reorder was applied — see `applyTabReorder`. A
    /// group's last tab can close mid-drag, taking the anchor with it.
    @discardableResult
    private func applyGroupReorder(
        _ commit: SidebarReorderController.Commit,
        visibleIDs: [String]
    ) -> Bool {
        guard case .group(let sourceID) = commit.dragged,
              case .group(let anchorID) = commit.anchor,
              visibleIDs.contains(sourceID),
              visibleIDs.contains(anchorID)
        else { return false }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            groupOrderStore.move(
                sourceID,
                relativeTo: anchorID,
                edge: commit.edge,
                visibleIDs: visibleIDs)
        }
        return true
    }
}

/// Top-of-sidebar chrome: "Sessions" label with trailing ~/Developer
/// folder-plus and new-tab "+" (always home / `~`), mirroring project
/// headers so the two actions stay visually distinct.
private struct SessionsHeader: View {
    let onNewTab: () -> Void
    let onOpenProject: (String) -> Void

    @State private var isHoveringPlus = false

    var body: some View {
        HStack(spacing: 0) {
            Text("Sessions")
                .font(SidebarFont.font(size: 12))
                .foregroundStyle(Color.white.opacity(0.65))
                .frame(maxWidth: .infinity, alignment: .leading)

            // NSButton+NSMenu — SwiftUI Menu forces a pure-white label tint.
            DeveloperFoldersButton(onOpen: onOpenProject)
                .frame(
                    width: SidebarTrailingColumn.slot,
                    height: SidebarTrailingColumn.slot)
                .padding(.trailing, 4)

            Button(action: onNewTab) {
                Image("PhanttomPlus")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(Color.white.opacity(isHoveringPlus ? 0.95 : 0.55))
                    .frame(
                        width: SidebarTrailingColumn.slot,
                        height: SidebarTrailingColumn.slot)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(isHoveringPlus ? 0.14 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
            .onHover { isHoveringPlus = $0 }
            .backport.pointerStyle(.link)
        }
        .padding(.leading, SidebarLeadingColumn.padding)
        .padding(.trailing, SidebarTrailingColumn.padding)
        .frame(height: 16)
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
    /// Off during reorder drag / settle so the row under the cursor doesn't
    /// paint a second highlight while the list animates.
    var hoverEnabled: Bool = true
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String?) -> Void
    /// Reorder drag. Lives on the row rather than at the call site so it can
    /// stand down while the inline rename field has focus.
    let reorder: SidebarReorderHandle

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
        if tab.isSelected { return Color.white.opacity(0.04) }
        if hoverEnabled && isHovering { return Color.white.opacity(0.04) }
        return Color.clear
    }

    private var cornerRadius: CGFloat { 12 }

    var body: some View {
        // Select/rename gestures live on the leading label AND the agent
        // card's trailing model strip (agentTrailing) — every part of the row
        // except the close button. Wrapping the close button too would make X
        // clicks also select (front) the tab, and guarding on the X's hover
        // state is fragile (onHover doesn't re-fire when a row's frame shifts
        // under a stationary cursor). Padding lives on the children so the
        // label's contentShape still covers the row edge (not just the text).
        HStack(spacing: 0) {
            Group {
                switch tab.kind {
                case .terminal: terminalRow
                case .claude, .codex, .cursor: agentRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.leading, SidebarLeadingColumn.padding)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
            // Both taps must be simultaneous (not exclusive `.gesture`): an
            // exclusive double-tap claims the mouse sequence and blocks the
            // row's `.onDrag`, so tab reorder never starts. Simultaneous keeps
            // first-click select immediate (no chained-onTapGesture delay) and
            // still lets a second click start rename (Finder-style).
            .simultaneousGesture(TapGesture(count: 2).onEnded(startRename))
            .simultaneousGesture(TapGesture().onEnded(onSelect))

            Group {
                switch tab.kind {
                case .terminal: trailing
                case .claude: agentTrailing(icon: "PhanttomClaude")
                case .codex: agentTrailing(icon: "PhanttomCodex")
                case .cursor: agentTrailing(icon: "PhanttomCursor")
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
            guard hoverEnabled else {
                isHovering = false
                isHoveringClose = false
                return
            }
            isHovering = hovering
            if !hovering { isHoveringClose = false }
        }
        .onChange(of: hoverEnabled) { enabled in
            if !enabled {
                isHovering = false
                isHoveringClose = false
            }
        }
        .contextMenu {
            Button("Rename Tab…", action: startRename)
            if tab.customTitle != nil || tab.autoTitle != nil {
                Button("Reset Name") { onRename(nil) }
            }
            if reorder.canStep(true) || reorder.canStep(false) {
                Divider()
                Button("Move Up") { reorder.step(true) }
                    .disabled(!reorder.canStep(true))
                Button("Move Down") { reorder.step(false) }
                    .disabled(!reorder.canStep(false))
            }
            Divider()
            Button("Close Tab", action: onClose)
        }
        .help(tab.directory ?? tab.title)
        .sidebarReorderDrag(reorder, isEnabled: !isEditing)
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
            // The model label is a wide strip; make it select/rename the row
            // like the leading label (same no-delay gesture pairing) so the
            // whole row — everything but the close button above — is tappable.
            Group {
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
            .contentShape(Rectangle())
            // Simultaneous (not exclusive `.gesture`) for the same reason as
            // the leading label: an exclusive double-tap claims the mouse
            // sequence and blocks the row's `.onDrag`, so a reorder started
            // from the model strip would never begin.
            .simultaneousGesture(TapGesture(count: 2).onEnded(startRename))
            .simultaneousGesture(TapGesture().onEnded(onSelect))
        }
    }

    /// Bare brand mark for the model-label trailing slot. nil → chip `icon`.
    private func brandMark(for kind: SidebarTabManager.TabKind) -> String? {
        switch kind {
        case .claude: return "PhanttomClaudeMark"
        case .codex: return "PhanttomCodexMark"
        case .cursor: return "PhanttomCursorMark"
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
