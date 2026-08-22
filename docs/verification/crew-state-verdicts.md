# Crew-state verdict guards: falsification record

Maintainer-verification record for the guards in [`bin/fm-crew-run-verdict-lib.sh`](../../bin/fm-crew-run-verdict-lib.sh), which that file's header owns.
Its purpose is narrow: prove the regression cases in `tests/fm-crew-state.test.sh` are not vacuous.
A guard whose test passes with the guard removed protects nothing, and this repo has shipped that mistake before.

Refresh this record after any change to run selection, code binding, ownership proof, or the terminal-pass evidence gates.

## Suite

Date: 2026-08-22.
Branch: `fm/fm-crew-state-stale-run-masks-live`.
`no-mistakes` v1.48.0, `gh` 2.x, ShellCheck 0.11.0.

```
$ bash tests/fm-crew-state.test.sh | grep -c '^ok'
76
$ bash tests/fm-inactive-reconcile.test.sh 2>/dev/null | grep -c '^ok'
17
```

The count is the evidence, not the exit status: a green step does not prove its assertions ran.
The second suite is listed because one guard below - the bound the scan derives for this reader's forge read - belongs to that caller and is pinned there.

## Falsification matrix

Each row removes one guard from a throwaway copy of the tree and runs the single case that claims to protect it.
Every row must fail, and must fail on the named assertion.

| Guard | Mutation | Case | Result |
| --- | --- | --- | --- |
| Only the branch's newest run row is ever examined | let the runs list be scanned past the newest row, keeping the LAST matching row instead of the first | `test_superseded_failed_row_does_not_mask_live_row` | fails: `missing: 'state: working'` |
| An unfetched pipeline head still admits a live verdict | `unresolvable` admits nothing | `test_superseded_failed_row_does_not_mask_live_row` | fails: `missing: 'state: working'` |
| An unfetched pipeline head never admits a terminal verdict | `unresolvable` admits everything | `test_terminal_run_at_unfetched_head_is_not_attributed` | fails: `unexpected: 'source: run-step'` |
| An executing step attributes its run regardless of head geometry | drop the liveness override | `test_live_active_step_attributes_run_despite_head_geometry` | fails: `missing: 'state: working'` |
| A skipped `ci` step is never validation | let the evidence whitelist accept every ci status word (`if true`) | `test_ci_skipped_pass_never_reads_as_done` | fails: `unexpected: 'state: done'` |
| A merged or closed claim comes only from the forge | restore the `run passed: PR merged/closed` detail | `test_open_pr_is_never_reported_as_merged` | fails: `missing: 'not merged'` |
| An unanswered forge is never rendered as a landing | restore the same detail | `test_unanswered_forge_never_claims_a_landing` | fails: `missing: 'unverified'` |
| `active_steps` columns are split quote-aware | stop treating `"` as a quote | `test_live_run_at_unfetched_head_is_not_replaced_by_older_failed_run` | fails: `missing: 'last activity 3m11s ago'` |
| A proven pipeline head admits its run's terminal verdict | drop the ownership proof | `test_terminal_run_at_proven_pipeline_head_is_attributed` | fails: `missing: 'state: failed'` |
| Ownership requires `pipeline.run` to be this run | drop that equality | `test_branch_sync_for_another_run_does_not_prove_ownership` | fails: `unexpected: 'source: run-step'` |
| Ownership requires the pipeline head to be this run's head | drop that equality | `test_branch_sync_for_another_head_does_not_prove_ownership` | fails: `unexpected: 'source: run-step'` |
| Ownership requires `local.head` to be this checkout | drop that equality | `test_branch_sync_for_another_checkout_does_not_prove_ownership` | fails: `unexpected: 'source: run-step'` |
| An absent `ci` row is the same absence of evidence a skipped one is | revert the whitelist to the old skipped-only blacklist (`[ "$1" != skipped ]`) | `test_terminal_pass_without_a_steps_table_is_not_done` | fails: `unexpected: 'state: done'` |
| An `outcome: checks-passed` run is done without a corroborating `ci,completed` row | send checks-passed back through the ci-step whitelist | `test_checks_passed_outcome_is_done_without_a_completed_ci_row` | fails: `missing: 'state: done'` |
| So is any other `ci` status word | the same mutation | `test_terminal_pass_with_a_pending_ci_step_is_not_done` | fails: `unexpected: 'state: done'` |
| A coarse runs-list `completed` row is not a pass without a forge-confirmed landing | let every forge answer take the done arm | `test_coarse_completed_row_without_a_merge_is_not_done` | fails: `unexpected: 'state: done'` |
| Nor when the forge did not answer at all | the same mutation | `test_coarse_completed_row_with_an_unanswered_forge_is_not_done` | fails: `unexpected: 'state: done'` |
| Run-record scalar reads exclude the `branch_sync:` block | make `fm_crew_run_scalars` a passthrough | `test_branch_sync_head_does_not_satisfy_a_missing_run_head` | fails: `unexpected: 'source: run-step'` |
| A provider with no forge client is named, not reported as a transient failure | collapse both structural non-answers back into `unverified` | `test_gitlab_merge_request_is_named_not_reported_as_a_forge_failure` | fails: `missing: 'no forge client for gitlab'` |
| So is a URL that is not a recognizable PR or MR | the same mutation | `test_unrecognized_pr_url_is_named_not_reported_as_a_forge_failure` | fails: `missing: 'PR url not recognized'` |
| `FM_CREW_STATE_NO_FORGE` honors any truthy value, as documented | narrow it back to the literal `1` | `test_no_forge_knob_honors_a_truthy_word` | fails: `missing: 'unverified'` |
| The coarse row's PR url is found by shape, not by column index | read it from the fixed sixth field again | `test_coarse_pr_url_is_found_by_shape_not_by_column` | fails: `missing: 'state: done'` |
| The `active_steps` table ends at any following TOON table header | end it only at a blank or comma-free line | `test_a_table_after_active_steps_is_not_read_as_an_active_step` | fails: `unexpected: 'test running'` |
| Gate and step reads are scoped to the run object, not the whole record | let `nm_gate_status` scan raw `$RUN_OUT` again | `test_branch_sync_gate_status_does_not_park_a_running_run` | fails: `unexpected: 'state: parked'` |
| A terminal pass with no CI evidence reads unknown, never parked | return `parked` for that verdict again | `test_terminal_pass_without_ci_evidence_supersedes_a_stale_gate_log` | fails: `missing: 'status-log superseded'` |
| The ci status column is read tolerant of padding and quoting | drop the trim, restoring the bare `[^,]*` capture | `test_padded_step_columns_do_not_change_the_verdict` | fails: `missing: 'state: done'` |
| So is every `active_steps` column | drop the per-value trim in the row split | the same case | fails: `missing: 'test running'` |
| The per-child forge bound is at most a third of the scan's remaining budget | pass the whole remaining budget as the bound | `test_forge_bound_is_derived_from_the_remaining_budget` (`tests/fm-inactive-reconcile.test.sh`) | fails: `forge bound exceeds a third of the 6s budget: '3\|'` |
| A budget too small to spare the read skips it instead of shrinking it | take the bound arm unconditionally (`if true`) | the same case | fails: `a 2s budget cannot spare a whole second of forge read: '0\|'` |

