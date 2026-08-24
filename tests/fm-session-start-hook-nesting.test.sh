#!/usr/bin/env bash
# tests/fm-session-start-hook-nesting.test.sh - the two deadlines around a
# session start must NEST: bin/fm-session-start.sh's own runtime bound has to
# bite BEFORE the harness kills the hook, or the operator is told nothing at all.
#
# WHY THIS IS ITS OWN SUITE. A run-tier harness blocks session initialization
# while the digest runs and enforces its own hook timeout by killing the hook
# process. bin/fm-session-start.sh bounds itself precisely so that overrun is
# survivable: the child is stopped, everything already emitted is already on the
# hook's stdout, and the parent prints a STARTUP TRUNCATED banner naming the
# stage that did not finish, the per-stage elapsed times, and the stages that
# were therefore never emitted. If the HARNESS's timeout is the shorter of the
# two, the parent is killed with the child and none of that is printed: the wake
# queue is still undrained and the supervision instructions are still missing,
# but now silently. That is strictly worse than truncating, so the ordering of
# these two numbers is a supervision property and not a tuning preference.
#
# It shipped inverted once. The Windows arm raised the default bound to 300 s
# while all three registrations still killed the hook at 180 s, and the one guard
# that named this invariant compared against a hardcoded 120 - so 180 > 120 was
# green the whole time the 180-300 s band lost its banner. The ceiling here is
# therefore DERIVED by running bin/fm-session-start-bound-lib.sh's own resolver
# over every platform arm (tests/session-start-bound-helpers.sh owns that one
# derivation), never written down.
#
# It then nearly shipped inverted a SECOND time by the same mechanism one level
# up: sections 1 and 2 only asked what the resolver picks by DEFAULT, while
# FM_SESSION_START_TIMEOUT overrides the default and the truncation banner's own
# remedy invites the operator to raise it. Section 3 covers that override path,
# because "the defaults nest" is not the invariant - "the bound in force nests"
# is.
#
# WHAT CONTRACT IS BEING READ. These hook registrations are machine-consumed
# declarative artifacts whose real consumer is the harness itself, which is not
# available in CI. They are therefore parsed into a normalized model - one entry
# per registered session-start hook, carrying its timeout and the command it
# launches - and asserted for meaning. No assertion below is a substring match
# over the raw file.
#
# WHAT IS OUT OF REACH, stated rather than left looking like an oversight. Pi and
# OpenCode deliver session start through tracked extensions and plugins that
# declare no timeout at all, so they have no second deadline to nest and nothing
# here to check. Every harness that registers a session-start hook with a
# DECLARED timeout is covered, and an unrecognized one fails below.
set -u

# shellcheck source=tests/session-start-bound-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/session-start-bound-helpers.sh"

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to read the tracked hook registrations semantically; a skip here would hide the inverted nesting this suite exists to catch"

# The wrappers a session-start hook can name, and whether that wrapper RUNS the
# bounded digest or only asks the agent to. Only the digest tier is subject to
# the nesting rule: bin/fm-sessionstart-nudge.sh prints one short instruction and
# returns, so Grok's 10 s registration is correct and must not be raised.
# bin/fm-sessionstart-cursor.sh is digest tier because it is a thin transport
# that calls bin/fm-sessionstart-run.sh and waits for the whole digest.
#
# The digest list is READ FROM THE LIBRARY, not restated: the clamp in
# fm_session_start_resolve_budget takes its ceiling from the same tier decision,
# so a second copy here would let the two disagree about which registration
# bounds the operator - and the guard would still be green.
DIGEST_WRAPPERS=$FM_SESSION_START_DIGEST_WRAPPERS
NUDGE_WRAPPERS='fm-sessionstart-nudge.sh'

# Every tracked JSON registration in the checkout, DISCOVERED rather than listed,
# so a fourth harness that lands its own .foo/hooks.json is read the day it
# appears instead of the day someone remembers to add it here.
#
# Scoped to TRACKED material with git rather than swept with find, because the
# unparseable-JSON arm below is a hard failure and this suite must only fail on
# files the repo owns: an operator's untracked .claude/settings.local.json is not
# gitignored here, and a scratch JSON file in it would fail a suite named for
# tracked registrations. Discovery is unchanged in the direction that matters - a
# newly added registration is tracked material, so it is still found the day it
# lands, at any depth, without being listed here.
tracked_json_registrations() {
  git -C "$ROOT" ls-files -z -- '*.json' 2>/dev/null | tr '\0' '\n' | LC_ALL=C sort
}

