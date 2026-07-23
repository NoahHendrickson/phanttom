import AppKit

/// The Phanttom fork's per-tab identity and activity state.
///
/// One value of this lives on each `TerminalWindow`
/// (`phanttomTabState`): every window in a tab group has its own
/// `SidebarTabManager`, so state shared between sidebars must live on the
/// window, never in a manager, and it dies with the window (see PHANTTOM.md).
/// Keeping it as one model rather than loose window properties keeps the
/// invariants — which title beats which, when status transitions fire — in
/// one place, mutated only through the methods below.
///
/// Main thread only, like the window that owns it.
final class PhanttomTabState {
    /// What is running in the tab, detected from the surface title. Drives
    /// which row style and icon the sidebar shows.
    enum Kind: Equatable {
        case terminal
        case claude
        case codex
    }

    /// Activity state shown on the trailing edge of the tab row. An explicit
    /// state machine: `update` and `noteBell` are the only transitions, and
    /// selecting a tab always acknowledges back to `.idle`.
    enum Status: Equatable {
        /// Nothing to report.
        case idle
        /// The tab's program reported progress (OSC 9;4) — animated sparkle.
        case working
        /// Work finished while the tab was unselected — blue square.
        case done
        /// Bell rang while the tab was unselected — yellow square.
        case attention
    }

    private(set) var status: Status = .idle

    /// An automatic tab name derived from the user's first agent prompt of
    /// the session (set via a marker title emitted by the Claude Code
    /// UserPromptSubmit hook). Beaten by the user's rename (upstream's
    /// `titleOverride`); cleared when the shell reclaims the title.
    private(set) var autoTitle: String?

    /// The last detected agent kind, kept sticky while decorated/marked
    /// titles come through so hook-set titles don't flip the row back to a
    /// plain terminal. Nil = plain terminal.
    private var agentKind: Kind?

    /// The exact title consumed by Reset Name, so the next refresh doesn't
    /// immediately re-capture it as the auto-name.
    private var lastResetTitle: String?

    var kind: Kind { agentKind ?? .terminal }

    /// The Claude Code hook marks auto-name titles with "❯" followed by
    /// U+2063 (INVISIBLE SEPARATOR) — collision-proof against shells whose
    /// title templates lead with a bare "❯" prompt char (starship, pure...).
    static let autoNameMarker = "❯\u{2063}"

    /// Step the state for one sidebar refresh pass: status transitions from
    /// the window's progress reports and selection, identity (kind and
    /// auto-name) from the current title.
    func update(title: String, isWorking: Bool, isSelected: Bool) {
        updateStatus(isWorking: isWorking, isSelected: isSelected)
        updateIdentity(title: title, isWorking: isWorking)
    }

    /// Bell rang while the tab was unselected. Only marks attention when
    /// there is nothing more urgent to show: working and done both outrank
    /// attention, and every indicator clears on selection anyway.
    func noteBell() {
        guard status == .idle else { return }
        status = .attention
    }

    /// Re-arm first-prompt auto-naming (rename cleared / Reset Name).
    /// Remembers the consumed title so a still-current marker title isn't
    /// immediately re-captured on the next refresh.
    func rearmAutoTitle(consuming title: String) {
        autoTitle = nil
        lastResetTitle = title
    }

    private func updateStatus(isWorking: Bool, isSelected: Bool) {
        if isWorking {
            status = .working
        } else if status == .working {
            // Progress just ended: done if it finished in the background,
            // nothing to report if the user was watching.
            status = isSelected ? .idle : .done
        }
        // Selecting a tab acknowledges any indicator.
        if isSelected, status == .done || status == .attention {
            status = .idle
        }
    }

    private func updateIdentity(title: String, isWorking: Bool) {
        // Our hook's marker: store the prompt-derived auto name — but only
        // the session's FIRST prompt names the tab. It re-arms when the
        // shell reclaims the title (session over) or via Reset Name.
        if title.hasPrefix(Self.autoNameMarker) {
            let auto = title.dropFirst(Self.autoNameMarker.count)
                .trimmingCharacters(in: .whitespaces)
            if !auto.isEmpty, autoTitle == nil, title != lastResetTitle {
                autoTitle = auto
            }
            // Only our Claude hook emits the marker; make the kind sticky.
            if agentKind == nil { agentKind = .claude }
            return
        }

        let t = title.lowercased()
        if t.contains("claude") {
            agentKind = .claude
            return
        }
        if t.contains("codex") {
            agentKind = .codex
            return
        }

        // Decorated titles (leading symbol glyph, e.g. Claude Code's "✳ …")
        // keep the previous agent kind — and so does a plain title while
        // work is in progress: the window title only mirrors the FOCUSED
        // split, so an agent running in another split must not reset the
        // identity mid-session.
        if agentKind != nil {
            if let first = title.unicodeScalars.first,
               !CharacterSet.alphanumerics.contains(first) {
                return
            }
            if isWorking { return }
        }

        // A plain title while idle: the shell reclaimed the tab, so the
        // agent session and its auto-name are over.
        agentKind = nil
        autoTitle = nil
        lastResetTitle = nil
    }
}
