#!/usr/bin/env bash
# Product-level demonstration of bin/fm-crew-state.sh - the tool firstmate uses
# to decide whether a worker is healthy, finished or dead.
#
# It drives the REAL reader over the recorded run-record fixtures the suite
# owns (tests/fm-crew-state.test.sh's prelude), and prints the one line a
# firstmate actually reads for each situation. No assertions here: this is the
# CLI transcript, so a human can see the four situations are distinguishable.
set -u
SRC_REPO=${1:?usage: crew-state-demo.sh <firstmate-repo-root>}

# Work from a throwaway copy so nothing is ever written into the repo under test.
ROOT_REPO=$(mktemp -d /tmp/fm-crew-demo-tree.XXXXXX)
trap 'rm -rf "$ROOT_REPO"' EXIT
tar -cf - --exclude=.git -C "$SRC_REPO" . | tar -xf - -C "$ROOT_REPO"

# Source only the fixture/helper prelude of the suite, never its test bodies.
PRELUDE="$ROOT_REPO/tests/demo-prelude.sh"
awk "NR < 822" "$ROOT_REPO/tests/fm-crew-state.test.sh" > "$PRELUDE"
# shellcheck source=/dev/null
. "$PRELUDE"

hdr() { printf '\n===== %s =====\n' "$1"; }
say() { printf '  %s\n' "$1"; }

# ---------------------------------------------------------------------------
hdr 'SITUATION 1/4 - PARKED awaiting a gate response'
reset_fakes
d=$(new_case demo-parked); make_repo_on_branch "$d/wt" fm/demo-parked
make_fakebin "$d" >/dev/null
fm_write_meta "$d/state/parked.meta" "window=fm:demo" "worktree=$d/wt" "kind=ship" "harness=claude"
printf 'working: review round under way\n' > "$d/state/parked.status"
FM_FAKE_AXI_STATUS="$(run_parked fm/demo-parked)"
say "run: status awaiting_approval, gate review, 2 findings (1 ask-user)"
say "$(run_crew_state "$d" parked)"

# ---------------------------------------------------------------------------
hdr 'SITUATION 2/4 - FAILED'
reset_fakes
d=$(new_case demo-failed); make_repo_on_branch "$d/wt" fm/demo-failed
make_fakebin "$d" >/dev/null
fm_write_meta "$d/state/failed.meta" "window=fm:demo" "worktree=$d/wt" "kind=ship" "harness=claude"
printf 'working: fix round under way\n' > "$d/state/failed.status"
FM_FAKE_AXI_STATUS="$(run_failed fm/demo-failed)"
say "run: outcome failed, review step failed"
say "$(run_crew_state "$d" failed)"

# ---------------------------------------------------------------------------
hdr 'SITUATION 3/4 - DONE (ci step completed, forge confirms the merge)'
reset_fakes
d=$(new_case demo-done); make_repo_on_branch "$d/wt" fm/demo-done
make_fakebin "$d" >/dev/null
fm_write_meta "$d/state/done.meta" "window=fm:demo" "worktree=$d/wt" "kind=ship" "harness=claude"
printf 'working: monitoring ci\n' > "$d/state/done.status"
FM_FAKE_AXI_STATUS="$(run_passed_ci_completed fm/demo-done)"
FM_FAKE_GH_PR='{"mergeStateStatus":"CLEAN","state":"MERGED","url":"https://github.com/o/r/pull/9"}'
say "run 01M0JASXQ1H4Q5YAZYJT03F1HN: outcome passed, ci,completed"
say "forge: gh pr view -> state MERGED"
say "$(run_crew_state "$d" done)"

# ---------------------------------------------------------------------------
hdr 'SITUATION 4/4 - completed with its CI STEP SKIPPED (absence of evidence)'
reset_fakes
d=$(new_case demo-skipped); make_repo_on_branch "$d/wt" fm/demo-skipped
make_fakebin "$d" >/dev/null
fm_write_meta "$d/state/skipped.meta" "window=fm:demo" "worktree=$d/wt" "kind=ship" "harness=claude"
printf 'working: monitoring ci\n' > "$d/state/skipped.status"
FM_FAKE_AXI_STATUS="$(run_passed_ci_skipped fm/demo-skipped)"
FM_FAKE_GH_PR='{"mergeStateStatus":"DIRTY","state":"OPEN","url":"https://github.com/o/r/pull/6"}'
say "run 01M0JMD3H94MKKF7SCM5C5QWR6: outcome passed, ci,SKIPPED"
say "forge: gh pr view -> state OPEN, mergeStateStatus DIRTY"
say "$(run_crew_state "$d" skipped)"

# ---------------------------------------------------------------------------
hdr 'OBSERVED FAILURE 1 - a superseded terminal-FAILED run must not mask the live one'
reset_fakes
d=$(new_case demo-mask); make_pipeline_ahead_topology "$d" fm/demo-mask
make_fakebin "$d" >/dev/null
fm_write_meta "$d/state/mask.meta" "window=fm:demo" "worktree=$d/wt" "kind=ship" "harness=claude"
printf 'working: fix round under way\n' > "$d/state/mask.status"
FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
FM_FAKE_RUNS_LIST="  running    fm/other-crew aaaaaaa  2026-08-21 15:30
  running    fm/demo-mask $(printf %.8s "$PIPE_HEAD")  2026-08-21 15:25
  failed     fm/demo-mask $(printf %.8s "$LOCAL_HEAD")  2026-08-20 02:21"
say "checkout head $(printf %.8s "$LOCAL_HEAD") carries run 01M0EFHK (FAILED)"
say "pipeline head $(printf %.8s "$PIPE_HEAD") carries the live run - unfetchable locally"
say "$(run_crew_state "$d" mask)"

