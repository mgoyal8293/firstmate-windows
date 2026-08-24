#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  # THE GIT FIXTURES MUST NOT SHARE THIS HELPER'S STDOUT. This function returns
  # its record THROUGH stdout, and `git commit -q` still writes "On branch
  # master / nothing to commit, working tree clean" to STDOUT when nothing is
  # staged - `-q` suppresses the success summary, not that status. Anything git
  # prints would be prepended to the record inside the caller's command
  # substitution, and the caller then builds real paths from it. Redirected to
  # STDERR rather than to /dev/null so a genuine git failure is still visible.
  fm_git_worktree "$proj" "$wt" "wt-$name" >&2
  fm_git_init_commit "$stale" >&2
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# --- how the worktree is acquired, per backend ------------------------------
#
# The line fm-spawn sends to acquire the worktree is not the same on every
# backend. tmux and friends send a bare `treehouse get`, whose provider opens a
# SUBSHELL that hosts the task; conpty cannot afford that subshell, because its
# liveness signal is the session shell's own OSC 133 prompt marks and a nested
# shell's rc files can destroy the carrier that emits the finished mark, freezing
# the signal at "a command is running" so `exit` can never prove a stop. There it
# leases the slot and `cd`s into it in the shell firstmate armed.
#
# Both arms are asserted against the text the BACKEND actually received.

# make_acquire_fakebin: a fake tmux that answers the settle loop from a fixed
# worktree path and appends every line sent with send-keys -l to FM_SENT_LOG.
make_acquire_fakebin() {  # <dir> <worktree> -> echoes fakebin dir
  local dir=$1 wt=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$wt"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    # send-keys -t TARGET TEXT Enter for a submitted line, -l TEXT for a
    # literal one. Both carry exactly one text argument; record it.
    shift
    text=
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -t) shift; [ \$# -gt 0 ] && shift; continue ;;
        -l) shift; text=\${1:-}; break ;;
        Enter) shift; continue ;;
        *) text=\$1; break ;;
      esac
    done
    [ -n "\$text" ] && printf '%s\n' "\$text" >> "\${FM_SENT_LOG:?}"
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_conpty_fakebin: the conpty adapter's whole runtime surface is one node
# client, so a fake `node` stands in for the backend exactly as
# tests/fm-backend-conpty.test.sh does. Text is delivered by FILE on this
# backend, so the sent line is recovered from the file the client was handed.
make_conpty_fakebin() {  # <dir> <worktree> -> echoes fakebin dir
  local dir=$1 wt=$2 fakebin real_node
  fakebin=$(fm_fakebin "$dir")
  real_node=$(command -v node || true)
  # shellcheck disable=SC2016 # deliberate: these expand in the fake, not here.
  cat > "$fakebin/node" <<SH
#!/usr/bin/env bash
set -u
# Only the conpty CLIENT is faked. fm-spawn also runs node as a plain JSON
# reader (the lease-release helper), and that must be the real interpreter.
if [ "\${1:-}" = -e ]; then exec "$real_node" "\$@"; fi
cmd=\${2:-}
case "\$cmd" in
  doctor) printf 'ok\n'; exit 0 ;;
  exists)
    # The first probe must miss (create_task refuses a live duplicate), every
    # later one must hit (the daemon has bound its pipe).
    n=0
    [ -f "\${FM_EXISTS_COUNT:?}" ] && n=\$(cat "\${FM_EXISTS_COUNT}")
    n=\$((n + 1)); printf '%s\n' "\$n" > "\${FM_EXISTS_COUNT}"
    [ "\$n" -gt 1 ] && { printf 'present\n'; exit 0; }
    printf 'absent\n'; exit 1 ;;
  cwd) printf '%s\n' "$wt"; exit 0 ;;
  send)
    prev=
    for a in "\$@"; do
      if [ "\$prev" = --text-file ]; then
        # The adapter hands the client a NATIVE path, so translate back when
        # this host has a translator (WSL and MSYS both do).
        f=\$a
        [ -f "\$f" ] || f=\$(wslpath -u "\$a" 2>/dev/null || cygpath -u "\$a" 2>/dev/null || printf '%s' "\$a")
        cat "\$f" >> "\${FM_SENT_LOG:?}"; printf '\n' >> "\${FM_SENT_LOG}"
      fi
      prev=\$a
    done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/node"
  make_recording_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_recording_treehouse: a treehouse that records every invocation and answers