29 of 29.

The first two rows share a case deliberately: both guards sit on the runs-list path, and the case needs both to hold - one stops the dead run being reached, the other makes the live run usable.
Three later pairs share a mutation rather than a case, because one gate covers several distinct ways for the evidence to be absent and each way needs its own case to show it is covered.
The `branch_sync:` scoping row is pointed at the case where it carries weight: the pre-existing `test_missing_run_head_falls_back_to_current_state` stays green under that mutation, because its fixture has no `branch_sync:` block for the unscoped read to pick up.
The strictness of the PR-URL rules themselves is not listed as a guard of this file's: `bin/fm-pr-lib.sh` owns them, and `fm_crew_forge_pr_state` reuses `fm_pr_url_parse` read-only rather than restating them.
The look-alike-host case above pins that reuse behaviourally, since a loosened parse would send `https://evil-github.com/o/r/pull/6` to the real forge.
The unknown-not-parked row is pointed at the case that shows the HARM, not just the word: with `parked` restored, the answered `needs-decision:` line stops being reconciled as superseded, which is what let a resolved decision resurface as a captain demand.
The 7-character floor in `fm_crew_sha_matches` is deliberately absent from the table: it is defensive against a degenerate abbreviation and has no observed trigger, so there is no honest case to pin it with.
The last two rows live in `tests/fm-inactive-reconcile.test.sh` because the budget belongs to that caller, and they are listed here because the bound it derives is what keeps this file's forge read affordable.

## Reproducing the matrix

The mutations are ordinary one-line edits to a copy of `bin/`; nothing in the tree needs to change to re-derive them.
For each row, copy the tree to a scratch directory, apply the mutation named above, run the one case, and confirm it fails on the named assertion.
The case names are the functions in `tests/fm-crew-state.test.sh`, except the budget row, whose case lives in `tests/fm-inactive-reconcile.test.sh`; running either file's whole runner list also works and is slower.

## Forge-read bound

`fm_crew_forge_pr_state` is the only outbound call this reader makes, and `FM_CREW_STATE_FORGE_TIMEOUT` bounds it.
The default is 3 seconds, from this measurement on 2026-08-22:

Command: `gh pr view <n> --repo <owner/repo> --json state,mergeStateStatus`, against a real GitHub PR, five consecutive runs.
Elapsed: 0.53s, 0.59s, 0.59s, 0.61s, 0.53s.

Worst case 0.61s, so 3s is roughly five times the worst observed call.
That is one host with warm `gh` auth: the figure is a headroom choice, not a latency guarantee, and a cold or unauthenticated `gh` is exactly the case the bound exists for.
What the choice protects is the caller, not the call: `bin/fm-inactive-reconcile.sh` runs `bin/fm-crew-state.sh` inside a 10-second aggregate budget for a whole scan, so a bound equal to that budget lets one hung call starve every remaining child.
At 3 seconds a fully hung call leaves that scan most of its budget, and the scan narrows the bound further to at most a third of what it has left, skipping the read entirely when the remainder cannot spare a whole second.
Skipping is safe by construction: an unread merge state is reported as unverified, and unverified is never rendered as a landing.

