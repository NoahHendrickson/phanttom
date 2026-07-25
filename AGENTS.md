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
  or PRs there, never push branches to it, never try to get anything merged
  there.** This fork does not contribute back to upstream — not now, not
  later, not via the user. The relationship is strictly one-way: we pull
  upstream in (rebase policy in PHANTTOM.md); nothing ever flows the other
  direction. Don't propose upstreaming a change, don't prepare
  "upstream-ready" patches, don't treat upstream as a target at all.

(Upstream's own version of this section is an unconditional "never create a
PR". That rule is about _their_ repo — it does not apply to the fork, and
tooling or agents reading this file should not treat fork PRs as forbidden.)

## Claude Code on the web specific instructions

Same platform caveat as Cursor Cloud below: the container is **Linux (Ubuntu
24.04, x86_64)**, so the macOS-only Swift in `macos/` cannot be built here.
Unlike Cursor Cloud, **nothing is baked into the image** — the toolchain is
provisioned by the `SessionStart` hook at `.claude/hooks/session-start.sh`
(registered in `.claude/settings.json`). It installs the GTK4/X11/GL apt
stack, Zig 0.16.0, and `blueprint-compiler`, then seeds the Zig package
cache. It is idempotent, so re-running it by hand is safe.

Two environment constraints shape that hook, and both will bite you if you
try to work around them ad hoc:

- **Outbound HTTPS is allowlisted.** `ziglang.org`, `codeberg.org`,
  `gitlab.gnome.org`, `gitlab.freedesktop.org` and `codeload.github.com` all
  answer `403` at the proxy. Zig therefore comes from the official `ziglang`
  **PyPI** distribution and `blueprint-compiler` from **PyPI** (Ubuntu only
  ships 0.12.0; Ghostty needs ≥ 0.16.0), since PyPI is reachable.
- **`deps.files.ghostty.org` must be on the environment's allowed-domains
  list.** Every one of Ghostty's ~39 dependencies — across all 49
  `build.zig.zon` manifests — is fetched from that single host. Without it
  `zig build` and `zig build test` cannot run at all. Linting is unaffected.

Non-obvious gotchas on this container:

- **Zig's fetcher cannot use the proxy.** It issues a plain-HTTP request
  instead of a `CONNECT` tunnel, so `zig build --fetch` fails with
  `bad HTTP response code: '405 Method Not Allowed'` even for allowed hosts.
  This is why the hook downloads each tarball with `curl` and seeds it via
  `zig fetch <file>`; never expect `zig build --fetch` to work directly.
- **`zig fetch` must run from a directory containing `build.zig`.** Run from
  anywhere else it fails with the misleading `no build.zig file found`.
- **`apt-get update` exits 100** because the image carries third-party PPAs
  (deadsnakes, ondrej/php) that are unsigned or blocked. Scope updates to
  Ubuntu's own archive, as the hook does.
- **`blueprint-compiler` must run under `python3.12`.** Ubuntu's `python3-gi`
  ships `_gi.cpython-312`, while `/usr/local/bin/python3` is a 3.11 build and
  fails with `cannot import name '_gi'`.
- **No X server runs by default.** `xvfb` is installed; launch the GUI with
  `xvfb-run ./zig-out/bin/ghostty` (there is no `DISPLAY=:1` here).
- Build with **`-Dgtk-wayland=false`** and lint with
  `zig fmt --check src build.zig build.zig.zon`, for the same reasons given
  in the Cursor Cloud section below.
- Tags are not fetched into this clone, so git version detection falls back
  to `build.zig.zon` and plain `zig build` works. If you ever fetch tags and
  land exactly on one, add `-Dversion-string=1.3.2-dev` (see below).

## Cursor Cloud specific instructions

The Cloud Agent VM is **Linux (Ubuntu 24.04, x86_64)**. Phanttom's own
features are **macOS-only Swift** (`macos/`) and **cannot be built or run
here** — Xcode/Metal/Swift 6 aren't available on Linux. On this VM you can
build/run/test the upstream **GTK Linux app + `ghostty` CLI**, the **Zig
core** (`zig build test`), and **libghostty-vt** (`zig build test-lib-vt`).
Standard commands live in `AGENTS.md` (above), `HACKING.md`, and `PACKAGING.md`.

The startup update script only refreshes Zig build deps
(`zig build --fetch -Dversion-string=1.3.2-dev`). The toolchain is baked into
the VM snapshot: Zig 0.16.0 (`/opt/zig`, on `PATH`), `blueprint-compiler`
0.16.0 built from source into `/usr/local` (Ubuntu's apt only has 0.12.0, but
the build requires ≥0.16.0), and the GTK4/libadwaita/X11/GL apt stack.

Non-obvious gotchas on this VM:

- **Always pass `-Dversion-string=1.3.2-dev`** (or any valid semver) to every
  `zig build …` command. The `phanttom` branch tip currently sits exactly on
  git tag `v1.5.0`, but `build.zig.zon` declares `1.3.2-dev`; the build's git
  version detection then `@panic`s with "tagged releases must be in vX.Y.Z
  format matching build.zig". An explicit `-Dversion-string` bypasses git
  detection and is always accepted. (If future commits move HEAD off the tag,
  plain `zig build` works again and the flag stays harmless.)
- **Build/run/test with `-Dgtk-wayland=false`** (X11 only). `gtk4-layer-shell`
  isn't packaged on Ubuntu, and the default (Wayland-enabled) build fails at
  `translate-c … 'gtk4-layer-shell.h' not found`. Wayland isn't needed here —
  the display is X11 (`DISPLAY=:1`).
- **Run the GUI:** `DISPLAY=:1 ./zig-out/bin/ghostty` (add `-e <cmd>` to run a
  command). GL is software (llvmpipe); the `libEGL … DRI3` warning is harmless.
- **Lint:** `zig fmt --check .` reports failures from the gitignored `zig-pkg/`
  dependency cache after a build. Check the real source with
  `zig fmt --check src build.zig build.zig.zon` (CI runs fmt before fetching,
  so bare `.` is fine there).
- Full `zig build test` is slow — prefer `-Dtest-filter=<name>`.
