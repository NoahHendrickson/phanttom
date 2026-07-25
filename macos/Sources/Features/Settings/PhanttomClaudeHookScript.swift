import Foundation

/// The Claude Code hook payload installed at `~/.claude/phanttom-hook.sh`.
///
/// Its own file because it is a ~300-line shell program, not Swift: keeping it
/// beside the merge engine buried that engine. The emit guard and the private
/// session directory come from `PhanttomIntegrationSupport.hookPrelude` —
/// every agent makes the same decision there. Everything below it is
/// Claude-specific (the `CLAUDE_PID` tty resolve, the marker wire format, the
/// `background_tasks` re-arm) and deliberately stays here.
///
/// Any edit to this text — or to the shared prelude — must bump
/// `payloadVersion`.
extension PhanttomClaudeIntegration {
    static var hookScript: String {
        """
        #!/bin/sh
        # phanttom-hook v\(payloadVersion)
        # Managed by Phanttom — do not edit; overwritten on Update.
        # No `set -e`: hook processes must never fail the Claude Code call.

        STATE="${HOME}/.claude/phanttom-integration.json"
        \(PhanttomIntegrationSupport.hookPrelude(agentDirName: ".claude"))

        resolve_tty() {
          # Some `ps` variants report a bare `?` (not `??`) for no tty.
          t=$(ps -o tty= -p "${CLAUDE_PID:-$PPID}" 2>/dev/null | tr -d " ")
          case "$t" in ""|"?"|"??") t=/dev/tty;; *) t=/dev/$t;; esac
          printf "%s" "$t"
        }

        # Prefer jq when present; else /usr/bin/perl + JSON::PP (ships with macOS).
        json_get() {
          path="$1"
          if command -v jq >/dev/null 2>&1; then
            case "$path" in
              prompt) jq -r ".prompt // empty" 2>/dev/null ;;
              cwd) jq -r ".cwd // empty" 2>/dev/null ;;
              transcript_path) jq -r ".transcript_path // empty" 2>/dev/null ;;
              session_id) jq -r ".session_id // empty" 2>/dev/null ;;
              model.id) jq -r ".model.id // empty" 2>/dev/null ;;
              model.display_name) jq -r ".model.display_name // empty" 2>/dev/null ;;
              *) jq -r ".$path // empty" 2>/dev/null ;;
            esac
          else
            /usr/bin/perl -MJSON::PP -0777 -e '
              my $path = shift @ARGV;
              my $raw = do { local $/; <STDIN> };
              my $j = eval { decode_json($raw) };
              exit 0 unless $j;
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

        json_get_cwd_uri() {
          if command -v jq >/dev/null 2>&1; then
            jq -r ".cwd // empty | @uri" 2>/dev/null | sed "s|%2F|/|g"
          else
            /usr/bin/perl -MJSON::PP -0777 -e '
              my $raw = do { local $/; <STDIN> };
              my $j = eval { decode_json($raw) };
              exit 0 unless $j && defined $j->{cwd} && !ref($j->{cwd});
              my $s = $j->{cwd};
              # decode_json yields Unicode chars; percent-encode UTF-8 *bytes*
              # (matching jq @uri), so ord() sees octets 0-255 not codepoints.
              utf8::encode($s);
              $s =~ s/([^A-Za-z0-9\\-_.~\\/])/sprintf("%%%02X", ord($1))/ge;
              $s =~ s/%2F/\\//gi;
              print $s;
            ' 2>/dev/null
          fi
        }

        # Count in-flight Claude background_tasks (subagents, background shells).
        # Missing / unparseable / non-array → 0 so pre-2.1.145 Claude Code keeps
        # the old "always clear on Stop" behavior.
        json_background_tasks_len() {
          if command -v jq >/dev/null 2>&1; then
            jq "(.background_tasks // []) | length" 2>/dev/null
          else
            /usr/bin/perl -MJSON::PP -0777 -e '
              my $raw = do { local $/; <STDIN> };
              my $j = eval { decode_json($raw) };
              exit 0 unless $j && ref($j) eq "HASH";
              my $bt = $j->{background_tasks};
              if (!defined $bt) { print 0; exit 0; }
              if (ref($bt) eq "ARRAY") { print scalar(@$bt); exit 0; }
              print 0;
            ' 2>/dev/null
          fi
        }

        emit_osc74() {
          t=$(resolve_tty)
          printf "\\033]9;4;%s;0\\033\\\\" "$1" > "$t" 2>/dev/null || true
        }

        emit_osc7() {
          d=$(json_get_cwd_uri)
          [ -n "$d" ] || return 0
          t=$(resolve_tty)
          printf "\\033]7;file://localhost%s\\033\\\\" "$d" > "$t" 2>/dev/null || true
        }

        emit_prompt_title() {
          j="$1"
          sid=$(printf "%s" "$j" | json_get session_id)
          # Distinct variable name on purpose: sh has no locals, and `d` is the
          # agent cwd in the emit_osc7 path.
          sdir=$(session_dir)
          named=""
          [ -n "$sdir" ] && named="$sdir/named-${sid:-unknown}-${CLAUDE_PID:-$PPID}"
          # Strip control bytes (ESC/BEL/etc.) so a crafted prompt can't inject
          # escape sequences into the OSC 2 title written below. Newlines first
          # become spaces; LC_ALL=C keeps multibyte UTF-8 (0x80+) intact.
          p=$(printf "%s" "$j" | json_get prompt | tr "\\n" " " |
              LC_ALL=C tr -d "[:cntrl:]" | cut -c1-56)
          # Only the session's FIRST prompt names the tab, and only the name is
          # ever consumed — so once a name has been sent, send the marker with
          # an empty prompt field. It still carries kind and model (which is
          # what keeps the row an agent row), and no further prompt text
          # reaches the window title, where screen recording, Accessibility
          # clients, and screenshots can all read it.
          if [ -z "$named" ] || [ -f "$named" ]; then
            p=""
          fi
          tp=$(printf "%s" "$j" | json_get transcript_path)
          m=""
          if [ -n "$tp" ] && [ -f "$tp" ]; then
            if command -v jq >/dev/null 2>&1; then
              m=$(tail -n 200 "$tp" 2>/dev/null | jq -rs '[.[]? | select(.type=="assistant") | .message.model // empty | select(startswith("<") | not)] | last // empty' 2>/dev/null || true)
            else
              m=$(tail -n 200 "$tp" 2>/dev/null | /usr/bin/perl -MJSON::PP -0777 -e '
                my $last = "";
                local $/;
                my $raw = <STDIN>;
                for my $line (split(/\\n/, $raw)) {
                  next unless length $line;
                  my $o = eval { decode_json($line) };
                  next unless $o && ref($o) eq "HASH" && ($o->{type} // "") eq "assistant";
                  my $model = "";
                  if (ref($o->{message}) eq "HASH") { $model = $o->{message}{model} // ""; }
                  next if $model eq "" || ref($model) || $model =~ /^</;
                  $last = $model;
                }
                print $last;
              ' 2>/dev/null || true)
            fi
          fi
          m=$(printf "%s" "$m" | LC_ALL=C tr -d "[:cntrl:]")
          t=$(resolve_tty)
          # Kind-aware marker: ❯⁣.claude⁣<prompt>⁣<model>. An empty prompt
          # field is the model-only form — kind and model still arrive, and
          # the tab keeps the name it already has.
          printf "\\033]2;\\xe2\\x9d\\xaf\\xe2\\x81\\xa3.claude\\xe2\\x81\\xa3%s\\xe2\\x81\\xa3%s\\007" "$p" "$m" > "$t" 2>/dev/null || true
          # Remember that this session has spent its one naming prompt. The
          # explicit `return 0` matters: a failed touch (or a false guard)
          # must never become the hook's exit status.
          if [ -n "$p" ] && [ -n "$named" ]; then
            : > "$named" 2>/dev/null || true
          fi
          return 0
        }

        emit_model_sideband() {
          j="$1"
          m=$(printf "%s" "$j" | json_get model.id)
          if [ -z "$m" ]; then
            m=$(printf "%s" "$j" | json_get model.display_name)
          fi
          m=$(printf "%s" "$m" | LC_ALL=C tr -d "[:cntrl:]")
          sid=$(printf "%s" "$j" | json_get session_id)
          sdir=$(session_dir)
          # No private cache dir → no dedup, just emit every time. Falling back
          # to a shared /tmp path is the symlink hazard this replaced.
          c=""
          [ -n "$sdir" ] && c="$sdir/model-${sid:-unknown}-${CLAUDE_PID:-$PPID}"
          if [ -n "$m" ] && [ "$(cat "$c" 2>/dev/null || true)" != "$m" ]; then
            [ -n "$c" ] && { printf "%s" "$m" > "$c" 2>/dev/null || true; }
            t=$(resolve_tty)
            # Model-only marker: ❯⁣.claude⁣⁣<model>
            printf "\\033]2;\\xe2\\x9d\\xaf\\xe2\\x81\\xa3.claude\\xe2\\x81\\xa3\\xe2\\x81\\xa3%s\\007" "$m" > "$t" 2>/dev/null || true
          fi
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
          name=$(printf "%s" "$j" | json_get model.display_name)
          if [ -z "$name" ]; then
            name=$(printf "%s" "$j" | json_get model.id)
          fi
          cwd=$(printf "%s" "$j" | json_get cwd)
          leaf=$(printf "%s" "$cwd" | sed "s|.*/||")
          if [ -n "$name" ] && [ -n "$leaf" ]; then
            printf "%s · %s\\n" "$name" "$leaf"
          elif [ -n "$name" ]; then
            printf "%s\\n" "$name"
          elif [ -n "$leaf" ]; then
            printf "%s\\n" "$leaf"
          fi
        }

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

        # Every Claude Code session on this machine runs these hooks, not just
        # the ones in Phanttom. Elsewhere the OSC sequences are noise at best
        # and a prompt-text leak into a foreign window title at worst, so emit
        # nothing — but still produce a statusline, since we replaced the
        # user's own command with this dispatch.
        if ! phanttom_terminal; then
          case "$cmd" in
            statusline) run_statusline_chain "$(cat)" ;;
          esac
          exit 0
        fi

        case "$cmd" in
          prompt-submit)
            j=$(cat)
            emit_osc74 3
            emit_prompt_title "$j"
            printf "%s" "$j" | emit_osc7
            ;;
          session-start)
            j=$(cat)
            prune_sessions
            printf "%s" "$j" | emit_osc7
            ;;
          post-tool-use)
            j=$(cat)
            printf "%s" "$j" | emit_osc7
            ;;
          stop)
            # Keep (or re-arm) rain while Claude reports in-flight
            # background_tasks; clear only when the session is truly idle.
            # SubagentStop is intentionally not hooked — clearing there can
            # flash rain off right before the parent wakes.
            j=$(cat)
            n=$(printf "%s" "$j" | json_background_tasks_len)
            if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
              emit_osc74 3
            else
              emit_osc74 0
            fi
            ;;
          subagent-start)
            emit_osc74 3
            ;;
          notification)
            # Clear + BEL (→ Attention). Two printfs on purpose: a trailing
            # `\\007` directly after the ST backslash reads as an escaped
            # backslash plus literal "007" and types those digits into the tty.
            t=$(resolve_tty)
            printf "\\033]9;4;0;0\\033\\\\" > "$t" 2>/dev/null || true
            printf "\\007" > "$t" 2>/dev/null || true
            ;;
          statusline)
            j=$(cat)
            emit_model_sideband "$j"
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
