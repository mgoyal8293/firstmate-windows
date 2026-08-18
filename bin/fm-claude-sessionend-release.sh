#!/usr/bin/env bash
# Claude SessionEnd-owned release of this session's lock-ownership token.
#
# Registered in tracked .claude/settings.json as a SessionEnd command hook.
# It exists for the token ownership path only (bin/fm-session-lock-lib.sh
# "Session tokens"), which is reachable only where the ancestry walk cannot
# answer at all - today, the Windows runtimes.
#
# Why it is needed. On the ancestry path an exited session leaves a dead harness
# pid in state/.lock, and the next session reclaims the home through the
# existing dead-owner path with no release step at all. The token path cannot
# reuse that: its recorded pid is a transient tool-call pid that is always dead,
# so the recorded TOKEN is what refuses a second session, and a token proves
# identity rather than liveness. Without a release, the freshness window in
# FM_SESSION_TOKEN_STALE_AFTER would be the only way out and every ordinary
# restart would leave the home read-only for hours. Measured on Windows before
# this hook existed: a second session was refused a minute after the first had
# exited.
#
# Boundaries, because this releases the fleet lock:
#   - It clears ONLY a token this very session owns. A token belonging to
#     another session, a missing token, or a malformed one is left untouched, so
#     a foreign or crashed session can never be evicted by someone else's exit.
#   - It clears the token only, never state/.lock. The dead pid left behind is
#     exactly what the unchanged dead-owner reclaim in bin/fm-lock.sh expects.
#   - It is inert off the token path: an ancestry-owned home records no token,
#     so fm_session_token_owned_by_self is false and nothing is removed.
#   - Scope is the same genuine-primary test the Stop auto-arm applies, so a
#     crew or scout worktree that loads these tracked settings stays inert.
#   - A crash is deliberately still covered by the freshness window rather than
#     by anything here; this hook shortens the common case, it does not replace
#     the backstop.
#
# Every path exits 0 and prints nothing: a session that is already ending has
# nothing useful to do with an error, and the freshness window remains the
# backstop for anything this hook could not do.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

# Consume the payload so a slow writer can never wedge on a full pipe, and stand
# down on a host that merely loads Claude-compatible settings.
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

if fm_session_token_owned_by_self "$STATE"; then
  fm_session_token_clear "$STATE"
fi
exit 0
