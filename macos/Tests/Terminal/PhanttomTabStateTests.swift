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

    @Test func claudeAndCodexTitlesSetKind() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: false, isSelected: true)
        #expect(state.kind == .claude)

        state.update(titles: ["codex exec"], isWorking: false, isSelected: true)
        #expect(state.kind == .codex)
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
        #expect(state.model == "Fable 5")

        // An empty model field (first turn of a fresh session, transcript
        // not yet written) keeps the last known model.
        state.update(
            titles: ["\(marker) another prompt\u{2063}"],
            isWorking: false, isSelected: true)
        #expect(state.model == "Fable 5")

        // A model switch mid-session (e.g. /model) updates the label even
        // though the auto-name stays locked to the first prompt.
        state.update(
            titles: ["\(marker) another prompt\u{2063}claude-opus-4-8"],
            isWorking: false, isSelected: true)
        #expect(state.autoTitle == "fix login bug")
        #expect(state.model == "Opus 4.8")
    }

    @Test func modelOnlyMarkerSetsModelWithoutNamingTab() {
        // The statusline sideband emits "❯" + U+2063 + U+2063 + model at
        // session start, before any prompt exists: model and kind must be
        // captured, the (empty) prompt field must not become an auto-name.
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker)\u{2063}claude-fable-5"],
            isWorking: false, isSelected: true)
        #expect(state.kind == .claude)
        #expect(state.model == "Fable 5")
        #expect(state.autoTitle == nil)

        // The first real prompt still names the tab afterwards.
        state.update(
            titles: ["\(marker) fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isSelected: true)
        #expect(state.autoTitle == "fix login bug")
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
    }

    @Test func modelDisplayNames() {
        #expect(PhanttomTabState.modelDisplayName("claude-fable-5") == "Fable 5")
        #expect(PhanttomTabState.modelDisplayName("claude-opus-4-8") == "Opus 4.8")
        #expect(PhanttomTabState.modelDisplayName("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(PhanttomTabState.modelDisplayName("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
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
