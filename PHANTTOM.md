# Phanttom 👻

A fork of [Ghostty](https://github.com/ghostty-org/ghostty) with vertical tabs
in a sidebar, an appearance settings GUI, and first-class support for AI coding
agents (Claude Code / Codex) — tab auto-naming, working/done/attention status,
and a pixel-rain activity indicator. The name is "Phantom" with two t's, in the
spirit of Ghostty's two t's.

**This file is the entry point for anyone (human or agent) working on the
fork.** Upstream's `AGENTS.md` covers general Ghostty conventions; this file
covers everything Phanttom adds and the sharp edges we've already hit.

- Repo: `github.com/NoahHendrickson/phanttom`, branch `phanttom` (default)
- Remotes: `upstream` = ghostty-org/ghostty, `origin` = the fork,
  `reference-tom` = tomreinert/ghostty (prior-art sidebar fork, study only)
- **Never open issues or PRs against upstream, and never try to merge
  anything into upstream** (their AGENTS.md forbids agent-created
  contributions; we honor that — and beyond that, this fork simply doesn't
  contribute back, ever). The relationship with upstream is one-way: we
  rebase onto their releases, nothing flows the other direction. All work
  stays on the fork — and PRs _on the fork_ (`origin`, base `phanttom`) are
  the normal way changes land, not an exception to that rule. See "Issue and
  PR Guidelines" in AGENTS.md.

## Build & run

```sh
zig build                          # full build incl. macOS app (needs Xcode + Metal toolchain + iOS SDK)
zig build -Demit-macos-app=false -Demit-xcframework=false   # Zig core only, no Xcode needed
zig build test-lib-vt              # fast core tests
macos/relaunch-debug.sh                                     # launch Debug (clean env; see note)
```

Always use `macos/relaunch-debug.sh` instead of bare `open …/Ghostty.app`
from Cursor/CI shells — those inherit `NO_COLOR=1` / `TERM=dumb` into the
app and strip Claude Code TUI colors. The script also quits only the Debug
bundle id, never prod.

- Zig **0.16.0** minimum (macOS 26.4+ SDK breaks Zig 0.15.x linking —
  ziglang/zig#31658 — which is why we track upstream main, not the v1.3.x tags).
- **Don't run `xcodebuild` with cwd inside `macos/`** — it creates a stray
  `macos/macos/` artifact tree. If you see one, delete it; never commit it.
- Capture build exit codes directly (`cmd > log 2>&1; echo $?`) — piping
  through `grep`/`tail` masks failures.

## Releasing

Distribution + auto-updates (GitHub Releases feed, Sparkle EdDSA keys, the
`phanttom-release.yml` workflow, sidebar update pill) are documented in
[PHANTTOM-RELEASING.md](PHANTTOM-RELEASING.md). The update feed and the
`SUPublicEDKey` in `Ghostty-Info.plist` are the fork's own — never point
either back at Ghostty's servers/keys or users will be "updated" to stock
Ghostty.

## Where Phanttom's code lives

All Phanttom code is Swift, under `macos/Sources/`. Zig (`src/`) is untouched.

| Area | Files |
|---|---|
| Sidebar UI (rows, status, rename, pixel rain) | `Features/Terminal/Sidebar/SidebarView.swift` |
| Tab model + event plumbing | `Features/Terminal/Sidebar/SidebarTabManager.swift` |
| Per-tab state machine (kind, status, auto-name) | `Features/Terminal/Sidebar/PhanttomTabState.swift` (tests: `macos/Tests/Terminal/PhanttomTabStateTests.swift`) |
| Async git-branch cache (off-main .git/HEAD reads; worktree detection) | `Features/Terminal/Sidebar/GitBranchCache.swift` |
| `[sidebar \| terminal]` split, collapse, width persistence | `Features/Terminal/Sidebar/SidebarSplitView.swift` |
| Titlebar sync hook (end of `syncAppearance`) | `Features/Terminal/Sidebar/PhanttomWindowGlass.swift` |
| Titlebar zone tracking sidebar width | `Features/Terminal/Sidebar/PhanttomTitlebarZone.swift` |
| Settings model (UserDefaults + locked chrome fragment) | `Features/Settings/PhanttomSettings.swift` |
| Settings UI | `Features/Settings/PhanttomSettingsView.swift` |
| Settings window host | `Features/Settings/SettingsWindowController.swift` |
| Claude Code hook installer (consent, launch re-sync, merge/strip) | `Features/Settings/PhanttomClaudeIntegration.swift` (tests: `macos/Tests/Settings/PhanttomClaudeIntegrationTests.swift`) |
| Claude/Codex icons | `macos/Assets.xcassets/PhanttomClaude.imageset`, `PhanttomCodex.imageset` |

Touches to upstream files are deliberately tiny and greppable — search
`Phanttom`/`phanttom` to find every hook point:

- `TerminalController.swift`: one `phanttomInstallSidebar` call in
  `windowDidLoad` (implementation lives in
  `Sidebar/TerminalController+PhanttomSidebar.swift`), a notification post in
  `relabelTabs`, and two stored properties (extensions can't add storage).
- `BaseTerminalController.swift`: one `phanttomTitleOverrideDidChange()` call
  in `titleOverride`'s didSet, so every rename writer (sidebar, ⌘-rename
  prompt, tab-bar inline editor) keeps the auto-name in sync on clear.
- `TerminalWindow.swift`: `sidebarActive` (tab bar suppression), one
  `phanttomTabState` property (the `PhanttomTabState` model: agent kind,
  status, auto-name), and one `phanttomSyncAppearanceDidRun()` call at the
  end of `syncAppearance`.
- `TerminalViewContainer.swift`: the `terminalViewContainer` accessor also
  looks through `SidebarSplitView` (upstream casts `contentView` directly —
  without this, config changes and macOS 26 glass never reach the container).
- `AppDelegate.swift`: one `setupPhanttomMenus()` call (implementation in
  `AppDelegate+Phanttom.swift`; inserts "Phanttom Settings…" ⌘⇧, and
  "Toggle Sidebar" ⌘B programmatically — MainMenu.xib is untouched),
  `PhanttomSettings.shared.setupOnLaunch(ghostty:)` (writes locked chrome
  into `phanttom.conf`), and `PhanttomClaudeIntegration.shared.setupOnLaunch()`
  (Claude Code hook install/re-sync; see the hooks protocol section).
- Sidebar is disabled when `macos-titlebar-style = tabs` (that style
  relocates the tab bar into the titlebar and fights the accessory hiding);
  the window falls back to plain upstream behavior. This is decided once per
  window at creation (`phanttomInstallSidebar` in `windowDidLoad`): a live
  config reload that switches to/from `tabs` affects only windows opened
  after the reload — existing windows keep whatever they were built with.
  Known limitation; reacting live would mean tearing down and rebuilding the
  window's content view, which isn't worth the risk.

The Xcode project uses filesystem-synchronized groups: **new files under
`macos/Sources/` are picked up automatically** — no pbxproj editing.

## Architecture: how the sidebar works

Ghostty macOS tabs are **native window tabs**: every tab is its own `NSWindow`
(+ `TerminalController`) joined into an `NSWindowTabGroup`. Phanttom keeps that
model. Each window's `contentView` is a `SidebarSplitView` =
`[SwiftUI sidebar | TerminalViewContainer]`; each window has its own
`SidebarTabManager` instance, all observing the shared tab group, so
cross-window state must live **on the window** (see
`TerminalWindow.phanttomTabState`), never in a manager instance.

`SidebarTabManager` is fully event-driven (no polling):

- membership changes ride upstream's `relabelTabs` (fires on new tab, close,
  and mouse reorder) via `.phanttomSidebarTabsDidChange`
- title/pwd via KVO on each window; selection via key-window notifications
- per-surface Combine subscriptions to `$progressReport` and
  `$backgroundColor`

### Native tab bar suppression — DO NOT "fix" this differently

AppKit **force-shows** the tab bar whenever a group has 2+ windows. Toggling it
back off (`toggleTabBar`, KVO on `isTabBarVisible`) fights AppKit in an
infinite loop and pegs the main thread — we shipped that bug once. The correct
mechanism is `TerminalWindow.sidebarActive`: the tab bar arrives as a titlebar
accessory view controller, and we hide the accessory as it's added
(`isHidden = true`, `fullScreenMinHeight = 0`).

### Locked chrome (Figma)

Sidebar and terminal pane colors are opinionated and not user-configurable:

- Sidebar / titlebar left: `#161917`
- Terminal / titlebar right: `#101211` (always written into `phanttom.conf`
  as `background` / opacity `1` / blur `0`)
- Divider: `#2D2E2E`
- Selected row: `white @ 4%`, corner radius 12; hover: `white @ 4%`, radius 8

Escape hatch: remove the `config-file = ?phanttom.conf` include from the
user's Ghostty config. Phanttom Settings no longer exposes chrome controls.

## Tab semantics (the behavioral contract)

**Kind** (`terminal` | `claude` | `codex`) is detected from surface titles —
every split's title, not just the focused one, so an idle agent in a
background split keeps its identity — and stored sticky on the window
(`phanttomTabState`):

- title starts with the hook marker `❯` + U+2063 (invisible separator) →
  `claude`, stored sticky (only our hook emits the marker)
- title contains "claude"/"codex" → that kind
- decorated title (leading non-alphanumeric glyph, e.g. Claude Code's "✳ …" or
  a bare "❯ …" prompt char from starship/pure) → keeps the previous kind
- plain title (shell integration reclaiming the tab) → back to `terminal`,
  and clears the auto-name

**Status** (leading slot on both agent cards and terminal rows):

- `working` (pixel rain in `#24FE8A`) — any surface in the window has an
  OSC 9;4 progress report (agents in non-focused splits count). Indeterminate
  reports (state 3, what the hooks emit) are exempt from upstream's 15s
  staleness timeout in `SurfaceView_AppKit.swift`, so the rain runs for the
  whole task and stops only on an explicit clear (Stop/Notification hooks)
  or surface close.
- `done` (blue `#3A89D8`, no glow) — work finished while the tab was unselected
- `attention` (yellow `#F5CC64`, no glow) — bell rang while unselected
  (judged against the bell window's own tab group)
- selecting a tab clears done/attention
- otherwise-idle tabs show their branch's GitHub PR state via
  `PhanttomGitPullRequestOpen` / `PhanttomGitPullRequestMerged` icons
  (`PRStatusCache`, gh-CLI-backed, 60s revalidate; silently absent without
  gh/auth/PR); idle with no PR is a `white @ 30%` 8pt circle
- status lives on `TerminalWindow` (`phanttomTabState`), never in a manager

**Project grouping** (settings toggle "Group tabs by project", default on;
also switchable from the grouping button at the sidebar's right edge of the
titlebar — a mode menu in `PhanttomTitlebarZone`, geometry synced with the
divider):
rows are grouped under a header per project — the repo toplevel of the tab's
pwd, with linked worktrees resolved to their parent repo (`GitBranchCache`
resolves branch + project root in one walk), else the pwd itself for non-git
directories (the home directory renders as "~"). Resolved metadata is sticky
per window (`PhanttomTabState.lastGitMetadata`): while the cache has no
answer for a pwd — resolve in flight, or the entry pruned — rows keep their
last known group instead of flapping through an interim one. Headers carry a
folder glyph — open when the group is expanded, closed when collapsed
(`PhanttomFolderOpen`/`PhanttomFolder` template assets, from the Figma
design; click the header to collapse/expand; state is process-global in
`ProjectCollapseStore` because every window hosts its own sidebar, and
persisted in UserDefaults). Expanded headers carry a trailing "+"
(`PhanttomPlus`) that opens a new tab in that project's directory (explicit
`SurfaceConfiguration.workingDirectory`, the window-restoration path). The
home group (`~`) also shows a folder-plus menu (`PhanttomFolderPlus`, from
Figma) left of "+" listing top-level folders in `~/Developer` — choosing one
seeds a new tab into that project the same way the group's "+" does. A bottom-of-list
"New tab" row always opens in home (`~`), independent of the focused project.
Grouping is presentation-only in `SidebarView`: native tab order, animations,
and all cross-window state are untouched. Tabs whose pwd isn't known yet form
a trailing header-less bucket.

**Name priority**: manual rename (upstream's
`BaseTerminalController.titleOverride` — shared with the titlebar, command
palette, and window restoration, so custom names survive restart) → prompt
auto-name (`phanttomTabState.autoTitle`) → state-owned title fallback
(`phanttomTabState.titleFallback`: current marker prompt, or `"Claude"` for a
model-only marker) → title with leading decoration glyphs stripped. Auto-name
comes from a marker title (`❯` + U+2063) and locks to the **first** prompt of
a session; it re-arms when the shell reclaims the title or via context-menu
**Reset Name** (which remembers the consumed title so the same one isn't
immediately re-captured). Marker-protocol parsing lives entirely in
`PhanttomTabState` — the sidebar view model has no U+2063 awareness.

## Claude Code integration (hooks protocol)

The app installs and maintains these hooks itself — user config is no longer
hand-maintained. `PhanttomClaudeIntegration` asks once on first launch
(consent `NSAlert`), then re-syncs `~/.claude/settings.json` silently on
every launch so protocol fixes ship with app updates; the toggle lives in
Phanttom Settings → Agents. `hookSpecs` in
`Features/Settings/PhanttomClaudeIntegration.swift` is the **source of
truth** for the commands — keep this section in sync with it. Sync
recognizes Phanttom's entries (current or legacy) by their escape-sequence
payload signatures (`]9;4;3;0`, `]9;4;0;0`, the `❯`+U+2063 marker bytes,
`file://localhost`) and replaces them, leaving everything else in the file
untouched (a rewrite normalizes JSON formatting; original backed up once to
`settings.json.bak-phanttom`; an unparsable settings file is never
modified). All hooks write
escape sequences to the session's terminal device (hook stdout is captured
by Claude Code, the tty is not). Hooks cannot just open `/dev/tty`: Claude
Code (observed in 2.1.218) spawns hook processes without a controlling
terminal, so that open fails with "Device not configured" — and the
`2>/dev/null; true` guard swallows it, making the failure look like the
hook never ran. Instead each hook resolves the real device from
`CLAUDE_PID` (the claude process's PID, exported to hooks — observed in
2.1.218, not a documented/stable contract), via `ps -o tty= -p
$CLAUDE_PID`, falling back to `/dev/tty` when that yields nothing, `?`,
or `??` (no controlling terminal; some `ps` variants report a bare `?`).
If `ps` itself is unavailable the command substitution is empty and the
same fallback applies. If a future Claude Code release stops exporting
`CLAUDE_PID` or changes its meaning, the hooks silently degrade to the
old `/dev/tty` behavior:

