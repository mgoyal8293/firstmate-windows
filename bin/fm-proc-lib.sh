#!/usr/bin/env bash
# Shared process-table and platform-capability primitives.
#
# ONE owner of the two questions every ancestry walk, reaper, lock holder check
# and stored-identity comparison asks: "what does the process table say about pid
# N?" and "does this platform behave the way POSIX callers assume?". Every such
# read lives here, including fm_pid_identity: a second copy of one of these reads
# is a second answer to the same question, and the copy is the one that rots.
#
# It exists because Git for Windows ships MSYS `ps`, not procps: `ps -o` is
# rejected outright, so every `ps -o comm=`/`args=`/`ppid=`/`pgid=` call fails on
# call one and the caller silently concludes the process does not exist. The same
# runtime exposes a Linux-shaped /proc with an exact equivalent for every field
# firstmate reads, including for the native Windows children MSYS spawned, so the
# fix is a capability read rather than a platform fork.
#
# Detection is by capability, never by uname: the /proc layout is what decides
# whether the fast path is usable, and keying on the platform name would both
# miss runtimes that grow the files and break ones that lose them. Linux and
# macOS have no /proc/<pid>/ppid, so they keep the exact `ps` path they use
# today.
#
# This file is sourced by scripts. Its only effect on source is to normalise the
# MSYS symlink mode below - environment normalisation in the same class as the
# LC_ALL pinning elsewhere in bin/, never a write to fleet state.

# ---------------------------------------------------------------------------
# Platform identity
# ---------------------------------------------------------------------------

# Resolved once at source time: these helpers run inside sub-second poll loops
# and forking uname per call is a measurable cost on exactly the platform
# (Git Bash/MSYS) that already pays the highest fork price.
# FM_PLATFORM_UNAME_OVERRIDE is the same test seam as FM_PROC_ROOT_OVERRIDE
# below: it lets the suite drive the Windows arms from a POSIX runner, which is
# the only way those arms get regression coverage at all before someone runs the
# suite on Windows.
FM_PROC_UNAME_S="${FM_PLATFORM_UNAME_OVERRIDE:-$(uname -s 2>/dev/null || echo unknown)}"
# The same read with the test seam deliberately NOT consulted, for the one thing
# the seam must never reach: the identity string fm_pid_identity prints.
# A capability arm is evaluated now and acted on now, so the suite driving it from
# a POSIX runner is exactly the point. An identity is written once and compared
# later, possibly by another process, so an identity whose bytes moved with the
# seam would mismatch for a live unchanged process - the false-dead verdict this
# file exists to prevent.
FM_PROC_HOST_UNAME_S="$(uname -s 2>/dev/null || echo unknown)"

# True on the Windows POSIX-emulation runtimes: Git for Windows / MSYS2
# (MINGW32_NT-*, MINGW64_NT-*, MSYS_NT-*) and Cygwin (CYGWIN_NT-*).
fm_platform_is_windows() {
  case "$FM_PROC_UNAME_S" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  return 1
}

# Make `ln -s` create a real symlink instead of silently copying.
#
# Default Git for Windows resolves `ln -s` of a directory to a RECURSIVE COPY.
# bin/fm-wake-lib.sh's fm_lock_try_create validates its new lock with readlink,
# so the copy never validates, the lock is never acquired, and
# fm_lock_acquire_wait spins forever on every lock in the fleet. "nativestrict"
# is the mode that both creates a real link and FAILS LOUDLY when the account
# lacks SeCreateSymbolicLinkPrivilege, rather than falling back to the copy that
# leaves a stray directory wedged at the lock path.
#
# An operator who has already expressed a winsymlinks preference keeps it; this
# only fills in the absent case. bin/fm-bootstrap.sh proves the result rather
# than assuming it.
fm_platform_enable_native_symlinks() {
  case "$FM_PROC_UNAME_S" in
    MINGW*|MSYS*)
      case "${MSYS:-}" in
        *winsymlinks*) return 0 ;;
        '') export MSYS=winsymlinks:nativestrict ;;
        *) export MSYS="${MSYS} winsymlinks:nativestrict" ;;
      esac
      ;;
    CYGWIN*)
      case "${CYGWIN:-}" in
        *winsymlinks*) return 0 ;;
        '') export CYGWIN=winsymlinks:nativestrict ;;
        *) export CYGWIN="${CYGWIN} winsymlinks:nativestrict" ;;
      esac
      ;;
  esac
  return 0
}