# `status --json` from the pool the case declares. `status --json` and
# `return --force --if-lease-holder` are the two shapes fm-spawn's abort path
# uses; the exit code of `return` is what the case varies.
make_recording_treehouse() {  # <fakebin>
  cat > "$1/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'treehouse'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_TREEHOUSE_LOG:?}"
case "${1:-}" in
  status)
    # An unreadable pool is the other half of the abort path: the release cannot
    # tell "nothing was leased" from "cannot say" without it.
    if [ -n "${FM_FAKE_STATUS_UNREADABLE:-}" ]; then
      printf 'treehouse: no pool here\n' >&2
      exit 1
    fi
    # A payload that parses but is not the array of rows the probe expects: it
    # answers nothing about this holder, so it must not read as an empty pool.
    if [ "${FM_FAKE_STATUS_SHAPE:-}" = object ]; then
      printf '{"error":"pool is locked"}\n'
      exit 0
    fi
    printf '[{"name":"1","path":"%s","status":"leased","lease_holder":"%s","processes":[]}]\n' \
      "${FM_FAKE_LEASED_PATH:-}" "${FM_FAKE_LEASE_HOLDER:-}"
    exit 0 ;;
  return) exit "${FM_FAKE_RETURN_EXIT:-0}" ;;
esac
exit 0
SH
  chmod +x "$1/treehouse"
}

# acquire_line: the first line the backend was sent, which is the worktree
# acquisition - fm-spawn sends nothing before it.
acquire_line() {  # <sent-log>
  head -n 1 "$1" 2>/dev/null
}

