# Crew-state verdict guards: falsification record

Maintainer-verification record for the guards in [`bin/fm-crew-run-verdict-lib.sh`](../../bin/fm-crew-run-verdict-lib.sh), which that file's header owns.
Its purpose is narrow: prove the regression cases in `tests/fm-crew-state.test.sh` are not vacuous.
A guard whose test passes with the guard removed protects nothing, and this repo has shipped that mistake before.

Refresh this record after any change to run selection, code binding, ownership proof, or the terminal-pass evidence gates.

## Suite

Date: 2026-08-23.
Branch: `fm/fm-crew-state-stale-run-masks-live`.
`no-mistakes` v1.48.0, `gh` 2.x, ShellCheck 0.11.0.

```
$ bash tests/fm-crew-state.test.sh | grep -c '^ok'
85
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
| An unfetched pipeline head admits no terminal verdict on geometry alone | `unresolvable` admits everything | `test_terminal_run_at_unfetched_head_is_not_attributed` | fails: `unexpected: 'source: run-step'` |
| An executing step attributes its run regardless of head geometry | drop the liveness override | `test_live_active_step_attributes_run_despite_head_geometry` | fails: `missing: 'state: working'` |
| A skipped `ci` step is never validation by itself | let the ranking's ci arm accept every ci status word | `test_ci_skipped_pass_does_not_read_as_done_by_itself` | fails: `unexpected: 'state: done'` |
| A merged or closed claim comes only from the forge | restore the `run passed: PR merged/closed` detail | `test_open_pr_is_never_reported_as_merged` | fails: `missing: 'not merged'` |
| An unanswered forge is never rendered as a landing | restore the same detail | `test_unanswered_forge_never_claims_a_landing` | fails: `missing: 'unverified'` |
| `active_steps` columns are split quote-aware | stop treating `"` as a quote | `test_live_run_at_unfetched_head_is_not_replaced_by_older_failed_run` | fails: `missing: 'last activity 3m11s ago'` |
| A proven pipeline head admits its run's terminal verdict | drop the ownership proof | `test_terminal_run_at_proven_pipeline_head_is_attributed` | fails: `missing: 'state: failed'` |
| Ownership requires `pipeline.run` to be this run | drop that equality | `test_branch_sync_for_another_run_does_not_prove_ownership` | fails: `unexpected: 'source: run-step'` |
| Ownership requires the pipeline head to be this run's head | drop that equality | `test_branch_sync_for_another_head_does_not_prove_ownership` | fails: `unexpected: 'source: run-step'` |
| Ownership requires `local.head` to be this checkout | drop that equality | `test_branch_sync_for_another_checkout_does_not_prove_ownership` | fails: `unexpected: 'source: run-step'` |
| An absent `ci` row is the same absence of evidence a skipped one is | revert that arm to the old skipped-only blacklist (`[ "$ci" != skipped ]`) | `test_terminal_pass_with_no_steps_table_and_no_landing_is_not_done` | fails: `unexpected: 'state: done'` |
| An `outcome: checks-passed` run is done without a corroborating `ci,completed` row | send checks-passed back through the terminal ranking | `test_checks_passed_outcome_is_done_without_a_completed_ci_row` | fails: `missing: 'state: done'` |
| So is any other `ci` status word | the same skipped-only blacklist mutation as the row above it | `test_terminal_pass_with_a_pending_ci_step_and_no_landing_is_not_done` | fails: `unexpected: 'state: done'` |
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
| A forge-confirmed MERGE settles a terminated run done whatever the ci step says | drop the merge arm from the ranking | `test_forge_confirmed_merge_settles_a_ci_skipped_run` | fails: `missing: 'state: done'` |
| A forge-confirmed CLOSE settles it failed, because a closed-unmerged PR is not a landing | rank `closed` with `merged` on the done arm again | `test_forge_confirmed_close_is_failed_not_done` | fails: `missing: 'state: failed'` |
| A host with no `gh` is a structural non-answer, not a transient one | report an absent client as `unverified` again | `test_absent_forge_client_is_structural_not_transient` | fails: `missing: 'no forge client for github'` |
| An `outcome: checks-passed` run asks the forge where the PR ended up | restore the short-circuit, emitting `done` with no forge read | `test_forge_confirmed_close_defeats_a_checks_passed_run` | fails: `missing: 'state: failed'` |
| So does the ci-log-green override, which reaches done by a different route | the same short-circuit on that arm | `test_forge_confirmed_close_defeats_a_green_ci_log` | fails: `missing: 'state: failed'` |
| So does a ci-ready status log, which reaches done with a different source | emit `done` from `emit_checks_green` without consulting the owner | `test_forge_confirmed_close_defeats_a_ci_ready_status_log` | fails: `missing: 'state: failed'` |
| A confirmed merge is named on the checks-green path | drop the merge suffix from `fm_crew_checks_green_verdict` | `test_checks_passed_keeps_ready_for_review_unless_the_pr_was_closed` | fails: `missing: 'PR merged'` |
| Both terminal paths reach the same verdict on a forge-confirmed merge | restore the asymmetry, letting only the no-steps path use the landing | `test_both_paths_agree_on_a_forge_confirmed_merge` | fails: `the two paths disagree on one world state` |
| And on an open PR with no ci evidence | give the no-steps path its own done arm whatever the forge said | `test_both_paths_agree_on_an_open_pr_with_no_ci_evidence` | fails: `missing: 'state: unknown'` |
| The per-child forge bound is at most a third of the scan's remaining budget | pass the whole remaining budget as the bound | `test_forge_bound_is_derived_from_the_remaining_budget` (`tests/fm-inactive-reconcile.test.sh`) | fails: `forge bound exceeds a third of the 6s budget: '3\|'` |
| A budget too small to spare the read skips it instead of shrinking it | take the bound arm unconditionally (`if true`) | the same case | fails: `a 2s budget cannot spare a whole second of forge read: '0\|'` |

