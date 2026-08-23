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
DIGEST_WRAPPERS='fm-session-start.sh fm-sessionstart-run.sh fm-sessionstart-cursor.sh'
NUDGE_WRAPPERS='fm-sessionstart-nudge.sh'

# Every tracked JSON registration in the checkout, DISCOVERED rather than listed,
# so a fourth harness that lands its own .foo/hooks.json is read the day it
# appears instead of the day someone remembers to add it here.
tracked_json_registrations() {
  find "$ROOT" -mindepth 2 -maxdepth 4 -type f -name '*.json' \
    -not -path "$ROOT/.git/*" -not -path '*/node_modules/*' -print 2>/dev/null | LC_ALL=C sort
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
  local ceiling reg rel line timeout cmd tier
  local seen=0 digest_hooks=0 digest_files=0 had_digest_here
  ceiling=$(fm_test_max_session_start_bound) \
    || fail "the session-start bound ceiling could not be derived"

  while IFS= read -r reg; do
    [ -n "$reg" ] || continue
    rel=${reg#"$ROOT"/}
    # A tracked registration that no longer parses is a FAILURE, not a skip: the
    # harness would silently run with no registration at all, and this suite
    # would report ok while covering nothing.
    jq -e . "$reg" >/dev/null 2>&1 \
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
    done < <(session_start_hooks_in "$reg")
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

test_the_ceiling_covers_every_arm_the_resolver_can_pick
test_every_registered_digest_hook_outlives_the_startup_bound