# One line per registered session-start hook in <file>: "<timeout><TAB><command>",
# with the timeout reported as ABSENT when the entry declares none. Keyed on the
# object KEY, case-insensitively, so Claude/Codex's `SessionStart` and Cursor's
# `sessionStart` are the same question, and nested `hooks` wrappers are found at
# any depth rather than at one hardcoded shape.
session_start_hooks_in() {
  jq -r '
    def session_start_values:
      [ .. | objects | to_entries[]
        | select((.key | ascii_downcase) == "sessionstart")
        | .value ];
    [ session_start_values[] | .. | objects
      | select(has("command") and (.command | type == "string")) ]
    | .[]
    | ((if has("timeout") then (.timeout | tostring) else "ABSENT" end)
       + "\t" + (.command | gsub("[ \t\n]+"; " ")))
  ' "$1" 2>/dev/null
}

# digest | nudge | unknown, from the wrapper the command launches.
hook_tier() {
  local cmd=$1 wrapper
  for wrapper in $DIGEST_WRAPPERS; do
    case "$cmd" in *"$wrapper"*) printf 'digest\n'; return 0 ;; esac
  done
  for wrapper in $NUDGE_WRAPPERS; do
    case "$cmd" in *"$wrapper"*) printf 'nudge\n'; return 0 ;; esac
  done
  printf 'unknown\n'
}

# --- 1. the ceiling the nesting is measured against --------------------------

# Anti-vacuity guard for the derivation itself. If the platform matrix in
# tests/session-start-bound-helpers.sh is ever shrunk back to one entry, or the
# Windows arm is dropped from the resolver, the ceiling silently falls to 120 and
# every 180 s registration would pass the nesting check below while losing its
# banner on MSYS. That is the exact defect this suite exists to prevent, so the
# ceiling is asserted to cover the raised arm rather than merely to be a number.
test_the_ceiling_covers_every_arm_the_resolver_can_pick() {
  local ceiling portable windows plat got
  ceiling=$(fm_test_max_session_start_bound) \
    || fail "the session-start bound ceiling could not be derived at all, so no nesting check below means anything"
  case "$ceiling" in ''|*[!0-9]*|0) fail "the derived ceiling must be a positive integer, got '$ceiling'" ;; esac
  portable=$(FM_PLATFORM_UNAME_OVERRIDE=Linux fm_session_start_default_budget)
  windows=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 fm_session_start_default_budget)
  [ "$ceiling" -ge "$portable" ] \
    || fail "the ceiling ${ceiling}s is below the portable default ${portable}s, so the derivation is not covering its own arms"
  [ "$ceiling" -ge "$windows" ] \
    || fail "the ceiling ${ceiling}s is below the Windows default ${windows}s: the derivation stopped covering the raised arm, which is how a 180s registration passed this check before"
  # And no arm at all may exceed it, which is what makes it a ceiling.
  for plat in $FM_TEST_SESSION_START_PLATFORMS; do
    got=$(FM_PLATFORM_UNAME_OVERRIDE="$plat" fm_session_start_default_budget)
    [ "$got" -le "$ceiling" ] \
      || fail "uname -s '$plat' resolves ${got}s, above the derived ceiling ${ceiling}s"
  done
  pass "the session-start bound ceiling is derived from the resolver's own arms and covers the raised Windows arm (${ceiling}s)"
}

# --- 2. every registered digest hook outlives that ceiling -------------------