| Event | Emits | Phanttom effect |
|---|---|---|
| `UserPromptSubmit` | OSC 9;4 state 3 (indeterminate) | pixel rain starts |
| `UserPromptSubmit` | OSC 2 title `❯⁣ <prompt, 56ch>⁣<model-id>` — that's `❯` + U+2063 (`\xe2\x9d\xaf\xe2\x81\xa3`) before the prompt and a second U+2063 before the model id (last non-synthetic assistant turn of the transcript at `.transcript_path`; empty until the session's first response) | first prompt names the tab; raw model id is sticky on `PhanttomTabState` and pretty-printed at the `TabItem` edge via `modelDisplayName` ("Fable 5") |
| `UserPromptSubmit`, `SessionStart`, `PostToolUse` (`EnterWorktree\|ExitWorktree`) | OSC 7 `file://localhost<cwd>` (`jq -r '.cwd \| @uri'`, `%2F` restored to `/`) | tab pwd tracks the *agent's* directory, not just the shell's |
| `Stop` | OSC 9;4 state 0 (clear) | rain stops → Done if unselected |
| `Notification` | OSC 9;4 clear + BEL | → Attention if unselected |
| statusline (see below) | OSC 2 title `❯⁣⁣<model-id>` — marker + a second U+2063 with an **empty** prompt field | model label from the session's very first render, and live `/model` switches |

