#!/usr/bin/env bash
# tests/session-start-bound-helpers.sh - the ONE derivation of the ceiling on
# bin/fm-session-start.sh's own runtime bound, shared by every guard that has to
# nest a harness hook timeout above it.
#
# WHY THE CEILING IS DERIVED AND NEVER WRITTEN DOWN. The nesting guard in
# tests/fm-cursor-primary.test.sh once asserted `.timeout > 120` against a
# hardcoded 120 whose provenance was a comment. When the Windows arm raised the
# default to 300 s the assertion kept passing on a 180 s registration, so the
# invariant it names - firstmate's own bound bites FIRST, therefore the
# truncation banner is always printed - was inverted on MSYS with every test
# still green. A literal here is that defect, so the ceiling is resolved by
# running the real resolver.
#
# THE PLATFORM MATRIX IS THE ARM LIST, and it is why this lives in one file
# rather than in each caller: fm_session_start_default_budget answers per
# `uname -s`, so the only way to take a maximum over its arms is to ask it for
# every platform this repo supports, and two copies of that list would drift the
# moment an arm is added. The real host is asked too, with the seam cleared, so a
# platform the matrix does not name still contributes its own answer on the box
# running the suite. tests/fm-session-start-hook-nesting.test.sh asserts that the
# ceiling this returns actually covers the raised Windows arm, so a matrix
# shrunk back to one entry fails there rather than quietly lowering the ceiling.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-session-start-bound-lib.sh
. "$ROOT/bin/fm-session-start-bound-lib.sh"

# Every `uname -s` this repo resolves a session-start bound for. The Windows
# spellings are the same ones tests/fm-session-start-bound.test.sh drives the
# raised arm with, through the FM_PLATFORM_UNAME_OVERRIDE seam.
FM_TEST_SESSION_START_PLATFORMS='Linux Darwin FreeBSD NetBSD OpenBSD SunOS AIX
unknown MINGW64_NT-10.0-26200 MINGW32_NT-6.2 MSYS_NT-10.0-19045 CYGWIN_NT-10.0'

# fm_test_max_session_start_bound: the highest default runtime bound in seconds
# that bin/fm-session-start.sh can pick on any supported platform, including this
# host. Fails (non-zero, nothing printed) rather than returning a guess if the
# resolver ever answers something that is not a positive integer.
fm_test_max_session_start_bound() {
  local plat got max=0
  for plat in $FM_TEST_SESSION_START_PLATFORMS ''; do
    if [ -n "$plat" ]; then
      got=$(FM_PLATFORM_UNAME_OVERRIDE="$plat" fm_session_start_default_budget) || return 1
    else
      got=$(unset FM_PLATFORM_UNAME_OVERRIDE; fm_session_start_default_budget) || return 1
    fi
    case "$got" in ''|*[!0-9]*|0) return 1 ;; esac
    [ "$got" -le "$max" ] || max=$got
  done
  [ "$max" -gt 0 ] || return 1
  printf '%s\n' "$max"
}
