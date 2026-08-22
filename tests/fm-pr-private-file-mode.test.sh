#!/usr/bin/env bash
# tests/fm-pr-private-file-mode.test.sh - the exact-mode half of firstmate's
# private-file trust binding (bin/fm-file-mode-lib.sh), and the platform-scoped
# waiver that keeps Windows able to merge at all.
#
# This is a SECURITY boundary, not a portability detail. The binding stops a
# watcher check script, a poll sidecar or a registration record being swapped
# between the moment firstmate writes it and the moment the watcher executes or
# trusts it. On Git for Windows every mount is `noacl`, so `chmod` is a silent
# no-op and the exact-mode assertion cannot pass at all - which blocked EVERY
# task PR merge, because bin/fm-pr-merge.sh aborts when bin/fm-pr-check.sh
# cannot record the PR.
#
# The waiver is therefore capability-gated, and this file pins both halves:
#   - wherever chmod round-trips, a wrong mode is still REFUSED;
#   - where it provably cannot, the other assertions (device pin, symlink
#     refusal, link count 1) still carry the binding on their own;
#   - and the probe that decides which is which is not fooled by a no-op chmod,
#     which is the exact bug that made an earlier version of this waiver never
#     engage while every test stayed green.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

# Clear the capability memo so the next probe re-measures. The two globals are
# owned by bin/fm-file-mode-lib.sh, so shellcheck cannot see their use from here.
# shellcheck disable=SC2034 # Read and written by bin/fm-file-mode-lib.sh fm_pr_mode_enforced.
reset_mode_memo() {
  FM_PR_MODE_ENFORCED_DIR=
  FM_PR_MODE_ENFORCED=
}

# Pin the memo to "this directory does not enforce modes", which is exactly the
# state the probe reaches on a Git-for-Windows noacl mount. Simulating it is what
# lets the waiver's behaviour be asserted from a POSIX runner.
# shellcheck disable=SC2034 # Read by bin/fm-file-mode-lib.sh fm_pr_mode_enforced.
pin_mode_not_enforced() {  # <dir>
  FM_PR_MODE_ENFORCED_DIR=$1
  FM_PR_MODE_ENFORCED=1
}

test_mode_assertion_stays_strict_where_chmod_works() {
  local root f
  root=$(fm_test_tmproot fm-mode) || fail "mode-gate: could not create a fixture root"
  f="$root/artifact"
  : > "$f"
  chmod 0600 "$f" || fail "mode-gate: could not chmod the fixture"
  [ "$(fm_pr_file_mode "$f")" = 600 ] || {
    pass "skip: this filesystem does not enforce modes, so the strict half cannot be exercised here"
    return 0
  }
  reset_mode_memo
  fm_pr_file_mode_is "$f" 600 || fail "mode-gate: a correct mode must validate"
  reset_mode_memo
  fm_pr_file_mode_is "$f" 700 \
    && fail "mode-gate: SECURITY - a WRONG mode must be refused where chmod round-trips"
  chmod 0644 "$f"
  reset_mode_memo
  fm_pr_file_mode_is "$f" 600 \
    && fail "mode-gate: SECURITY - a world-readable artifact must be refused where chmod round-trips"
  pass "fm_pr_file_mode_is: the exact-mode assertion stays strict wherever chmod round-trips"
}

test_mode_assertion_is_waived_only_where_chmod_cannot_round_trip() {
  local root f
  root=$(fm_test_tmproot fm-mode) || fail "mode-gate: could not create a fixture root"
  f="$root/artifact"
  : > "$f"
  chmod 0644 "$f"
  # Simulate the noacl filesystem by pinning the memo to "not enforced" for this
  # directory, which is exactly the state the probe reaches on Git for Windows.
  pin_mode_not_enforced "$root"
  fm_pr_file_mode_is "$f" 600 \
    || fail "mode-gate: where modes are not enforced the assertion must be waived, or no PR can ever be merged"
  reset_mode_memo
  pass "fm_pr_file_mode_is: waives the exact-mode assertion only where the filesystem provably cannot express it"
}

# The probe itself, against the exact shape that fooled an earlier version of it:
# a filesystem where chmod is a silent no-op. mktemp already creates at 0600, so
# a probe that only chmods TO 0600 and reads 600 back "passes" on precisely the
# platform it is supposed to detect - and the waiver never engages, which is how
# a Windows PR merge stays blocked while every test looks green.
test_mode_probe_is_not_fooled_by_a_no_op_chmod() {
  local root fakebin
  root=$(fm_test_tmproot fm-mode) || fail "mode-probe: could not create a fixture root"
  fakebin=$(fm_fakebin "$root")
  cat > "$fakebin/chmod" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/chmod"

  reset_mode_memo
  PATH="$fakebin:$PATH" fm_pr_mode_enforced "$root" \
    && fail "mode-probe: a no-op chmod must NOT read as an enforcing filesystem"

  reset_mode_memo
  if fm_pr_mode_enforced "$root"; then
    : # the real chmod on this host enforces, which is the other half below
  else
    pass "skip: this filesystem does not enforce modes, so the contrast cannot be shown here"
    reset_mode_memo
    return 0
  fi
  reset_mode_memo
  pass "fm_pr_mode_enforced: a no-op chmod reads as not-enforcing even though mktemp already created the probe at 0600"
}

test_private_file_binding_keeps_its_other_assertions_when_mode_is_waived() {
  local root f device link
  root=$(fm_test_tmproot fm-mode) || fail "mode-gate: could not create a fixture root"
  f="$root/artifact"
  : > "$f"
  device=$(fm_pr_file_device "$f") || fail "mode-gate: could not read the fixture device"
  pin_mode_not_enforced "$root"

  fm_pr_private_file_valid "$f" 600 "$device" \
    || fail "mode-gate: the binding must still validate a genuine private artifact"
  fm_pr_private_file_valid "$f" 600 999999 \
    && fail "mode-gate: SECURITY - the device pin must still be enforced when the mode check is waived"

  link="$root/artifact-link"
  ln -s "$f" "$link" 2>/dev/null || link=
  if [ -n "$link" ]; then
    fm_pr_private_file_valid "$link" 600 "$device" \
      && fail "mode-gate: SECURITY - a symlink must still be refused when the mode check is waived"
  fi

  ln "$f" "$root/artifact-hard" 2>/dev/null && {
    fm_pr_private_file_valid "$f" 600 "$device" \
      && fail "mode-gate: SECURITY - a link count above 1 must still be refused when the mode check is waived"
  }
  reset_mode_memo
  pass "fm_pr_private_file_valid: device pin, symlink refusal and link-count 1 all survive the waived mode assertion"
}

test_mode_assertion_stays_strict_where_chmod_works
test_mode_assertion_is_waived_only_where_chmod_cannot_round_trip
test_mode_probe_is_not_fooled_by_a_no_op_chmod
test_private_file_binding_keeps_its_other_assertions_when_mode_is_waived
