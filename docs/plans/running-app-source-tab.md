# Plan: Sidebar indicator for the running app’s source checkout

## Prompt for the implementing agent

```
Implement the v1 plan in docs/plans/running-app-source-tab.md.

Add a small sidebar icon on any tab whose pwd matches the checkout that
built the currently running Phanttom/Ghostty.app binary. Derive sourceRoot
from Bundle.main (strip macos/build/<Config>/Ghostty.app). Gate to
debug-shaped bundles. Prefer longest directory match; do not match on
collapsed projectRoot alone (worktrees). No Zig changes. Follow PHANTTOM.md
and keep the change surgical — TabItem flag + SidebarView icon is enough.
```

---

## Goal

Show a small sidebar cue (icon/badge is enough) when a tab’s checkout is
the source tree that produced the **currently running** Phanttom binary.

This means “this directory built this app,” **not** “this branch is checked
out.” With git worktrees, every tab’s branch is checked out in its own
directory; the useful signal is which checkout produced the running app.

---

## Background (current behavior)

- Agent tabs show directory + branch via `GitBranchCache` /
  `SidebarTabManager` / `SidebarView`.
- Branch comes from each tab’s pwd → `.git/HEAD`.
- Linked worktrees are folded into the parent repo for **project grouping**
  (`projectRoot`). `GitBranchCache.Resolved` already exposes `isWorktree`
  (tested, unused in the UI) for a future worktree glyph — that is a
  **separate** signal from “running app source.” This plan does not require
  consuming `isWorktree`.
- Debug builds land at:
  `<checkout>/macos/build/Debug/Ghostty.app`
  (also `Release` / `ReleaseLocal` configs).

Key files:

| Area | Path |
|---|---|
| Branch / project resolve | `macos/Sources/Features/Terminal/Sidebar/GitBranchCache.swift` |
| Tab model + refresh | `macos/Sources/Features/Terminal/Sidebar/SidebarTabManager.swift` |
| Row UI | `macos/Sources/Features/Terminal/Sidebar/SidebarView.swift` |
| Grouping | `macos/Sources/Features/Terminal/Sidebar/SidebarTabGrouping.swift` |
| Fork architecture | `PHANTTOM.md` |

Pwd per tab (refresh path in `SidebarTabManager`):

```text
surface?.pwd ?? window.representedURL?.path ?? state?.seedDirectory
```

---

## Matching strategy (recommended)

At launch (or once, lazily):

1. Read `Bundle.main.bundleURL`, resolve symlinks.
2. If the path ends with
   `/macos/build/{Debug|Release|ReleaseLocal}/Ghostty.app`,
   strip that suffix → **`sourceRoot`**.
3. On each sidebar refresh, mark tabs whose `directory` best matches that
   root.

**Match rule (longest wins):**

- Prefer `tab.directory == sourceRoot`
- Else `sourceRoot` has prefix `tab.directory + "/"` (tab `cd`’d into a
  subdir of that checkout)
- Normalize with standardized absolute paths / symlink resolution
- If several tabs match, prefer the **longest** `directory` match (one
  clear winner when possible). Marking all matches under that root is an
  acceptable alternative if simpler.

**Do not** match on `tab.projectRoot` alone. Worktrees collapse to the
parent repo in `GitBranchCache`, so parent + worktree would both light up
incorrectly.

If `sourceRoot` can’t be derived (e.g. `/Applications/Ghostty.app`) → show
nothing (fail closed).

---

## Implementation sketch (v1)

| Piece | Where | What |
|---|---|---|
| Resolve once | small helper near `GitBranchCache` or `SidebarTabManager` | `runningAppSourceRoot() -> String?` from `Bundle.main` |
| Tab flag | `TabItem` in `SidebarTabManager.swift` | `isRunningAppSource: Bool` |
| Refresh | same refresh path that sets `gitBranch` / `directory` | compute matches |
| UI | `SidebarView` row (`agentRow`, optionally terminal rows) | tiny icon when true |

No Zig changes. No new git IO beyond what already exists.

### Gating

Show only when at least one of:

- `#if DEBUG` / bundle id ends with `.debug`
- path contains `/macos/build/`
- `Ghostty.info.mode` is debug-ish (same idea as `DebugBuildWarningView`)

Installed Release users should never see a confusing missing/empty marker.

### UI

**v1: icon only** — small play / app / pin glyph next to directory or branch
on matching rows. Lowest clutter.

Optional follow-ons (out of scope for v1):

- Tooltip: “Running app built from this checkout”
- Project-header badge when grouping is on (weaker for worktrees that share
  a group)
- About panel: source path / branch string

---

## Edge cases

| Case | Behavior |
|---|---|
| App from `/Applications` | no `sourceRoot` → no icon |
| Several tabs in same worktree | longest pwd match (or mark all under that root) |
| Main vs worktree | only the checkout that contains the running `macos/build/.../Ghostty.app` matches |
| Running app from tree A, tabs only in B | no icon |
| pwd not ready (`seedDirectory` / nil) | skip until real pwd |
| Stale `macos/build` under another tree | only the **running** bundle path matters |
| Zig-only tree (`-Demit-macos-app=false`) | no app in that tree; no false positive unless an old build dir happens to match the running bundle |

---

## Verification

1. Build + `open -n` from worktree A; open tabs in A and main → only A gets
   the icon.
2. Build from main instead → icon moves.
3. Launch installed app (if available) → no icon.
4. Two tabs both inside the same checkout → longest match wins (or both
   marked, per chosen rule).

---

## Out of scope

- Changing git worktree / branch display semantics
- Upstream Ghostty changes / PRs
- Tracking “which branch is checked out globally” (not meaningful with
  worktrees)
- Showing build identity in About (nice follow-on, not required for v1)
