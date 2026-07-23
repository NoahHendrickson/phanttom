import Testing
@testable import Ghostty

struct TabTitlePolicyTests {
    @Test func plainTitleIsTerminalAndClearsState() {
        let before = TabTitleState(kind: .claude, autoTitle: "old prompt")
        let after = TabTitlePolicy.apply(title: "zsh", to: before)
        #expect(after == .empty)
    }

    @Test func claudeInTitleSetsKind() {
        let after = TabTitlePolicy.apply(title: "claude", to: .empty)
        #expect(after.kind == .claude)
        #expect(after.autoTitle == nil)
    }

    @Test func codexInTitleSetsKind() {
        let after = TabTitlePolicy.apply(title: "codex", to: .empty)
        #expect(after.kind == .codex)
    }

    @Test func decoratedTitleKeepsStickyKind() {
        let before = TabTitleState(kind: .claude, autoTitle: "rename tabs")
        let after = TabTitlePolicy.apply(title: "✳ rename tabs", to: before)
        #expect(after.kind == .claude)
        #expect(after.autoTitle == "rename tabs")
    }

    @Test func markedTitleCapturesFirstPromptOnly() {
        let first = TabTitlePolicy.apply(title: "❯ first prompt", to: .empty)
        #expect(first.kind == .claude)
        #expect(first.autoTitle == "first prompt")

        let second = TabTitlePolicy.apply(title: "❯ second prompt", to: first)
        #expect(second.autoTitle == "first prompt")
    }

    @Test func markedTitleDefaultsKindToClaudeWhenUnknown() {
        let after = TabTitlePolicy.apply(title: "❯ do the thing", to: .empty)
        #expect(after.kind == .claude)
    }

    @Test func markedTitlePreservesExistingCodexKind() {
        let before = TabTitleState(kind: .codex, autoTitle: nil)
        let after = TabTitlePolicy.apply(title: "❯ do the thing", to: before)
        #expect(after.kind == .codex)
        #expect(after.autoTitle == "do the thing")
    }

    @Test func displayTitlePrefersCustomThenAutoThenStripped() {
        #expect(
            TabTitlePolicy.displayTitle(
                title: "✳ raw",
                customTitle: "Custom",
                autoTitle: "Auto",
                kind: .claude
            ) == "Custom"
        )
        #expect(
            TabTitlePolicy.displayTitle(
                title: "✳ raw",
                customTitle: nil,
                autoTitle: "Auto",
                kind: .claude
            ) == "Auto"
        )
        #expect(
            TabTitlePolicy.displayTitle(
                title: "✳ raw title",
                customTitle: nil,
                autoTitle: nil,
                kind: .claude
            ) == "raw title"
        )
        #expect(
            TabTitlePolicy.displayTitle(
                title: "~/src",
                customTitle: nil,
                autoTitle: nil,
                kind: .terminal
            ) == "~/src"
        )
    }

    @Test func stripLeadingDecoration() {
        #expect(TabTitlePolicy.stripLeadingDecoration("✳ hello") == "hello")
        #expect(TabTitlePolicy.stripLeadingDecoration("hello") == "hello")
    }
}
