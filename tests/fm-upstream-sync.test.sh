#!/usr/bin/env bash
# tests/fm-upstream-sync.test.sh - the upstream-freshness dry run
# (bin/fm-upstream-sync.sh).
#
# The load-bearing contract is what this tool must NOT do. This repo is a
# Windows port of an actively developed upstream whose platform delta is carried
# as `case "$(uname -s)" in MINGW*|MSYS*)` arms added inside existing functions.
# Git will merge many upstream changes around those arms cleanly and still leave
# an arm guarding code that moved, so a silent auto-merge would land a broken
# port and it would only surface the next time someone needed Windows to work.
#
# Therefore:
#   1. a clean merge is REPORTED, never landed - no ref the operator can see
#      moves, and no scratch branch or worktree survives the run;
#   2. conflicts are reported with the exact conflicted paths and a non-zero
#      exit, so a scheduled run is visibly red rather than quietly skipped;
#   3. an already-current port says so and does no work.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-upstream-sync.sh"

# Build a fixture: a bare "upstream", a bare "origin", and a port checkout that
# has both as remotes. Echoes the port checkout path.
make_fixture() {
  local root=$1 seed
  seed="$root/seed"
  mkdir -p "$seed"
  git init --quiet "$seed"
  fm_git_identity "$seed"
  printf 'shared\nline-a\nline-b\n' > "$seed/shared.sh"
  printf 'upstream-only\n' > "$seed/other.sh"
  git -C "$seed" add -A
  git -C "$seed" commit --quiet -m 'seed'
  git -C "$seed" branch -M main

  git clone --quiet --bare "$seed" "$root/upstream.git"
  git clone --quiet --bare "$seed" "$root/origin.git"

  git clone --quiet "$root/origin.git" "$root/port"
  fm_git_identity "$root/port"
  git -C "$root/port" remote add upstream "$root/upstream.git"
  git -C "$root/port" fetch --quiet upstream
  printf '%s\n' "$root/port"
}

# Add a commit to the bare upstream through a scratch clone.
upstream_commit() {  # <root> <file> <content> <message>
  local root=$1 file=$2 content=$3 message=$4 wc
  wc="$root/upstream-wc.$RANDOM"
  git clone --quiet "$root/upstream.git" "$wc"
  fm_git_identity "$wc"
  printf '%s' "$content" > "$wc/$file"
  git -C "$wc" add -A
  git -C "$wc" commit --quiet -m "$message"
  git -C "$wc" push --quiet origin main
  rm -rf "$wc"
}

run_sync() {  # <port> [args...]
  local port=$1
  shift
  FM_ROOT_OVERRIDE="$port" bash "$SYNC" --no-fetch --tests none "$@" 2>&1
}

test_reports_current_when_nothing_is_new() {
  local root port out rc
  root=$(fm_test_tmproot fm-upsync) || fail "upstream-sync: could not create a fixture root"
  port=$(make_fixture "$root")
  out=$(run_sync "$port"); rc=$?
  [ "$rc" -eq 0 ] || fail "upstream-sync: an already-current port must exit 0, got $rc"
  assert_contains "$out" 'current:' "upstream-sync: an already-current port must say so"
  pass "fm-upstream-sync.sh: reports an already-current port and does no work"
}

test_reports_a_clean_merge_without_landing_it() {
  local root port out rc before_main before_head
  root=$(fm_test_tmproot fm-upsync) || fail "upstream-sync: could not create a fixture root"
  port=$(make_fixture "$root")
  upstream_commit "$root" other.sh 'upstream-changed
' 'upstream: touch a file the port does not carry'
  git -C "$port" fetch --quiet upstream

  before_main=$(git -C "$port" rev-parse refs/remotes/origin/main)
  before_head=$(git -C "$port" rev-parse HEAD)

  out=$(run_sync "$port"); rc=$?
  [ "$rc" -eq 0 ] || fail "upstream-sync: a clean merge must exit 0, got $rc: $out"
  assert_contains "$out" 'CLEAN' "upstream-sync: a clean merge must be reported as clean"
  assert_contains "$out" 'new upstream commits not in base: 1' \
    "upstream-sync: the report must count the new upstream commits"

  # The whole point: nothing landed.
  [ "$(git -C "$port" rev-parse refs/remotes/origin/main)" = "$before_main" ] \
    || fail "upstream-sync: origin/main moved - this tool must never land a merge"
  [ "$(git -C "$port" rev-parse HEAD)" = "$before_head" ] \
    || fail "upstream-sync: HEAD moved - this tool must never land a merge"
  assert_no_grep 'upstream-sync-scratch' <(git -C "$port" branch --list) \
    "upstream-sync: the scratch branch must not survive the run"
  assert_no_grep 'fm-upstream-sync' <(git -C "$port" worktree list) \
    "upstream-sync: the scratch worktree must not survive the run"
  pass "fm-upstream-sync.sh: reports a clean merge and lands nothing"
}