The U+2063 INVISIBLE SEPARATOR makes the marker collision-proof: a bare "❯"
is the default prompt char of starship/pure/p10k and must NOT trigger
auto-naming (it's treated as a decorated title instead).

**Why the statusline is involved:** hook stdin JSON carries **no model
field** on any event (verified empirically against a live session — the
docs' optional `SessionStart.model` does not appear in practice), so the
`UserPromptSubmit` hook can only read the model from the transcript's last
assistant turn — which doesn't exist until the first response. The
statusline command, however, receives `model.id`/`model.display_name` on
every render, starting before the first prompt. So
`~/.claude/statusline-phanttom.sh` (referenced from `statusLine.command` in
settings) relays the JSON to the user's real statusline script unchanged
and sidebands the model as a model-only marker title — emitted only when
the model _changes_ (cached per claude process in `$TMPDIR`), so the title
channel isn't stomped on every render. App-side, a model-only marker sets
kind/model and `titleFallback = "Claude"` but never the auto-name, so a
model id can't masquerade as a tab name.

The OSC 7 cwd report rides the terminal's normal pwd channel (the same one
shell integration uses at each prompt), so no app-side plumbing is needed:
when an agent session enters a linked worktree, the tab's pwd, branch,
project group (worktrees group under their parent repo via `projectRoot`),
and PR dot all follow the agent's checkout — the branch label simply shows
the worktree's branch with the standard glyph (`Resolved.isWorktree` is
still resolved on `TabItem.git`, but no longer changes the icon). When the
session ends, the next shell prompt re-reports
the real pwd and the tab heals itself. The two writers can't fight because
the shell's OSC 7 is emitted by its prompt hooks, and the prompt doesn't
render while the CLI owns the foreground — it redraws (and re-reports) only
after the CLI exits. If the CLI ever stops being the sole foreground
process for the session's lifetime, that assumption breaks.