test_every_registered_digest_hook_outlives_the_startup_bound() {
  local floor rel abs line timeout cmd tier
  local seen=0 digest_hooks=0 digest_files=0 had_digest_here
  # The floor is `default + margin`, per platform arm, NOT the bare maximum
  # default. The margin is what pays for the parent's pre-fork prologue and its
  # post-kill banner, and the harness kills the whole hook - so a registration
  # that merely exceeds the bound still preempts the banner by up to a margin.
  floor=$(fm_test_min_registration_floor) \
    || fail "the minimum registration floor could not be derived, so no nesting check below means anything"

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    abs="$ROOT/$rel"
    # A tracked registration that no longer parses is a FAILURE, not a skip: the
    # harness would silently run with no registration at all, and this suite
    # would report ok while covering nothing.
    jq -e . "$abs" >/dev/null 2>&1 \
      || fail "$rel does not parse as JSON, so whatever it registers cannot be verified"
    had_digest_here=0
    while IFS=$'\t' read -r timeout cmd; do
      [ -n "$cmd" ] || continue
      seen=$((seen + 1))
      tier=$(hook_tier "$cmd")
      # An unrecognized wrapper is a FAILURE, so a fourth harness cannot be
      # registered unprotected: whoever adds it must say which tier it is in.
      [ "$tier" != unknown ] \
        || fail "$rel registers a session-start hook naming no wrapper this guard knows ($cmd); add it to DIGEST_WRAPPERS or NUDGE_WRAPPERS in $(basename "${BASH_SOURCE[0]}") so its deadline is checked"
      # A missing or non-numeric timeout is also a failure rather than a pass by
      # omission: an unbounded session-start hook is its own hazard, and on the
      # digest tier there would be no number left to nest.
      case "$timeout" in
        ''|ABSENT) fail "$rel registers a $tier-tier session-start hook with no timeout at all" ;;
        *[!0-9]*|0) fail "$rel registers a $tier-tier session-start hook whose timeout '$timeout' is not a positive integer" ;;
      esac
      if [ "$tier" = digest ]; then
        digest_hooks=$((digest_hooks + 1))
        had_digest_here=1
        # The margin is already the strict separation, so the comparison is
        # `>=` against a floor that has it built in: at ${floor}s the bound
        # bites first AND the parent still has its margin to print the banner in.
        [ "$timeout" -ge "$floor" ] \
          || fail "$rel kills the session-start hook after ${timeout}s, below the ${floor}s that the largest platform bound plus its own nesting margin needs: the harness preempts the STARTUP TRUNCATED banner mid-print, so an over-budget startup loses its wake-queue drain and supervision instructions with nothing printed"
      fi
    done < <(session_start_hooks_in "$abs")
    [ "$had_digest_here" -eq 0 ] || digest_files=$((digest_files + 1))
  done < <(tracked_json_registrations)

  [ "$seen" -gt 0 ] \
    || fail "no session-start hook registration was found at all, so this suite verified nothing"
  # The three run-tier transports (Claude, Codex exec, Cursor) each register the
  # digest. Asserted as a floor on DISCOVERED files so a rename that drops one
  # out of discovery fails here instead of quietly narrowing the guard.
  [ "$digest_files" -ge 3 ] \
    || fail "only $digest_files tracked registration(s) were found to run the digest; Claude, Codex and Cursor each register one, so discovery has stopped seeing at least one of them"
  pass "hook nesting: all $digest_hooks digest-running session-start hook(s) across $digest_files registration(s) clear the ${floor}s bound-plus-margin floor, so firstmate's own bound bites first AND the banner has time to print"
}

# --- 3. and so does an EXPLICIT override, which is where this got through -----
#
# Sections 1 and 2 only ever ask what the resolver picks by DEFAULT. That is
# exactly how the hazard survived the first round: FM_SESSION_START_TIMEOUT
# overrides the default, the resolver accepted any positive integer, and the
# truncation banner's own remedy told the operator to raise it - so following the
# printed advice past the shortest registration killed the hook outright and
# printed nothing, which is the failure the whole suite exists to prevent.
#
# The number these cases nest under is read with jq, independently of the awk
# scanner the library uses, so the two implementations have to agree.
#
# Every resolve below asserts hook context explicitly with the marker
# bin/fm-sessionstart-run.sh exports, because the clamp is scoped to the paths
# the harness ceiling governs and this suite is about the hook path. Leaving it
# implicit would make these assertions depend on whether the runner happens to
# hand the suite a terminal on stderr, which is not a property of the invariant.
# tests/fm-session-start-bound.test.sh owns the scoping itself, including that an
# UNDETERMINED context still clamps.

# The shortest timeout any tracked registration declares for a DIGEST-tier
# session-start hook. This is the deadline that actually kills the hook first.
min_registered_digest_timeout() {
  local rel timeout cmd min=
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    while IFS=$'\t' read -r timeout cmd; do
      [ -n "$cmd" ] || continue
      [ "$(hook_tier "$cmd")" = digest ] || continue
      case "$timeout" in ''|ABSENT|*[!0-9]*|0) continue ;; esac
      [ -n "$min" ] && [ "$timeout" -ge "$min" ] || min=$timeout
    done < <(session_start_hooks_in "$ROOT/$rel")
  done < <(tracked_json_registrations)
  [ -n "$min" ] || return 1
  printf '%s\n' "$min"
}

