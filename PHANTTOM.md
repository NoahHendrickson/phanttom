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
| Typewriter reveal of a newly assigned auto-name | `Features/Terminal/Sidebar/SidebarTypewriterTitle.swift` |
| Async git-branch cache (off-main .git/HEAD reads; worktree detection) | `Features/Terminal/Sidebar/GitBranchCache.swift` |
| `[sidebar \| terminal]` split, collapse, width persistence | `Features/Terminal/Sidebar/SidebarSplitView.swift` |
| Titlebar sync hook (end of `syncAppearance`) | `Features/Terminal/Sidebar/PhanttomWindowGlass.swift` |
| Titlebar zone tracking sidebar width | `Features/Terminal/Sidebar/PhanttomTitlebarZone.swift` |
| Settings model (UserDefaults + locked chrome fragment) | `Features/Settings/PhanttomSettings.swift` |
| Settings UI | `Features/Settings/PhanttomSettingsView.swift` |
| Settings window host | `Features/Settings/SettingsWindowController.swift` |
| Claude Code hook installer (launch auto-install/re-sync, merge/strip) | `Features/Settings/PhanttomClaudeIntegration.swift` (tests: `macos/Tests/Settings/PhanttomClaudeIntegrationTests.swift`) |
| Cursor Agent CLI hook installer (launch auto-install/re-sync, merge/strip) | `Features/Settings/PhanttomCursorIntegration.swift` (tests: `macos/Tests/Settings/PhanttomCursorIntegrationTests.swift`) |
| Claude Code hook payload (the installed `phanttom-hook.sh`) | `Features/Settings/PhanttomClaudeHookScript.swift` |
| Cursor Agent hook payload | `Features/Settings/PhanttomCursorHookScript.swift` |
| Shared installer plumbing (JSON I/O, backups, script payload, opt-out + consent markers, the hook scripts' shared shell prelude) | `Features/Settings/PhanttomIntegrationSupport.swift` (tests: `macos/Tests/Settings/PhanttomIntegrationSupportTests.swift`) |
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
- `done` (blue `#3A89D8`, no glow) — work finished while the user wasn't watching
- `attention` (yellow `#F5CC64`, no glow) — bell rang while the user wasn't
  watching (judged against the bell window's own tab group)
- **"Watching" is `SidebarTabManager.isWatched`: frontmost tab of its own group
  AND key window AND `NSApp.isActive`** — deliberately stricter than
  `TabItem.isSelected`, which is tab order and drives only the row highlight.
  Acknowledgement is a claim about the user, not about tab order. Judging it by
  selection alone meant the tab you happened to leave selected when you
  switched apps counted as "seen": an agent that blocked for input there showed
  the *gray idle dot*, the one reading that actively misleads a sidebar scan,
  since gray means "nothing to do here". Same for work that finished while you
  were away — it now owes you the blue dot like any background tab. The mark
  side (`noteBell`) and the acknowledge side (`PhanttomTabState.update`) MUST
  ask this same question; if they diverge the indicator either never appears or
  never clears. `isWatched` reads `NSApp.isActive`, so the manager observes
  `NSApplication.didBecomeActive` — without it the ack sits stale and returning
  to Ghostty leaves a yellow dot on the tab you're staring at. Resign-active is
  deliberately *not* observed: going unwatched cannot change any status.
- **Precedence is `attention > working > done > idle`**, and `updateStatus`
  works on *edges* of `isWorking`, not levels, to enforce it. This is load
  bearing, not stylistic: the Notification hook clears the progress report and
  rings the BEL in the same breath, so the sidebar sees the clear-refresh and
  the bell in an order it does not control. Level-based logic lost the bell in
  **both** orderings — `noteBell` used to bail unless `status == .idle`, which
  by then was either `.working` (bell first) or the `.done` the clear had just
  produced — and a tab *blocked waiting for input* rendered blue "done". Only a
  rising edge of `isWorking` may take the slot back from `.attention`; a report
  that is merely still live may not.
  **Known limit, deliberate:** `isWorking` is an OR across every surface in the
  window, so that rising edge says *some* split started work — not that the
  split which rang the bell resumed. In a tab running two agents, the second one
  starting clears the first one's unread yellow dot. Do not "fix" it by dropping
  the rising edge; that restores the double-drop regression above. Closing it
  properly needs per-surface progress, which a window-level report cannot
  express — and the same root cause bounds the deferral rule below.
- **A bell rung against a live progress report is deferred one refresh, not
  taken.** At bell time the hook's own BEL (racing the clear printed beside it)
  and a stray BEL from the running program (test runner, build tool, readline)
  are indistinguishable. The next refresh separates them: report gone → that was
  the hook, take `.attention`; report still live → incidental, the sparkle
  stands. Taking it unconditionally stranded any stray BEL as a permanent yellow
  dot on a *running* tab, since the rising edge cannot re-fire for a report that
  never went away and the falling edge yields to attention. One refresh is the
  width of the race being settled — the hook writes clear and BEL together, so
  they parse microseconds apart while a refresh costs a runloop turn.
- watching a tab clears done/attention; it never clears `.working`, which is a
  fact about the process rather than an unread notice
- otherwise-idle tabs show their branch's GitHub PR state via
  `PhanttomGitPullRequestOpen` / `PhanttomGitPullRequestMerged` icons
  (`PRStatusCache`, gh-CLI-backed, 60s revalidate; silently absent without
  gh/auth/PR); idle with no PR is a `white @ 30%` 8pt circle.
  On by default but switchable (Settings → Sidebar → "Show pull request
  status") — this is the only thing in Phanttom that touches the network, so
  it owes the user a switch and a plain description: resolving it runs `gh`
  with the user's credentials *in the tab's own directory* and makes an
  authenticated request that discloses the branch. The query is limited to
  `.idle` rows (the only ones that render the icon) and to repositories whose
  config declares a github.com remote (`GitBranchCache.hasGitHubRemote`,
  parsed from the config text — no git subprocess runs in the repo to answer
  it), so it is never made from an arbitrary directory
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

**Asked once, then zero-touch:** the first launch that finds a `~/.claude`
without our hooks shows one dialog (`askAgentIntegrationConsent` in
`AppDelegate+Phanttom.swift`). Say yes and the hooks install; after that they
are repaired and updated silently on every launch, forever, with no further
prompts. Say no and the opt-out marker is written. The answer is recorded as
an empty `~/.claude/.phanttom-autoinstall-asked` file — beside the config it
governs, for the same cross-build reason as the opt-out marker below — and a
`~/.claude` that already has hooks (installed by an earlier build) is
grandfathered as consented rather than re-asked. Setting up or removing from
Settings also counts as answering.

This is not ceremony: `~/.claude/settings.json` is *another tool's*
configuration, the hooks we add run in every Claude Code session on the
machine (not just Phanttom's), and one of them puts prompt text into a
window title. That is a question, not a default.

The off switch stays **Phanttom Settings → Claude Code → Remove…**, which
writes an empty `~/.claude/.phanttom-no-autoinstall` marker so removal sticks
across launches; `Set Up` deletes it and auto-sync resumes. Remove… also
deletes the timestamped backups and the private session directory. A missing
`~/.claude` or corrupt `settings.json` is silently retried next launch.

**The opt-out is a file, not a UserDefaults key** — deliberately.
`UserDefaults.standard` is scoped to the bundle identifier, so the Debug
build (`com.mitchellh.ghostty.debug`) and the release build
(`com.mitchellh.ghostty`) have separate domains while auto-installing into
the *same* `~/.claude`: a defaults-backed opt-out set in one build was
invisible to the other, which silently reinstalled the hooks. Keep the
marker beside `settings.json` (and **not** in `phanttom-integration.json`,
which uninstall deletes — `optOutSurvivesUninstall` guards that).

Three pre-marker defaults are migrated once and never written again:
`PhanttomClaudeSetupPrompted` and PR #15's `PhanttomClaudeHooks` via
`migrateConsent` (a prior decline / Remove becomes the opt-out; installed
users keep syncing), and `PhanttomClaudeAutoInstallDisabled` via
`migrateOptOutFromDefaults`. Both migrations defer while `~/.claude` is
absent rather than consuming the key with nowhere to record the answer.
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
| `.phanttom-sessions/`                          | 0700 per-session scratch (model last emitted, "tab already named") — never `$TMPDIR`/`/tmp`, which is world-writable and guessable when `TMPDIR` is unset |
| `.phanttom-autoinstall-asked`                  | The consent question has been answered (either way)                          |

**Version bump rule.** Any change to the script text or the desired hook /
statusline spec **must** bump `payloadVersion` — that's what drives
Settings' "Update available".

**Emit guard.** The hooks live in `~/.claude`, so they run for every Claude
Code session on the machine — including ones started from iTerm, VS Code,
tmux, or an ssh-in. Nothing but Phanttom/Ghostty understands these sequences,
and the marker title carries prompt text, so the script emits nothing unless
`TERM_PROGRAM=ghostty` (or `GHOSTTY_RESOURCES_DIR` is set). The statusline
branch is the exception: it still chains to the user's own statusline
everywhere, because we replaced that command with our dispatch.

**One prompt per session.** `prompt-submit` puts prompt text in the title
only for the session's *first* prompt; later ones send the marker with an
empty prompt field (kind + model only). The app never consumed anything but
the first — auto-naming locks — so every later emission was prompt text in
the macOS window title, where screen recording, Accessibility clients, and
screenshots can read it, for no gain. Consequence to know: **Reset Name**
re-arms the app side, but the hook will not re-send a prompt for that
session, so the row falls back to the "Claude" label until a new session
starts. That is the intended trade.

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
| `statusline`                                                                      | model-only marker `❯⁣.claude⁣⁣<model-id>` on change (cache file under `~/.claude/.phanttom-sessions/`); then chains to the user's original statusline (or a minimal `<model> · <dir>` default) | sidebar model label from session start / `/model` switches                          |

Bumping `payloadVersion` (currently 7: the emit guard, one-prompt-per-session,
and the private session directory) shows every existing Claude-integrated user
Settings' "Update available" and triggers silent launch repair — expected
churn, not a regression.

## Cursor Agent CLI integration (hooks protocol)

**Asked once, then zero-touch**, exactly like the Claude integration above:
one dialog the first time a hook-less `~/.cursor` is found, then silent
repair / update on every launch (`autoSyncCursorIntegration` in
`AppDelegate+Phanttom.swift`). The only off switch is **Phanttom Settings →
Cursor Agent → Remove…**, which writes an empty
`~/.cursor/.phanttom-no-autoinstall` marker so removal sticks across launches;
`Set Up` deletes it and auto-sync resumes. Same file-not-UserDefaults
reasoning as the Claude opt-out above — one decision per `~/.cursor`, shared
by every build — and likewise **not** a field in `phanttom-integration.json`,
which uninstall deletes (`optOutSurvivesUninstall` guards that). A missing
`~/.cursor` or unparseable `hooks.json` / `cli-config.json` is silently
retried next launch. There is no key migration here (the Claude side has
two): this integration never shipped a prompt, and its short-lived
`PhanttomCursorAutoInstallDisabled` default never reached a release.
Implementation:
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
| `~/.cursor/.phanttom-sessions/` | 0700 per-session scratch (last model emitted) |
| `~/.cursor/.phanttom-autoinstall-asked` | The consent question has been answered |
| `*.bak-phanttom-<stamp>` | Timestamped backups of hooks.json / cli-config.json (keep ≤5 + oldest) |

**Emit guards.** Hooks only emit OSC when `CURSOR_AGENT=1` (Cursor Agent CLI
sets this; IDE Agent Chat does not), **and** the session is running in a
Phanttom/Ghostty terminal (`TERM_PROGRAM=ghostty` / `GHOSTTY_RESOURCES_DIR` —
`~/.cursor/hooks.json` is read by every Cursor Agent session on the machine),
**and** a real pty is found by walking ancestors from `$PPID` (or from
`PHANTTOM_TTY` injected by `sessionStart`'s `env` response). A gated-out
`statusline` still chains to the user's own statusline. There is no `CURSOR_PID` analog and **no** `/dev/tty`
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

## Adding a third agent

`PhanttomIntegrationSupport` holds everything that is genuinely agent-agnostic:
JSON read/write (atomic, with a re-parse guard and the file's prior mode
re-applied), timestamped backups (0600) and their pruning and removal, writing
the versioned `phanttom-hook.sh` payload, parsing `# phanttom-hook v<N>` back
out, the `.phanttom-no-autoinstall` opt-out and `.phanttom-autoinstall-asked`
consent markers, and `hookPrelude` — the opening of every hook script (the
`phanttom_terminal` emit guard and the 0700 `.phanttom-sessions` directory),
which is one decision for every agent and must not fork between payloads.
Editing it changes both scripts: bump **both** `payloadVersion`s. Each script
itself lives in its own file (`Phanttom*HookScript.swift`) — they are shell
programs, not Swift, and burying them in the merge engines made those hard to
read. A new agent should need a merge core, a hook script, and an `autoSync…`
call — **not** another copy of the file layer.

What deliberately stays per-agent, because it differs for real reasons:

- **Merge core.** Claude has one `settings.json` with nested matcher entries;
  Cursor has flat hooks in `hooks.json` plus a `statusLine` in
  `cli-config.json`. There is no shape both fit.
- **`IntegrationStatus` / `ActionError`.** Claude carries a `legacyInline`
  state and a single `settingsCorrupt`; Cursor has two config files that can
  each be corrupt independently. A union type would be wrong for both, so
  each maps `PhanttomIntegrationSupport.IOError` onto its own vocabulary.
- **The hook script below the shared prelude**: tty resolution (`CLAUDE_PID`
  vs an ancestor walk from `$PPID`), the `CURSOR_AGENT` check, the marker wire
  format, and the JSON each agent expects back. The `phanttom_terminal` guard
  and the session directory are *not* per-agent — they come from
  `PhanttomIntegrationSupport.hookPrelude`.

The launch-time consent ladder is shared too:
`agentIntegrationConsentAllows` in `AppDelegate+Phanttom.swift` takes the
agent's copy plus three closures (the closures exist because the two
integrations are separate types by design, and their marker APIs take a
defaulted `paths:`).

Settings UI is shared: `AgentIntegrationSection` in `PhanttomSettingsView.swift`
renders the caption / Set Up / Update / Remove… chrome once, and each agent
supplies its copy plus three closures. `AgentIntegrationState` is the
normalizing adapter — add an `init` for the new agent's `ActionResult` and the
section works unchanged.

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

**Gotcha — never put `\007` straight after an ST backslash in one printf
format.** `printf '…\033\\\007'` does not emit ST followed by BEL: `printf`
consumes `\\` as an escaped backslash and then prints the *digits* `007` as
literal text, which lands in whatever is reading the tty (the shell prompt,
an agent's input box). The `notification` branch shipped this bug twice.
Emit the BEL from its own `printf '\007'`, and remember the escaping runs
through four layers (Swift literal → shell double quotes → `printf` →
tty). Verify with `od -c`, never by eye —
`sh ~/.claude/phanttom-hook.sh notification` with `resolve_tty` pointed at a
file is the quickest byte-level check.

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

## Security & privacy

The fork adds two things upstream Ghostty does not do: it writes another
tool's configuration, and it can reach the network. Both are worth keeping
honest.

**What leaves the machine.** Only the PR-status lookup, which is on by
default and switchable off (Settings → Sidebar). It runs `gh pr list --head <branch>`
with the user's GitHub credentials, from the tab's working directory, at most
once per 60s per (directory, branch). Nothing else in Phanttom talks to the
network except Sparkle's update check. Prompts, titles, directories, and
branch names are never logged (`Ghostty.logger` calls in Phanttom code carry
no user content) and never persisted beyond the UserDefaults listed under
"Session restore".

**What lands in the window title.** The tab auto-name is the first 56
characters of a session's first prompt, and the title is a real `NSWindow`
title — readable by any app with Screen Recording permission
(`CGWindowListCopyWindowInfo`), by Accessibility clients, and captured in
screenshots, screen shares, and Mission Control. That is the cost of the
feature; the hook keeps it to one prompt per session and emits nothing
outside Phanttom (see the hooks sections above), and a user who wants none of
it can Remove… the integration.

**Marker titles are not authenticated.** `❯` + U+2063 makes the marker
collision-proof against shell prompts, not forgery-proof: any program that
can write to the tty — a `cat` of a crafted file, a remote ssh session — can
emit one, and OSC 9;4 progress the same way. So a row's kind icon, model
badge, name, and even its working/done/attention dot are all
attacker-steerable in a tab running hostile output. They are presentation
only, and must stay that way: **never gate an action on `PhanttomTabState`
identity**. Fields are length-clamped (`maxMarkerFieldLength`) so a forged
title can't blow up a row.

**Untrusted directories.** A tab's pwd is arbitrary. Everything Phanttom does
with it reads files (`GitBranchCache` walks `.git`, parses `HEAD` and the
config as text) rather than running git there. The one exception is the
PR-status lookup, which sets `gh`'s cwd to that directory — hence the opt-in
and the GitHub-remote precondition. `gh` is invoked with an argument array,
never a shell, so branch names containing `;`, `$`, or backticks (all legal
in git refs) cannot inject.

**Config writes.** Agent config is read-modify-written atomically, with a
re-parse guard, unknown keys round-tripped, a timestamped backup first, and
the file's prior mode re-applied afterwards (an atomic write replaces the
file, and `settings.json` can hold credentials). Backups are 0600 and are
deleted on Remove… — a snapshot of a file that once held a token should not
outlive the integration.

**Distribution.** Releases are ad-hoc signed and not notarized (no Apple
Developer Program membership — see PHANTTOM-RELEASING.md), and the shipped
`ReleaseLocal` configuration carries `com.apple.security.cs.disable-library-validation`.
Sparkle protects the *update channel* (HTTPS appcast, EdDSA signature checked
against `SUPublicEDKey`), but after the user's one-time "Open Anyway" nothing
checks the installed bundle: any process running as the user can modify it or
inject a dylib without breaking a signature. Users should know that before
they install a terminal that also writes their agent config. Joining the
Developer Program and notarizing is the fix, and it changes nothing else.

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
