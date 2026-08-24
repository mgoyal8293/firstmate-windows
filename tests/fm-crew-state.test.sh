#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-state.sh - the deterministic crew-current-state
# helper.
#
# The status file (state/<id>.status) is a best-effort append-only EVENT LOG, so
# `tail -1` of it reports the last event, not the current state. fm-crew-state
# reads the AUTHORITATIVE source (a matching no-mistakes run-step, else the
# semantic busy-state contract) and reconciles the possibly-stale log against it.
#
# The run-step half of that logic - which run is the candidate, what its code
# binding may support, and which verdict its evidence settles - is owned by
# bin/fm-crew-run-verdict-lib.sh, so this suite is also the behaviour coverage
# for that library: every rule in it is exercised here through the executable
# helper rather than through the library's own functions.
#
# These cases pin every branch of that logic, hermetically, over real throwaway
# git repos with a fake `no-mistakes` (run-step source) and a fake `tmux` (pane
# source):
#   (a) active run-step is authoritative                          -> run-step
#   (b) needs-decision/blocked log + resumed run = SUPERSEDED     -> run-step
#   (c) genuine parked run + needs-decision log = NOT superseded  -> run-step
#   (d) terminal run-step (passed/failed) is authoritative        -> run-step
#   (e) cross-branch attribution: this branch's own run found via list lookup
#   (f) no run + semantic busy                                    -> pane
#   (g) no run + semantic idle falls to the status-log verb       -> status-log
#   (h) dead pane: no run -> unknown/none; with a run -> run-step (not the shell)
#   (i) kind=scout skips the run lookup                           -> pane/status-log
#   (j) torn-down worktree / missing meta                         -> unknown/none
#   (k) crew_is_provably_working end-to-end over the REAL helper (not a canned
#       fake fm-crew-state.sh verdict): cross-branch attribution via the runs
#       list -> absorbed; genuinely no run anywhere + idle pane -> surfaced.
#       This is the direct regression pair for the 2026-07-02 herdr incident,
#       proving the watcher's own absorb-only-when-provably-working predicate
#       benefits from the fix in both directions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state)
fm_git_identity fmtest fmtest@example.invalid

# Wall-clock bound for the perl-bounded no-mistakes lookup in
# test_no_timeout_uses_perl_bound. Measured around exactly the command the
# assertion wraps, with the bound neutralised so the run completes, three runs
# per platform:
#
#   Linux     1.246s 1.258s 1.264s  worst 1.264s  under 5s   = 4.0x headroom
#   Git Bash  3.429s 4.219s 4.605s  worst 4.605s  under 25s  = 5.4x headroom
#
# The 5s bound fails on Windows by a hair, not by an order of magnitude: the
# assertion compares integer $SECONDS, so a true 4.605s reads as elapsed=5 and
# `[ 5 -lt 5 ]` is false. 25s is deliberately more than parity headroom because
# the Windows figure is far less stable - a 34% spread across three runs against
# 1.4% on Linux - and a GitHub Windows runner is slower than the machine these
# came from. Scaled in a Windows arm so the Linux tripwire keeps its sensitivity.
NM_TIMEOUT_WALL_LIMIT=5
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) NM_TIMEOUT_WALL_LIMIT=25 ;;
esac

# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live crew worktree.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  # Real worktree HEAD for run head-binding (fixtures read FM_FAKE_RUN_HEAD).
  FM_FAKE_RUN_HEAD=$(git -C "$dir" rev-parse HEAD)
  export FM_FAKE_RUN_HEAD
}

# The REAL geometry that made a dead run mask a live one: a task worktree plus a
# separate clone standing in for the pipeline's own, where the pipeline's commit
# exists only in that clone. Its sha is therefore a real commit this checkout
# genuinely cannot resolve - which is what happens on a live fleet, because the
# pipeline pushes its fix commits to the remote and the task worktree has not
# fetched them. A made-up sha would pin the symptom; this pins the cause.
# Sets LOCAL_HEAD (the worktree tip) and PIPE_HEAD (the unfetchable run head).
make_pipeline_ahead_topology() {  # <dir> <branch>
  local dir=$1 branch=$2
  git init -q --bare "$dir/origin.git"
  git init -q "$dir/wt"
  git -C "$dir/wt" remote add origin "$dir/origin.git"
  git -C "$dir/wt" commit -q --allow-empty -m base
  git -C "$dir/wt" checkout -q -b "$branch"
  git -C "$dir/wt" commit -q --allow-empty -m 'crew implementation commit'
  git -C "$dir/wt" push -q origin "$branch"
  LOCAL_HEAD=$(git -C "$dir/wt" rev-parse HEAD)
  git clone -q "$dir/origin.git" "$dir/pipeline" 2>/dev/null
  git -C "$dir/pipeline" checkout -q "$branch"
  git -C "$dir/pipeline" commit -q --allow-empty -m 'no-mistakes(review): pipeline fix commit'
  PIPE_HEAD=$(git -C "$dir/pipeline" rev-parse HEAD)
  git -C "$dir/wt" rev-parse --verify -q "${PIPE_HEAD}^{commit}" >/dev/null 2>&1 &&
    fail "fixture broken: the pipeline head is resolvable in the task worktree"
  export LOCAL_HEAD PIPE_HEAD
}

# A fakebin with a fake `no-mistakes` (serves the env-driven run output) and a
# fake `tmux` (serves a busy or idle pane). The fake no-mistakes mirrors the real
# command surface the helper uses: `axi status`, `axi status --run <id>` (the
# `axi` surface - no runs-listing subcommand exists under it, verified against
# the real CLI), and the actual top-level run-listing command, `no-mistakes
# runs --limit N`, which is plain text - no run id, no quoting - serving
# FM_FAKE_RUNS_LIST verbatim.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
      logs)
        printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs)
    printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  # The forge read fm-crew-state makes before it will emit any `done`. Serves
  # FM_FAKE_GH_PR verbatim; empty (the default) or FM_FAKE_GH_CALL_FAILS=1 both
  # mean "the client RAN and did not answer", which is the TRANSIENT case and
  # must never render as a landing.
  #
  # This knob cannot produce the STRUCTURAL case, and its name says so on purpose:
  # a client that is absent is a different fact from a client that failed, this
  # suite exists to keep those two apart, and only make_path_with_no_gh_binary
  # below can make the binary genuinely absent.
  #
  # FM_FAKE_GH_CALL_LOG records one line per invocation, so the reader's bound on
  # OUTBOUND CALLS is observable rather than assumed. A fake that answers
  # identically every time cannot show a second call happening, which is exactly
  # why a duplicated read went unnoticed while the header promised there was none.
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_GH_CALL_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_FAKE_GH_CALL_LOG"
[ "${FM_FAKE_GH_CALL_FAILS:-0}" = 1 ] && exit 1
[ -n "${FM_FAKE_GH_PR:-}" ] || exit 1
printf '%s\n' "$FM_FAKE_GH_PR"
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\n%s\n' "${FM_FAKE_BUSY_TEXT:-esc to interrupt}"
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    [ "${2:-}" = --json ] && {
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
      exit 0
    } ;;
  server)
    exit 0 ;;
  pane)
    case "${2:-}" in
      read)
        [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$FM_FAKE_HERDR_AGENT_STATUS"
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/herdr" "$fb/gh"
  printf '%s\n' "$fb"
}

make_no_timeout_toolbin() {  # <dir> -> echoes toolbin path
  local dir=$1 tb="$1/notimeoutbin" tool real shell
  mkdir -p "$tb"
  # Windows: an MSYS or MINGW binary locates its runtime DLL (msys-2.0.dll for
  # /usr/bin tools, the mingw64 set for /mingw64/bin ones) through PATH, which is
  # Windows' last-resort DLL search location. Callers use this toolbin with PATH
  # restricted to the toolbin itself, which drops the real bin directory and
  # makes those DLLs unreachable, so a symlinked binary dies with "error while
  # loading shared libraries" before it runs. An exec wrapper keeps the real
  # binary running from its own directory, where its DLLs sit, so this helper
  # never has to know which DLLs each tool needs.
  shell=$(command -v bash) || fail "missing bash for no-timeout path"
  for tool in bash git grep sed head cut tail dirname perl; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for no-timeout path: $tool"
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*)
        printf '#!%s\nexec "%s" "$@"\n' "$shell" "$real" > "$tb/$tool"
        chmod +x "$tb/$tool"
        ;;
      *)
        ln -s "$real" "$tb/$tool"
        ;;
    esac
  done
  printf '%s\n' "$tb"
}

# A PATH with no `gh` binary reachable on it, for the host-has-no-forge-client
# case: the STRUCTURAL non-answer, and the only route to it. It cannot be faked
# from inside a fake `gh`, because the reader asks whether the binary EXISTS -
# FM_FAKE_GH_CALL_FAILS above makes the client run and fail, which is the
# TRANSIENT non-answer and a different fact.
#
# Only the PATH entries that actually provide `gh` are mirrored; every other entry
# is left pointing at the real directory. That keeps the mirror small, and it is
# also what keeps the MSYS/MINGW runtime-DLL search working for the untouched
# entries, for the reason make_no_timeout_toolbin above records: PATH is Windows'
# last-resort DLL location, so a wholesale mirror strands each tool's DLLs.
make_path_with_no_gh_binary() {  # <case-dir> -> echoes a PATH with no gh binary on it
  local dir=$1 out="" entry mirror n=0 f base
  local -a parts
  IFS=: read -r -a parts <<< "$PATH"
  for entry in "${parts[@]}"; do
    [ -n "$entry" ] || continue
    if [ -x "$entry/gh" ] || [ -x "$entry/gh.exe" ]; then
      n=$((n + 1))
      mirror="$dir/no-gh-binary$n"
      mkdir -p "$mirror"
      for f in "$entry"/*; do
        [ -e "$f" ] || continue
        base=${f##*/}
        case "$base" in gh|gh.exe) continue ;; esac
        [ -e "$mirror/$base" ] && continue
        ln -s "$f" "$mirror/$base" 2>/dev/null || true
      done
      entry=$mirror
    fi
    out="${out:+$out:}$entry"
  done
  printf '%s\n' "$out"
}

# Run the helper for one case dir. FM_FAKE_* env (run output, busy flag) are read
# from the caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

# crew_is_provably_working over the REAL reader for one case dir, with the same
# fakebin PATH run_crew_state uses. Lives beside it so the PATH composition has
# one owner, and so a caller further down the file does not have to re-derive it.
run_provably_working() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" crew_is_provably_working "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

arm_idle_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_AXI_STATUS_RUN=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  FM_FAKE_BUSY_TEXT=
  FM_FAKE_TMUX_MISSING=0
  FM_FAKE_HERDR_BUSY=0
  FM_FAKE_HERDR_MISSING=0
  FM_FAKE_HERDR_AGENT_STATUS=""
  FM_FAKE_CI_LOGS=""
  FM_FAKE_GH_PR=""
  FM_FAKE_GH_CALL_FAILS=0
  FM_FAKE_GH_CALL_LOG=""
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_BUSY FM_FAKE_BUSY_TEXT FM_FAKE_TMUX_MISSING
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_CI_LOGS
  export FM_FAKE_GH_PR FM_FAKE_GH_CALL_FAILS FM_FAKE_GH_CALL_LOG
}

# A forge answer that settles the PR's fate as OPEN and says nothing else.
#
# Cases whose guard is about something OTHER than where the PR ended up use this,
# so that question is answered and cannot be what carries their verdict. Leaving
# it unanswered is not neutral: an unanswered forge is the TRANSIENT non-answer,
# which no path may resolve to `done`, so a case that means to assert `done` about
# ci evidence would instead be asserting the forge gate. That coupling is how the
# ci-padding guard silently stopped falsifying anything once a later ruling gave
# its fixture a second route to `done`.
forge_answers_open() {
  FM_FAKE_GH_PR='{"mergeStateStatus":"CLEAN","state":"OPEN","url":"https://github.com/o/r/pull/1"}'
}

# --- run-object fixtures (TOON, as `no-mistakes axi status` emits) -----------

run_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

run_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
EOF
}

run_top_level_ci() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ci
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
EOF
}

run_parked() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_scalar_gate_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_in_gate_block() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate:
  step: review
  status: fix_review
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  review,fix_review,1,0
  test,pending,0,0
EOF
}

# A genuine pass: the pipeline completed AND this run's own ci step ran to
# completion, which is the only shape that satisfies the CI-evidence whitelist.
run_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,0
    push,completed,0,0
    ci,completed,0,0
outcome: passed
EOF
}

# The same genuine pass with its two step tables in the REVERSE order, and with a
# `ci` row in each carrying a DIFFERENT word. Synthetic, and deliberately so: it
# separates the two tables, which no recorded shape does, because a reader keyed
# on the first `ci,<word>,` row it meets agrees with an anchored one on every
# record where only `steps` has such a row. The steps table is the step HISTORY
# and is the one the terminal ranking asks about; the active table is what is
# executing now.
run_passed_active_steps_first() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,2m,"1m ago: log: watching checks",2010043,1
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,0
    push,completed,0,0
    ci,completed,0,0
outcome: passed
EOF
}

# `outcome: checks-passed` is the pipeline's own statement that the checks went
# green while the PR waits to be merged. Its ci step is left `running` here
# deliberately: on a repo where merge is the captain's call that is what the
# monitor phase records, and the point of the case is that the verdict does not
# depend on the ci-step word. The accompanying ci status for a real
# checks-passed run is unobserved on this fork; see
# docs/verification/crew-state-verdicts.md.
run_checks_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/5"
  findings: none
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,0
    push,completed,0,0
    ci,running,0,0
outcome: checks-passed
EOF
}

# The same outcome word on a run that has TERMINATED: `status: completed`, no
# active step, nothing anywhere in the record still executing. The fixture above
# pins `status: running`, which is the shape a monitoring run has, and its own
# comment records that the real ci/status shape of a checks-passed run is
# unobserved on this fork - so the two shapes are BOTH kept, because the verdict
# has to differ between them and a single fixture cannot show that.
run_checks_passed_terminated() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/5"
  findings: none
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,0
    push,completed,0,0
    ci,running,0,0
outcome: checks-passed
EOF
}

# A terminal pass carrying its own `ci,completed` evidence and NO PR url, for the
# ship-task-with-a-run half of the no-PR split. The run exists and finished; what
# is absent is any PR it could have landed.
run_passed_no_pr() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,0
    push,completed,0,0
    ci,completed,0,0
outcome: passed
EOF
}

# A run record with NO `status:` key at all, and no active step. The reader's own
# arms disagreed about this one shape: the status dispatch mapped an absent status
# to working/"run active", while crew_liveness rules the same record `terminated`
# because an absent status is no evidence of liveness. Nothing else in the suite
# produces a record without a status word.
run_no_status_word() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/4"
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    push,completed,0,0
EOF
}

# ANOTHER task's live run, carrying a real PR url of its own. `axi status` is
# REPO-scoped, so this is what a crew with no run of its own is answered with,
# and the url in it belongs to a crew that is not the one being read.
run_running_other_task_with_pr() {  # <branch> <pr-url>
  cat <<EOF
run:
  id: "01SIBLING"
  branch: $1
  status: running
  head: "0000000"
  pr: "$2"
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

# The same terminal pass with NO steps table at all - the record carries nothing
# that could show whether ci ran. Absence of evidence, spelled differently from a
# skipped row.
run_passed_no_steps() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed
EOF
}

run_failed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
EOF
}

run_ci_monitoring() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_fixing_ci_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_ci_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,fixing,0,0
EOF
}

# Recorded from run 01M0JMD3H94MKKF7SCM5C5QWR6 (2026-08-21), the false-done
# incident: every step completed EXCEPT ci, which was skipped, so the run
# reached `outcome: passed` while its PR stayed open, conflicted, and carried no
# checks at all. `outcome: passed` means the pipeline completed, not that CI did.
run_passed_ci_skipped() {  # <branch>
  cat <<EOF
run:
  id: "01M0JMD3H94MKKF7SCM5C5QWR6"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/6"
  findings: "2 awaiting, 3 info"
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,25007
    rebase,completed,0,1591
    review,completed,2,671938
    test,completed,0,951876
    document,completed,2,623133
    lint,completed,0,6280
    push,completed,0,3735
    pr,completed,0,75403
    ci,skipped,1,4221
outcome: passed
EOF
}

# Recorded from run 01M0JASXQ1H4Q5YAZYJT03F1HN (2026-08-21): the same outcome
# word, but its ci step actually ran to completion.
run_passed_ci_completed() {  # <branch>
  cat <<EOF
run:
  id: "01M0JASXQ1H4Q5YAZYJT03F1HN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/9"
  findings: "1 auto-fix, 1 info"
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,15
    rebase,completed,0,1798
    review,completed,1,3655286
    test,completed,1,2096186
    document,completed,0,938812
    lint,completed,0,2952
    push,completed,0,4579
    pr,completed,0,83478
    ci,completed,0,886177
outcome: passed
EOF
}