# ---------------------------------------------------------------------------
hdr 'OBSERVED FAILURE 2 - an OPEN DIRTY PR must never be reported as merged'
reset_fakes
d=$(new_case demo-openpr); make_repo_on_branch "$d/wt" fm/demo-openpr
make_fakebin "$d" >/dev/null
fm_write_meta "$d/state/openpr.meta" "window=fm:demo" "worktree=$d/wt" "kind=ship" "harness=claude"
printf 'done: implemented, ready to validate\n' > "$d/state/openpr.status"
FM_FAKE_AXI_STATUS="$(run_passed_ci_skipped fm/demo-openpr)"
FM_FAKE_GH_PR='{"mergeStateStatus":"DIRTY","state":"OPEN","url":"https://github.com/o/r/pull/6"}'
FM_FAKE_GH_CALL_LOG="$d/gh-calls.log"; export FM_FAKE_GH_CALL_LOG
say "status log claims 'done'; forge says OPEN + DIRTY, zero checks"
say "$(run_crew_state "$d" openpr)"
say "outbound forge reads this invocation made: $(wc -l < "$d/gh-calls.log") -> $(cat "$d/gh-calls.log")"

hdr 'OBSERVED FAILURE 2b - the forge did not answer at all'
reset_fakes
d=$(new_case demo-noforge); make_repo_on_branch "$d/wt" fm/demo-noforge
make_fakebin "$d" >/dev/null
fm_write_meta "$d/state/nf.meta" "window=fm:demo" "worktree=$d/wt" "kind=ship" "harness=claude"
printf 'done: implemented, ready to validate\n' > "$d/state/nf.status"
FM_FAKE_AXI_STATUS="$(run_passed_ci_completed fm/demo-noforge)"
FM_FAKE_GH_CALL_FAILS=1
say "run passed with ci,completed; the forge read FAILED"
say "$(run_crew_state "$d" nf)"

# ---------------------------------------------------------------------------
hdr 'OBSERVED FAILURE 3 - a live-but-parked pipeline must not read as unknown'
reset_fakes
d=$(new_case demo-live); make_repo_on_branch "$d/wt" fm/demo-live
run_head=$(git -C "$d/wt" rev-parse HEAD)
git -C "$d/wt" commit -q --allow-empty -m 'local commit made while the run was executing'
make_fakebin "$d" >/dev/null
fm_write_meta "$d/state/live.meta" "window=fm:demo" "worktree=$d/wt" "kind=ship" "harness=claude"
printf 'resolved: firstmate answered the review question\n' > "$d/state/live.status"
FM_FAKE_AXI_STATUS="$(run_live_active_step fm/demo-live "$run_head")"
FM_FAKE_BUSY=0
arm_idle_record "$d/state" live
say "run 01M0N8J9ET64CBM89W4D663WBZ: active_steps says test running, agent_pid 2419262"
say "checkout has advanced past the run head, pane is idle, log holds only an event"
say "$(run_crew_state "$d" live)"

# ---------------------------------------------------------------------------
hdr 'ACCEPTED RULING - a forge read that TIMES OUT reports UNVERIFIED, never done'
reset_fakes
d=$(new_case demo-timeout); make_repo_on_branch "$d/wt" fm/demo-timeout
make_fakebin "$d" >/dev/null
# A forge that WOULD answer MERGED, but only after the bound has expired.
cat > "$d/fakebin/gh" <<'SH'
#!/usr/bin/env bash
sleep 5
printf '{"mergeStateStatus":"CLEAN","state":"MERGED","url":"https://github.com/o/r/pull/9"}\n'
SH
chmod +x "$d/fakebin/gh"
fm_write_meta "$d/state/to.meta" "window=fm:demo" "worktree=$d/wt" "kind=ship" "harness=claude"
printf 'working: monitoring ci\n' > "$d/state/to.status"
FM_FAKE_AXI_STATUS="$(run_passed_ci_completed fm/demo-timeout)"
say "run passed with ci,completed; the forge would answer MERGED after 5s"
say "the bound is 1s here (the fleet snapshot narrows it to 3s)"
t0=$SECONDS
line=$(export FM_CREW_STATE_FORGE_TIMEOUT=1; run_crew_state "$d" to)
say "$line"
say "elapsed: $((SECONDS - t0))s - the bound held and no landing was claimed"

# ---------------------------------------------------------------------------
hdr 'REPO-SCOPED axi status naming a SIBLING branch is not this task run'
reset_fakes
d=$(new_case demo-sibling); make_repo_on_branch "$d/wt" fm/demo-sibling
make_fakebin "$d" >/dev/null
fm_write_meta "$d/state/sib.meta" "window=fm:demo" "worktree=$d/wt" "kind=ship" "harness=claude"
printf 'done: implemented, ready to validate\n' > "$d/state/sib.status"
FM_FAKE_AXI_STATUS="$(run_running_other_task_with_pr fm/some-other-task https://github.com/o/r/pull/77)"
FM_FAKE_GH_PR='{"mergeStateStatus":"CLEAN","state":"MERGED","url":"https://github.com/o/r/pull/77"}'
FM_FAKE_RUNS_LIST="  running    fm/some-other-task aaaaaaa  2026-08-23 15:30"
FM_FAKE_BUSY=0
arm_idle_record "$d/state" sib
say "axi status answers for branch fm/some-other-task, carrying PR 77 (merged)"
say "this task's own branch is fm/demo-sibling and has no run"
say "$(run_crew_state "$d" sib)"

printf '\n'

