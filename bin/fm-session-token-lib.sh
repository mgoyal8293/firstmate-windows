#!/usr/bin/env bash
# Per-session ownership tokens, and the refusals bin/fm-lock.sh prints on that
# path.
#
# bin/fm-session-lock-lib.sh remains the single owner of harness IDENTITY - the
# ancestry walk, FM_HARNESS_RE, holder liveness - and sources this file, so every
# consumer of that library keeps reaching these functions unchanged.
# bin/fm-lock.sh remains the single owner of the acquisition SEQUENCE: which
# evidence it consults, in what order, and where under the claim lock each check
# sits. That ordering is load-bearing and is deliberately NOT restated here.
# This file owns the token mechanism itself, and lives apart from both so each of
# those owners carries a call rather than the mechanism.
#
# fm_session_ancestry_unavailable calls fm_harness_ancestry_pids from
# bin/fm-session-lock-lib.sh, which sources this file, so the walk is defined by
# the time anything here runs.

# Loaded only when it is not already here, and re-loaded whenever the platform
# seam disagrees with what is loaded, so a test that sets
# FM_PLATFORM_UNAME_OVERRIDE still gets its Windows arm.
# Every sourcer of this file that matters is on a poll path - bin/fm-wake-lib.sh
# alone is re-sourced from inside bin/fm-pending-reply-lib.sh once per unresolved
# record per watcher tick - and it has already loaded bin/fm-proc-lib.sh by the
# time it reaches here, so the common case must cost nothing.
# `${BASH_SOURCE[0]%/*}` rather than `$(dirname ...)` for the same reason: a
# command substitution plus a dirname exec, paid on every one of those sources.
if ! command -v fm_platform_is_windows >/dev/null 2>&1 \
  || [ "${FM_PLATFORM_UNAME_OVERRIDE:-${FM_PROC_UNAME_S:-}}" != "${FM_PROC_UNAME_S:-}" ]; then
  # shellcheck source=bin/fm-proc-lib.sh
  . "${BASH_SOURCE[0]%/*}/fm-proc-lib.sh"
fi

# ---------------------------------------------------------------------------
# Session tokens: ownership WITHOUT asking "who is my parent"
#
# The ancestry walk in bin/fm-session-lock-lib.sh is the original and still the
# primary path, and every platform that can answer it keeps using it unchanged. It cannot be answered at
# all on the Windows runtimes: MSYS's /proc contains only MSYS processes, so a
# native harness (Claude Code ships claude.exe) never appears in it and the tool
# or hook subprocess it spawns reports ppid 1. The walk ends on hop one, so the
# session lock could never be acquired and a Windows home stayed read-only.
#
# A token answers the ownership question directly instead of inferring it from
# the process tree: the harness exports a value that is stable for the life of
# ONE session and different in every other, so a process holding it is provably
# inside that session. Verified per harness below - never guessed from a name.
#
# Deliberate boundaries, because this sits under the fleet lock:
#   - A token proves IDENTITY, not liveness. Nothing here reports a session
#     alive. Liveness stays with state/.lock's recorded pid and the existing
#     dead-owner reclaim in bin/fm-lock.sh, which is what lets a later session
#     take over from an exited one with no new staleness policy.
#   - No Windows pid is ever recorded. state/.lock keeps holding a plain numeric
#     pid, so bin/fm-bootstrap.sh, bin/fm-claude-stop-autoarm.sh and
#     bin/fm-session-start.sh keep reading exactly what they read today and no
#     caller becomes namespace-aware. The token lives in its own file.
#   - Reading a token is an environment lookup plus one small file read, and the
#     token path itself queries no process table. The gate in front of it does:
#     fm_session_ancestry_unavailable below must prove the ancestry walk found
#     nothing before a token may be honoured, so a process pays that walk once.
#     The memo on that function owns why once is the floor and not zero.
#
# Verified token sources, most specific first. Add a row only after confirming
# the value is present in the harness's OWN tool and hook subprocesses AND is
# distinct between two concurrent sessions.
#
#   claude  CLAUDE_CODE_SESSION_ID  a per-session UUID. Verified on Windows
#           against Claude Code 2.1.220/2.1.200: identical across SessionStart,
#           the Bash tool's PreToolUse, and Stop, and it matches the session_id
#           the hook payload carries on stdin.
FM_SESSION_TOKEN_VARS=(CLAUDE_CODE_SESSION_ID)

