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
# It also asserts, once rather than per harness, the lease state transition that
# bin/fm-spawn.sh's abort path depends on: a holder-scoped return clears this
# task's own durable lease, and a return naming any other holder does not. That
# one needs a real pool, because a faked treehouse can only confirm whatever the
# fake was written to do, and it is the property that keeps an aborting spawn
# from handing back a slot belonging to another live task.
#
# Run it after any harness upgrade, after a treehouse upgrade, and before
# trusting the dated per-harness rows in docs/verification/runtime-backends.md
# "conpty".
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

# A session daemon holds its state directory open for a moment after the pty
# child is killed, and Windows refuses to remove a directory a live process is
# still sitting in - so the shared reaper printed a "Device or resource busy" it
# could do nothing about, on every run including the passing ones. Retry briefly
# first, then hand back to the shared reaper. This is the extra-teardown hook
# tests/lib.sh documents for exactly this case.
fm_conpty_live_cleanup() {
  local dir i
  for dir in "$LAB" "${LEASE_LAB:-}"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    i=0
    while [ "$i" -lt 15 ]; do
      rm -rf "$dir" 2>/dev/null && break
      i=$((i + 1)); sleep 1
    done
  done
  fm_test_cleanup
}
trap fm_conpty_live_cleanup EXIT INT TERM
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
# The daemon's own explanation of the verdict. Used for synchronisation, so the
# guard never re-implements the harness-name table it exists to check: only the
# daemon knows which attached process it recognised.
why() {  # <id>
  fmpty state --id "$1" 2>/dev/null | sed -n 's/.*"why":"\([^"]*\)".*/\1/p'
}
# Wait until the daemon reports a harness ATTACHED to the console while the
# shell holds the foreground. Without this the backgrounded case is vacuous: the
# session is already `dead` before the harness is launched, so waiting for
# `dead` passes whether or not the harness ever attached.
wait_attached_idle() {  # <id> <secs>
  local i=0
  while [ "$i" -lt "$2" ]; do
    case "$(why "$1")" in *'attached but not in the foreground') return 0 ;; esac
    i=$((i + 1)); sleep 1
  done
  return 1
}
# Wait for the mark counter to pass a baseline, which is how a newly started
# interactive shell announces it armed and reached its OWN prompt. Typing into a
# shell that has not got there yet loses the keystrokes.
wait_marks_above() {  # <id> <baseline> <secs>
  local i=0 now
  while [ "$i" -lt "$3" ]; do
    now=$(prompt_marks "$1")
    if [ -n "$now" ] && [ "$now" -gt "$2" ] 2>/dev/null; then return 0; fi
    i=$((i + 1)); sleep 1
  done
  return 1
}
# Wait until the SESSION SHELL, not some foreground process, is the thing
# consuming keystrokes. A bare Enter at a shell prompt runs the prompt hook and
# advances the mark counter; the same Enter delivered to a foreground TUI does
# not. Measured on claude 2.1.220: three bare Enters at a prompt moved the
# counter 3 -> 6 -> 9 -> 12, and three delivered to the harness in the
# foreground left it at 13.
#
# This is needed because a BACKGROUNDED harness still reads the pty even with
# its output redirected. Measured on the same build, it swallowed the next line
# the case typed and then exited 1, which turned the following assertion into a
# false `dead` on roughly two runs in three.
wait_shell_owns_input() {  # <id> <secs>
  local i=0 base now
  base=$(prompt_marks "$1")
  [ -n "$base" ] || return 1
  while [ "$i" -lt "$2" ]; do
    fmpty key --id "$1" --key Enter >/dev/null 2>&1
    sleep 1
    now=$(prompt_marks "$1")
    if [ -n "$now" ] && [ "$now" -gt "$base" ] 2>/dev/null; then return 0; fi
    i=$((i + 1))
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

# --- the lease transition bin/fm-spawn.sh's abort path depends on -------------
#
# conpty_release_spawn_lease hands a leased slot back when a spawn aborts before
# the task record teardown would read exists, holder-scoped with
# `treehouse return --force --if-lease-holder <holder> <path>`. Two properties of
# REAL treehouse are load-bearing there, and a faked pool can only ever confirm
# what the fake was written to do:
#
#   - a return from the OWNING holder really does clear the durable lease, or the
#     abort leaks a slot with no record left to reclaim it from;
#   - a return from any OTHER holder really does not, or the abort could hand
#     back a slot belonging to another live task, because it locates the slot by
#     holder label rather than by a path it may never have observed.
#
# This asserts the transition, not an immediate reclaim: releasing the lease is
# not the same as freeing the slot, which stays in use until the aborted
# session's own window closes (bin/fm-spawn.sh records that measurement).
#
# The pool is pinned inside the temp root, so this can never reach a real one.
if command -v treehouse >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  LEASE_LAB=$(fm_test_tmproot fm-conpty-lease-transition)
  LEASE_REPO="$LEASE_LAB/repo"

  # THIS FIXTURE MUST NEVER BE ABLE TO TARGET THE CHECKOUT UNDER TEST, and it is
  # written defensively because the obvious form is not safe. Two behaviours
  # combine badly: `set -e` is SUPPRESSED inside a compound command used as the
  # left operand of `||`, so a `( set -e; cd "$dir"; git ... ) || fail` block does
  # NOT abort when the `cd` fails - and every git command after it then runs
  # against the ambient working directory, which is the checkout being tested.
  # A `git add -A && git commit` reached that way commits the tester's own
  # in-progress work to the branch under test, under the fixture's identity.
  #
  # So nothing here relies on `cd` for isolation and nothing lets git choose its
  # own target: the path is validated before use, and the repo is seeded through
  # tests/lib.sh's shared `fm_git_init_commit`, whose every git call is pinned
  # with `-C` and whose identity is passed inline rather than written to any
  # config. That helper is the suite's one owner of fixture commits, so no test
  # hand-rolls a mutating git command that could pick its own target.
  [ -n "$LEASE_REPO" ] && [ "$LEASE_REPO" != /repo ] \
    || fail "the lease fixture got no usable temp path, so it refused to run git rather than risk the checkout under test"
  case "$LEASE_LAB" in
    "$ROOT"|"$ROOT"/*)
      fail "the lease fixture resolved inside the checkout under test ($LEASE_LAB), so it refused to run" ;;
  esac
  fm_git_init_commit "$LEASE_REPO" >/dev/null 2>&1 \
    || fail "could not seed the disposable pool repo at $LEASE_REPO"
  # Assert the outcome rather than each step: treehouse can only lease a slot
  # from a repo that already has a commit.
  git -C "$LEASE_REPO" rev-parse --verify -q HEAD >/dev/null \
    || fail "the disposable pool repo at $LEASE_REPO has no commit, so treehouse could not lease from it"
  # A TOML literal string, so a Windows root needs no backslash escaping.
  printf "max_trees = 1\nroot = '%s'\n" "$(winpath "$LEASE_LAB")" \
    > "$LEASE_REPO/treehouse.toml" || fail "could not write the fixture pool config"

  # The holder recorded against one slot, '' once released, or a marker when the
  # row is gone entirely - which is also 'no longer leased to me'.
  lease_holder_of() {  # <slot-path>
    ( cd "$LEASE_REPO" && treehouse status --json 2>/dev/null ) | node -e '
      let s = "";
      process.stdin.on("data", function (d) { s += d; });
      process.stdin.on("end", function () {
        try {
          const rows = JSON.parse(s);
          const hit = (Array.isArray(rows) ? rows : []).find(function (r) {
            return r && r.path === process.argv[1];
          });
          process.stdout.write(hit ? String(hit.lease_holder || "") : "<row-gone>");
        } catch (e) { process.stdout.write("<unreadable>"); }
      });
    ' "$1"
  }

  LEASE_MINE="firstmate-fmlive-$$"
  LEASE_THEIRS="firstmate-another-task-$$"
  LEASE_SLOT=$( cd "$LEASE_REPO" && treehouse get --lease --lease-holder "$LEASE_MINE" 2>/dev/null )
  [ -n "$LEASE_SLOT" ] \
    || fail "could not lease a slot from the disposable pool, so the lease transition proved nothing"
  held=$(lease_holder_of "$LEASE_SLOT")
  [ "$held" = "$LEASE_MINE" ] \
    || fail "a freshly leased slot recorded holder '$held', not this task's '$LEASE_MINE'"

  ( cd "$LEASE_REPO" && treehouse return --force --if-lease-holder "$LEASE_THEIRS" "$LEASE_SLOT" ) \
    >/dev/null 2>&1 || true
  held=$(lease_holder_of "$LEASE_SLOT")
  [ "$held" = "$LEASE_MINE" ] \
    || fail "a return naming a holder that does not own the lease still changed it to '$held'; an aborting spawn could take a live task's slot"

  ( cd "$LEASE_REPO" && treehouse return --force --if-lease-holder "$LEASE_MINE" "$LEASE_SLOT" ) \
    >/dev/null 2>&1 \
    || fail "the holder-scoped return failed against this task's own lease, so the abort path would leak the slot"
  held=$(lease_holder_of "$LEASE_SLOT")
  case "$held" in
    ''|'<row-gone>') ;;
    *) fail "the durable lease survived a return by its own holder; it is still held by '$held'" ;;
  esac

  pass "conpty spawn abort: against real treehouse $(treehouse --version 2>/dev/null | tr -d 'v\n'), a holder-scoped return clears this task's own durable lease and refuses one it does not own"
else
  echo "note: treehouse or git is missing here, so the spawn-abort lease transition was not checked"
fi

CHECKED=0
for harness in claude codex opencode grok kimi pi cursor-agent muse; do
  command -v "$harness" >/dev/null 2>&1 || {
    echo "note: $harness is not installed here, so it was not checked"
    continue
  }
  id="fmlive-$harness-$$"
  start_session "$id"

  # 1. Backgrounded: attached to the console, but the shell owns the foreground.
  #
  # Wait for the harness to ATTACH before reading the verdict. start_session has
  # already asserted the empty session is `dead`, so waiting only for `dead`
  # would pass without the harness ever starting and would prove nothing - and
  # it is the attached-but-not-foreground reading, not the empty one, that a
  # console-list-only classifier gets wrong.
  type_line "$id" "$harness >/dev/null 2>&1 &"
  wait_attached_idle "$id" 60 \
    || fail "$harness never attached to the console while the shell was idle (daemon says: $(why "$id")), so the backgrounded case proved nothing"
  [ "$(verdict "$id")" = dead ] \
    || fail "$harness backgrounded with an idle shell reported '$(verdict "$id")', not dead"

  # Read that state promptly and do not assume it persists: measured on claude
  # 2.1.220, a backgrounded harness quits within about 25s in every redirection
  # this tried (pty stdin, a pipe that never closes, and /dev/null). Take the
  # keyboard back before typing anything the next case depends on.
  wait_shell_owns_input "$id" 60 \
    || fail "the session shell never took the keyboard back after $harness was backgrounded, so nothing typed after this could be trusted"

  # 2. Foreground, in a NESTED shell, which is the shape every real task has.
  #
  # Synchronise on the nested shell's OWN prompt mark, not on a verdict that is
  # already true. `dead` holds before `bash -i` is even typed, so waiting for it
  # neither proves the mark chain reached the nested shell nor keeps the next
  # line from being typed into a shell that is still starting. Measured on real
  # Windows: it did exactly that, the harness line was swallowed, and the case
  # failed as a false `dead` roughly two runs in three.
  marks_outer=$(prompt_marks "$id")
  [ -n "$marks_outer" ] || fail "could not read promptMarks before nesting, so the nested case could not be synchronised"
  type_line "$id" 'bash -i'
  wait_marks_above "$id" "$marks_outer" 30 \
    || fail "the nested shell never emitted a prompt mark of its own (still $(prompt_marks "$id"), baseline $marks_outer), so the mark chain did not reach it"
  wait_verdict "$id" dead 20 \
    || fail "a nested shell at its own prompt reported '$(verdict "$id")', not dead"
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
