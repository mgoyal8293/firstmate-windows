#!/usr/bin/env bash
# Path-spelling helpers for hosts where one location has more than one name.
#
# The MSYS runtimes reach the same file through several spellings: a mount table
# aliases POSIX prefixes, and a native tool needs the Windows form of a path bash
# handed it in POSIX form.
# Both helpers below answer a question their caller already owned; they live here
# so those upstream owners - bin/fm-wake-lib.sh and bin/fm-spawn.sh - carry a
# call rather than the mechanism.
# Neither helper is Windows-only by platform test: each probes for cygpath, the
# tool that owns the mount table, so a runtime without it keeps the caller's
# original answer.
#
# fm_path_gotmpdir_export_line requires shell_quote from its caller
# (bin/fm-spawn.sh defines it, as do bin/fm-brief.sh and bin/fm-bootstrap.sh).

# shellcheck source=bin/fm-proc-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-proc-lib.sh"

# True when two path spellings name the same location.
#
# The raw string compare in fm_lock_points_to_owner is the fast path and stays
# authoritative everywhere it succeeds. It needs a fallback on the Windows
# runtimes because a NATIVE symlink stores a Windows target, and MSYS reads it
# back through its mount table in that path's canonical POSIX spelling - which
# is not necessarily the spelling that was passed to `ln -s`. A home under the
# Windows temp directory is the case that bites: it is created as
# /c/Users/<user>/AppData/Local/Temp/... and reads back as /tmp/..., because the
# mount table aliases the two. Measured on Git-for-Windows MINGW64.
#
# Without this, fm_lock_try_create's validation never matches, the lock is never
# acquired, and fm_lock_acquire_wait spins forever - the exact wedge the
# winsymlinks fix was meant to remove, reintroduced one layer up.
#
# `cd ... && pwd -P` deliberately is NOT the resolver here: it canonicalises
# symlinked COMPONENTS but preserves the mount alias, so it returns the two
# spellings unchanged and answers this question wrongly (measured). cygpath is
# the tool that owns the mount table, so it is the one that can answer it, and
# its presence is the capability probe - no platform name is tested, and on a
# runtime without cygpath the strict string compare above remains the only
# verdict. This can therefore widen a match, never silently accept an
# unresolvable one.
fm_lock_same_path() {
  local a=$1 b=$2 wa wb
  [ -n "$a" ] && [ -n "$b" ] || return 1
  command -v cygpath >/dev/null 2>&1 || return 1
  wa=$(cygpath -m -- "$a" 2>/dev/null) || return 1
  wb=$(cygpath -m -- "$b" 2>/dev/null) || return 1
  [ -n "$wa" ] && [ -n "$wb" ] || return 1
  [ "$wa" = "$wb" ]
}

# Print the `export GOTMPDIR=<dir>` line for a task's pane shell.
#
# The EXPORTED form is not always the POSIX one. MSYS converts paths in argv but
# never in the environment, so a native Go exe handed the POSIX /tmp/fm-<id>/gotmp
# looks for \tmp\fm-<id>\gotmp off the current drive and Go's build temp lands
# somewhere teardown will not clean.
# Only the exported value is translated; the caller's own directory variable stays
# POSIX, because bash created the directory and fm-teardown.sh (via tasktmp= in the
# task's metadata) is the only reader of it.
# The exported literal is quoted on Windows, not just translated, because the
# Windows form carries backslashes the pane shell would otherwise read as escapes.
# Off Windows the literal stays byte-identical to what it has always been, so no
# backend's send log changes.
fm_path_gotmpdir_export_line() {  # <posix-gotmpdir>
  local dir=$1 win
  if fm_platform_is_windows && command -v cygpath >/dev/null 2>&1; then
    win=$(cygpath -w "$dir" 2>/dev/null || true)
    if [ -n "$win" ]; then
      printf 'export GOTMPDIR=%s\n' "$(shell_quote "$win")"
      return 0
    fi
  fi
  printf 'export GOTMPDIR=%s\n' "$dir"
}
