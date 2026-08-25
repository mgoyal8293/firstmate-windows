#!/usr/bin/env bash
# tests/fm-session-start-bound.test.sh - the session-start runtime bound
# (bin/fm-session-start-bound-lib.sh) and how bin/fm-session-start.sh reports a
# truncated startup.
#
# WHY THIS SUITE EXISTS. A session start that hits its bound truncates, and a
# truncated digest has not drained the wake queue and has never printed the
# supervision instructions, so it is a session that looks started and is not
# supervising. Two properties keep that from happening quietly:
#
#   1. The DEFAULT bound is per platform. A subprocess costs about 1 ms on Linux
#      and about 42 ms under MSYS, so one portable number is generous on one
#      platform and marginal on the other. The Windows arm is driven here through
#      FM_PLATFORM_UNAME_OVERRIDE - the same seam bin/fm-proc-lib.sh uses - because
#      that is the only way it is covered by a POSIX CI runner at all.
#   2. A truncation ATTRIBUTES its own time. The banner tells the operator to
#      "report the slow stage", so a banner that names no per-stage time is asking
#      a question it withholds the answer to.
#
# Every case below is written to FAIL if its protection is removed, not merely to
# pass while it is present.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-session-start-bound-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
BOUND_TMP_ROOT=$(fm_test_tmproot fm-session-start-bound-tests)
fm_git_identity fmtest fmtest@example.invalid

# --- hermetic world for the end-to-end cases ---------------------------------
#
# The two cases in section 5 run the REAL bin/fm-session-start.sh, so they need
# the same isolation the rest of the session-start suite uses
# (tests/fm-session-start.test.sh): FM_ROOT_OVERRIDE pointed at a throwaway repo
# and a stubbed PATH. Without both, FM_ROOT falls through to the live checkout,
# so the worktree-tangle and default-branch checks inspect the branch under test,
# and the deferred network stage - which a fresh home reaches, because it
# acquires the lock - detaches a worker making real git and gh calls that outlive
# the case. Only the environment is stubbed; the script itself runs end to end.