# Create a throwaway symlink under directory $1 and report what came back.
# 0 a real symlink pointing where it was asked to; 1 anything else - a copy, a
# plain file, or a refusal. Callers use this to PROVE the lock layer can work
# before a session commits to it; nothing here is inferred from the platform.
fm_platform_symlink_probe() {  # <dir>
  local dir=$1 base target link rc=1
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  base=".fm-symlink-probe.$$.$RANDOM"
  target="$dir/$base.target"
  link="$dir/$base.link"
  rm -rf -- "$target" "$link" 2>/dev/null || true
  mkdir -p -- "$target" 2>/dev/null || return 1
  if ln -s -- "$target" "$link" 2>/dev/null \
    && [ -L "$link" ] \
    && [ "$(readlink -- "$link" 2>/dev/null)" = "$target" ]; then
    rc=0
  fi
  rm -rf -- "$link" "$target" 2>/dev/null || true
  return "$rc"
}

# ---------------------------------------------------------------------------
# Process table
# ---------------------------------------------------------------------------

fm_proc_root() {
  printf '%s' "${FM_PROC_ROOT_OVERRIDE:-/proc}"
}

# True when this /proc exposes the Cygwin/MSYS per-pid scalar files
# (ppid, pgid, sid, exename) that stand in for the `ps -o` fields.
# Probed against the pid being asked about, because a pid owned by another user
# is unreadable even where the layout exists, and the `ps` path may still work.
fm_proc_msys_fields_readable() {  # <pid>
  local pid=$1 root
  root=$(fm_proc_root)
  [ -r "$root/$pid/ppid" ]
}

# fm_proc_field <pid> <comm|args|ppid|pgid|sid>
#
# The portable replacement for `ps -o <field>= -p <pid>`, with the SAME output
# shape and the same "print nothing and return non-zero when the pid is gone"
# contract, so a call site converts by substitution alone.
#
# Field map on the MSYS/Cygwin layout:
#   comm -> /proc/<pid>/exename   (a full executable path, like macOS `ps -o comm=`)
#   args -> /proc/<pid>/cmdline   (NUL-separated argv, joined with spaces)
#   ppid -> /proc/<pid>/ppid
#   pgid -> /proc/<pid>/pgid
#   sid  -> /proc/<pid>/sid
fm_proc_field() {  # <pid> <field>
  local pid=$1 field=$2 root value
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  root=$(fm_proc_root)
  if fm_proc_msys_fields_readable "$pid"; then
    case "$field" in
      comm)
        value=$(cat "$root/$pid/exename" 2>/dev/null) || return 1
        ;;
      args)
        [ -r "$root/$pid/cmdline" ] || return 1
        value=$(tr '\0' ' ' < "$root/$pid/cmdline" 2>/dev/null) || return 1
        value=${value%"${value##*[![:space:]]}"}
        ;;
      ppid|pgid|sid)
        value=$(cat "$root/$pid/$field" 2>/dev/null) || return 1
        ;;
      *)
        return 1
        ;;
    esac
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
    return 0
  fi
  LC_ALL=C ps -o "$field=" -p "$pid" 2>/dev/null
}