test_reports_conflicts_with_paths_and_a_nonzero_exit() {
  local root port out rc
  root=$(fm_test_tmproot fm-upsync) || fail "upstream-sync: could not create a fixture root"
  port=$(make_fixture "$root")
  upstream_commit "$root" shared.sh 'shared
UPSTREAM-EDIT
line-b
' 'upstream: edit the shared line'
  git -C "$port" fetch --quiet upstream

  # The port edits the same line, the way a Windows arm added inside an existing
  # function does.
  printf 'shared\nPORT-WINDOWS-ARM\nline-b\n' > "$port/shared.sh"
  git -C "$port" add -A
  git -C "$port" commit --quiet -m 'port: windows arm on the shared line'
  git -C "$port" push --quiet origin main
  git -C "$port" fetch --quiet origin

  out=$(run_sync "$port"); rc=$?
  [ "$rc" -eq 1 ] || fail "upstream-sync: conflicts must exit 1, got $rc: $out"
  assert_contains "$out" 'CONFLICTS' "upstream-sync: conflicts must be reported as conflicts"
  assert_contains "$out" 'shared.sh' "upstream-sync: the conflicted path must be named"
  assert_no_grep 'upstream-sync-scratch' <(git -C "$port" branch --list) \
    "upstream-sync: a conflicted run must still clean up its scratch branch"
  pass "fm-upstream-sync.sh: reports conflicts with their exact paths and exits non-zero"
}

test_json_report_is_machine_readable() {
  local root port json
  root=$(fm_test_tmproot fm-upsync) || fail "upstream-sync: could not create a fixture root"
  port=$(make_fixture "$root")
  upstream_commit "$root" shared.sh 'shared
UPSTREAM-EDIT
line-b
' 'upstream: edit the shared line'
  git -C "$port" fetch --quiet upstream
  printf 'shared\nPORT-WINDOWS-ARM\nline-b\n' > "$port/shared.sh"
  git -C "$port" add -A
  git -C "$port" commit --quiet -m 'port: windows arm'
  git -C "$port" push --quiet origin main
  git -C "$port" fetch --quiet origin

  json="$root/report.json"
  run_sync "$port" --json "$json" >/dev/null 2>&1 || true
  [ -f "$json" ] || fail "upstream-sync: --json must write a report even on the conflict path"
  assert_grep '"status": "conflict"' "$json" "upstream-sync: the json report must carry the status"
  assert_grep 'shared.sh' "$json" "upstream-sync: the json report must carry the conflicted paths"
  pass "fm-upstream-sync.sh: writes a machine-readable report a scheduled run can act on"
}

# A merge that reports no conflicted paths failed for an environmental reason,
# not a textual one - a CI runner with no committer identity is the case that
# actually happened. The refusal is correct, but a BLOCKED report that does not
# carry git's own reason turns a one-line diagnosis into a reproduction.
test_blocked_merge_names_gits_reason() {
  local root port out rc
  root=$(fm_test_tmproot fm-upsync) || fail "upstream-sync: could not create a fixture root"
  port=$(make_fixture "$root")
  upstream_commit "$root" other.sh 'upstream-changed
' 'upstream: touch a file the port does not carry'
  git -C "$port" fetch --quiet upstream

  # Strip every identity source the merge could draw on, the way a bare CI
  # checkout does. This merges cleanly when an identity is present.
  out=$(env -u HOME -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL \
    -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    FM_ROOT_OVERRIDE="$port" bash "$SYNC" --no-fetch --tests none 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "upstream-sync: an unattemptable merge must exit 3, got $rc: $out"
  assert_contains "$out" 'BLOCKED' "upstream-sync: an unattemptable merge must be reported as blocked"
  assert_contains "$out" 'git reported:' \
    "upstream-sync: a blocked merge must carry git's own stderr, not discard it"
  assert_contains "$out" 'identity' \
    "upstream-sync: the blocked report must name the missing identity as the cause"
  pass "fm-upstream-sync.sh: a blocked merge reports git's own reason"
}

test_refuses_a_missing_upstream_remote() {
  local root port out rc
  root=$(fm_test_tmproot fm-upsync) || fail "upstream-sync: could not create a fixture root"
  port=$(make_fixture "$root")
  out=$(FM_ROOT_OVERRIDE="$port" bash "$SYNC" --no-fetch --tests none --upstream nope 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "upstream-sync: a missing remote must exit 3, got $rc"
  assert_contains "$out" 'no remote named' "upstream-sync: a missing remote must be named plainly"
  pass "fm-upstream-sync.sh: refuses a missing upstream remote instead of reporting a false all-clear"
}

test_reports_current_when_nothing_is_new
test_reports_a_clean_merge_without_landing_it
test_reports_conflicts_with_paths_and_a_nonzero_exit
test_json_report_is_machine_readable
test_blocked_merge_names_gits_reason
test_refuses_a_missing_upstream_remote
