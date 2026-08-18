#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-pane discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names and precedence are unchanged from when this logic lived inline
# in bin/fm-supervise-daemon.sh, so its unit tests (tests/fm-daemon.test.sh)
# keep exercising the same names after the daemon sources this file.

# Default supervisor pane target when nothing is configured or detected.
# "firstmate:0" is a tmux session:window name, so the bare target fallback stays
# the daemon's pre-herdr behavior byte-for-byte. It is deliberately NOT made
# backend-aware: no other session provider has a conventional "firstmate's own
# pane" name to guess, and a wrong guess would inject into someone else's pane.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"

# Last-resort supervisor backend when nothing is configured and nothing is
# detected. The literal below is the value used when this file is sourced on its
# own; fm_supervisor_default_backend prefers the home's OWN resolved backend when
# bin/fm-backend.sh is loaded (both real callers load it). Naming tmux
# unconditionally meant a home not running tmux was told its supervisor pane "is
# not a tmux pane" when the real answer is that its own backend is the one the
# daemon has no injection primitives for.
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# fm_supervisor_default_backend: the bare fallback's backend. On a tmux home
# fm_backend_name returns tmux, so this is unchanged there; it is only a home
# running something else that stops being described as tmux.
fm_supervisor_default_backend() {
  local resolved=''
  if command -v fm_backend_name >/dev/null 2>&1; then
    # 2>/dev/null: fm_backend_name's herdr/cmux auto-detect NOTICE is spawn-time
    # advice, not a diagnostic for resolving the captain's own pane.
    resolved=$(fm_backend_name 2>/dev/null) || resolved=''
  fi
  [ -n "$resolved" ] || resolved=$FM_SUPERVISOR_BACKEND_DEFAULT
  printf '%s' "$resolved"
}

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - may be a tmux target or a
#      herdr "<session>:<pane-id>" target (paired with discover_supervisor_backend
#      to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   4. FM_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if the
#      session is named differently). Returns 1 so the caller can warn.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. fm_supervisor_default_backend - the home's own resolved backend, or the
#      literal tmux default when bin/fm-backend.sh is not loaded. Returns 1.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  fm_supervisor_default_backend
  return 1
}