# Print this process's session token, or return 1 when none is available.
# A token must look like a token: non-empty, single-line, and free of the
# whitespace that would let a crafted value forge a second field on disk.
fm_session_token_self() {
  local var value
  for var in "${FM_SESSION_TOKEN_VARS[@]}"; do
    eval "value=\${$var:-}"
    [ -n "$value" ] || continue
    case "$value" in
      *[[:space:]]*) continue ;;
    esac
    printf '%s\n' "$value"
    return 0
  done
  return 1
}

fm_session_token_path() {  # <state-dir>
  printf '%s/.lock.session\n' "$1"
}

# Print the token recorded for state dir $1, or return 1.
# Refuses anything that is not a plain single-line regular file, so a directory,
# a symlink or a multi-line file is uncertainty rather than an owner.
fm_session_token_recorded() {  # <state-dir>
  local file value lines
  file=$(fm_session_token_path "$1")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  lines=$(wc -l < "$file" 2>/dev/null | tr -d '[:space:]') || return 1
  [ "${lines:-0}" -le 1 ] || return 1
  IFS= read -r value < "$file" 2>/dev/null || return 1
  [ -n "$value" ] || return 1
  case "$value" in
    *[[:space:]]*) return 1 ;;
  esac
  printf '%s\n' "$value"
}

# Record this process's token for state dir $1, then read it back and prove it.
# Fails rather than reporting a write it could not verify.
fm_session_token_publish() {  # <state-dir>
  local state=$1 file token back
  token=$(fm_session_token_self) || return 1
  file=$(fm_session_token_path "$state")
  [ ! -L "$file" ] || return 1
  { printf '%s\n' "$token" > "$file"; } 2>/dev/null || return 1
  back=$(fm_session_token_recorded "$state") || return 1
  [ "$back" = "$token" ]
}

fm_session_token_clear() {  # <state-dir>
  local file
  file=$(fm_session_token_path "$1")
  [ ! -L "$file" ] || return 0
  rm -f -- "$file" 2>/dev/null || true
}

# True when this process holds the token recorded for state dir $1.
# Both sides must exist: no recorded token, or no token of our own, is not
# ownership.
fm_session_token_owned_by_self() {  # <state-dir>
  local state=$1 mine theirs
  mine=$(fm_session_token_self) || return 1
  theirs=$(fm_session_token_recorded "$state") || return 1
  [ "$mine" = "$theirs" ]
}

# How long a recorded token keeps refusing a DIFFERENT session, in seconds.
#
# This is the one heuristic on the token path, and it exists for a single case:
# two concurrent sessions in one home. A token proves identity but not liveness,
# and no vendor artifact supplies liveness either - Claude Code's per-session
# session-env directory and transcript both survive the process (verified: they
# accumulate, one per session). So "is that other session still running?" is
# answered by whether it has refreshed its own token recently.
#
# Generous on purpose. Refusing a live peer is a correctness requirement; making
# an operator wait after a crash is an inconvenience, and the refusal names the
# exact file to remove. The owning session refreshes on every acquisition and on
# every verified Stop-hook ownership check, so an active session refreshes far
# more often than this bound.
FM_SESSION_TOKEN_STALE_AFTER=${FM_SESSION_TOKEN_STALE_AFTER:-14400}

# Touch the recorded token so a live session keeps its claim fresh. Never
# creates the file: refreshing a claim that was never published is not ownership.
fm_session_token_refresh() {  # <state-dir>
  local file
  file=$(fm_session_token_path "$1")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  touch "$file" 2>/dev/null || return 1
}