# Recorded from run 01M0EFHKF1A3CJX4KK58HWJ7D2 (2026-08-20): the terminal-failed
# run that sat at the task worktree's own head while a newer run was live. Its
# daemon died mid-review, which is how the superseded/live pair arises.
run_failed_at_local_head() {  # <branch> <head>
  cat <<EOF
run:
  id: "01M0EFHKF1A3CJX4KK58HWJ7D2"
  branch: $1
  status: failed
  head: "$2"
  findings: "1 awaiting, 1 auto-fix, 1 info"
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,12
    rebase,completed,0,1686
    review,failed,3,2391918
    test,pending,0,0
    document,pending,0,0
    lint,pending,0,0
    push,pending,0,0
    pr,pending,0,0
    ci,pending,0,0
outcome: failed
error: "step review failed: agent review: claude exited: exit status 1: "
EOF
}

# Recorded from run 01M0N8J9ET64CBM89W4D663WBZ while it was live. The
# active_steps table is the daemon's own statement of what is executing right
# now; its last_activity column is quoted free text that contains commas of its
# own, so this fixture also pins the quote-aware column read.
run_live_active_step() {  # <branch> <head>
  cat <<EOF
run:
  id: "01M0N8J9ET64CBM89W4D663WBZ"
  branch: $1
  status: running
  head: "$2"
  findings: 2 auto-fix
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,7
    rebase,completed,0,1517
    review,completed,2,2728864
    test,running,0,0
    document,pending,0,0
    lint,pending,0,0
    push,pending,0,0
    pr,pending,0,0
    ci,pending,0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    test,running,3m38s,"3m11s ago: log: Now let me run the primary targeted suite, then lint.","2419262",starting
EOF
}

# The same live-run shape with its tables in the OTHER order, and with nothing
# executing: an `active_steps` table carrying no rows, followed by the `steps`
# table. Every TOON table header carries commas inside its braces, so a reader
# that ends the active-steps table only at a blank or comma-free line runs on
# into the next table and reads ITS rows as active steps, under active_steps'
# column names - reporting `test,running,0,0` as the live activity. Every
# recorded record emits `steps` first; this fixture varies that order
# deliberately, because the verdict must not depend on it.
run_active_steps_before_steps() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUNORDER"
  branch: $1
  status: running
  head: "$2"
  findings: none
  active_steps[0]{step,status,active_for,last_activity,agent_pid,round}:
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,7
    review,completed,0,120
    test,running,0,0
EOF
}

# The `branch_sync:` block `axi status` adds when the invoking worktree's branch
# has a live pipeline push binding - which is how fm-crew-state always invokes it,
# from the task worktree. Field set and shape recorded from run
# 01M0N8J9ET64CBM89W4D663WBZ read from its own worktree. The identities are
# parameters so a case can drive each ownership equality apart deliberately, and
# so is the pipeline status, because that key sits at the same indent as the run
# object's own `status:` and names the state of the run that owns the BINDING.
branch_sync_block() {  # <pipeline-run-id> <pipeline-head> <local-head> <branch> [pipeline-status]
  cat <<EOF
branch_sync:
  state: behind
  changed: false
  local:
    branch: $4
    head: $3
    clean: true
  pipeline:
    run: "$1"
    status: ${5:-running}
    phase: ""
    submitted_head: $3
    current_head: $2
    pushed_head: $2
    pushed_at: 1787426383
    push_generation: 1
  target:
    kind: upstream
    remote: origin
    url: "https://github.com/o/r.git"
    ref: refs/heads/$4
  remote:
    observed_head: $2
    freshness: pipeline_push
    observed_at: 1787426383
  relation: behind
  safety: refresh_required
  pr_state: open
  next_action:
    code: sync
    command: no-mistakes axi sync
EOF
}

# ---------------------------------------------------------------------------
# (a) active run-step is authoritative
test_active_run_is_authoritative() {
  reset_fakes
  local d; d=$(new_case active)
  make_repo_on_branch "$d/wt" fm/feat-a
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-a.meta" "window=fm:fm-feat-a" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-a)"
  local out; out=$(run_crew_state "$d" feat-a)
  assert_contains "$out" "state: working" "active run -> working"
  assert_contains "$out" "source: run-step" "active run -> run-step source"
  assert_contains "$out" "validating (running)" "active run reports the step"
  pass "active run-step is authoritative"
}

# (b) needs-decision log + a resumed (running/fixing) run = SUPERSEDED
test_stale_needs_decision_superseded() {
  reset_fakes
  local d; d=$(new_case superseded)
  make_repo_on_branch "$d/wt" fm/feat-b
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-b.meta" "window=fm:fm-feat-b" "worktree=$d/wt" "kind=ship"
  printf 'working: started\nneeds-decision: pick A or B\n' > "$d/state/feat-b.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-b)"
  local out; out=$(run_crew_state "$d" feat-b)
  assert_contains "$out" "state: working" "resumed run -> working despite needs-decision log"
  assert_contains "$out" "source: run-step" "resumed run -> run-step source"
  assert_contains "$out" "superseded" "stale needs-decision log flagged superseded"
  pass "stale needs-decision over active run is superseded"
}

# blocked log + a resumed run is also superseded
test_stale_blocked_superseded() {
  reset_fakes
  local d; d=$(new_case superseded-blocked)
  make_repo_on_branch "$d/wt" fm/feat-bb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-bb.meta" "window=fm:fm-feat-bb" "worktree=$d/wt" "kind=ship"
  printf 'blocked: waiting on review answer\n' > "$d/state/feat-bb.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-bb)"
  local out; out=$(run_crew_state "$d" feat-bb)
  assert_contains "$out" "state: working" "resumed run -> working despite blocked log"
  assert_contains "$out" "superseded" "stale blocked log flagged superseded"
  pass "stale blocked over active run is superseded"
}

# (c) genuine parked run + needs-decision log AGREE -> parked, NOT superseded
test_genuine_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked)
  make_repo_on_branch "$d/wt" fm/feat-c
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-c.meta" "window=fm:fm-feat-c" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-c.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-c)"
  local out; out=$(run_crew_state "$d" feat-c)
  assert_contains "$out" "state: parked" "genuine parked run -> parked"
  assert_contains "$out" "source: run-step" "parked -> run-step source"
  assert_contains "$out" "2 finding(s)" "parked includes gate finding count"
  assert_contains "$out" "ask-user" "parked surfaces ask-user finding"
  assert_not_contains "$out" "superseded" "agreeing parked+needs-decision not flagged stale"
  pass "genuine parked run is not flagged superseded"
}

test_scalar_gate_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-scalar-gate)
  make_repo_on_branch "$d/wt" fm/feat-cs
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cs.meta" "window=fm:fm-feat-cs" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cs.status"
  FM_FAKE_AXI_STATUS="$(run_parked_scalar_gate_running fm/feat-cs)"
  local out; out=$(run_crew_state "$d" feat-cs)
  assert_contains "$out" "state: parked" "scalar gate wait -> parked"
  assert_contains "$out" "source: run-step" "scalar gate wait -> run-step source"
  assert_contains "$out" "parked at review" "scalar gate wait names the gate"
  assert_contains "$out" "1 finding(s)" "scalar gate wait includes finding count"
  assert_not_contains "$out" "superseded" "scalar gate wait not flagged stale"
  pass "scalar gate parked run is not flagged superseded"
}

test_gate_block_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-gate-block)
  make_repo_on_branch "$d/wt" fm/feat-cb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cb.meta" "window=fm:fm-feat-cb" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cb.status"
  FM_FAKE_AXI_STATUS="$(run_parked_in_gate_block fm/feat-cb)"
  local out; out=$(run_crew_state "$d" feat-cb)
  assert_contains "$out" "state: parked" "gate block wait -> parked"
  assert_contains "$out" "source: run-step" "gate block wait -> run-step source"
  assert_contains "$out" "parked at review" "gate block wait names the gate"
  assert_contains "$out" "1 finding(s)" "gate block wait includes finding count"
  assert_not_contains "$out" "superseded" "gate block wait not flagged stale"
  pass "gate block parked run is not flagged superseded"
}

test_ci_ready_done_log_beats_monitoring_run() {
  reset_fakes
  local d; d=$(new_case ci-ready)
  make_repo_on_branch "$d/wt" fm/feat-ci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci.meta" "window=fm:fm-feat-ci" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-ci.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ci)"
  forge_answers_open
  local out; out=$(run_crew_state "$d" feat-ci)
  assert_contains "$out" "state: done" "ci-ready status log -> done"
  assert_contains "$out" "source: status-log" "ci-ready state comes from the status log"
  assert_contains "$out" "checks green" "ci-ready detail preserves the report"
  assert_not_contains "$out" "state: working" "ci-ready is not hidden by monitoring run"
  pass "ci-ready status log beats monitoring run"
}

# Regression for the PR #252 incident: the crew's own status log never got a
# "done: ... checks green" line (log_reports_ci_ready above does not apply),
# but the ci step's log tail shows CI is actually green and only waiting on
# merge/close. fm-crew-state must surface this as done, not "validating
# (running)", so a green PR is never silently absorbed as still-in-progress.
test_ci_monitoring_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-green)
  make_repo_on_branch "$d/wt" fm/feat-cigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cigreen.meta" "window=fm:fm-feat-cigreen" "worktree=$d/wt" "kind=ship"
  # No status-log line at all: the crew never reported its own checks-green line.
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cigreen)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
EOF
)
  forge_answers_open
  local out; out=$(run_crew_state "$d" feat-cigreen)
  assert_contains "$out" "state: done" "green ci-monitor run -> done"
  assert_contains "$out" "source: run-step" "green ci-monitor -> run-step source"
  assert_contains "$out" "checks green" "green ci-monitor detail mentions checks green"
  assert_not_contains "$out" "state: working" "green ci-monitor must not read as still validating"
  pass "ci-monitoring run with checks already green surfaces done"
}

test_top_level_ci_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case top-level-ci-green)
  make_repo_on_branch "$d/wt" fm/feat-topcigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topcigreen.meta" "window=fm:fm-feat-topcigreen" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_top_level_ci fm/feat-topcigreen)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  forge_answers_open
  local out; out=$(run_crew_state "$d" feat-topcigreen)
  assert_contains "$out" "state: done" "top-level ci with green log -> done"
  assert_contains "$out" "source: run-step" "top-level ci green -> run-step source"
  assert_contains "$out" "checks green" "top-level ci green detail mentions checks green"
  assert_not_contains "$out" "state: working" "top-level ci green must not stay working"
  pass "top-level ci status uses ci log green marker"
}

test_ci_monitoring_no_checks_terminal_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-nochecks)
  make_repo_on_branch "$d/wt" fm/feat-cinochecks
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecks.meta" "window=fm:fm-feat-cinochecks" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecks)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  forge_answers_open
  local out; out=$(run_crew_state "$d" feat-cinochecks)
  assert_contains "$out" "state: done" "terminal no-checks ci-monitor run -> done"
  assert_contains "$out" "checks green" "terminal no-checks ci-monitor detail mentions checks green"
  pass "terminal no-checks ci-monitor marker surfaces done"
}

test_ci_monitoring_green_then_rearm_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-rearm)
  make_repo_on_branch "$d/wt" fm/feat-cirearm
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirearm.meta" "window=fm:fm-feat-cirearm" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirearm)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirearm)
  assert_contains "$out" "state: working" "base-advance rearm marker -> working"
  assert_not_contains "$out" "state: done" "base-advance rearm marker must not read as done"
  assert_not_contains "$out" "checks green" "base-advance rearm marker must not read as checks green"
  pass "base-advance rearm after green stays working"
}

test_ci_monitoring_no_checks_yet_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-yet)
  make_repo_on_branch "$d/wt" fm/feat-cinochecksyet
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecksyet.meta" "window=fm:fm-feat-cinochecksyet" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecksyet)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
no CI checks reported - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
no CI checks reported yet, waiting for checks to register...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cinochecksyet)
  assert_contains "$out" "state: working" "pending no-checks marker -> working"
  assert_not_contains "$out" "state: done" "pending no-checks marker must not read as done"
  assert_not_contains "$out" "checks green" "pending no-checks marker must not read as checks green"
  pass "pending no-checks ci-monitor marker stays working"
}

test_ci_monitoring_still_waiting_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-waiting)
  make_repo_on_branch "$d/wt" fm/feat-ciwait
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciwait.meta" "window=fm:fm-feat-ciwait" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciwait)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-ciwait)
  assert_contains "$out" "state: working" "ci step still red -> working"
  assert_not_contains "$out" "checks green" "no green marker present -> no checks-green detail"
  pass "ci-monitoring run with checks not yet green stays working"
}

# A later merge-conflict auto-fix round after an earlier green reading must
# not be masked: the MOST RECENT marker in the log tail wins.
test_ci_monitoring_green_then_new_issue_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-issue)
  make_repo_on_branch "$d/wt" fm/feat-cirelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirelapse.meta" "window=fm:fm-feat-cirelapse" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
issues detected: merge conflict - auto-fixing (attempt 2/10)...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirelapse)
  assert_contains "$out" "state: working" "a later relapse marker must win over an earlier green one"
  assert_not_contains "$out" "state: done" "relapsed ci run must not read as done"
  pass "a fresh issue after an earlier green reading is not masked"
}

test_ci_ready_done_log_relapse_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-ready-then-relapse)
  make_repo_on_branch "$d/wt" fm/feat-cireadyrelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cireadyrelapse.meta" "window=fm:fm-feat-cireadyrelapse" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cireadyrelapse.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cireadyrelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
CI checks running, waiting for results...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cireadyrelapse)
  assert_contains "$out" "state: working" "a stale ready status must not mask a later CI relapse"
  assert_contains "$out" "source: run-step" "relapsed ci run remains run-step sourced"
  assert_not_contains "$out" "state: done" "relapsed ci run with stale done log must not read as done"
  pass "stale checks-green status log does not mask CI relapse"
}

test_ci_fixing_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-fixing-after-green)
  make_repo_on_branch "$d/wt" fm/feat-cifixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cifixing.meta" "window=fm:fm-feat-cifixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cifixing.status"
  FM_FAKE_AXI_STATUS="$(run_ci_fixing fm/feat-cifixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cifixing)
  assert_contains "$out" "state: working" "ci fixing step must stay working"
  assert_contains "$out" "source: run-step" "ci fixing remains run-step sourced"
  assert_not_contains "$out" "state: done" "ci fixing must not read as checks-green done"
  pass "ci fixing is not overridden by an earlier green marker"
}

test_top_level_fixing_ci_running_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-ci-running)
  make_repo_on_branch "$d/wt" fm/feat-topfixingci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixingci.meta" "window=fm:fm-feat-topfixingci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_fixing_ci_running fm/feat-topfixingci)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixingci)
  assert_contains "$out" "state: working" "top-level fixing with ci running must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing with ci running remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not use stale green marker"
  pass "top-level fixing is not overridden by a stale ci running row"
}

test_top_level_fixing_done_log_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-done-log)
  make_repo_on_branch "$d/wt" fm/feat-topfixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixing.meta" "window=fm:fm-feat-topfixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-topfixing.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-topfixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixing)
  assert_contains "$out" "state: working" "top-level fixing must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not read as stale checks-green done"
  pass "top-level fixing is not overridden by a stale done log"
}

# (d) terminal run-step is authoritative
test_terminal_passed() {
  reset_fakes
  local d; d=$(new_case passed)
  make_repo_on_branch "$d/wt" fm/feat-d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-d.meta" "window=fm:fm-feat-d" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-d)"
  forge_answers_open
  local out; out=$(run_crew_state "$d" feat-d)
  assert_contains "$out" "state: done" "passed run -> done"
  assert_contains "$out" "source: run-step" "passed -> run-step source"
  pass "terminal passed run is authoritative"
}

test_terminal_failed() {
  reset_fakes
  local d; d=$(new_case failed)
  make_repo_on_branch "$d/wt" fm/feat-e
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-e.meta" "window=fm:fm-feat-e" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-e)"
  local out; out=$(run_crew_state "$d" feat-e)
  assert_contains "$out" "state: failed" "failed run -> failed"
  assert_contains "$out" "source: run-step" "failed -> run-step source"
  pass "terminal failed run is authoritative"
}

# (e) cross-branch attribution: `axi status` returns ANOTHER branch's run (the
# routine case once more than one crew validates the same underlying repo
# concurrently - they share ONE no-mistakes repo registration), so the helper
# falls back to the real top-level `no-mistakes runs` listing to learn whether
# THIS branch has an active run of its own. Regression coverage for the
# 2026-07-02 herdr incident: the old fallback shelled out to `no-mistakes axi`
# (bare) expecting a `runs[N]{...}:` TOON table that the real CLI never emits
# (verified against the installed v1.32.2 - the `axi` surface has no
# runs-listing subcommand at all), so attribution silently failed every time
# the repo-wide answer was not this crew's own branch.
test_cross_branch_attribution_via_runs_list() {
  reset_fakes
  local d short; d=$(new_case crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-f
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f.meta" "window=fm:fm-feat-f" "worktree=$d/wt" "kind=ship"
  # The repo-wide active/most-recent run belongs to a different crew's branch.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  # Real `no-mistakes runs` shape: plain text, newest-first, no run id, no
  # quoting - "<status> <branch> <short-sha> <date> [<pr-url>]".
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-f ${short}  2026-07-02 22:05
EOF
)"
  local out; out=$(run_crew_state "$d" feat-f)
  assert_contains "$out" "state: working" "this branch's own run attributed via the runs list"
  assert_contains "$out" "source: run-step" "runs-list-resolved run -> run-step source"
  pass "cross-branch run is attributed via the real runs list"
}