# new_world <name>: a real, throwaway git repo on `main` to use as
# FM_ROOT_OVERRIDE, plus an empty FM_HOME and a fakebin.
# Echoes "<root-dir>|<home-dir>|<fakebin>".
new_world() {
  local name=$1 w root home fakebin
  w="$BOUND_TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  fakebin="$w/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$fakebin"
  git init -q -b main "$root" || return 1
  git -C "$root" commit -q --allow-empty -m init || return 1
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

# make_fake_toolchain <fakebin>: every tool the startup detects, present and
# answering, so nothing in the digest depends on what this host happens to have
# installed. Mirrors fm-session-start.test.sh's fixture.
make_fake_toolchain() {
  local fakebin=$1
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi gh treehouse
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
  fm_fake_version_tool "$fakebin" no-mistakes FM_FAKE_NO_MISTAKES_VERSION \
    'no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z'
}

# slow_toolchain <fakebin> <seconds>: add a fixed delay to every stub already in
# <fakebin>, preserving what each one does.
#
# WHY THE TRUNCATION CASES NEED THIS. Three cases below assert what a startup
# prints when it hits its bound, and the smallest bound `timeout` accepts is 1 s.
# Whether a digest against a stubbed toolchain and an empty home takes longer
# than that is a property of the box, not of the code under test - and this
# branch is actively making that digest faster, so the fixture races the very
# improvement it ships beside. Measured here: before this round's dedups the
# digest outlasted 1 s on 6 runs out of 6, after them on 3 out of 6.
#
# A delay on the detection stubs removes the race in the only direction that
# matters: the digest is then reliably longer than its bound, so the banner is
# always the thing under test. It is applied to the detection toolchain only, and
# after it is built, so a case that adds its own stub afterwards - the `rm` and
# `env` recorders below - is not slowed with it.
slow_toolchain() {  # <fakebin> <seconds>
  local fakebin=$1 delay=$2 tool
  for tool in "$fakebin"/*; do
    [ -f "$tool" ] || continue
    { printf '#!/bin/sh\n'; printf 'sleep %s\n' "$delay"; tail -n +2 "$tool"; } > "$tool.slow" || return 1
    mv "$tool.slow" "$tool" || return 1
    chmod +x "$tool" || return 1
  done
}

# run_session_start <home> <root> <fakebin> - drops every harness env marker so a
# local claude/pi/grok session cannot leak into the fixture, exactly as
# tests/fm-session-start.test.sh does.
run_session_start() {
  local home=$1 root=$2 fakebin=$3
  shift 3
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" \
    "$@" bash "$ROOT/bin/fm-session-start.sh" 2>&1
}

# --- 1. the platform arm on the default bound --------------------------------

test_windows_platforms_raise_the_default_bound() {
  local plat got portable
  portable=$(FM_PLATFORM_UNAME_OVERRIDE=Linux fm_session_start_default_budget)
  [ "$portable" = 120 ] || fail "portable default must stay 120s, got '$portable'"
  for plat in MINGW64_NT-10.0-22631 MINGW32_NT-6.2 MSYS_NT-10.0-19045 CYGWIN_NT-10.0; do
    got=$(FM_PLATFORM_UNAME_OVERRIDE="$plat" fm_session_start_default_budget)
    # Asserted as a RELATION, not just a literal: the defect being prevented is a
    # Windows session inheriting the portable bound, so equality is the failure.
    [ "$got" -gt "$portable" ] \
      || fail "uname -s '$plat' must raise the default above the portable ${portable}s, got '$got'"
    [ "$got" = 300 ] || fail "uname -s '$plat' must resolve to 300s, got '$got'"
  done
  pass "fm_session_start_default_budget: MINGW/MSYS/CYGWIN raise the default bound above the portable 120s"
}

test_non_windows_platforms_keep_the_portable_bound() {
  local plat got
  for plat in Linux Darwin FreeBSD SunOS unknown; do
    got=$(FM_PLATFORM_UNAME_OVERRIDE="$plat" fm_session_start_default_budget)
    [ "$got" = 120 ] \
      || fail "uname -s '$plat' must keep the portable 120s default, got '$got'"
  done
  pass "fm_session_start_default_budget: non-Windows platforms keep the portable 120s default"
}

# --- a real terminal, for the one branch that is defined by having one --------
#
# fm_session_start_hook_context answers `none` on `[ -t 2 ]`, so the only honest
# way to cover that branch is to give it a terminal. An env flag standing in for
# the predicate would test the flag and leave the predicate unproven, which is
# how a branch ships unexercised.
#
# `script -qec` is the portable pty allocator here; the case that uses it skips
# with a printed note when it is absent rather than passing quietly.

fm_test_have_pty() {
  command -v script >/dev/null 2>&1 || return 1
  script -qec true /dev/null >/dev/null 2>&1
}

# Run <snippet> with bin/fm-session-start-bound-lib.sh sourced and a pty on all
# three descriptors, printing its first output line. The \r a pty adds is
# stripped, so the caller compares plain numbers.
fm_test_on_pty() {  # <shell-snippet>
  local out
  out=$(script -qec "bash -c '. \"$ROOT/bin/fm-session-start-bound-lib.sh\"; $1'" /dev/null 2>/dev/null) \
    || return 1
  printf '%s\n' "$out" | tr -d '\r' | sed -n '1p'
}

# --- 2. precedence, and the fallback that is silent on Linux -----------------

test_explicit_timeout_wins_on_every_platform() {
  local got
  got=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0 fm_session_start_resolve_budget 45)
  [ "$got" = 45 ] || fail "an explicit 45s must win over the Windows default, got '$got'"
  got=$(FM_PLATFORM_UNAME_OVERRIDE=Linux fm_session_start_resolve_budget 45)
  [ "$got" = 45 ] || fail "an explicit 45s must win over the portable default, got '$got'"
  # The raised default must not become a floor: an operator lowering the bound
  # deliberately (a fast probe, a test) must still get the value they asked for.
  got=$(FM_PLATFORM_UNAME_OVERRIDE=MSYS_NT-10.0 fm_session_start_resolve_budget 5)
  [ "$got" = 5 ] || fail "an explicit bound BELOW the Windows default must still win, got '$got'"
  pass "fm_session_start_resolve_budget: an explicit FM_SESSION_START_TIMEOUT wins on every platform, including below the raised default"
}

test_unusable_explicit_bound_falls_back_to_the_platform_default() {
  local bad got
  # `timeout 0` and the perl fallback's `alarm 0` DISABLE the deadline, so 0 and
  # any non-numeric value must resolve to a real bound, and specifically to THIS
  # platform's bound. Falling back to a portable constant is invisible on Linux
  # and silently costs a Windows session the raised bound it needs, so the
  # Windows arm is what this case actually pins.
  # The padded spellings are here because "not the character 0" is not the same
  # question as "not numerically zero", and only the second one is safe. `00` and
  # `000` are all digits and are not the string `0`, so a digits-only guard passes
  # them straight through - and `timeout 00 sleep 2` exits 0 after the full two
  # seconds instead of 124, so the deadline is not merely wrong, it is ABSENT.
  # The digest then runs unbounded: a wedged startup never truncates, never names
  # a stage and never prints the banner, which is the same silent
  # non-supervision this whole suite exists to prevent.
  for bad in '' 0 00 000 0000 abc 12x ' ' -30 30.5 ' 0'; do
    got=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0 fm_session_start_resolve_budget "$bad")
    [ "$got" = 300 ] \
      || fail "unusable bound '$bad' on MINGW must fall back to the 300s platform default, got '$got'"
    got=$(FM_PLATFORM_UNAME_OVERRIDE=Linux fm_session_start_resolve_budget "$bad")
    [ "$got" = 120 ] \
      || fail "unusable bound '$bad' on Linux must fall back to the 120s platform default, got '$got'"
  done
  pass "fm_session_start_resolve_budget: an unusable bound - including every zero-padded spelling of zero - falls back to the PLATFORM default, never to a portable constant"
}

# The whole point of rejecting a zero bound is that the resulting number is
# handed to a real deadline, so this case asserts the deadline rather than the
# string: `timeout <resolved> sleep ...` must actually kill, whereas the
# unresolved value does not. That closes the loop the string comparison above
# leaves open - a resolver could return a plausible-looking value that `timeout`
# still treats as "no deadline".
test_a_zero_padded_bound_still_produces_a_deadline_that_bites() {
  local resolved rc
  # First the observation this case is built on: the raw value disables the
  # deadline outright. Asserted, not assumed, so a `timeout` that later starts
  # rejecting `00` turns this into a visible skip rather than a silent pass.
  timeout 00 sleep 0.6 >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] \
    || fail "this case assumes 'timeout 00' runs to completion unbounded (rc 0); this timeout returned $rc, so the hazard it guards has changed shape"
  resolved=$(FM_PLATFORM_UNAME_OVERRIDE=Linux fm_session_start_resolve_budget 00)
  # The resolved bound is a real deadline: a command that outlives it is killed
  # and reports 124, which is the exit status bin/fm-session-start.sh keys its
  # STARTUP TRUNCATED banner on.
  timeout "$resolved" true >/dev/null 2>&1 \
    || fail "the resolved bound '${resolved}' was not even accepted by timeout"
  timeout 1 sleep 5 >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 124 ] \
    || fail "this box's timeout does not report 124 on expiry (got $rc), so the truncation contract cannot be checked here"
  pass "fm_session_start_resolve_budget: a zero-padded bound resolves to a value timeout enforces (${resolved}s), not to the absent deadline the raw value produces"
}

# --- 2b. the clamp is scoped to the paths the harness ceiling governs --------
#
# The ceiling exists because the harness kills the hook process. That premise
# holds under a hook and nowhere else, so the clamp is skipped on a POSITIVELY
# established direct run - the operator's own rerun, which the truncation banner
# itself prescribes, must be allowed the time they asked for.
#
# The asymmetry is the whole design and each branch below is one leg of it: a
# wrong "hook" costs recoverable bound, a wrong "not a hook" costs the banner
# entirely. So `undetermined` clamps.
test_the_clamp_follows_hook_context_and_undetermined_clamps() {
  local cap got ctx
  # THE CEILING IS DERIVED ON THE ARM THE ASSERTIONS NAME. The nesting margin is
  # per platform and resolved through the same call-time override as the budget,
  # so a ceiling taken in the suite's own shell is the HOST's, and comparing a
  # MINGW resolve against it would be checking a number that arm never uses -
  # which is what these cases silently did while the margin was a source-time
  # constant.
  cap=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0 fm_session_start_hook_ceiling) \
    || fail "no harness ceiling could be derived from this checkout, so none of the clamp branches below mean anything"

  # (a) POSITIVELY under a hook: the marker bin/fm-sessionstart-run.sh exports.
  ctx=$(FM_SESSION_START_UNDER_HOOK=1 fm_session_start_hook_context)
  [ "$ctx" = binds ] \
    || fail "the wrapper's marker must positively establish that a deadline binds, got '$ctx'"
  got=$(FM_SESSION_START_UNDER_HOOK=1 FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0 \
    fm_session_start_resolve_budget "$((cap * 10))")
  [ "$got" -eq "$cap" ] \
    || fail "under a registered hook an over-ceiling bound must clamp to ${cap}s, got ${got}s"
  # The Windows arm's ceiling must be STRICTLY below the host's, or the margin is
  # not per platform at all and the override above proved nothing.
  [ "$cap" -lt "$(fm_session_start_hook_ceiling)" ] \
    || fail "the MINGW ceiling ${cap}s is not below the host's $(fm_session_start_hook_ceiling)s: the platform override is not reaching the nesting margin, so every MINGW assertion here is checking the host's number"

  # (b) THE SAFETY PROPERTY. Hook context cannot be established either way - no
  # marker, and stderr is not a terminal because this assertion redirects it -
  # and that MUST clamp. Honouring the value here is what reintroduces the
  # silent kill, because "not a hook" was never established.
  ctx=$(FM_SESSION_START_UNDER_HOOK='' fm_session_start_hook_context 2>/dev/null)
  [ "$ctx" = undetermined ] \
    || fail "with no marker and no terminal on stderr the context must be 'undetermined', got '$ctx'"
  got=$(FM_SESSION_START_UNDER_HOOK='' FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0 \
    fm_session_start_resolve_budget "$((cap * 10))" 2>/dev/null)
  [ "$got" -eq "$cap" ] \
    || fail "an UNDETERMINED hook context must fall to the safe side and clamp to ${cap}s, got ${got}s: an unprovable 'not under a hook' hands back a bound the harness kills with no banner at all"

  # (c) POSITIVELY a direct run: stderr is a terminal. Faked with a pty rather
  # than with an env flag, so the real `[ -t 2 ]` predicate is what answers.
  if fm_test_have_pty; then
    ctx=$(fm_test_on_pty 'fm_session_start_hook_context')
    [ "$ctx" = none ] \
      || fail "with a terminal on stderr and no hook marker nothing kills this run on a clock, so the context must be 'none', got '$ctx'"
    got=$(fm_test_on_pty "FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0 fm_session_start_resolve_budget $((cap * 10))")
    [ "$got" -eq "$((cap * 10))" ] \
      || fail "a positively established direct run must be honoured IN FULL ($((cap * 10))s), got ${got}s: the operator's own rerun is the remedy the truncation banner prescribes and nothing kills it at the hook timeout"
  else
    printf 'note: no pty allocator (script/python3) on this box, so the direct-run branch is unverified here\n' >&2
  fi
  pass "fm_session_start_resolve_budget: clamps under a hook AND when hook context is undetermined, and honours a positively established direct run in full"
}

# --- 2b-ii. a transport that arms no deadline is not clamped by someone else's -
#
# The clamp exists because something kills this process at a deadline. That
# premise is per TRANSPORT, not per "is this a hook", and the Pi run tier is
# where the two came apart: .pi/extensions/fm-primary-turnend-guard.ts spawns
# bin/fm-sessionstart-run.sh with no timeout option, no AbortSignal, no
# setTimeout and no child.kill - it truncates on BYTES at 512 KiB and resolves on
# `close`. Nothing ends a Pi session start on a clock.
#
# Under the old predicate that run answered "hook", was clamped to a ceiling
# derived entirely from the Claude, Codex and Cursor registrations, and was told
# a kill second that does not exist there - with a remedy pointing at
# registrations that would not have bought it one second.
#
# The declaration is what is exercised here, through the same env variable the
# extension sets at its own spawn site.
test_a_transport_that_arms_no_deadline_is_honoured_in_full() {
  local cap raised got remedy advisory
  cap=$(fm_session_start_hook_ceiling) \
    || fail "no harness ceiling could be derived, so there is no clamp for this case to be exempt from"
  raised=$((cap * 2))

  # THE GUARD. A transport that positively declares no deadline gets the bound it
  # asked for, even though the marker says it is a hook and other harnesses have
  # registered timeouts.
  got=$(FM_SESSION_START_UNDER_HOOK=1 FM_SESSION_START_HOOK_DEADLINE=none \
    fm_session_start_resolve_budget "$raised" 2>/dev/null)
  [ "$got" -eq "$raised" ] \
    || fail "a transport that arms no deadline was clamped from ${raised}s to ${got}s by a ceiling derived from registrations belonging to harnesses that are not running"

  # And the same run WITHOUT the declaration must clamp, or the case above proves
  # nothing about the declaration.
  got=$(FM_SESSION_START_UNDER_HOOK=1 fm_session_start_resolve_budget "$raised" 2>/dev/null)
  [ "$got" -eq "$cap" ] \
    || fail "without the no-deadline declaration the same bound was expected to clamp to ${cap}s, got ${got}s, so this case is not exercising the exemption"

  # The remedy must not name a ceiling the running transport does not enforce.
  # Telling a Pi operator to raise Claude's registration is worse than silence:
  # it spends their next move on an edit that cannot help.
  remedy=$(FM_SESSION_START_UNDER_HOOK=1 FM_SESSION_START_HOOK_DEADLINE=none \
    fm_session_start_bound_remedy "$raised" 2>/dev/null)
  case "$remedy" in
    *"at most ${cap}s"*|*"harness ceiling"*|*'SessionStart timeouts in the harness registrations'*)
      fail "the truncation remedy quoted a harness ceiling to a transport that arms no deadline, so it points the operator at registrations that cannot buy it a second: $remedy" ;;
  esac
  case "$remedy" in
    *'raise FM_SESSION_START_TIMEOUT'*) : ;;
    *) fail "a run nothing kills on a clock must still be told it can raise its own bound, got: $remedy" ;;
  esac

  # And no clamp advisory, because nothing was clamped.
  advisory=$(FM_SESSION_START_UNDER_HOOK=1 FM_SESSION_START_HOOK_DEADLINE=none \
    fm_session_start_budget_advisory "$raised" "$raised" 2>/dev/null)
  [ -z "$advisory" ] \
    || fail "an unclamped run produced a clamp advisory: $advisory"

  pass "fm_session_start_resolve_budget: a transport declaring no kill deadline keeps its full ${raised}s bound and is never pointed at another harness's registrations"
}

# --- 2c. an unreadable registration set caps too, it does not release --------
#
# The ceiling used to be consulted with `&&`, so a deployment where no
# registration could be READ - a bin-only install with no .claude/.codex/.cursor
# beside the library, or a box with no awk - short-circuited straight past the
# clamp and handed the operator's explicit bound back in full. That is the same
# outcome as a wrong "not a hook", which the case above proves is the one
# inference that must never be made: a bound above a hook timeout, killed with no
# banner at all. The uncertainty is identical, so the resolution has to be.
#
# The deployment is reproduced rather than described: FM_SESSION_START_REGISTRATION_ROOT
# points the library's own discovery glob at a directory with nothing in it, so
# the real derivation runs and really finds nothing.
test_an_unreadable_registration_set_caps_rather_than_releasing() {
  local empty windows got out
  empty=$(fm_test_tmproot fm-session-start-bound-bin-only) \
    || fail "could not create a temp root"
  # The premise, asserted rather than assumed: if a ceiling could still be
  # derived here, every assertion below would be checking the ordinary clamp.
  if FM_SESSION_START_REGISTRATION_ROOT="$empty" fm_session_start_hook_ceiling >/dev/null 2>&1; then
    fail "a registration root holding no registrations still yielded a ceiling, so this case is not exercising the unreadable path"
  fi
  windows=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0 fm_session_start_default_budget)

  # THE GUARD. Under a hook, with nothing readable to bound it by, an explicit
  # bound above the platform default must fall CLOSED to that default.
  got=$(FM_SESSION_START_UNDER_HOOK=1 FM_SESSION_START_REGISTRATION_ROOT="$empty" \
    FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0 \
    fm_session_start_resolve_budget "$((windows * 10))")
  [ "$got" -eq "$windows" ] \
    || fail "with no readable registration an over-default bound must fall back to the ${windows}s platform default, got ${got}s: honouring it in full is the same silent kill a wrong 'not a hook' produces"
  # And the same on an UNDETERMINED context, which is the safe side everywhere
  # else in this file.
  got=$(FM_SESSION_START_UNDER_HOOK='' FM_SESSION_START_REGISTRATION_ROOT="$empty" \
    FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0 \
    fm_session_start_resolve_budget "$((windows * 10))" 2>/dev/null)
  [ "$got" -eq "$windows" ] \
    || fail "an undetermined context with no readable registration must also fall back to the ${windows}s platform default, got ${got}s"

  # Failing closed must not become a floor: a value the platform default already
  # covers is still the operator's to choose.
  got=$(FM_SESSION_START_UNDER_HOOK=1 FM_SESSION_START_REGISTRATION_ROOT="$empty" \
    FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0 fm_session_start_resolve_budget 45)
  [ "$got" -eq 45 ] \
    || fail "a bound below the platform default must still be honoured exactly when no registration can be read, got ${got}s"

  # Nor may it cap a POSITIVELY established direct run: nothing kills that
  # process at a hook timeout, so there is no deadline to fail closed against.
  if fm_test_have_pty; then
    got=$(fm_test_on_pty "FM_SESSION_START_REGISTRATION_ROOT='$empty' fm_session_start_resolve_budget $((windows * 10))")
    [ "$got" -eq "$((windows * 10))" ] \
      || fail "a direct run must still be honoured in full when no registration can be read, got ${got}s"
  else
    printf 'note: no pty allocator on this box, so the direct-run leg of the unreadable-registration case is unverified here\n' >&2
  fi

  # And the operator must not be told a harness deadline this shell never read.
  # The clamp is real, so it is announced; the second it would be killed at is
  # not known here, so no number is invented for it.
  out=$(FM_SESSION_START_REGISTRATION_ROOT="$empty" FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0 \
    fm_session_start_budget_advisory "$((windows * 10))" "$windows" binds)
  assert_contains "$out" 'CLAMPED' \
    'a bound clamped by the platform default is still a clamp and must say so'
  printf '%s\n' "$out" | grep -q 'killed by the harness after' \
    && fail "the advisory quoted a harness kill deadline while no registration could be read, so the number is invented: $out"
  pass "fm_session_start_resolve_budget: an unreadable registration set falls back to the ${windows}s platform default instead of releasing the bound, and the advisory invents no harness deadline"
}

# --- 2d. the detached worker's window is the digest's bound, not its own ------
#
# bin/fm-startup-network.sh keeps offering its result for inline delivery for
# exactly as long as the digest could still be running. It is a DETACHED worker
# with stdio on /dev/null, so `[ -t 2 ]` is false inside it and its hook context
# can never be `direct` - which means re-resolving FM_SESSION_START_TIMEOUT there
# reproduces the CLAMP rather than the digest's bound. On a terminal rerun above
# the ceiling the digest gets the value asked for and the worker would stop
# delivering inline at the ceiling, silently, for the rest of the run.
#
# The worker's own context is reproduced here rather than described: every resolve
# below runs with no hook marker and with stderr redirected away from any
# terminal, which is exactly what `undetermined` means and exactly what the worker
# sees.
test_the_delivery_bound_follows_the_digest_and_not_the_workers_own_context() {
  local cap raised worker digest
  cap=$(fm_session_start_hook_ceiling) \
    || fail "no harness ceiling could be derived, so there is no clamp for the worker to diverge by"
  raised=$((cap * 2))

  # THE GUARD. The digest resolved ${raised}s and exported it; the worker must
  # use that, not the ${cap}s its own context would re-derive.
  worker=$(FM_SESSION_START_UNDER_HOOK='' FM_SESSION_START_RESOLVED_BOUND="$raised" \
    fm_session_start_delivery_bound "$raised" 2>/dev/null)
  [ "$worker" -eq "$raised" ] \
    || fail "the detached worker resolved ${worker}s while the digest is bounded at ${raised}s: from ${worker}s to ${raised}s the digest is still running and the worker has stopped offering inline delivery, so the result arrives as a durable wake instead of in the digest the operator is waiting on"

  # And the two really would have disagreed without it, or the case above proves
  # nothing: the worker's own context clamps.
  digest=$(FM_SESSION_START_UNDER_HOOK='' fm_session_start_resolve_budget "$raised" 2>/dev/null)
  [ "$digest" -eq "$cap" ] \
    || fail "the worker's own context was expected to clamp ${raised}s to ${cap}s, got ${digest}s, so this case is not reproducing the divergence it guards"

  # A worker running standalone has no digest to inherit from and must still
  # resolve a usable bound rather than none.
  worker=$(FM_SESSION_START_UNDER_HOOK='' FM_SESSION_START_RESOLVED_BOUND='' \
    fm_session_start_delivery_bound 45 2>/dev/null)
  [ "$worker" -eq 45 ] \
    || fail "with nothing inherited the worker must resolve its own bound, got ${worker}s"

  # An inherited value that is not a usable bound is not preferred over one this
  # shell can derive: `timeout 0` and every zero-padded spelling of it disable the
  # deadline outright.
  local bad
  for bad in 0 00 000 abc -5 ' '; do
    worker=$(FM_SESSION_START_UNDER_HOOK='' FM_SESSION_START_RESOLVED_BOUND="$bad" \
      fm_session_start_delivery_bound 45 2>/dev/null)
    [ "$worker" -eq 45 ] \
      || fail "an unusable inherited bound '$bad' must fall back to a real resolution, got ${worker}s"
  done
  pass "fm_session_start_delivery_bound: a detached worker uses the ${raised}s bound the digest resolved rather than the ${cap}s its own context would clamp to"
}

# --- 2e. the binder's outputs are all defined, on every path ------------------
#
# fm_session_start_bind_budget returns THREE values through variables rather than
# through stdout, and bin/fm-session-start.sh reads all three under `set -u`. A
# path that returns early without defining one is therefore not a missing
# optimisation, it is an unbound-variable abort before the bounded child is even
# forked - on the DEFAULT path, which is every ordinary session start.
#
# That is a regression this suite caught rather than a hypothetical: threading the
# hook context through to the advisory bound it only on the clamped path, and the
# default path then aborted. Asserted by running a real `set -u` shell that reads
# every one of them, which is exactly what the caller does.
test_the_binder_defines_every_value_it_returns_on_every_path() {
  local out rc arg
  for arg in '' 0 00 abc 45 9999; do
    out=$(FM_SESSION_START_UNDER_HOOK=1 bash -u -c '
      . "$1"
      fm_session_start_bind_budget "$2"
      printf "%s|%s|%s\n" "$FM_SESSION_START_BOUND" "$FM_SESSION_START_CAP" "$FM_SESSION_START_CONTEXT"
    ' _ "$ROOT/bin/fm-session-start-bound-lib.sh" "$arg" 2>&1)
    rc=$?
    [ "$rc" -eq 0 ] \
      || fail "fm_session_start_bind_budget '$arg' left one of its return values undefined, so a caller running under 'set -u' aborts before forking the bounded child: $out"
    case "$out" in
      [0-9]*'|'*'|'*) : ;;
      *) fail "fm_session_start_bind_budget '$arg' did not return a usable bound, got: $out" ;;
    esac
  done
  pass "fm_session_start_bind_budget: every path defines all three return values, so a 'set -u' caller never aborts on one it did not set"
}

# --- 2f. the banner never states a kill second that was never established -----
#
# The clamp under `undetermined` is an accepted decision and is NOT what this
# covers - it stays. What this covers is the WORDING. On `undetermined` the
# library has not established that anything kills this run, so the remedy must
# not print "the harness kills this hook after Ns" as fact.
#
# Reachable on shipped tiers: the nudge-tier transports ask the agent to run
# bin/fm-session-start.sh through its own tool, which has no hook marker and no
# terminal on fd 2, so it answers `undetermined`. Telling that operator to go
# raise a Claude, Codex or Cursor registration that is not running is the same
# misdirection the Pi transport was fixed for.
test_the_remedy_states_a_kill_second_only_where_a_deadline_was_established() {
  local cap below at
  cap=$(fm_session_start_hook_ceiling) \
    || fail "no harness ceiling could be derived, so there is no wording to check"

  # (a) A deadline IS established: naming the second is correct and must stay.
  below=$(fm_session_start_bound_remedy $((cap - 1)) binds)
  case "$below" in
    *"kills this hook after $(fm_session_start_hook_deadline)s"*) : ;;
    *) fail "with a deadline established the remedy must still name the second the harness kills at, got: $below" ;;
  esac

  # (b) THE GUARD. Nothing established a deadline, so nothing may be stated as
  # one. The bound is still clamped - that is checked elsewhere - but the text
  # must not assert a kill.
  below=$(fm_session_start_bound_remedy $((cap - 1)) undetermined)
  printf '%s\n' "$below" | grep -q 'kills this hook after' \
    && fail "the remedy told a run that could not establish any kill deadline that the harness kills it at a specific second, which is the misdirection the Pi transport was fixed for: $below"
  case "$below" in
    *'cannot establish'*) : ;;
    *) fail "the remedy on an unestablished deadline must say so rather than stating one, got: $below" ;;
  esac

  # And the same at the pinned end, which is the branch an operator reaches after
  # following the advice once.
  at=$(fm_session_start_bound_remedy "$cap" undetermined)
  printf '%s\n' "$at" | grep -q 'kills this hook after' \
    && fail "the pinned remedy asserted a harness kill second on a run that established no deadline: $at"
  printf '%s\n' "$at" | grep -q 'Raise the SessionStart timeouts in the harness registrations, or fix' \
    && fail "the pinned remedy sent a run with no established deadline to edit registrations that may not be running: $at"
  case "$at" in
    *'largest bound this run can'*) : ;;
    *) fail "the pinned remedy on an unestablished deadline must describe the cap as the largest safe assumption, got: $at" ;;
  esac

  pass "fm_session_start_bound_remedy: names the harness kill second only where a deadline was established, and describes the cap as the largest safe assumption otherwise"
}

# --- 2f-ii. the ADVISORY is held to the same certainty as the remedy ----------
#
# The wording rule was applied to the truncation remedy first and the advisory
# was missed, which mattered more rather than less: the remedy prints only after
# a truncation, while the advisory prints on EVERY clamped run. Under
# `undetermined` it was still stating a harness kill second as fact and still
# sending the operator to raise registrations that may not be the ones running -
# contradicting, in the same block, the hedge printed between those two lines.
test_the_advisory_states_a_kill_second_only_where_a_deadline_was_established() {
  local cap spec deadline out
  cap=$(fm_session_start_hook_ceiling) \
    || fail "no harness ceiling could be derived, so there is no wording to check"
  # The REAL cap spec, not one assembled here: the deadline it carries is the
  # thing the advisory prints, so building the spec by hand would test the
  # assembly rather than the library's own.
  spec=$(fm_session_start_cap binds) \
    || fail "no cap spec could be derived, so there is no wording to check"
  deadline=$(fm_session_start_hook_deadline) \
    || fail "no registered deadline could be read, so there is no second to check against"

  # (a) A deadline IS established: naming the second is correct and must stay.
  out=$(fm_session_start_budget_advisory $((cap * 10)) "$cap" binds "$spec")
  case "$out" in
    *"killed by the harness after ${deadline}s"*) : ;;
    *) fail "with a deadline established the advisory must still name the second the harness kills at, got: $out" ;;
  esac
  case "$out" in
    *'Raise the SessionStart timeouts in the harness registrations'*) : ;;
    *) fail "with a deadline established the advisory must still point at the registrations, got: $out" ;;
  esac

  # (b) THE GUARD. Nothing established a deadline, so nothing may be stated as
  # one, and the operator must not be sent to registrations that may not be
  # running. The CLAMP is unchanged and is checked elsewhere.
  out=$(fm_session_start_budget_advisory $((cap * 10)) "$cap" undetermined "$spec")
  printf '%s\n' "$out" | grep -q 'killed by the harness after' \
    && fail "the advisory told a run that could not establish any kill deadline that the harness kills it at a specific second: $out"
  printf '%s\n' "$out" | grep -q '^●  Raise the SessionStart timeouts in the harness registrations' \
    && fail "the advisory sent a run with no established deadline to raise registrations that may not be the ones running: $out"
  case "$out" in
    *'largest bound'*) : ;;
    *) fail "the advisory on an unestablished deadline must describe the cap as the largest bound it can establish is safe, got: $out" ;;
  esac
  # It must still say plainly that a clamp happened, or the operator cannot tell
  # why their value did not take effect.
  assert_contains "$out" 'CLAMPED' \
    'a clamped bound is still a clamp and must say so whatever the context'

  pass "fm_session_start_budget_advisory: names the harness kill second only where a deadline was established, and never points an unestablished run at another harness's registrations"
}

# --- 2g. a registration too small for the margin is not "unreadable" ----------
#
# The ceiling used to return the same non-zero for "read a deadline smaller than
# the margin" as for "could not read anything", and the unreadable path falls
# back to the PLATFORM DEFAULT - which on MSYS is 300s. So a registration
# declaring 2s produced a cap of 300s: 298 seconds above a kill this shell had
# successfully read, which is the silent-no-banner class the clamp exists to
# remove. Both operator messages also claimed no registration could be read when
# one had been.
test_a_registration_smaller_than_the_margin_still_bounds_the_clamp() {
  local root ceiling windows got
  root=$(fm_test_tmproot fm-session-start-tiny-registration) \
    || fail "could not create a temp root"
  mkdir -p "$root/.synthetic"
  printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bin/fm-sessionstart-run.sh","timeout":2}]}]}}' \
    > "$root/.synthetic/hooks.json"
  windows=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 fm_session_start_default_budget)

  # On the Windows arm the margin is larger than this registration, which is the
  # case that used to report as unreadable.
  ceiling=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 \
    FM_SESSION_START_REGISTRATION_ROOT="$root" fm_session_start_hook_ceiling) \
    || fail "a registration of 2s was reported as UNREADABLE, so the clamp falls back to the ${windows}s platform default - a bound above a kill this shell actually read"

  # THE GUARD. Whatever is returned must never exceed the deadline that was read.
  [ "$ceiling" -lt 2 ] \
    || fail "the ceiling ${ceiling}s is not below the 2s deadline the registration declared: a bound at or above the kill loses the banner outright"
  [ "$ceiling" -ge 1 ] \
    || fail "the ceiling ${ceiling}s is not a usable bound"

  # And the clamp really lands there rather than on the platform default.
  got=$(FM_SESSION_START_UNDER_HOOK=1 FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 \
    FM_SESSION_START_REGISTRATION_ROOT="$root" fm_session_start_resolve_budget 600)
  [ "$got" -eq "$ceiling" ] \
    || fail "an explicit 600s bound resolved to ${got}s against a 2s registration; it must clamp to the ${ceiling}s the library derived, never to the ${windows}s platform default"
  [ "$got" -lt "$windows" ] \
    || fail "the clamp landed on the ${windows}s platform default despite a readable 2s registration, which is the fail-open this case exists to catch"

  pass "fm_session_start_hook_ceiling: a registration smaller than the margin still bounds the clamp at ${ceiling}s rather than reporting as unreadable and releasing to the ${windows}s default"
}

# --- 2h. no banner may name a kill second past the registration it read -------
#
# The ceiling used to be the ONLY thing carried, and both banners rebuilt the
# kill second as cap + margin. That identity holds only while
# ceiling = deadline - margin, which the sub-margin branch cannot satisfy - no
# non-negative ceiling can. So the branch added to stop the clamp overstating the
# bound left the banners overstating the deadline instead: with the margin at 22s
# a 20s registration produced a ceiling of 19 and a banner announcing a kill at
# 41s, twenty-one seconds past what the registration declared.
#
# The band is every registration at or below the margin, which on MSYS is now 22s
# - a plausible misconfiguration rather than an absurd one, and it brackets the
# 10s the nudge tier already uses.
test_no_banner_names_a_deadline_past_the_registration_it_read() {
  local root declared margin ceiling cap adv rem second
  declared=20
  root=$(fm_test_tmproot fm-session-start-submargin-banner) \
    || fail "could not create a temp root"
  mkdir -p "$root/.synthetic"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bin/fm-sessionstart-run.sh","timeout":%s}]}]}}\n' \
    "$declared" > "$root/.synthetic/hooks.json"

  # The premise: on the Windows arm this registration really is inside the margin,
  # so the sub-margin branch is the one under test. Without this the case would
  # silently drift onto the ordinary path the day the margin changes.
  # Read in a FRESH shell, so the override is in place before the library binds
  # its margin and this suite's own global is left alone.
  margin=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 bash -c \
    '. "$1"; fm_session_start_bind_margin; printf "%s\n" "$FM_SESSION_START_NESTING_MARGIN"' \
    _ "$ROOT/bin/fm-session-start-bound-lib.sh") \
    || fail "the MINGW nesting margin could not be read"
  [ "$declared" -le "$margin" ] \
    || fail "a ${declared}s registration is no longer inside the ${margin}s MINGW margin, so this case is not exercising the sub-margin branch it names"

  ceiling=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 \
    FM_SESSION_START_REGISTRATION_ROOT="$root" fm_session_start_hook_ceiling) \
    || fail "the ${declared}s registration was reported as unreadable"
  cap=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 \
    FM_SESSION_START_REGISTRATION_ROOT="$root" fm_session_start_cap binds) \
    || fail "no cap was derived from the ${declared}s registration"

  adv=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 \
    FM_SESSION_START_REGISTRATION_ROOT="$root" \
    fm_session_start_budget_advisory 9999 "$ceiling" binds "$cap")
  rem=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 \
    FM_SESSION_START_REGISTRATION_ROOT="$root" \
    fm_session_start_bound_remedy "$ceiling" binds)

  # THE GUARD. Every second either banner attributes to the harness must be the
  # one the registration actually declared - never a reconstruction past it.
  for second in \
    $(printf '%s\n' "$adv" | sed -n 's/.*killed by the harness after \([0-9]*\)s.*/\1/p') \
    $(printf '%s\n' "$rem" | sed -n 's/.*kills this hook after \([0-9]*\)s.*/\1/p')
  do
    [ "$second" -le "$declared" ] \
      || fail "a banner told the operator the harness kills at ${second}s against a registration declaring ${declared}s, so they are $((second - declared))s past a deadline this shell had already read; advisory: $adv remedy: $rem"
    [ "$second" -eq "$declared" ] \
      || fail "a banner named ${second}s where the registration declared ${declared}s: the deadline must be the one that was read, not a number derived from the ceiling; advisory: $adv remedy: $rem"
  done

  # Anti-vacuity: the loop above is only meaningful if a kill second was printed
  # at all, so at least one of the two banners must have named one.
  printf '%s\n%s\n' "$adv" "$rem" | grep -qE 'after [0-9]+s' \
    || fail "neither banner named a harness kill second, so the assertion above checked nothing; advisory: $adv remedy: $rem"

  pass "the truncation banners name the ${declared}s deadline the registration declared, not the ceiling plus the margin, on the sub-margin branch where those two differ"
}

# --- 3. the stage marks must not distort what they measure -------------------

test_stage_mark_spawns_no_subprocess() {
  local tmp file stamp name
  tmp=$(fm_test_tmproot) || fail "could not create a temp root"
  file="$tmp/stages"
  # The path being measured is one whose cost IS its subprocess count, so an
  # instrument that forks per stage inflates the number it exists to report.
  # Proven behaviourally rather than by reading the source: with PATH emptied,
  # every external command is unreachable, so a mark that still records a
  # well-formed stamp used only shell builtins. Introduce a `$(date ...)` or a
  # `$(uname)` here and the stamp goes empty and this case fails.
  # shellcheck disable=SC2123  # Emptying PATH is the assertion, not a mistake:
  # it is what proves no external command was reachable.
  ( PATH= ; fm_session_stage_mark "$file" lock ) || fail "mark must not fail with an empty PATH"
  [ -s "$file" ] || fail "mark recorded nothing with an empty PATH"
  name=$(cut -f1 < "$file")
  stamp=$(cut -f2 < "$file")
  [ "$name" = lock ] || fail "recorded stage name must be 'lock', got '$name'"
  case "$stamp" in
    *[0-9][.,][0-9]*) : ;;
    *) fail "mark must record a real clock stamp using builtins alone, got '$stamp'" ;;
  esac
  pass "fm_session_stage_mark: records a real stamp using shell builtins alone, spawning nothing on the path it measures"
}