make_acquire_case() {  # <name> <id> -> case dir
  local name=$1 id=$2 case_dir home proj wt
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  # Redirected for the reason spelled out in make_settle_case: this helper
  # returns its case dir through stdout, so no fixture command may write there.
  fm_git_worktree "$proj" "$wt" "wt-$name" >&2
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# make_conpty_binroot: a copy of bin/ whose conpty adapter passes its own
# dependency preflight. The adapter refuses without node-pty installed, and
# bin/backends/conpty/node_modules is not part of a checkout, so the copy is
# what makes this arm reachable off Windows. The scripts are the real ones.
#
# BUILT ONCE AND SHARED by every conpty case here. The tree is read-only to
# them - the node-pty stub is the only thing written into it, and every case
# wants it - while each case keeps its own home, state and pool through
# run_acquire_spawn's overrides, so nothing a case does can reach this copy. Per
# case it was seven copies of bin/ per run, which on the Windows lane is the
# slowest operation in the suite for no gain. A case that ever needs to MUTATE
# the tree must build its own rather than share this one.
#
# The cache is the TREE ITSELF, not a variable: every call site reads this
# through a command substitution, so a variable set here would be set in a
# subshell and lost. The node-pty stub is created last, so its presence is what
# proves a previous copy finished rather than died half-way.
make_conpty_binroot() {  # -> echoes the fm-spawn to run
  local root="$TMP_ROOT/conpty-binroot"
  if [ ! -d "$root/bin/backends/conpty/node_modules/node-pty" ]; then
    rm -rf "$root"
    mkdir -p "$root"
    cp -R "$ROOT/bin" "$root/bin"
    mkdir -p "$root/bin/backends/conpty/node_modules/node-pty"
  fi
  printf '%s\n' "$root/bin/fm-spawn.sh"
}

# THE FAKE POOL'S CONFIGURATION IS THE CALLER'S LOCALS, and the defaults below
# are what a case that says nothing gets. A case declares the FM_FAKE_* names it
# needs with `local`, so bash's dynamic scope makes them visible here and they
# die with the case - where `export` put them in the test shell's own
# environment, and the suite then passed only because every later case happened
# to overwrite the path or take a branch that never read it. Order-dependent
# green is not green: reordering the calls at the bottom of this file, or adding
# a case that forgets one name, would have run it against a previous case's slot.
run_acquire_spawn() {  # <case-dir> <fakebin> <spawn> <id> [extra spawn args...]
  local case_dir=$1 fakebin=$2 spawn=$3 id=$4; shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" FM_DATA_OVERRIDE="$case_dir/home/data" \
    FM_PROJECTS_OVERRIDE="$case_dir/home/projects" FM_CONFIG_OVERRIDE="$case_dir/home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_SENT_LOG="$case_dir/sent.log" FM_EXISTS_COUNT="$case_dir/exists.count" \
    FM_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    FM_FAKE_LEASED_PATH="${FM_FAKE_LEASED_PATH:-}" FM_FAKE_LEASE_HOLDER="${FM_FAKE_LEASE_HOLDER:-}" \
    FM_FAKE_RETURN_EXIT="${FM_FAKE_RETURN_EXIT:-0}" \
    FM_FAKE_STATUS_UNREADABLE="${FM_FAKE_STATUS_UNREADABLE:-}" \
    FM_FAKE_STATUS_SHAPE="${FM_FAKE_STATUS_SHAPE:-}" \
    FM_BACKEND_CONPTY_ALLOW_NON_WINDOWS=1 \
    FM_BACKEND_CONPTY_SHELL='C:\fake\bash.exe' \
    FM_BACKEND_CONPTY_STATE="$case_dir/conpty-state" \
    PATH="$fakebin:$PATH" \
    "$spawn" "$id" "$case_dir/project" --mode no-mistakes --yolo off "$@" 2>&1
}

test_default_backend_sends_bare_treehouse_get() {
  local case_dir id fakebin out
  id=acquire-tmux-z1
  case_dir=$(make_acquire_case acquire-tmux "$id")
  fakebin=$(make_acquire_fakebin "$case_dir/fake" "$case_dir/wt")

  out=$(run_acquire_spawn "$case_dir" "$fakebin" "$SPAWN" "$id" --backend tmux)
  assert_contains "$out" "spawned $id" "spawn did not report success"$'\n'"$out"
  [ "$(acquire_line "$case_dir/sent.log")" = 'treehouse get' ] \
    || fail "a tmux spawn acquired the worktree with '$(acquire_line "$case_dir/sent.log")', not a bare 'treehouse get'"
  pass "fm-spawn acquires the worktree with a bare 'treehouse get' on a backend that can host the task in the provider's subshell"
}

test_conpty_leases_and_cds_in_the_session_shell() {
  local case_dir id fakebin spawn out line
  id=acquire-conpty-z2
  case_dir=$(make_acquire_case acquire-conpty "$id")
  fakebin=$(make_conpty_fakebin "$case_dir/fake" "$case_dir/wt")
  spawn=$(make_conpty_binroot)

  out=$(run_acquire_spawn "$case_dir" "$fakebin" "$spawn" "$id" --backend conpty)
  line=$(acquire_line "$case_dir/sent.log")
  [ -n "$line" ] || fail "the conpty spawn sent nothing to the session"$'\n'"$out"
  # The command substitution must reach the SESSION unexpanded - firstmate has no
  # treehouse of its own to run here - and the lease must be attributable, which
  # is what makes an abandoned slot traceable to the task that leased it.
  [ "$line" = "cd \"\$(treehouse get --lease --lease-holder firstmate-$id)\"" ] \
    || fail "the conpty spawn acquired the worktree with '$line', not the lease-and-cd form"
  case "$line" in
    'treehouse get') fail "the conpty spawn still opens a provider subshell" ;;
  esac
  # A spawn that SUCCEEDS must keep its lease: the record now carries worktree=,
  # so teardown is what returns it.
  case "$(cat "$case_dir/treehouse.log" 2>/dev/null || true)" in
    *return*) fail "a successful conpty spawn released its own worktree lease" ;;
  esac
  pass "fm-spawn leases the worktree and cds into the marked session shell on conpty, so no provider subshell hosts the agent"
}

