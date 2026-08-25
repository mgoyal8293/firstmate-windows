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
#   4. fm_lock_same_path lets the same lock validation survive MSYS reading a
#      native symlink back in a DIFFERENT spelling from the one it was given,
#      which is the second way that validation can never match and every lock
#      spins forever.
#   5. fm_pid_identity is served from this same file, because a stored process
#      identity is another `ps -o` read: a second copy elsewhere in bin/ answered
#      nothing on MSYS while this one answers from /proc.
#   6. The root .gitattributes pins an LF working tree for every clone, because
#      Git for Windows defaults core.autocrlf=true and a CRLF checkout makes
#      ShellCheck reject every shell file with SC1017 - the lint gate then says
#      nothing about the code, and assertions compare against strings that grew
#      a \r.
#
# The remaining blocker - the private-file mode assertion - is a security
# boundary and has its own file: tests/fm-pr-private-file-mode.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-proc-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"

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

# bin/fm-proc-lib.sh carries a source guard because it is re-sourced from inside
# functions on poll paths - one session start sourced it 42 times, paying a
# `uname` fork each time, which on MSYS is about 42 ms apiece.
#
# The guard's failure mode is SILENT and lands squarely on this file: keyed on a
# bare "already loaded" flag it would skip the re-source that every case here
# performs after setting FM_PLATFORM_UNAME_OVERRIDE, so every Windows arm above
# would quietly go on testing the host platform and still report ok. So the seam
# half below is the load-bearing assertion, not the skip half.
#
# "Did the prologue re-run?" is observed by clobbering the value the prologue
# assigns and seeing whether a re-source restores it. That needs no fork counter
# and no platform.
test_proc_lib_source_guard_skips_repeats_without_blinding_the_platform_seam() {
  local out cleared
  out=$(
    cd "$ROOT" || exit 1
    . bin/fm-proc-lib.sh
    # A repeat source with an UNCHANGED seam must be skipped: the sentinel
    # survives only if the prologue did not run again.
    FM_PROC_UNAME_S=SENTINEL
    . bin/fm-proc-lib.sh
    printf 'unchanged=%s\n' "$FM_PROC_UNAME_S"
    # A CHANGED seam must re-resolve, or every Windows arm in this file is vacuous.
    FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0
    . bin/fm-proc-lib.sh
    printf 'seam_set=%s windows=%s\n' "$FM_PROC_UNAME_S" \
      "$(fm_platform_is_windows && printf yes || printf no)"
    # Changing it again must be honoured too, not just the first transition.
    FM_PLATFORM_UNAME_OVERRIDE=Linux
    . bin/fm-proc-lib.sh
    printf 'seam_changed=%s windows=%s\n' "$FM_PROC_UNAME_S" \
      "$(fm_platform_is_windows && printf yes || printf no)"
    # Clearing it must return to the real host value rather than sticking.
    # The value cleared FROM is an override no host ever reports, so "did it
    # stick?" is answerable on every platform: a literal MINGW prefix would be
    # unfalsifiable on Linux, where the host value could never look stuck, and
    # would FAIL on a real Git Bash host, whose true uname IS MINGW64_NT-*.
    FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-0.0-fmtest-override
    . bin/fm-proc-lib.sh
    unset FM_PLATFORM_UNAME_OVERRIDE
    . bin/fm-proc-lib.sh
    printf 'seam_cleared=%s\n' "$FM_PROC_UNAME_S"
    # The subshell's LAST command is what `out=$(...)` reports, so without this
    # an earlier `. bin/fm-proc-lib.sh` that died left the `|| fail` below silent
    # and the extraction working on a truncated blob.
    printf 'probe_complete\n'
  ) || fail "sourcing bin/fm-proc-lib.sh repeatedly must not fail"
  assert_contains "$out" 'probe_complete' \
    'the probe subshell must reach its end: without this a source that died midway is invisible, because only the last command status reaches the assignment'

  assert_contains "$out" 'unchanged=SENTINEL' \
    'a repeat source with an unchanged seam must be skipped, not re-run'
  assert_contains "$out" 'seam_set=MINGW64_NT-10.0 windows=yes' \
    'setting FM_PLATFORM_UNAME_OVERRIDE must re-resolve the platform, or every Windows arm here is vacuous'
  assert_contains "$out" 'seam_changed=Linux windows=no' \
    'changing the seam again must re-resolve, not just the first transition'
  # PRESENCE BEFORE EXTRACTION. `${out##*seam_cleared=}` returns $out UNCHANGED
  # when the marker never appears, so both checks below would pass on the whole
  # captured blob - non-empty, and not equal to the override literal. That is the
  # strongest half of this case going vacuous exactly when the thing it measures
  # never ran.
  assert_contains "$out" 'seam_cleared=' \
    'the probe must have printed the cleared-seam marker at all, or the two checks below are extracting from a blob that never contained it'
  cleared=${out##*seam_cleared=}
  cleared=${cleared%%$'\n'*}
  [ -n "$cleared" ] \
    || fail 'clearing the seam must leave a resolved host platform, not an empty one'
  [ "$cleared" != 'MINGW64_NT-0.0-fmtest-override' ] \
    || fail "clearing the seam must re-resolve to the host value, not stick on the override ($cleared)"
  pass "fm-proc-lib.sh: the source guard skips repeat sources without blinding FM_PLATFORM_UNAME_OVERRIDE"
}

test_proc_field_reads_msys_layout() {
  local root out
  root=$(fm_test_tmproot fm-proc) || fail "proc-field: could not create a fixture root"
  fake_msys_proc "$root" 4242 1 4242 4242 '/c/nvm4w/nodejs/node' \
    'C:\Users\x\AppData\Local\claude\versions\2.1.220\claude.js' --resume
  # shellcheck disable=SC2034 # Read by bin/fm-proc-lib.sh fm_proc_root.
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
  # shellcheck disable=SC2034 # Read by bin/fm-proc-lib.sh fm_proc_root.
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
  # shellcheck disable=SC2034 # Read by bin/fm-proc-lib.sh fm_proc_root.
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
  # shellcheck disable=SC2034 # Read by bin/fm-proc-lib.sh fm_proc_root.
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

# The two preflight detectors bin/fm-bootstrap.sh calls at every session start,
# which now live in bin/fm-symlink-preflight-lib.sh. Both answer with a PLATFORM
# diagnostic line rather than a verdict, and BOTH must stay silent on a healthy
# home: this pair runs on every session, so a false positive is a permanent
# scary line, and a false negative is a home whose locks can never be acquired
# or a harness that silently loads zero project skills.
run_symlink_preflight() {  # <home> <root>
  # shellcheck disable=SC2034 # STATE, FM_HOME and FM_ROOT are read as globals by
  # detect_symlink_capability and detect_repo_symlink_checkout in
  # bin/fm-symlink-preflight-lib.sh, which take no arguments.
  (
    STATE="$1/state"
    FM_HOME=$1
    FM_ROOT=$2
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-symlink-preflight-lib.sh"
    detect_symlink_capability
    detect_repo_symlink_checkout
  )
}

test_symlink_preflight_reports_only_a_proven_capability_failure() {
  local fixture home root out
  fixture=$(fm_test_tmproot fm-symlink-preflight) || fail "preflight: could not create a fixture root"
  home=$fixture/home
  root=$fixture/root
  mkdir -p "$home/state" "$root/.claude" "$root/.agents/skills"
  ln -s ../.agents/skills "$root/.claude/skills"

  out=$(run_symlink_preflight "$home" "$root")
  [ -z "$out" ] || fail "preflight: a healthy home must be silent, got [$out]"

  # A state directory that cannot hold a symlink. Every fleet lock is created as
  # one, so this is the difference between a refusal an operator can act on and
  # a lock wait that spins forever. Skipped where the runner can write to a
  # 0500 directory anyway, which is what running as root means.
  chmod 0500 "$home/state"
  if ln -s target "$home/state/.probe-writable" 2>/dev/null; then
    rm -f "$home/state/.probe-writable"
    chmod 0700 "$home/state"
  else
    out=$(run_symlink_preflight "$home" "$root")
    chmod 0700 "$home/state"
    case "$out" in
      "PLATFORM: cannot create a symlink in $home/state, so no fleet lock can ever be acquired"*) ;;
      *) fail "preflight: an unlinkable state dir must report the lock-layer failure, got [$out]" ;;
    esac
  fi

  # core.symlinks=false checks the tracked .claude/skills blob out as a plain
  # file holding its target path, and the harness then sees no project skills.
  rm -f "$root/.claude/skills"
  printf '../.agents/skills\n' > "$root/.claude/skills"
  out=$(run_symlink_preflight "$home" "$root")
  case "$out" in
    "PLATFORM: $root/.claude/skills was checked out as a plain file"*) ;;
    *) fail "preflight: a skills link checked out as a plain file must be reported, got [$out]" ;;
  esac

  # An ordinary file that merely happens to sit at that path is NOT the tracked
  # symlink blob, so reporting it would be a false alarm.
  printf 'notes an operator left here\n' > "$root/.claude/skills"
  out=$(run_symlink_preflight "$home" "$root")
  [ -z "$out" ] || fail "preflight: a plain file that is not the tracked link blob must stay silent, got [$out]"

  # A home with no state directory at all - a read-only session that never got
  # that far - must not fail, and must not invent a diagnostic.
  rm -rf "$home/state"
  rm -f "$root/.claude/skills"
  ln -s ../.agents/skills "$root/.claude/skills"
  out=$(run_symlink_preflight "$home" "$root")
  [ -z "$out" ] || fail "preflight: a home without state/ must stay silent, got [$out]"
  pass "symlink preflight: reports the lock-layer and skills-checkout failures, and stays silent otherwise"
}

