# Phanttom 👻

A fork of [Ghostty](https://github.com/ghostty-org/ghostty) with vertical tabs
in a sidebar, an appearance settings GUI, and first-class support for AI coding
agents (Claude Code / Codex / Cursor Agent CLI) — tab auto-naming,
working/done/attention status, and a pixel-rain activity indicator. The name is
"Phantom" with two t's, in the spirit of Ghostty's two t's.

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
| Claude Code hook installer (launch auto-install/re-sync, merge/strip) | `Features/Settings/PhanttomClaudeIntegration.swift` (tests: `macos/Tests/Settings/PhanttomClaudeIntegrationTests.swift`) |
| Cursor Agent CLI hook installer (launch auto-install/re-sync, merge/strip) | `Features/Settings/PhanttomCursorIntegration.swift` (tests: `macos/Tests/Settings/PhanttomCursorIntegrationTests.swift`) |
| Claude/Codex/Cursor icons | `macos/Assets.xcassets/PhanttomClaude.imageset`, `PhanttomCodex.imageset`, `PhanttomCursor.imageset` (+ `*Mark` variants) |
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
  into `phanttom.conf`), and `autoSyncClaudeIntegration()` /
  `autoSyncCursorIntegration()` (Claude Code / Cursor Agent hook
  auto-install/re-sync; see the hooks protocol sections).
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

Sidebar and terminal pane colors are opinionated and not user-configurable.
Tokens live in one place (`PhanttomSettings.Chrome`) and feed SwiftUI,
AppKit, and the config fragment:

- Sidebar / titlebar left: `#161917`
- Terminal / titlebar right: `#101211` (written into `phanttom.conf` as
  `background` / opacity `1` / blur `0`)
- Divider: `#2D2E2E`
- Working / done / attention status: `#24FE8A` / `#3A89D8` / `#F5CC64`
- Selected / hover row: `white @ 4%`, corner radius 12

Launch re-applies `phanttom.conf` (and the optional include) silently.
Escape hatch: remove the `config-file = ?phanttom.conf` include from the
user's Ghostty config. Phanttom Settings no longer exposes chrome controls.

## Tab semantics (the behavioral contract)

**Kind** (`terminal` | `claude` | `codex` | `cursor`) is detected from surface
titles — every split's title, not just the focused one, so an idle agent in a
background split keeps its identity — and stored sticky on the window
(`phanttomTabState`):

- title starts with the hook marker `❯` + U+2063 (invisible separator) →
  agent kind from the marker payload (see below), stored sticky (only our
  hooks emit the marker)
- title contains "claude" / "codex" / "cursor" → that kind (Cursor Agent CLI
  titles look like `Cursor Agent` / `Cursor ready`; bare `"agent"` is **not**
  matched)
- decorated title (leading non-alphanumeric glyph, e.g. Claude Code's "✳ …" or
  a bare "❯ …" prompt char from starship/pure) → keeps the previous kind
- plain title (shell integration reclaiming the tab) → back to `terminal`,
  and clears the auto-name

**Marker wire format** (OSC 2 title). Fields are separated by U+2063:

- Kind-aware (current): `❯⁣.claude⁣<prompt>⁣<model>` / `.cursor` / `.codex`
  (model-only: empty prompt field). Kind tokens are **dot-prefixed** so a
  legacy prompt that is literally `cursor` cannot be misread as a kind field.
- Legacy Claude (still accepted): `❯⁣<prompt>⁣<model>` → kind `.claude`.

**Status** (leading slot on agent cards, trailing slot on terminal rows):

- `working` (pixel rain in `#24FE8A`) — any surface in the window has an
  OSC 9;4 progress report (agents in non-focused splits count). Indeterminate
  reports (state 3, what the hooks emit) are exempt from upstream's 15s
  staleness timeout in `SurfaceView_AppKit.swift`, so the rain runs for the
  whole task and stops only on an explicit clear (Stop with no in-flight
  `background_tasks`, Notification, or surface close). A Stop that still has
  background work (e.g. subagents) re-arms rain instead of clearing.
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
pinned top-of-sidebar "New tab" row always opens in home (`~`), with a
trailing folder-plus menu (`PhanttomFolderPlus`) listing top-level folders
in `~/Developer` — choosing one seeds a new tab into that project.
Grouping is presentation-only in `SidebarView`: native tab order, animations,
and all cross-window state are untouched. Tabs whose pwd isn't known yet form
a trailing header-less bucket. Sidebar drag-and-drop reorders tabs by mutating
the native tab group (`removeWindow` + `addTabbedWindowSafely`, same contract
as keyboard move-tab and the group "+"); when grouping is on, tab drops stay
inside the same project (or the pending bucket). Project-group header drag
reorders a persisted display sequence in `ProjectGroupOrderStore`
(`PhanttomProjectGroupOrder`) — it does not rewrite `tabbedWindows`.

