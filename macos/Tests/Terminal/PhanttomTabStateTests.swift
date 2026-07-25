import Foundation
import Testing
@testable import Ghostty

/// The window-level shorthand most of these tests are written against: the
/// tab has one split, which carries the whole window's working flag. That is
/// exactly the degenerate case of the per-surface API — and exactly what the
/// sidebar used to pass before status went per split — so every single-split
/// expectation below still exercises the real state machine. Scenarios with
/// two agents in one tab use `update(titles:surfaces:isWatched:)` directly
/// with distinct surface ids.
extension PhanttomTabState {
    /// Stand-in identity for a tab's only split.
    static let soleSurface = SurfaceID()

    func update(titles: [String], isWorking: Bool, isWatched: Bool) {
        update(
            titles: titles,
            surfaces: [.init(id: Self.soleSurface, isWorking: isWorking)],
            isWatched: isWatched)
    }

    func noteBell() {
        noteBell(surface: Self.soleSurface)
    }
}

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
        state.update(titles: ["\(marker) fix login bug"], isWorking: false, isWatched: true)
        #expect(state.kind == .claude)
        #expect(state.autoTitle == "fix login bug")

        state.update(titles: ["zsh"], isWorking: false, isWatched: true)
        #expect(state.kind == .terminal)
        #expect(state.autoTitle == nil)
    }

    @Test func claudeCodexAndCursorTitlesSetKind() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: false, isWatched: true)
        #expect(state.kind == .claude)

        state.update(titles: ["codex exec"], isWorking: false, isWatched: true)
        #expect(state.kind == .codex)

        state.update(titles: ["Cursor Agent"], isWorking: false, isWatched: true)
        #expect(state.kind == .cursor)

        state.update(titles: ["cursor-agent"], isWorking: false, isWatched: true)
        #expect(state.kind == .cursor)

        // Bare "agent" must not become a Cursor tab.
        state.update(titles: ["zsh"], isWorking: false, isWatched: true)
        state.update(titles: ["agent"], isWorking: false, isWatched: true)
        #expect(state.kind == .terminal)
    }

    @Test func cursorInAPathTitleIsNotAnAgentTab() {
        // "cursor" is an ordinary word in paths and filenames, and every
        // Cursor user has a `~/.cursor`. A shell tab whose title is its cwd
        // (or an edited file) must stay a plain terminal row — the match is
        // anchored at the start of the title, not a substring scan.
        for title in ["~/.cursor", "src/cursor.rs", "vim cursor.c", "nvim: cursor"] {
            let state = PhanttomTabState()
            state.update(titles: [title], isWorking: false, isWatched: true)
            #expect(state.kind == .terminal, "\(title) should not be a Cursor tab")
        }
    }

    @Test func decoratedTitleKeepsStickyKind() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: false, isWatched: true)
        state.update(titles: ["✳ Compacting conversation"], isWorking: false, isWatched: true)
        #expect(state.kind == .claude)
    }

    @Test func bareChevronPromptIsNotAnAgent() {
        // "❯" without U+2063 is the default prompt char of starship/pure —
        // it must be treated as a decorated title, never as our marker.
        let state = PhanttomTabState()
        state.update(titles: ["❯ ~/dev"], isWorking: false, isWatched: true)
        #expect(state.kind == .terminal)
        #expect(state.autoTitle == nil)
    }

    @Test func backgroundSplitAgentTitleKeepsIdentity() {
        // The focused split's plain title must not wipe an idle agent
        // living in another split (identity is judged from every title).
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: false, isWatched: true)
        state.update(titles: ["zsh", "✳ Waiting on your input"], isWorking: false, isWatched: true)
        #expect(state.kind == .claude)
    }

    @Test func workingPlainTitleKeepsIdentity() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: false, isWatched: true)
        state.update(titles: ["zsh"], isWorking: true, isWatched: true)
        #expect(state.kind == .claude)
    }

    // MARK: - Auto-naming

    @Test func markerCapturesFirstPromptOnly() {
        let state = PhanttomTabState()
        state.update(titles: ["\(marker) first prompt"], isWorking: false, isWatched: true)
        #expect(state.autoTitle == "first prompt")

        state.update(titles: ["\(marker) second prompt"], isWorking: false, isWatched: true)
        #expect(state.autoTitle == "first prompt")
    }

    @Test func markerInBackgroundSplitCapturesName() {
        let state = PhanttomTabState()
        state.update(titles: ["zsh", "\(marker) refactor the cache"], isWorking: false, isWatched: true)
        #expect(state.kind == .claude)
        #expect(state.autoTitle == "refactor the cache")
    }

    @Test func rearmConsumesCurrentMarkerTitle() {
        let state = PhanttomTabState()
        state.update(titles: ["\(marker) fix login bug"], isWorking: false, isWatched: true)
        state.rearmAutoTitle()
        #expect(state.autoTitle == nil)

        // The still-current marker title must not be re-captured...
        state.update(titles: ["\(marker) fix login bug"], isWorking: false, isWatched: true)
        #expect(state.autoTitle == nil)

        // ...but a NEW prompt names the tab again.
        state.update(titles: ["\(marker) add dark mode"], isWorking: false, isWatched: true)
        #expect(state.autoTitle == "add dark mode")
    }

    // MARK: - Model reporting

    @Test func markerModelSuffixSetsModelAndStaysSticky() {
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker) fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isWatched: true)
        #expect(state.autoTitle == "fix login bug")
        // State stores the raw id; pretty-printing is a TabItem/view concern.
        #expect(state.model == "claude-fable-5")
        #expect(state.titleFallback == "fix login bug")

        // An empty model field (first turn of a fresh session, transcript
        // not yet written) keeps the last known model.
        state.update(
            titles: ["\(marker) another prompt\u{2063}"],
            isWorking: false, isWatched: true)
        #expect(state.model == "claude-fable-5")

        // A model switch mid-session (e.g. /model) updates the id even
        // though the auto-name stays locked to the first prompt.
        state.update(
            titles: ["\(marker) another prompt\u{2063}claude-opus-4-8"],
            isWorking: false, isWatched: true)
        #expect(state.autoTitle == "fix login bug")
        #expect(state.model == "claude-opus-4-8")
    }

    @Test func modelOnlyMarkerSetsModelWithoutNamingTab() {
        // Legacy statusline sideband: "❯" + U+2063 + U+2063 + model.
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker)\u{2063}claude-fable-5"],
            isWorking: false, isWatched: true)
        #expect(state.kind == .claude)
        #expect(state.model == "claude-fable-5")
        #expect(state.autoTitle == nil)
        #expect(state.titleFallback == "Claude")

        // The first real prompt still names the tab afterwards.
        state.update(
            titles: ["\(marker) fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isWatched: true)
        #expect(state.autoTitle == "fix login bug")
        #expect(state.titleFallback == "fix login bug")
    }

    @Test func kindTokenMarkerSetsCursorKindAndModel() {
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker).cursor\u{2063}\u{2063}grok-4.5"],
            isWorking: false, isWatched: true)
        #expect(state.kind == .cursor)
        #expect(state.model == "grok-4.5")
        #expect(state.autoTitle == nil)
        #expect(state.titleFallback == "Cursor")

        state.update(
            titles: ["\(marker).cursor\u{2063}fix the sidebar\u{2063}grok-4.5"],
            isWorking: false, isWatched: true)
        #expect(state.kind == .cursor)
        #expect(state.autoTitle == "fix the sidebar")
        #expect(state.titleFallback == "fix the sidebar")
    }

    @Test func kindTokenMarkerSetsClaudeKind() {
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker).claude\u{2063}fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isWatched: true)
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
            isWorking: false, isWatched: true)
        #expect(state.kind == .claude)
        #expect(state.autoTitle == "cursor")
        #expect(state.model == "claude-fable-5")
    }

    @Test func cursorMarkerForcesKindBackFromCodex() {
        let state = PhanttomTabState()
        state.update(titles: ["codex exec"], isWorking: false, isWatched: true)
        #expect(state.kind == .codex)

        state.update(
            titles: ["\(marker).cursor\u{2063}\u{2063}grok-4.5"],
            isWorking: false, isWatched: true)
        #expect(state.kind == .cursor)
        #expect(state.model == "grok-4.5")
    }

    @Test func markerWithoutModelSuffixLeavesModelNil() {
        let state = PhanttomTabState()
        state.update(titles: ["\(marker) fix login bug"], isWorking: false, isWatched: true)
        #expect(state.model == nil)
    }

    @Test func shellReclaimClearsModel() {
        let state = PhanttomTabState()
        state.update(
            titles: ["\(marker) fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isWatched: true)
        state.update(titles: ["zsh"], isWorking: false, isWatched: true)
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
            isWorking: false, isWatched: true)
        #expect(state.kind == .claude)
        #expect(state.model == "claude-fable-5")

        state.update(titles: ["codex exec"], isWorking: false, isWatched: true)
        #expect(state.kind == .codex)
        #expect(state.model == nil)
        #expect(state.titleFallback == nil)
    }

    @Test func markerForcesKindBackFromCodex() {
        // Codex first, then a Claude marker (no plain "claude" title): the
        // marker path must flip kind to .claude so the model badge can show.
        let state = PhanttomTabState()
        state.update(titles: ["codex exec"], isWorking: false, isWatched: true)
        #expect(state.kind == .codex)

        state.update(
            titles: ["\(marker) fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isWatched: true)
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
            isWorking: false, isWatched: true)
        state.rearmAutoTitle()
        #expect(state.autoTitle == nil)

        state.update(
            titles: ["\(marker) fix login bug\u{2063}claude-fable-5"],
            isWorking: false, isWatched: true)
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
        // A bracketed context-window suffix survives, parenthesized.
        #expect(PhanttomTabState.modelDisplayName("claude-opus-5[1m]") == "Opus 5 (1M)")
        #expect(PhanttomTabState.modelDisplayName("claude-haiku-4-5-20251001[1m]") == "Haiku 4.5 (1M)")
        // No recognizable family word: show the id rather than hiding — and
        // that exit keeps the qualifier too.
        #expect(PhanttomTabState.modelDisplayName("claude") == "claude")
        #expect(PhanttomTabState.modelDisplayName("claude[1m]") == "claude (1M)")
        // The peel is trailing: an earlier "[" is not the start of the
        // qualifier (from the first "[", everything after it would be
        // swallowed into one). An empty qualifier adds nothing.
        #expect(PhanttomTabState.modelDisplayName("claude-[x]-opus-5[1m]") == "Opus 5 (1M)")
        #expect(PhanttomTabState.modelDisplayName("claude-opus-5[]") == "Opus 5")
    }

    // MARK: - Status transitions

    @Test func workingEndsUnselectedBecomesDone() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: true, isWatched: false)
        #expect(state.status == .working)

        state.update(titles: ["claude"], isWorking: false, isWatched: false)
        #expect(state.status == .done)

        // Selection acknowledges.
        state.update(titles: ["claude"], isWorking: false, isWatched: true)
        #expect(state.status == .idle)
    }

    @Test func workingEndsSelectedIsIdle() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: true, isWatched: true)
        #expect(state.status == .working)

        state.update(titles: ["claude"], isWorking: false, isWatched: true)
        #expect(state.status == .idle)
    }

    @Test func bellOutranksWorkingAndDone() {
        let state = PhanttomTabState()
        state.noteBell()
        #expect(state.status == .attention)

        // A bell after work finished replaces done: needing input outranks
        // having finished.
        let finished = PhanttomTabState()
        finished.update(titles: ["claude"], isWorking: true, isWatched: false)
        finished.update(titles: ["claude"], isWorking: false, isWatched: false)
        #expect(finished.status == .done)
        finished.noteBell()
        #expect(finished.status == .attention)

        // A bell rung against a live report is deferred, then honored by the
        // clear it raced — the hook emits both together, so the report is
        // gone by the next refresh.
        let blocked = PhanttomTabState()
        blocked.update(titles: ["claude"], isWorking: true, isWatched: false)
        #expect(blocked.status == .working)
        blocked.noteBell()
        blocked.update(titles: ["claude"], isWorking: false, isWatched: false)
        #expect(blocked.status == .attention)

        // And nothing later re-asserts over it while it stands unread.
        blocked.update(titles: ["claude"], isWorking: false, isWatched: false)
        #expect(blocked.status == .attention)
    }

    /// A BEL from the program itself — a test runner, a build tool, a
    /// readline beep inside a Bash tool — is not the agent asking for input.
    /// Only the bell that rides a progress-clear is the Notification hook,
    /// so a bell against a report that stays live must leave the sparkle
    /// alone and must not outlive the refresh that judged it.
    @Test func strayBellDuringWorkKeepsWorking() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: true, isWatched: false)
        #expect(state.status == .working)

        state.noteBell()
        state.update(titles: ["claude"], isWorking: true, isWatched: false)
        #expect(state.status == .working)
        state.update(titles: ["claude"], isWorking: true, isWatched: false)
        #expect(state.status == .working)

        // Taking the slot unconditionally stranded the tab on yellow here:
        // the rising edge cannot re-fire for a report that never went away,
        // and the falling edge yields to attention. The run must still
        // resolve to done.
        state.update(titles: ["claude"], isWorking: false, isWatched: false)
        #expect(state.status == .done)
    }

    /// The deferred bell is an edge like any other: the first manager to
    /// step the state consumes it, and the rest agree on the result.
    @Test func deferredBellIsConsumedOnceAcrossManagers() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: true, isWatched: false)
        state.noteBell()

        state.update(titles: ["claude"], isWorking: false, isWatched: false)
        #expect(state.status == .attention)
        state.update(titles: ["claude"], isWorking: false, isWatched: false)
        #expect(state.status == .attention)
    }

    /// The real Claude Code notification-hook sequence: the hook clears the
    /// progress report and rings the BEL in the same breath, so the sidebar
    /// sees a progress-clear refresh and a bell in an order it does not
    /// control. Both orderings must land on attention — this is the
    /// regression that made a blocked agent render blue "done".
    @Test func notificationHookLandsOnAttentionEitherOrder() {
        // Ordering A: the progress-clear refresh is processed first.
        let clearFirst = PhanttomTabState()
        clearFirst.update(titles: ["claude"], isWorking: true, isWatched: false)
        clearFirst.update(titles: ["claude"], isWorking: false, isWatched: false)
        clearFirst.noteBell()
        #expect(clearFirst.status == .attention)
        // A later refresh with no new work leaves it standing.
        clearFirst.update(titles: ["claude"], isWorking: false, isWatched: false)
        #expect(clearFirst.status == .attention)

        // Ordering B: the bell is delivered first, while progress is live.
        let bellFirst = PhanttomTabState()
        bellFirst.update(titles: ["claude"], isWorking: true, isWatched: false)
        bellFirst.noteBell()
        bellFirst.update(titles: ["claude"], isWorking: false, isWatched: false)
        #expect(bellFirst.status == .attention)
    }

    /// Watching a tab whose agent is still running must not strand it on the
    /// idle dot: acknowledgement clears the indicator, never the fact that
    /// the process is working.
    @Test func selectingWorkingTabWithAttentionKeepsWorking() {
        let state = PhanttomTabState()
        state.noteBell()
        #expect(state.status == .attention)

        // Work starts again while the bell is still unread.
        state.update(titles: ["claude"], isWorking: true, isWatched: false)
        #expect(state.status == .working)

        // User watches it while the progress report is still live.
        state.update(titles: ["claude"], isWorking: true, isWatched: true)
        #expect(state.status == .working)
        state.update(titles: ["claude"], isWorking: true, isWatched: true)
        #expect(state.status == .working)

        // And it still resolves to idle when the work actually ends.
        state.update(titles: ["claude"], isWorking: false, isWatched: true)
        #expect(state.status == .idle)
    }

    /// New work after an unacknowledged bell takes the slot back: a rising
    /// edge means the agent genuinely started something, not that a stale
    /// report is lingering.
    @Test func newWorkAfterBellResumesWorking() {
        let state = PhanttomTabState()
        state.noteBell()
        #expect(state.status == .attention)
        state.update(titles: ["claude"], isWorking: true, isWatched: false)
        #expect(state.status == .working)
    }

    /// Several sidebars step the same window state each refresh; only the
    /// first call may consume a transition.
    @Test func repeatedUpdatesAreIdempotent() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: true, isWatched: false)
        state.update(titles: ["claude"], isWorking: true, isWatched: false)
        #expect(state.status == .working)

        state.update(titles: ["claude"], isWorking: false, isWatched: false)
        #expect(state.status == .done)
        // A second manager's pass over the same inputs must not re-run the
        // falling edge or otherwise disturb the recorded result.
        state.update(titles: ["claude"], isWorking: false, isWatched: false)
        #expect(state.status == .done)
    }

    @Test func watchingClearsAttention() {
        let state = PhanttomTabState()
        state.noteBell()
        #expect(state.status == .attention)
        state.update(titles: ["zsh"], isWorking: false, isWatched: true)
        #expect(state.status == .idle)
    }

    // MARK: - Two agents in one tab
    //
    // Status used to collapse the whole window to one bool — an OR across
    // every split's progress report — so both the rising edge that clears an
    // unread bell and the deferral that judges a bell were answered by
    // whatever ANY split happened to be doing. With two agents in one tab
    // that is the wrong question twice over, and both ways it failed hid a
    // blocked agent, which is the one thing the sidebar exists to show.

    /// Titles for a two-split tab; identity is judged from all of them, and
    /// none of these cases is about identity.
    private let twoAgents = ["claude", "claude"]

    /// Snapshot helper: `[a: true, b: false]` reads like the tab looks.
    private func splits(
        _ a: PhanttomTabState.SurfaceID, _ aWorking: Bool,
        _ b: PhanttomTabState.SurfaceID, _ bWorking: Bool
    ) -> [PhanttomTabState.SurfaceProgress] {
        [.init(id: a, isWorking: aWorking), .init(id: b, isWorking: bWorking)]
    }

    /// The headline case. Split A's agent blocks for input and takes the
    /// yellow dot; split B then starts work (a subagent spawning, or a Stop
    /// with background tasks still in flight, both of which re-arm OSC 9;4).
    /// The window-level rising edge used to read that as "the tab resumed"
    /// and clear A's unread dot, leaving a blocked agent showing the sparkle.
    /// Only A resuming may take the slot back.
    @Test func secondAgentStartingKeepsFirstAgentsAttention() {
        let a = PhanttomTabState.SurfaceID()
        let b = PhanttomTabState.SurfaceID()
        let state = PhanttomTabState()

        state.update(titles: twoAgents, surfaces: splits(a, true, b, false), isWatched: false)
        #expect(state.status == .working)

        // A's notification hook: BEL against its own live report, then the
        // clear it raced.
        state.noteBell(surface: a)
        state.update(titles: twoAgents, surfaces: splits(a, false, b, false), isWatched: false)
        #expect(state.status == .attention)

        // B starts. A is still waiting on the user.
        state.update(titles: twoAgents, surfaces: splits(a, false, b, true), isWatched: false)
        #expect(state.status == .attention)
        state.update(titles: twoAgents, surfaces: splits(a, false, b, true), isWatched: false)
        #expect(state.status == .attention)

        // A itself resuming is the agent unblocking, and does take the slot.
        state.update(titles: twoAgents, surfaces: splits(a, true, b, true), isWatched: false)
        #expect(state.status == .working)
    }

    /// The same pair in the other order: B is already working when A blocks.
    /// A's bell arrives against a quiet split of its own, so there is no race
    /// to settle and the dot is taken immediately — B's report is not
    /// evidence about A.
    @Test func bellInAQuietSplitIsTakenWhileAnotherSplitWorks() {
        let a = PhanttomTabState.SurfaceID()
        let b = PhanttomTabState.SurfaceID()
        let state = PhanttomTabState()

        state.update(titles: twoAgents, surfaces: splits(a, true, b, true), isWatched: false)
        #expect(state.status == .working)

        // A's progress-clear is processed first, then its bell.
        state.update(titles: twoAgents, surfaces: splits(a, false, b, true), isWatched: false)
        #expect(state.status == .working, "B is still running, so the tab is not done")
        state.noteBell(surface: a)
        #expect(state.status == .attention)

        // And it stands while B keeps working.
        state.update(titles: twoAgents, surfaces: splits(a, false, b, true), isWatched: false)
        #expect(state.status == .attention)
    }

    /// Bell first, while A's own report is still live — the deferred path.
    /// The deferral used to be answered by the window: it found B's report
    /// still live, called A's bell incidental, and dropped it. A blocked
    /// agent got no dot at all. The next refresh must judge A's bell against
    /// A's report only.
    @Test func deferredBellIsJudgedByItsOwnSplitNotTheWindow() {
        let a = PhanttomTabState.SurfaceID()
        let b = PhanttomTabState.SurfaceID()
        let state = PhanttomTabState()

        state.update(titles: twoAgents, surfaces: splits(a, true, b, true), isWatched: false)
        state.noteBell(surface: a)

        state.update(titles: twoAgents, surfaces: splits(a, false, b, true), isWatched: false)
        #expect(state.status == .attention)
        // Idempotent across the several managers stepping this state.
        state.update(titles: twoAgents, surfaces: splits(a, false, b, true), isWatched: false)
        #expect(state.status == .attention)
    }

    /// The stray-BEL rule is unchanged, only narrowed: a bell whose own split
    /// keeps working is still incidental, even with a busy neighbor, and must
    /// not outlive the refresh that judged it.
    @Test func strayBellInAStillWorkingSplitIsStillIgnored() {
        let a = PhanttomTabState.SurfaceID()
        let b = PhanttomTabState.SurfaceID()
        let state = PhanttomTabState()

        state.update(titles: twoAgents, surfaces: splits(a, true, b, true), isWatched: false)
        state.noteBell(surface: a)
        state.update(titles: twoAgents, surfaces: splits(a, true, b, true), isWatched: false)
        #expect(state.status == .working)

        state.update(titles: twoAgents, surfaces: splits(a, false, b, false), isWatched: false)
        #expect(state.status == .done, "the discarded bell must not resurface as attention")
    }

    /// One split going quiet is not the tab finishing: `.done` is the last
    /// report in the window ending, not the first.
    @Test func oneSplitFinishingWhileAnotherWorksIsNotDone() {
        let a = PhanttomTabState.SurfaceID()
        let b = PhanttomTabState.SurfaceID()
        let state = PhanttomTabState()

        state.update(titles: twoAgents, surfaces: splits(a, true, b, true), isWatched: false)
        state.update(titles: twoAgents, surfaces: splits(a, true, b, false), isWatched: false)
        #expect(state.status == .working)

        state.update(titles: twoAgents, surfaces: splits(a, false, b, false), isWatched: false)
        #expect(state.status == .done)
    }

    /// Two blocked agents own the one yellow dot jointly: it survives until
    /// both are answered, so the first one resuming cannot speak for the
    /// second.
    @Test func twoBlockedSplitsBothHoldTheAttention() {
        let a = PhanttomTabState.SurfaceID()
        let b = PhanttomTabState.SurfaceID()
        let state = PhanttomTabState()

        state.update(titles: twoAgents, surfaces: splits(a, false, b, false), isWatched: false)
        state.noteBell(surface: a)
        state.noteBell(surface: b)
        #expect(state.status == .attention)

        state.update(titles: twoAgents, surfaces: splits(a, true, b, false), isWatched: false)
        #expect(state.status == .attention, "B is still blocked")

        state.update(titles: twoAgents, surfaces: splits(a, true, b, true), isWatched: false)
        #expect(state.status == .working)
    }

    /// Watching the tab acknowledges every split's dot at once — but hands
    /// the slot back to the sparkle when another split is still running,
    /// rather than stranding a working tab on the gray idle dot.
    @Test func watchingClearsAttentionButKeepsAnotherSplitWorking() {
        let a = PhanttomTabState.SurfaceID()
        let b = PhanttomTabState.SurfaceID()
        let state = PhanttomTabState()

        state.update(titles: twoAgents, surfaces: splits(a, false, b, true), isWatched: false)
        state.noteBell(surface: a)
        #expect(state.status == .attention)

        state.update(titles: twoAgents, surfaces: splits(a, false, b, true), isWatched: true)
        #expect(state.status == .working)

        // Acknowledged for good: going away again does not bring it back.
        state.update(titles: twoAgents, surfaces: splits(a, false, b, true), isWatched: false)
        #expect(state.status == .working)
    }

    /// Every per-surface record is keyed on a split that must still exist.
    /// Closing the blocked split takes its dot with it (there is nothing left
    /// to attend to) — and, more importantly, leaves nothing behind: the
    /// bookkeeping is pruned from the live list on every pass, so it cannot
    /// grow for the life of the window.
    @Test func closingTheBlockedSplitDropsItsAttention() {
        let a = PhanttomTabState.SurfaceID()
        let b = PhanttomTabState.SurfaceID()
        let state = PhanttomTabState()

        state.update(titles: twoAgents, surfaces: splits(a, false, b, false), isWatched: false)
        state.noteBell(surface: a)
        #expect(state.status == .attention)

        // A closes; only B is left.
        state.update(titles: ["claude"], surfaces: [.init(id: b, isWorking: false)],
                     isWatched: false)
        #expect(state.status == .idle)
    }

    /// A window mid-teardown (or a non-terminal window falling back to its
    /// own title) reports no splits at all. That is not "every split closed"
    /// and must not quietly eat an unread dot.
    @Test func anEmptySurfaceListDoesNotEatAnUnreadDot() {
        let a = PhanttomTabState.SurfaceID()
        let state = PhanttomTabState()

        state.update(titles: ["claude"], surfaces: [.init(id: a, isWorking: false)],
                     isWatched: false)
        state.noteBell(surface: a)
        #expect(state.status == .attention)

        state.update(titles: ["claude"], surfaces: [], isWatched: false)
        #expect(state.status == .attention)
    }

    // MARK: - Watched vs merely selected
    //
    // `isWatched` is stricter than tab selection: frontmost in its group AND
    // key window AND app active. These cases are the ones where the two
    // disagree — the tab you left selected when you switched to another app.
    // Judging by selection alone reported them as seen, which is how a
    // blocked agent ended up showing the gray idle dot.

    /// Work finishing in the tab you left selected, while you are off in
    /// another app, owes you the blue dot exactly like a background tab.
    @Test func workEndingWhileAwayIsDoneEvenOnTheSelectedTab() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: true, isWatched: false)
        #expect(state.status == .working)

        state.update(titles: ["claude"], isWorking: false, isWatched: false)
        #expect(state.status == .done)

        // Coming back to the app acknowledges it.
        state.update(titles: ["claude"], isWorking: false, isWatched: true)
        #expect(state.status == .idle)
    }

    /// The headline case: the agent blocks for input in the tab you left
    /// selected. This used to be dropped outright and rendered gray.
    @Test func bellOnSelectedButUnwatchedTabMarksAttention() {
        let state = PhanttomTabState()
        state.update(titles: ["claude"], isWorking: true, isWatched: false)
        // Notification hook: clear progress, then ring.
        state.update(titles: ["claude"], isWorking: false, isWatched: false)
        state.noteBell()
        #expect(state.status == .attention)

        // It must survive refreshes for as long as the user stays away —
        // app-activation changes are what re-run this, so a stale pass must
        // not quietly clear it.
        state.update(titles: ["claude"], isWorking: false, isWatched: false)
        #expect(state.status == .attention)

        // Returning to Ghostty acknowledges it.
        state.update(titles: ["claude"], isWorking: false, isWatched: true)
        #expect(state.status == .idle)
    }
}