test_an_explicit_override_is_clamped_below_the_shortest_registration() {
  local harness cap got plat
  harness=$(min_registered_digest_timeout) \
    || fail "no digest-tier session-start timeout could be read at all, so the override cases below would verify nothing"

  # The library derives the same cap from the same registrations by its own
  # route. If the two disagree, one of them is reading a registration the other
  # cannot see - most likely the library's dot-directory glob has stopped finding
  # one - and the clamp would then be computed from the wrong deadline.
  cap=$(fm_session_start_hook_ceiling) \
    || fail "fm_session_start_hook_ceiling derived no cap from the checkout's registrations, so an explicit FM_SESSION_START_TIMEOUT is not clamped at all"
  [ "$cap" -eq "$((harness - FM_SESSION_START_NESTING_MARGIN))" ] \
    || fail "the library's cap ${cap}s does not match the ${harness}s shortest registration minus the ${FM_SESSION_START_NESTING_MARGIN}s nesting margin: the two discoveries disagree, so check the dot-directory glob in bin/fm-session-start-bound-lib.sh against what git ls-files finds"

  # THE GUARD. An operator following the banner's advice past the shortest
  # registration must still end up with a bound that bites first, on every
  # platform arm - the Windows one especially, since its default is already the
  # closest to the registrations.
  for plat in $FM_TEST_SESSION_START_PLATFORMS; do
    got=$(FM_SESSION_START_UNDER_HOOK=1 FM_PLATFORM_UNAME_OVERRIDE="$plat" \
      fm_session_start_resolve_budget "$((harness * 10))")
    case "$got" in ''|*[!0-9]*|0) fail "an over-cap override on '$plat' resolved to '$got', which is not a usable bound" ;; esac
    [ "$got" -lt "$harness" ] \
      || fail "FM_SESSION_START_TIMEOUT=$((harness * 10)) on '$plat' resolves to ${got}s, at or above the ${harness}s harness hook timeout: the harness kills the hook first, so there is no STARTUP TRUNCATED banner, no named stage and no reconcile list"
  done

  # Clamped, never reduced to the default and never rejected: an operator who
  # asked for MORE time must not be handed LESS than the machine can give.
  got=$(FM_SESSION_START_UNDER_HOOK=1 FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 \
    fm_session_start_resolve_budget "$((harness * 10))")
  [ "$got" -eq "$cap" ] \
    || fail "an over-cap override must land ON the ${cap}s cap, got ${got}s"
  [ "$got" -gt "$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 fm_session_start_default_budget)" ] \
    || fail "an over-cap override resolved to ${got}s, no more than the Windows default: asking for more time must not yield less"

  # And the clamp must not become a floor or eat a usable value: anything at or
  # below the cap is honoured exactly.
  got=$(FM_SESSION_START_UNDER_HOOK=1 FM_PLATFORM_UNAME_OVERRIDE=Linux fm_session_start_resolve_budget "$cap")
  [ "$got" -eq "$cap" ] \
    || fail "an override exactly AT the ${cap}s cap must be honoured, got ${got}s"
  got=$(FM_SESSION_START_UNDER_HOOK=1 FM_PLATFORM_UNAME_OVERRIDE=Linux fm_session_start_resolve_budget 45)
  [ "$got" -eq 45 ] \
    || fail "an override well below the cap must be honoured exactly, got ${got}s"

  # An UNUSABLE value still resolves to the platform default. `timeout 0`
  # disables the deadline outright, so the clamp must not turn a garbage value
  # into the cap either.
  got=$(FM_SESSION_START_UNDER_HOOK=1 FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 fm_session_start_resolve_budget abc)
  [ "$got" -eq "$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 fm_session_start_default_budget)" ] \
    || fail "an unusable override must still fall back to the platform default, got ${got}s"

  pass "hook nesting: an explicit FM_SESSION_START_TIMEOUT above the cap is clamped to ${cap}s on every platform arm, strictly under the ${harness}s shortest registration, and a usable value at or below it is untouched"
}