# The runs list is newest-first; a branch with an OLDER completed run must not
# shadow its own newer active one - the first (topmost) matching row wins.
test_cross_branch_attribution_picks_most_recent_row() {
  reset_fakes
  local d short; d=$(new_case crossbranch-mostrecent)
  make_repo_on_branch "$d/wt" fm/feat-fq
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-fq.meta" "window=fm:fm-feat-fq" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-fq ${short}  2026-07-02 21:50
  completed  fm/feat-fq bbbbbbb  2026-07-02 20:00  https://github.com/o/r/pull/1
EOF
)"
  local out; out=$(run_crew_state "$d" feat-fq)
  assert_contains "$out" "state: working" "most recent (running) row wins over an older completed row"
  assert_contains "$out" "source: run-step" "most-recent-row resolution -> run-step source"
  pass "cross-branch attribution picks the branch's most recent row"
}

test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status() {
  reset_fakes
  local d short; d=$(new_case coarse-ready-other-log)
  make_repo_on_branch "$d/wt" fm/feat-coarseready
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarseready.meta" "window=fm:fm-feat-coarseready" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/4 checks green\n' > "$d/state/feat-coarseready.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-coarseready ${short}  2026-07-02 22:05
EOF
)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  forge_answers_open
  local out; out=$(run_crew_state "$d" feat-coarseready)
  assert_contains "$out" "state: done" "coarse ready status -> done"
  assert_contains "$out" "source: status-log" "coarse ready status remains status-log sourced"
  assert_not_contains "$out" "state: working" "coarse ready status must not be suppressed by another branch log"
  pass "coarse run does not probe another branch's ci log"
}

# A different-branch run with NO matching runs-list row must NOT be
# misattributed, and must not be treated as a false "working" verdict either.
test_other_branch_run_ignored() {
  reset_fakes
  local d; d=$(new_case otherbranch)
  make_repo_on_branch "$d/wt" fm/feat-g
  make_fakebin "$d" >/dev/null
  # The recorded PR is what keeps this case about ATTRIBUTION. Its subject is
  # that another branch's run is not misattributed and the status log answers
  # instead, and the log verb it asserts is `done` - which a SHIP task may only
  # reach once a PR exists for the forge to rule on (fm_crew_no_pr_class). Left
  # PR-less, the case would silently start asserting that rule instead of its own.
  fm_write_meta "$d/state/feat-g.meta" "window=fm:fm-feat-g" "worktree=$d/wt" "kind=ship" "harness=claude" \
    "pr=https://github.com/o/r/pull/3"
  printf 'done: implemented, ready to validate\n' > "$d/state/feat-g.status"
  forge_answers_open
  FM_FAKE_AXI_STATUS="$(run_running fm/some-other)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/some-other aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-g
  local out; out=$(run_crew_state "$d" feat-g)
  assert_not_contains "$out" "source: run-step" "another branch's run not misattributed"
  assert_contains "$out" "source: status-log" "no own run -> falls back to status-log"
  assert_contains "$out" "state: done" "falls back to the log verb"
  pass "another branch's run is ignored, falls back"
}

# (f) no run for this crew + a busy pane -> working via pane
test_no_run_busy_pane() {
  reset_fakes
  local d; d=$(new_case busy)
  make_repo_on_branch "$d/wt" fm/feat-h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h.meta" "window=fm:fm-feat-h" "worktree=$d/wt" "kind=ship" "harness=claude"
  # No matching run anywhere. The busy verdict comes from the crew's own
  # semantic lifecycle record (bin/fm-busy-lib.sh), not from rendered text.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-h)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-h busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-h)
  assert_contains "$out" "state: working" "busy record -> working"
  assert_contains "$out" "source: pane" "busy record -> pane source"
  assert_contains "$out" "claude-hook" "the working verdict names its semantic source"
  pass "no run + a busy semantic record reads working, attributed to its source"
}

# A converted adapter must NOT read working from rendered footer text: the
# redesign removed that dependency, so a pane painting "esc to interrupt" with
# no semantic record is unknown, never working and never silently idle.
test_no_run_footer_text_alone_is_not_working() {
  reset_fakes
  local d; d=$(new_case busy-footer-only)
  make_repo_on_branch "$d/wt" fm/feat-h2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h2.meta" "window=fm:fm-feat-h2" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  printf 'done: stale completion event\n' > "$d/state/feat-h2.status"
  local out; out=$(run_crew_state "$d" feat-h2)
  assert_not_contains "$out" "state: working" "a footer alone must not read working for a converted adapter"
  assert_contains "$out" "state: unknown" "no semantic record -> unknown"
  assert_not_contains "$out" "source: status-log" "unknown semantic state must not fall through to a stale log"
  pass "a converted adapter never reads working from rendered footer text"
}

# Grok keeps its isolated temporary rendered-tail fallback until its structured
# lifecycle is live-verified, so a grok crew still reads working from its own
# verified signature.
test_no_run_grok_uses_isolated_fallback() {
  reset_fakes
  local d; d=$(new_case busy-grok)
  make_repo_on_branch "$d/wt" fm/feat-h3
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h3.meta" "window=fm:fm-feat-h3" "worktree=$d/wt" "kind=ship" "harness=grok"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT='Ctrl+c:cancel'
  export FM_FAKE_BUSY_TEXT
  local out; out=$(run_crew_state "$d" feat-h3)
  assert_contains "$out" "state: working" "grok busy tail -> working"
  assert_contains "$out" "grok-regex" "the grok verdict names its isolated fallback source"
  pass "grok still reads working through its isolated rendered-tail fallback"
}

test_no_run_herdr_unknown_uses_backend_capture() {
  command -v jq >/dev/null 2>&1 || { pass "herdr pane fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-busy)
  make_repo_on_branch "$d/wt" fm/feat-herdr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_BUSY=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-herdr)
  assert_contains "$out" "state: working" "herdr native busy -> working"
  assert_contains "$out" "source: pane" "herdr native busy -> pane source"
  assert_contains "$out" "herdr-native" "the herdr verdict names its native source"
  pass "herdr's native busy verdict reads working with no record present"
}

# Regression (2026-07 herdr false-surface incident, now solved semantically):
# herdr's agent.get reports generation state ("working" only while the model is
# actively streaming - docs/herdr-backend.md "Busy state"), not "this crew's
# turn is still in progress". A crew blocked on its own long-running foreground
# `no-mistakes axi run` (no --yes; blocks until a gate or outcome) is not
# generating for that whole span, so agent.get reads idle. The crew's own
# semantic lifecycle record still says busy for the whole turn, and it outranks
# the narrower native verdict - so the crew is no longer misread as not-working.
test_no_run_herdr_idle_agent_status_outranked_by_record() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle corroboration skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-busy-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-idle
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-idle.meta" "window=default:w1:p3" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  # No run attributable (mirrors a no-mistakes run-step lookup that found no
  # matching row within the configured runs-list window): the crew's semantic
  # busy state is the only remaining signal.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-idle)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-idle busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-herdr-idle)
  assert_contains "$out" "state: working" "a busy record with herdr idle agent_status -> working"
  assert_contains "$out" "claude-hook" "the record's source outranks herdr's narrower native verdict"
  pass "a mid-tool-call crew stays working because its record outranks herdr's generation state"
}

# The record must not mask a genuinely idle or human-blocked agent: an idle
# record with idle agent_status still reads not-busy.
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle+idle-record skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-idle-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stopped.meta" "window=default:w1:p4" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-herdr-stopped.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-stopped)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-stopped idle --gen "$gen" \
    --source claude-hook --event stop
  local out; out=$(run_crew_state "$d" feat-herdr-stopped)
  assert_not_contains "$out" "source: pane" "an idle record must not read as busy"
  assert_contains "$out" "source: status-log" "an idle record falls to the status log"
  pass "an idle record with idle agent_status stays not-busy (no regression for a human-blocked agent)"
}

# (g) no run + idle pane -> the status-log verb, as-is
test_no_run_idle_pane_uses_log() {
  reset_fakes
  local d; d=$(new_case idle)
  make_repo_on_branch "$d/wt" fm/feat-i
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-i.meta" "window=fm:fm-feat-i" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: which database?\n' > "$d/state/feat-i.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-i
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: parked" "needs-decision log -> parked"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  pass "no run + idle pane uses the status-log verb"
}

test_no_run_idle_pane_uses_keyed_log() {
  reset_fakes
  local d; d=$(new_case keyed-idle)
  make_repo_on_branch "$d/wt" fm/feat-keyed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-keyed.meta" "window=fm:fm-feat-keyed" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision [key=q1]: which database?\n' > "$d/state/feat-keyed.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-keyed
  local out; out=$(run_crew_state "$d" feat-keyed)
  assert_contains "$out" "state: parked" "keyed needs-decision log -> parked"
  assert_contains "$out" "which database?" "key token is excluded from status detail"
  pass "no run + idle pane parses keyed status syntax"
}

# (g') no run + idle pane on a DECLARED external-wait pause -> state: paused, so a
# supervisor reading the crew sees a distinct pause (and its reason) rather than a
# wedge-suspect idle. This is the reader half the watcher/daemon build on.
test_no_run_idle_pane_paused() {
  reset_fakes
  local d; d=$(new_case paused)
  make_repo_on_branch "$d/wt" fm/feat-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pause.meta" "window=fm:fm-feat-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'paused: holding for the upstream tool release\n' > "$d/state/feat-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-pause
  local out; out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "paused log -> paused"
  assert_contains "$out" "source: status-log" "idle pause -> status-log source"
  assert_contains "$out" "holding for the upstream tool release" "the pause reason is carried in the detail"
  pass "no run + idle pane on a paused: status reports state: paused with its reason"
}

test_no_run_idle_pane_custom_paused_verb() {
  reset_fakes
  local d; d=$(new_case custom-paused)
  make_repo_on_branch "$d/wt" fm/feat-custom-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-custom-pause.meta" "window=fm:fm-feat-custom-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'awaiting: vendor maintenance window\n' > "$d/state/feat-custom-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-custom-pause
  local out; out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: paused" "custom paused verb -> paused"
  assert_contains "$out" "source: status-log" "custom paused verb -> status-log source"
  assert_contains "$out" "vendor maintenance window" "custom pause preserves its reason"
  printf 'paused: default verb no longer selected\n' > "$d/state/feat-custom-pause.status"
  out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: unknown" "custom paused verb replaces the default"
  pass "no run + idle pane honors the configured paused verb"
}

# A trailing keyed resolved: event is a decision-CLOSING event, not a run-state
# verb. It must never become the current state or leak its resolution prose as the
# detail: a healthy idle secondmate that just closed a keyed decision falls through
# to the idle default (unknown/none), not `unknown` with the resolution note as its
# `doing`. Regression for the bearings render bug where such a secondmate showed
# state=unknown with resolution prose. The one-owner keyed fold in fm-classify-lib.sh
# is untouched; this only stops the deriver from reading a non-state event as state.
test_no_run_idle_secondmate_resolved_event_not_state() {
  reset_fakes
  local d; d=$(new_case resolved-idle)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "home=$d/wt"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$d/state/mate.status"
  printf 'resolved [key=race]: went with subscribe-before-write\n' >> "$d/state/mate.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "resolved-then-idle secondmate is not a spurious run-state"
  assert_contains "$out" "source: none" "a resolved event is not treated as a status-log state source"
  assert_not_contains "$out" "subscribe-before-write" "resolution prose must not leak into the detail"
  # A bare (non-keyed) resolved: closes the default key and behaves the same.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "source: none" "a bare resolved: is not a state source either"
  assert_not_contains "$out" "infra access granted" "bare resolution prose must not leak into the detail"
  # Control: a genuine trailing state verb still renders from the log.
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a real trailing state verb still renders"
  assert_contains "$out" "reconciling routed items" "a real state line still carries its detail"
  pass "a trailing resolved: event does not corrupt state render (idle stays idle)"
}

test_dead_window_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case dead-window)
  make_repo_on_branch "$d/wt" fm/feat-dead
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead.meta" "window=fm:fm-feat-dead" "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-dead.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead)
  assert_contains "$out" "state: unknown" "dead window -> unknown"
  assert_contains "$out" "source: none" "dead window -> none source"
  assert_not_contains "$out" "source: status-log" "dead window does not reuse stale log"
  pass "dead window ignores stale status log"
}

# A closed/unreadable pane must NOT mask an authoritative run-step: judge by the
# run-step, not the shell. The common case is a finished crew whose agent has
# exited and closed its window (the normal gap between completion and teardown) -
# it must still report its terminal run-step state (e.g. done), never unknown.
test_dead_window_still_reports_terminal_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-done)
  make_repo_on_branch "$d/wt" fm/feat-dead-done
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-done.meta" "window=fm:fm-feat-dead-done" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/3 checks green\n' > "$d/state/feat-dead-done.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-dead-done)"
  forge_answers_open
  FM_FAKE_TMUX_MISSING=1   # the crew's window has closed
  local out; out=$(run_crew_state "$d" feat-dead-done)
  assert_contains "$out" "state: done" "closed pane still reports terminal run-step done"
  assert_contains "$out" "source: run-step" "closed pane does not mask the run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with a run must never be unknown"
  pass "closed pane still reports a terminal run-step"
}

# The same for an active run: an agent pane that crashed mid-validation while the
# daemon-backed run continues must report the live run-step, not unknown.
test_dead_window_still_reports_active_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-active)
  make_repo_on_branch "$d/wt" fm/feat-dead-act
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-act.meta" "window=fm:fm-feat-dead-act" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-dead-act)"
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead-act)
  assert_contains "$out" "state: working" "closed pane still reports active run-step"
  assert_contains "$out" "source: run-step" "closed pane does not mask the active run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with an active run must never be unknown"
  pass "closed pane still reports an active run-step"
}

test_no_timeout_uses_perl_bound() {
  reset_fakes
  local d toolbin out start elapsed calls_file calls
  d=$(new_case no-timeout)
  make_repo_on_branch "$d/wt" fm/feat-timeout
  make_fakebin "$d" >/dev/null
  calls_file="$d/no-mistakes.calls"
  : > "$calls_file"
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:-/dev/null}"
while :; do :; done
SH
  chmod +x "$d/fakebin/no-mistakes"
  toolbin=$(make_no_timeout_toolbin "$d")
  fm_write_meta "$d/state/feat-timeout.meta" "window=fm:fm-feat-timeout" "worktree=$d/wt" "kind=ship" \
    "harness=claude"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-timeout)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-timeout busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  start=$SECONDS
  out=$(FM_FAKE_NM_CALLS="$calls_file" PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" feat-timeout)
  elapsed=$((SECONDS - start))
  assert_contains "$out" "state: working" "timed-out no-mistakes falls back to pane"
  assert_contains "$out" "source: pane" "timed-out no-mistakes -> pane source"
  [ "$elapsed" -lt "$NM_TIMEOUT_WALL_LIMIT" ] \
    || fail "perl timeout did not bound no-mistakes calls (elapsed ${elapsed}s, bound ${NM_TIMEOUT_WALL_LIMIT}s)"
  calls=$(awk 'END { print NR + 0 }' "$calls_file" 2>/dev/null || echo 0)
  [ "$calls" -eq 1 ] || fail "empty no-mistakes status triggered extra lookups ($calls calls)"
  pass "no timeout command uses perl bound"
}

# (i) kind=scout skips the run lookup entirely (its deliverable is a report).
test_scout_skips_run_lookup() {
  reset_fakes
  local d; d=$(new_case scout)
  make_repo_on_branch "$d/wt" fm/scout-j
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/scout-j.meta" "window=fm:fm-scout-j" "worktree=$d/wt" "kind=scout" \
    "harness=claude"
  # Even if a run existed on this branch, a scout must not read it.
  FM_FAKE_AXI_STATUS="$(run_running fm/scout-j)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" scout-j)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" scout-j busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" scout-j)
  assert_not_contains "$out" "source: run-step" "scout ignores no-mistakes run-step"
  assert_contains "$out" "source: pane" "scout reads its semantic busy state"
  pass "scout skips the run lookup"
}

# (j) torn-down worktree and missing meta are graceful (unknown/none, exit 0)
test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torndown)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/gone-k.meta" "window=fm:fm-gone-k" "worktree=$d/no-such-worktree" "kind=ship"
  local out rc
  out=$(run_crew_state "$d" gone-k); rc=$?
  expect_code 0 "$rc" "torn-down worktree exits 0"
  assert_contains "$out" "state: unknown" "torn-down -> unknown"
  assert_contains "$out" "source: none" "torn-down -> none source"
  pass "torn-down worktree is handled gracefully"
}

