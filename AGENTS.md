# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

> **This is the Phanttom fork.** Read [PHANTTOM.md](PHANTTOM.md) FIRST — it
> documents the fork's architecture (sidebar, settings, agent-tab semantics,
> Claude Code hooks), where all Phanttom code lives, and hard-won gotchas
> (e.g. never toggle the native tab bar). The rest of this file is upstream
> Ghostty guidance and still applies, including: never create issues or PRs
> against upstream.

## Commands

- **Build:** `zig build`
  - If you're on macOS and don't need to build the macOS app, use
    `-Demit-macos-app=false` to skip building the app bundle and speed up
    compilation.
- **Test (Zig):** `zig build test`
  - Prefer to run targeted tests with `-Dtest-filter` because the full
    test suite is slow to run.
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (Swift)**: `swiftlint lint --strict --fix`
- **Formatting (other)**: `prettier -w .`

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`
- Test: `zig build test-lib-vt -Dtest-filter=<filter>`
  - Prefer this when the change is in a libghostty-vt file
- All C enums in `include/ghostty/vt/` must have a `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`
  sentinel as the last entry to force int enum sizing (pre-C23 portability).

## Directory Structure

- Shared Zig core: `src/`
- macOS app: `macos/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`

## Issue and PR Guidelines

- Never create issues or PRs against upstream Ghostty
  (github.com/ghostty-org/ghostty).
- Issues and PRs against this fork are fine when the user asks for them.
  PRs target the `phanttom` branch unless told otherwise.
