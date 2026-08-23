#!/usr/bin/env bash
# Symlink preflight detectors for the session-start bootstrap.
#
# bin/fm-bootstrap.sh remains the single owner of the detect-only bootstrap
# contract and of the diagnostic-line vocabulary these two emit; its header
# documents the PLATFORM line. They live here so that owner carries two calls
# rather than the mechanism.
#
# Both read the caller's resolved home layout - STATE, FM_HOME and FM_ROOT - and
# both print a PLATFORM diagnostic line rather than returning a verdict, exactly
# as they did inside bin/fm-bootstrap.sh's detect_local_config.

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

# Symlink preflight. PROVES the lock layer can work here rather than assuming it.
#
# Every lock in the fleet - the session lock, the watcher lock, the wake queue,
# the per-meta locks - is created by fm_lock_try_create as a symlink and
# validated with readlink. Default Git for Windows answers `ln -s` of a directory
# with a recursive COPY, which never validates, so fm_lock_acquire_wait spins
# forever and the failed attempt leaves a stray directory wedged at the lock
# path. bin/fm-proc-lib.sh sets winsymlinks:nativestrict on source to prevent
# that, but the mode needs Developer Mode or SeCreateSymbolicLinkPrivilege and
# fails where the account has neither - which is silent unless something checks.
#
# So this creates a throwaway symlink in the home's own state directory and
# reports what actually came back. Run everywhere, not just on Windows: the same
# proof is the honest answer on any filesystem that cannot make one.
#
# state/ specifically, because the filesystem holding the locks is the one whose
# capability matters and TMPDIR is often a different mount. The probe is a
# uniquely named artifact removed on both paths, so it is safe in a lock-refused
# read-only session: it records nothing and leaves no fleet state behind.
detect_symlink_capability() {
  local probe_dir=$STATE remedy
  [ -d "$probe_dir" ] || probe_dir=$FM_HOME
  [ -d "$probe_dir" ] || return 0
  fm_platform_symlink_probe "$probe_dir" && return 0
  if fm_platform_is_windows; then
    remedy="enable Windows Developer Mode (Settings > System > For developers), or grant this account SeCreateSymbolicLinkPrivilege, then start a new session"
  else
    remedy="the filesystem holding $probe_dir cannot create symlinks; move this home to one that can"
  fi
  echo "PLATFORM: cannot create a symlink in $probe_dir, so no fleet lock can ever be acquired and every lock wait would spin - $remedy"
}

# Repository symlink preflight. The repo's one tracked symlink is
# .claude/skills -> ../.agents/skills, and Git for Windows ships
# core.symlinks=false by default, which checks that blob out as a PLAIN FILE
# containing the target path. The directory then does not resolve and the harness
# sees zero project skills - with no error anywhere.
detect_repo_symlink_checkout() {
  local link=$FM_ROOT/.claude/skills
  [ -e "$link" ] || [ -L "$link" ] || return 0
  [ ! -L "$link" ] || return 0
  [ -f "$link" ] || return 0
  grep -q '^\.\./\.agents/skills$' "$link" 2>/dev/null || return 0
  echo "PLATFORM: $FM_ROOT/.claude/skills was checked out as a plain file, not a symlink, so this home loads no project skills - re-clone or re-check-out with symlinks enabled: git -C $FM_ROOT config core.symlinks true, then git -C $FM_ROOT checkout -- .claude/skills"
}