test_missing_meta() {
  reset_fakes
  local d; d=$(new_case nometa)
  make_fakebin "$d" >/dev/null
  local out rc
  out=$(run_crew_state "$d" ghost-z); rc=$?
  expect_code 0 "$rc" "missing meta exits 0"
  assert_contains "$out" "state: unknown" "missing meta -> unknown"
  assert_contains "$out" "source: none" "missing meta -> none source"
  pass "missing meta is handled gracefully"
}

# (k) crew_is_provably_working end-to-end over the REAL fm-crew-state.sh (not a
# canned fake verdict, unlike tests/fm-watch-triage.test.sh's classifier
# coverage). This is the direct regression pair for the 2026-07-02 herdr
# incident: a validating crew whose bare `axi status` answer belongs to
# another branch must still be absorbed by the watcher via the runs-list
# fallback (working), while a crew with genuinely no run anywhere and an idle
# pane must still surface (the safety property the fix must never widen away).
test_provably_working_via_runs_list_fallback() {
  reset_fakes
  local d short; d=$(new_case provably-working-crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-provable
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-provable.meta" "window=fm:fm-feat-provable" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-provable ${short}  2026-07-02 22:05
EOF
)"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-provable \
    || fail "cross-branch attribution via the runs list was not treated as provably working"
  pass "crew_is_provably_working absorbs a validating crew found only via the runs-list fallback"
}

test_not_provably_working_when_stopped() {
  reset_fakes
  local d; d=$(new_case provably-working-stopped)
  make_repo_on_branch "$d/wt" fm/feat-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-stopped.meta" "window=fm:fm-feat-stopped" "worktree=$d/wt" "kind=ship"
  # Repo-wide run belongs to someone else, and this branch has no row in the
  # runs list either (it never validated, or genuinely finished/stopped) - the
  # only remaining signal is the pane, which is idle.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-stopped \
    && fail "a stopped crew with no run anywhere and an idle pane was treated as provably working"
  pass "crew_is_provably_working still surfaces a genuinely stopped crew (safety property preserved)"
}

# Usage error (no id) is the one non-zero exit.
test_usage_error() {
  reset_fakes
  local rc
  "$CREW_STATE" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  pass "usage error exits 2"
}

# Head-binding: same branch name with a rewritten/diverged worktree tip must not
# attribute a historical no-mistakes run (multi-stage branch reuse incident).
test_historical_same_branch_rewritten_head_not_current() {
  reset_fakes
  local d old_head new_head out
  d=$(new_case rewritten-head)
  make_repo_on_branch "$d/wt" fm/todo-flag
  old_head=$(git -C "$d/wt" rev-parse HEAD)
  # Simulate a rebase rewrite: orphan new history on the same branch name.
  git -C "$d/wt" checkout -q --orphan tmp-rewrite
  git -C "$d/wt" commit -q --allow-empty -m 'rewritten tip'
  git -C "$d/wt" branch -q -M fm/todo-flag
  new_head=$(git -C "$d/wt" rev-parse HEAD)
  [ "$old_head" != "$new_head" ] || fail "rewrite did not produce a new head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/wishlist.meta" "window=fm:fm-wishlist" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 setup complete rebased onto merged #76\n' > "$d/state/wishlist.status"
  # Historical run still reports the pre-rewrite head on the reused branch.
  FM_FAKE_RUN_HEAD="$old_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/todo-flag)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" wishlist
  out=$(run_crew_state "$d" wishlist)
  assert_not_contains "$out" "source: run-step" "historical rewritten head must not use run-step"
  assert_not_contains "$out" "parked at" "historical parked run must not mask current state"
  assert_contains "$out" "source: status-log" "falls back to status-log after head mismatch"
  assert_contains "$out" "state: working" "status-log working: remains current"
  pass "historical same-branch rewritten head is not attributed as current"
}

# Head-binding: an active pipeline whose run head is a descendant of the local
# tip (fix commits on the same history) remains current.
test_active_run_descendant_fix_head_remains_current() {
  reset_fakes
  local d base_head fix_head out
  d=$(new_case pipeline-descendant)
  make_repo_on_branch "$d/wt" fm/feat-pipeline
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'pipeline fix commit'
  fix_head=$(git -C "$d/wt" rev-parse HEAD)
  # Worktree still at the pre-fix tip; run reports the pipeline fix head.
  git -C "$d/wt" reset -q --hard "$base_head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/pipe.meta" "window=fm:fm-pipe" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$fix_head"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-pipeline)"
  out=$(run_crew_state "$d" pipe)
  assert_contains "$out" "source: run-step" "descendant pipeline fix head remains run-step"
  assert_contains "$out" "state: working" "active fixing run remains working"
  pass "active run with valid descendant fix head remains current"
}

# Head-binding: local work that advanced past the run head invalidates the run.
test_local_advanced_past_run_head_invalidates() {
  reset_fakes
  local d run_head out
  d=$(new_case local-advanced)
  make_repo_on_branch "$d/wt" fm/feat-adv
  run_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'local stage-2 work after prior run'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/adv.meta" "window=fm:fm-adv" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 implementation in progress\n' > "$d/state/adv.status"
  FM_FAKE_RUN_HEAD="$run_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-adv)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" adv
  out=$(run_crew_state "$d" adv)
  assert_not_contains "$out" "source: run-step" "local-advanced tip must not use historical run"
  assert_contains "$out" "source: status-log" "falls back after local advanced past run"
  assert_contains "$out" "state: working" "status-log working: is current"
  pass "local work advanced past run head invalidates attribution"
}

test_missing_run_head_falls_back_to_current_state() {
  reset_fakes
  local d out
  d=$(new_case missing-run-head)
  make_repo_on_branch "$d/wt" fm/feat-no-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/no-head.meta" "window=fm:fm-no-head" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: current stage still in progress\n' > "$d/state/no-head.status"
  FM_FAKE_AXI_STATUS=$(run_parked fm/feat-no-head | grep -v '^  head:')
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" no-head
  out=$(run_crew_state "$d" no-head)
  assert_not_contains "$out" "source: run-step" "missing run head must not permit branch-only attribution"
  assert_contains "$out" "source: status-log" "missing run head falls back to current state sources"
  assert_contains "$out" "state: working" "status-log remains current after missing run head"
  pass "missing run head falls back instead of matching by branch"
}

# ---------------------------------------------------------------------------
# Run selection: a superseded terminal run must never mask a live one.
#
# Reproduced twice on the real fleet (2026-08-19 and 2026-08-21) and filed with
# exact heads: the pipeline advanced the branch to a commit the task worktree had
# not fetched, so the LIVE run failed to bind to local code, selection stepped
# past it, and an OLDER terminal-failed run still sitting at the local head was
# reported instead. A demonstrably progressing task read `failed`, which
# AGENTS.md section 7 treats as terminal - it licenses abandoning the work or
# duplicating it, and it manufactured a captain-facing failure escalation.

# The runs-list path: `axi status` answers with another crew's run, so this
# branch's own newest row has to be found in the list.
test_superseded_failed_row_does_not_mask_live_row() {
  reset_fakes
  local d out
  d=$(new_case superseded-mask-coarse)
  make_pipeline_ahead_topology "$d" fm/feat-mask
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mask.meta" "window=fm:fm-mask" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: fix round under way\n' > "$d/state/mask.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="  running    fm/other-crew aaaaaaa  2026-08-21 15:30
  running    fm/feat-mask $(printf %.8s "$PIPE_HEAD")  2026-08-21 15:25
  failed     fm/feat-mask $(printf %.8s "$LOCAL_HEAD")  2026-08-20 02:21"
  out=$(run_crew_state "$d" mask)
  assert_contains "$out" "state: working" "the branch's newest run is live, so the task is working"
  assert_not_contains "$out" "state: failed" "a superseded failed row must never be selected"
  assert_contains "$out" "source: run-step" "the live row is attributed as the run"
  pass "a superseded failed row does not mask this branch's newest live row"
}

# The `axi status` path: the repo-wide answer already IS this branch's live run,
# at the head the task worktree cannot resolve. Reaching past it into the runs
# list is what found the dead run, so that fallback is not taken from here.
test_live_run_at_unfetched_head_is_not_replaced_by_older_failed_run() {
  reset_fakes
  local d out
  d=$(new_case superseded-mask-full)
  make_pipeline_ahead_topology "$d" fm/feat-ahead
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/ahead.meta" "window=fm:fm-ahead" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: fix round under way\n' > "$d/state/ahead.status"
  FM_FAKE_AXI_STATUS="$(run_live_active_step fm/feat-ahead "$PIPE_HEAD")"
  FM_FAKE_RUNS_LIST="  running    fm/feat-ahead $(printf %.8s "$PIPE_HEAD")  2026-08-21 15:25
  failed     fm/feat-ahead $(printf %.8s "$LOCAL_HEAD")  2026-08-20 02:21"
  out=$(run_crew_state "$d" ahead)
  assert_contains "$out" "state: working" "a live run whose head is merely unfetched is still live"
  assert_not_contains "$out" "state: failed" "the older failed run must not be reachable from here"
  assert_contains "$out" "test running" "the live run's own active step is reported"
  assert_contains "$out" "last activity 3m11s ago" "the activity age is reported for the supervisor"
  pass "a live run at an unfetched head is not replaced by an older failed run"
}

# A run with an actively executing step is the daemon stating it is alive NOW,
# and one branch cannot host two concurrent runs, so that liveness attributes the
# run whatever the head geometry says. Without it, a pipeline that is
# demonstrably working reads as no information at all - observed 2026-08-22,
# `unknown - no current-state source available` for a run whose step was mid-fix
# with a live agent pid.
# The other half of the same binding rule. A TERMINAL verdict is what licenses
# abandoning or escalating work, so it is emitted only from a run whose code
# identity this checkout can actually verify. An unfetched head is
# indistinguishable from a pruned or rewritten one, so a terminal run there
# degrades to "I do not know" rather than to a captain-facing failure - a
# handling turn is the cheap loss, a wrong terminal claim is not.
test_terminal_run_at_unfetched_head_is_not_attributed() {
  reset_fakes
  local d out
  d=$(new_case terminal-unfetched)
  make_pipeline_ahead_topology "$d" fm/feat-term
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/term.meta" "window=fm:fm-term" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'resolved: firstmate answered the review question\n' > "$d/state/term.status"
  FM_FAKE_AXI_STATUS="$(run_failed_at_local_head fm/feat-term "$PIPE_HEAD")"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" term
  out=$(run_crew_state "$d" term)
  assert_not_contains "$out" "source: run-step" "an unverifiable head must not carry a terminal verdict"
  assert_not_contains "$out" "state: failed" "no failure is claimed from a run this checkout cannot verify"
  assert_contains "$out" "state: unknown" "the honest answer is that the evidence does not settle it"
  pass "a terminal run at an unfetched head is not attributed"
}

test_live_active_step_attributes_run_despite_head_geometry() {
  reset_fakes
  local d run_head out
  d=$(new_case live-overrides-geometry)
  make_repo_on_branch "$d/wt" fm/feat-live
  run_head=$(git -C "$d/wt" rev-parse HEAD)
  # Local work advanced past the run head: geometry alone refuses this run.
  git -C "$d/wt" commit -q --allow-empty -m 'local commit made while the run was executing'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/live.meta" "window=fm:fm-live" "worktree=$d/wt" "kind=ship" "harness=claude"
  # A decision-closing event is not a state, so with the run discarded there is
  # no current-state source left and the answer collapses to unknown.
  printf 'resolved: firstmate answered the review question\n' > "$d/state/live.status"
  FM_FAKE_AXI_STATUS="$(run_live_active_step fm/feat-live "$run_head")"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" live
  out=$(run_crew_state "$d" live)
  assert_contains "$out" "state: working" "an executing step means the task is working"
  assert_contains "$out" "source: run-step" "liveness attributes the run itself"
  assert_not_contains "$out" "state: unknown" "a live pipeline must never read as no information"
  pass "an executing step attributes the run despite unbindable head geometry"
}

# ---------------------------------------------------------------------------
# Terminal-pass evidence: the destructive direction.
#
# Observed 2026-08-21: `state: done - run passed: PR merged/closed` for PR #6,
# which was OPEN, DIRTY and carried zero checks. The run had reached
# `outcome: passed` because every step either passed or was recorded SKIPPED -
# ci among them - and the "PR merged/closed" reason was never read from the forge
# at all. A firstmate trusting that reports the work as landed and tears down an
# unmerged branch.

test_ci_skipped_pass_does_not_read_as_done_by_itself() {
  reset_fakes
  local d out
  d=$(new_case ci-skipped-pass)
  make_repo_on_branch "$d/wt" fm/feat-skip
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/skip.meta" "window=fm:fm-skip" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'paused: holding for the signal that main is final\n' > "$d/state/skip.status"
  FM_FAKE_AXI_STATUS="$(run_passed_ci_skipped fm/feat-skip)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"DIRTY","state":"OPEN","url":"https://github.com/o/r/pull/6"}'
  out=$(run_crew_state "$d" skip)
  assert_not_contains "$out" "state: done" "a skipped ci step is the absence of validation, not validation"
  assert_contains "$out" "state: unknown" "the evidence does not settle whether this passed"
  assert_not_contains "$out" "state: parked" "a terminated run is not a gate the worker can respond to"
  assert_not_contains "$out" "merged" "an open PR must never be described as merged"
  assert_contains "$out" "run terminated" "the detail says the run is over, not waiting"
  assert_contains "$out" "ci SKIPPED" "the missing CI evidence is named"
  assert_contains "$out" "PR still open" "the forge's own answer is reported"
  pass "a run that passed with ci skipped does not read as done by itself"
}

test_merged_claim_requires_forge_confirmation() {
  reset_fakes
  local d out
  d=$(new_case merged-confirmed)
  make_repo_on_branch "$d/wt" fm/feat-merged
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/merged.meta" "window=fm:fm-merged" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_ci_completed fm/feat-merged)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"MERGED","url":"https://github.com/o/r/pull/9"}'
  out=$(run_crew_state "$d" merged)
  assert_contains "$out" "state: done" "a genuine pass with ci completed is done"
  assert_contains "$out" "PR merged" "the forge confirmed the merge, so the claim is allowed"
  pass "a merged claim is emitted once the forge confirms it"
}

test_open_pr_is_never_reported_as_merged() {
  reset_fakes
  local d out
  d=$(new_case open-not-merged)
  make_repo_on_branch "$d/wt" fm/feat-open
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/open.meta" "window=fm:fm-open" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_ci_completed fm/feat-open)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"BLOCKED","state":"OPEN","url":"https://github.com/o/r/pull/9"}'
  out=$(run_crew_state "$d" open)
  assert_contains "$out" "not merged" "an open PR is reported as not merged"
  assert_not_contains "$out" "PR merged" "the run's own pass claim cannot promote an open PR"
  assert_not_contains "$out" "PR closed" "nor invent a close"
  pass "an open PR is never reported as merged"
}

test_unanswered_forge_never_claims_a_landing() {
  reset_fakes
  local d out
  d=$(new_case forge-silent)
  make_repo_on_branch "$d/wt" fm/feat-silent
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/silent.meta" "window=fm:fm-silent" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_ci_completed fm/feat-silent)"
  FM_FAKE_GH_CALL_FAILS=1
  out=$(run_crew_state "$d" silent)
  assert_contains "$out" "unverified" "an unanswered forge is reported as unverified"
  assert_not_contains "$out" "merged" "an unanswered forge must never render as a landing"
  assert_not_contains "$out" "PR closed" "nor as a close"
  pass "an unanswered forge never claims a landing"
}

# CI evidence is one arm of the ranking, and a skipped ci step is only one way for
# it to be missing; a record with no steps table at all, and a ci row with any
# other status word, are the same absence spelled differently, and each one used
# to fall straight through to `done - run passed`. Both fixtures below hold an
# OPEN PR, so no confirmed landing is available to settle them either - that is
# what makes the absence decisive rather than merely present.
test_terminal_pass_with_no_steps_table_and_no_landing_is_not_done() {
  reset_fakes
  local d out
  d=$(new_case pass-no-steps)
  make_repo_on_branch "$d/wt" fm/feat-nosteps
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/nosteps.meta" "window=fm:fm-nosteps" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_passed_no_steps fm/feat-nosteps)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"BLOCKED","state":"OPEN","url":"https://github.com/o/r/pull/1"}'
  out=$(run_crew_state "$d" nosteps)
  assert_not_contains "$out" "state: done" "a record with no ci evidence at all must not read as a pass"
  assert_contains "$out" "state: unknown" "no CI evidence cannot tell whether it passed"
  assert_not_contains "$out" "state: parked" "a terminated run is not a gate anyone can respond to"
  assert_contains "$out" "no ci step recorded" "the absent ci row is named honestly"
  assert_not_contains "$out" "ci SKIPPED" "an absent ci row is not a skipped one"
  pass "a terminal pass with no steps table and no landing is not done"
}

