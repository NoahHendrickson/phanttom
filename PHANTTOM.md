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
  stays on the fork — and PRs *on the fork* (`origin`, base `phanttom`) are
  the normal way changes land, not an exception to that rule. See "Issue and
  PR Guidelines" in AGENTS.md.

## Build & run

```sh
zig build                          # full build incl. macOS app (needs Xcode + Metal toolchain + iOS SDK)
zig build -Demit-macos-app=false -Demit-xcframework=false   # Zig core only, no Xcode needed
zig build test-lib-vt              # fast core tests
open -n macos/build/Debug/Ghostty.app                       # launch the debug app
```

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
| Async git-branch cache (off-main .git/HEAD reads) | `Features/Terminal/Sidebar/GitBranchCache.swift` |
| `[sidebar \| terminal]` split, collapse, width persistence | `Features/Terminal/Sidebar/SidebarSplitView.swift` |
| Window glass (transparency + CGS blur radius) | `Features/Terminal/Sidebar/PhanttomWindowGlass.swift` |
| Titlebar zone tracking sidebar width | `Features/Terminal/Sidebar/PhanttomTitlebarZone.swift` |
| Settings model (UserDefaults + config fragment) | `Features/Settings/PhanttomSettings.swift` |
| Settings UI | `Features/Settings/SettingsView.swift` (replaces upstream's "Coming Soon" placeholder) |
| Settings window host | `Features/Settings/SettingsWindowController.swift` |
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
  "Toggle Sidebar" ⌘B programmatically — MainMenu.xib is untouched).
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

### Sidebar glass

Real see-through glass, not a material overlay: when Glass is on, the window
goes non-opaque (rides upstream's transparency branch in
`TerminalWindow.syncAppearance`) and the blur is a genuine compositor radius
via `CGSSetWindowBackgroundBlurRadius` (same undocumented API upstream uses
for terminal blur; declared via `@_silgen_name` in `PhanttomWindowGlass.swift`).
The terminal surface paints its own opaque background, so only the sidebar's
translucent pixels reveal what's behind. Blur slider = radius 0–40. Caveat:
the radius is per-window, so if the *terminal* also uses transparency, the
terminal's configured blur owns the window.

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

**Status** (leading slot on agent cards, trailing slot on terminal rows):
- `working` (pixel rain) — any surface in the window has an OSC 9;4 progress
  report (agents in non-focused splits count). Indeterminate reports (state 3,
  what the hooks emit) are exempt from upstream's 15s staleness timeout in
  `SurfaceView_AppKit.swift`, so the rain runs for the whole task and stops
  only on an explicit clear (Stop/Notification hooks) or surface close.
- `done` (blue `#2C86F4`) — work finished while the tab was unselected
- `attention` (yellow `#F4BC2C`) — bell rang while unselected (judged against
  the bell window's own tab group)
- selecting a tab clears done/attention
- otherwise-idle tabs show their branch's GitHub PR state: green `#3FB950`
  open, purple `#A371F7` merged (`PRStatusCache`, gh-CLI-backed, 60s
  revalidate; silently absent without gh/auth/PR)
- status lives on `TerminalWindow` (`phanttomTabState`), never in a manager

**Project grouping** (settings toggle "Group tabs by project", default on;
also switchable from the grouping button at the sidebar's right edge of the
titlebar — a mode menu in `PhanttomTitlebarZone`, geometry synced with the
divider):
rows are grouped under a header per project — the repo toplevel of the tab's
pwd, with linked worktrees resolved to their parent repo (`GitBranchCache`
resolves branch + project root in one walk), else the pwd itself for non-git
directories (the home directory renders as "~"). Headers carry a disclosure
chevron (click the header to collapse/expand; state is process-global in
`ProjectCollapseStore` because every window hosts its own sidebar, and
persisted in UserDefaults) and a trailing "+" that opens a new tab in that
project's directory (explicit `SurfaceConfiguration.workingDirectory`, the
window-restoration path). The bottom "New tab" row is project-neutral: it
always opens in the home directory. Grouping is presentation-only in
`SidebarView`: native tab order, animations, and all cross-window state are
untouched. Tabs whose pwd isn't known yet form a trailing header-less
bucket.