test_stage_mark_is_append_only_and_survives_an_unwritable_target() {
  local tmp file
  tmp=$(fm_test_tmproot) || fail "could not create a temp root"
  file="$tmp/stages"
  fm_session_stage_mark "$file" lock
  fm_session_stage_mark "$file" bootstrap
  fm_session_stage_mark "$file" wake-queue
  [ "$(wc -l < "$file")" -eq 3 ] \
    || fail "marks must APPEND: an overwrite loses every earlier stage and with it the attribution"
  [ "$(fm_session_stage_last "$file")" = wake-queue ] \
    || fail "the last recorded stage must be the one the banner names"
  # Losing an attribution line must never change what a startup prints.
  local noise
  noise=$(fm_session_stage_mark "$tmp/no-such-dir/stages" lock 2>&1) \
    || fail "an unwritable breadcrumb target must not fail the caller"
  # A raw shell redirection error printed mid-digest is itself a defect: it lands
  # in the middle of a stage's output and reads as a real fault.
  [ -z "$noise" ] \
    || fail "an unwritable breadcrumb target must stay silent, printed: '$noise'"
  fm_session_stage_mark '' lock || fail "an unset breadcrumb target must not fail the caller"
  pass "fm_session_stage_mark: appends every stage, and an unwritable or unset target never fails the digest"
}

