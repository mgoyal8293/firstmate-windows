#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"
# shellcheck source=bin/fm-proc-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-proc-lib.sh"

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# ---------------------------------------------------------------------------
# Session tokens: ownership WITHOUT asking "who is my parent"
#
# The ancestry walk above is the original and still the primary path, and every
# platform that can answer it keeps using it unchanged. It cannot be answered at
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
#   - Reading a token is an environment lookup plus one small file read. Nothing
#     here queries the Windows process table, so the every-turn Stop hook pays
#     no per-turn process-enumeration cost.
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
fm_session_ancestry_unavailable() {
  fm_platform_is_windows || return 1
  fm_harness_ancestry_pids >/dev/null 2>&1 && return 1
  return 0
}

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  # On the Windows runtimes the process table reports native paths
  # (C:\Users\...\claude\...), whose components this POSIX match would never
  # see. Normalising the separator is what lets the SAME component rule identify
  # a version-named Claude Code install there. Confined to those platforms
  # because a backslash is a legal character inside a POSIX path component, and
  # rewriting it elsewhere would invent components that do not exist.
  if fm_platform_is_windows; then
    path=${path//\\//}
  fi
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(fm_proc_field "$pid" comm) || break
    args=$(fm_proc_field "$pid" args)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(fm_proc_field "$pid" ppid | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(fm_proc_field "$pid" comm) || return 1
  args=$(fm_proc_field "$pid" args)
  fm_harness_process_matches "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # Token path, consulted ONLY where the ancestry walk cannot answer at all.
  # The recorded token names the session that acquired this lock, so holding it
  # is the same claim membership below makes - reached without asking who our
  # parent is, which is unanswerable on the Windows runtimes. Ordered after the
  # .lock read on purpose: a home with no lock, or a malformed one, is still not
  # owned by anybody.
  if fm_session_ancestry_unavailable; then
    fm_session_token_owned_by_self "$state"
    return $?
  fi
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
