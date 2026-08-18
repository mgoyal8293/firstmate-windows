#!/usr/bin/env bash
# tests/fm-windows-portability.test.sh - the four capability substitutions that
# let firstmate run on Git for Windows, tested by SIMULATING the capability that
# is missing rather than by needing that platform.
#
# Each case pins one blocker from the Windows port inventory:
#   1. bin/fm-proc-lib.sh's fm_proc_field reads the MSYS/Cygwin /proc scalar
#      files, because MSYS `ps` rejects -o outright and every ancestry walk,
#      liveness read and process-group check would otherwise conclude the pid
#      does not exist. Its `ps` fallback must stay byte-compatible so no POSIX
#      host changes behavior.
#   2. fm_platform_enable_native_symlinks makes `ln -s` a real link there,
#      because the default copy can never satisfy the readlink validation in
#      fm_lock_try_create and every lock in the fleet then spins forever.
#   3. fm_proc_pids_with_cwd_under replaces the absent lsof, because Windows
#      also physically REFUSES to delete a directory a live process sits in.
#
# The fourth blocker - the private-file mode assertion - is a security boundary
# and has its own file: tests/fm-pr-private-file-mode.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-proc-lib.sh"

# Build a fake MSYS-shaped /proc: per-pid scalar files instead of Linux's stat.
fake_msys_proc() {  # <root> <pid> <ppid> <pgid> <sid> <exename> <arg>...
  local root=$1 pid=$2 ppid=$3 pgid=$4 sid=$5 exename=$6
  shift 6
  mkdir -p "$root/$pid"
  printf '%s\n' "$ppid" > "$root/$pid/ppid"
  printf '%s\n' "$pgid" > "$root/$pid/pgid"
  printf '%s\n' "$sid" > "$root/$pid/sid"
  printf '%s\n' "$exename" > "$root/$pid/exename"
  {
    printf '%s\0' "$exename"
    local a
    for a in "$@"; do printf '%s\0' "$a"; done
  } > "$root/$pid/cmdline"
}

# --- 1. ps -o -> /proc -----------------------------------------------------

test_proc_field_reads_msys_layout() {
  local root out
  root=$(fm_test_tmproot fm-proc) || fail "proc-field: could not create a fixture root"
  fake_msys_proc "$root" 4242 1 4242 4242 '/c/nvm4w/nodejs/node' \
    'C:\Users\x\AppData\Local\claude\versions\2.1.220\claude.js' --resume
  FM_PROC_ROOT_OVERRIDE=$root

  out=$(fm_proc_field 4242 ppid) || fail "proc-field: ppid read failed"
  [ "$out" = 1 ] || fail "proc-field: ppid expected 1, got '$out'"
  out=$(fm_proc_field 4242 pgid) || fail "proc-field: pgid read failed"
  [ "$out" = 4242 ] || fail "proc-field: pgid expected 4242, got '$out'"
  out=$(fm_proc_field 4242 sid) || fail "proc-field: sid read failed"
  [ "$out" = 4242 ] || fail "proc-field: sid expected 4242, got '$out'"
  out=$(fm_proc_field 4242 comm) || fail "proc-field: comm read failed"
  [ "$out" = '/c/nvm4w/nodejs/node' ] || fail "proc-field: comm expected the exename path, got '$out'"

  # args must be the space-joined argv with no trailing separator, exactly the
  # shape `ps -o args=` produces, because callers match it as one string.
  out=$(fm_proc_field 4242 args) || fail "proc-field: args read failed"
  case "$out" in
    *'claude.js --resume') : ;;
    *) fail "proc-field: args must join argv with spaces and not trail, got '$out'" ;;
  esac
  unset FM_PROC_ROOT_OVERRIDE
  pass "fm_proc_field: reads comm/args/ppid/pgid/sid from the MSYS /proc layout"
}

test_proc_field_falls_back_to_ps_where_proc_is_absent() {
  local root out
  root=$(fm_test_tmproot fm-proc) || fail "proc-field: could not create a fixture root"
  # An EMPTY fake /proc forces the portable `ps -o` path. Where that form works
  # at all - Linux, macOS - it must answer unchanged, which is what keeps this
  # substitution invisible off Windows. Where it does not (MSYS `ps` rejects -o
  # outright, the blocker this whole file exists for) there is nothing to fall
  # back TO, and the caller correctly reads the pid as unreadable.
  FM_PROC_ROOT_OVERRIDE=$root
  if LC_ALL=C ps -o ppid= -p "$$" >/dev/null 2>&1; then
    out=$(fm_proc_field "$$" ppid | tr -d '[:space:]') \
      || fail "proc-field: the ps fallback did not answer for a live pid"
    case "$out" in
      ''|*[!0-9]*) fail "proc-field: the ps fallback returned a non-numeric ppid '$out'" ;;
    esac
    unset FM_PROC_ROOT_OVERRIDE
    pass "fm_proc_field: falls back to ps -o where the /proc scalar files are absent"
  else
    out=$(fm_proc_field "$$" ppid 2>/dev/null | tr -d '[:space:]') || true
    [ -z "$out" ] \
      || fail "proc-field: this platform has no working ps -o, so the fallback must produce nothing, got '$out'"
    unset FM_PROC_ROOT_OVERRIDE
    pass "fm_proc_field: on a platform whose ps rejects -o the fallback answers nothing rather than something wrong"
  fi
}

