#!/usr/bin/env bash
# tests/fm-session-token.test.sh - per-session token ownership for the fleet lock
# (bin/fm-session-lock-lib.sh, bin/fm-lock.sh).
#
# WHY THIS EXISTS. The ancestry walk cannot work on the Windows runtimes: MSYS's
# /proc holds only MSYS processes, so a native harness never appears in it and
# the tool subprocess it spawns reports ppid 1. The walk ends on hop one, the
# session lock could never be acquired, and a Windows home stayed permanently
# read-only. A token answers ownership directly instead of inferring it from the
# process tree.
#
# The contract this file pins, in the order it matters:
#   1. OFF WINDOWS THE ADDITION IS INERT. This is the load-bearing one. A token
#      is honoured only where ancestry is STRUCTURALLY unanswerable, never merely
#      where the walk found nothing - otherwise any Linux process carrying the
#      environment variable could claim a lock the ancestry walk correctly
#      refuses it.
#   2. On the token path, ownership is the token and nothing else.
#   3. state/.lock keeps holding a plain numeric pid, so no existing reader has
#      to learn a second identity namespace, and no Windows pid is ever stored.
#   4. A different, recently refreshed token refuses rather than silently
#      co-owning the home.
#   5. A session that ENDS releases its own claim immediately, so the ordinary
#      restart is not held off by the freshness window that exists only as the
#      crash backstop. This is the case measured as broken on Windows before
#      bin/fm-claude-sessionend-release.sh existed: a second session was refused
#      a minute after the first had exited.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-session-lock-lib.sh"

WIN=MINGW64_NT-10.0-26200

# Run bin/fm-lock.sh against a throwaway home and echo its output.
#
# Launched DETACHED so the launcher exits immediately and the tree reparents to
# init, exactly as tests/fm-session-lock-ancestry.test.sh does. Without that the
# suite's own harness would be a real ancestor - this file usually runs inside a
# live session - and every case would take the ancestry path and prove nothing.
# The platform seam then drives the Windows arms from a POSIX runner.
run_lock() {  # <home> <uname> <token> [arg]
  local home=$1 uname=$2 token=$3 arg=${4:-} out="$1/lock.out" rc="$1/lock.rc" i=0
  rm -f "$out" "$rc"
  # shellcheck disable=SC2016 # The detached shell expands these, not this one.
  env -u CLAUDE_CODE_SESSION_ID \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PLATFORM_UNAME_OVERRIDE="$uname" \
    ${token:+CLAUDE_CODE_SESSION_ID="$token"} \
    FM_TOKEN_OUT="$out" FM_TOKEN_RC="$rc" FM_TOKEN_ARG="$arg" \
    bash -c 'bash -c "
      bash \"$0\" ${FM_TOKEN_ARG:+\"$FM_TOKEN_ARG\"} > \"$FM_TOKEN_OUT\" 2>&1
      printf %s \$? > \"$FM_TOKEN_RC\"
    " &' "$ROOT/bin/fm-lock.sh"
  while [ "$i" -lt 400 ] && [ ! -s "$rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$rc" ] || fail "run_lock: fm-lock.sh never finished for $home"
  cat "$out"
}

new_home() {
  local h
  h=$(fm_test_tmproot fm-session-token) || fail "could not create a fixture home"
  mkdir -p "$h/state"
  printf '%s\n' "$h"
}


# A fixture that satisfies fm_primary_scope_matches: a plain (non-worktree)
# checkout with AGENTS.md, bin/, and a state dir - the same shape
# tests/fm-claude-stop-autoarm.test.sh builds, because the release hook applies
# the identical scope gate.
new_primary_home() {
  local h lib
  h=$(fm_test_tmproot fm-session-token-primary) || fail "could not create a fixture home"
  mkdir -p "$h/state" "$h/bin"
  git init -q "$h"
  git -C "$h" commit -q --allow-empty -m init
  : > "$h/AGENTS.md"
  for lib in fm-claude-sessionend-release.sh fm-primary-scope-lib.sh fm-session-lock-lib.sh \
    fm-cursor-lib.sh fm-proc-lib.sh fm-session-token-lib.sh fm-hook-host-lib.sh \
    fm-path-lib.sh fm-wake-lib.sh fm-lock.sh; do
    cp "$ROOT/bin/$lib" "$h/bin/$lib"
  done
  chmod +x "$h/bin/fm-claude-sessionend-release.sh" "$h/bin/fm-lock.sh"
  printf '%s\n' "$h"
}