test_native_symlink_mode_is_set_and_preserves_operator_choice() {
  local out start
  # The exported normalisation is what the whole lock layer depends on, so it is
  # asserted on the platform it applies to and asserted INERT everywhere else.
  #
  # Both starting states are covered on purpose. fm_platform_enable_native_symlinks
  # branches on "${MSYS:-}", which collapses an UNSET variable and a
  # PRESENT-BUT-EMPTY one to the same '' arm - so that equivalence is an
  # assumption, and an assumption a test should pin rather than inherit. `env -u`
  # and `env MSYS=` are the two states spelled out; a bare `MSYS= bash` prefix
  # would only ever exercise the second.
  for start in unset empty; do
    case "$start" in
      unset) out=$(env -u MSYS bash -c ". '$ROOT/bin/fm-proc-lib.sh'; printf '%s' \"\${MSYS:-}\"") ;;
      empty) out=$(env MSYS= bash -c ". '$ROOT/bin/fm-proc-lib.sh'; printf '%s' \"\${MSYS:-}\"") ;;
    esac
    if fm_platform_is_windows; then
      case "$out" in
        *winsymlinks:nativestrict*) : ;;
        *) fail "native-symlinks: from $start, MSYS must carry winsymlinks:nativestrict, got '$out'" ;;
      esac
    else
      [ -z "$out" ] \
        || fail "native-symlinks: from $start, must stay inert off Windows, but MSYS became '$out'"
    fi
  done
  # An operator who already expressed a winsymlinks preference keeps it verbatim.
  out=$(env MSYS=winsymlinks:lnk bash -c ". '$ROOT/bin/fm-proc-lib.sh'; printf '%s' \"\$MSYS\"")
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
  # shellcheck disable=SC2034 # Read by bin/fm-proc-lib.sh fm_proc_root.
  FM_PROC_ROOT_OVERRIDE=/definitely-not-a-proc-root
  fm_proc_pids_with_cwd_under /tmp >/dev/null 2>&1 \
    && fail "cwd-scan: an impossible scan must return non-zero, never a proven-empty result"
  unset FM_PROC_ROOT_OVERRIDE
  # This is the fail-safe half: teardown reads a non-zero return as "cannot
  # determine leaked processes" and REFUSES, rather than deleting a worktree
  # something is still sitting in.
  pass "fm_proc_pids_with_cwd_under: an unusable /proc returns failure, not an empty result"
}