test_proc_field_rejects_bad_input() {
  FM_PROC_ROOT_OVERRIDE=/nonexistent-proc-root
  fm_proc_field '' ppid >/dev/null 2>&1 && fail "proc-field: an empty pid must not succeed"
  fm_proc_field 'not-a-pid' ppid >/dev/null 2>&1 && fail "proc-field: a non-numeric pid must not succeed"
  unset FM_PROC_ROOT_OVERRIDE
  pass "fm_proc_field: refuses an empty or non-numeric pid"
}

test_proc_field_rejects_unknown_field() {
  local root
  root=$(fm_test_tmproot fm-proc) || fail "proc-field: could not create a fixture root"
  fake_msys_proc "$root" 77 1 77 77 /usr/bin/bash
  FM_PROC_ROOT_OVERRIDE=$root
  fm_proc_field 77 lstart >/dev/null 2>&1 \
    && fail "proc-field: an unmapped field must not silently succeed on the /proc path"
  unset FM_PROC_ROOT_OVERRIDE
  pass "fm_proc_field: refuses a field it has no /proc equivalent for"
}

# --- 2. symlink capability --------------------------------------------------

test_symlink_probe_proves_rather_than_assumes() {
  local root
  root=$(fm_test_tmproot fm-symlink) || fail "symlink-probe: could not create a fixture root"
  mkdir -p "$root/probe"
  fm_platform_symlink_probe "$root/probe" \
    || fail "symlink-probe: a filesystem that supports symlinks must probe true"
  # The probe must leave nothing behind, because it runs at every session start.
  [ -z "$(ls -A "$root/probe")" ] \
    || fail "symlink-probe: left artifacts behind: $(ls -A "$root/probe")"
  fm_platform_symlink_probe "$root/definitely-absent" \
    && fail "symlink-probe: a missing directory must probe false, not true"
  pass "fm_platform_symlink_probe: proves symlink creation and leaves no residue"
}

test_native_symlink_mode_is_set_and_preserves_operator_choice() {
  local out
  # The exported normalisation is what the whole lock layer depends on, so it is
  # asserted on the platform it applies to and asserted INERT everywhere else.
  out=$(MSYS= bash -c ". '$ROOT/bin/fm-proc-lib.sh'; printf '%s' \"\${MSYS:-}\"")
  if fm_platform_is_windows; then
    case "$out" in
      *winsymlinks:nativestrict*) : ;;
      *) fail "native-symlinks: MSYS must carry winsymlinks:nativestrict, got '$out'" ;;
    esac
  else
    [ -z "$out" ] \
      || fail "native-symlinks: must stay inert off Windows, but MSYS became '$out'"
  fi
  # An operator who already expressed a winsymlinks preference keeps it verbatim.
  out=$(MSYS=winsymlinks:lnk bash -c ". '$ROOT/bin/fm-proc-lib.sh'; printf '%s' \"\$MSYS\"")
  [ "$out" = winsymlinks:lnk ] \
    || fail "native-symlinks: an existing winsymlinks preference must be preserved, got '$out'"
  pass "fm_platform_enable_native_symlinks: sets nativestrict on Windows, inert elsewhere, never overrides an explicit choice"
}

# --- 3. lsof -> /proc cwd scan ---------------------------------------------

test_proc_cwd_scan_finds_processes_rooted_under_a_directory() {
  local root work pid found
  fm_proc_scan_available || {
    pass "skip: this platform exposes no /proc cwd links, so the lsof substitute cannot be exercised here"
    return 0
  }
  root=$(fm_test_tmproot fm-cwd) || fail "cwd-scan: could not create a fixture root"
  work="$root/wt/sub"
  mkdir -p "$work"
  ( cd "$work" && exec sleep 30 ) &
  pid=$!
  # Give the child time to reach its exec; the scan reads a live /proc entry.
  sleep 1
  found=$(fm_proc_pids_with_cwd_under "$root/wt" | grep -c "^$pid$" || true)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$found" = 1 ] \
    || fail "cwd-scan: a process whose cwd is under the root was not found (pid $pid)"
  found=$(fm_proc_pids_with_cwd_under "$root/wt" | grep -c "^$pid$" || true)
  [ "$found" = 0 ] \
    || fail "cwd-scan: a dead process must not still be reported under the root"
  pass "fm_proc_pids_with_cwd_under: finds live processes rooted under a directory and forgets dead ones"
}

test_proc_cwd_scan_reports_scan_failure_distinctly() {
  FM_PROC_ROOT_OVERRIDE=/definitely-not-a-proc-root
  fm_proc_pids_with_cwd_under /tmp >/dev/null 2>&1 \
    && fail "cwd-scan: an impossible scan must return non-zero, never a proven-empty result"
  unset FM_PROC_ROOT_OVERRIDE
  # This is the fail-safe half: teardown reads a non-zero return as "cannot
  # determine leaked processes" and REFUSES, rather than deleting a worktree
  # something is still sitting in.
  pass "fm_proc_pids_with_cwd_under: an unusable /proc returns failure, not an empty result"
}

test_proc_field_reads_msys_layout
test_proc_field_falls_back_to_ps_where_proc_is_absent
test_proc_field_rejects_bad_input
test_proc_field_rejects_unknown_field
test_symlink_probe_proves_rather_than_assumes
test_native_symlink_mode_is_set_and_preserves_operator_choice
test_proc_cwd_scan_finds_processes_rooted_under_a_directory
test_proc_cwd_scan_reports_scan_failure_distinctly