# Run the SessionEnd release hook against fixture home $1 as session $2.
run_release() {  # <home> <token>
  local home=$1 token=$2
  printf '%s\n' '{"session_id":"sess-release","reason":"clear"}' \
    | env -u CLAUDE_CODE_SESSION_ID \
      FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_PLATFORM_UNAME_OVERRIDE="$WIN" \
      ${token:+CLAUDE_CODE_SESSION_ID="$token"} \
      bash "$home/bin/fm-claude-sessionend-release.sh"
}

# --- 1. inert off Windows ----------------------------------------------------

test_token_is_ignored_where_ancestry_actually_works() {
  local home out
  home=$(new_home)
  # A token is present and the walk finds no harness - the exact shape that must
  # NOT acquire on a POSIX host, because there an empty walk is a real answer.
  out=$(run_lock "$home" Linux 11111111-2222-3333-4444-555555555555)
  assert_contains "$out" "cannot locate harness process in ancestry" \
    "token: SECURITY - a token must never substitute for ancestry off Windows"
  assert_absent "$home/state/.lock" "token: no lock may be written off Windows"
  assert_absent "$home/state/.lock.session" "token: no token may be recorded off Windows"
  pass "session token: ignored entirely where the ancestry walk is the real answer (Linux, Darwin)"
}

# The predicate is an AND of two conditions, and getting either half wrong is a
# security bug rather than a portability one, so both are pinned across the whole
# truth table. The walk result is stubbed because this runner's own ancestry
# cannot be made to answer both ways.
test_ancestry_unavailable_requires_both_platform_and_empty_walk() {
  local platform walk expected got
  for platform in Linux Darwin "$WIN"; do
    for walk in found empty; do
      if [ "$platform" = "$WIN" ] && [ "$walk" = empty ]; then expected=0; else expected=1; fi
      got=0
      (
        # shellcheck disable=SC2030 # Confining the platform seam to this case is the point.
        FM_PROC_UNAME_S=$platform
        if [ "$walk" = empty ]; then
          # shellcheck disable=SC2329 # Called indirectly by fm_session_ancestry_unavailable.
          fm_harness_ancestry_pids() { return 1; }
        else
          # shellcheck disable=SC2329 # Called indirectly by fm_session_ancestry_unavailable.
          fm_harness_ancestry_pids() { printf '%s\n' 4242; return 0; }
        fi
        fm_session_ancestry_unavailable
      ) || got=1
      [ "$got" = "$expected" ] \
        || fail "token: ancestry-unavailable on platform=$platform walk=$walk expected rc=$expected, got $got"
    done
  done
  pass "fm_session_ancestry_unavailable: true only when the platform cannot answer AND the walk found nothing"
}

# The refusal a Windows user without a token actually reads. Naming the ancestry
# walk there is true and useless: it can never answer for anyone on that platform,
# which is precisely why ownership is token-based. So the two refusals are
# distinct, and each must stay on its own platform - a diagnostic that names an
# impossible mechanism sends the reader after something they cannot affect.
test_the_windows_refusal_names_the_token_not_ancestry() {
  local home out
  home=$(new_home)
  out=$(run_lock "$home" "$WIN" "")
  assert_contains "$out" "no firstmate session token" \
    "refusal: a Windows session with no token must be told the token is what is missing"
  assert_contains "$out" "CLAUDE_CODE_SESSION_ID" \
    "refusal: the Windows refusal must name the variable that supplies the token"
  assert_contains "$out" "Only Claude Code" \
    "refusal: the Windows refusal must say which harness can supply one today"
  assert_not_contains "$out" "cannot locate harness process in ancestry" \
    "refusal: the Windows refusal must not cite a mechanism that can never work there"
  assert_absent "$home/state/.lock" "refusal: a refused Windows session must acquire nothing"

  # The POSIX refusal is unchanged: there an empty walk IS the real answer, and
  # ancestry is exactly the right thing to name.
  out=$(run_lock "$home" Linux "")
  assert_contains "$out" "cannot locate harness process in ancestry" \
    "refusal: off Windows the ancestry refusal must be unchanged"
  assert_not_contains "$out" "no firstmate session token" \
    "refusal: the token refusal must never appear off Windows, where ancestry is the real answer"
  pass "lock refusal: Windows names the missing session token and its remedy; other platforms still name ancestry"
}

