#!/usr/bin/env bash
# tests/fm-conpty-liveness-live-e2e.test.sh - opt-in Windows guard proving the
# ConPTY backend's foreground liveness source still works against a REAL
# installed harness, on a real ConPTY.
#
# Why this file exists. The verdict this backend gives depends on two things a
# vendor controls: how a harness names its own process, and whether a harness
# writes OSC 133 marks of its own onto the pty stream. Neither can be seen by a
# stubbed agent, and neither can be seen off Windows at all, because there is no
# ConPTY to read. The portable counterpart in tests/fm-backend-conpty.test.sh
# pins the decision table and the mark chain in CI; this guard is the half only a
# real harness on a real console can answer.
#
# It launches each installed harness BARE, with no prompt, so it consumes no
# model tokens. An unauthenticated harness still starts its process, which is all
# the liveness probe reads.
#
# What it asserts, per harness:
#   1. backgrounded, shell idle  -> dead    (the case the console process list
#                                            alone gets wrong: the harness is
#                                            attached but nothing is running it)
#   2. in the foreground         -> alive
#   3. under a NESTED shell      -> the mark chain continues. No firstmate path
#                                   nests any more (the spawn path leases the
#                                   worktree and cds into the session shell),
#                                   but a hand-opened shell must still mark
#   4. no untagged OSC 133 mark on the transcript, which would mean a harness
#      had begun emitting its own and could announce "command finished" while it
#      is alive
#   5. no TAGGED mark either, while the harness holds the foreground. This is
#      the one that matters: the carriers are exported into every descendant of
#      the session shell, so a harness that ran a tool shell as an INTERACTIVE
#      bash whose output reached the pty would emit a correctly tagged `D` while
#      it is alive, and the verdict would flip to dead under a live agent
#
# THE TOKEN-FREE LAUNCH IS A DESIGN CHOICE, AND IT BOUNDS THIS GUARD. Because no
# prompt is ever sent, check 5 catches a harness that marks at STARTUP but not
# one that only marks during a tool call. The structural protection for the
# latter is that a non-interactive `bash -c` runs neither PS0 nor PROMPT_COMMAND,
# and no verified harness runs its tool shells any other way (measured for
# Claude Code 2.1.220: promptMarks did not move across a real Bash tool call).
#
# Run it after any harness upgrade, and before trusting the dated per-harness
# rows in docs/verification/runtime-backends.md "conpty".
#
# NOT YET REGISTERED IN bin/fm-test-run.sh. It belongs in that script's
# `live-harness-optin` family, so its gate skip is expected rather than
# surprising. That one-line classification was deliberately left to the owner of
# the in-flight change to that file rather than edited concurrently; until then
# the runner reports this script as `unclassified`, which still runs it and still
# counts its skip as a success.
set -u

if [ "${FM_CONPTY_LIVENESS_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_CONPTY_LIVENESS_LIVE=1 to run the real-harness ConPTY liveness guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

case "$(uname -s 2>/dev/null || echo unknown)" in
  CYGWIN*|MINGW*|MSYS*|Windows_NT) ;;
  *) echo "skip: not a Windows host, so there is no ConPTY to read"; exit 0 ;;
esac
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

CLIENT="$ROOT/bin/backends/conpty/fmpty.js"
RCFILE="$ROOT/bin/backends/conpty/fm-shell-integration.bash"
[ -f "$CLIENT" ] || fail "conpty client missing at $CLIENT"
[ -f "$RCFILE" ] || fail "shell integration missing at $RCFILE"
node -e 'require("node-pty")' --prefix "$(dirname "$CLIENT")" >/dev/null 2>&1 \
  || (cd "$(dirname "$CLIENT")" && node -e 'require("node-pty")' >/dev/null 2>&1) \
  || { echo "skip: node-pty is not installed in bin/backends/conpty"; exit 0; }

LAB=$(fm_test_tmproot fm-conpty-liveness-live)
STATE="$LAB/state"
mkdir -p "$STATE"
SESSION_SHELL=${FM_BACKEND_CONPTY_SHELL:-C:\\Program Files\\Git\\bin\\bash.exe}