# The clamp is not allowed to be silent: a bound the operator does not know is in
# force is how they conclude the cap did not apply and raise the value again.
test_a_clamp_says_so_on_the_digest() {
  local harness cap out
  harness=$(min_registered_digest_timeout) || fail "no digest-tier timeout could be read"
  cap=$(fm_session_start_hook_ceiling) || fail "no cap could be derived"
  out=$(fm_session_start_budget_advisory "$((harness * 10))" "$cap" hook)
  case "$out" in
    *"$((harness * 10))"*) : ;;
    *) fail "the clamp advisory must name the value that was requested, got: $out" ;;
  esac
  case "$out" in
    *"$cap"*) : ;;
    *) fail "the clamp advisory must name the cap that was applied, got: $out" ;;
  esac
  case "$out" in
    *CLAMPED*) : ;;
    *) fail "the clamp advisory must say plainly that it clamped, got: $out" ;;
  esac
  # And it stays quiet when nothing was clamped, so the digest does not carry a
  # warning about a bound that is in force exactly as asked.
  out=$(fm_session_start_budget_advisory 45 45 hook)
  [ -z "$out" ] || fail "an unclamped bound must produce no advisory, got: $out"
  out=$(fm_session_start_budget_advisory '' 300 hook)
  [ -z "$out" ] || fail "an unset FM_SESSION_START_TIMEOUT must produce no advisory, got: $out"
  pass "hook nesting: a clamped bound names the requested value, the cap applied and why, and an unclamped one stays silent"
}

# --- 4. the margin covers the parent's OWN time, not just the equal-deadline race
#
# The bound governs the bounded CHILD. The harness kills the PARENT, and the
# parent spends time outside that child at both ends: the pre-fork prologue
# (SCRIPT_DIR/FM_ROOT resolution, three library sources with their own transitive
# prologues, the stage-file mktemp) and, after the kill, the whole banner
# (fm_session_stage_last, the pending-stage awk/tr pipeline,
# fm_session_start_bound_remedy, fm_session_stage_render). So the hook's wall
# time is prologue + bound + banner, and a margin sized only for the race covers
# neither end - which means an operator who does exactly what the banner tells
# them, raise FM_SESSION_START_TIMEOUT to the printed ceiling, still loses the
# banner on MSYS.
#
# The measured pattern is 26 subprocesses at a worst measured 124.0 ms per fork
# under contention on the target box; bin/fm-session-start-bound-lib.sh and
# docs/verification/session-start-fork-profile.md record how both numbers were
# taken. This suite holds the library's Windows arm to covering that product.
#
# The count is the CLAMPED path, not the default one, and that distinction is the
# whole point of the number. The default Windows bound is 300 s against a ceiling
# in the 350s, so the default path can never reach the ceiling; the only bound
# that ever equals it is a clamped one, which additionally runs the pre-fork cap
# derivation. An earlier version of this constant was 22 - the default path - and
# it was too small for the path the margin actually owes.
#
# THE CONSTANT IS THE WORST COUNT ON RECORD, NOT THE ONE THE MARGIN WAS DERIVED
# FROM. The margin was derived from 26; an independent re-measurement of the same
# path with the same interposer came out at 31, and 32 was argued for. All of them
# ceiling to the same 4 s, so the margin does not turn on which is right - but a
# guard that assumed the smallest would pass a margin that the largest does not
# cover, so it is held to the largest. That leaves this assertion with only 32 ms
# of headroom, which is the honest state of it: it is a guard against the margin
# shrinking, not evidence that 4 s is roomy.
#
# THE WINDOWS ARM IS DRIVEN BY SOURCING THE LIBRARY UNDER THE PLATFORM OVERRIDE,
# not by reading its text: the margin is resolved when the file is sourced, so a
# fresh shell with FM_PLATFORM_UNAME_OVERRIDE set is what a Git Bash session
# actually does, and every number below comes from running the real functions
# there.
MEASURED_CLAMPED_PATH_SUBPROCESSES=32
MEASURED_WORST_FORK_MS=124

# Run <snippet> with bin/fm-session-start-bound-lib.sh sourced in a fresh shell
# that resolves its platform arms as <uname>, under a positively established hook
# context. A fresh shell rather than a subshell, because the margin is resolved
# when the file is sourced and the override has to be in place before that.
on_platform() {  # <uname-s> <shell-snippet>
  FM_PLATFORM_UNAME_OVERRIDE="$1" FM_SESSION_START_UNDER_HOOK=1 \
    bash -c '. "$1"; eval "$2"' _ "$ROOT/bin/fm-session-start-bound-lib.sh" "$2"
}

# Deferred on purpose: this is evaluated in the fresh shell on_platform starts,
# after the library has been sourced there under that shell's platform override.
# shellcheck disable=SC2016
READ_MARGIN='printf "%s\n" "$FM_SESSION_START_NESTING_MARGIN"'

