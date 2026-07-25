import Foundation

/// The Cursor Agent CLI hook payload installed at
/// `~/.cursor/phanttom-hook.sh`.
///
/// Its own file for the same reason as `PhanttomClaudeHookScript`: this is a
/// shell program, not Swift. The emit guard and the private session directory
/// come from `PhanttomIntegrationSupport.hookPrelude`; the `CURSOR_AGENT`
/// check, the ancestor tty walk, and the JSON responses Cursor expects are
/// specific to this agent and stay here.
///
/// Any edit to this text — or to the shared prelude — must bump
/// `payloadVersion`.
extension PhanttomCursorIntegration {
    static var hookScript: String {
        """
        #!/bin/sh
        # phanttom-hook v\(payloadVersion)
        # Managed by Phanttom — do not edit; overwritten on Update.
        # No `set -e`: hook processes must never fail the Cursor Agent call.

        STATE="${HOME}/.cursor/phanttom-integration.json"
        \(PhanttomIntegrationSupport.hookPrelude(agentDirName: ".cursor"))

        resolve_tty() {
          # Prefer path stashed by session-start (env injection).
          if [ -n "${PHANTTOM_TTY:-}" ] && [ -e "${PHANTTOM_TTY}" ]; then
            printf "%s" "${PHANTTOM_TTY}"
            return 0
          fi
          # Hook processes themselves often have no controlling tty (`??`).
          # Walk ancestors for a real pty — never fall back to bare /dev/tty
          # (that path is known-broken for hooks and can hit the wrong device
          # when IDE hooks somehow slip through).
          p=${PPID}
          i=0
          while [ "$i" -lt 12 ] && [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ]; do
            t=$(ps -o tty= -p "$p" 2>/dev/null | tr -d " ")
            case "$t" in
              ""|"?"|"??") ;;
              *) printf "/dev/%s" "$t"; return 0 ;;
            esac
            p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d " ")
            i=$((i + 1))
          done
          printf ""
        }

        json_get() {
          path="$1"
          if command -v jq >/dev/null 2>&1; then
            case "$path" in
              model) jq -r ".model // empty" 2>/dev/null ;;
              model_id) jq -r ".model_id // empty" 2>/dev/null ;;
              model.id) jq -r ".model.id // empty" 2>/dev/null ;;
              model.display_name) jq -r ".model.display_name // empty" 2>/dev/null ;;
              prompt) jq -r ".prompt // empty" 2>/dev/null ;;
              cwd) jq -r ".cwd // empty" 2>/dev/null ;;
              session_id) jq -r ".session_id // .conversation_id // empty" 2>/dev/null ;;
              workspace_roots.0) jq -r ".workspace_roots[0] // empty" 2>/dev/null ;;
              *) jq -r ".$path // empty" 2>/dev/null ;;
            esac
          else
            /usr/bin/perl -MJSON::PP -0777 -e '
              my $path = shift @ARGV;
              my $raw = do { local $/; <STDIN> };
              my $j = eval { decode_json($raw) };
              exit 0 unless $j;
              if ($path eq "workspace_roots.0") {
                my $wr = $j->{workspace_roots};
                exit 0 unless ref($wr) eq "ARRAY" && @$wr;
                my $v = $wr->[0];
                exit 0 if !defined $v || ref($v);
                print $v;
                exit 0;
              }
              if ($path eq "session_id") {
                for my $k (qw(session_id conversation_id)) {
                  next unless defined $j->{$k} && !ref($j->{$k});
                  print $j->{$k};
                  exit 0;
                }
                exit 0;
              }
              my @p = split(/\\./, $path);
              my $cur = $j;
              for my $k (@p) {
                if (ref($cur) eq "HASH" && exists $cur->{$k}) { $cur = $cur->{$k}; }
                else { exit 0; }
              }
              exit 0 if !defined $cur || ref($cur);
              print $cur;
            ' "$path" 2>/dev/null
          fi
        }

        uri_encode_path() {
          p="$1"
          if command -v jq >/dev/null 2>&1; then
            printf "%s" "$p" | jq -Rr "@uri" 2>/dev/null | sed "s|%2F|/|g"
          else
            printf "%s" "$p" | /usr/bin/perl -0777 -e '
              my $s = do { local $/; <STDIN> };
              utf8::encode($s);
              $s =~ s/([^A-Za-z0-9\\-_.~\\/])/sprintf("%%%02X", ord($1))/ge;
              $s =~ s/%2F/\\//gi;
              print $s;
            ' 2>/dev/null
          fi
        }

        resolve_cwd() {
          j="$1"
          d=$(printf "%s" "$j" | json_get cwd)
          case "$d" in ""|"."|"null") d="" ;; esac
          if [ -z "$d" ]; then
            d=$(printf "%s" "$j" | json_get workspace_roots.0)
          fi
          if [ -z "$d" ]; then
            d="${CURSOR_PROJECT_DIR:-}"
          fi
          printf "%s" "$d"
        }

        emit_osc74() {
          t=$(resolve_tty)
          [ -n "$t" ] || return 0
          printf "\\033]9;4;%s;0\\033\\\\" "$1" > "$t" 2>/dev/null || true
        }

        emit_osc7_path() {
          d="$1"
          [ -n "$d" ] || return 0
          enc=$(uri_encode_path "$d")
          [ -n "$enc" ] || return 0
          t=$(resolve_tty)
          [ -n "$t" ] || return 0
          printf "\\033]7;file://localhost%s\\033\\\\" "$enc" > "$t" 2>/dev/null || true
        }

        pick_model() {
          j="$1"
          m=$(printf "%s" "$j" | json_get model_id)
          if [ -z "$m" ]; then
            m=$(printf "%s" "$j" | json_get model.id)
          fi
          if [ -z "$m" ]; then
            m=$(printf "%s" "$j" | json_get model.display_name)
          fi
          if [ -z "$m" ]; then
            m=$(printf "%s" "$j" | json_get model)
          fi
          # Skip nested/object leftovers that slipped through as the literal
          # string "null".
          case "$m" in ""|"null") m="" ;; esac
          printf "%s" "$m" | LC_ALL=C tr -d "[:cntrl:]"
        }

        # Model-only marker: ❯⁣.cursor⁣⁣<model>
        emit_model_marker() {
          m="$1"
          [ -n "$m" ] || return 0
          sid="$2"
          # Distinct variable name on purpose: sh has no locals, and callers of
          # this function hold the agent cwd in `d`.
          sdir=$(session_dir)
          # No private cache dir → no dedup, just emit every time. Falling back
          # to a shared /tmp path is the symlink hazard this replaced.
          c=""
          if [ -n "$sdir" ]; then
            # Prefer a stable cache key when the session id is known.
            if [ -n "$sid" ]; then
              c="$sdir/model-${sid}"
            else
              c="$sdir/model-unknown-$$"
            fi
          fi
          if [ -n "$c" ] && [ "$(cat "$c" 2>/dev/null || true)" = "$m" ]; then
            return 0
          fi
          # Resolve the tty BEFORE recording the model as emitted. Caching
          # first would mark this model delivered even when there was no tty
          # to write to, and every later hook would then skip the marker —
          # the badge would never appear for the rest of the session.
          t=$(resolve_tty)
          [ -n "$t" ] || return 0
          [ -n "$c" ] && { printf "%s" "$m" > "$c" 2>/dev/null || true; }
          printf "\\033]2;\\xe2\\x9d\\xaf\\xe2\\x81\\xa3.cursor\\xe2\\x81\\xa3\\xe2\\x81\\xa3%s\\007" "$m" > "$t" 2>/dev/null || true
          return 0
        }

        read_original_statusline() {
          if [ -f "$STATE" ]; then
            if command -v jq >/dev/null 2>&1; then
              jq -r ".originalStatusLine // empty" < "$STATE" 2>/dev/null || true
            else
              /usr/bin/perl -MJSON::PP -0777 -e '
                my $j = eval { decode_json(do { local $/; <STDIN> }) };
                exit 0 unless $j && defined $j->{originalStatusLine} && !ref($j->{originalStatusLine});
                print $j->{originalStatusLine};
              ' < "$STATE" 2>/dev/null || true
            fi
          fi
        }

        default_statusline() {
          j="$1"
          name=$(pick_model "$j")
          cwd=$(resolve_cwd "$j")
          leaf=$(printf "%s" "$cwd" | sed "s|.*/||")
          if [ -n "$name" ] && [ -n "$leaf" ]; then
            printf "%s · %s\\n" "$name" "$leaf"
          elif [ -n "$name" ]; then
            printf "%s\\n" "$name"
          elif [ -n "$leaf" ]; then
            printf "%s\\n" "$leaf"
          fi
        }

        respond_empty() { printf '%s\\n' '{}'; }

        # Chain to the statusline command we replaced (or a minimal default).
        run_statusline_chain() {
          orig=$(read_original_statusline)
          if [ -n "$orig" ]; then
            printf "%s" "$1" | sh -c "$orig"
          else
            default_statusline "$1"
          fi
        }

        cmd="${1:-}"

        # Not a Cursor Agent CLI session (IDE Agent Chat shares this
        # hooks.json), or not running in a Phanttom/Ghostty terminal: emit
        # nothing. The statusline still has to produce the user's own
        # statusline, since we replaced their command with this dispatch.
        if [ "${CURSOR_AGENT:-}" != "1" ] || ! phanttom_terminal; then
          case "$cmd" in
            statusline) run_statusline_chain "$(cat)" ;;
            *) respond_empty ;;
          esac
          exit 0
        fi

        case "$cmd" in
          session-start)
            j=$(cat)
            prune_sessions
            m=$(pick_model "$j")
            sid=$(printf "%s" "$j" | json_get session_id)
            d=$(resolve_cwd "$j")
            tty=$(resolve_tty)
            emit_model_marker "$m" "$sid"
            emit_osc7_path "$d"
            # Stash tty for later hooks via sessionStart env injection.
            if [ -n "$tty" ]; then
              if command -v jq >/dev/null 2>&1; then
                jq -n --arg t "$tty" '{env:{PHANTTOM_TTY:$t}}'
              else
                /usr/bin/perl -MJSON::PP -e '
                  print encode_json({ env => { PHANTTOM_TTY => $ARGV[0] } });
                ' "$tty"
                printf '\\n'
              fi
            else
              respond_empty
            fi
            ;;
          pre-tool-use)
            j=$(cat)
            emit_osc74 3
            m=$(pick_model "$j")
            sid=$(printf "%s" "$j" | json_get session_id)
            emit_model_marker "$m" "$sid"
            d=$(resolve_cwd "$j")
            emit_osc7_path "$d"
            respond_empty
            ;;
          model-update)
            j=$(cat)
            m=$(pick_model "$j")
            sid=$(printf "%s" "$j" | json_get session_id)
            emit_model_marker "$m" "$sid"
            respond_empty
            ;;
          stop)
            # Always clear — Cursor stop has no Claude-style background_tasks.
            cat >/dev/null
            emit_osc74 0
            respond_empty
            ;;
          statusline)
            j=$(cat)
            m=$(pick_model "$j")
            sid=$(printf "%s" "$j" | json_get session_id)
            emit_model_marker "$m" "$sid"
            run_statusline_chain "$j"
            ;;
          *)
            echo "phanttom-hook: unknown command: $cmd" >&2
            exit 1
            ;;
        esac
        """
    }
}
