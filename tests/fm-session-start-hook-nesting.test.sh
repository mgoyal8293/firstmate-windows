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
  local ceiling rel abs line timeout cmd tier
  local seen=0 digest_hooks=0 digest_files=0 had_digest_here
  ceiling=$(fm_test_max_session_start_bound) \
    || fail "the session-start bound ceiling could not be derived"

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
        # STRICT: equality already loses the banner, because at equal deadlines
        # which process dies first is a race.
        [ "$timeout" -gt "$ceiling" ] \
          || fail "$rel kills the session-start hook after ${timeout}s while the digest may bound itself at ${ceiling}s: the harness preempts the STARTUP TRUNCATED banner, so an over-budget startup loses its wake-queue drain and supervision instructions with nothing printed"
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
  pass "hook nesting: all $digest_hooks digest-running session-start hook(s) across $digest_files registration(s) outlive the ${ceiling}s startup bound, so firstmate's own bound always bites first"
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
    got=$(FM_PLATFORM_UNAME_OVERRIDE="$plat" fm_session_start_resolve_budget "$((harness * 10))")
    case "$got" in ''|*[!0-9]*|0) fail "an over-cap override on '$plat' resolved to '$got', which is not a usable bound" ;; esac
    [ "$got" -lt "$harness" ] \
      || fail "FM_SESSION_START_TIMEOUT=$((harness * 10)) on '$plat' resolves to ${got}s, at or above the ${harness}s harness hook timeout: the harness kills the hook first, so there is no STARTUP TRUNCATED banner, no named stage and no reconcile list"
  done

  # Clamped, never reduced to the default and never rejected: an operator who
  # asked for MORE time must not be handed LESS than the machine can give.
  got=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 fm_session_start_resolve_budget "$((harness * 10))")
  [ "$got" -eq "$cap" ] \
    || fail "an over-cap override must land ON the ${cap}s cap, got ${got}s"
  [ "$got" -gt "$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 fm_session_start_default_budget)" ] \
    || fail "an over-cap override resolved to ${got}s, no more than the Windows default: asking for more time must not yield less"

  # And the clamp must not become a floor or eat a usable value: anything at or
  # below the cap is honoured exactly.
  got=$(FM_PLATFORM_UNAME_OVERRIDE=Linux fm_session_start_resolve_budget "$cap")
  [ "$got" -eq "$cap" ] \
    || fail "an override exactly AT the ${cap}s cap must be honoured, got ${got}s"
  got=$(FM_PLATFORM_UNAME_OVERRIDE=Linux fm_session_start_resolve_budget 45)
  [ "$got" -eq 45 ] \
    || fail "an override well below the cap must be honoured exactly, got ${got}s"

  # An UNUSABLE value still resolves to the platform default. `timeout 0`
  # disables the deadline outright, so the clamp must not turn a garbage value
  # into the cap either.
  got=$(FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 fm_session_start_resolve_budget abc)
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
  out=$(fm_session_start_budget_advisory "$((harness * 10))" "$cap")
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
  out=$(fm_session_start_budget_advisory 45 45)
  [ -z "$out" ] || fail "an unclamped bound must produce no advisory, got: $out"
  out=$(fm_session_start_budget_advisory '' 300)
  [ -z "$out" ] || fail "an unset FM_SESSION_START_TIMEOUT must produce no advisory, got: $out"
  pass "hook nesting: a clamped bound names the requested value, the cap applied and why, and an unclamped one stays silent"
}

test_the_ceiling_covers_every_arm_the_resolver_can_pick
test_every_registered_digest_hook_outlives_the_startup_bound
test_an_explicit_override_is_clamped_below_the_shortest_registration
test_a_clamp_says_so_on_the_digest
