# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

> **This is the Phanttom fork** (`NoahHendrickson/phanttom`), not upstream
> Ghostty. Read [PHANTTOM.md](PHANTTOM.md) FIRST — it documents the fork's
> architecture (sidebar, settings, agent-tab semantics, Claude Code hooks),
> where all Phanttom code lives, and hard-won gotchas (e.g. never toggle the
> native tab bar). The build/test guidance below is upstream Ghostty's and
> still applies; the Issue and PR Guidelines are the fork's own.

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

Two different repos, two different rules — don't conflate them:

- **The fork — `NoahHendrickson/phanttom`, remote `origin`: creating PRs and
  issues here is the normal, expected workflow.** All changes land through
  fork PRs. Branch from `phanttom`, push to `origin`, then:

  ```sh
  gh pr create --repo NoahHendrickson/phanttom --base phanttom
  ```

- **Upstream — `ghostty-org/ghostty`, remote `upstream`: never create issues
  or PRs there, and never push branches to it.** Upstream's AGENTS.md forbids
  agent-created contributions and we honor that. If something belongs
  upstream, say so and let the user handle it themselves.

(Upstream's own version of this section is an unconditional "never create a
PR". That rule is about *their* repo — it does not apply to the fork, and
tooling or agents reading this file should not treat fork PRs as forbidden.)
