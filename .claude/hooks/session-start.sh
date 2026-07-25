#!/bin/bash
# SessionStart hook for Claude Code on the web.
#
# Provisions the Linux toolchain Phanttom/Ghostty needs so that `zig build`,
# `zig build test`, `zig fmt` and the GTK app all work in a cloud session.
# See AGENTS.md ("Claude Code on the web specific instructions") for the
# rationale and for the egress-policy requirement dependency seeding needs.
#
# Safe to re-run: every step is guarded and skips when already satisfied.

set -euo pipefail

# Only provision cloud sessions. Local machines are already set up by the
# developer (and we must never mutate their apt/pip state).
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ZIG_VERSION="0.16.0"
BLUEPRINT_VERSION="0.22.2"
# Marker dir so a re-run (resume/clear/compact) skips the slow apt step.
# Lives in the cache dir so it is writable whether or not we are root.
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/phanttom-session-start"
mkdir -p "$STATE_DIR"

log() { echo "[session-start] $*"; }

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
# The image carries third-party PPAs (deadsnakes, ondrej/php) that are either
# unsigned or blocked by egress policy, so a bare `apt-get update` exits 100.
# Scope the update to Ubuntu's own archive, which is reachable.
apt_update_ubuntu_only() {
  sudo apt-get update -qq \
    -o Dir::Etc::sourcelist="sources.list.d/ubuntu.sources" \
    -o Dir::Etc::sourceparts="-" \
    -o APT::Get::List-Cleanup="0"
}

PACKAGES=(
  build-essential cmake meson ninja-build pkg-config gettext
  libgtk-4-dev libadwaita-1-dev libglib2.0-dev libglib2.0-bin
  libgirepository1.0-dev
  libxkbcommon-dev libx11-dev libxcursor-dev libxext-dev libxi-dev
  libxinerama-dev libxrandr-dev
  libgl1-mesa-dev libegl1-mesa-dev
  libfontconfig-dev libfreetype-dev libharfbuzz-dev libpng-dev zlib1g-dev
  libbz2-dev libexpat1-dev libxml2-dev libonig-dev
  adwaita-icon-theme xvfb
)

if [ ! -f "$STATE_DIR/apt.done" ]; then
  log "installing system packages (GTK4, X11, GL, build tools)..."
  apt_update_ubuntu_only
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    --no-install-recommends "${PACKAGES[@]}"
  touch "$STATE_DIR/apt.done"
  log "system packages installed."
else
  log "system packages already present, skipping."
fi

# ---------------------------------------------------------------------------
# 2. Zig toolchain
# ---------------------------------------------------------------------------
# ziglang.org is blocked by the egress policy, but the official `ziglang` PyPI
# distribution ships the identical upstream toolchain and PyPI is reachable.
ZIG_DIR="$(/usr/local/bin/python3 -c \
  'import os,ziglang; print(os.path.dirname(ziglang.__file__))' 2>/dev/null || true)"

if [ -z "$ZIG_DIR" ] || [ ! -x "$ZIG_DIR/zig" ]; then
  log "installing Zig $ZIG_VERSION from PyPI..."
  sudo /usr/local/bin/python3 -m pip install --quiet --break-system-packages \
    "ziglang==$ZIG_VERSION"
  ZIG_DIR="$(/usr/local/bin/python3 -c \
    'import os,ziglang; print(os.path.dirname(ziglang.__file__))')"
fi

# Expose a plain `zig` on PATH rather than making everyone call the pip path.
sudo ln -sf "$ZIG_DIR/zig" /usr/local/bin/zig
log "zig $("$ZIG_DIR/zig" version) ready at /usr/local/bin/zig"

# ---------------------------------------------------------------------------
# 3. blueprint-compiler (GTK .blp -> .ui)
# ---------------------------------------------------------------------------
# Ghostty needs >= 0.16.0; Ubuntu 24.04 only ships 0.12.0 and gitlab.gnome.org
# is blocked, so install from PyPI. It must run under python3.12: that is the
# interpreter Ubuntu's python3-gi (_gi.cpython-312) is built against, while
# /usr/local/bin/python3 is a 3.11 build that cannot load those bindings.
if ! blueprint-compiler --version >/dev/null 2>&1; then
  log "installing blueprint-compiler $BLUEPRINT_VERSION (python3.12)..."
  sudo /usr/bin/python3.12 -m pip install --quiet --break-system-packages \
    "blueprint-compiler==$BLUEPRINT_VERSION"
fi
log "blueprint-compiler $(blueprint-compiler --version) ready."

# ---------------------------------------------------------------------------
# 4. Seed the Zig package cache
# ---------------------------------------------------------------------------
# Zig's own fetcher cannot use this environment's HTTPS proxy: it issues a
# plain-HTTP request instead of a CONNECT tunnel and the proxy answers 405.
# So we download each dependency with curl (which tunnels correctly) and hand
# the local tarball to `zig fetch`, which stores it in the global cache under
# its content hash. `zig build` then resolves everything offline.
#
# NOTE: `zig fetch` must be run from a directory containing build.zig in
# Zig 0.16, hence the cd into the project root.
seed_dependencies() {
  local urls tmpdir url file failures=0 seeded=0

  # Every build.zig.zon in the tree, including the nested pkg/* manifests.
  mapfile -t urls < <(
    find "$PROJECT_DIR" -name build.zig.zon -not -path "*/zig-out/*" \
      -not -path "*/.zig-cache/*" -exec grep -ho 'https://[^"]*' {} \; \
      | sort -u
  )

  [ "${#urls[@]}" -eq 0 ] && return 0

  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  cd "$PROJECT_DIR"
  for url in "${urls[@]}"; do
    file="$tmpdir/$(basename "$url")"
    if ! curl -fsSL --max-time 180 "$url" -o "$file" 2>/dev/null; then
      failures=$((failures + 1))
      continue
    fi
    if zig fetch "$file" >/dev/null 2>&1; then
      seeded=$((seeded + 1))
    else
      failures=$((failures + 1))
    fi
    rm -f "$file"
  done

  log "seeded $seeded/${#urls[@]} Zig dependencies into the global cache."
  if [ "$failures" -gt 0 ]; then
    cat >&2 <<'WARN'
[session-start] WARNING: some dependencies could not be downloaded.
[session-start] Ghostty fetches every dependency from deps.files.ghostty.org.
[session-start] If that host is not on this environment's allowed-domains list
[session-start] the proxy answers 403 and `zig build` / `zig build test` cannot
[session-start] run. Add deps.files.ghostty.org to the environment's network
[session-start] settings, then start a new session.
[session-start] Linting (zig fmt, prettier) works regardless.
WARN
  fi
}

log "seeding Zig dependencies..."
seed_dependencies || log "dependency seeding hit an error; continuing."

# ---------------------------------------------------------------------------
# 5. Session environment
# ---------------------------------------------------------------------------
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"$ZIG_DIR:\$PATH\""
    # gtk4-layer-shell is not packaged for Ubuntu, so Wayland support cannot
    # build here; X11 (under Xvfb) is what this container can actually run.
    echo "export GHOSTTY_BUILD_FLAGS=\"-Dgtk-wayland=false\""
  } >> "$CLAUDE_ENV_FILE"
fi

log "done."