## Fixture provenance

The run records in those cases are recorded output from real runs on this fork, not invented shapes:

| Fixture | Run | What it captures |
| --- | --- | --- |
| `run_passed_ci_skipped` | `01M0JMD3H94MKKF7SCM5C5QWR6` | `outcome: passed` with `ci,skipped`, PR open and conflicted |
| `run_passed_ci_completed` | `01M0JASXQ1H4Q5YAZYJT03F1HN` | the same outcome word with `ci,completed` |
| `run_failed_at_local_head` | `01M0EFHKF1A3CJX4KK58HWJ7D2` | the terminal-failed run that masked a live one |
| `run_live_active_step` | `01M0N8J9ET64CBM89W4D663WBZ` | a live `active_steps` row, including its quoted comma-bearing `last_activity` |
| `branch_sync_block` | `01M0N8J9ET64CBM89W4D663WBZ` | the `branch_sync:` field set and shape, read from that run's own task worktree |

The remaining fixtures are synthetic minimal shapes rather than recordings, and they are named for what they omit: `run_passed` carries a `ci,completed` row, `run_passed_no_steps` carries no steps table at all, and the pending-ci case rewrites the former's `ci` row to `pending`.

`run_checks_passed` is synthetic too, and one thing about it is deliberately NOT a claim.
No `outcome: checks-passed` run has been recorded on this fork, so the ci-step status that actually accompanies one is unobserved here, and the fixture's `ci,running` row is a plausible shape rather than an observed one.
That is exactly why the verdict does not read the ci-step word for this outcome: `checks-passed` is itself a statement about the checks, so the answer holds whatever the accompanying row turns out to say, and the guard above is falsified against that independence rather than against a guessed value.
Record the real pairing here the first time a `checks-passed` run is observed, and treat any surprise in it as information about the fixture, not about the rule.

`make_pipeline_ahead_topology` builds the geometry those cases need for real - a task worktree plus a separate clone standing in for the pipeline's own - so the run head under test is a genuine commit the checkout cannot resolve rather than a made-up sha.

## Run listings

Both were verified on 2026-08-22 against `no-mistakes` v1.48.0, because run selection depends on which one can find a branch's run:

| Listing | Run ids | Reach |
| --- | --- | --- |
| bare `no-mistakes axi` home view, `runs[N]{id,branch,status,head,pr}` | yes | capped at the 10 most recent runs repo-wide (`count: 10 of 21 total`), no limit flag |
| `no-mistakes runs --limit N` | no | arbitrary, newest-first plain text |

Selection uses the second because finding the branch's run at all outranks richer detail about it.
The first would allow a follow-up `axi status --run <id>` and so give that path the same full step, activity and `branch_sync` evidence the `axi status` path gets, which a coarse row cannot carry; that upgrade is named in `bin/fm-crew-state.sh` as follow-up work rather than done here.
Until it lands, a coarse `completed` row can never satisfy the CI-evidence whitelist, so the forge's own answer is the only terminal fact that path has: merged or closed reads done, and open or unanswered reads unknown.

## branch_sync availability

`bin/fm-crew-run-verdict-lib.sh` widens the unresolvable-head case using the `branch_sync:` block that `no-mistakes axi status` already returns, so what that block does and does not appear for is load-bearing.
Observed on 2026-08-22 against `no-mistakes` v1.48.0:

| Invocation | `branch_sync:` |
| --- | --- |
| `axi status` from the task worktree of a live pipeline-owned run | present, with `pipeline.run`, `submitted_head`, `current_head`, `pushed_head`, `local.head`, `remote.observed_head`, `pr_state` |
| `axi status --run <that same live run>` from that worktree | present |
| `axi status` from a worktree whose branch has no push binding | absent - the command still answers with another branch's run, and carries no block at all |
| `axi status --run <terminal run>` from a worktree on a different branch | absent |
| `axi status` from the primary checkout on `main` | present but `state: ambiguous_context`, every `pipeline` field empty |

Two consequences worth keeping straight.
The block is computed for the INVOKING worktree's branch, not for the run named by `--run`, which is why the ownership proof compares `pipeline.run` against the run under test instead of trusting the block's mere presence.
And its persistence for a terminal run queried from its own branch is expected but NOT yet observed here, because no branch in this repo currently has both a worktree and a terminal run; `axi sync --recover`'s contract - returning custody of a branch stranded by a terminal run with unpublished pipeline commits - is the reason to expect the binding to outlive the run.
Where the block is absent the conservative refusal simply stands, so that gap costs a handling turn and never a wrong verdict.
Refresh this row the next time a completed run's branch still has its worktree:

```
cd <task worktree on the run's branch>
no-mistakes axi status --run <that branch's terminal run id> | grep -A12 '^branch_sync:'
```
