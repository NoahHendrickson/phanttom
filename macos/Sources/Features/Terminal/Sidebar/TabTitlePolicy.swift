import Foundation

/// Agent/tab kind detected from the surface title. Sticky across decorated
/// titles so hook-set names don't flip the row back to a plain terminal.
enum PhanttomTabKind: Equatable {
    case terminal
    case claude
    case codex
}

/// Pure title/kind/auto-name state for one tab. Stored on `TerminalWindow`
/// (`phanttomAgentKind` / `phanttomAutoTitle`); this type is the testable
/// record the policy reads and writes. `kind` is non-optional — `.terminal`
/// is the cleared state (one representation end-to-end).
struct TabTitleState: Equatable {
    var kind: PhanttomTabKind
    var autoTitle: String?

    static let empty = TabTitleState(kind: .terminal, autoTitle: nil)
}

/// Title → kind / auto-name policy. No AppKit, no side effects — apply the
/// result to the window (or a test fixture) at the call site.
enum TabTitlePolicy {
    /// Interpret a title update: detect the agent kind (sticky across
    /// decorated titles), and capture "❯ "-marked titles from the Claude
    /// Code UserPromptSubmit hook as the tab's auto-name. A plain title
    /// (shell integration reclaiming it) resets both.
    ///
    /// Auto-name locks to the session's FIRST prompt; it re-arms when the
    /// shell reclaims the title (session over) or when the caller clears
    /// `autoTitle` (Reset Name).
    static func apply(title: String, to state: TabTitleState) -> TabTitleState {
        var next = state

        if title.hasPrefix("❯") {
            let auto = title.dropFirst().trimmingCharacters(in: .whitespaces)
            if !auto.isEmpty, next.autoTitle == nil {
                next.autoTitle = auto
            }
            // Marked titles imply an agent session; default sticky kind to Claude
            // when we haven't seen an explicit "claude"/"codex" title yet.
            if next.kind == .terminal { next.kind = .claude }
            return next
        }

        let lower = title.lowercased()
        if lower.contains("claude") {
            next.kind = .claude
            return next
        }
        if lower.contains("codex") {
            next.kind = .codex
            return next
        }

        // Decorated titles (leading symbol glyph, e.g. Claude Code's "✳ …")
        // keep the previous agent kind; a plain title means the shell took
        // the tab back, so the agent session and its auto-name are over.
        if let first = title.unicodeScalars.first,
           !CharacterSet.alphanumerics.contains(first),
           next.kind != .terminal {
            return next
        }

        return .empty
    }

    /// What the sidebar shows: custom name, else prompt-derived auto name,
    /// else the surface title with leading decoration glyphs stripped.
    static func displayTitle(
        title: String,
        customTitle: String?,
        autoTitle: String?,
        kind: PhanttomTabKind
    ) -> String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let autoTitle, !autoTitle.isEmpty { return autoTitle }
        guard kind != .terminal else { return title }
        return stripLeadingDecoration(title)
    }

    /// Strip leading non-alphanumeric glyphs (agents like Claude Code prefix
    /// their own "✳", which would double the sidebar icon).
    static func stripLeadingDecoration(_ title: String) -> String {
        var s = Substring(title)
        while let first = s.unicodeScalars.first,
              !CharacterSet.alphanumerics.contains(first) {
            s = s.dropFirst()
        }
        let cleaned = s.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : String(cleaned)
    }
}