# --- 4. a truncation attributes its own time --------------------------------

test_render_attributes_each_stage_and_flags_the_unfinished_one() {
  local tmp file out
  tmp=$(fm_test_tmproot) || fail "could not create a temp root"
  file="$tmp/stages"
  # Three stages 1.0s, 2.5s and (killed) apart, written as raw clock stamps.
  {
    printf 'lock\t1000.000000\n'
    printf 'bootstrap\t1001.000000\n'
    printf 'wake-queue\t1003.500000\n'
  } >> "$file"
  out=$(fm_session_stage_render "$file" 10)
  assert_contains "$out" 'lock' 'render must list the lock stage'
  assert_contains "$out" 'elapsed=1000' 'lock ran 1000ms: the gap to the NEXT stage mark'
  assert_contains "$out" 'elapsed=2500' 'bootstrap ran 2500ms: the gap to the next stage mark'
  # The final stage has no successor mark because the child was killed inside it,
  # so it is bounded by the budget: 10000ms budget - 3500ms already spent.
  assert_contains "$out" 'elapsed=6500' 'the unfinished stage must be bounded by the remaining budget'
  assert_contains "$out" 'did not finish' 'the unfinished stage must be marked as such'
  assert_contains "$out" 'start=+0' 'the first stage must sit at offset zero'
  assert_contains "$out" 'start=+3500' 'offsets must accumulate from the first stage mark'
  pass "fm_session_stage_render: attributes elapsed time per stage and bounds the unfinished one by the budget"
}