test_terminal_pass_with_a_pending_ci_step_and_no_landing_is_not_done() {
  reset_fakes
  local d out
  d=$(new_case pass-ci-pending)
  make_repo_on_branch "$d/wt" fm/feat-cipending
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cipending.meta" "window=fm:fm-cipending" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-cipending | sed 's/^    ci,completed,/    ci,pending,/')"
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"OPEN","url":"https://github.com/o/r/pull/1"}'
  out=$(run_crew_state "$d" cipending)
  assert_not_contains "$out" "state: done" "only a completed ci step earns the pass"
  assert_contains "$out" "state: unknown" "any other ci status word is absence of evidence"
  assert_not_contains "$out" "state: parked" "a terminated run is not a gate anyone can respond to"
  assert_contains "$out" "ci pending" "the ci step's own word is reported"
  pass "a terminal pass whose ci step never completed, with no landing, is not done"
}

# The runs-list path carries a status word, a sha and a PR url and nothing else,
# so it can never see a skipped ci step. It used to map `completed` straight to
# `done`, which bypassed the whole evidence gate: the incident run appears there
# as `completed` at the local head with its PR open and DIRTY.
test_coarse_completed_row_without_a_merge_is_not_done() {
  reset_fakes
  local d short out
  d=$(new_case coarse-completed-open)
  make_repo_on_branch "$d/wt" fm/feat-coarseopen
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/coarseopen.meta" "window=fm:fm-coarseopen" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-21 15:30
  completed  fm/feat-coarseopen ${short}  2026-08-21 15:05  https://github.com/o/r/pull/6
EOF
)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"DIRTY","state":"OPEN","url":"https://github.com/o/r/pull/6"}'
  out=$(run_crew_state "$d" coarseopen)
  assert_contains "$out" "source: run-step" "the branch's own coarse row is still attributed"
  assert_not_contains "$out" "state: done" "a coarse completed row cannot rule out a skipped ci step"
  assert_contains "$out" "state: unknown" "no CI evidence on this path cannot settle the run"
  assert_not_contains "$out" "state: parked" "a terminated coarse row is not a gate"
  assert_contains "$out" "runs-list path" "the detail names why the evidence is missing"
  assert_contains "$out" "PR still open" "the forge's own answer is reported"
  assert_not_contains "$out" "PR merged" "an open PR is never described as merged"
  pass "a coarse completed row without a merge is not done"
}

test_coarse_completed_row_is_done_once_the_forge_confirms_the_merge() {
  reset_fakes
  local d short out
  d=$(new_case coarse-completed-merged)
  make_repo_on_branch "$d/wt" fm/feat-coarsemerged
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/coarsemerged.meta" "window=fm:fm-coarsemerged" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-21 15:30
  completed  fm/feat-coarsemerged ${short}  2026-08-21 15:05  https://github.com/o/r/pull/7
EOF
)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"MERGED","url":"https://github.com/o/r/pull/7"}'
  out=$(run_crew_state "$d" coarsemerged)
  assert_contains "$out" "state: done" "a forge-confirmed merge is the one terminal fact this path has"
  assert_contains "$out" "PR merged" "the confirmed landing is reported"
  pass "a coarse completed row is done once the forge confirms the merge"
}

test_coarse_completed_row_with_an_unanswered_forge_is_not_done() {
  reset_fakes
  local d short out
  d=$(new_case coarse-completed-silent)
  make_repo_on_branch "$d/wt" fm/feat-coarsesilent
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/coarsesilent.meta" "window=fm:fm-coarsesilent" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-21 15:30
  completed  fm/feat-coarsesilent ${short}  2026-08-21 15:05  https://github.com/o/r/pull/8
EOF
)"
  FM_FAKE_GH_CALL_FAILS=1
  out=$(run_crew_state "$d" coarsesilent)
  assert_not_contains "$out" "state: done" "an unanswered forge cannot settle a coarse completed row"
  assert_contains "$out" "state: unknown" "unverified is not a landing"
  assert_contains "$out" "unverified" "the unanswered forge is reported honestly"
  pass "a coarse completed row with an unanswered forge is not done"
}

# Key scoping. `axi status` answers this reader with a `branch_sync:` block whose
# `local.head` is, by construction, this worktree's own HEAD. An unscoped scalar
# read of `head:` picks that up whenever the run object carries no head of its
# own, which makes the head binding report `equal` and admit ANY verdict -
# including a terminal one - for a run whose code identity was never checked.
test_branch_sync_head_does_not_satisfy_a_missing_run_head() {
  reset_fakes
  local d out
  d=$(new_case branch-sync-cross-read)
  make_repo_on_branch "$d/wt" fm/feat-crossread
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/crossread.meta" "window=fm:fm-crossread" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: current stage still in progress\n' > "$d/state/crossread.status"
  # A terminal-failed run with NO head of its own, plus a branch_sync block whose
  # local.head IS this checkout's HEAD - the shape the real CLI emits.
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-crossread | grep -v '^  head:')
$(branch_sync_block 01OTHERRUNIDENTIFIER0000000 "$FM_FAKE_RUN_HEAD" "$FM_FAKE_RUN_HEAD" fm/feat-crossread)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" crossread
  out=$(run_crew_state "$d" crossread)
  assert_not_contains "$out" "source: run-step" "a branch_sync head must not stand in for a missing run head"
  assert_not_contains "$out" "state: failed" "no terminal verdict from an unbound run"
  assert_contains "$out" "source: status-log" "the run is unattributed, so current-state sources answer"
  assert_contains "$out" "state: working" "the status log remains current"
  pass "a branch_sync head does not satisfy a missing run head"
}

# `outcome: checks-passed` is CI evidence in its own right, unlike `outcome:
# passed`, which says only that the pipeline completed. Requiring a corroborating
# `ci,completed` row would silently withhold the ready-for-review signal on the
# fleet where merge is the captain's call and the ci step stays `running`.
test_checks_passed_outcome_is_done_without_a_completed_ci_row() {
  reset_fakes
  local d out
  d=$(new_case checks-passed)
  make_repo_on_branch "$d/wt" fm/feat-checksgreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/checksgreen.meta" "window=fm:fm-checksgreen" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-checksgreen)"
  forge_answers_open
  out=$(run_crew_state "$d" checksgreen)
  assert_contains "$out" "state: done" "checks-passed is its own CI evidence"
  assert_contains "$out" "checks green: PR ready for review" "the captain gets the ready-for-review signal"
  assert_contains "$out" "source: run-step" "the run itself is the source"
  assert_not_contains "$out" "no CI evidence" "the run's own outcome names the checks as passed"
  pass "a checks-passed outcome is done without a completed ci row"
}

# A PR URL this reader has no forge client for is a PERMANENT condition, and it
# used to be reported with the same word as a timed-out or unauthenticated gh.
# On the coarse path that conflation is load-bearing, because a completed row
# reads unknown unless the forge confirms a landing: without the distinction,
# every finished run on a non-GitHub project reads unknown with no way to tell it
# from a transient failure that will clear on the next heartbeat.
test_gitlab_merge_request_is_named_not_reported_as_a_forge_failure() {
  reset_fakes
  local d short out
  d=$(new_case coarse-gitlab)
  make_repo_on_branch "$d/wt" fm/feat-gitlab
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/gitlab.meta" "window=fm:fm-gitlab" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-21 15:30
  completed  fm/feat-gitlab ${short}  2026-08-21 15:05  https://gitlab.com/grp/sub/proj/-/merge_requests/12
EOF
)"
  # gh would answer if it were asked; the point is that it never is.
  FM_FAKE_GH_PR='{"mergeStateStatus":"CLEAN","state":"MERGED","url":"https://gitlab.com/grp/sub/proj/-/merge_requests/12"}'
  out=$(run_crew_state "$d" gitlab)
  assert_not_contains "$out" "state: done" "nothing proves a run landed without CI evidence or a forge answer"
  assert_contains "$out" "state: unknown" "an unqueryable provider leaves the run unsettled"
  assert_contains "$out" "no forge client for gitlab" "the permanent condition names the provider"
  assert_not_contains "$out" "PR state unverified" "a permanent condition must not read as a transient forge failure"
  assert_not_contains "$out" "PR merged" "a merge claim is never emitted for a PR that was never read"
  pass "a gitlab merge request is named, not reported as a forge failure"
}

test_unrecognized_pr_url_is_named_not_reported_as_a_forge_failure() {
  reset_fakes
  local d short out
  d=$(new_case coarse-badurl)
  make_repo_on_branch "$d/wt" fm/feat-badurl
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/badurl.meta" "window=fm:fm-badurl" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  # A host that merely ends in github.com is a different host; the URL identity
  # owner refuses it, and so must this reader.
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-21 15:30
  completed  fm/feat-badurl ${short}  2026-08-21 15:05  https://evil-github.com/o/r/pull/6
EOF
)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"CLEAN","state":"MERGED","url":"https://evil-github.com/o/r/pull/6"}'
  out=$(run_crew_state "$d" badurl)
  assert_not_contains "$out" "state: done" "an unrecognized PR url cannot confirm a landing"
  assert_contains "$out" "PR url not recognized" "the unrecognized url is named for what it is"
  assert_not_contains "$out" "PR merged" "a look-alike host must never reach the real forge"
  pass "an unrecognized PR url is named, not reported as a forge failure"
}

# FM_CREW_STATE_NO_FORGE is documented as truthy, which in this repo means
# anything other than empty or 0/false/no/off.
test_no_forge_knob_honors_a_truthy_word() {
  reset_fakes
  local d out
  d=$(new_case no-forge-truthy)
  make_repo_on_branch "$d/wt" fm/feat-noforge
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/noforge.meta" "window=fm:fm-noforge" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_ci_completed fm/feat-noforge)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"MERGED","url":"https://github.com/o/r/pull/9"}'
  out=$(FM_CREW_STATE_NO_FORGE=true run_crew_state "$d" noforge)
  assert_contains "$out" "unverified" "a truthy knob skips the forge read"
  assert_not_contains "$out" "PR merged" "a skipped forge read never renders as a landing"
  out=$(FM_CREW_STATE_NO_FORGE=0 run_crew_state "$d" noforge)
  assert_contains "$out" "PR merged" "0 is not truthy, so the forge is still read"
  pass "the no-forge knob honors a truthy word"
}

# Ownership proof. Geometry cannot tell an unfetched pipeline head from a pruned
# rewrite, so a terminal verdict is withheld there - but the run record itself
# settles it, because `axi status` read from the task worktree reports which run
# owns this branch and what head it advanced to. With that proof the terminal
# verdict is admissible; the three equalities below each keep a different way of
# being wrong out.
test_terminal_run_at_proven_pipeline_head_is_attributed() {
  reset_fakes
  local d out
  d=$(new_case proven-ownership)
  make_pipeline_ahead_topology "$d" fm/feat-proven
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/proven.meta" "window=fm:fm-proven" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: fix round under way\n' > "$d/state/proven.status"
  FM_FAKE_AXI_STATUS="$(run_failed_at_local_head fm/feat-proven "$PIPE_HEAD")
$(branch_sync_block 01M0EFHKF1A3CJX4KK58HWJ7D2 "$PIPE_HEAD" "$LOCAL_HEAD" fm/feat-proven)"
  out=$(run_crew_state "$d" proven)
  assert_contains "$out" "state: failed" "a proven pipeline head carries its run's terminal verdict"
  assert_contains "$out" "source: run-step" "the run itself is the source once ownership is proven"
  pass "a terminal run at a proven pipeline head is attributed"
}

test_branch_sync_for_another_run_does_not_prove_ownership() {
  reset_fakes
  local d out
  d=$(new_case proven-other-run)
  make_pipeline_ahead_topology "$d" fm/feat-otherrun
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/otherrun.meta" "window=fm:fm-otherrun" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'resolved: firstmate answered the review question\n' > "$d/state/otherrun.status"
  # Same heads, but the push binding belongs to a DIFFERENT run.
  FM_FAKE_AXI_STATUS="$(run_failed_at_local_head fm/feat-otherrun "$PIPE_HEAD")
$(branch_sync_block 01M0SOMEOTHERRUNIDENTIFIER "$PIPE_HEAD" "$LOCAL_HEAD" fm/feat-otherrun)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" otherrun
  out=$(run_crew_state "$d" otherrun)
  assert_not_contains "$out" "source: run-step" "another run's binding cannot vouch for this run"
  assert_not_contains "$out" "state: failed" "no terminal verdict from an unproven head"
  assert_contains "$out" "state: unknown" "the evidence still does not settle it"
  pass "a branch_sync binding for another run does not prove ownership"
}

test_branch_sync_for_another_head_does_not_prove_ownership() {
  reset_fakes
  local d other out
  d=$(new_case proven-other-head)
  make_pipeline_ahead_topology "$d" fm/feat-otherhead
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/otherhead.meta" "window=fm:fm-otherhead" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'resolved: firstmate answered the review question\n' > "$d/state/otherhead.status"
  # Right run, right checkout, but the branch has been advanced to some OTHER
  # head, so this run's head is not the one the pipeline currently owns.
  other=1111111111111111111111111111111111111111
  FM_FAKE_AXI_STATUS="$(run_failed_at_local_head fm/feat-otherhead "$PIPE_HEAD")
$(branch_sync_block 01M0EFHKF1A3CJX4KK58HWJ7D2 "$other" "$LOCAL_HEAD" fm/feat-otherhead)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" otherhead
  out=$(run_crew_state "$d" otherhead)
  assert_not_contains "$out" "source: run-step" "a binding for another head cannot vouch for this run head"
  assert_contains "$out" "state: unknown" "the evidence still does not settle it"
  pass "a branch_sync binding for another head does not prove ownership"
}

test_branch_sync_for_another_checkout_does_not_prove_ownership() {
  reset_fakes
  local d out
  d=$(new_case proven-other-checkout)
  make_pipeline_ahead_topology "$d" fm/feat-othertree
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/othertree.meta" "window=fm:fm-othertree" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'resolved: firstmate answered the review question\n' > "$d/state/othertree.status"
  # Right run, right pipeline head, but the block describes a different checkout.
  FM_FAKE_AXI_STATUS="$(run_failed_at_local_head fm/feat-othertree "$PIPE_HEAD")
$(branch_sync_block 01M0EFHKF1A3CJX4KK58HWJ7D2 "$PIPE_HEAD" 0000000000000000000000000000000000000000 fm/feat-othertree)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" othertree
  out=$(run_crew_state "$d" othertree)
  assert_not_contains "$out" "source: run-step" "a binding for another checkout cannot vouch for this one"
  assert_contains "$out" "state: unknown" "the evidence still does not settle it"
  pass "a branch_sync binding for another checkout does not prove ownership"
}

# The coarse row's PR url is load-bearing on that path - a `completed` row reads
# done only when the forge confirms a landing - and its column index is not
# evidence: the same listing has been described here with the date as one field
# and as two, so a fixed index is one layout change away from handing a timestamp
# to the URL owner and leaving every completed row unknown forever with "PR url
# not recognized". Both rows below put the url where a sixth-field read would
# miss it.
test_coarse_pr_url_is_found_by_shape_not_by_column() {
  reset_fakes
  local d short out
  d=$(new_case coarse-url-layout)
  make_repo_on_branch "$d/wt" fm/feat-urllayout
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/urllayout.meta" "window=fm:fm-urllayout" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"MERGED","url":"https://github.com/o/r/pull/11"}'
  # Date and time as ONE token: the url is the row's fifth field.
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-22T15:30:00Z
  completed  fm/feat-urllayout ${short}  2026-08-22T15:05:00Z  https://github.com/o/r/pull/11
EOF
)"
  out=$(run_crew_state "$d" urllayout)
  assert_contains "$out" "state: done" "the row's url is read wherever the layout puts it"
  assert_contains "$out" "PR merged" "the forge-confirmed landing is still reported"
  assert_not_contains "$out" "not recognized" "a timestamp is never offered to the url owner as a PR url"
  # One extra column ahead of the url: the seventh field this time, so no single
  # index fits both layouts.
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-22 15:30  -
  completed  fm/feat-urllayout ${short}  2026-08-22 15:05  4m12s  https://github.com/o/r/pull/11
EOF
)"
  out=$(run_crew_state "$d" urllayout)
  assert_contains "$out" "state: done" "an extra column ahead of the url does not hide it"
  assert_contains "$out" "PR merged" "the forge answer still settles the row"
  assert_not_contains "$out" "not recognized" "an unrelated column is never read as the PR url"
  pass "the coarse row's PR url is found by shape, not by column"
}

# A table emitted after `active_steps` must not be read as more active steps.
# The consequence is a detail line rather than a verdict, but the detail is what
# a supervisor reads as proof of life, so an idle run must not borrow one from
# the steps table.
test_a_table_after_active_steps_is_not_read_as_an_active_step() {
  reset_fakes
  local d out
  d=$(new_case active-steps-order)
  make_repo_on_branch "$d/wt" fm/feat-steporder
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/steporder.meta" "window=fm:fm-steporder" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_active_steps_before_steps fm/feat-steporder "$FM_FAKE_RUN_HEAD")"
  out=$(run_crew_state "$d" steporder)
  assert_contains "$out" "source: run-step" "the run is this branch's own"
  assert_contains "$out" "state: working" "a running run is still working"
  assert_not_contains "$out" "test running" "a steps row is never reported as the live activity"
  assert_not_contains "$out" "active 0" "a steps duration column is not an active_for field"
  assert_contains "$out" "validating (running)" "with no active step the run's own status word is the detail"
  pass "a table after active_steps is not read as an active step"
}