test_the_nesting_margin_covers_the_windows_clamped_path() {
  local margin portable owed

  margin=$(on_platform MINGW64_NT-10.0-26200 "$READ_MARGIN")
  case "$margin" in ''|*[!0-9]*|0) fail "the Windows nesting margin must be a positive integer, got '$margin'" ;; esac
  portable=$(on_platform Linux "$READ_MARGIN")
  case "$portable" in ''|*[!0-9]*|0) fail "the portable nesting margin must be a positive integer, got '$portable'" ;; esac

  # THE GUARD. The Windows margin has to cover the measured cost of the work the
  # parent does outside the bounded child. A margin sized for the race alone does
  # not, and this is the assertion that says so in milliseconds rather than in
  # prose.
  owed=$((MEASURED_CLAMPED_PATH_SUBPROCESSES * MEASURED_WORST_FORK_MS))
  [ "$((margin * 1000))" -ge "$owed" ] \
    || fail "the Windows nesting margin is ${margin}s, below the ${owed}ms the measured ${MEASURED_CLAMPED_PATH_SUBPROCESSES}-subprocess clamped path costs at ${MEASURED_WORST_FORK_MS}ms per fork: the harness kills the parent mid-banner, so a truncation prints no stage and no reconcile list"
  # The portable arm is the strict-inequality margin and stays that: forks are
  # about 1 ms here, so the same product is well under a second.
  [ "$portable" -ge 1 ] \
    || fail "the portable nesting margin must stay at least 1s: at equal deadlines which process dies first is a race"

  pass "hook nesting: the Windows margin ${margin}s covers the measured ${owed}ms of clamped-path prologue, cap derivation and banner the bound itself does not, and the portable arm keeps its ${portable}s strict-inequality margin"
}

# The clamp and the operator-facing advice must be reading the SAME margin. If
# either of them carried its own copy the two would drift, and the operator would
# be told a kill deadline that is not the one the bound was computed against -
# which is the whole failure mode the margin exists to prevent. Asserted against
# the registration timeout read independently with jq, so the printed second has
# to be the real one and not merely self-consistent.
test_the_clamp_and_the_banner_agree_on_the_margin() {
  local harness margin cap budget below at advisory
  harness=$(min_registered_digest_timeout) \
    || fail "no digest-tier session-start timeout could be read at all"
  margin=$(on_platform MINGW64_NT-10.0-26200 "$READ_MARGIN")
  cap=$(on_platform MINGW64_NT-10.0-26200 'fm_session_start_hook_ceiling') \
    || fail "no cap could be derived on the Windows arm"
  case "$cap" in ''|*[!0-9]*|0) fail "the Windows cap must be a positive integer, got '$cap'" ;; esac

  # The clamp: the bound in force is the registration minus that one margin.
  [ "$cap" -eq "$((harness - margin))" ] \
    || fail "the Windows cap ${cap}s is not the ${harness}s shortest registration minus its own ${margin}s margin: the clamp is using a different margin from the one the library defines"
  budget=$(on_platform MINGW64_NT-10.0-26200 "fm_session_start_resolve_budget $((harness * 10))")
  [ "$budget" -eq "$cap" ] \
    || fail "an over-cap override on the Windows arm resolved to ${budget}s rather than the ${cap}s cap"

  # The banner: every line that names the second the harness kills at must name
  # the registration's own timeout. A second literal margin anywhere makes this
  # print ${harness} minus the difference, and this fails.
  below=$(on_platform MINGW64_NT-10.0-26200 "fm_session_start_bound_remedy $((cap - 1))")
  case "$below" in
    *"after ${harness}s"*) : ;;
    *) fail "the raise advice on the Windows arm must name the ${harness}s registration as the second the harness kills at, got: $below" ;;
  esac
  at=$(on_platform MINGW64_NT-10.0-26200 "fm_session_start_bound_remedy $cap")
  case "$at" in
    *"after ${harness}s"*) : ;;
    *) fail "the pinned advice on the Windows arm must name the ${harness}s registration as the second the harness kills at, got: $at" ;;
  esac
  advisory=$(on_platform MINGW64_NT-10.0-26200 "fm_session_start_budget_advisory $((harness * 10)) $cap hook")
  case "$advisory" in
    *"after ${harness}s"*) : ;;
    *) fail "the clamp advisory on the Windows arm must name the ${harness}s registration as the second the harness kills at, got: $advisory" ;;
  esac

  pass "hook nesting: the clamp and every banner line on the Windows arm go through the one ${margin}s margin, so the ${cap}s bound and the ${harness}s kill deadline they print cannot disagree"
}