# Age in seconds of the recorded token, or return 1 when it cannot be read.
fm_session_token_age() {  # <state-dir>
  local file m now
  file=$(fm_session_token_path "$1")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  if [ "$FM_PROC_UNAME_S" = Darwin ]; then
    m=$(stat -f %m "$file" 2>/dev/null) || return 1
  else
    m=$(stat -c %Y "$file" 2>/dev/null) || return 1
  fi
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s 2>/dev/null) || return 1
  printf '%s\n' "$(( now - m ))"
}

# True when a DIFFERENT session's token holds this home and is recent enough to
# treat as live. Uncertainty is a held lock, not a free one: an unreadable age
# refuses, matching how every other lock proof in the fleet fails safe.
fm_session_token_held_by_other() {  # <state-dir>
  local state=$1 mine theirs age
  theirs=$(fm_session_token_recorded "$state") || return 1
  mine=$(fm_session_token_self 2>/dev/null || true)
  [ "$mine" != "$theirs" ] || return 1
  age=$(fm_session_token_age "$state") || return 0
  [ "$age" -lt "$FM_SESSION_TOKEN_STALE_AFTER" ]
}

# True only where the ancestry walk is STRUCTURALLY unable to answer, which is
# the sole condition under which the token path is consulted.
#
# Both halves are load-bearing, and the platform half is the important one. A
# walk that merely found no harness is NOT the same as a walk that cannot work:
# on Linux and macOS an empty result means this process genuinely is not inside a
# harness session, and honouring a token there would let any process that happens
# to carry the environment variable - a detached tool subprocess, an inherited
# value in a multiplexer's stored environment - claim the fleet lock that the
# ancestry walk correctly refuses it today. On the Windows runtimes the walk can
# never succeed for anyone, because MSYS's /proc holds only MSYS processes and
# the harness is a native executable.
#
# So this is gated on the platform as well, and the whole token path is
# consequently unreachable off Windows: same code, byte-identical behaviour.
#
# MEMOISED for the life of the process, because the answer cannot change within
# one. Not for the steady-state Stop hook, which asks exactly once and saves
# nothing here: bin/fm-claude-stop-autoarm.sh's second ownership check is inside
# its RECOVER_SESSION_LOCK branch and is reached only after the first one fails.
# The memo pays where one process asks more than once, which three callers do:
# that recovery branch, bin/fm-lock.sh where fm_session_token_acquire_eligible
# declines and the predicate is asked again directly, and current_session_still_ours
# in bin/fm-turnend-guard-cursor.sh, which re-checks on every park and rearm step.
# With the fork removal in place the recorded fixed fm_harness_ancestry_pids is
# 392.73 ms, so each repeat call the memo saves is about 0.4 s on Windows
# (docs/verification/windows-session-lock-cost.md).
#
# A memo is the safe fix and REORDERING the caller to try the token first is not:
# a process's own ancestry is fixed for its lifetime, so a second answer cannot
# honestly differ from the first, while consulting the token first would answer a
# DIFFERENT question in the case where the walk does resolve on Windows.
# That case is driven under "Decision preservation" in
# docs/verification/windows-session-lock-cost.md.
#
# Keyed on the platform seam rather than a bare "computed" flag, the same rule
# bin/fm-proc-lib.sh's source guard uses: a test that drives FM_PROC_UNAME_S to a
# second platform in one shell must get a fresh answer, or the Windows arm goes
# vacuous. Both directions are cached, and the cached refusal is the safe one: it
# keeps the home read-only rather than opening the token path.
FM_SESSION_ANCESTRY_MEMO_SEAM=
FM_SESSION_ANCESTRY_MEMO_RC=
fm_session_ancestry_unavailable() {
  if [ -n "$FM_SESSION_ANCESTRY_MEMO_RC" ] \
    && [ "$FM_SESSION_ANCESTRY_MEMO_SEAM" = "${FM_PROC_UNAME_S:-}" ]; then
    return "$FM_SESSION_ANCESTRY_MEMO_RC"
  fi
  FM_SESSION_ANCESTRY_MEMO_SEAM=${FM_PROC_UNAME_S:-}
  FM_SESSION_ANCESTRY_MEMO_RC=1
  fm_platform_is_windows || return 1
  # A missing owner is uncertainty, and uncertainty refuses.
  # The walk lives in bin/fm-session-lock-lib.sh, which sources this file, so a
  # consumer that sources this file alone would otherwise get 127 from the call
  # below, skip the `&& return 1`, and report "ancestry structurally cannot
  # answer" on evidence that was never gathered - opening the token acquisition
  # path and the fleet lock with it. Refusing here leaves the home read-only and
  # falls back on upstream's own ancestry refusal.
  command -v fm_harness_ancestry_pids >/dev/null 2>&1 || return 1
  fm_harness_ancestry_pids >/dev/null 2>&1 && return 1
  FM_SESSION_ANCESTRY_MEMO_RC=0
  return 0
}