# --- 2 and 3. acquisition on the token path ---------------------------------

test_token_acquires_and_records_a_plain_pid() {
  local home out lock
  home=$(new_home)
  out=$(run_lock "$home" "$WIN" aaaaaaaa-0000-1111-2222-333333333333)
  assert_contains "$out" "lock acquired: session token" \
    "token: a Windows session with a token must acquire the lock"
  assert_present "$home/state/.lock" "token: the lock file must still be written"
  lock=$(cat "$home/state/.lock")
  case "$lock" in
    ''|*[!0-9]*) fail "token: state/.lock must stay a plain numeric pid, got '$lock'" ;;
  esac
  [ "$(cat "$home/state/.lock.session")" = aaaaaaaa-0000-1111-2222-333333333333 ] \
    || fail "token: the session token must be recorded as the ownership authority, got '$(cat "$home/state/.lock.session")'"
  pass "session token: acquires on Windows, records the token, and keeps state/.lock a plain numeric pid"
}

test_same_session_reacquisition_is_idempotent() {
  local home out
  home=$(new_home)
  run_lock "$home" "$WIN" bbbbbbbb-0000-1111-2222-333333333333 >/dev/null
  out=$(run_lock "$home" "$WIN" bbbbbbbb-0000-1111-2222-333333333333)
  assert_contains "$out" "lock acquired: session token" \
    "token: the same session must re-acquire its own lock, not fight the dead pid it recorded"
  pass "session token: re-acquisition by the same session is idempotent"
}

test_a_later_session_reclaims_an_exited_one() {
  local home out
  home=$(new_home)
  run_lock "$home" "$WIN" cccccccc-0000-1111-2222-333333333333 >/dev/null
  # Age the claim past the refusal window: the earlier session exited, so its
  # token stopped being refreshed. This is the sequential case, and it must
  # self-heal without an operator touching anything.
  touch -d '10 hours ago' "$home/state/.lock.session" 2>/dev/null \
    || touch -A -100000 "$home/state/.lock.session" 2>/dev/null \
    || { pass "skip: this platform's touch cannot age a file for the reclaim case"; return 0; }
  out=$(run_lock "$home" "$WIN" dddddddd-0000-1111-2222-333333333333)
  assert_contains "$out" "lock acquired: session token" \
    "token: a later session must reclaim a home whose owner exited"
  [ "$(cat "$home/state/.lock.session")" = dddddddd-0000-1111-2222-333333333333 ] \
    || fail "token: the reclaiming session must become the recorded owner"
  pass "session token: a later session reclaims a home whose previous session exited"
}

# --- 4. concurrency refusal --------------------------------------------------

test_a_live_peer_token_refuses_rather_than_co_owning() {
  local home out
  home=$(new_home)
  run_lock "$home" "$WIN" eeeeeeee-0000-1111-2222-333333333333 >/dev/null
  # A second concurrent session. The recorded pid is dead - it always is on this
  # path - so without the token check this would silently reclaim and both
  # sessions would believe they own the fleet.
  out=$(run_lock "$home" "$WIN" ffffffff-0000-1111-2222-333333333333)
  assert_contains "$out" "another firstmate session holds the lock" \
    "token: SECURITY - a live peer's token must refuse, never co-own"
  [ "$(cat "$home/state/.lock.session")" = eeeeeeee-0000-1111-2222-333333333333 ] \
    || fail "token: a refused acquisition must not overwrite the holder's token"
  pass "session token: a concurrent session is refused instead of silently co-owning the home"
}

