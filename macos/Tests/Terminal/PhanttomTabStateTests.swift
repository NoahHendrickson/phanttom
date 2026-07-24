import Testing
@testable import Ghostty

/// Tests for the Phanttom per-tab state machine: agent-kind detection,
/// first-prompt auto-naming (and its re-arm semantics), and the
/// working/done/attention status transitions. See PHANTTOM.md
/// "Tab semantics" for the behavioral contract these encode.
@Suite
@MainActor
struct PhanttomTabStateTests {
    /// The hook's marker: "❯" + U+2063 (INVISIBLE SEPARATOR).
    private let marker = PhanttomTabState.autoNameMarker

    // MARK: - Kind detection

    @Test func plainTitleResetsIdentity() {
        let state = PhanttomTabState()
        state.update(titles: ["\(marker) fix login bug"], isWorking: false, isSelected: true)
        #expect(state.kind == .claude)
        #expect(state.autoTitle == "fix login bug")

        state.update(titles: ["zsh"], isWorking: false, isSelected: true)
        #expect(state.kind == .terminal)
        #expect(state.autoTitle == nil)
    }

    @Test func claudeCodexAndCursorTitlesSetKind() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: false, isSelected: true)
        #expect(state.kind == .claude)

        state.update(titles: ["codex exec"], isWorking: false, isSelected: true)
        #expect(state.kind == .codex)

        state.update(titles: ["Cursor Agent"], isWorking: false, isSelected: true)
        #expect(state.kind == .cursor)

        state.update(titles: ["cursor-agent"], isWorking: false, isSelected: true)
        #expect(state.kind == .cursor)

        // Bare "agent" must not become a Cursor tab.
        state.update(titles: ["zsh"], isWorking: false, isSelected: true)
        state.update(titles: ["agent"], isWorking: false, isSelected: true)
        #expect(state.kind == .terminal)
    }

    @Test func cursorInAPathTitleIsNotAnAgentTab() {
        // "cursor" is an ordinary word in paths and filenames, and every
        // Cursor user has a `~/.cursor`. A shell tab whose title is its cwd
        // (or an edited file) must stay a plain terminal row — the match is
        // anchored at the start of the title, not a substring scan.
        for title in ["~/.cursor", "src/cursor.rs", "vim cursor.c", "nvim: cursor"] {
            let state = PhanttomTabState()
            state.update(titles: [title], isWorking: false, isSelected: true)
            #expect(state.kind == .terminal, "\(title) should not be a Cursor tab")
        }
    }

    @Test func decoratedTitleKeepsStickyKind() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: false, isSelected: true)
        state.update(titles: ["✳ Compacting conversation"], isWorking: false, isSelected: true)
        #expect(state.kind == .claude)
    }

    @Test func bareChevronPromptIsNotAnAgent() {
        // "❯" without U+2063 is the default prompt char of starship/pure —
        // it must be treated as a decorated title, never as our marker.
        let state = PhanttomTabState()
        state.update(titles: ["❯ ~/dev"], isWorking: false, isSelected: true)
        #expect(state.kind == .terminal)
        #expect(state.autoTitle == nil)
    }

    @Test func backgroundSplitAgentTitleKeepsIdentity() {
        // The focused split's plain title must not wipe an idle agent
        // living in another split (identity is judged from every title).
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: false, isSelected: true)
        state.update(titles: ["zsh", "✳ Waiting on your input"], isWorking: false, isSelected: true)
        #expect(state.kind == .claude)
    }

    @Test func workingPlainTitleKeepsIdentity() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: false, isSelected: true)
        state.update(titles: ["zsh"], isWorking: true, isSelected: true)
        #expect(state.kind == .claude)
    }

    // MARK: - Auto-naming

    @Test func markerCapturesFirstPromptOnly() {
        let state = PhanttomTabState()
        state.update(titles: ["\(marker) first prompt"], isWorking: false, isSelected: true)
        #expect(state.autoTitle == "first prompt")

        state.update(titles: ["\(marker) second prompt"], isWorking: false, isSelected: true)
        #expect(state.autoTitle == "first prompt")
    }

    @Test func markerInBackgroundSplitCapturesName() {
        let state = PhanttomTabState()
        state.update(titles: ["zsh", "\(marker) refactor the cache"], isWorking: false, isSelected: true)
        #expect(state.kind == .claude)
        #expect(state.autoTitle == "refactor the cache")
    }

    @Test func rearmConsumesCurrentMarkerTitle() {
        let state = PhanttomTabState()
        state.update(titles: ["\(marker) fix login bug"], isWorking: false, isSelected: true)
        state.rearmAutoTitle()
        #expect(state.autoTitle == nil)

        // The still-current marker title must not be re-captured...
        state.update(titles: ["\(marker) fix login bug"], isWorking: false, isSelected: true)
        #expect(state.autoTitle == nil)

        // ...but a NEW prompt names the tab again.
        state.update(titles: ["\(marker) add dark mode"], isWorking: false, isSelected: true)
        #expect(state.autoTitle == "add dark mode")
    }

    // MARK: - Model reporting

    @Test func markerModelSuffixSetsModelAndStaysSticky() {
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker) fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isSelected: true)
        #expect(state.autoTitle == "fix login bug")
        // State stores the raw id; pretty-printing is a TabItem/view concern.
        #expect(state.model == "claude-fable-5")
        #expect(state.titleFallback == "fix login bug")

        // An empty model field (first turn of a fresh session, transcript
        // not yet written) keeps the last known model.
        state.update(
            titles: ["\(marker) another prompt\u{2063}"],
            isWorking: false, isSelected: true)
        #expect(state.model == "claude-fable-5")

        // A model switch mid-session (e.g. /model) updates the id even
        // though the auto-name stays locked to the first prompt.
        state.update(
            titles: ["\(marker) another prompt\u{2063}claude-opus-4-8"],
            isWorking: false, isSelected: true)
        #expect(state.autoTitle == "fix login bug")
        #expect(state.model == "claude-opus-4-8")
    }

    @Test func modelOnlyMarkerSetsModelWithoutNamingTab() {
        // Legacy statusline sideband: "❯" + U+2063 + U+2063 + model.
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker)\u{2063}claude-fable-5"],
            isWorking: false, isSelected: true)
        #expect(state.kind == .claude)
        #expect(state.model == "claude-fable-5")
        #expect(state.autoTitle == nil)
        #expect(state.titleFallback == "Claude")

        // The first real prompt still names the tab afterwards.
        state.update(
            titles: ["\(marker) fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isSelected: true)
        #expect(state.autoTitle == "fix login bug")
        #expect(state.titleFallback == "fix login bug")
    }

    @Test func kindTokenMarkerSetsCursorKindAndModel() {
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker).cursor\u{2063}\u{2063}grok-4.5"],
            isWorking: false, isSelected: true)
        #expect(state.kind == .cursor)
        #expect(state.model == "grok-4.5")
        #expect(state.autoTitle == nil)
        #expect(state.titleFallback == "Cursor")

        state.update(
            titles: ["\(marker).cursor\u{2063}fix the sidebar\u{2063}grok-4.5"],
            isWorking: false, isSelected: true)
        #expect(state.kind == .cursor)
        #expect(state.autoTitle == "fix the sidebar")
        #expect(state.titleFallback == "fix the sidebar")
    }

    @Test func kindTokenMarkerSetsClaudeKind() {
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker).claude\u{2063}fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isSelected: true)
        #expect(state.kind == .claude)
        #expect(state.autoTitle == "fix login bug")
        #expect(state.model == "claude-fable-5")
    }

    @Test func legacyPromptNamedCursorDoesNotBecomeCursorKind() {
        // Dot-prefixed tokens avoid this collision; a bare "cursor" prompt
        // under the legacy format must stay Claude.
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker)cursor\u{2063}claude-fable-5"],
            isWorking: false, isSelected: true)
        #expect(state.kind == .claude)
        #expect(state.autoTitle == "cursor")
        #expect(state.model == "claude-fable-5")
    }

    @Test func cursorMarkerForcesKindBackFromCodex() {
        let state = PhanttomTabState()
        state.update(titles: ["codex exec"], isWorking: false, isSelected: true)
        #expect(state.kind == .codex)

        state.update(
            titles: ["\(marker).cursor\u{2063}\u{2063}grok-4.5"],
            isWorking: false, isSelected: true)
        #expect(state.kind == .cursor)
        #expect(state.model == "grok-4.5")
    }

    @Test func markerWithoutModelSuffixLeavesModelNil() {
        let state = PhanttomTabState()
        state.update(titles: ["\(marker) fix login bug"], isWorking: false, isSelected: true)
        #expect(state.model == nil)
    }

    @Test func shellReclaimClearsModel() {
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker) fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isSelected: true)
        state.update(titles: ["zsh"], isWorking: false, isSelected: true)
        #expect(state.kind == .terminal)
        #expect(state.model == nil)
        #expect(state.titleFallback == nil)
    }

    @Test func kindChangeClearsStaleModel() {
        // Claude session reports a model, then Codex starts in the same tab
        // without a plain interstitial title — the namedKind branch must
        // drop the previous session's model so the Codex card can't show a
        // stale Claude badge.
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker) fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isSelected: true)
        #expect(state.kind == .claude)
        #expect(state.model == "claude-fable-5")

        state.update(titles: ["codex exec"], isWorking: false, isSelected: true)
        #expect(state.kind == .codex)
        #expect(state.model == nil)
        #expect(state.titleFallback == nil)
    }

    @Test func markerForcesKindBackFromCodex() {
        // Codex first, then a Claude marker (no plain "claude" title): the
        // marker path must flip kind to .claude so the model badge can show.
        let state = PhanttomTabState()
        state.update(titles: ["codex exec"], isWorking: false, isSelected: true)
        #expect(state.kind == .codex)

        state.update(
            titles: ["\(marker) fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isSelected: true)
        #expect(state.kind == .claude)
        #expect(state.model == "claude-fable-5")
        #expect(state.autoTitle == "fix login bug")
    }

    @Test func rearmKeepsTitleFallbackFromCurrentMarker() {
        // After Reset Name, autoTitle is nil but the still-current marker
        // prompt must remain available as the presentation fallback so the
        // view model never re-parses the wire format.
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker) fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isSelected: true)
        state.rearmAutoTitle()
        #expect(state.autoTitle == nil)

        state.update(
            titles: ["\(marker) fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isSelected: true)
        #expect(state.autoTitle == nil)
        #expect(state.titleFallback == "fix login bug")
    }

    @Test func modelDisplayNames() {
        #expect(PhanttomTabState.modelDisplayName("claude-fable-5") == "Fable 5")
        #expect(PhanttomTabState.modelDisplayName("claude-opus-4-8") == "Opus 4.8")
        #expect(PhanttomTabState.modelDisplayName("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(PhanttomTabState.modelDisplayName("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        // Qualifiers after the version are not version tokens.
        #expect(PhanttomTabState.modelDisplayName("claude-opus-4-8-preview-2") == "Opus 4.8")
        // No recognizable family word: show the id rather than hiding.
        #expect(PhanttomTabState.modelDisplayName("claude") == "claude")
    }

    // MARK: - Status transitions

    @Test func workingEndsUnselectedBecomesDone() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: true, isSelected: false)
        #expect(state.status == .working)

        state.update(titles: ["claude"], isWorking: false, isSelected: false)
        #expect(state.status == .done)

        // Selection acknowledges.
        state.update(titles: ["claude"], isWorking: false, isSelected: true)
        #expect(state.status == .idle)
    }

    @Test func workingEndsSelectedIsIdle() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: true, isSelected: true)
        #expect(state.status == .working)

        state.update(titles: ["claude"], isWorking: false, isSelected: true)
        #expect(state.status == .idle)
    }

    @Test func bellMarksAttentionOnlyFromIdle() {
        let state = PhanttomTabState()
        state.noteBell()
        #expect(state.status == .attention)

        // Working outranks attention; a bell mid-work is not recorded.
        state.update(titles: ["claude"], isWorking: true, isSelected: false)
        state.noteBell()
        #expect(state.status == .working)

        // And done outranks a later bell.
        state.update(titles: ["claude"], isWorking: false, isSelected: false)
        #expect(state.status == .done)
        state.noteBell()
        #expect(state.status == .done)
    }

    @Test func selectionClearsAttention() {
        let state = PhanttomTabState()
        state.noteBell()
        #expect(state.status == .attention)
        state.update(titles: ["zsh"], isWorking: false, isSelected: true)
        #expect(state.status == .idle)
    }
}