**Name priority**: manual rename (upstream's
`BaseTerminalController.titleOverride` — shared with the titlebar, command
palette, and window restoration, so custom names survive restart) → prompt
auto-name (`phanttomTabState.autoTitle`) → title with leading decoration glyphs
stripped. Auto-name comes from a marker title (`❯` + U+2063) and locks to the
**first** prompt of a session; it re-arms when the shell reclaims the title
or via context-menu **Reset Name** (which remembers the consumed title so the
same one isn't immediately re-captured).

## Claude Code integration (hooks protocol)

**Zero-touch:** hooks install (and repair / update) automatically on every
launch whenever `~/.claude` exists — no prompt, no consent dialog
(`autoSyncClaudeIntegration` in `AppDelegate+Phanttom.swift`). The only off
switch is **Phanttom Settings → Claude Code → Remove…**, which sets the
`PhanttomClaudeAutoInstallDisabled` default so removal sticks across
launches; `Set Up` clears it and auto-sync resumes. A missing `~/.claude`
or corrupt `settings.json` is silently retried next launch. The two
pre-auto-install consent defaults (`PhanttomClaudeSetupPrompted`, PR #15
`PhanttomClaudeHooks`) are migrated once via `migrateConsent`: a prior
decline / Remove becomes the opt-out; installed users keep syncing.
Installer implementation:
`macos/Sources/Features/Settings/PhanttomClaudeIntegration.swift`.

**Architecture.** One versioned helper script at
`~/.claude/phanttom-hook.sh` (embedded in the app as `hookScript`; payload
version is `payloadVersion`). Every hook and the statusline are thin
dispatch calls — no shell-quoting-inside-JSON:

```sh
sh "$HOME/.claude/phanttom-hook.sh" prompt-submit
sh "$HOME/.claude/phanttom-hook.sh" session-start
sh "$HOME/.claude/phanttom-hook.sh" post-tool-use
sh "$HOME/.claude/phanttom-hook.sh" stop
sh "$HOME/.claude/phanttom-hook.sh" notification
sh "$HOME/.claude/phanttom-hook.sh" statusline
```

**Files the installer touches** (under `~/.claude/`):

| File                                           | Role                                                                         |
| ---------------------------------------------- | ---------------------------------------------------------------------------- |
| `settings.json`                                | Hooks + `statusLine` entries (unknown keys round-trip)                       |
| `settings.json.bak-phanttom-<yyyyMMdd-HHmmss>` | Timestamped backup before every write (keep ≤5)                              |
| `phanttom-hook.sh`                             | Versioned payload (`chmod 0755`)                                             |
| `phanttom-integration.json`                    | `{"version", "originalStatusLine"}` — statusline chains to the saved command |

**Version bump rule.** Any change to the script text or the desired hook /
statusline spec **must** bump `payloadVersion` — that's what drives
Settings' "Update available".

All hooks write escape sequences to the session tty (hook stdout is captured
by Claude Code). Tty resolution is
`ps -o tty= -p "${CLAUDE_PID:-$PPID}"` with `""|"?"|"??"` → `/dev/tty`
fallback — plain `/dev/tty` alone is known-broken (hook processes have no
controlling terminal). `CLAUDE_PID` is undocumented; keep the full fallback
chain. Ownership detection never treats bare OSC 9;4 / OSC 7 alone as
Phanttom's (those are generic sequences); legacy inline hooks match via the
CLAUDE_PID tty-resolve pairing, the title marker, or `statusline-phanttom.sh`.
JSON parsing prefers `jq` when present, else `/usr/bin/perl` + `JSON::PP`
(no Homebrew / CLT dependency).

| Event / subcommand                                                                | Emits                                                                                                                                                            | Phanttom effect                                                                     |
| --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `prompt-submit`                                                                   | OSC 9;4 state 3 (indeterminate)                                                                                                                                  | pixel rain starts                                                                   |
| `prompt-submit`                                                                   | OSC 2 title `❯⁣.claude⁣<prompt, 56ch>⁣<model-id>` — `❯` + U+2063 (`\xe2\x9d\xaf\xe2\x81\xa3`) + `.claude` kind token                                              | first prompt names the tab; model from last non-synthetic assistant transcript turn |
| `prompt-submit`, `session-start`, `post-tool-use` (`EnterWorktree\|ExitWorktree`) | OSC 7 `file://localhost<cwd>` (URI-encoded, `%2F` restored to `/`)                                                                                               | tab pwd tracks the _agent's_ directory, not just the shell's                        |
| `stop`                                                                            | OSC 9;4 clear **or** re-arm state 3                                                                                                                              | reads stdin `background_tasks` (Claude Code ≥2.1.145): if any in-flight background work remains, re-emits rain; otherwise clears → Done if unselected. Missing/unparseable → clear (pre-2.1.145) |
| `subagent-start`                                                                  | OSC 9;4 state 3 (indeterminate)                                                                                                                                  | re-arms rain when a subagent spawns (covers races where Stop cleared before tasks were registered). `SubagentStop` is intentionally not hooked — clearing there can flash rain off before the parent wakes |
| `notification`                                                                    | OSC 9;4 clear + BEL                                                                                                                                              | → Attention if unselected                                                           |
| `statusline`                                                                      | model-only marker `❯⁣.claude⁣⁣<model-id>` on change (cache file under `$TMPDIR`); then chains to the user's original statusline (or a minimal `<model> · <dir>` default) | sidebar model label from session start / `/model` switches                          |

Bumping `payloadVersion` (currently 5 for the `.claude` kind-token markers)
shows every existing Claude-integrated user Settings' "Update available" and
triggers silent launch repair — expected churn, not a regression.

## Cursor Agent CLI integration (hooks protocol)

**Zero-touch**, exactly like the Claude integration above: hooks install
(and repair / update) automatically on every launch whenever `~/.cursor`
exists — no prompt, no consent dialog (`autoSyncCursorIntegration` in
`AppDelegate+Phanttom.swift`). The only off switch is **Phanttom Settings →
Cursor Agent → Remove…**, which sets the `PhanttomCursorAutoInstallDisabled`
default so removal sticks across launches; `Set Up` clears it and auto-sync
resumes. A missing `~/.cursor` or unparseable `hooks.json` / `cli-config.json`
is silently retried next launch. There is no consent-key migration here (the
Claude side has one): this integration never shipped a prompt, so there is no
prior decision to honor. Implementation:
`macos/Sources/Features/Settings/PhanttomCursorIntegration.swift`.

**Architecture.** Same versioned helper pattern as Claude, adapted to Cursor's
split config:

```sh
sh "$HOME/.cursor/phanttom-hook.sh" session-start
sh "$HOME/.cursor/phanttom-hook.sh" pre-tool-use
sh "$HOME/.cursor/phanttom-hook.sh" model-update
sh "$HOME/.cursor/phanttom-hook.sh" stop
sh "$HOME/.cursor/phanttom-hook.sh" statusline
```

| File | Role |
| --- | --- |
| `~/.cursor/hooks.json` | Lifecycle hooks (flat `{ "command" }` entries; foreign hooks preserved) |
| `~/.cursor/cli-config.json` | `statusLine` command (absent file treated as empty `[:]`, not corrupt) |
| `~/.cursor/phanttom-hook.sh` | Versioned payload (`chmod 0755`) |
| `~/.cursor/phanttom-integration.json` | `{version, originalStatusLine, originalStatusLineObject?}` |
| `*.bak-phanttom-<stamp>` | Timestamped backups of hooks.json / cli-config.json (keep ≤5 + oldest) |

**Emit guards.** Hooks only emit OSC when `CURSOR_AGENT=1` (Cursor Agent CLI
sets this; IDE Agent Chat does not) **and** a real pty is found by walking
ancestors from `$PPID` (or from `PHANTTOM_TTY` injected by `sessionStart`'s
`env` response). There is no `CURSOR_PID` analog and **no** `/dev/tty`
fallback — bare `/dev/tty` is known-broken for hook processes.

| Event / subcommand | Emits | Phanttom effect |
| --- | --- | --- |
| `sessionStart` | model-only marker `❯⁣.cursor⁣⁣<model>`; OSC 7 from `workspace_roots[0]` / `CURSOR_PROJECT_DIR`; optional `{env:{PHANTTOM_TTY}}` | kind sticky, model badge, agent pwd |
| `preToolUse` | OSC 9;4 state 3; model marker; OSC 7 | pixel rain + model/pwd refresh |
| `afterAgentThought` / `postToolUse` | model marker on change | live model badge |
| `stop` | OSC 9;4 clear (**always** — no Claude-style `background_tasks` re-arm) | → Done if unselected |
| `statusLine` (`cli-config.json`) | model marker on change; chains prior statusline | model from session start / `/model` |

`beforeSubmitPrompt` is not installed yet — print-mode CLI spikes did not
observe it; auto-name falls back to the `"Cursor"` kind label / surface title
until that path is confirmed in a real interactive tab. Codex remains
title-branding only (no hooks installer).

The U+2063 INVISIBLE SEPARATOR makes the marker collision-proof: a bare "❯"
is the default prompt char of starship/pure/p10k and must NOT trigger
auto-naming (it's treated as a decorated title instead). Hook stdin JSON has
**no model field** on any event — the statusline is the only pre-first-response
model source, which is why the statusline wrapper exists.

The OSC 7 cwd report rides the terminal's normal pwd channel (the same one
shell integration uses at each prompt), so no app-side plumbing is needed:
when an agent session enters a linked worktree, the tab's pwd, directory
label, branch, project group (worktrees group under their parent repo via
`projectRoot`), and PR dot all follow the agent's checkout, and the row
swaps the branch glyph for `arrow.triangle.branch` (`Resolved.isWorktree`
on `TabItem.git`). When the session ends, the next shell prompt re-reports
the real pwd and the tab heals itself. The two writers can't fight because
the shell's OSC 7 is emitted by its prompt hooks, and the prompt doesn't
render while the CLI owns the foreground — it redraws (and re-reports) only
after the CLI exits. If the CLI ever stops being the sole foreground
process for the session's lifetime, that assumption breaks.

Manual test commands (any tab):
`printf '\033]9;4;3;0\033\\'` (rain) · `printf '\033]9;4;0;0\033\\'` (clear) ·
`printf '\a'` (bell) ·
`printf '\033]2;\xe2\x9d\xaf\xe2\x81\xa3 some name\007'` (auto-name) ·
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
- **Restore windows on quit** (`restoreWindowsOnQuit`, default off) writes
  `window-save-state = always` into the same fragment when enabled; when
  off the key is omitted so a user's own `window-save-state` is not
  overridden. Exposed in **Phanttom Settings → Windows**.
- **Sidebar grouping** (`sidebarGroupByProject`) is UserDefaults-only and
  applies instantly through SwiftUI.

## Session restore (layout, not agent resume)

Upstream Ghostty already restores **window layout** on macOS via AppKit
restorable state (`NSWindowRestoration`), gated by `window-save-state`.
Phanttom uses that path unchanged — Debug and prod share the same code;
they only differ by bundle ID (separate saved-state stores under
`~/Library/Saved Application State/`).

**What “bring sessions back” means today:**

| Survives restore | Does **not** survive |
|---|---|
| Windows / tab groups | Running processes (Claude Code, servers, shells mid-command) |
| Splits | Scrollback / buffer contents |
| Working directory per surface | Agent status (working / done / attention) |
| Manual tab rename (`titleOverride`) | Auto-name, agent kind, model label (`PhanttomTabState`) |
| Tab color, focused surface, fullscreen | Live mid-conversation agent session |
| Quick terminal layout | Surfaces launched with a custom `command` |

Restore opens a **fresh PTY in the saved directory**. Realistic deliverable:
layout + cwd + manual names — not “close app → Claude resumes mid-conversation.”

Sidebar width/collapse, project-group order/collapse, Phanttom settings, and
last window frame survive separately via UserDefaults even when window
restore does not run.

**When it saves:**

| `window-save-state` | Behavior |
|---|---|
| `default` (shipped) | Save only on **forced termination** (crash, force quit, Xcode Stop), or if macOS Settings keeps windows on quit |
| `always` | Save whenever the app exits (including intentional Cmd-Q) |
| `never` | Never save / restore |

That is why Debug “comes back after a crash” feels special: Xcode Stop is
forced termination, which saves under `default`. Intentional Cmd-Q of prod
does not restore unless you opt in.

**Opt in for quit → reopen restore** (preferred): **Phanttom Settings →
Windows → Restore windows on quit**. That writes `window-save-state =
always` into `phanttom.conf` and reloads config. Equivalent manual config:

```ini
window-save-state = always
```

Mapped in `AppDelegate.ghosttyConfigDidChange` to `NSQuitAlwaysKeepsWindows`.
Encode path: `TerminalController.window(_:willEncodeRestorableState:)` →
`TerminalRestorableState` (currently version 7, minimum 5). Decode path:
`TerminalWindowRestoration` in `TerminalRestorable.swift`.

**Product guidance (do not “just flip” these):**

- The Settings toggle is the productized opt-in. Do **not** change the fork
  default to `always` — that is a user-visible divergence from upstream
  (every Cmd-Q reopens windows; some users dislike that) that every rebase
  must consciously preserve.
- Encoding `PhanttomTabState` into restorable state is real work (`final`
  class, not currently `Codable`; restorable state is versioned — bump +
  migrate) and buys only cosmetic survival (name/kind), not a live session.
- Scrollback restore is a large Zig/core effort; upstream deferred it.
  Separate from layout restore.

Sparkle update relaunches can skip save/restore in some cases (upstream
limitation).

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
  radius 12 / `white 4%` (selected and hover), sidebar width 271, sidebar bg
  `#161917`, terminal bg `#101211`.
- Rebase policy: rebase `phanttom` onto upstream release tags once one ships
  requiring Zig 0.16+; until then we pin upstream main. Keep upstream-file
  hunks small so rebases stay cheap.
