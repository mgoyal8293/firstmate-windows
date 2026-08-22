#!/usr/bin/env bash
# End-user CLI transcript for bin/fm-lock.sh across every verdict the session
# lock can print - the seven `status` verdicts and the six acquisition outcomes.
# Run against two trees (before/after the mechanism move) and diff the output:
# an identical transcript is the behaviour-identical claim, exercised rather
# than compiled.
#
# Usage: lock-cli-matrix.sh <fm-root>
set -u
ROOT=$1
WIN=MINGW64_NT-10.0-26200
A=aaaaaaaa-0000-1111-2222-333333333333
B=bbbbbbbb-0000-1111-2222-333333333333
export FM_SESSION_TOKEN_STALE_AFTER=5

TOP=$(mktemp -d "${TMPDIR:-/tmp}/fm-lockmatrix-XXXXXX")
FAKE="$TOP/fake"; mkdir -p "$FAKE"; cp /bin/sleep "$FAKE/claude"
"$FAKE/claude" 300 & HARNESS=$!
trap 'kill $HARNESS 2>/dev/null; rm -rf "$TOP"' EXIT

new_home() { local h; h=$(mktemp -d "$TOP/home-XXXXXX"); mkdir -p "$h/state"; printf '%s\n' "$h"; }

# status is a read-only inspection: run it in-process.
status() {  # <home> <uname> <token>
  env -u CLAUDE_CODE_SESSION_ID FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" \
    FM_STATE_OVERRIDE="$1/state" FM_PLATFORM_UNAME_OVERRIDE="$2" \
    ${3:+CLAUDE_CODE_SESSION_ID="$3"} \
    bash "$ROOT/bin/fm-lock.sh" status 2>&1
}

# Acquisition must run DETACHED, so the runner's own live harness is not an
# ancestor and the walk genuinely cannot answer - the Windows condition.
acquire() {  # <home> <uname> <token>
  local home=$1 out="$1/o" rc="$1/r" i=0
  rm -f "$out" "$rc"
  env -u CLAUDE_CODE_SESSION_ID FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_PLATFORM_UNAME_OVERRIDE="$2" \
    ${3:+CLAUDE_CODE_SESSION_ID="$3"} OUT="$out" RC="$rc" \
    bash -c 'bash -c "bash \"$0\" > \"$OUT\" 2>&1; printf %s \$? > \"$RC\"" &' \
    "$ROOT/bin/fm-lock.sh"
  while [ "$i" -lt 400 ] && [ ! -s "$rc" ]; do sleep 0.05; i=$((i+1)); done
  printf '%s (exit %s)\n' "$(cat "$out")" "$(cat "$rc")"
}

say() { printf '%-58s | %s\n' "$1" "$2"; }

echo "### fm-lock.sh status verdicts"
h=$(new_home);                                    say "no lock file"                    "$(status "$h" Linux '')"
h=$(new_home); printf '%s\n' $HARNESS > "$h/state/.lock"
                                                  say "live harness pid"                "$(status "$h" Linux '' | sed "s/$HARNESS/<live-harness-pid>/")"
h=$(new_home); printf '%s\n' 999999 > "$h/state/.lock"
                                                  say "dead pid, no token"              "$(status "$h" Linux '')"
h=$(new_home); printf '%s\n' 999999 > "$h/state/.lock"; chmod 000 "$h/state/.lock"
                                                  say "unreadable lock"                 "$(status "$h" Linux '')"
h=$(new_home); printf '%s\n' 999999 > "$h/state/.lock"; printf '%s\n' "$A" > "$h/state/.lock.session"
                                                  say "dead pid, this session's token"  "$(status "$h" "$WIN" "$A")"
                                                  say "dead pid, another session's token" "$(status "$h" "$WIN" "$B")"
touch -d '1 hour ago' "$h/state/.lock.session"
                                                  say "dead pid, token gone stale"      "$(status "$h" "$WIN" "$B")"

echo
echo "### fm-lock.sh acquisition outcomes"
h=$(new_home);                                    say "Windows + token: first acquire"  "$(acquire "$h" "$WIN" "$A")"
                                                  say "  same session again (idempotent)" "$(acquire "$h" "$WIN" "$A")"
                                                  say "  recorded pid is plain numeric" "$(cat "$h/state/.lock")"
                                                  say "  status now reads"              "$(status "$h" "$WIN" "$A")"
                                                  say "concurrent peer session refused" "$(acquire "$h" "$WIN" "$B" | sed "s#$h#<home>#")"
                                                  say "  peer did not overwrite token"  "$(cat "$h/state/.lock.session")"
h=$(new_home);                                    say "Windows, no token at all"        "$(acquire "$h" "$WIN" '')"
h=$(new_home);                                    say "Linux + token: token path inert" "$(acquire "$h" Linux "$A")"