The exact cwd hook command (identical for all three cwd events; kept here so
its quoting/escaping is auditable — the canonical builder is
`PhanttomClaudeIntegration.hookSpecs`, the installed copy lives in user
config):

```sh
sh -c 'd=$(jq -r ".cwd // empty | @uri" 2>/dev/null | sed "s|%2F|/|g"); t=$(ps -o tty= -p "${CLAUDE_PID:-0}" 2>/dev/null | tr -d " "); case "$t" in ""|"?"|"??") t=/dev/tty;; *) t=/dev/$t;; esac; [ -n "$d" ] && printf "\033]7;file://localhost%s\033\\\\" "$d" > "$t" 2>/dev/null; true'
```

The other hooks share the same `ps`-based tty resolution; rain start/clear
and bell differ only in their printf payloads, while the title hook also
reads the hook's stdin JSON once (for `.prompt`) and tails the transcript
file (for the model id). If claude
itself has no tty (`ps` reports `?`/`??` — e.g. a headless or app-managed
session), the fallback write to `/dev/tty` fails silently, which is
correct: there is no terminal to paint.

One caveat discovered while debugging this: in Claude Desktop–managed
sessions (stream-json transport), the `UserPromptSubmit` event does not
fire at all — so first-prompt tab naming and rain-start don't happen
there. `SessionStart`, `PostToolUse`, `Stop`, and `Notification` still
fire, so agent-cwd tracking and rain-clear keep working.