# THE LEASE OUTLIVES ITS ACQUIRER, so the acquirer has to hand it back when it
# aborts. Every other backend gets this free: `treehouse get`'s subshell holds
# the slot and drops it when the endpoint dies. Here the abort happens before the
# record exists, so fm-teardown cannot reclaim it either, and a finite pool would
# be consumed one slot per failed spawn.
#
# The abort is triggered where a real one is cheapest to reproduce: the session
# settles into a directory that is not an isolated git worktree, which is exactly
# what validate_spawn_worktree refuses.
make_abort_case() {  # <name> <id> -> case dir
  local case_dir
  case_dir=$(make_acquire_case "$1" "$2")
  mkdir -p "$case_dir/not-a-worktree" "$case_dir/leased-slot"
  printf '%s\n' "$case_dir"
}

treehouse_return_call() {  # <treehouse-log>
  grep -F "$(printf '\x1f')return$(printf '\x1f')" "$1" 2>/dev/null || true
}

test_aborted_conpty_spawn_returns_its_own_lease() {
  local case_dir id fakebin spawn out status call us
  local FM_FAKE_LEASED_PATH FM_FAKE_LEASE_HOLDER FM_FAKE_RETURN_EXIT
  id=acquire-conpty-abort-z3
  case_dir=$(make_abort_case acquire-conpty-abort "$id")
  FM_FAKE_LEASED_PATH="$case_dir/leased-slot" FM_FAKE_LEASE_HOLDER="firstmate-$id" FM_FAKE_RETURN_EXIT=0
  fakebin=$(make_conpty_fakebin "$case_dir/fake" "$case_dir/not-a-worktree")
  spawn=$(make_conpty_binroot)

  out=$(run_acquire_spawn "$case_dir" "$fakebin" "$spawn" "$id" --backend conpty)
  status=$?
  [ "$status" -ne 0 ] || fail "the spawn should have aborted on a worktree that is not isolated"$'\n'"$out"
  call=$(treehouse_return_call "$case_dir/treehouse.log")
  [ -n "$call" ] || fail "the aborted conpty spawn never returned its lease"$'\n'"$out"
  us=$(printf '\x1f')
  # Found by THIS task's holder label, not by the rejected directory: the slot
  # the pool reports is the one handed back, and --if-lease-holder is what stops
  # the abort from ever taking another task's slot.
  assert_contains "$call" "${us}return${us}--force${us}--if-lease-holder${us}firstmate-$id${us}$case_dir/leased-slot" \
    "the release did not name the leased slot and its holder"
  pass "an aborted conpty spawn hands its worktree lease back, holder-scoped, before the task record exists"
}

test_unreleasable_lease_prints_the_operator_command() {
  local case_dir id fakebin spawn out status
  local FM_FAKE_LEASED_PATH FM_FAKE_LEASE_HOLDER FM_FAKE_RETURN_EXIT
  id=acquire-conpty-stuck-z4
  case_dir=$(make_abort_case acquire-conpty-stuck "$id")
  FM_FAKE_LEASED_PATH="$case_dir/leased-slot" FM_FAKE_LEASE_HOLDER="firstmate-$id" FM_FAKE_RETURN_EXIT=1
  fakebin=$(make_conpty_fakebin "$case_dir/fake" "$case_dir/not-a-worktree")
  spawn=$(make_conpty_binroot)

  out=$(run_acquire_spawn "$case_dir" "$fakebin" "$spawn" "$id" --backend conpty)
  status=$?
  [ "$status" -ne 0 ] || fail "the spawn should have aborted on a worktree that is not isolated"$'\n'"$out"
  # A failed abort is worse than a leaked slot, so the release stays best-effort
  # and the operator gets the exact command instead of a failure.
  assert_contains "$out" "treehouse return --force --if-lease-holder firstmate-$id $case_dir/leased-slot" \
    "a lease that could not be released did not print the command to release it"
  pass "a lease the abort cannot release is reported with the exact one-line command, not swallowed and not fatal"
}

