#!/usr/bin/env bash
# The /proc answer to "does a live process hold this path?", for hosts with no
# lsof.
#
# bin/fm-lock-lib.sh remains the single owner of the git-lock staleness DECISION
# and of the three conditions that proof rests on.
# This file owns only the holder question that its condition 2 asks, answered
# from /proc instead of lsof, and it is a separate file so that owner carries a
# source line and one capability branch rather than this block inside it.
#
# Git for Windows ships no lsof, which would make every abandoned index.lock or
# packed-refs.lock permanently unprovable and leave it for manual removal.
# The /proc scan answers the same question from cwd plus the per-pid fd links.
# Its caller scopes it to Windows on purpose: on a POSIX host a missing lsof is a
# degraded toolchain, and answering "provably no holder" there would START
# proving staleness where that owner has always refused to.
# This file's own uncertainty stays fail-safe either way - a scan that cannot run
# returns "cannot prove".

# shellcheck source=bin/fm-proc-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-proc-lib.sh"

# fm_lock_proc_holder <target>: same contract as fm_lock_lsof_holder, answered
# from /proc - 0 a process holds it (as cwd or an open fd), 1 provably none, 2
# the scan could not run.
fm_lock_proc_holder() {
  local target=$1 out
  out=$(fm_proc_pids_holding_path "$target" 2>/dev/null) || return 2
  [ -z "$out" ] || return 0
  return 1
}

# The /proc counterpart of fm_lock_has_live_holder's lsof body, with the same
# fail-safe defaults: anything other than "provably no holder on both" is live.
fm_lock_proc_has_live_holder() {
  local lock=$1 dir=$2 status
  fm_proc_scan_available || return 0
  if [ -n "$lock" ]; then
    if fm_lock_proc_holder "$lock"; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  if [ -n "$dir" ]; then
    if fm_lock_proc_holder "$dir"; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  return 1
}