test_ownership_predicate_matches_only_the_recorded_token() {
  # shellcheck disable=SC2031 # Read in the parent; the subshells below never write it back.
  local home saved=$FM_PROC_UNAME_S
  home=$(new_home)
  printf '%s\n' 99999 > "$home/state/.lock"
  printf '%s\n' 12345678-0000-1111-2222-333333333333 > "$home/state/.lock.session"
  # The walk is stubbed empty in each subshell: this runner usually has a real
  # harness ancestry of its own, which would take the ancestry branch and never
  # reach the token path under test.
  FM_PROC_UNAME_S=$WIN
  (
    # shellcheck disable=SC2329 # Called indirectly by fm_session_lock_owned_by_self.
    fm_harness_ancestry_pids() { return 1; }
    # shellcheck disable=SC2030 # Confining the token to this subshell is the point.
    export CLAUDE_CODE_SESSION_ID=12345678-0000-1111-2222-333333333333
    fm_session_lock_owned_by_self "$home/state"
  ) || { FM_PROC_UNAME_S=$saved; fail "token: the recorded token's holder must read as the owner"; }
  (
    # shellcheck disable=SC2329 # Called indirectly by fm_session_lock_owned_by_self.
    fm_harness_ancestry_pids() { return 1; }
    # shellcheck disable=SC2031 # Each subshell starts from the parent's value by design.
    export CLAUDE_CODE_SESSION_ID=87654321-0000-1111-2222-333333333333
    fm_session_lock_owned_by_self "$home/state"
  ) && { FM_PROC_UNAME_S=$saved; fail "token: SECURITY - a different token must never read as the owner"; }
  (
    # shellcheck disable=SC2329 # Called indirectly by fm_session_lock_owned_by_self.
    fm_harness_ancestry_pids() { return 1; }
    unset CLAUDE_CODE_SESSION_ID
    fm_session_lock_owned_by_self "$home/state"
  ) && { FM_PROC_UNAME_S=$saved; fail "token: no token of our own is not ownership"; }
  FM_PROC_UNAME_S=$saved
  pass "fm_session_lock_owned_by_self: on the token path, ownership is the recorded token and nothing else"
}

test_malformed_token_records_are_refused() {
  local home saved=$FM_PROC_UNAME_S
  home=$(new_home)
  FM_PROC_UNAME_S=$WIN
  printf 'one two\n' > "$home/state/.lock.session"
  fm_session_token_recorded "$home/state" >/dev/null 2>&1 \
    && { FM_PROC_UNAME_S=$saved; fail "token: a whitespace-bearing record must be refused"; }
  printf 'a\nb\n' > "$home/state/.lock.session"
  fm_session_token_recorded "$home/state" >/dev/null 2>&1 \
    && { FM_PROC_UNAME_S=$saved; fail "token: a multi-line record must be refused"; }
  rm -f "$home/state/.lock.session"
  ln -s /etc/hostname "$home/state/.lock.session" 2>/dev/null
  fm_session_token_recorded "$home/state" >/dev/null 2>&1 \
    && { FM_PROC_UNAME_S=$saved; fail "token: SECURITY - a symlinked record must be refused"; }
  FM_PROC_UNAME_S=$saved
  pass "fm_session_token_recorded: refuses whitespace, multi-line, and symlinked records"
}


# --- 5. release on session end ----------------------------------------------

# The measured Windows gap this closes. Ownership is the token, and the recorded
# pid on this path is always dead, so nothing about an EXITED session looks
# different from a live one until its token goes stale. Before the release hook
# a restart was refused for the whole freshness window - four hours of a
# read-only home after every ordinary quit.
test_release_lets_the_next_session_acquire_immediately() {
  local home out
  home=$(new_primary_home)
  out=$(run_lock "$home" "$WIN" 1111aaaa-0000-1111-2222-333333333333)
  assert_contains "$out" "lock acquired: session token" "release: the first session must acquire"
  run_release "$home" 1111aaaa-0000-1111-2222-333333333333
  assert_absent "$home/state/.lock.session" "release: an ending session must drop its own token"
  assert_present "$home/state/.lock" \
    "release: state/.lock must be left alone so the unchanged dead-owner reclaim still applies"
  # No ageing anywhere: this is the ordinary restart, seconds later.
  out=$(run_lock "$home" "$WIN" 2222bbbb-0000-1111-2222-333333333333)
  assert_contains "$out" "lock acquired: session token" \
    "release: the next session must acquire at once, not wait out the freshness window"
  pass "session end: releasing the token lets the very next session acquire without waiting"
}

