# Phanttom 👻

A fork of [Ghostty](https://github.com/ghostty-org/ghostty) exploring bigger UX/UI
ideas — starting with vertical tabs in a sidebar — while keeping Ghostty's
performance and responsiveness fully intact.

Phanttom is based on a pin of upstream **main** (post-v1.3.1). The name is
"Phantom" with two t's, in the spirit of Ghostty's two t's.

> **Why main and not the v1.3.1 tag:** the macOS 26.4+ SDK changed its `.tbd`
> stub format (`arm64e-macos` targets), which breaks Zig 0.15.2's linker with
> `undefined symbol` errors ([ziglang/zig#31658](https://codeberg.org/ziglang/zig/issues/31658)).
> The fix ships in Zig 0.16.0 — which is what main requires. Once a release tag
> ships requiring Zig 0.16.0+, rebase onto tags as originally planned.

## Why a fork

Upstream closed the vertical tabs request
([discussion #2549](https://github.com/ghostty-org/ghostty/discussions/2549)):
macOS tabs in Ghostty are *native window tabs* (each tab is an `NSWindow` joined
into a tab group), and upstream won't build custom tab chrome. The maintainers
explicitly point people at forks for this — Phanttom is one.

## Architecture cheat sheet

- Terminal emulation, fonts, and GPU (Metal) rendering live in the Zig core,
  consumed by the Swift app as `GhosttyKit.xcframework`. **UI work never touches
  Zig** — performance is inherited, not at risk, as long as we stay in chrome.
- All macOS UI is Swift (AppKit + SwiftUI) under `macos/Sources/`:
  - `Features/Terminal/TerminalController.swift` — one controller per window/tab;
    tabs = `window.tabGroup` / `addTabbedWindow`.
  - `Features/Terminal/Window Styles/` — window chrome variants (titlebar tabs
    etc.). A natural home for a sidebar window style.
  - `Ghostty/` (~11k lines) — the embedding layer: `SurfaceView` owns input, IME,
    scrolling, resize sync. Don't rewrite; don't regress.
  - `TerminalView.swift` — SwiftUI view rendering the `SplitTree` of surfaces.

## Prior art: tomreinert/ghostty (remote `reference-tom`)

His sidebar is ~2.7k lines, almost all new files — study with:
`git fetch reference-tom && git diff phanttom reference-tom/main -- macos`

Mechanics worth knowing:
- Each window's `contentView` becomes an `NSSplitView`: `[sidebar | terminal]`,
  sidebar is an `NSHostingView<SidebarView>` (SwiftUI), width persisted in
  `UserDefaults`, holding priorities keep the terminal dominant on resize.
- `SidebarTabManager` (ObservableObject) publishes `[TabItem]` derived from
  `window.tabbedWindows`; selection = `tabGroup.selectedWindow`.
- Attention indicators hook bell + OSC desktop-notification NSNotifications.
- Wart to improve on: he polls the tab group with a 0.5s `Timer` — KVO/observation
  on `tabGroup.windows` + targeted notifications would be cleaner and cheaper.
- Known upstream-fork bug to avoid: unread indicator doesn't always clear.

## Roadmap

1. **Toolchain**: Xcode 26 (App Store) + Metal toolchain + iOS SDK, and Zig
   **0.16.0** (installed at `~/.local/zig-aarch64-macos-0.16.0`, symlinked as
   `~/.local/bin/zig`). Verify a clean unmodified build first: `zig build` then
   the Xcode project in `macos/`.
2. **Sidebar MVP**: new `Features/Terminal/Sidebar/` — vertical tab list driving
   the native tab group, native tab bar hidden. Keep upstream-file edits minimal.
3. **UI lift**: tab cards (title, cwd, git branch), drag-to-reorder, collapse,
   theme derived from terminal palette, attention dots.
4. **Bigger swings** (single-window ideas, tab overview) only after the MVP —
   these mean rearchitecting `TerminalController` to own multiple surface trees.

## Staying close to upstream

- `main` tracks upstream `main`; work happens on `phanttom` (based on release
  tags). Rebase `phanttom` onto each new release tag, not onto upstream main.
- Keep changes in new files under `Features/`; when an upstream file must
  change, keep the hunk small and obvious.
- Remotes: `upstream` = ghostty-org/ghostty, `reference-tom` = tomreinert/ghostty.