# ---------------------------------------------------------------------------
# Acquisition-path refusals and verdicts
#
# Each of these is the BODY of one step in bin/fm-lock.sh's sequence, moved out
# whole. None of them decides where it is called from, and none may be reordered
# against its neighbours by reading this file - that sequence is bin/fm-lock.sh's.
# Every one that refuses prints to stderr and returns 1, leaving the exit to its
# caller.
# ---------------------------------------------------------------------------

# True when this process cannot be placed by ancestry but does carry a token, so
# the token path is the evidence to use.
fm_session_token_acquire_eligible() {
  fm_session_ancestry_unavailable && fm_session_token_self >/dev/null 2>&1
}

# Refuse an acquisition on a host where the ancestry walk cannot answer and this
# process carries no token, which is the one refusal this port owns. The refusal
# for a walk that merely found no harness is upstream's, and stays in
# bin/fm-lock.sh where upstream can reword it.
#
# Windows, and no token. Naming the ancestry walk there would be true and
# useless: on Windows it can NEVER answer for anyone, because MSYS's /proc holds
# only MSYS processes and the harness is a native executable. The actionable fact
# is the missing token, and today only Claude Code exports one
# (FM_SESSION_TOKEN_VARS above). So say that, and say what the reader can do
# about it.
fm_session_token_acquire_refuse() {
  echo "error: no firstmate session token in this environment, so this session cannot prove it owns this home - on Windows ownership is a per-session token, never process ancestry, because a native harness never appears in MSYS's /proc. Only Claude Code exports one today (CLAUDE_CODE_SESSION_ID); under any other harness a Windows firstmate stays read-only - run firstmate from Claude Code, or continue read-only (docs/windows.md 'How the session lock is owned')" >&2
  return 1
}

# Refuse when a DIFFERENT session's token holds this home.
#
# On the token path the recorded pid is always dead, so it can never report a
# live peer. A different, recently refreshed token is that evidence instead;
# without this check two concurrent Windows sessions would both reclaim the lock
# from each other's dead pid and silently co-own the fleet.
fm_session_token_refuse_if_held_by_other() {  # <state-dir>
  local state=$1
  fm_session_token_held_by_other "$state" || return 0
  echo "error: another firstmate session holds the lock for this home; operate read-only until it exits, or remove $state/.lock.session if that session is gone" >&2
  return 1
}

# Publish this session's token, or refuse.
# The caller publishes the ownership authority BEFORE the pid it accompanies and
# proves the write, so a lock file can never name a session whose token was not
# recorded.
fm_session_token_publish_or_refuse() {  # <state-dir>
  fm_session_token_publish "$1" && return 0
  echo "error: cannot record this session's ownership token; operate read-only until resolved" >&2
  return 1
}

# Print the `fm-lock.sh status` verdict for a token-held home, or return 1 when
# no token is recorded so the caller falls back to its own pid verdict.
#
# A token-path lock always records a dead pid, so reporting it as stale would be
# wrong: the token, not the pid, is what holds this home.
fm_session_token_status_line() {  # <state-dir>
  local state=$1
  fm_session_token_recorded "$state" >/dev/null 2>&1 || return 1
  if fm_session_token_owned_by_self "$state"; then
    echo "lock: held by this session's token"
  elif fm_session_token_held_by_other "$state"; then
    echo "lock: held by another session's token"
  else
    echo "lock: stale (token last refreshed over ${FM_SESSION_TOKEN_STALE_AFTER}s ago)"
  fi
}