38 of 38, re-derived in full on 2026-08-23.

The first two rows share a case deliberately: both guards sit on the runs-list path, and the case needs both to hold - one stops the dead run being reached, the other makes the live run usable.
Four later pairs share a mutation rather than a case, because one gate covers several distinct ways for the evidence to be absent and each way needs its own case to show it is covered.
The `branch_sync:` scoping row is pointed at the case where it carries weight: the pre-existing `test_missing_run_head_falls_back_to_current_state` stays green under that mutation, because its fixture has no `branch_sync:` block for the unscoped read to pick up.
The strictness of the PR-URL rules themselves is not listed as a guard of this file's: `bin/fm-pr-lib.sh` owns them, and `fm_crew_forge_pr_state` reuses `fm_pr_url_parse` read-only rather than restating them.
The look-alike-host case above pins that reuse behaviourally, since a loosened parse would send `https://evil-github.com/o/r/pull/6` to the real forge.
The unknown-not-parked row is pointed at the case that shows the HARM, not just the word: with `parked` restored, the answered `needs-decision:` line stops being reconciled as superseded, which is what let a resolved decision resurface as a captain demand.
The 7-character floor in `fm_crew_sha_matches` is deliberately absent from the table: it is defensive against a degenerate abbreviation and has no observed trigger, so there is no honest case to pin it with.
The last two rows live in `tests/fm-inactive-reconcile.test.sh` because the budget belongs to that caller, and they are listed here because the bound it derives is what keeps this file's forge read affordable.

### Matrix decay, and the re-audit that found it

Every row above was re-derived from scratch on 2026-08-23, one mutation at a time, because a row was found that had silently stopped falsifying anything.
That is worse than having no matrix, since a decayed row launders confidence: it reads as evidence while proving nothing.

Two rows needed repair, and they failed in two different ways worth telling apart.