# The clamped-path invariant, stated as the library defines it: the ceiling the
# clamp hands an operator, PLUS the margin, must never exceed the shortest
# registration. That is what makes a clamped bound survivable - the digest
# truncates at the ceiling and the parent still has the margin left to print the
# banner before the harness kills the hook.
#
# It is asserted on EVERY platform arm, not just the host's, because the margin
# is per platform and the arm with the largest margin is the one with the least
# room. The registration side is read with jq, independently of the library's own
# awk scanner, so the two implementations have to agree about which deadline
# bounds the operator.
test_a_clamped_bound_plus_its_margin_never_exceeds_the_registration() {
  local harness plat margin cap checked=0
  harness=$(min_registered_digest_timeout) \
    || fail "no digest-tier session-start timeout could be read at all"

  for plat in $FM_TEST_SESSION_START_PLATFORMS; do
    margin=$(fm_test_session_start_margin "$plat") \
      || fail "no nesting margin could be resolved for '$plat'"
    cap=$(on_platform "$plat" 'fm_session_start_hook_ceiling') \
      || fail "no ceiling could be derived on '$plat', so an explicit bound there is not clamped at all"
    case "$cap" in ''|*[!0-9]*|0) fail "the ceiling on '$plat' must be a positive integer, got '$cap'" ;; esac
    # THE GUARD. Not `cap < harness`, which a one-second margin would satisfy
    # while losing the banner: the margin has to still be there after the bound
    # is spent.
    [ "$((cap + margin))" -le "$harness" ] \
      || fail "on '$plat' a clamped bound of ${cap}s plus its ${margin}s margin is $((cap + margin))s against the ${harness}s shortest registration: an operator who follows the banner's own advice to the printed ceiling has the harness kill the parent mid-banner"
    # And the clamp must really land there, or the invariant is about a number
    # nothing uses.
    [ "$(on_platform "$plat" "fm_session_start_resolve_budget $((harness * 10))")" -eq "$cap" ] \
      || fail "on '$plat' an over-ceiling override did not resolve to the ${cap}s ceiling the assertion above checked"
    checked=$((checked + 1))
  done

  [ "$checked" -gt 0 ] \
    || fail "no platform arm was checked, so this case verified nothing"
  pass "hook nesting: on all $checked platform arm(s) the clamped bound plus its own margin still fits inside the ${harness}s shortest registration"
}

# Anti-vacuity for the floor the section-2 guard now uses. If it ever degenerates
# back to the bare maximum default budget, section 2 silently returns to the
# weaker comparison it had before - green against a registration that preempts
# the banner by up to a margin.
test_the_registration_floor_includes_the_margin_it_is_named_for() {
  local floor max plat margin widest=0
  floor=$(fm_test_min_registration_floor) || fail "the registration floor could not be derived"
  max=$(fm_test_max_session_start_bound) || fail "the maximum default bound could not be derived"
  for plat in $FM_TEST_SESSION_START_PLATFORMS; do
    margin=$(fm_test_session_start_margin "$plat") || fail "no margin for '$plat'"
    [ "$margin" -le "$widest" ] || widest=$margin
  done
  [ "$widest" -gt 0 ] || fail "no platform arm declared a positive nesting margin"
  [ "$floor" -ge "$((max + 1))" ] \
    || fail "the ${floor}s registration floor does not exceed the ${max}s maximum default bound, so it carries no margin at all and section 2 is back to the weaker check"
  pass "hook nesting: the ${floor}s registration floor is the ${max}s largest default bound plus a real margin (widest arm ${widest}s), not the bound alone"
}

test_the_ceiling_covers_every_arm_the_resolver_can_pick
test_the_registration_floor_includes_the_margin_it_is_named_for
test_every_registered_digest_hook_outlives_the_startup_bound
test_a_clamped_bound_plus_its_margin_never_exceeds_the_registration
test_an_explicit_override_is_clamped_below_the_shortest_registration
test_a_clamp_says_so_on_the_digest
test_the_nesting_margin_covers_the_windows_clamped_path
test_the_clamp_and_the_banner_agree_on_the_margin