test_render_is_quiet_when_it_has_nothing_to_say() {
  local tmp out
  tmp=$(fm_test_tmproot) || fail "could not create a temp root"
  : > "$tmp/empty"
  out=$(fm_session_stage_render "$tmp/empty" 10)
  [ -z "$out" ] || fail "an empty record must render nothing, got '$out'"
  out=$(fm_session_stage_render "$tmp/absent" 10)
  [ -z "$out" ] || fail "a missing record must render nothing, got '$out'"
  # A shell without EPOCHREALTIME records empty stamps. That is an unmeasured
  # run, and reporting it as a table of zeros would invent a fast stage.
  printf 'lock\t\nbootstrap\t\n' > "$tmp/unstamped"
  out=$(fm_session_stage_render "$tmp/unstamped" 10)
  # Asserted as "no elapsed figure AT ALL", not as "not zero": a renderer that
  # substitutes the origin or the budget for a missing stamp invents a timing
  # that reads as measured, which is worse than printing nothing. An earlier
  # version of this case only rejected elapsed=0 and passed against a mutation
  # that fabricated elapsed=10000. Emptiness is the whole assertion and it is
  # made once - a further grep for `elapsed=` after this line could only ever run
  # against a string already known to be empty.
  [ -z "$out" ] \
    || fail "an unstamped run must render nothing, got: $out"
  pass "fm_session_stage_render: stays silent on an empty, missing, or unstamped record rather than inventing timings"
}

