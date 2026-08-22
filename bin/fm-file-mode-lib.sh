#!/usr/bin/env bash
# The mode half of bin/fm-pr-lib.sh's private-file trust binding, as one owner.
#
# Split into its own file so that upstream owner carries a source line and one
# predicate call rather than this block inside it.
# bin/fm-pr-lib.sh remains the single owner of the trust binding itself and of
# the other five assertions that carry it; the security rationale for the ONE
# assertion that is capability-gated lives below, because this is the only file
# that can weaken it.
#
# Requires fm_pr_file_mode from bin/fm-pr-lib.sh, which sources this file, so the
# function is defined by the time either predicate here is ever called.

# ---------------------------------------------------------------------------
# Private-file trust binding
#
# SECURITY BOUNDARY, and the ONE owner of a deliberate, platform-scoped
# reduction in it. Read this before touching either function below.
#
# The binding exists so a watcher check script, a poll data sidecar or a
# registration record cannot be SUBSTITUTED between the moment firstmate writes
# it and the moment the watcher executes or trusts it. Five independent
# assertions carry that: the file is a regular file, it is not a symlink, its
# link count is 1, it sits on the pinned device, and (for executable checks) its
# SHA-256 content binding matches the registration.
#
# The exact-mode assertion is the sixth, and it is UNAVAILABLE on Git for
# Windows: every mount is `noacl`, so POSIX modes are synthesised rather than
# stored and `chmod 0600` followed by `stat -c %a` reports 644/755 unchanged.
# The assertion therefore does not weaken there - it fails outright, and with it
# every task PR merge (bin/fm-pr-merge.sh delegates recording to
# bin/fm-pr-check.sh, which cannot arm a poll whose artifacts never validate),
# every custom watcher check, and the bootstrap migration.
#
# So the mode assertion is CAPABILITY-GATED: where chmod genuinely round-trips
# it is enforced exactly as before, and where it provably cannot the remaining
# five assertions carry the binding alone. That is a real reduction in
# protection, not a portability tweak: on such a filesystem firstmate can no
# longer prove the file is unreadable and unwritable by other local accounts,
# only that it is the same regular, single-linked, device-pinned, content-bound
# file it wrote. The compensating control is the location - these paths live
# under the home's own state/ directory - plus the SHA-256 binding, which still
# catches substitution of a check script's CONTENT.
#
# It is deliberately a capability probe rather than a uname test: the question is
# whether THIS filesystem enforces modes, which is also the honest question on a
# POSIX host whose state/ happens to sit on a mount that does not. The captain's
# recorded decision is that this narrow reduction is preferred to changing the
# machine's Git-for-Windows mounts to `acl`.
# ---------------------------------------------------------------------------

FM_PR_MODE_ENFORCED_DIR=
FM_PR_MODE_ENFORCED=

# True when chmod round-trips for files created in directory $1.
# Memoised for the last directory asked about, because these checks run inside
# the watcher's poll loop and every private artifact of a home shares one state/
# directory, so a single-entry memo is a full cache in practice.
fm_pr_mode_enforced() {  # <dir>
  local dir=$1 probe observed
  [ -n "$dir" ] || return 0
  # A missing owner is uncertainty, and uncertainty is enforcement. Both
  # predicates here read the stored mode through fm_pr_file_mode, which
  # bin/fm-pr-lib.sh owns; splitting them into this file made "sourced without
  # that owner" reachable for the first time, and without this the probe below
  # would compare an empty reading against 644, conclude the filesystem does not
  # enforce modes, and WAIVE the assertion. Keep the strict check instead.
  command -v fm_pr_file_mode >/dev/null 2>&1 || return 0
  if [ "$dir" = "$FM_PR_MODE_ENFORCED_DIR" ]; then
    return "$FM_PR_MODE_ENFORCED"
  fi
  # Uncertainty is enforcement: an unprobeable directory keeps the strict check
  # and fails the caller, rather than silently dropping an assertion.
  probe=$(mktemp "$dir/.fm-mode-probe.XXXXXX" 2>/dev/null) || return 0
  # chmod BOTH ways, and away from the mode mktemp already created the file with.
  # A one-way probe is worthless here: mktemp creates at 0600, and a `noacl`
  # filesystem that ignores chmod entirely still reports 600 afterwards, which
  # reads as success. Enforcement means the stored mode actually follows chmod.
  FM_PR_MODE_ENFORCED_DIR=$dir
  FM_PR_MODE_ENFORCED=1
  if chmod 0644 "$probe" 2>/dev/null; then
    observed=$(fm_pr_file_mode "$probe")
    if [ "$observed" = 644 ] && chmod 0600 "$probe" 2>/dev/null; then
      observed=$(fm_pr_file_mode "$probe")
      [ "$observed" = 600 ] && FM_PR_MODE_ENFORCED=0
    fi
  fi
  rm -f "$probe" 2>/dev/null || true
  return "$FM_PR_MODE_ENFORCED"
}

# The mode half of the binding, as one owner-side predicate: true when $1 has
# mode $2, or when this filesystem provably cannot express modes at all.
# Every "is this artifact's mode right?" question in bin/ goes through here so
# the security boundary above has exactly one place to read.
fm_pr_file_mode_is() {  # <path> <mode>
  local path=$1 mode=$2 dir
  [ "$(fm_pr_file_mode "$path")" = "$mode" ] && return 0
  dir=$(dirname -- "$path")
  fm_pr_mode_enforced "$dir" && return 1
  return 0
}