# MSYS reports /proc/<pid>/cwd in the mount table's OWN canonical spelling of the
# process's Windows cwd, which need not be the spelling the caller holds. Git for
# Windows mounts /tmp with `usertemp`, i.e. wherever %TEMP% points, so when %TEMP%
# carries a short (8.3) component - how GitHub's Windows runners spell it - a
# fixture created as /tmp/x reads back from /proc as
# /c/Users/<user>/AppData/Local/Temp/<long-name>/x. Measured on Git-for-Windows
# MINGW64: the strict prefix compare then finds NOBODY under a directory a live
# process is sitting in, and teardown reads that as a proven-empty scan.
#
# Driven through a fake /proc plus a stub resolver so the contract is pinned on a
# POSIX host too, exactly as the lock-spelling case below is.
test_proc_cwd_scan_matches_a_mount_aliased_cwd_spelling() {
  local dir proc out
  dir=$(fm_test_tmproot fm-proc-cwd-alias) || fail "cwd-alias: could not create a fixture root"
  # `mnt` is the spelling the caller passes; `long` is the spelling /proc answers
  # in. They are the same location as far as the stub mount table is concerned.
  mkdir -p "$dir/mnt/wt/sub" "$dir/long/wt/sub" "$dir/stub" "$dir/elsewhere"
  proc="$dir/proc"
  # 4242 sits under the aliased spelling; 4243 sits somewhere else entirely and
  # must never be claimed by the widening.
  mkdir -p "$proc/4242" "$proc/4243"
  # A missing target is a silent dangling link on POSIX but a hard `ln -s`
  # failure under MSYS winsymlinks:nativestrict, so it is asserted on every host.
  [ -e "$dir/long/wt/sub" ] \
    || fail "cwd-alias: link target does not exist: $dir/long/wt/sub"
  ln -s "$dir/long/wt/sub" "$proc/4242/cwd" || fail "cwd-alias: could not stage the aliased cwd link"
  [ -e "$dir/elsewhere" ] \
    || fail "cwd-alias: link target does not exist: $dir/elsewhere"
  ln -s "$dir/elsewhere" "$proc/4243/cwd" || fail "cwd-alias: could not stage the unrelated cwd link"

  cat > "$dir/stub/cygpath" <<STUB
#!/usr/bin/env bash
# Stand-in for the MSYS mount table: \$dir/mnt and \$dir/long are one Windows
# path, and -u answers in the spelling /proc uses (the \`long\` one).
p=\${!#}
case "\$1" in
  -u)
    case "\$p" in
      X:/win/*) printf '%s/%s\n' '$dir/long' "\${p#X:/win/}" ;;
      *) printf '%s\n' "\$p" ;;
    esac
    ;;
  *)
    case "\$p" in
      '$dir/mnt'/*) printf 'X:/win/%s\n' "\${p#$dir/mnt/}" ;;
      '$dir/long'/*) printf 'X:/win/%s\n' "\${p#$dir/long/}" ;;
      *) printf '%s\n' "\$p" ;;
    esac
    ;;
esac
STUB
  chmod +x "$dir/stub/cygpath"

  # shellcheck disable=SC2034 # Read by bin/fm-proc-lib.sh fm_proc_root.
  FM_PROC_ROOT_OVERRIDE=$proc
  out=$(with_path "$dir/stub:$PATH" fm_proc_pids_with_cwd_under "$dir/mnt/wt") \
    || fail "cwd-alias: the scan must still report success when a resolver is present"
  case $'\n'"$out"$'\n' in
    *$'\n4242\n'*) : ;;
    *) fail "cwd-alias: a process whose /proc cwd uses the aliased spelling must be found, got '$out'" ;;
  esac
  case $'\n'"$out"$'\n' in
    *$'\n4243\n'*) fail "cwd-alias: SECURITY - a process outside the directory must never be claimed, got '$out'" ;;
  esac

  # The widening is capability-gated, never assumed: a resolver that cannot
  # answer leaves the strict compare as the only verdict, so the aliased pid is
  # reported as not-found rather than guessed at.
  cat > "$dir/stub/cygpath" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$dir/stub/cygpath"
  out=$(with_path "$dir/stub:$PATH" fm_proc_pids_with_cwd_under "$dir/mnt/wt") \
    || fail "cwd-alias: an unusable resolver must not turn a completed scan into a failed one"
  [ -z "$out" ] \
    || fail "cwd-alias: with no working resolver the strict compare must be the only verdict, got '$out'"

  # And the caller's own spelling never needs the resolver at all.
  out=$(with_path "$dir/stub:$PATH" fm_proc_pids_with_cwd_under "$dir/long/wt") \
    || fail "cwd-alias: scanning the /proc spelling itself must succeed"
  case $'\n'"$out"$'\n' in
    *$'\n4242\n'*) : ;;
    *) fail "cwd-alias: the strict compare must still match the spelling /proc reports, got '$out'" ;;
  esac
  unset FM_PROC_ROOT_OVERRIDE
  pass "fm_proc_pids_with_cwd_under: a mount-aliased /proc cwd spelling still matches the caller's directory"
}


# The same mount aliasing reaches /proc/<pid>/fd/N, and for a lock FILE the fd
# links are the ONLY branch that can ever match - no process holds a regular file
# as its cwd. fm_lock_proc_holder reads an empty result as "provably no holder",
# which is what lets fm_lock_is_provably_stale delete a lock a live git process
# still owns, so the fd compare has to widen exactly as the cwd compare does.
test_proc_holder_scan_matches_a_mount_aliased_fd_target() {
  local dir proc out
  dir=$(fm_test_tmproot fm-proc-fd-alias) || fail "fd-alias: could not create a fixture root"
  mkdir -p "$dir/mnt/wt" "$dir/long/wt" "$dir/stub"
  : > "$dir/long/wt/index.lock" || fail "fd-alias: could not stage the lock file"
  : > "$dir/long/wt/other.lock" || fail "fd-alias: could not stage the unrelated file"
  proc="$dir/proc"
  # 4242 holds the lock open under the aliased spelling; 4243 holds a different
  # file and must never be claimed by the widening.
  mkdir -p "$proc/4242/fd" "$proc/4243/fd"
  ln -s "$dir/long/wt/index.lock" "$proc/4242/fd/3" \
    || fail "fd-alias: could not stage the aliased fd link"
  ln -s "$dir/long/wt/other.lock" "$proc/4243/fd/3" \
    || fail "fd-alias: could not stage the unrelated fd link"

  cat > "$dir/stub/cygpath" <<STUB
#!/usr/bin/env bash
# Stand-in for the MSYS mount table, same shape as the cwd case above.
p=\${!#}
case "\$1" in
  -u)
    case "\$p" in
      X:/win/*) printf '%s/%s\n' '$dir/long' "\${p#X:/win/}" ;;
      *) printf '%s\n' "\$p" ;;
    esac
    ;;
  *)
    case "\$p" in
      '$dir/mnt'/*) printf 'X:/win/%s\n' "\${p#$dir/mnt/}" ;;
      '$dir/long'/*) printf 'X:/win/%s\n' "\${p#$dir/long/}" ;;
      *) printf '%s\n' "\$p" ;;
    esac
    ;;
esac
STUB
  chmod +x "$dir/stub/cygpath"

  # shellcheck disable=SC2034 # Read by bin/fm-proc-lib.sh fm_proc_root.
  FM_PROC_ROOT_OVERRIDE=$proc
  out=$(with_path "$dir/stub:$PATH" fm_proc_pids_holding_path "$dir/mnt/wt/index.lock") \
    || fail "fd-alias: the scan must still report success when a resolver is present"
  case $'\n'"$out"$'\n' in
    *$'\n4242\n'*) : ;;
    *) fail "fd-alias: a process whose /proc fd link uses the aliased spelling must be found, got '$out'" ;;
  esac
  case $'\n'"$out"$'\n' in
    *$'\n4243\n'*) fail "fd-alias: SECURITY - a process holding a different file must never be claimed, got '$out'" ;;
  esac

  # Capability-gated exactly as the cwd widening is: no working resolver leaves
  # the strict compare as the only verdict.
  cat > "$dir/stub/cygpath" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$dir/stub/cygpath"
  out=$(with_path "$dir/stub:$PATH" fm_proc_pids_holding_path "$dir/mnt/wt/index.lock") \
    || fail "fd-alias: an unusable resolver must not turn a completed scan into a failed one"
  [ -z "$out" ] \
    || fail "fd-alias: with no working resolver the strict compare must be the only verdict, got '$out'"

  # And the spelling /proc itself reports never needs the resolver.
  out=$(with_path "$dir/stub:$PATH" fm_proc_pids_holding_path "$dir/long/wt/index.lock") \
    || fail "fd-alias: scanning the /proc spelling itself must succeed"
  case $'\n'"$out"$'\n' in
    *$'\n4242\n'*) : ;;
    *) fail "fd-alias: the strict compare must still match the spelling /proc reports, got '$out'" ;;
  esac
  case $'\n'"$out"$'\n' in
    *$'\n4243\n'*) fail "fd-alias: the strict compare must not claim an unrelated holder, got '$out'" ;;
  esac
  unset FM_PROC_ROOT_OVERRIDE
  pass "fm_proc_pids_holding_path: a mount-aliased /proc fd target still matches the caller's path"
}


# --- 4. symlink target spelling ---------------------------------------------

# Stage real tool $2 inside directory $1 so it still runs when $1 is the ENTIRE
# PATH, which is how the cases below prove what happens with no resolver present.
#
# A symlink cannot do that on Windows: an MSYS binary finds msys-2.0.dll through
# PATH, Windows' last-resort DLL search location, so a link reached through a PATH
# that carries only the link's own directory exits 127 before running and the case
# reads as a failure of the code under test rather than of its fixture (measured
# on Git-for-Windows MINGW64: `PATH=$dir readlink` -> 127). An exec wrapper keeps
# the real binary running from its own directory, where its DLLs sit, so this
# never has to know which DLLs a tool needs. Same reasoning, and the same shape,
# as make_no_timeout_toolbin in tests/fm-crew-state.test.sh.
stage_tool_for_restricted_path() {  # <dir> <tool>
  local dir=$1 tool=$2 real shell
  real=$(command -v "$tool") || return 1
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      shell=$(command -v bash) || return 1
      printf '#!%s\nexec "%s" "$@"\n' "$shell" "$real" > "$dir/$tool" || return 1
      chmod +x "$dir/$tool" || return 1
      ;;
    *)
      ln -s "$real" "$dir/$tool" || return 1
      ;;
  esac
}

# Run a predicate with PATH replaced, then put PATH back. Replacing PATH is the
# case under test - these functions decide what to do by probing for a resolver
# on it - so the warnings about doing that are the expected shape here.
with_path() {  # <path> <command>...
  local restore=$PATH rc=0
  # shellcheck disable=SC2123 # Replacing the search path is exactly what is under test.
  PATH=$1
  shift
  "$@" || rc=$?
  PATH=$restore
  return "$rc"
}

# MSYS resolves a native symlink's stored Windows target back through its mount
# table, so readlink can answer in a canonical POSIX spelling that is not the
# one passed to `ln -s`. Measured on Git-for-Windows MINGW64: a directory
# created as /c/Users/<user>/AppData/Local/Temp/x/target reads back as
# /tmp/x/target, because the mount table aliases the two. The strict compare in
# fm_lock_points_to_owner then never matches, fm_lock_try_create never validates
# its own link, and fm_lock_acquire_wait spins forever.
#
# cygpath owns the mount table and is therefore the only thing that can answer
# this; `cd ... && pwd -P` cannot, because it canonicalises symlinked components
# but leaves the mount alias exactly as given (also measured). The test drives
# the resolver through a stub so the contract is pinned on a POSIX host too.
test_lock_same_path_resolves_a_mount_alias_only_through_cygpath() {
  local dir out
  dir=$(fm_test_tmproot fm-lock-same-path) || fail "could not create a fixture dir"
  mkdir -p "$dir/real" "$dir/other"

  # No cygpath (every POSIX host): the strict compare is the only verdict, so
  # two different spellings stay unresolved rather than being widened.
  out=0
  with_path /nonexistent-for-this-test fm_lock_same_path "$dir/real" "$dir/other" || out=1
  [ "$out" = 1 ] || fail "same-path: without cygpath, two paths must never be reported the same"
  out=0
  with_path /nonexistent-for-this-test fm_lock_same_path "$dir/real" "$dir/real" || out=1
  [ "$out" = 1 ] \
    || fail "same-path: without a resolver even an identical pair must stay unresolved; the strict compare in fm_lock_points_to_owner is what accepts it"

  # With a cygpath that reports the alias: the two spellings resolve together.
  mkdir -p "$dir/stub"
  cat > "$dir/stub/cygpath" <<'STUB'
#!/usr/bin/env bash
# Stand-in for the MSYS mount table: both spellings of the temp directory are
# one Windows path, and anything else is returned unchanged.
p=${!#}
case "$p" in
  /c/Users/probe/AppData/Local/Temp/*) printf 'C:/Users/probe/AppData/Local/Temp/%s\n' "${p#/c/Users/probe/AppData/Local/Temp/}" ;;
  /tmp/*) printf 'C:/Users/probe/AppData/Local/Temp/%s\n' "${p#/tmp/}" ;;
  *) printf '%s\n' "$p" ;;
esac
STUB
  chmod +x "$dir/stub/cygpath"
  out=0
  with_path "$dir/stub:$PATH" \
    fm_lock_same_path /c/Users/probe/AppData/Local/Temp/home/state/.wake.lock.owner.AbCdEf \
    /tmp/home/state/.wake.lock.owner.AbCdEf || out=1
  [ "$out" = 0 ] \
    || fail "same-path: the two spellings of one mount-aliased directory must resolve to the same location"
  out=0
  with_path "$dir/stub:$PATH" \
    fm_lock_same_path /c/Users/probe/AppData/Local/Temp/home/state/.wake.lock.owner.AbCdEf \
    /tmp/home/state/.wake.lock.owner.ZzZzZz || out=1
  [ "$out" = 1 ] \
    || fail "same-path: SECURITY - two genuinely different owner directories must never resolve the same"
  pass "fm_lock_same_path: widens a mount-aliased spelling through cygpath and stays strict everywhere else"
}

# The widening must live only in the fallback: an exact readlink answer is still
# accepted with no resolver involved at all.
test_lock_points_to_owner_still_accepts_an_exact_readlink_answer() {
  local dir
  dir=$(fm_test_tmproot fm-lock-points-to-owner) || fail "could not create a fixture dir"
  mkdir -p "$dir/owner" "$dir/nocyg"
  ln -s "$dir/owner" "$dir/lock" || fail "fixture: could not create the owner link"
  # A PATH carrying readlink and deliberately no cygpath, so the case holds on a
  # Windows host running this suite too.
  stage_tool_for_restricted_path "$dir/nocyg" readlink \
    || fail "fixture: could not stage readlink"
  with_path "$dir/nocyg" fm_lock_points_to_owner "$dir/lock" "$dir/owner" \
    || fail "points-to-owner: an exact readlink match must be accepted without any resolver"
  with_path "$dir/nocyg" fm_lock_points_to_owner "$dir/lock" "$dir/somewhere-else" \
    && fail "points-to-owner: a link to a different directory must never validate"
  pass "fm_lock_points_to_owner: the strict readlink compare remains the primary, unresolved verdict"
}

# --- 5. process identity ----------------------------------------------------

# A /proc with the Linux-shaped per-pid stat and cmdline that Cygwin/MSYS also
# expose. The parenthesised comm field deliberately contains a ')' and a space,
# because field 22 can only be located after the LAST such delimiter.
fake_proc_identity() {  # <root> <pid> <starttime>
  local root=$1 pid=$2 starttime=$3
  mkdir -p "$root/$pid"
  printf '%s (bash ) x) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 %s 20 21 22\n' \
    "$pid" "$starttime" > "$root/$pid/stat"
  printf 'bash\0/path with spaces/fm-send.sh\0--flag\0' > "$root/$pid/cmdline"
}

test_pid_identity_is_served_by_this_file_from_proc() {
  local root fakebin first second reused
  root=$(fm_test_tmproot fm-pid-identity) || fail "pid-identity: could not create a fixture root"
  fakebin="$root/bin"
  mkdir -p "$fakebin"
  # MSYS `ps` shape: -o is rejected outright, so a caller that depends on it gets
  # nothing at all. This is what made a stored process identity unreadable there.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    -o) printf 'ps: unknown option -- o\n' >&2; exit 1 ;;
  esac
done
exit 0
SH
  chmod +x "$fakebin/ps"
  fake_proc_identity "$root/proc" 4242 987654
  # Exported here, unlike the in-process cases above, because each read below runs
  # in a child shell that sources only the library under test.
  export FM_PROC_ROOT_OVERRIDE="$root/proc"

  # Sourcing bin/fm-proc-lib.sh alone must be enough: it is the one owner of this
  # read, so no caller has to pull in a second library to ask the question.
  first=$(PATH="$fakebin:$PATH" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-proc-lib.sh" 4242) \
    || fail "pid-identity: fm-proc-lib.sh did not answer for a pid with a readable /proc"
  case "$first" in
    *starttime=987654*cmdline-hex=*) : ;;
    *) fail "pid-identity: expected parsed starttime field 22 plus the full cmdline, got '$first'" ;;
  esac
  second=$(PATH="$fakebin:$PATH" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-proc-lib.sh" 4242)
  [ "$second" = "$first" ] \
    || fail "pid-identity: two reads of the same process must match ('$first' vs '$second')"

  fake_proc_identity "$root/proc" 4242 987655
  reused=$(PATH="$fakebin:$PATH" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-proc-lib.sh" 4242)
  [ "$reused" != "$first" ] || fail "pid-identity: a reused pid must not keep the old identity"

  # And the same library sourced through bin/fm-wake-lib.sh, which every watcher
  # and lock check reaches it by, must answer identically rather than from a copy.
  [ "$(FM_STATE_OVERRIDE="$root/state" PATH="$fakebin:$PATH" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" 4242)" = "$reused" ] \
    || fail "pid-identity: the wake library must serve the same answer as its owner"
  unset FM_PROC_ROOT_OVERRIDE
  pass "fm_pid_identity: bin/fm-proc-lib.sh answers from /proc where ps rejects -o, and detects pid reuse"
}

# --- 6. line endings ---------------------------------------------------------

# The invariant belongs to the REPO, not to the two Windows CI jobs: a Windows
# contributor who clones this published repo with Git-for-Windows defaults and
# runs bin/fm-lint.sh must not meet SC1017 on all 304 files with no hint why.
#
# Driven through git itself, with the SHIPPED .gitattributes copied into the
# fixture, so this pins that file's meaning rather than re-spelling its rules.
# The no-attributes arm is the control: it proves the fixture really exercises
# core.autocrlf's conversion, so a passing result cannot be vacuous.
test_gitattributes_pins_an_lf_working_tree_for_every_clone() {
  local dir variant src clone attrs
  assert_present "$ROOT/.gitattributes" "the repo must carry a root .gitattributes"
  dir=$(fm_test_tmproot fm-gitattributes-lf) || fail "gitattributes: could not create a fixture root"

  for variant in shipped text-only bare; do
    src="$dir/src-$variant"
    mkdir -p "$src/bin" "$src/assets"
    case "$variant" in
      shipped) cp "$ROOT/.gitattributes" "$src/.gitattributes" ;;
      # The `* text=auto eol=lf` line alone, so the assertions below can tell
      # which of the two shipped lines is doing the work.
      text-only) printf '* text=auto eol=lf\n' > "$src/.gitattributes" ;;
      bare) : ;;
    esac
    printf 'echo one\necho two\n' > "$src/bin/sample.sh"
    # Bytes a content sniffer cannot tell from text - CRLF and no NUL - so
    # `text=auto` alone would call this a text file and rewrite it. Pinning
    # *.png binary is what keeps a real banner intact.
    printf 'PNG-fixture\r\nrow\r\n' > "$src/assets/sample.png"
    git -C "$src" -c init.defaultBranch=main init -q \
      || fail "gitattributes: could not init the $variant fixture repo"
    git -C "$src" -c core.autocrlf=true -c core.safecrlf=false add -A \
      || fail "gitattributes: could not stage the $variant fixture"
    git -C "$src" -c core.autocrlf=true -c core.safecrlf=false \
      -c user.name='Firstmate Tests' \
      -c user.email='tests@example.invalid' commit -qm fixture \
      || fail "gitattributes: could not commit the $variant fixture"
    # Git for Windows' default, which is the whole point: the clone must land as
    # LF without the operator knowing to override anything.
    git -c core.autocrlf=true clone -q "$src" "$dir/clone-$variant" \
      || fail "gitattributes: could not clone the $variant fixture"
  done

  # The CR byte travels in a variable and is double-quoted at the call. MEASURED
  # on windows-latest (runner image 20260810.198.2, git 2.55.0.windows.3, Git
  # Bash): spelled inline as $'\r' the pattern can reach grep EMPTY, and an
  # empty pattern matches every file - see docs/fm-test-windows-lane.md. The
  # control arm below would still catch that, but it would report it as a
  # .gitattributes failure rather than as the detector's.
  local cr=$'\r'

  clone="$dir/clone-bare/bin/sample.sh"
  grep -qU "$cr" "$clone" \
    || fail "gitattributes: CONTROL FAILED - core.autocrlf=true did not produce a CRLF checkout here, so this fixture proves nothing"

  clone="$dir/clone-shipped/bin/sample.sh"
  grep -qU "$cr" "$clone" \
    && fail "gitattributes: a shell file cloned with core.autocrlf=true must still land as LF"
  cmp -s "$dir/src-shipped/bin/sample.sh" "$clone" \
    || fail "gitattributes: the LF checkout must be byte-identical to the committed file"

  clone="$dir/clone-shipped/assets/sample.png"
  cmp -s "$dir/src-shipped/assets/sample.png" "$clone" \
    || fail "gitattributes: *.png must survive the clone byte-for-byte, got a rewritten file"

  clone="$dir/clone-text-only/assets/sample.png"
  cmp -s "$dir/src-text-only/assets/sample.png" "$clone" \
    && fail "gitattributes: CONTROL FAILED - text=auto alone left the fake png intact, so the *.png binary pin is untested"

  # And the shipped file must keep saying so for the paths that actually exist.
  attrs=$(git -C "$ROOT" check-attr text eol -- bin/fm-lint.sh) \
    || fail "gitattributes: could not read the attributes git resolves for bin/fm-lint.sh"
  case "$attrs" in
    *'text: auto'*) : ;;
    *) fail "gitattributes: bin/fm-lint.sh must resolve text=auto, got '$attrs'" ;;
  esac
  case "$attrs" in
    *'eol: lf'*) : ;;
    *) fail "gitattributes: bin/fm-lint.sh must resolve eol=lf, got '$attrs'" ;;
  esac
  attrs=$(git -C "$ROOT" check-attr text -- assets/banner.png) \
    || fail "gitattributes: could not read the attributes git resolves for assets/banner.png"
  case "$attrs" in
    *'text: unset'*) : ;;
    *) fail "gitattributes: assets/banner.png must resolve text unset (binary), got '$attrs'" ;;
  esac

  pass "root .gitattributes: a core.autocrlf=true clone still lands LF, and the one binary blob survives"
}

# --- 7. the GOTMPDIR export line -------------------------------------------

# MSYS converts paths in argv but never in the environment, so the exported
# GOTMPDIR must be the native Windows form or a native Go exe puts its build
# temp somewhere fm-teardown.sh will never clean. The Windows form carries
# backslashes, so it is QUOTED as well as translated - and the quoter,
# shell_quote, belongs to the caller rather than to bin/fm-path-lib.sh.
#
# bin/fm-path-lib.sh is now reached through bin/fm-wake-lib.sh, which dozens of
# scripts source and almost none of them define shell_quote in. An unprobed call
# would expand to nothing there and emit a valid-looking `export GOTMPDIR=` line
# pointing at the process's own idea of nowhere, so the absent quoter must
# degrade to the untranslated POSIX literal - what every non-Windows host emits
# today - rather than to an empty value.
test_gotmpdir_export_line_degrades_to_the_posix_literal_without_a_quoter() {
  local dir out
  dir=$(fm_test_tmproot fm-gotmpdir-line) || fail "could not create a fixture dir"
  mkdir -p "$dir/stub"
  cat > "$dir/stub/cygpath" <<'STUB'
#!/usr/bin/env bash
# Stand-in for the MSYS translator: answer the native Windows spelling.
printf 'C:\\fmtmp\\gotmp\n'
STUB
  chmod +x "$dir/stub/cygpath"

  # The production path (bin/fm-spawn.sh defines shell_quote before it calls):
  # translated AND quoted, byte-identical to what it has always emitted.
  out=$(
    FM_PROC_UNAME_S=MINGW64_NT-10.0-26200
    # shellcheck disable=SC2329 # Called indirectly by fm_path_gotmpdir_export_line.
    shell_quote() { printf "'"; printf '%s' "$1" | sed "s/'/'\\\\''/g"; printf "'"; }
    with_path "$dir/stub:$PATH" fm_path_gotmpdir_export_line /tmp/fm-1/gotmp
  )
  [ "$out" = "export GOTMPDIR='C:\\fmtmp\\gotmp'" ] \
    || fail "gotmpdir: with a quoter the Windows form must be translated and quoted, got [$out]"

  # The same Windows host reached through a sourcer that has no shell_quote.
  out=$(
    FM_PROC_UNAME_S=MINGW64_NT-10.0-26200
    with_path "$dir/stub:$PATH" fm_path_gotmpdir_export_line /tmp/fm-1/gotmp
  )
  [ "$out" = "export GOTMPDIR=/tmp/fm-1/gotmp" ] \
    || fail "gotmpdir: without a quoter the line must be the untranslated POSIX literal, never an empty export; got [$out]"

  # Off Windows nothing is translated at all, quoter or not.
  out=$(
    # shellcheck disable=SC2034 # Read by fm_platform_is_windows in bin/fm-proc-lib.sh.
    FM_PROC_UNAME_S=Linux
    with_path "$dir/stub:$PATH" fm_path_gotmpdir_export_line /tmp/fm-1/gotmp
  )
  [ "$out" = "export GOTMPDIR=/tmp/fm-1/gotmp" ] \
    || fail "gotmpdir: off Windows the literal must stay exactly as it has always been, got [$out]"
  pass "fm_path_gotmpdir_export_line: translates and quotes on Windows, and falls back to the POSIX literal rather than an empty export when the caller has no quoter"
}

test_proc_lib_source_guard_skips_repeats_without_blinding_the_platform_seam
test_proc_field_reads_msys_layout
test_proc_field_falls_back_to_ps_where_proc_is_absent
test_proc_field_rejects_bad_input
test_proc_field_rejects_unknown_field
test_symlink_probe_proves_rather_than_assumes
test_symlink_preflight_reports_only_a_proven_capability_failure
test_native_symlink_mode_is_set_and_preserves_operator_choice
test_proc_cwd_scan_finds_processes_rooted_under_a_directory
test_proc_cwd_scan_reports_scan_failure_distinctly
test_proc_cwd_scan_matches_a_mount_aliased_cwd_spelling
test_proc_holder_scan_matches_a_mount_aliased_fd_target
test_lock_same_path_resolves_a_mount_alias_only_through_cygpath
test_lock_points_to_owner_still_accepts_an_exact_readlink_answer
test_pid_identity_is_served_by_this_file_from_proc
test_gitattributes_pins_an_lf_working_tree_for_every_clone
test_gotmpdir_export_line_degrades_to_the_posix_literal_without_a_quoter