# fm_pid_identity <pid>
#
# A stable identity for the process at pid $1: two reads of the same live
# process print the same string, and a pid that has since been reused prints a
# different one. Callers store it next to a pid and compare it later, so nothing
# printed here may vary with the wall clock or the caller's locale.
#
# Prefer a Linux-compatible /proc when present: stat field 22 (starttime, clock
# ticks since boot) is immune to the wall-clock steps that re-render the ps
# lstart fallback's date (observed as WSL2 btime drift) and would evict a live
# watcher; combining the full NUL-separated cmdline keeps PID reuse a mismatch
# even on a tick collision.
#
# Detection is by capability for the reason this file's header gives: Git
# Bash/MSYS exposes these compatible files while its Cygwin ps rejects the
# portable fallback's -o fields, so keying on uname would answer nothing there.
fm_pid_identity() {  # <pid>
  local pid=$1 out proc_root stat_line starttime cmdline_hex identity_key
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 19 is proc stat field 22.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    cmdline_hex=$(od -An -v -tx1 "$proc_root/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    identity_key=proc-starttime
    [ "$FM_PROC_HOST_UNAME_S" != Linux ] || identity_key=linux-starttime
    printf '%s=%s cmdline-hex=%s\n' "$identity_key" "$starttime" "$cmdline_hex"
    return 0
  fi
  # Neither the caller's locale nor the caller's terminal width may reach a value
  # that is written once and compared later. LC_ALL=C keeps lstart's date format
  # invariant, which would otherwise mismatch on a non-C locale (e.g. ko_KR) and
  # reject a live watcher. COLUMNS pins the width BSD/Darwin ps takes from an
  # exported COLUMNS, else the terminal, else a roughly 79-column default, and
  # truncates the trailing command column to, which would otherwise make the
  # identity depend on the width of whichever terminal happened to write it.
  out=$(COLUMNS=10000 LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

# fm_pid_identity_legacy_ps <pid>
#
# TRANSITIONAL. The identity read exactly as the release before fm_pid_identity
# owned it wrote it, COLUMNS pin and leading whitespace included, because
# reproducing byte-for-byte what that release stored is this function's entire
# purpose: fm_pid_identity's own ps fallback now pins the same width and differs
# from it only in stripping leading whitespace, so the two are still not
# interchangeable. What classifies a stored value is its format tag, never a
# difference in shape between the two readers.
#
# Call it ONLY to read an identity an older release already wrote into a record.
# Never call it to describe a live process for a new record - fm_pid_identity is
# the one owner of that. Delete this function once no untagged records remain.
fm_pid_identity_legacy_ps() {  # <pid>
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  COLUMNS=10000 LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null
}

# Current working directory of pid $1, or non-zero when it cannot be read.
# On MSYS this resolves for native Windows children too, which is precisely the
# set a teardown reaper cares about.
fm_proc_cwd() {  # <pid>
  local pid=$1 root cwd
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  root=$(fm_proc_root)
  cwd=$(readlink -- "$root/$pid/cwd" 2>/dev/null) || return 1
  [ -n "$cwd" ] || return 1
  printf '%s\n' "$cwd"
}

# True when a /proc scan is a usable substitute for lsof here: the per-pid cwd
# link must actually resolve. Guarded by capability so a caller on a platform
# with lsof keeps using lsof and this stays a fallback.
fm_proc_scan_available() {
  local root
  root=$(fm_proc_root)
  [ -d "$root" ] || return 1
  fm_proc_cwd "$$" >/dev/null 2>&1
}

# Print every pid whose CWD is exactly $1 or below it, one per line.
# The direct replacement for teardown's bounded `lsof -a -d cwd -Fpn` scan, with
# the same "bounded by process count, never a recursive file-tree walk" cost.
# Returns non-zero when no scan could be performed at all, so an uncertain
# result is never mistaken for a proven-empty one.
fm_proc_pids_with_cwd_under() {  # <root-dir>
  local dir=$1 root entry pid cwd scanned=0
  [ -n "$dir" ] || return 1
  root=$(fm_proc_root)
  [ -d "$root" ] || return 1
  for entry in "$root"/[0-9]*; do
    [ -d "$entry" ] || continue
    pid=${entry##*/}
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    scanned=1
    cwd=$(fm_proc_cwd "$pid") || continue
    case "$cwd" in
      "$dir"|"$dir"/*) printf '%s\n' "$pid" ;;
    esac
  done
  [ "$scanned" -eq 1 ]
}

# Print every pid holding path $1 open as its cwd or as any file descriptor.
# Same uncertainty contract as above: non-zero means "could not scan", never
# "provably nobody".
fm_proc_pids_holding_path() {  # <path>
  local path=$1 root entry pid cwd fd target scanned=0
  [ -n "$path" ] || return 1
  root=$(fm_proc_root)
  [ -d "$root" ] || return 1
  for entry in "$root"/[0-9]*; do
    [ -d "$entry" ] || continue
    pid=${entry##*/}
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    scanned=1
    cwd=$(fm_proc_cwd "$pid" 2>/dev/null || true)
    case "$cwd" in
      '') ;;
      "$path"|"$path"/*) printf '%s\n' "$pid"; continue ;;
    esac
    [ -d "$entry/fd" ] || continue
    for fd in "$entry"/fd/*; do
      [ -L "$fd" ] || continue
      target=$(readlink -- "$fd" 2>/dev/null) || continue
      if [ "$target" = "$path" ]; then
        printf '%s\n' "$pid"
        break
      fi
    done
  done
  [ "$scanned" -eq 1 ]
}

fm_platform_enable_native_symlinks
