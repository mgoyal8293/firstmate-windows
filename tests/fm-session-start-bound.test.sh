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
  for bad in '' 0 abc 12x ' ' -30 30.5; do
    got=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0 fm_session_start_resolve_budget "$bad")
    [ "$got" = 300 ] \
      || fail "unusable bound '$bad' on MINGW must fall back to the 300s platform default, got '$got'"
    got=$(FM_PLATFORM_UNAME_OVERRIDE=Linux fm_session_start_resolve_budget "$bad")
    [ "$got" = 120 ] \
      || fail "unusable bound '$bad' on Linux must fall back to the 120s platform default, got '$got'"
  done
  pass "fm_session_start_resolve_budget: an unusable bound falls back to the PLATFORM default, never to a portable constant"
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
  # that fabricated elapsed=10000.
  [ -z "$out" ] \
    || fail "an unstamped run must render nothing, got: $out"
  printf '%s\n' "$out" | grep -q 'elapsed=' \
    && fail "an unstamped run must not report any elapsed figure, got: $out"
  pass "fm_session_stage_render: stays silent on an empty, missing, or unstamped record rather than inventing timings"
}

# --- 5. end to end: the real script, really truncated -----------------------

test_truncated_startup_names_the_stage_and_attributes_its_time() {
  local tmp home out
  tmp=$(fm_test_tmproot) || fail "could not create a temp root"
  home="$tmp/home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  # A 1s bound truncates any real digest, so this exercises the actual banner
  # path rather than a reconstruction of it.
  out=$(FM_HOME="$home" FM_SESSION_START_TIMEOUT=1 \
    bash "$ROOT/bin/fm-session-start.sh" 2>&1) \
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
  # seconds under MSYS, which is exactly where it had to be named.
  assert_contains "$out" 'startup' 'the pre-lock setup window must be attributable, not reported as unknown'
  pass "fm-session-start.sh: a truncated startup names the stage it died in AND attributes its elapsed time per stage"
}

test_every_stage_prints_its_header_before_the_stage_runs() {
  local tmp home out sect
  tmp=$(fm_test_tmproot) || fail "could not create a temp root"
  home="$tmp/home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  out=$(FM_HOME="$home" bash "$ROOT/bin/fm-session-start.sh" 2>&1) \
    || fail "session start must exit 0"
  # A stage that runs without first printing its header is a silent wait that
  # reads as a wedge, and leaves a truncation with no printed context.
  for sect in 'LOCK' 'BOOTSTRAP' 'WAKE QUEUE' 'SUPERVISION INSTRUCTIONS' \
              'READ-ONCE CONTRACT' 'FLEET STATE' 'NETWORK CHECKS' 'CONTEXT' 'NEXT STEP'; do
    assert_contains "$out" "$sect" "stage header '$sect' must be printed"
  done
  pass "fm-session-start.sh: every one of the nine stages prints a header, so a long stage is attributable rather than silent"
}

test_windows_platforms_raise_the_default_bound
test_non_windows_platforms_keep_the_portable_bound
test_explicit_timeout_wins_on_every_platform
test_unusable_explicit_bound_falls_back_to_the_platform_default
test_stage_mark_spawns_no_subprocess
test_stage_mark_is_append_only_and_survives_an_unwritable_target
test_render_attributes_each_stage_and_flags_the_unfinished_one
test_render_is_quiet_when_it_has_nothing_to_say
test_truncated_startup_names_the_stage_and_attributes_its_time
test_every_stage_prints_its_header_before_the_stage_runs