winpath() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }
# Path conversion is disabled for every client call for the same reason
# bin/backends/conpty.sh disables it: MSYS rewrites an argument that merely looks
# like a POSIX path, and `/exit` becomes an absolute Windows path.
fmpty() { MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 node "$(winpath "$CLIENT")" "$@" --state "$(winpath "$STATE")"; }
verdict() { fmpty state --id "$1" --plain 2>/dev/null; }
# The daemon reports its running mark count in the JSON state, which is how a
# harness emitting marks of its own becomes visible without sending it a prompt.
prompt_marks() {  # <id>
  fmpty state --id "$1" 2>/dev/null | sed -n 's/.*"promptMarks":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1
}
type_line() {  # <id> <text>
  fmpty send --id "$1" --text "$2" >/dev/null 2>&1 || fail "send failed for $1"
  fmpty key --id "$1" --key Enter >/dev/null 2>&1 || fail "Enter failed for $1"
}
wait_verdict() {  # <id> <want> <secs> -> 0 when reached
  local id=$1 want=$2 max=$3 i=0
  while [ "$i" -lt "$max" ]; do
    [ "$(verdict "$id")" = "$want" ] && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}
start_session() {  # <id>
  fmpty kill --id "$1" >/dev/null 2>&1 || true
  fmpty spawn --id "$1" --cwd "$(winpath "$LAB")" \
    --cmd "$SESSION_SHELL" --arg --rcfile --arg "$(winpath "$RCFILE")" --arg -i \
    >/dev/null 2>&1 || fail "could not start ConPTY session $1"
  sleep 3
  [ "$(verdict "$1")" = dead ] \
    || fail "a session with nothing running should be dead, got '$(verdict "$1")'"
}

CHECKED=0
for harness in claude codex opencode grok kimi pi cursor-agent muse; do
  command -v "$harness" >/dev/null 2>&1 || {
    echo "note: $harness is not installed here, so it was not checked"
    continue
  }
  id="fmlive-$harness-$$"
  start_session "$id"

  # 1. Backgrounded: attached to the console, but the shell owns the foreground.
  type_line "$id" "$harness >/dev/null 2>&1 &"
  wait_verdict "$id" dead 30 \
    || fail "$harness backgrounded with an idle shell reported '$(verdict "$id")', not dead"

  # 2. Foreground, in a NESTED shell, which is the shape every real task has.
  type_line "$id" 'bash -i'
  sleep 2
  wait_verdict "$id" dead 20 \
    || fail "a nested shell at its own prompt reported '$(verdict "$id")', not dead - the mark chain did not reach it"
  type_line "$id" "$harness"
  wait_verdict "$id" alive 60 \
    || fail "$harness in the foreground of a nested shell reported '$(verdict "$id")', not alive"

  # 3. A live harness must not mark the stream AT ALL while it holds the
  # foreground. A correctly tagged `D` from a harness's own interactive shell
  # would read as "the session returned to its prompt" and turn a live agent
  # into `dead`, which is the one direction that can launch a duplicate agent
  # onto a live worktree. Counted at the moment it first read alive and again
  # after it has settled, so a mark emitted at startup is caught.
  marks_before=$(prompt_marks "$id")
  [ -n "$marks_before" ] || fail "could not read promptMarks for $harness, so this check proved nothing"
  sleep 5
  marks_after=$(prompt_marks "$id")
  [ "$marks_after" = "$marks_before" ] \
    || fail "$harness advanced promptMarks from $marks_before to $marks_after while holding the foreground; it is emitting firstmate-tagged marks of its own and a live agent could read as stopped"
  [ "$(verdict "$id")" = alive ] \
    || fail "$harness stopped reading alive while it was still in the foreground (now '$(verdict "$id")')"

  # 4. No harness may emit an untagged OSC 133 mark of its own.
  tr=$(fmpty state --id "$id" 2>/dev/null | sed -n 's/.*"transcript":"\([^"]*\)".*/\1/p')
  [ -n "$tr" ] || tr="$STATE/$id/transcript.log"
  if [ -f "$tr" ]; then
    stray=$(grep -ao $'\033\]133;[^\a]*' "$tr" 2>/dev/null | grep -vc 'fmpty=1' || true)
    [ "${stray:-0}" -eq 0 ] \
      || fail "$harness emitted $stray OSC 133 mark(s) without firstmate's tag; switch to a private marker"
  fi

  fmpty kill --id "$id" >/dev/null 2>&1 || true
  CHECKED=$((CHECKED + 1))
  pass "conpty liveness against real $harness: backgrounded reads dead, foreground under a nested shell reads alive, and it emits no marks of its own - tagged or untagged - while it holds the foreground"
done

[ "$CHECKED" -gt 0 ] || fail "no verified harness was installed, so this guard proved nothing"
pass "conpty real-harness liveness guard complete ($CHECKED harness(es) checked)"
