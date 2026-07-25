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
        case cursor

        /// Sidebar label when a model-only marker has no prompt yet.
        var label: String {
            switch self {
            case .terminal: return "Terminal"
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .cursor: return "Cursor"
            }
        }
    }

    /// Parse a leading marker field as a kind token. Bare names are not
    /// accepted — they collide with legacy prompt text.
    static func kind(fromMarkerToken token: String) -> Kind? {
        switch token {
        case ".claude": return .claude
        case ".codex": return .codex
        case ".cursor": return .cursor
        default: return nil
        }
    }

    /// Activity state shown in the leading status slot of the tab row. An
    /// explicit state machine: `update` and `noteBell` are the only
    /// transitions.
    ///
    /// Precedence, most urgent first — the ordering the sidebar promises the
    /// user, and the reason `updateStatus` works on edges:
    ///
    ///   attention > working > done > idle
    ///
    /// Attention wins because it is the only state that is *about the user*:
    /// the agent has stopped and cannot continue without them. Working and
    /// done are both merely reports on the agent. Watching a tab
    /// (`isWatched`, not mere selection) acknowledges attention and done; it
    /// cannot acknowledge working, which is a fact about the process rather
    /// than an unread notice, so a watched tab with live progress stays on
    /// `.working`.
    enum Status: Equatable {
        /// Nothing to report — gray dot (or the branch's PR icon).
        case idle
        /// The tab's program reported progress (OSC 9;4) — animated sparkle.
        case working
        /// Work finished while the user wasn't watching — blue status dot.
        case done
        /// The agent needs the user: bell rang while the user wasn't
        /// watching — yellow status dot.
        case attention
    }

    private(set) var status: Status = .idle

    /// The previous refresh's `isWorking`, so status transitions are judged
    /// on edges rather than levels (see `updateStatus`). Idempotent across
    /// the several `SidebarTabManager`s that each step this same window
    /// state: the first call consumes the edge, the rest see none and agree.
    private var wasWorking = false

    /// A bell that arrived while a progress report was still live, waiting on
    /// the next refresh to say what it meant (see `noteBell`). Consumed
    /// there, and consumed by the first stepper like every other edge, so
    /// the several managers stepping this state agree.
    private var pendingBell = false

    /// The working directory this tab was created into (sidebar group "+",
    /// Sessions header + / folder picker). Only a pwd fallback: the sidebar
    /// uses it until the shell integration reports a real pwd, so a
    /// brand-new tab lands in its project group immediately instead of
    /// flashing through the pending bucket. Cleared on the first real pwd.
    var seedDirectory: String?

    /// True from sidebar-driven creation until this window's own sidebar
    /// has published a list containing rows other than its own — i.e.
    /// while it is still "catching up" to the existing tab group. Breaks
    /// the catch-up vs new-arrival ambiguity in `SidebarTabManager` when a
    /// group "+" inserts the new tab ABOVE existing rows. Deliberately a
    /// separate lifetime from `seedDirectory`, which dies as soon as a
    /// real pwd exists.
    var pendingSidebarCatchUp = false

    /// When this state (and thus its window — the state is a stored `let`
    /// on `TerminalWindow`) was created. The sidebar treats only freshly
    /// created windows as catch-up candidates; an established window must
    /// never stage its own row away no matter where a new sibling lands.
    let createdAt = ContinuousClock.now

    /// The last git metadata (branch, project root, worktree flag) that
    /// finished a
    /// definitive resolve for this window. Sticky: while the cache has no
    /// answer for the current pwd — first resolve still in flight, or the
    /// entry was pruned — the sidebar keeps using this instead of
    /// regrouping the row through a wrong interim group (pwd-keyed, or
    /// none) and snapping it back a frame later. Updated only from
    /// resolved cache values, never cleared on unknown.
    var lastGitMetadata: GitBranchCache.Resolved?

    /// An automatic tab name derived from the user's first agent prompt of
    /// the session (set via a marker title emitted by the Claude Code
    /// UserPromptSubmit hook). Beaten by the user's rename (upstream's
    /// `titleOverride`); cleared when the shell reclaims the title.
    private(set) var autoTitle: String?

    /// Raw model id the tab's agent session is using ("claude-fable-5"),
    /// from the model field the Claude Code hook appends to the marker
    /// title. Sticky like the agent kind — the marker only rides
    /// UserPromptSubmit, so between prompts the last value stands — and
    /// cleared when the shell reclaims the tab or the kind flips away
    /// from Claude. Pretty-print at the TabItem/view edge via
    /// `modelDisplayName`.
    private(set) var model: String?

    /// Sidebar title when neither custom nor auto-name applies: the current
    /// marker's prompt field, or the kind label for a model-only marker.
    /// Keeps marker-protocol knowledge inside this state machine so the
    /// view model never has to re-parse U+2063 fields.
    private(set) var titleFallback: String?

    /// The last detected agent kind, kept sticky while decorated/marked
    /// titles come through so hook-set titles don't flip the row back to a
    /// plain terminal. Nil = plain terminal.
    private var agentKind: Kind?

    /// The exact title consumed by Reset Name, so the next refresh doesn't
    /// immediately re-capture it as the auto-name.
    private var lastResetTitle: String?

    /// The marker title seen in the last update pass, if any — what
    /// `rearmAutoTitle` must remember so a still-current marker title isn't
    /// immediately re-captured.
    private var lastMarkerTitle: String?

    var kind: Kind { agentKind ?? .terminal }

    /// The Claude Code hook marks auto-name titles with "❯" followed by
    /// U+2063 (INVISIBLE SEPARATOR) — collision-proof against shells whose
    /// title templates lead with a bare "❯" prompt char (starship, pure...).
    static let autoNameMarker = "❯\u{2063}"

    /// Step the state for one sidebar refresh pass: status transitions from
    /// the window's progress reports and whether the user is watching,
    /// identity (kind and auto-name) from the current titles.
    ///
    /// `titles` is every surface title in the window, not just the focused
    /// one: the window title only mirrors the FOCUSED split, so judging
    /// identity from it alone wipes an idle agent in a background split the
    /// moment a plain shell split takes focus.
    ///
    /// `isWatched` is the user's eyes being on this tab — frontmost in its
    /// group, key window, app active (`SidebarTabManager.isWatched`) — not
    /// merely tab selection. Only the strict form may acknowledge an
    /// indicator; see the note there.
    func update(titles: [String], isWorking: Bool, isWatched: Bool) {
        updateStatus(isWorking: isWorking, isWatched: isWatched)
        updateIdentity(titles: titles, isWorking: isWorking)
    }

    /// Bell rang while the user was not watching this tab (the caller checks
    /// that, via `SidebarTabManager.isWatched`).
    ///
    /// Attention outranks every other state. A bell is the agent explicitly
    /// asking for the user — Claude Code's Notification hook rings it for
    /// permission prompts and idle input waits — which is strictly more
    /// urgent than "still running" or "finished". Cleared when the user
    /// watches the tab, like every other indicator.
    ///
    /// A bell that lands while progress is still live is DEFERRED rather
    /// than taken, because at this instant the two cases that produce one
    /// are indistinguishable:
    ///
    ///   - the hook's own bell, racing the progress-clear printed next to
    ///     it — the report is about to go away and the agent is blocked;
    ///   - any other BEL the running program emits — a test runner, a build
    ///     tool, a readline beep — where the report stays live and there is
    ///     nothing to report.
    ///
    /// The next refresh separates them: a report that cleared means this was
    /// the hook, and attention is taken; a report still live means the bell
    /// was incidental, and the sparkle stands. Taking the slot
    /// unconditionally instead stranded any stray BEL as a permanent yellow
    /// dot on a *running* tab — the rising edge cannot re-fire for a report
    /// that never went away, and the falling edge yields to attention, so
    /// neither `.working` nor `.done` could be reached again.
    ///
    /// The deferral is one refresh wide, which is the width of the race it
    /// settles: the hook prints the clear and the BEL into the same write,
    /// so they are parsed a few microseconds apart while a refresh costs a
    /// runloop turn.
    func noteBell() {
        guard wasWorking else {
            status = .attention
            return
        }
        pendingBell = true
    }

    /// Re-arm first-prompt auto-naming (rename cleared / Reset Name).
    /// Consumes the currently visible marker title, if any, so it isn't
    /// immediately re-captured on the next refresh — only a NEW prompt
    /// names the tab again.
    func rearmAutoTitle() {
        autoTitle = nil
        lastResetTitle = lastMarkerTitle
    }

    private func updateStatus(isWorking: Bool, isWatched: Bool) {
        // This pass is the one that says what a deferred bell meant: it rode
        // the hook's progress-clear if the report is gone by now, and was
        // incidental if the report is still live. Either way it is answered
        // here and does not carry into a later refresh.
        let bellRodeTheClear = pendingBell
        pendingBell = false

        if isWorking, !wasWorking {
            // Rising edge only: a report that is merely still live may not
            // re-take the slot, and pairing with the falling edge below is
            // what makes both idempotent across the several managers that
            // step this state.
            //
            // Note this is the one transition that can drop an unread
            // `.attention`, and it is coarser than it looks: `isWorking` is
            // an OR across every surface in the window, so the edge says
            // *some* split started work, not that the split that rang the
            // bell resumed. With two agents in one tab, the second one
            // starting will clear the first one's yellow dot. Closing that
            // needs per-surface progress, which the window-level report
            // cannot express.
            status = .working
        } else if !isWorking, wasWorking, status != .attention {
            // Progress just ended: nothing to report if the user was actually
            // watching it happen, otherwise done. Judged on `isWatched`, not
            // tab order — work that finishes in the selected tab while you are
            // off in another app has not been seen, and owes you a blue dot
            // exactly like work that finishes in a background tab. A bell that
            // rode this very clear takes the slot instead — that is the hook
            // reporting a blocked agent, and needing input outranks merely
            // having finished.
            status = bellRodeTheClear ? .attention : (isWatched ? .idle : .done)
        }
        wasWorking = isWorking

        // Looking at a tab acknowledges its indicator — the indicator only,
        // never the fact that the process is working. Both `.done` and
        // `.attention` are only ever reached with the report already gone,
        // so a live one here would have taken the rising edge above and left
        // `.working`; the `isWorking` arm is belt-and-braces against a future
        // path that reaches this block with work in flight, which would
        // otherwise strand a running tab on the gray dot.
        if isWatched, status == .done || status == .attention {
            status = isWorking ? .working : .idle
        }
    }

    private func updateIdentity(titles: [String], isWorking: Bool) {
        // One pass over every split's title: any single agent-ish title
        // keeps the window's agent identity alive.
        var markerTitle: String?
        var namedKind: Kind?
        var anyDecorated = false
        for title in titles {
            if markerTitle == nil, title.hasPrefix(Self.autoNameMarker) {
                markerTitle = title
                continue
            }
            let t = title.lowercased()
            if t.contains("claude") {
                if namedKind == nil { namedKind = .claude }
            } else if t.contains("codex") {
                if namedKind == nil { namedKind = .codex }
            } else if t == "cursor" || t.hasPrefix("cursor ")
                        || t.hasPrefix("cursor-") {
                // Cursor Agent CLI titles ("Cursor Agent", "Cursor ready",
                // "cursor-agent"). Anchored at the start rather than a
                // substring match: "cursor" is an ordinary word in paths and
                // filenames, and every Cursor user has a `~/.cursor` — a plain
                // shell tab whose title is its cwd must not be branded as an
                // agent tab. Bare "agent" is too generic to match at all.
                if namedKind == nil { namedKind = .cursor }
            } else if let first = title.unicodeScalars.first,
                      !CharacterSet.alphanumerics.contains(first) {
                // Decorated title: a leading symbol glyph, e.g. Claude
                // Code's "✳ …" or a bare "❯ …" prompt char.
                anyDecorated = true
            }
        }
        lastMarkerTitle = markerTitle

        // Our hook's marker: store the prompt-derived auto name — but only
        // the session's FIRST prompt names the tab. It re-arms when the
        // shell reclaims the title (session over) or via Reset Name.
        if let markerTitle {
            // Marker payload (kind-aware):
            //   ❯⁣.claude⁣<prompt>⁣<model>   / ❯⁣.cursor⁣… / ❯⁣.codex⁣…
            //   ❯⁣.cursor⁣⁣<model>           (model-only; empty prompt)
            // Legacy Claude (no leading-dot kind field):
            //   ❯⁣<prompt>⁣<model>
            // Kind tokens are dot-prefixed so a legacy prompt that is
            // literally "cursor"/"claude"/"codex" cannot be misread as a
            // kind field.
            let fields = markerTitle.dropFirst(Self.autoNameMarker.count)
                .split(separator: "\u{2063}", omittingEmptySubsequences: false)
            let parsedKind: Kind
            let auto: String
            let modelField: String?
            if let token = fields.first.map({ $0.trimmingCharacters(in: .whitespaces) }),
               let kind = Self.kind(fromMarkerToken: token) {
                parsedKind = kind
                auto = fields.count > 1
                    ? fields[1].trimmingCharacters(in: .whitespaces) : ""
                modelField = fields.count > 2
                    ? fields[2].trimmingCharacters(in: .whitespaces) : nil
            } else {
                parsedKind = .claude
                auto = (fields.first ?? "").trimmingCharacters(in: .whitespaces)
                modelField = fields.count > 1
                    ? fields[1].trimmingCharacters(in: .whitespaces) : nil
            }
            if let id = modelField, !id.isEmpty { model = id }
            if !auto.isEmpty, autoTitle == nil, markerTitle != lastResetTitle {
                autoTitle = auto
            }
            // Presentation fallback for the sidebar when autoTitle is nil
            // (model-only marker, or post-rearm before a new prompt).
            titleFallback = auto.isEmpty ? parsedKind.label : auto
            // Force kind from the marker even when a prior agent left
            // agentKind sticky — otherwise the card keeps the old kind and
            // the model badge never shows for the new session.
            agentKind = parsedKind
            return
        }

        // Left the marker path — drop the marker-derived title fallback so
        // glyph-stripping of the live surface title takes over.
        titleFallback = nil

        if let namedKind {
            // A kind flip (Claude → Codex in the same tab) must not keep the
            // previous session's model badge.
            if namedKind != agentKind { model = nil }
            agentKind = namedKind
            return
        }

        // A decorated title keeps the previous agent kind — and so does an
        // active progress report: an agent session (idle between prompts or
        // mid-work) must not lose its identity just because no split
        // currently titles itself after the agent.
        if agentKind != nil, anyDecorated || isWorking { return }

        // Every split has a plain title and nothing is working: the shell
        // reclaimed the tab, so the agent session and its auto-name are over.
        agentKind = nil
        autoTitle = nil
        model = nil
        lastResetTitle = nil
    }

    /// "claude-fable-5" → "Fable 5", "claude-opus-4-8" → "Opus 4.8",
    /// "claude-haiku-4-5-20251001" → "Haiku 4.5": family word capitalized,
    /// short numeric tokens immediately before/after the family joined with
    /// dots, 8-digit date stamps and later qualifiers ("preview-2") dropped.
    /// Works for old ids with the family last ("claude-3-5-sonnet-…") too.
    /// A bracketed context-window suffix is kept, parenthesized and upper
    /// cased: "claude-opus-5[1m]" → "Opus 5 (1M)".
    /// An id with no recognizable family shows as-is rather than hiding.
    static func modelDisplayName(_ id: String) -> String {
        // Split the bracketed suffix off before tokenizing: it hangs off the
        // last token ("5[1m]"), which would otherwise fail the all-digits
        // test and swallow the version number with it. Matched from the LAST
        // "[" so the peel is genuinely trailing, as the docs above promise —
        // from the first, any earlier bracket would swallow everything after
        // it into the qualifier. An empty "[]" peels but adds no suffix.
        var suffix = ""
        var base = Substring(id)
        if base.hasSuffix("]"), let open = base.lastIndex(of: "[") {
            let inner = base[base.index(after: open)..<base.index(before: base.endIndex)]
            if !inner.isEmpty { suffix = " (\(inner.uppercased()))" }
            base = base[base.startIndex..<open]
        }
        // One composition point: every exit inside `baseDisplayName` returns
        // the bare name, so no return path can forget the qualifier.
        return baseDisplayName(base) + suffix
    }

    /// `modelDisplayName` with any bracketed qualifier already peeled off.
    private static func baseDisplayName(_ id: Substring) -> String {
        let tokens = id.split(separator: "-")
        guard let familyIdx = tokens.firstIndex(where: {
            $0.allSatisfy(\.isLetter) && $0.lowercased() != "claude"
        }) else { return String(id) }
        let family = tokens[familyIdx]
        var before: [Substring] = []
        var i = familyIdx
        while i > tokens.startIndex {
            let t = tokens[tokens.index(before: i)]
            guard t.allSatisfy(\.isNumber), t.count < 8 else { break }
            before.insert(t, at: 0)
            i = tokens.index(before: i)
        }
        var after: [Substring] = []
        i = tokens.index(after: familyIdx)
        while i < tokens.endIndex {
            let t = tokens[i]
            guard t.allSatisfy(\.isNumber), t.count < 8 else { break }
            after.append(t)
            i = tokens.index(after: i)
        }
        let version = (before + after).joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }
}