# The branch_sync block describes the branch's PUSH BINDING, which routinely
# belongs to a different run than the one `axi status` answers with. Its
# `pipeline.status` sits at the same indent as the run object's own `status:`, so
# an unscoped gate read takes a binding for another run as this run's gate: the
# superseded/live pair this whole change exists for, where the older run parked at
# a gate before its daemon died while the live run is plainly running. A
# demonstrably working pipeline must not be reported parked at a gate it is not at.
test_branch_sync_gate_status_does_not_park_a_running_run() {
  reset_fakes
  local d out
  d=$(new_case branch-sync-gate)
  make_repo_on_branch "$d/wt" fm/feat-bsgate
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/bsgate.meta" "window=fm:fm-bsgate" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-bsgate)
$(branch_sync_block 01M0SOMEOTHERRUNIDENTIFIER "$FM_FAKE_RUN_HEAD" "$FM_FAKE_RUN_HEAD" fm/feat-bsgate awaiting_approval)"
  out=$(run_crew_state "$d" bsgate)
  assert_not_contains "$out" "state: parked" "another run's push binding is not this run's gate"
  assert_not_contains "$out" "parked at" "a branch_sync status word never names a gate"
  assert_contains "$out" "state: working" "the run's own object says it is running"
  assert_contains "$out" "source: run-step" "the run itself remains the source"
  pass "a branch_sync pipeline status does not park a running run"
}

# The harm the overloaded word did. A crew appends `needs-decision:`, the captain
# answers it, and the run then TERMINATES at `outcome: passed` with `ci,skipped`
# without the crew appending anything further, so the log's last line is still
# `needs-decision:` - the exact stale-log condition this whole script exists for.
# While that verdict shared the word `parked` with a live gate, the reconciliation
# below treated the answered decision as still live: the superseded annotation was
# withheld, and a consumer that clears an open decision once the run moves off
# parked stopped clearing it, so a resolved decision could resurface as a captain
# demand. The state word is pinned in BOTH directions here so it cannot drift back.
test_terminal_pass_without_ci_evidence_supersedes_a_stale_gate_log() {
  reset_fakes
  local d out
  d=$(new_case terminal-pass-stale-gate)
  make_repo_on_branch "$d/wt" fm/feat-staleg
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/staleg.meta" "window=fm:fm-staleg" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: review gate, finding r2 needs a ruling\n' > "$d/state/staleg.status"
  FM_FAKE_AXI_STATUS="$(run_passed_ci_skipped fm/feat-staleg)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"DIRTY","state":"OPEN","url":"https://github.com/o/r/pull/6"}'
  out=$(run_crew_state "$d" staleg)
  assert_contains "$out" "status-log superseded" "the answered gate line is reconciled as stale"
  assert_not_contains "$out" "state: parked" "the answered gate is gone, so nothing is parked"
  assert_contains "$out" "state: unknown" "a terminated run with no CI evidence is unknown"
  assert_contains "$out" "ci SKIPPED" "the detail still names what withheld the pass"
  pass "a terminal pass without CI evidence supersedes a stale gate log"
}

# Column padding, in the table HEADER as well as the rows. The recorded tables are
# unpadded, but the ci status column now decides done versus unknown for every
# full-path terminal pass, and the active_steps status column decides whether a
# live run is recognised at all. A no-mistakes version that emits
# `ci, completed,0,0` would otherwise demote every terminal pass fleet-wide and
# silently stop the liveness override, both in the conservative direction and both
# invisible. Both readers key their columns by NAME off the header, so a padded
# header is the same outage by the other side of that lookup: ` status` names no
# column, and every row then reports an empty status word.
#
# The PR here is deliberately OPEN. This case paired the padded row with a MERGED
# forge answer once, and a LATER ruling - a confirmed merge settles done whatever
# the ci step says - silently made the guard unfalsifiable: the merge arm carried
# the verdict, so dropping the trim changed nothing the assertions could see. With
# an open PR the padded ci read is the ONLY thing that can reach done, so the
# guard is load-bearing again.
test_padded_step_columns_do_not_change_the_verdict() {
  reset_fakes
  local d run_head out
  d=$(new_case padded-columns)
  make_repo_on_branch "$d/wt" fm/feat-padded
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/padded.meta" "window=fm:fm-padded" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-padded \
    | sed -e 's/^    ci,completed,0,0$/    ci , completed , 0, 0/' \
      -e 's/^  steps\[\([0-9]*\)\]{step,status,findings,duration_ms}:$/  steps[\1]{step, status , findings,duration_ms }:/')"
  FM_FAKE_GH_PR='{"mergeStateStatus":"BLOCKED","state":"OPEN","url":"https://github.com/o/r/pull/1"}'
  out=$(run_crew_state "$d" padded)
  assert_contains "$out" "state: done" "a padded ci,completed row is still CI evidence"
  assert_contains "$out" "run passed" "the lead phrase reports the padded ci row as read"
  assert_contains "$out" "PR open, not merged" "the open PR is reported, and is not what settled this"
  assert_not_contains "$out" "no CI evidence" "padding must not read as a missing ci row"

  d=$(new_case padded-active-step)
  make_repo_on_branch "$d/wt" fm/feat-paddedlive
  run_head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/paddedlive.meta" "window=fm:fm-paddedlive" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_live_active_step fm/feat-paddedlive "$run_head" |
    sed -e 's/^    test,running,3m38s,/    test , running , 3m38s , /' \
      -e 's/^  active_steps\[1\]{step,status,active_for,/  active_steps[1]{step, status , active_for ,/')"
  out=$(run_crew_state "$d" paddedlive)
  assert_contains "$out" "state: working" "a padded active_steps row is still an executing step"
  assert_contains "$out" "test running" "the padded step and status words are reported unpadded"
  assert_contains "$out" "active 3m38s" "so is the padded active_for column"
  assert_contains "$out" "last activity 3m11s ago" "and the padded header still located every column"

  # The third reader of the same column: the ci-step word that licenses the
  # ci-log-green override. A padded `ci , running` row used to match nothing here,
  # so the override never fired and a crew whose checks were already green read as
  # still validating - the conservative direction, and invisible.
  reset_fakes
  d=$(new_case padded-ci-monitor)
  make_repo_on_branch "$d/wt" fm/feat-paddedci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/paddedci.meta" "window=fm:fm-paddedci" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-paddedci \
    | sed -e 's/^    ci,running,0,0$/    ci , running , 0, 0/' \
      -e 's/^  steps\[\([0-9]*\)\]{step,status,findings,duration_ms}:$/  steps[\1]{step, status , findings,duration_ms }:/')"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  forge_answers_open
  out=$(run_crew_state "$d" paddedci)
  assert_contains "$out" "checks green" "a padded ci,running row is still an executing ci step"
  assert_not_contains "$out" "validating (running)" "so the crew is not reported as still validating"
  pass "padded step columns do not change the verdict"
}

# The ci word the terminal ranking asks about comes from the step HISTORY, not
# from whichever TOON table the record happens to emit first. `active_steps` rows
# begin with a step name too, so a reader that matched any `ci,<word>,` row read
# the active table on a record that emitted it first - and the ci word is what
# acceptance criterion 1 rests on when it rules a skipped ci step never reads as
# done. Here the two tables disagree on purpose: history says `completed`, the
# active row says `running`, and only the history may settle the pass.
test_the_ci_word_comes_from_the_steps_table_whatever_its_position() {
  reset_fakes
  local d out
  d=$(new_case ci-table-anchor)
  make_repo_on_branch "$d/wt" fm/feat-cianchor
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cianchor.meta" "window=fm:fm-cianchor" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_passed_active_steps_first fm/feat-cianchor)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"BLOCKED","state":"OPEN","url":"https://github.com/o/r/pull/1"}'
  out=$(run_crew_state "$d" cianchor)
  assert_contains "$out" "state: done" "the steps table's ci,completed is the CI evidence, whatever table came first"
  assert_not_contains "$out" "no CI evidence" "an active_steps ci row must not stand in for the step history"
  pass "the ci word comes from the steps table whatever its position"
}

# ONE ranking, both paths. A forge-confirmed merge is stronger evidence than ci
# completion for the question actually asked - the merge proves the work LANDED,
# ci completion only proves that checks ran - so it settles done whatever the ci
# step says. This is the recorded ci-SKIPPED incident run with one thing changed:
# its PR is merged instead of open and DIRTY.
test_forge_confirmed_merge_settles_a_ci_skipped_run() {
  reset_fakes
  local d out
  d=$(new_case merge-settles-skipped)
  make_repo_on_branch "$d/wt" fm/feat-mergeskip
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mergeskip.meta" "window=fm:fm-mergeskip" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_passed_ci_skipped fm/feat-mergeskip)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"MERGED","url":"https://github.com/o/r/pull/6"}'
  out=$(run_crew_state "$d" mergeskip)
  assert_contains "$out" "state: done" "a confirmed landing settles the run whatever ci says"
  assert_contains "$out" "PR merged" "the confirmed landing is what settled it"
  assert_not_contains "$out" "cannot tell" "no line may claim a merge and doubt the pass at once"
  assert_not_contains "$out" "no CI evidence" "the landing, not the ci gap, is the verdict here"
  pass "a forge-confirmed merge settles a ci-skipped run"
}

# The other half of that ranking, and the opposite outcome. A closed-unmerged PR
# is the OPPOSITE of a landing: the work will never land. It used to be ranked
# with the merge as one "landing" and read `done`, with the truth surviving only
# in the detail line - and bin/fm-inactive-reconcile.sh builds its captain
# presentation from the state word and the PR alone, so that detail is dropped
# exactly at the captain-facing boundary and abandoned work was presented as a
# success. Asserted in both directions, because the word is the whole point.
test_forge_confirmed_close_is_failed_not_done() {
  reset_fakes
  local d out
  d=$(new_case close-not-a-landing)
  make_repo_on_branch "$d/wt" fm/feat-closed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/closed.meta" "window=fm:fm-closed" "worktree=$d/wt" "kind=ship" "harness=claude"
  # A genuine pass with its ci step completed, so nothing but the close can be
  # what settles this away from done.
  FM_FAKE_AXI_STATUS="$(run_passed_ci_completed fm/feat-closed)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"CLOSED","url":"https://github.com/o/r/pull/9"}'
  out=$(run_crew_state "$d" closed)
  assert_contains "$out" "state: failed" "an abandoned PR is a terminal non-landing"
  assert_not_contains "$out" "state: done" "closed is not merged, and the state word must say so alone"
  assert_contains "$out" "PR closed without merging" "the detail names the close for what it is"
  assert_not_contains "$out" "PR merged" "a close is never rendered as a merge"
  pass "a forge-confirmed close is failed, not done"
}

# A host with no `gh` cannot query GitHub, ever, and that is as permanent as an
# unsupported provider - it was reported with the TRANSIENT word, so on the coarse
# path, where a completed row reads done only on a forge-confirmed merge, every
# finished run on a gh-less host read `PR state unverified` forever with no way to
# tell it from a call that would succeed on the next heartbeat.
test_absent_forge_client_is_structural_not_transient() {
  reset_fakes
  local d no_gh_path out
  d=$(new_case no-forge-client)
  make_repo_on_branch "$d/wt" fm/feat-noclient
  make_fakebin "$d" >/dev/null
  rm -f "$d/fakebin/gh"
  no_gh_path=$(make_path_with_no_gh_binary "$d")
  ( PATH="$no_gh_path"; hash -r; command -v gh >/dev/null 2>&1 ) &&
    fail "fixture broken: gh is still reachable on the stripped PATH"
  fm_write_meta "$d/state/noclient.meta" "window=fm:fm-noclient" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_passed_ci_skipped fm/feat-noclient)"
  out=$(PATH="$d/fakebin:$no_gh_path" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" noclient)
  assert_contains "$out" "state: unknown" "with no client and no ci evidence nothing settles the run"
  assert_contains "$out" "no forge client for github" "the absent client is named as the permanent condition it is"
  assert_not_contains "$out" "PR state unverified" "a permanent condition must not read as a transient forge failure"
  assert_not_contains "$out" "PR merged" "a client that never ran can confirm no landing"
  pass "an absent forge client is structural, not a transient failure"
}

# The same false success in a SIBLING path, and worse in one respect. `outcome:
# checks-passed` used to short-circuit before the forge was ever asked, so an
# abandoned PR read `done - checks green: PR ready for review`, which does not
# merely overstate the work - it actively invites the captain to go and review
# something already thrown away. bin/fm-inactive-reconcile.sh drops the detail
# and presents the state word and the PR alone, so that is what the captain sees.
#
# Green checks and the PR's fate are two DIFFERENT questions. checks-passed still
# answers the first on its own, with no ci,completed row (pinned separately by
# test_checks_passed_outcome_is_done_without_a_completed_ci_row); it never
# answered the second.
test_forge_confirmed_close_defeats_a_checks_passed_run() {
  reset_fakes
  local d out
  d=$(new_case checks-passed-closed)
  make_repo_on_branch "$d/wt" fm/feat-cpclosed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cpclosed.meta" "window=fm:fm-cpclosed" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-cpclosed)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"CLOSED","url":"https://github.com/o/r/pull/5"}'
  out=$(run_crew_state "$d" cpclosed)
  assert_contains "$out" "state: failed" "an abandoned PR is not a ready-for-review success"
  assert_not_contains "$out" "state: done" "green checks cannot settle where the PR ended up"
  assert_contains "$out" "PR closed without merging" "the detail names the close for what it is"
  assert_contains "$out" "checks green: PR closed" "the lead claims only the green checks"
  assert_not_contains "$out" "run passed" "this run reached no outcome and passed nothing"
  assert_not_contains "$out" "ready for review" "nothing here should send the captain to review it"
  pass "a forge-confirmed close defeats a checks-passed run"
}

# The ready-for-review signal is what that arm exists to produce, so every answer
# but a confirmed close leaves it intact, and a confirmed merge names the merge.
test_checks_passed_keeps_ready_for_review_unless_the_pr_was_closed() {
  reset_fakes
  local d out
  d=$(new_case checks-passed-open)
  make_repo_on_branch "$d/wt" fm/feat-cpopen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cpopen.meta" "window=fm:fm-cpopen" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-cpopen)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"CLEAN","state":"OPEN","url":"https://github.com/o/r/pull/5"}'
  out=$(run_crew_state "$d" cpopen)
  assert_contains "$out" "state: done" "an open PR with green checks is still ready for review"
  assert_contains "$out" "checks green: PR ready for review" "the signal the captain waits for survives"
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"MERGED","url":"https://github.com/o/r/pull/5"}'
  out=$(run_crew_state "$d" cpopen)
  assert_contains "$out" "state: done" "a merged PR with green checks is done"
  assert_contains "$out" "PR merged" "the confirmed merge is named"
  pass "checks-passed keeps ready-for-review unless the PR was closed"
}

# The ci-log-green override reaches `done` by a different route - the run is still
# monitoring and its ci-step log tail reads green - and lands at the same
# captain-facing boundary, so it answers to the same owner.
test_forge_confirmed_close_defeats_a_green_ci_log() {
  reset_fakes
  local d out
  d=$(new_case ci-green-closed)
  make_repo_on_branch "$d/wt" fm/feat-cigreenclosed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cigreenclosed.meta" "window=fm:fm-cigreenclosed" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cigreenclosed)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"CLOSED","url":"https://github.com/o/r/pull/2"}'
  out=$(run_crew_state "$d" cigreenclosed)
  assert_contains "$out" "state: failed" "a closed PR ends the monitor as an abandonment"
  assert_not_contains "$out" "state: done" "a green ci log cannot settle where the PR ended up"
  assert_contains "$out" "PR closed without merging" "the detail names the close"
  assert_contains "$out" "checks green: PR closed" "the lead claims only the green checks"
  assert_not_contains "$out" "run passed" "this run is still running and passed nothing"
  pass "a forge-confirmed close defeats a green ci log"
}

# The third route to `done` on this path: the crew's own status log reports its
# checks green while the run still monitors, and the verdict is emitted with
# `source: status-log`. Different source, same captain-facing boundary, same
# owner for the question the log cannot answer.
test_forge_confirmed_close_defeats_a_ci_ready_status_log() {
  reset_fakes
  local d out
  d=$(new_case ci-ready-closed)
  make_repo_on_branch "$d/wt" fm/feat-cireadyclosed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cireadyclosed.meta" "window=fm:fm-cireadyclosed" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/cireadyclosed.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cireadyclosed)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"CLOSED","url":"https://github.com/o/r/pull/2"}'
  out=$(run_crew_state "$d" cireadyclosed)
  assert_contains "$out" "state: failed" "a closed PR is not a ready-for-review success"
  assert_not_contains "$out" "state: done" "the crew's own log cannot settle where the PR ended up"
  assert_contains "$out" "PR closed without merging" "the detail names the close"
  assert_contains "$out" "checks green: PR closed" "the lead claims only the green checks"
  assert_not_contains "$out" "run passed" "this run is still running and passed nothing"
  pass "a forge-confirmed close defeats a ci-ready status log"
}