# NO ANSWER THE PROBE GIVES IS A CONFIDENT NEGATIVE, and the message must not
# pretend otherwise in either direction. Claiming the slot stays leased sends the
# operator after a lease that may not exist; claiming none was ever taken loses a
# slot silently, because the in-session `treehouse get --lease` can still be
# running - a lease that FAILED and a lease still being cut both leave the shell
# in the project and both time out the cwd poll identically. So this path states
# what is recorded now, names the in-flight case, and still hands over the
# reclaim command.
test_no_recorded_lease_is_reported_without_claiming_either_way() {
  local case_dir id fakebin spawn out status
  local FM_FAKE_LEASED_PATH FM_FAKE_LEASE_HOLDER FM_FAKE_RETURN_EXIT
  id=acquire-conpty-nolease-z5
  case_dir=$(make_abort_case acquire-conpty-nolease "$id")
  # The pool reads cleanly and its one slot is leased to a DIFFERENT task, so the
  # probe finds no row for this holder.
  # The return is always attempted, and a real treehouse refuses it because this
  # holder holds nothing - which is what leaves the message to be chosen.
  FM_FAKE_LEASED_PATH="$case_dir/leased-slot" FM_FAKE_LEASE_HOLDER="firstmate-someone-else" FM_FAKE_RETURN_EXIT=1
  fakebin=$(make_conpty_fakebin "$case_dir/fake" "$case_dir/not-a-worktree")
  spawn=$(make_conpty_binroot)

  out=$(run_acquire_spawn "$case_dir" "$fakebin" "$spawn" "$id" --backend conpty)
  status=$?
  [ "$status" -ne 0 ] || fail "the spawn should have aborted on a worktree that is not isolated"$'\n'"$out"
  assert_not_contains "$out" "stays leased" \
    "the abort asserted a leaked slot as fact although no lease is recorded for this holder"
  assert_contains "$out" "no worktree lease is recorded for firstmate-$id" \
    "the abort did not report what the pool actually established"
  assert_contains "$out" "still running" \
    "the abort did not tell the operator an in-flight acquisition can still land a lease after the check"
  assert_contains "$out" "treehouse return --force --if-lease-holder firstmate-$id" \
    "the abort withheld the reclaim command, so a lease landing after the check could never be reclaimed"
  pass "an abort with no recorded lease for this task says so, names the in-flight case, and still offers the reclaim command"
}

# A ROW WITHOUT A USABLE PATH IS NOT AN ABSENT LEASE. The pool names this holder
# but carries no path for it - a drifted or renamed key, or a row written before
# the path was known. The release must still be attempted against the path this
# spawn observed, because skipping it is the leak this function exists to
# prevent, and the message must not tell the operator no lease is recorded when
# the pool just said otherwise.
test_pathless_holder_row_still_attempts_the_release() {
  local case_dir id fakebin spawn out status us call
  local FM_FAKE_LEASED_PATH FM_FAKE_LEASE_HOLDER FM_FAKE_RETURN_EXIT
  id=acquire-conpty-pathless-z8
  case_dir=$(make_abort_case acquire-conpty-pathless "$id")
  FM_FAKE_LEASED_PATH='' FM_FAKE_LEASE_HOLDER="firstmate-$id" FM_FAKE_RETURN_EXIT=1
  fakebin=$(make_conpty_fakebin "$case_dir/fake" "$case_dir/not-a-worktree")
  spawn=$(make_conpty_binroot)

  out=$(run_acquire_spawn "$case_dir" "$fakebin" "$spawn" "$id" --backend conpty)
  status=$?
  [ "$status" -ne 0 ] || fail "the spawn should have aborted on a worktree that is not isolated"$'\n'"$out"
  us=$(printf '\x1f')
  call=$(treehouse_return_call "$case_dir/treehouse.log")
  assert_contains "$call" "${us}return${us}--force${us}--if-lease-holder${us}firstmate-$id${us}$case_dir/not-a-worktree" \
    "a holder row with no usable path suppressed the release entirely, leaking the slot it was meant to hand back"
  assert_not_contains "$out" "no worktree lease is recorded" \
    "the abort claimed no lease is recorded although the pool named this holder"
  assert_contains "$out" "stays leased to firstmate-$id" \
    "a release that failed while the pool named this holder did not report the slot as still leased"
  pass "a pool row naming this holder with no usable path still gets the release attempted, and is never reported as no lease"
}