The ci-padding row DECAYED.
It was genuinely falsifiable when written, and a LATER ruling invalidated it without touching it: once a forge-confirmed merge settled `done` whatever the ci step said, the case's MERGED fixture carried the verdict on its own, so dropping the column trim changed nothing any assertion could see.
The repair is in the case, not the row: its PR is now OPEN, so the padded ci read is the only thing that can reach `done`, and the recorded mutation fails on the recorded assertion again.
The general hazard is worth naming, because it will recur: a case that asserts an OUTCOME reachable by more than one route stops testing the route it was written for the moment another route can carry it alone.

The pending-ci row was MIS-RECORDED from the start, not decayed.
Its mutation column said "the same mutation", and the row it sits under had changed, so the phrase picked up the wrong antecedent - the checks-passed mutation, which cannot affect an `outcome: passed` run at all.
The guard itself was always real and the recorded assertion was always right; only the pointer was wrong, and it now names its mutation outright rather than inheriting one.
Rows that inherit a neighbour's mutation are the ones to distrust first on the next re-audit.

The remaining rows all still falsify on their named assertion, including every row this change added.

## Reproducing the matrix

The mutations are ordinary one-line edits to a copy of `bin/`; nothing in the tree needs to change to re-derive them.
For each row, copy the tree to a scratch directory, apply the mutation named above, run the one case, and confirm it fails on the named assertion.
The case names are the functions in `tests/fm-crew-state.test.sh`, except the last two rows, whose case lives in `tests/fm-inactive-reconcile.test.sh`; running either file's whole runner list also works and is slower.

## Amended acceptance criterion: done by itself

The criterion this branch started from read "a skipped ci step never reads as done".
It was AMENDED, by the same authority that set it, to "a skipped ci step never reads as done BY ITSELF".
Recorded here because a future reader will otherwise find the code contradicting the older wording and try to restore it.

The reasoning: a forge-confirmed merge is stronger evidence than ci completion for the question actually being asked.
The merge proves the work LANDED, while ci completion only proves that checks ran.
The defect this whole change exists to kill was ever claiming merged when nothing merged, and a confirmed merge cannot be that defect.

The case that settled it is the real justification.
On a repo with no CI checks configured every run records `ci,skipped`, so a merged crew read `unknown` permanently on the full `axi status` path, and `bin/fm-inactive-reconcile.sh` accepts only `done` or `failed`, so its terminal outcome was never reconciled and the captain never got the presentation receipt.
Then an unrelated crew started a run in the same repo; `axi status` is repo-scoped, so it began answering for that other branch, the first crew fell to the coarse runs-list path, and the identical world state read `done - run completed: PR merged`.
One world state resolving to opposite verdicts depending on whether an unrelated task happens to be running is the same nondeterminism this change exists to remove, and shipping it would have been worse than the bug it was guarding against.

The structural answer is that `fm_crew_terminal_verdict` is now the ONE ranking both paths call, in one order: a forge-confirmed merge or close, then this run's own `ci,completed`, then unknown.
A path that cannot see a steps table says so by passing `FM_CREW_CI_NO_STEP_DETAIL`, which is missing evidence inside that single ranking rather than a second ranking.
The two agreement cases in the matrix above assert the agreement directly - one compares the two paths' emitted lines for byte equality on a merged run - because per-path cases in isolation are exactly what let the two rankings drift apart.
They cover those two world states and claim no more than that, because agreement is not general and the residual is accepted rather than unnoticed: only a path that can read a steps table can ever satisfy rule 2, so a run with `ci,completed` and no confirmed landing reads done on the full path and unknown on the coarse one.
That is not the contradiction rule 1 fixed, and the distinction is the reason it is acceptable: there both paths held the same evidence and ranked it differently, while here they hold different evidence, so each answer is honest about what that path observed, the direction is conservative, and the cost is a delayed presentation receipt rather than a wrong verdict.
The remedy is the filed runs-list upgrade named in `bin/fm-crew-state.sh`, not a second way for the ranking to guess at ci evidence; `fm_crew_terminal_verdict` records the same residual where the ranking is stated.

## Ruled: a forge-confirmed close is not a landing