# The precondition for a tight forge bound. A TRANSIENT non-answer - the read
# timed out, gh was unauthenticated, or a budgeted caller skipped it - cannot tell
# an open PR from a closed one, so no path may resolve it to `done`. Shortening
# the wait must degrade to honesty, never to the false success this whole change
# removes, and both routes to `done` are pinned here because both are reachable
# from the snapshot that now waits less.
test_a_transient_forge_non_answer_never_reads_done() {
  reset_fakes
  local d out
  d=$(new_case transient-non-answer)
  make_repo_on_branch "$d/wt" fm/feat-transient
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/transient.meta" "window=fm:fm-transient" "worktree=$d/wt" "kind=ship"
  # A genuine pass carrying its OWN ci,completed evidence: only the unanswered
  # forge stands between it and done.
  FM_FAKE_AXI_STATUS="$(run_passed_ci_completed fm/feat-transient)"
  FM_FAKE_GH_CALL_FAILS=1
  out=$(run_crew_state "$d" transient)
  assert_not_contains "$out" "state: done" "an unread merge state cannot rule out a close"
  assert_contains "$out" "state: unknown" "the honest word while the forge is unread"
  assert_contains "$out" "cannot rule out a close" "the detail says which half is missing"
  assert_contains "$out" "run passed" "the ci evidence it does have is still reported"
  pass "an unconfirmed forge answer never reads done on a terminated run"
}

# WITHHOLDING A TERMINAL CLAIM AND REPORTING LIVENESS ARE DIFFERENT STATEMENTS.
# This is the concrete sequence a directive overshot into: a crew in merge
# monitoring with green checks, `gh` unauthenticated or the bound hit, the forge
# answering nothing. "I cannot confirm this landed" was allowed to become "I know
# nothing about this crew", which is reproduced failure (3) of this whole change
# arriving by a new route, and a regression of accepted criterion 4.
#
# All three properties are asserted, because the useful ones are what must NOT be
# there: the crew reads working, never done, and never unknown.
test_an_unconfirmed_answer_keeps_a_live_crew_working() {
  reset_fakes
  local d run_head out
  d=$(new_case unconfirmed-live)
  make_repo_on_branch "$d/wt" fm/feat-unconfirmed
  run_head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unconf.meta" "window=fm:fm-unconf" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_GH_CALL_FAILS=1
  # The checks-passed route: the run is monitoring, its ci step still running.
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-unconfirmed)"
  out=$(run_crew_state "$d" unconf)
  assert_contains "$out" "state: working" "a crew still monitoring its PR is working"
  assert_not_contains "$out" "state: done" "an unread merge state cannot rule out a close"
  assert_not_contains "$out" "state: unknown" "the forge said nothing about the CREW"
  assert_contains "$out" "PR state unverified" "the detail names what is missing"
  assert_contains "$out" "checks green: PR ready for review" "and keeps what is known"
  # The ci-log-green route, on a run with a genuinely executing step.
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-unconfirmed)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  out=$(run_crew_state "$d" unconf)
  assert_contains "$out" "state: working" "so is one whose ci log went green"
  assert_not_contains "$out" "state: done" "the same unread merge state, the same refusal"
  assert_not_contains "$out" "state: unknown" "liveness is not erased by an unread forge"
  pass "an unconfirmed forge answer keeps a live crew working"
}

# The forge-read invariant admits no exemption for the SOURCE of a done claim.
# A worker's own `done:` line is a self-report - weaker evidence than a run
# record, not stronger - and bin/fm-inactive-reconcile.sh matches the WORD
# regardless of source, so an abandoned PR reached the captain as a success by
# exactly this route while the run-backed routes were being closed one by one.
test_a_no_run_status_log_done_asks_the_forge() {
  reset_fakes
  local d out
  d=$(new_case log-done-forge)
  make_repo_on_branch "$d/wt" fm/feat-logdone
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/logdone.meta" "window=fm:fm-logdone" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'done: PR https://github.com/o/r/pull/8 ready for review\n' > "$d/state/logdone.status"
  # No run anywhere for this branch, so the status log is the only source.
  FM_FAKE_AXI_STATUS="$(run_running fm/some-other)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" logdone
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"CLOSED","url":"https://github.com/o/r/pull/8"}'
  out=$(run_crew_state "$d" logdone)
  assert_contains "$out" "state: failed" "an abandoned PR is not a success whoever reported it"
  assert_not_contains "$out" "state: done" "the worker's own claim does not settle where the PR ended up"
  assert_contains "$out" "PR closed without merging" "the detail names the close"
  assert_contains "$out" "worker reported done" "and names the self-report it overrode"
  # An unconfirmed answer withholds done too, and here there is no run and no
  # liveness to fall back on, so unknown is all that is left.
  FM_FAKE_GH_PR=""
  FM_FAKE_GH_CALL_FAILS=1
  out=$(run_crew_state "$d" logdone)
  assert_contains "$out" "state: unknown" "with no run and no answer, nothing is settled"
  assert_not_contains "$out" "state: done" "an unread merge state cannot rule out a close here either"
  pass "a no-run status-log done asks the forge"
}

# The url the reader must not miss. A coarse runs-list row never carries a PR, and
# the run record may not either, but the worker's own status log names it - and
# bin/fm-inactive-reconcile.sh digs that same url out to show the captain beside
# the state word. Looking only at the run record meant answering "no PR to ask
# about" while holding the url in hand.
test_a_pr_url_only_in_the_status_log_is_still_queried() {
  reset_fakes
  local d short out
  d=$(new_case log-only-pr)
  make_repo_on_branch "$d/wt" fm/feat-logpr
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/logpr.meta" "window=fm:fm-logpr" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'done: PR https://github.com/o/r/pull/9 checks green\n' > "$d/state/logpr.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 15:30
  running    fm/feat-logpr ${short}  2026-08-23 15:05
EOF
)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"CLOSED","url":"https://github.com/o/r/pull/9"}'
  out=$(run_crew_state "$d" logpr)
  assert_contains "$out" "state: failed" "the url in the log is queried, and it says closed"
  assert_not_contains "$out" "state: done" "a row with no PR column is not a task with no PR"
  assert_contains "$out" "PR closed without merging" "the detail names the close"
  pass "a PR url only in the status log is still queried"
}

# The other side of that lookup, and why `no-pr` may still read done. A scout has
# no PR anywhere - not in a run record, not in its meta, not in its log - so its
# `done:` is a statement that the work finished, not a landing claim, and there is
# nothing the forge could have been asked.
test_a_task_with_no_pr_anywhere_still_reads_done() {
  reset_fakes
  local d out
  d=$(new_case no-pr-anywhere)
  make_repo_on_branch "$d/wt" fm/feat-nopr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/nopr.meta" "window=fm:fm-nopr" "worktree=$d/wt" "kind=scout" "harness=claude"
  printf 'done: report ready in data/nopr/report.md\n' > "$d/state/nopr.status"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" nopr
  FM_FAKE_GH_CALL_FAILS=1
  out=$(run_crew_state "$d" nopr)
  assert_contains "$out" "state: done" "a task with no PR has no landing to confirm"
  assert_contains "$out" "source: status-log" "the log is the only source a scout has"
  assert_not_contains "$out" "state: unknown" "an absent PR is not an unread one"
  pass "a task with no PR anywhere still reads done"
}

# The other half of that rule, and the reason it is a SPLIT rather than a blanket
# refusal. A STRUCTURAL non-answer - no forge client on this host, or a PR url
# this reader cannot recognise - is never cleared by a later read, so refusing
# `done` would refuse it forever: every GitLab project and every host without
# `gh` would lose the ready-for-review signal permanently. That is a worse failure
# than the one the transient rule guards against, so the run's own evidence still
# settles done there.
test_a_structural_forge_non_answer_still_reads_done() {
  reset_fakes
  local d no_gh_path out
  d=$(new_case structural-non-answer)
  make_repo_on_branch "$d/wt" fm/feat-structural
  make_fakebin "$d" >/dev/null
  rm -f "$d/fakebin/gh"
  no_gh_path=$(make_path_with_no_gh_binary "$d")
  ( PATH="$no_gh_path"; hash -r; command -v gh >/dev/null 2>&1 ) &&
    fail "fixture broken: gh is still reachable on the stripped PATH"
  fm_write_meta "$d/state/structural.meta" "window=fm:fm-structural" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_ci_completed fm/feat-structural)"
  out=$(PATH="$d/fakebin:$no_gh_path" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" structural)
  assert_contains "$out" "state: done" "the run's own ci evidence still settles it"
  assert_contains "$out" "no forge client for github" "the permanent condition is named"
  assert_not_contains "$out" "cannot rule out a close" "no later read would ever clear this one"
  pass "a structural forge non-answer still reads done"
}

# The property that actually failed: the full `axi status` path and the coarse
# runs-list path ranked this evidence separately, so ONE world state read `done`
# or `unknown` depending only on whether an unrelated crew happened to have a run
# in flight - which is what decides who `axi status` answers for. Same run, same
# PR, same forge answer, asserted for BYTE equality across both paths rather than
# each path in isolation.
#
# This covers the forge-confirmed merge, not agreement in general: where the ci
# step alone would settle the run, the coarse path cannot see that step at all and
# honestly answers unknown, an accepted residual recorded at
# fm_crew_terminal_verdict in bin/fm-crew-run-verdict-lib.sh.
test_both_paths_agree_on_a_forge_confirmed_merge() {
  reset_fakes
  local d short full coarse
  d=$(new_case path-agreement)
  make_repo_on_branch "$d/wt" fm/feat-agree
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/agree.meta" "window=fm:fm-agree" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"MERGED","url":"https://github.com/o/r/pull/6"}'
  # Full path: this branch's own run answers, ci skipped, PR merged.
  FM_FAKE_AXI_STATUS="$(run_passed_ci_skipped fm/feat-agree)"
  full=$(run_crew_state "$d" agree)
  # Coarse path: an unrelated crew's run answers instead, so the same run is seen
  # only as its runs-list row - same sha, same PR, same forge answer.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-22 15:30
  completed  fm/feat-agree ${short}  2026-08-22 15:05  https://github.com/o/r/pull/6
EOF
)"
  coarse=$(run_crew_state "$d" agree)
  [ "$full" = "$coarse" ] ||
    fail "the two paths disagree on one world state:"$'\n'"full:   $full"$'\n'"coarse: $coarse"
  assert_contains "$full" "state: done" "the full path settles the merged run"
  assert_contains "$coarse" "state: done" "so does the coarse path"
  pass "both paths agree on a forge-confirmed merge"
}

# The same agreement for one more world state: an open PR with no ci evidence is
# unknown on either path, and neither may claim a landing. The gap phrase differs
# by construction, because the paths genuinely know different things about the ci
# step, so this asserts the verdict rather than the whole line.
test_both_paths_agree_on_an_open_pr_with_no_ci_evidence() {
  reset_fakes
  local d short full coarse
  d=$(new_case path-agreement-open)
  make_repo_on_branch "$d/wt" fm/feat-agreeopen
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/agreeopen.meta" "window=fm:fm-agreeopen" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_GH_PR='{"mergeStateStatus":"DIRTY","state":"OPEN","url":"https://github.com/o/r/pull/6"}'
  FM_FAKE_AXI_STATUS="$(run_passed_ci_skipped fm/feat-agreeopen)"
  full=$(run_crew_state "$d" agreeopen)
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-22 15:30
  completed  fm/feat-agreeopen ${short}  2026-08-22 15:05  https://github.com/o/r/pull/6
EOF
)"
  coarse=$(run_crew_state "$d" agreeopen)
  assert_contains "$full" "state: unknown" "an open PR and no ci evidence settles nothing"
  assert_contains "$coarse" "state: unknown" "and the coarse path says the same"
  assert_not_contains "$full" "PR merged" "an open PR is never a landing on either path"
  assert_not_contains "$coarse" "PR merged" "including from the runs-list row"
  pass "both paths agree on an open PR with no ci evidence"
}

# A FOREIGN task's PR url must never settle this crew. `axi status` is
# REPO-scoped, so a crew with no run of its own is routinely answered with
# another task's record; the reader's own model says a `branch:` mismatch means
# THIS TASK HAS NO RUN, never "use that one". The record was nonetheless left in
# place after a failed attribution, and the PR-url lookup read it, so a sibling's
# MERGED PR made this crew emit a landing claim for a PR that was never its own.
#
# The fixture is the shape that hole needs and no earlier fixture had: a foreign
# run object carrying a REAL merged PR url, while the task under test has none
# anywhere - not in a run of its own, not in its meta, not in its status log.
test_a_sibling_runs_pr_url_never_settles_this_crew() {
  reset_fakes
  local d out
  d=$(new_case sibling-pr-leak)
  make_repo_on_branch "$d/wt" fm/feat-sibling
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/sibling.meta" "window=fm:fm-sibling" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'done: implemented, ready to validate\n' > "$d/state/sibling.status"
  FM_FAKE_AXI_STATUS="$(run_running_other_task_with_pr fm/other-crew https://github.com/o/r/pull/77)"
  # This branch has no row of its own, so attribution fails outright.
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-08-23 15:30
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" sibling
  FM_FAKE_GH_PR='{"mergeStateStatus":"UNKNOWN","state":"MERGED","url":"https://github.com/o/r/pull/77"}'
  out=$(run_crew_state "$d" sibling)
  assert_not_contains "$out" "PR merged" "a sibling's merged PR is not this crew's landing"
  assert_not_contains "$out" "state: done" "and it cannot carry this crew to done"
  assert_not_contains "$out" "source: run-step" "another branch's run is not this crew's run"
  assert_contains "$out" "state: unknown" "a ship task with no PR of its own settles nothing"
  pass "a sibling run's PR url never settles this crew"
}

# RULING: the `no-pr` class comes from the RECORDED TASK KIND, not from the
# absent url. A SCOUT permits `done` with no PR, because it has no landing to
# claim by construction and its deliverable is a report - that is
# test_a_task_with_no_pr_anywhere_still_reads_done, and it stands. A SHIP task
# with no PR does NOT, because a ship task exists to land a branch and that is
# precisely where a `done` would be wrong. The two used to be settled the same
# way, so a ship crew rode the scout's exemption.
#
# The detail is asserted too, not just the word: the reader must name WHICH case
# it is rather than implying an unread or unverifiable PR, which is what the
# transient wording it used to borrow implied. WHICH phrase names it belongs to
# test_a_pre_validation_ship_reads_differently_from_a_run_that_landed_nothing;
# this case only requires that the moment be named rather than glossed as an
# unread forge answer.
test_a_ship_task_with_no_pr_anywhere_is_not_done() {
  reset_fakes
  local d out
  d=$(new_case ship-no-pr)
  make_repo_on_branch "$d/wt" fm/feat-shipnopr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/shipnopr.meta" "window=fm:fm-shipnopr" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'done: implemented, ready to validate\n' > "$d/state/shipnopr.status"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" shipnopr
  out=$(run_crew_state "$d" shipnopr)
  assert_not_contains "$out" "state: done" "a ship task that never opened a PR has landed nothing"
  assert_contains "$out" "state: unknown" "and unknown is the honest word for it"
  assert_contains "$out" "reported complete, not yet validated" "the detail names which case this is"
  assert_not_contains "$out" "PR state unverified" "nothing here is unread, so nothing is pending"
  pass "a ship task with no PR anywhere is not done"
}

# The `outcome: checks-passed` route claimed liveness it had not established. The
# other two green-checks routes sit inside `[ "$RUN_STATE" = working ]`, but this
# one fires on the outcome word alone - and an outcome word is what makes a run
# TERMINAL - so a run that had genuinely finished reported `state: working` on
# every unconfirmed forge read, with no active step and no non-terminal status
# behind the claim.
#
# The live half of the rule is asserted in the same case, because the fix must
# not withdraw it: turning a demonstrably live crew into `unknown` is reproduced
# failure (3) of this change, and the correction that prevents it stands. Only
# the TERMINATED run is stopped from borrowing that live crew's answer.
test_a_terminated_checks_passed_run_does_not_borrow_a_live_crews_answer() {
  reset_fakes
  local d out
  d=$(new_case checks-passed-terminated)
  make_repo_on_branch "$d/wt" fm/feat-cpterm
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cpterm.meta" "window=fm:fm-cpterm" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_GH_CALL_FAILS=1
  FM_FAKE_AXI_STATUS="$(run_checks_passed_terminated fm/feat-cpterm)"
  out=$(run_crew_state "$d" cpterm)
  assert_not_contains "$out" "state: working" "a terminated run is not a crew still monitoring"
  assert_not_contains "$out" "state: done" "and an unread merge state still cannot rule out a close"
  assert_contains "$out" "state: unknown" "neither the landing nor the liveness is established"
  # The same answer, the same route, a run the record shows still executing.
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-cpterm)"
  out=$(run_crew_state "$d" cpterm)
  assert_contains "$out" "state: working" "a live crew still reports its own liveness"
  assert_not_contains "$out" "state: unknown" "which the fix for the terminated case must not withdraw"
  pass "a terminated checks-passed run does not borrow a live crew's answer"
}