**Name priority**: manual rename (upstream's
`BaseTerminalController.titleOverride` — shared with the titlebar, command
palette, and window restoration, so custom names survive restart) → prompt
auto-name (`phanttomTabState.autoTitle`) → title with leading decoration glyphs
stripped. Auto-name comes from a marker title (`❯` + U+2063) and locks to the
**first** prompt of a session; it re-arms when the shell reclaims the title
or via context-menu **Reset Name** (which remembers the consumed title so the
same one isn't immediately re-captured).

## Claude Code integration (hooks protocol)

Installed in the user's `~/.claude/settings.json` (not in this repo — it's
user config; backup kept as `settings.json.bak-phanttom`). Three hooks, all
writing escape sequences to `/dev/tty` (hook stdout is captured by Claude
Code, the tty is not):

| Event | Emits | Phanttom effect |
|---|---|---|
| `UserPromptSubmit` | OSC 9;4 state 3 (indeterminate) | pixel rain starts |
| `UserPromptSubmit` | OSC 2 title `❯⁣ <prompt, 56ch>` — that's `❯` + U+2063 (`\xe2\x9d\xaf\xe2\x81\xa3`), via `jq -r .prompt` | first prompt names the tab |
| `Stop` | OSC 9;4 state 0 (clear) | rain stops → Done if unselected |
| `Notification` | OSC 9;4 clear + BEL | → Attention if unselected |

The U+2063 INVISIBLE SEPARATOR makes the marker collision-proof: a bare "❯"
is the default prompt char of starship/pure/p10k and must NOT trigger
auto-naming (it's treated as a decorated title instead).

Manual test commands (any tab):
`printf '\033]9;4;3;0\033\\'` (rain) · `printf '\033]9;4;0;0\033\\'` (clear) ·
`printf '\a'` (bell) ·
`printf '\033]2;\xe2\x9d\xaf\xe2\x81\xa3 some name\007'` (auto-name).
Tabs can be scripted via AppleScript: `tell application id
"com.mitchellh.ghostty" to new tab in window 1`.

## Settings architecture

Two storage planes, deliberately different:
- **Terminal appearance** (background color/opacity/blur) flows through
  Ghostty's real config system: `PhanttomSettings` writes a managed fragment
  `~/.config/ghostty/phanttom.conf` and triggers `reloadConfig()`. The user's
  main config gets a one-time optional include
  (`config-file = ?phanttom.conf`). Never write the user's own config beyond
  that line.
- **Sidebar appearance** (style/color/opacity/glass/blur/working-indicator
  color) is app-side only: UserDefaults (`Phanttom*` keys), applied instantly
  via SwiftUI.

`Ghostty.App.config` is `@Published`; SwiftUI observes it for theme
reactivity. For the *actual rendered* terminal background, prefer the
surface's `$backgroundColor` (see `SidebarTabManager.terminalBackground`) —
the app-level getter can miss overrides.

## Gotchas for agents

- Deployment target is **macOS 13**: no two-parameter `onChange`, check
  availability before using newer SwiftUI API.
- `Ghostty.SurfaceView` (`macos/Sources/Ghostty/`, ~11k lines) owns input/IME/
  rendering polish — don't rewrite it, don't regress it. UI work should not
  touch `src/` (Zig) at all.
- One `SidebarTabManager` per window: shared state goes on `TerminalWindow`.
- The design source of truth is the Figma file ("Untitled",
  `MgM8y8QIVMfT2zNEbbxz1S`): component set "tab" with variants for
  kind/selection/status. Metrics: rows 255×29 (terminal) / 255×45 (agent),
  8pt padding, 8pt radius, selected `white 8%`, sidebar width 271.
- Rebase policy: rebase `phanttom` onto upstream release tags once one ships
  requiring Zig 0.16+; until then we pin upstream main. Keep upstream-file
  hunks small so rebases stay cheap.
