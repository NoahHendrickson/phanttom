#!/bin/bash
# (Re)launch the Debug Ghostty/Phanttom app with a clean environment.
#
# Why: bare `open` from Cursor agent shells inherits NO_COLOR=1,
# FORCE_COLOR=0, and TERM=dumb into the app process, which strips color
# from Claude Code and other TUIs. Always use this script (or the same
# env -i pattern) instead of plain `open`.
#
# Quits ONLY com.mitchellh.ghostty.debug — never prod
# (com.mitchellh.ghostty). See .cursor/rules/phanttom-relaunch.mdc.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${ROOT}/build/Debug/Ghostty.app"
BIN="${APP}/Contents/MacOS/ghostty"

if [[ ! -d "$APP" ]]; then
  echo "error: Debug app not found at $APP" >&2
  echo "Build first: macos/build.nu  (or xcodebuild … -configuration Debug)" >&2
  exit 1
fi

osascript -e 'tell application id "com.mitchellh.ghostty.debug" to quit' 2>/dev/null || true

# Wait only for this Debug binary path — never match prod by process name.
for _ in $(seq 1 25); do
  if ! pgrep -f "$BIN" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

env -i \
  HOME="${HOME:?}" \
  USER="${USER:-}" \
  LOGNAME="${LOGNAME:-${USER:-}}" \
  TMPDIR="${TMPDIR:-/tmp}" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  LANG="${LANG:-en_US.UTF-8}" \
  TERM=xterm-256color \
  COLORTERM=truecolor \
  SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}" \
  /usr/bin/open "$APP"

echo "Relaunched Debug: $APP"