# --- 5. end to end: the real script, really truncated -----------------------

test_truncated_startup_names_the_stage_and_attributes_its_time() {
  local world root home fakebin out ceiling
  world=$(new_world truncated) || fail "could not build a world"
  root=${world%%|*}; world=${world#*|}
  home=${world%%|*}; fakebin=${world#*|}
  make_fake_toolchain "$fakebin"
  slow_toolchain "$fakebin" 0.4 \
    || fail "could not slow the detection toolchain, so the 1s bound would race the digest"
  # A 1s bound truncates any real digest, so this exercises the actual banner
  # path rather than a reconstruction of it.
  out=$(run_session_start "$home" "$root" "$fakebin" FM_SESSION_START_TIMEOUT=1) \
    || fail "session start must still exit 0 when it truncates"
  assert_contains "$out" 'STARTUP TRUNCATED' 'a startup over its bound must say so loudly'
  assert_contains "$out" 'HIT ITS 1s RUNTIME BOUND' 'the banner must report the bound that was actually in force'
  assert_contains "$out" 'It stopped during the' 'the banner must name the stage it died in'
  assert_contains "$out" 'per stage' 'the banner must attribute its time per stage'
  assert_contains "$out" 'did not finish' 'the banner must mark the stage that did not complete'
  # The banner asks the operator to report the slow stage, so it must carry at
  # least one real elapsed figure to report.
  printf '%s\n' "$out" | grep -q 'elapsed=[0-9]' \
    || fail "the banner asks for the slow stage but carried no elapsed figure"
  # The script's OWN setup - the harness probe, the library sources and the
  # tasks-axi probe - is four subprocesses and every library prologue, and it
  # used to sit outside every stage, so a truncation inside it could only report
  # "unknown" and list no lost stages. That window is milliseconds on Linux and
  # seconds under MSYS, which is exactly where it had to be named. Asserted as a
  # rendered row with its own offset and elapsed figure, not as the bare word:
  # "startup" appears in the stage list the banner prints either way, so a
  # substring match would pass against a window that is still unattributed.
  printf '%s\n' "$out" | grep -qE 'startup +start=\+[0-9]+ +elapsed=[0-9]+' \
    || fail "the pre-lock setup window must be attributed with its own elapsed time, got: $out"
  # The banner tells the operator to raise FM_SESSION_START_TIMEOUT, and above
  # the shortest registered hook timeout the harness kills the hook outright and
  # prints none of this - so the advice has to carry its own ceiling, by number,
  # or the printed remedy leads into a strictly worse failure. Asserted against
  # the ceiling the library derives, never against a literal.
  ceiling=$(fm_session_start_hook_ceiling) \
    || fail "no harness hook ceiling could be derived from the checkout, so the banner has no cap to name"
  printf '%s\n' "$out" | grep -qE "to at most ${ceiling}s" \
    || fail "the banner told the operator to raise the bound without naming the ${ceiling}s ceiling the harness enforces, got: $out"
  pass "fm-session-start.sh: a truncated startup names the stage it died in, attributes its elapsed time per stage, and caps its own remedy at the ${ceiling}s harness ceiling"
}

# The worker only has a digest bound to inherit if the parent actually hands it
# over, so the export is asserted through the real script rather than assumed.
#
# WHAT IS OBSERVED. The parent forks its bounded child as
# `env <assignments> fm-session-start.sh`, and `env` is resolved through PATH, so
# a stub records the exact assignments the parent asked for before exec'ing the
# real one. That argv IS the handover mechanism; nothing here reads the script.
test_the_parent_hands_its_resolved_bound_to_the_bounded_child() {
  local world root home fakebin envlog out
  world=$(new_world bound-handover) || fail "could not build a world"
  root=${world%%|*}; world=${world#*|}
  home=${world%%|*}; fakebin=${world#*|}
  make_fake_toolchain "$fakebin"
  slow_toolchain "$fakebin" 0.4 \
    || fail "could not slow the detection toolchain, so the 1s bound would race the digest"
  envlog="$home/env.argv"
  : > "$envlog"
  # shellcheck disable=SC2016  # The stub body is deferred; it expands when the stub runs.
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "$FM_TEST_ENV_LOG"\nfor c in /usr/bin/env /bin/env; do [ -x "$c" ] && exec "$c" "$@"; done\nexit 0\n' > "$fakebin/env"
  chmod +x "$fakebin/env"
  out=$(run_session_start "$home" "$root" "$fakebin" \
    FM_TEST_ENV_LOG="$envlog" FM_SESSION_START_TIMEOUT=1) \
    || fail "session start must still exit 0 when it truncates"
  assert_contains "$out" 'HIT ITS 1s RUNTIME BOUND' \
    'the fixture must run bounded at the value it asked for, or there is no bound to hand over'
  # THE GUARD. The bound in force is 1s, so that is the bound the child - and
  # through it the detached network worker - must be told about.
  grep -qx -- 'FM_SESSION_START_RESOLVED_BOUND=1' "$envlog" \
    || fail "the parent forked its bounded child without handing over the 1s bound it resolved, so the detached network worker re-derives its inline-delivery window from its own hook context and can silently stop delivering while the digest is still running; env argv seen: $(tr '\n' ' ' < "$envlog")"
  pass "fm-session-start.sh: the bound the parent resolved is handed to the bounded child, which is what the detached network worker inherits it through"
}

# When mktemp fails there is no breadcrumb file, and the path falls back to
# /dev/null. That sentinel is load-bearing and cannot simply be blanked: a
# NON-EMPTY FM_SESSION_START_STAGE_FILE is what tells the bounded child from the
# parent. So it must never reach the cleanup instead. An unprivileged account is
# saved only by /dev not being writable; a session start running as root in a
# container would delete /dev/null for everything else running in it.
#
# Driven through the real script with mktemp failing, and asserted on what rm was
# actually ASKED to delete - recorded by a stub on PATH - because that request is
# what the hazard consists of.
test_a_failed_breadcrumb_mktemp_never_hands_dev_null_to_rm() {
  local world root home fakebin rmlog out
  world=$(new_world devnull-cleanup) || fail "could not build a world"
  root=${world%%|*}; world=${world#*|}
  home=${world%%|*}; fakebin=${world#*|}
  make_fake_toolchain "$fakebin"
  slow_toolchain "$fakebin" 0.4 \
    || fail "could not slow the detection toolchain, so the 1s bound would race the digest"
  rmlog="$home/rm.log"
  : > "$rmlog"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/mktemp"
  # shellcheck disable=SC2016  # The stub body is deferred; it expands when the stub runs.
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "$FM_TEST_RM_LOG"\nfor c in /bin/rm /usr/bin/rm; do [ -x "$c" ] && exec "$c" "$@"; done\nexit 0\n' > "$fakebin/rm"
  chmod +x "$fakebin/mktemp" "$fakebin/rm"
  out=$(run_session_start "$home" "$root" "$fakebin" \
    FM_TEST_RM_LOG="$rmlog" FM_SESSION_START_TIMEOUT=1) \
    || fail "session start must still exit 0 when it truncates with no breadcrumb file"
  assert_contains "$out" 'STARTUP TRUNCATED' \
    'the fixture must reach the cleanup, which only runs after the banner'
  # The premise, asserted rather than assumed: with no breadcrumb file there are
  # no marks to render, so a per-stage table here would mean mktemp succeeded
  # after all and the sentinel was never in force.
  printf '%s\n' "$out" | grep -q 'per stage' \
    && fail "a breadcrumb file was created after all, so the /dev/null sentinel was never in force and this case proves nothing"
  grep -qx -- '/dev/null' "$rmlog" \
    && fail "the cleanup asked rm to delete /dev/null; running as root in a container that removes /dev/null for everything else running in it"
  pass "fm-session-start.sh: a failed breadcrumb mktemp leaves the /dev/null sentinel alone instead of handing it to rm"
}

# The same remedy on a run that was ALREADY bounded at the ceiling. Telling an
# operator to raise a knob pinned at its maximum spends their next move on a
# no-op and reads as though nothing was checked, so the remedy has to change
# shape rather than repeat itself.
#
# Exercised through fm_session_start_bound_remedy directly, which is the function
# the banner delegates to and whose printed lines ARE the operator-facing
# contract. The end-to-end case above already proves the banner calls it with the
# bound that was really in force; reaching the pinned state through the real
# script would mean waiting out a several-minute clamped bound, since the clamp
# is what pins it there in the first place.
#
# Hook context is asserted explicitly with the marker bin/fm-sessionstart-run.sh
# exports, because the remedy is scoped to the paths a cap governs: on a
# positively established direct run nothing kills this process at a hook timeout
# and the uncapped advice is the correct one. Leaving the context implicit would
# make these assertions depend on whether the runner happens to hand the suite a
# terminal on stderr, which is not a property of the invariant.
test_the_remedy_stops_advising_a_knob_that_is_already_pinned() {
  local ceiling below at above
  ceiling=$(fm_session_start_hook_ceiling) \
    || fail "no harness hook ceiling could be derived, so there is no pinned state to describe"
  below=$(FM_SESSION_START_UNDER_HOOK=1 fm_session_start_bound_remedy $((ceiling - 1)))
  at=$(FM_SESSION_START_UNDER_HOOK=1 fm_session_start_bound_remedy "$ceiling")
  above=$(FM_SESSION_START_UNDER_HOOK=1 fm_session_start_bound_remedy $((ceiling + 1)))

  # Below the ceiling the advice is actionable and must carry the cap by number.
  assert_contains "$below" 'raise FM_SESSION_START_TIMEOUT' \
    'below the ceiling, raising the bound is still the remedy'
  assert_contains "$below" "at most ${ceiling}s" \
    'the raise advice must name how far the bound may actually go'

  # AT the ceiling the raise advice must be GONE, not merely accompanied by a
  # caveat: that is the defect this case exists for.
  printf '%s\n' "$at" | grep -q 'raise FM_SESSION_START_TIMEOUT' \
    && fail "a run already bounded at the ${ceiling}s ceiling was still told to raise FM_SESSION_START_TIMEOUT, got: $at"
  assert_contains "$at" 'ALREADY at the' \
    'a pinned run must say the ceiling has been reached'
  assert_contains "$at" 'harness registrations' \
    'a pinned run must point at the registrations, the one knob that still moves the ceiling'

  # And a bound somehow ABOVE the ceiling is the same pinned case, not a third
  # behaviour - the comparison is >=, so a future clamp change cannot open a gap
  # in which the dead advice comes back.
  printf '%s\n' "$above" | grep -q 'raise FM_SESSION_START_TIMEOUT' \
    && fail "a bound above the ${ceiling}s ceiling was told to raise FM_SESSION_START_TIMEOUT, got: $above"
  assert_contains "$above" 'ALREADY at the' \
    'a bound above the ceiling is the pinned case too'
  pass "fm_session_start_bound_remedy: names the cap below the ${ceiling}s ceiling and stops advising the knob entirely at or above it"
}

# first_line_matching <text> <extended-regex>: the 1-based number of the first
# line of <text> matching <regex>, or nothing when it never matches.
first_line_matching() {
  printf '%s\n' "$1" | grep -n -m1 -E -- "$2" | cut -d: -f1
}

# assert_header_precedes_body <text> <header-re> <body-re> <label>: the stage's
# own header line must come BEFORE the first line of the stage's own output.
#
# Presence was not enough, and that is the whole point of this helper. The
# earlier version of this case asserted only that each header string appeared
# somewhere in the digest, so moving `subsection "WAKE QUEUE"` back BELOW the
# drain output - the exact defect being fixed - left it green. Both patterns are
# anchored for the same reason: bare substrings collide, with 'LOCK' inside
# 'BLOCKED' and 'CONTEXT' inside surrounding prose.
assert_header_precedes_body() {
  local out=$1 header_re=$2 body_re=$3 label=$4 header_line body_line
  header_line=$(first_line_matching "$out" "$header_re")
  [ -n "$header_line" ] \
    || fail "stage '$label': no header line matching /$header_re/ was printed at all"
  body_line=$(first_line_matching "$out" "$body_re")
  [ -n "$body_line" ] \
    || fail "stage '$label': no output line matching /$body_re/ was printed, so the ordering is unprovable"
  [ "$header_line" -lt "$body_line" ] \
    || fail "stage '$label': its header is on line $header_line but the stage had already printed on line $body_line, so the header was emitted when the stage FINISHED and a long stage is a silent wait"
}

test_every_stage_prints_its_header_before_the_stage_runs() {
  local world root home fakebin out
  world=$(new_world headers) || fail "could not build a world"
  root=${world%%|*}; world=${world#*|}
  home=${world%%|*}; fakebin=${world#*|}
  make_fake_toolchain "$fakebin"
  # The bound is pinned rather than inherited so a loaded runner cannot turn
  # this case into a truncation reported as a missing header. 300s is the same
  # number the Windows arm resolves to, and this hermetic world finishes in
  # seconds, so it is headroom and not a wait.
  out=$(run_session_start "$home" "$root" "$fakebin" FM_SESSION_START_TIMEOUT=300) \
    || fail "session start must exit 0"
  # Matched on the banner's own line rather than the words "STARTUP TRUNCATED",
  # which the READ-ONCE CONTRACT section quotes in prose on a completed run.
  printf '%s\n' "$out" | grep -q 'HIT ITS .* RUNTIME BOUND' \
    && fail "the digest truncated, so a missing header below would be a truncation and not a defect"
  # Every header the digest owns, each paired with a line only its OWN stage
  # emits. LOCK through NEXT STEP is the whole printed contract; the tenth stage
  # - `startup` - is the pre-lock window that by construction runs before any
  # header can be printed, so it is asserted by the truncation case above
  # instead. Where a stage has more than one shape in this hermetic world, the
  # body pattern covers each of them, so the case pins ordering and not the
  # fixture's incidental content.
  assert_header_precedes_body "$out" '^LOCK$' \
    '^lock (acquired|held)' lock
  assert_header_precedes_body "$out" '^BOOTSTRAP$' \
    '^(MISSING: |\(silent - all good\)$)' bootstrap
  assert_header_precedes_body "$out" '^WAKE QUEUE$' \
    '^(\(no queued wakes\)$|WAKE_|inactive outcome reconciliation:|skipped \(read-only session\))' wake-queue
  # This stage announces itself from its own body rather than through a
  # subsection header: bin/fm-supervision-instructions.sh prints the line below
  # as its first output, so a header above it would be the same name twice with
  # only a rule between them. The stage MARK is independent of the printed line,
  # so a truncation inside this stage still names it.
  assert_header_precedes_body "$out" '^SUPERVISION OPERATING INSTRUCTIONS' \
    '^Current state:$' supervision-instructions
  assert_header_precedes_body "$out" '^READ-ONCE CONTRACT$' \
    '^Do NOT re-read any of them' read-once
  assert_header_precedes_body "$out" '^FLEET STATE$' \
    '^Work under way \(state/\*\.meta\)$' fleet-state
  assert_header_precedes_body "$out" '^NETWORK CHECKS$' \
    '^(completed off the startup path|IN PROGRESS -|not started -|skipped \(read-only session\))' network-checks
  assert_header_precedes_body "$out" '^CONTEXT$' \
    '^data/projects\.md$' context
  assert_header_precedes_body "$out" '^NEXT STEP$' \
    '^The digest above is complete for this session start\.' next-step
  pass "fm-session-start.sh: each of the nine printed stages emits its header BEFORE its own output, so a long stage is attributable rather than silent"
}

test_windows_platforms_raise_the_default_bound
test_non_windows_platforms_keep_the_portable_bound
test_explicit_timeout_wins_on_every_platform
test_unusable_explicit_bound_falls_back_to_the_platform_default
test_a_zero_padded_bound_still_produces_a_deadline_that_bites
test_the_clamp_follows_hook_context_and_undetermined_clamps
test_a_transport_that_arms_no_deadline_is_honoured_in_full
test_the_remedy_states_a_kill_second_only_where_a_deadline_was_established
test_the_advisory_states_a_kill_second_only_where_a_deadline_was_established
test_a_registration_smaller_than_the_margin_still_bounds_the_clamp
test_no_banner_names_a_deadline_past_the_registration_it_read
test_an_unreadable_registration_set_caps_rather_than_releasing
test_the_delivery_bound_follows_the_digest_and_not_the_workers_own_context
test_the_binder_defines_every_value_it_returns_on_every_path
test_stage_mark_spawns_no_subprocess
test_stage_mark_is_append_only_and_survives_an_unwritable_target
test_render_attributes_each_stage_and_flags_the_unfinished_one
test_render_is_quiet_when_it_has_nothing_to_say
test_truncated_startup_names_the_stage_and_attributes_its_time
test_a_failed_breadcrumb_mktemp_never_hands_dev_null_to_rm
test_the_parent_hands_its_resolved_bound_to_the_bounded_child
test_the_remedy_stops_advising_a_knob_that_is_already_pinned
test_every_stage_prints_its_header_before_the_stage_runs