test_release_never_evicts_another_session() {
  local home
  home=$(new_primary_home)
  run_lock "$home" "$WIN" 3333cccc-0000-1111-2222-333333333333 >/dev/null
  # Some other session ends. It must not be able to hand this home to anyone.
  run_release "$home" 4444dddd-0000-1111-2222-333333333333
  [ "$(cat "$home/state/.lock.session" 2>/dev/null)" = 3333cccc-0000-1111-2222-333333333333 ] \
    || fail "release: SECURITY - a foreign session's end must never clear the holder's token"
  # A session with no token of its own must be equally powerless.
  run_release "$home" ""
  [ "$(cat "$home/state/.lock.session" 2>/dev/null)" = 3333cccc-0000-1111-2222-333333333333 ] \
    || fail "release: SECURITY - a tokenless end must never clear the holder's token"
  pass "session end: the release clears only a token this session owns"
}

# Off the token path there is no token to release, and the release must not
# invent one or disturb an ancestry-owned lock.
test_release_is_inert_on_an_ancestry_owned_home() {
  local home
  home=$(new_primary_home)
  printf '%s\n' 4242 > "$home/state/.lock"
  run_release "$home" 5555eeee-0000-1111-2222-333333333333
  [ "$(cat "$home/state/.lock")" = 4242 ] \
    || fail "release: an ancestry-owned lock must be left exactly as it was"
  assert_absent "$home/state/.lock.session" "release: no token may be created by the release"
  pass "session end: inert on a home that records no token"
}

# The other half of the same predicate: a walk that is MISSING is not a walk
# that answered "nobody".
#
# CONTRACT: fm_session_ancestry_unavailable must never report "ancestry
# structurally cannot answer" on evidence it did not gather. The walk lives in
# bin/fm-session-lock-lib.sh, which sources bin/fm-session-token-lib.sh, so a
# consumer that sources the token lib alone would get 127 from the walk call,
# skip the refusal it guards, and open the token acquisition path - granting the
# fleet lock on an unmeasured claim. Refusing leaves the home read-only and
# falls back on upstream's own ancestry refusal.
#
# Driven in a fresh bash rather than a subshell because a subshell inherits
# fm_harness_ancestry_pids from this file's own source line, which is exactly
# the condition being excluded.
test_ancestry_unavailable_refuses_when_the_walk_itself_is_absent() {
  local rc=0
  bash -c '
    set -u
    . "$1/bin/fm-session-token-lib.sh"
    command -v fm_harness_ancestry_pids >/dev/null 2>&1 \
      && { printf "fixture: fm_harness_ancestry_pids must NOT be defined here\n" >&2; exit 2; }
    FM_PROC_UNAME_S=$2
    fm_session_ancestry_unavailable
  ' _ "$ROOT" "$WIN" || rc=$?
  [ "$rc" = 2 ] && fail "token: the fixture failed to isolate bin/fm-session-token-lib.sh from the ancestry walk"
  [ "$rc" = 0 ] \
    && fail "token: SECURITY - a MISSING ancestry walk must not read as one that structurally cannot answer; the token acquisition path was opened on evidence never gathered"
  pass "fm_session_ancestry_unavailable: refuses when the ancestry walk is not available to be asked"
}

test_token_is_ignored_where_ancestry_actually_works
test_ancestry_unavailable_requires_both_platform_and_empty_walk
test_ancestry_unavailable_refuses_when_the_walk_itself_is_absent
test_the_windows_refusal_names_the_token_not_ancestry
test_token_acquires_and_records_a_plain_pid
test_same_session_reacquisition_is_idempotent
test_a_later_session_reclaims_an_exited_one
test_a_live_peer_token_refuses_rather_than_co_owning
test_ownership_predicate_matches_only_the_recorded_token
test_malformed_token_records_are_refused
test_release_lets_the_next_session_acquire_immediately
test_release_never_evicts_another_session
test_release_is_inert_on_an_ancestry_owned_home
