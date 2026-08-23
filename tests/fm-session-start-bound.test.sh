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
# fm_session_start_hook_context answers `direct` on `[ -t 2 ]`, so the only
# honest way to cover that branch is to give it a terminal. An env flag standing
# in for the predicate would test the flag and leave the predicate unproven,
# which is how a branch ships unexercised.
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
  cap=$(fm_session_start_hook_ceiling) \
    || fail "no harness ceiling could be derived from this checkout, so none of the clamp branches below mean anything"

  # (a) POSITIVELY under a hook: the marker bin/fm-sessionstart-run.sh exports.
  ctx=$(FM_SESSION_START_UNDER_HOOK=1 fm_session_start_hook_context)
  [ "$ctx" = hook ] \
    || fail "the wrapper's marker must positively establish hook context, got '$ctx'"
  got=$(FM_SESSION_START_UNDER_HOOK=1 FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0 \
    fm_session_start_resolve_budget "$((cap * 10))")
  [ "$got" -eq "$cap" ] \
    || fail "under a registered hook an over-ceiling bound must clamp to ${cap}s, got ${got}s"

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
    [ "$ctx" = direct ] \
      || fail "with a terminal on stderr and no hook marker the context must be 'direct', got '$ctx'"
    got=$(fm_test_on_pty "fm_session_start_resolve_budget $((cap * 10))")
    [ "$got" -eq "$((cap * 10))" ] \
      || fail "a positively established direct run must be honoured IN FULL ($((cap * 10))s), got ${got}s: the operator's own rerun is the remedy the truncation banner prescribes and nothing kills it at the hook timeout"
  else
    printf 'note: no pty allocator (script/python3) on this box, so the direct-run branch is unverified here\n' >&2
  fi
  pass "fm_session_start_resolve_budget: clamps under a hook AND when hook context is undetermined, and honours a positively established direct run in full"
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
test_the_remedy_stops_advising_a_knob_that_is_already_pinned() {
  local ceiling below at above
  ceiling=$(fm_session_start_hook_ceiling) \
    || fail "no harness hook ceiling could be derived, so there is no pinned state to describe"
  below=$(fm_session_start_bound_remedy $((ceiling - 1)))
  at=$(fm_session_start_bound_remedy "$ceiling")
  above=$(fm_session_start_bound_remedy $((ceiling + 1)))

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
  assert_header_precedes_body "$out" '^SUPERVISION INSTRUCTIONS$' \
    '^SUPERVISION OPERATING INSTRUCTIONS' supervision-instructions
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
test_stage_mark_spawns_no_subprocess
test_stage_mark_is_append_only_and_survives_an_unwritable_target
test_render_attributes_each_stage_and_flags_the_unfinished_one
test_render_is_quiet_when_it_has_nothing_to_say
test_truncated_startup_names_the_stage_and_attributes_its_time
test_the_remedy_stops_advising_a_knob_that_is_already_pinned
test_every_stage_prints_its_header_before_the_stage_runs