# AN UNEXPECTED PAYLOAD SHAPE IS NOT AN EMPTY POOL. `status --json` answering with
# an object - an error envelope, or a future wrapper around the rows - parses
# cleanly but says nothing about this holder, so it must fall to the unknown
# branch that keeps the hint rather than read as "no lease recorded".
test_non_array_status_payload_is_treated_as_unknown() {
  local case_dir id fakebin spawn out status
  local FM_FAKE_STATUS_SHAPE FM_FAKE_RETURN_EXIT
  id=acquire-conpty-shape-z7
  case_dir=$(make_abort_case acquire-conpty-shape "$id")
  FM_FAKE_STATUS_SHAPE=object FM_FAKE_RETURN_EXIT=1
  fakebin=$(make_conpty_fakebin "$case_dir/fake" "$case_dir/not-a-worktree")
  spawn=$(make_conpty_binroot)

  out=$(run_acquire_spawn "$case_dir" "$fakebin" "$spawn" "$id" --backend conpty)
  status=$?
  [ "$status" -ne 0 ] || fail "the spawn should have aborted on a worktree that is not isolated"$'\n'"$out"
  assert_contains "$out" "treehouse return --force --if-lease-holder firstmate-$id $case_dir/not-a-worktree" \
    "a status payload that was not the expected array of rows was read as an empty pool, suppressing the hint"
  pass "a status payload that is not the expected array of rows is treated as unknown, so the hint survives"
}

test_unreadable_pool_still_prints_the_operator_command() {
  local case_dir id fakebin spawn out status
  local FM_FAKE_STATUS_UNREADABLE FM_FAKE_RETURN_EXIT
  id=acquire-conpty-unknown-z6
  case_dir=$(make_abort_case acquire-conpty-unknown "$id")
  # `treehouse status` cannot answer, so whether a lease is held is unknown - and
  # an unknown state still earns the hint, aimed at the path the session settled
  # in because it is the only one this spawn observed.
  FM_FAKE_STATUS_UNREADABLE=1 FM_FAKE_RETURN_EXIT=1
  fakebin=$(make_conpty_fakebin "$case_dir/fake" "$case_dir/not-a-worktree")
  spawn=$(make_conpty_binroot)

  out=$(run_acquire_spawn "$case_dir" "$fakebin" "$spawn" "$id" --backend conpty)
  status=$?
  [ "$status" -ne 0 ] || fail "the spawn should have aborted on a worktree that is not isolated"$'\n'"$out"
  assert_contains "$out" "treehouse return --force --if-lease-holder firstmate-$id $case_dir/not-a-worktree" \
    "an unreadable pool suppressed the operator command instead of falling back to the observed path"
  pass "an abort that cannot read the pool keeps the exact one-line release command, because unknown is not the same as none"
}