# The reader's own header promises "at most ONE outbound `gh pr view` per
# invocation", and every budgeted caller sizes its bound on that promise:
# bin/fm-fleet-snapshot.sh records 3s per task and a worst case of 3 tasks x 3s.
# The promise rested on the done-capable paths being mutually exclusive, which
# they are not - a checks-passed run whose read came back unconfirmed stays
# `working`, and a `working` run with a ci-ready status log asks again, so the
# recorded worst case was silently double.
#
# Asserted by COUNTING the calls, because no assertion on the verdict can see
# this: the answer is identical either way, and only the cost differs.
test_one_invocation_makes_at_most_one_forge_read() {
  reset_fakes
  local d out calls
  d=$(new_case one-forge-read)
  make_repo_on_branch "$d/wt" fm/feat-oneread
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/oneread.meta" "window=fm:fm-oneread" "worktree=$d/wt" "kind=ship" "harness=claude"
  # The exact overlap: a checks-passed run on a LIVE crew, whose forge read does
  # not answer, so it stays `working` and falls into the ci-ready status-log
  # block below - which is a second done-capable path in the same invocation.
  printf 'done: PR https://github.com/o/r/pull/5 checks green\n' > "$d/state/oneread.status"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-oneread)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_GH_CALL_FAILS=1
  FM_FAKE_GH_CALL_LOG="$d/gh-calls.log"
  : > "$FM_FAKE_GH_CALL_LOG"
  out=$(run_crew_state "$d" oneread)
  assert_contains "$out" "state: working" "the fixture must reach the second done-capable path"
  calls=$(grep -c . "$FM_FAKE_GH_CALL_LOG" 2>/dev/null || printf '0')
  [ "$calls" = 1 ] ||
    fail "one invocation made $calls forge reads, and every caller's bound assumes 1"$'\n'"--- output ---"$'\n'"$out"
  pass "one invocation makes at most one forge read"
}

# The mergeStateStatus this path has already paid a bounded forge read to fetch
# must not be discarded. The green-checks ranking dropped it for an `open`
# answer, so an OPEN, DIRTY PR - reproduced failure (2) of this change - read as
# an unqualified readiness claim, while the terminal ranking rendered the same
# forge answer as "PR open, not merged (DIRTY)". One answer, two renderings, and
# the captain-facing one was the silent one.
test_an_open_pr_names_its_merge_state_on_the_checks_green_path() {
  reset_fakes
  local d out
  d=$(new_case checks-green-open-dirty)
  make_repo_on_branch "$d/wt" fm/feat-opendirty
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/opendirty.meta" "window=fm:fm-opendirty" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-opendirty)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"DIRTY","state":"OPEN","url":"https://github.com/o/r/pull/5"}'
  out=$(run_crew_state "$d" opendirty)
  assert_contains "$out" "state: done" "green checks on an open PR are still ready for review"
  assert_contains "$out" "PR still open" "the forge answer this path paid for is reported"
  assert_contains "$out" "(DIRTY)" "including the merge state that says it cannot land as it is"
  pass "an open PR names its merge state on the checks-green path"
}

# A ship task with no PR is TWO situations, and acceptance criterion 1 requires
# they read differently.
#
# The PRE-VALIDATION moment is the ordinary one: a crew appends `done:
# implementation complete, ready to validate` before firstmate hands it to
# no-mistakes, so no PR exists anywhere yet and none is due. That is a HEALTHY
# task at a known point in its lifecycle, and the detail has to say so - the
# wording it replaced read as a defect report and sent a reader hunting for a PR
# that was never owed.
#
# The RUN-BACKED moment is not that at all: a run exists, it finished, and it
# recorded no PR, so nothing has landed and there is no validation still to come.
# One phrase for both would credit a finished run with a pending validation.
#
# The state word is `unknown` for both, and that is the ruling rather than an
# accident, so the last assertion pins the property that makes `unknown`
# acceptable: crew_absorb_class does NOT absorb it. Reading a pre-validation crew
# `working` would let it disappear from supervision, which is the worst failure in
# this whole set.
test_a_pre_validation_ship_reads_differently_from_a_run_that_landed_nothing() {
  reset_fakes
  local d pre backed
  d=$(new_case prevalidation-ship)
  make_repo_on_branch "$d/wt" fm/feat-prevalidate
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/prevalidate.meta" "window=fm:fm-prevalidate" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'done: implementation complete, ready to validate\n' > "$d/state/prevalidate.status"
  # No run anywhere for this branch: the pre-validation state by construction.
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" prevalidate
  pre=$(run_crew_state "$d" prevalidate)
  assert_contains "$pre" "state: unknown" "nothing has been verified yet, so nothing is settled"
  assert_contains "$pre" "reported complete, not yet validated" "the detail names the moment and what it invites"
  assert_not_contains "$pre" "state: done" "a ship's done is a PR with checks green, not this"
  assert_not_contains "$pre" "exists to land one" "a healthy task is not reported as a missing PR"
  # The same kind, the same absent PR, but a run that finished and landed nothing.
  FM_FAKE_AXI_STATUS="$(run_passed_no_pr fm/feat-prevalidate)"
  backed=$(run_crew_state "$d" prevalidate)
  assert_contains "$backed" "state: unknown" "a run that landed nothing settles nothing either"
  assert_contains "$backed" "no PR recorded by this run" "and its detail names the run, not a pending validation"
  assert_not_contains "$backed" "not yet validated" "this run already ran, so nothing is awaiting validation"
  [ "$pre" != "$backed" ] ||
    fail "a pre-validation ship and a run that landed nothing must not read alike"$'\n'"--- output ---"$'\n'"$pre"
  # The property that makes `unknown` the safe word here: not absorbed, so the
  # signal still reaches firstmate. The run-backed half above set
  # FM_FAKE_AXI_STATUS, so it goes back to the pre-validation shape first.
  FM_FAKE_AXI_STATUS=""
  run_provably_working "$d" prevalidate &&
    fail "a pre-validation crew must not be absorbed as provably working"
  pass "a pre-validation ship reads differently from a run that landed nothing"
}

# `mode=local-only` is a first-class ship delivery mode whose brief FORBIDS a PR:
# the worker never pushes, firstmate lands the ready branch with
# bin/fm-merge-local.sh, and no pipeline ever runs. Classifying an absent PR on
# the task KIND alone therefore made the mode permanently unreadable as done - its
# only terminal evidence is the status log's own `done:`, which is exactly the
# claim a `no-landing` answer refuses - and bin/fm-inactive-reconcile.sh, which
# accepts only `done` or `failed`, never reconciled such a crew or produced its
# terminal receipt.
#
# BOTH arms are asserted in one case, because the permissive one is only safe
# while the strict one holds. The second half is the falsifiable guard: the same
# status log, the same kind, the same absent PR, and NO recorded mode must still
# read `unknown`. An unrecorded delivery contract is not a contract exempting the
# task, and if that arm ever goes permissive every ship task with no PR silently
# rides the local-only exemption - the defect this whole split exists to remove.
test_a_local_only_ship_reads_done_without_a_pr_but_an_unrecorded_mode_does_not() {
  reset_fakes
  local d out
  d=$(new_case local-only-ship)
  make_repo_on_branch "$d/wt" fm/feat-localonly
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/localonly.meta" "window=fm:fm-localonly" "worktree=$d/wt" \
    "kind=ship" "mode=local-only" "harness=claude"
  printf 'done: ready in branch fm/feat-localonly\n' > "$d/state/localonly.status"
  # No run anywhere: local-only runs no pipeline, so this is the mode's only shape.
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" localonly
  out=$(run_crew_state "$d" localonly)
  assert_contains "$out" "state: done" "a local-only ship owes no PR, so its own done: is the landing"
  assert_contains "$out" "source: status-log" "and the status log is the only source the mode has"
  assert_contains "$out" "mode=local-only" "the detail names the contract, not a missing PR"
  assert_not_contains "$out" "not yet validated" "nothing is awaiting a validation this mode never runs"
  assert_not_contains "$out" "nothing has landed" "the ready branch is the landing for this mode"

  # The guard half: same kind, same log, same absent PR, no recorded mode.
  reset_fakes
  d=$(new_case unrecorded-mode-ship)
  make_repo_on_branch "$d/wt" fm/feat-nomode
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/nomode.meta" "window=fm:fm-nomode" "worktree=$d/wt" \
    "kind=ship" "harness=claude"
  printf 'done: ready in branch fm/feat-nomode\n' > "$d/state/nomode.status"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" nomode
  out=$(run_crew_state "$d" nomode)
  assert_not_contains "$out" "state: done" "an unrecorded delivery mode exempts nothing"
  assert_contains "$out" "state: unknown" "and unknown is the honest word for an unstated contract"
  assert_not_contains "$out" "mode=local-only" "no mode was recorded, so none may be claimed"
  pass "a local-only ship reads done without a PR, and an unrecorded mode still does not"
}

# The absent-`status:` record, and the one shape on which this reader contradicted
# itself. The status dispatch mapped a record with no status word to
# working/"run active"; crew_liveness rules the same record `terminated`, because
# an absent status is no evidence of liveness at all. Both arms now ask that one
# owner, so the two ROUTES out of this record are asserted separately, because
# either one alone leaves the other free to claim liveness the record does not
# carry.
test_a_record_with_no_status_word_does_not_assert_liveness() {
  reset_fakes
  local d out
  d=$(new_case no-status-word)
  make_repo_on_branch "$d/wt" fm/feat-nostatus
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/nostatus.meta" "window=fm:fm-nostatus" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'done: PR https://github.com/o/r/pull/4 checks green\n' > "$d/state/nostatus.status"
  FM_FAKE_AXI_STATUS="$(run_no_status_word fm/feat-nostatus)"
  FM_FAKE_GH_CALL_FAILS=1
  out=$(run_crew_state "$d" nostatus)
  assert_not_contains "$out" "state: working" "a record with no status word proves no liveness"
  assert_not_contains "$out" "state: done" "and an unread merge state still cannot rule out a close"
  assert_contains "$out" "state: unknown" "neither the landing nor the liveness is established"

  # The OTHER route out of the same record: no ci-ready status log, so the status
  # dispatch answers alone. It used to report working/"run active" here - a
  # liveness claim whose only evidence is the absent word - and the forge is
  # answering MERGED to show that a `done` is not what is being avoided: the
  # record cannot say this crew is alive, and that is the whole finding.
  reset_fakes
  d=$(new_case no-status-word-no-ci-log)
  make_repo_on_branch "$d/wt" fm/feat-nostatus2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/nostatus2.meta" "window=fm:fm-nostatus2" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing the change\n' > "$d/state/nostatus2.status"
  FM_FAKE_AXI_STATUS="$(run_no_status_word fm/feat-nostatus2)"
  FM_FAKE_GH_PR='{"mergeStateStatus":"CLEAN","state":"MERGED","url":"https://github.com/o/r/pull/4"}'
  out=$(run_crew_state "$d" nostatus2)
  assert_not_contains "$out" "state: working" "the status dispatch cannot assert liveness on its own either"
  assert_contains "$out" "state: unknown" "an absent status word is no evidence, so the answer is unknown"
  assert_contains "$out" "no status word" "and the reason names what the record is missing"
  pass "a record with no status word does not assert liveness"
}

test_active_run_is_authoritative
test_stale_needs_decision_superseded
test_stale_blocked_superseded
test_genuine_parked_not_superseded
test_scalar_gate_parked_not_superseded
test_gate_block_parked_not_superseded
test_ci_ready_done_log_beats_monitoring_run
test_ci_monitoring_checks_green_surfaces_done
test_top_level_ci_checks_green_surfaces_done
test_ci_monitoring_no_checks_terminal_surfaces_done
test_ci_monitoring_green_then_rearm_stays_working
test_ci_monitoring_no_checks_yet_stays_working
test_ci_monitoring_still_waiting_stays_working
test_ci_monitoring_green_then_new_issue_stays_working
test_ci_ready_done_log_relapse_stays_working
test_ci_fixing_after_green_stays_working
test_top_level_fixing_ci_running_after_green_stays_working
test_top_level_fixing_done_log_stays_working
test_terminal_passed
test_terminal_failed
test_cross_branch_attribution_via_runs_list
test_cross_branch_attribution_picks_most_recent_row
test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status
test_other_branch_run_ignored
test_no_run_busy_pane
test_no_run_footer_text_alone_is_not_working
test_no_run_grok_uses_isolated_fallback
test_no_run_herdr_unknown_uses_backend_capture
test_no_run_herdr_idle_agent_status_outranked_by_record
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle
test_no_run_idle_pane_uses_log
test_no_run_idle_pane_uses_keyed_log
test_no_run_idle_pane_paused
test_no_run_idle_pane_custom_paused_verb
test_no_run_idle_secondmate_resolved_event_not_state
test_dead_window_ignores_stale_status_log
test_dead_window_still_reports_terminal_run_step
test_dead_window_still_reports_active_run_step
test_no_timeout_uses_perl_bound
test_scout_skips_run_lookup
test_torn_down_worktree
test_missing_meta
test_provably_working_via_runs_list_fallback
test_not_provably_working_when_stopped
test_usage_error
test_historical_same_branch_rewritten_head_not_current
test_active_run_descendant_fix_head_remains_current
test_local_advanced_past_run_head_invalidates
test_missing_run_head_falls_back_to_current_state
test_superseded_failed_row_does_not_mask_live_row
test_live_run_at_unfetched_head_is_not_replaced_by_older_failed_run
test_live_active_step_attributes_run_despite_head_geometry
test_terminal_run_at_unfetched_head_is_not_attributed
test_terminal_run_at_proven_pipeline_head_is_attributed
test_branch_sync_for_another_run_does_not_prove_ownership
test_branch_sync_for_another_head_does_not_prove_ownership
test_branch_sync_for_another_checkout_does_not_prove_ownership
test_ci_skipped_pass_does_not_read_as_done_by_itself
test_checks_passed_outcome_is_done_without_a_completed_ci_row
test_gitlab_merge_request_is_named_not_reported_as_a_forge_failure
test_unrecognized_pr_url_is_named_not_reported_as_a_forge_failure
test_no_forge_knob_honors_a_truthy_word
test_coarse_pr_url_is_found_by_shape_not_by_column
test_a_table_after_active_steps_is_not_read_as_an_active_step
test_branch_sync_gate_status_does_not_park_a_running_run
test_terminal_pass_without_ci_evidence_supersedes_a_stale_gate_log
test_padded_step_columns_do_not_change_the_verdict
test_the_ci_word_comes_from_the_steps_table_whatever_its_position
test_forge_confirmed_merge_settles_a_ci_skipped_run
test_forge_confirmed_close_is_failed_not_done
test_forge_confirmed_close_defeats_a_checks_passed_run
test_checks_passed_keeps_ready_for_review_unless_the_pr_was_closed
test_forge_confirmed_close_defeats_a_green_ci_log
test_forge_confirmed_close_defeats_a_ci_ready_status_log
test_a_transient_forge_non_answer_never_reads_done
test_an_unconfirmed_answer_keeps_a_live_crew_working
test_a_no_run_status_log_done_asks_the_forge
test_a_pr_url_only_in_the_status_log_is_still_queried
test_a_task_with_no_pr_anywhere_still_reads_done
test_a_structural_forge_non_answer_still_reads_done
test_absent_forge_client_is_structural_not_transient
test_both_paths_agree_on_a_forge_confirmed_merge
test_both_paths_agree_on_an_open_pr_with_no_ci_evidence
test_terminal_pass_with_no_steps_table_and_no_landing_is_not_done
test_terminal_pass_with_a_pending_ci_step_and_no_landing_is_not_done
test_coarse_completed_row_without_a_merge_is_not_done
test_coarse_completed_row_is_done_once_the_forge_confirms_the_merge
test_coarse_completed_row_with_an_unanswered_forge_is_not_done
test_branch_sync_head_does_not_satisfy_a_missing_run_head
test_merged_claim_requires_forge_confirmation
test_open_pr_is_never_reported_as_merged
test_unanswered_forge_never_claims_a_landing
test_a_sibling_runs_pr_url_never_settles_this_crew
test_a_ship_task_with_no_pr_anywhere_is_not_done
test_a_terminated_checks_passed_run_does_not_borrow_a_live_crews_answer
test_one_invocation_makes_at_most_one_forge_read
test_an_open_pr_names_its_merge_state_on_the_checks_green_path
test_a_pre_validation_ship_reads_differently_from_a_run_that_landed_nothing
test_a_record_with_no_status_word_does_not_assert_liveness
test_a_local_only_ship_reads_done_without_a_pr_but_an_unrecorded_mode_does_not

echo "all fm-crew-state tests passed"