`@uri` percent-encodes everything (spaces, UTF-8, control chars) so no raw
byte from `.cwd` ever reaches the escape sequence; the `sed` only restores
`/` so the encoded value still reads as a path. A missing `.cwd`, non-JSON
input, or absent jq all produce no output (the `true` keeps the hook from
ever failing the Claude Code call).

Manual test commands (any tab):
`printf '\033]9;4;3;0\033\\'` (rain) · `printf '\033]9;4;0;0\033\\'` (clear) ·
`printf '\a'` (bell) ·
`printf '\033]2;\xe2\x9d\xaf\xe2\x81\xa3 some name\xe2\x81\xa3claude-fable-5\007'` (auto-name + model) ·
`printf '\033]7;file://localhost/tmp\033\\'` (agent cwd).
Tabs can be scripted via AppleScript: `tell application id
"com.mitchellh.ghostty" to new tab in window 1`.

## Settings architecture

Chrome is locked; only a few preferences remain:

- **Terminal background** is always written into the managed fragment
  `~/.config/ghostty/phanttom.conf` (`background = #101211`, opacity 1,
  blur 0) and reloaded via `reloadConfig()`. The user's main config gets a
  one-time optional include (`config-file = ?phanttom.conf`). Never write
  the user's own config beyond that line.
- **Font size override** (optional) also flows through that fragment.
- **Sidebar grouping** (`sidebarGroupByProject`) is UserDefaults-only and
  applies instantly through SwiftUI.

## Gotchas for agents

- Deployment target is **macOS 13**: no two-parameter `onChange`, check
  availability before using newer SwiftUI API.
- `Ghostty.SurfaceView` (`macos/Sources/Ghostty/`, ~11k lines) owns input/IME/
  rendering polish — don't rewrite it, don't regress it. UI work should not
  touch `src/` (Zig) at all.
- One `SidebarTabManager` per window: shared state goes on `TerminalWindow`.
- The design source of truth is the Figma file ("Untitled",
  `MgM8y8QIVMfT2zNEbbxz1S`): component set "tab" with variants for
  kind/selection/status. Metrics: rows 255 wide, 12/8 padding, selected
  radius 12 / `white 4%`, hover radius 8, sidebar width 271, sidebar bg
  `#161917`, terminal bg `#101211`.
- Rebase policy: rebase `phanttom` onto upstream release tags once one ships
  requiring Zig 0.16+; until then we pin upstream main. Keep upstream-file
  hunks small so rebases stay cheap.
