#!/usr/bin/env bash
# Differential proof for the claim-lock re-check on the session-token
# acquisition path (bin/fm-lock.sh + bin/fm-session-token-lib.sh).
#
# THE RACE, as the real code sees it:
#   1. Session B looks at state/.lock unlocked. It does not exist yet.
#   2. Session B blocks acquiring the claim lock state/.lock.acquire.
#   3. While B waits, peer session A - which holds the claim lock - publishes
#      its own token to state/.lock.session and a (now dead) pid to state/.lock,
#      then releases.
#   4. B takes the claim lock and MUST re-check the token before publishing.
#
# Correct behaviour: B refuses, and A's state/.lock is never overwritten.
# Without the re-check B acquires and both Windows sessions co-own the home.
#
# Usage: claim-lock-recheck-race.sh <fm-root> <label>
set -u
ROOT=$1
LABEL=$2
WIN=MINGW64_NT-10.0-26200
A=aaaaaaaa-0000-1111-2222-333333333333
B=bbbbbbbb-0000-1111-2222-333333333333

home=$(mktemp -d "${TMPDIR:-/tmp}/fm-recheck-XXXXXX")
state="$home/state"
mkdir -p "$state"

# --- peer session A: hold the claim lock with the library itself -------------
env FM_ROOT_OVERRIDE="$ROOT" STATE="$state" TOKEN_A="$A" \
  bash -c '
    set -u
    . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$STATE/.lock.acquire"
    : > "$STATE/.held"
    while [ ! -e "$STATE/.publish" ]; do sleep 0.05; done
    # Peer A finishes its own acquisition: token first, then its pid.
    printf "%s\n" "$TOKEN_A" > "$STATE/.lock.session"
    printf "%s\n" 999999 > "$STATE/.lock"
    fm_lock_release "$STATE/.lock.acquire"
  ' &
peer=$!
i=0; while [ ! -e "$state/.held" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i+1)); done
[ -e "$state/.held" ] || { echo "fixture: peer never took the claim lock" >&2; exit 2; }
[ -e "$state/.lock" ] && { echo "fixture: state/.lock must not exist yet" >&2; exit 2; }

# --- session B: acquire, detached so its ancestry cannot answer --------------
out="$home/b.out"; rc="$home/b.rc"
env -u CLAUDE_CODE_SESSION_ID \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
  FM_PLATFORM_UNAME_OVERRIDE="$WIN" CLAUDE_CODE_SESSION_ID="$B" \
  OUT="$out" RC="$rc" \
  bash -c 'bash -c "bash \"$0\" > \"$OUT\" 2>&1; printf %s \$? > \"$RC\"" &' \
  "$ROOT/bin/fm-lock.sh"

# Let B get past the unlocked look and into the claim-lock wait, then have the
# peer publish underneath it - the exact interleaving the re-check exists for.
sleep 1.5
[ -s "$rc" ] && { echo "fixture: B finished before the peer published" >&2; exit 2; }
: > "$state/.publish"
wait "$peer" 2>/dev/null
i=0; while [ ! -s "$rc" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i+1)); done
[ -s "$rc" ] || { echo "fixture: B never finished" >&2; exit 2; }

echo "=== $LABEL ==="
echo "session B exit: $(cat "$rc")"
echo "session B says: $(cat "$out")"
echo "state/.lock         = $(cat "$state/.lock" 2>/dev/null)   (peer A wrote 999999)"
echo "state/.lock.session = $(cat "$state/.lock.session" 2>/dev/null)"
if [ "$(cat "$rc")" != 0 ] && [ "$(cat "$state/.lock")" = 999999 ] \
  && [ "$(cat "$state/.lock.session")" = "$A" ]; then
  echo "VERDICT: REFUSED - peer A still owns the home, no co-ownership"
else
  echo "VERDICT: ACQUIRED - session B took a home peer A owns (both sessions co-own)"
fi
echo
rm -rf "$home"