# THE FIXTURE HELPERS' RETURN CHANNEL. Every case here builds real paths out of
# the value a case-dir helper hands back, so that value sharing its stdout with a
# fixture command is not a cosmetic problem: a polluted value is used verbatim as
# a path prefix by `mkdir -p` and `cat >`, which writes the fixture into whatever
# relative location the pollution implies. That is not hypothetical - it put two
# generated stubs under a repo-root directory whose name was git's own "On branch
# master / nothing to commit, working tree clean" (embedded newlines and all)
# into a commit on this branch, and a path component containing a newline is
# invalid on Win32, so a Windows checkout of that tree fails outright.
#
# The trigger is reproduced rather than described: calling a helper a SECOND time
# for the same case name leaves nothing staged for `git commit -qm initial`,
# which then writes its status to STDOUT - `-q` suppresses the success summary,
# not that status. Against an unredirected helper this case fails on the second
# call, reporting a three-line value; the assertions are the shape of the return
# channel (one line, an existing directory, under this test's own temp root),
# which is what a leak from any future fixture command would also break.
assert_returned_case_dir() {  # <value> <helper> <call>
  local value=$1 helper=$2 which=$3
  case "$value" in
    *$'\n'*)
      fail "$which call to $helper returned a MULTI-LINE value, so a fixture command wrote to the helper's stdout and the caller would build paths from the leaked text: <$value>" ;;
  esac
  [ -n "$value" ] || fail "$which call to $helper returned an empty value"
  case "$value" in
    "$TMP_ROOT"/*) ;;
    *) fail "$which call to $helper returned '$value', which is not under this test's own temp root" ;;
  esac
  [ -d "$value" ] || fail "$which call to $helper returned '$value', which is not an existing directory"
}

test_case_dir_helpers_keep_their_return_channel_clean() {
  local dir err record
  err="$TMP_ROOT/return-channel.err"

  dir=$(make_acquire_case return-channel "return-channel-z9" 2>"$err")
  assert_returned_case_dir "$dir" make_acquire_case first
  # THE SECOND CALL IS THE TRIGGER, and its stderr is the proof. Nothing is
  # staged this time, so `git commit -qm initial` DOES write its status - the
  # assertions below pin both halves of the split: stdout carries only the path,
  # and that status really was produced and went to stderr. An unredirected
  # helper fails the first half AND leaves this file empty, so neither half can
  # pass vacuously.
  : > "$err"
  dir=$(make_acquire_case return-channel "return-channel-z9" 2>"$err")
  assert_returned_case_dir "$dir" make_acquire_case second
  [ -s "$err" ] \
    || fail "the repeat make_acquire_case call produced nothing on stderr, so this case never reached the 'nothing to commit' path it exists to pin"

  # The settle helper returns a pipe-delimited RECORD, and read_settle_record
  # splits it, so a leaked line lands in the first field and every later field
  # shifts.
  record=$(make_settle_case return-channel-settle "return-channel-settle-z9" 0 2>"$err")
  assert_returned_case_dir "${record%%|*}" make_settle_case first
  : > "$err"
  record=$(make_settle_case return-channel-settle "return-channel-settle-z9" 0 2>"$err")
  assert_returned_case_dir "${record%%|*}" make_settle_case second
  [ -s "$err" ] \
    || fail "the repeat make_settle_case call produced nothing on stderr, so this case never reached the 'nothing to commit' path it exists to pin"
  read_settle_record "$record"
  [ -d "$HOME_DIR" ] \
    || fail "make_settle_case's record split to HOME_DIR='$HOME_DIR', which is not a directory, so the fields shifted"
  [ "$STALE_READS" = 0 ] \
    || fail "make_settle_case's record split to STALE_READS='$STALE_READS' rather than the 0 it was given, so the fields shifted"
  pass "the case-dir fixture helpers return exactly one existing path on stdout, so a fixture command's output can never be used as a path prefix"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_default_backend_sends_bare_treehouse_get
test_conpty_leases_and_cds_in_the_session_shell
test_aborted_conpty_spawn_returns_its_own_lease
test_unreleasable_lease_prints_the_operator_command
test_no_recorded_lease_is_reported_without_claiming_either_way
test_unreadable_pool_still_prints_the_operator_command
test_non_array_status_payload_is_treated_as_unknown
test_pathless_holder_row_still_attempts_the_release
test_case_dir_helpers_keep_their_return_channel_clean

echo "# all fm-spawn-worktree-settle tests passed"