The approved rule for the strongest arm of `fm_crew_terminal_verdict` said "a forge-confirmed landing", and the code implemented that wording faithfully by ranking `merged` and `closed` together as `done`.
The wording was the imprecision, not the implementation: a closed-unmerged PR is the opposite of a landing, because the work will never land.
Closed is not merged.

The decisive consequence is downstream.
`bin/fm-inactive-reconcile.sh` builds its captain presentation from the state word and the PR alone, so the detail line saying "PR closed" is dropped exactly at the captain-facing boundary, and ABANDONED work was presented to the captain as a success.
A false success is the worst direction this tool can fail in.

Rule 1 is therefore amended from "a forge-confirmed landing" to "a forge-confirmed MERGE", and a forge-confirmed close becomes a terminal NON-landing that ranks as `failed`.
The amendment recorded in the section above is untouched by it: a confirmed merge still settles `done` whatever the ci step said, and only a confirmed close moved off that arm.

The alternative was rejected, and the reason is worth recording.
Keeping `done` and carrying the detail into the reconcile payload fixes one consumer and leaves the word itself lying, and a state word that lies while a payload tells the truth is a trap for the next reader.

This is the third instance of one rule, now stated in `bin/fm-crew-run-verdict-lib.sh`'s header as the principle governing future state-word choices there: a state word must be honest STANDALONE, because consumers drop the detail at the captain-facing boundary.
The three are `parked` reused for a terminated run, `done` for a terminated run with no CI evidence, and `done` for a forge-confirmed close.
When a word carries a false implication once its detail is stripped, the fix is to make the word honest, never to teach one more consumer to read the fine print.

## Ruled: green checks do not answer where the PR ended up

The close ruling above landed on `fm_crew_terminal_verdict` and left a sibling path untouched, so the same false success survived one route over.
An `outcome: checks-passed` run short-circuited before the forge was ever asked and emitted `done - checks green: PR ready for review`.
A captain who closes that PR without merging, on a crewmate that then goes inactive, was presented with the abandoned work as a success, because `bin/fm-inactive-reconcile.sh` builds its payload from the state word and the PR alone.

That route is the worse of the two to get wrong.
A stale `done` merely overstates the work; `done - PR ready for review` actively invites the captain to go and review something already thrown away.

TWO DIFFERENT QUESTIONS, and the fix keeps them apart rather than merging them.
What proves CI RAN: `checks-passed` is a statement about the CHECKS, so it is CI evidence in its own right and still needs no corroborating `ci,completed` row, exactly as ruled before.
What proves WHERE THE PR ENDED UP: nothing in the run record, on any path.
Green checks answer the first question and are silent on the second, so `checks-passed` keeps its own CI evidence and is simply no longer EXEMPT from the forge read.
`fm_crew_checks_green_verdict` owns the second question for every route that reaches `done` this way: the `checks-passed` outcome, the ci-log-green override, and the ci-ready status log.

The resulting invariant is stated once in `bin/fm-crew-state.sh`'s header rather than as a list of arms: this reader never emits `done` without having asked the forge where the PR ended up.
A confirmed close settles `failed`; every other answer keeps the ready-for-review detail, which is the signal those paths exist to produce, and a confirmed merge names the merge.

The cost changed and is recorded honestly.
The forge read used to happen only on a terminal pass, so a crew monitoring a green PR made no forge call; it now costs one bounded `gh pr view` per heartbeat while that crew waits.
The paths that can say `done` are mutually exclusive, so no single invocation makes two calls, and a crew reported working, parked, failed or unknown still makes none.
That is the price of the invariant, and it is the right way round: the read is cheap and bounded, while presenting abandoned work to a captain as a success is not.

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
Until it lands, a coarse `completed` row can offer no ci-step evidence at all, so the forge's own answer is the only terminal fact that path has: merged reads done, closed reads failed, and open or unanswered reads unknown.
That is the same ranking the full path uses, reached with one input missing rather than by a second rule.
The closed arm is the ruling recorded three sections above, and it holds on BOTH paths, because `fm_crew_terminal_verdict` is the one owner they both call.

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
