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
98
$ bash tests/fm-inactive-reconcile.test.sh 2>/dev/null | grep -c '^ok'
17
$ bash tests/fm-fleet-snapshot-view.test.sh 2>/dev/null | grep -c '^ok'
16
$ bash tests/fm-watch-triage.test.sh 2>/dev/null | grep -c '^ok'
50
```

The count is the evidence, not the exit status: a green step does not prove its assertions ran.
The later suites are listed because four guards below belong to those callers and are pinned there: the bound the scan derives for this reader's forge read, the fixed per-task bound the snapshot chooses, and the per-crew bound the watcher's triage chooses.

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
| The checks-green lead claims only green checks, never a pass | pass `verified` to the closed detail again, restoring the "run passed" lead | `test_forge_confirmed_close_defeats_a_green_ci_log` | fails: `missing: 'checks green: PR closed'` |
| An UNCONFIRMED answer never reads done on the terminal path | drop the unconfirmed arm from `fm_crew_terminal_verdict` | `test_a_transient_forge_non_answer_never_reads_done` | fails: `unexpected: 'state: done'` |
| Nor on the green-checks path, which reports the crew's proven liveness instead | return `unknown` from the unconfirmed arm of `fm_crew_done_claim_verdict` | `test_an_unconfirmed_answer_keeps_a_live_crew_working` | fails: `unexpected: 'state: unknown'` |
| An UNANSWERABLE answer still reads done, because no read will ever clear it | class the unanswerable words as unconfirmed | `test_a_structural_forge_non_answer_still_reads_done` | fails: `missing: 'state: done'` |
| A SCOUT with no PR anywhere still reads done, having no landing to claim by construction | class `no-pr` as unconfirmed | `test_a_task_with_no_pr_anywhere_still_reads_done` | fails: `missing: 'state: done'` |
| A no-run status-log `done:` asks the forge like every other done claim | emit the log verb without consulting `fm_crew_reported_done_verdict` | `test_a_no_run_status_log_done_asks_the_forge` | fails: `missing: 'state: failed'` |
| A PR url recorded only in the status log is still found and queried | drop the status-log arm of `crew_pr_url` | `test_a_pr_url_only_in_the_status_log_is_still_queried` | fails: `missing: 'state: failed'` |
| The watch-triage caller narrows the per-crew forge bound | drop the `FM_CREW_STATE_FORGE_TIMEOUT` `crew_absorb_class` passes | `test_crew_absorb_class_narrows_the_forge_bound` (`tests/fm-watch-triage.test.sh`) | fails: `crew_absorb_class left the forge bound at the reader's own default` |
| The fleet snapshot narrows the per-task forge bound rather than inheriting it | drop the `FM_CREW_STATE_FORGE_TIMEOUT` it passes | `test_snapshot_narrows_the_per_task_forge_bound` (`tests/fm-fleet-snapshot-view.test.sh`) | fails: `the snapshot must narrow the per-task forge bound to 3s, got '10'` |
| Both terminal paths reach the same verdict on a forge-confirmed merge | restore the asymmetry, letting only the no-steps path use the landing | `test_both_paths_agree_on_a_forge_confirmed_merge` | fails: `the two paths disagree on one world state` |
| And on an open PR with no ci evidence | give the no-steps path its own done arm whatever the forge said | `test_both_paths_agree_on_an_open_pr_with_no_ci_evidence` | fails: `missing: 'state: unknown'` |
| The per-child forge bound is at most a third of the scan's remaining budget | pass the whole remaining budget as the bound | `test_forge_bound_is_derived_from_the_remaining_budget` (`tests/fm-inactive-reconcile.test.sh`) | fails: `forge bound exceeds a third of the full 10s budget: '10\|'` |
| A budget too small to spare the read skips it instead of shrinking it | take the bound arm unconditionally (`if true`) | the same case | fails: `a 2s budget cannot spare a whole second of forge read: '0\|'` |
| A failed branch attribution discards the run record, so a SIBLING task's PR url can never settle this crew | restore `RUN_SOURCE=full` at initialisation and drop the `RUN_OUT`/`RUN_OBJECT` clearing in the mismatch arm | `test_a_sibling_runs_pr_url_never_settles_this_crew` | fails: `unexpected: 'PR merged'`, on the line `state: done · source: status-log · implemented, ready to validate, PR merged` |
| A SHIP task with no PR anywhere is never done, because a ship task exists to land a branch | settle every kind the scout way, returning `no-pr` from every arm of `fm_crew_no_pr_class` | `test_a_ship_task_with_no_pr_anywhere_is_not_done` | fails: `unexpected: 'state: done'` |
| A TERMINATED checks-passed run does not borrow the live crew's unconfirmed answer | hardcode `working` in `fm_crew_checks_green_verdict` again, ignoring `<liveness>` | `test_a_terminated_checks_passed_run_does_not_borrow_a_live_crews_answer` | fails: `unexpected: 'state: working'` |
| One invocation makes at most one outbound forge read | drop the memo, letting `crew_ask_forge` re-read on every call | `test_one_invocation_makes_at_most_one_forge_read` | fails: `one invocation made 2 forge reads, and every caller's bound assumes 1` |
| The merge state the forge read already paid for is reported on the green-checks path | return the done arm of `fm_crew_done_claim_verdict` without its forge suffix | `test_an_open_pr_names_its_merge_state_on_the_checks_green_path` | fails: `missing: 'PR still open'` |
| A pre-validation ship names the moment, distinctly from a run that landed nothing | drop the `reported` arm from `fm_crew_ship_no_pr_phrase`, leaving one phrase for both moments | `test_a_pre_validation_ship_reads_differently_from_a_run_that_landed_nothing` | fails: `missing: 'reported complete, not yet validated'` |
| That crew stays `unknown` rather than `working` | pass `working` as `fm_crew_reported_done_verdict`'s unconfirmed state | the same case | fails: `missing: 'state: unknown'` |
| And `crew_absorb_class` does not absorb it, which is what makes `unknown` safe | let the absorb whitelist admit `unknown` alongside `working` | the same case | fails: `a pre-validation crew must not be absorbed as provably working` |
| Liveness on the full-path ci-ready route is DERIVED from the record, not asserted | pass the literal `live` from that call site again | `test_a_record_with_no_status_word_does_not_assert_liveness` | fails: `unexpected: 'state: working'` |

56 of 56, re-derived in full on 2026-08-23 - once per fix round since the decay was found.

The last four rows were added by the round that separated the two ship-with-no-PR moments and stopped the ci-ready route asserting liveness it had not established.

Three of those four share one case, because the ruling they carry has three parts that only hold together: the pre-validation crew must NAME its moment, must stay `unknown`, and must not be ABSORBED.
Each part is falsified by a different mutation - collapsing the phrase, reporting `working`, and widening the absorb whitelist - so the shared case is not a shared guard.

The absorb row is worth reading closely, because the obvious mutation does NOT falsify it and that is informative rather than a gap.
Reporting the crew `working` leaves it unabsorbed anyway, since `crew_absorb_class` absorbs `working` only from `run-step` or `pane` and this verdict carries `source: status-log`.
Two independent gates therefore protect the same property, and only mutating the absorb predicate itself can show the assertion has teeth - which it does.
The row records the mutation that actually falsifies it rather than the one that looks like it should, since a row naming a mutation that changes nothing is the decay mode this table exists to catch.

The five rows before those were added by the round that closed the sibling-PR leak, the kind-blind `no-pr` settlement, the borrowed liveness claim and the duplicated forge read.
Three of them are paired with a case that must STAY GREEN under the same mutation, and that pairing is the point rather than a courtesy: each fix narrows a rule that a previous ruling had deliberately widened, so a mutation that only shows the new case failing cannot show the old ruling survived.
Under the kind-blind mutation `test_a_task_with_no_pr_anywhere_still_reads_done` still passes, so the SCOUT exemption is intact and only the ship case moved.
Under the hardcoded-`working` mutation `test_an_unconfirmed_answer_keeps_a_live_crew_working` still passes, so a demonstrably live crew still reads `working` on an unconfirmed answer - reproduced failure (3) is not reintroduced, and what was removed is only the TERMINATED run's ability to borrow that answer.

The one-forge-read row is the only row in this table that asserts a COST rather than a verdict, and it needs a different kind of assertion for a reason worth recording.
Every other guard here changes what the reader says; this one changes only how many times it asks, and the answer is byte-identical either way.
No assertion on the output line can see it, which is precisely how the duplicate survived: the suite's fake `gh` answered the same on every call, so the second call was invisible.
The case counts invocations through `FM_FAKE_GH_CALL_LOG` instead, and its fixture is built to REACH the overlap - a checks-passed run whose unconfirmed read leaves it `working`, plus a ci-ready status log - because a fixture that takes only one done-capable path would pass without the memo and prove nothing.

The first two rows share a case deliberately: both guards sit on the runs-list path, and the case needs both to hold - one stops the dead run being reached, the other makes the live run usable.
Four later pairs share a mutation rather than a case, because one gate covers several distinct ways for the evidence to be absent and each way needs its own case to show it is covered.
The `branch_sync:` scoping row is pointed at the case where it carries weight: the pre-existing `test_missing_run_head_falls_back_to_current_state` stays green under that mutation, because its fixture has no `branch_sync:` block for the unscoped read to pick up.
The strictness of the PR-URL rules themselves is not listed as a guard of this file's: `bin/fm-pr-lib.sh` owns them, and `fm_crew_forge_pr_state` reuses `fm_pr_url_parse` read-only rather than restating them.
The look-alike-host case above pins that reuse behaviourally, since a loosened parse would send `https://evil-github.com/o/r/pull/6` to the real forge.
The unknown-not-parked row is pointed at the case that shows the HARM, not just the word: with `parked` restored, the answered `needs-decision:` line stops being reconciled as superseded, which is what let a resolved decision resurface as a captain demand.
The 7-character floor in `fm_crew_sha_matches` is deliberately absent from the table: it is defensive against a degenerate abbreviation and has no observed trigger, so there is no honest case to pin it with.
Four rows live in other suites because the bound belongs to those callers, and they are listed here because what those callers choose is what keeps this file's forge read affordable: two in `tests/fm-inactive-reconcile.test.sh` for the scan's derived share, one in `tests/fm-fleet-snapshot-view.test.sh` for the snapshot's fixed per-task bound, and one in `tests/fm-watch-triage.test.sh` for the watcher's per-crew bound.
Four rows and three callers, which is why the Suite section counts four guards while naming three bounds: the scan's share is pinned twice, once for the third-of-budget ceiling and once for its refusal to shrink a budget too small to spare the read at all.
The snapshot row is only falsifiable because that bound is TIGHTER than the library default.
While the two coincided at 3s, removing the snapshot's override changed nothing and the row proved nothing - the same decay mode the ci-padding row taught, caught here before it was recorded rather than after.

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
The case names are the functions in `tests/fm-crew-state.test.sh`, except the four rows whose cases live in the other suites named above.
Those four are SCATTERED through the table rather than gathered at its end, so find them by the file named in their Case column and never by position - reading only the bottom of the table is how the watch-triage row gets silently skipped.
Three of the four name the file outright; the fourth is the second `tests/fm-inactive-reconcile.test.sh` row, whose Case column reads `the same case` and inherits the file from the row above it.
Running any of those files' whole runner list also works and is slower.

## Amended acceptance criterion: done by itself

The criterion this branch started from read "a skipped ci step never reads as done".
It was AMENDED, by the same authority that set it, to "a skipped ci step never reads as done BY ITSELF".
Recorded here because a future reader will otherwise find the code contradicting the older wording and try to restore it.

That reader is likely to find the older wording in the branch's OWN intent text, which restates criterion 1 in its superseded form.
The restatement is an error in composing the intent, not a defect in the code, and it has already sent one review round back to this settled ruling.
A forge-confirmed merge settles `done` on its own and must keep doing so; the amendment above is the governing wording wherever the two disagree.

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
No single invocation makes two calls, and the reason is now the MEMO rather than the paths.
They were claimed to be mutually exclusive and are not: a `checks-passed` run whose read comes back unconfirmed stays `working`, and a `working` run with a ci-ready status log then falls into `emit_checks_green`, which asked a second time.
That doubled every bound derived from this figure - the snapshot's recorded worst case of 3 tasks x 3s became 18s - so `crew_ask_forge` caches the answer and the bound is structural instead of an emergent property of control flow nobody re-checks.
Which paths call the forge is decided by the path, not by the word it produces: `bin/fm-crew-state.sh`'s header owns that invariant, and states why a `failed` or an `unknown` is often the RESULT of a call rather than evidence that none was made.
That is the price of the invariant, and it is the right way round: the read is cheap and bounded, while presenting abandoned work to a captain as a success is not.

## Ruled: an unconfirmed non-answer never reads done

Making the forge bound TIGHTER is only safe if failing to read the forge produces honesty rather than the false success this change removes.
That is the precondition, not a separate nicety, so it is recorded next to the bound it licenses.

A non-answer splits on ONE test, and `fm_crew_forge_answer_class` owns it: could ANYTHING ever answer, not merely did this read answer.

An UNCONFIRMED answer is `unverified`: the read timed out, `gh` was unauthenticated, or a budgeted caller skipped it with `FM_CREW_STATE_NO_FORGE`.
The answer exists and this reader does not have it, so it cannot tell an open PR from a closed one and no path resolves it to `done`.
The next read clears it, so the cost is one heartbeat.

An UNANSWERABLE answer is `unqueryable <provider>` or `unparseable`: this host has no forge client for that provider, or the url is not a recognizable PR or MR.
No read will ever answer, so refusing `done` would refuse it forever: every GitLab project and every host without `gh` would permanently lose both the ready-for-review signal and any terminal receipt.
That is a worse failure than the one the unconfirmed rule guards against - the same failure the amended criterion above already rejected once - so the run's own evidence still settles `done` there, with the detail naming the missing confirmation.

`no-pr` is the third answer, and it is reached only after `crew_pr_url` has looked in the run record, the coarse row, the task meta and the status log, so it means "this task has no PR" rather than "this reader did not look".
That distinction was previously blurred: a coarse runs-list row never carries a PR url, so a crew on that path answered "no PR to ask about" while the very status log the same invocation had already read named the PR, and `bin/fm-inactive-reconcile.sh` then dug that url out to show the captain beside the word.

What an absent PR LICENSES is a second question, and it is settled by the RECORDED TASK KIND rather than by the absent url.
The url is missing in every case, so it cannot possibly tell those cases apart, and only the kind states whether a PR was ever owed.
A SCOUT settles like `unanswerable`: it has no landing to claim by construction, its deliverable is a report, and a `done` there is not a landing claim at all.
A SHIP task does not, because a ship task exists to land a branch, so "no PR" is not an exemption from the landing question - it is that question answered badly, and it is the single place a `done` is most certainly wrong.
`fm_crew_no_pr_class` owns the split and spells out every recorded kind, with the unrecognized arm refusing `done` rather than falling through to the permissive one: a kind this reader has never heard of is not evidence that no landing was expected.

That hole was one sentence wide and had been written down.
`fm_crew_forge_answer_class` said the case "is a scout, or a task that has not opened a PR yet" - two situations named in one breath and then given one answer - so a ship crew rode the scout's exemption in code and in prose.
The rendering carried the same conflation: `no-pr` fell through to the transient arm of both detail helpers and printed "PR state unverified", which tells a reader to wait for a state that will never arrive, while the `unrecorded` arms those helpers carried were reachable from nowhere.

The rules are one idea, which is why they share an owner: withhold a verdict exactly as long as an answer could still arrive, and no longer.

### Ruled: a ship with no PR is two moments, and only the words differ

Refusing `done` for every ship task with no PR reaches further than the false landing claim it was aimed at.
It also reaches the ordinary PRE-VALIDATION moment: a crew appends `done: implementation complete, ready to validate` before firstmate hands it to no-mistakes, so no PR exists in the run record, the coarse row, the task meta or the log, and none is due yet.

The verdict for that moment was RULED to stay `unknown`, and both alternatives were rejected on the record.
Not `working`, because `crew_absorb_class` in `bin/fm-classify-lib.sh` absorbs `working` from `run-step` or `pane`, so that word would suppress the very signal firstmate needs and let the task disappear from supervision - the worst failure in this whole set.
Not `done`, because this repo defines a ship's done as "PR <url> checks green", so a pre-validation done is a DIFFERENT EVENT WEARING THE SAME WORD, which is the confusion this branch exists to end.
The crew has claimed completion and nothing has been verified, which is exactly what `unknown` says.

What did change is the DETAIL, and only the detail.
"No PR recorded anywhere, and a ship task exists to land one" reads as a defect report about a healthy task and sends a reader hunting for a PR that was never owed.
"Reported complete, not yet validated" says what the moment IS and what it invites, which is what firstmate does with it in practice: it learns of the moment from the worker's own status line and steers the task into validation.

That rewording could not be applied to the ship arm alone, and the reason is the point.
A ship task with no PR is TWO situations - the self-report above, and a run that FINISHED and recorded no PR - and one phrase for both would credit a finished run with a validation still to come.
So `fm_crew_no_pr_phrase` now takes the evidence level that already distinguishes them: `reported` is the self-report with no run behind it, and every other token in the vocabulary comes from a run.
`fm_crew_forge_suffix` carries that level for the one answer whose wording depends on which moment is being described, and every caller already held it.
Acceptance criterion 1 requires the two read differently, and the matrix row above falsifies exactly that.

This also changed what the test fixtures must say.
A case that means to assert `done` about ci evidence now has to answer the forge question explicitly, or it is really asserting the forge gate; `forge_answers_open` in `tests/fm-crew-state.test.sh` exists for that, and its comment records the coupling.
That is the same lesson the ci-padding row taught, arriving from the other direction: a fixture that leaves a second input unpinned stops testing the input it names.

## Ruled: withholding a landing claim is not the same as knowing nothing

The rule above was right and was then allowed to reach too far, and the overshoot is recorded here because it was in the DIRECTIVE, not in its implementation.

"An unverified answer must never read `done`" is correct.
Applied without a second thought to a run that had not terminated, it turned a crew in merge monitoring - green checks, an actively running step, recent activity - into `state: unknown` on every heartbeat where `gh` could not answer.
That is reproduced failure (3) of this whole change, "a demonstrably live pipeline read unknown", arriving by a new route, and a regression of accepted criterion 4.

Withholding a terminal claim and reporting liveness are DIFFERENT STATEMENTS, and both can be true at once.
"I cannot confirm this landed" does not imply "I know nothing about this crew".

So an unconfirmed answer on the green-checks path reports `working`, with the merge state named in the detail: the crew is monitoring its PR, which is exactly what it is doing.
`fm_crew_done_claim_verdict` takes that word as a parameter for precisely this reason, and the two entry points differ in nothing else - `fm_crew_reported_done_verdict` passes `unknown` because there is no run there and so nothing to be live.

`fm_crew_checks_green_verdict` was written to pass `working` unconditionally, on the claim that "liveness is a precondition of every route into it".
That claim was true of two routes and false of the third.
The ci-log-green override and `emit_checks_green` both sit inside `[ "$RUN_STATE" = working ]`, but the `outcome: checks-passed` arm fires on the outcome word alone - and `fm_crew_terminality` classifies ANY non-empty outcome as terminal - so a run that had genuinely FINISHED reported `state: working` on every unconfirmed read, with no active step and no non-terminal status behind the claim.
Liveness is now an argument rather than an assumption, and `crew_liveness` in `bin/fm-crew-state.sh` establishes it from the evidence the record carries: the daemon's own `active_steps` table first, then a non-terminal `status:` word, with an ABSENT status counting as no evidence rather than as non-terminal.

The correction above is NOT withdrawn by that, and the falsification row is paired with a case that proves it: under the mutation that hardcodes `working` again, `test_an_unconfirmed_answer_keeps_a_live_crew_working` still passes.
A demonstrably live crew still reads `working` on an unconfirmed answer.
What was removed is only the terminated run's ability to borrow that answer, and where it lands is `unknown` - the governing preference wherever the evidence does not settle it.

Making liveness an argument left one caller still asserting it, and that caller was wrong on exactly one record shape.
`emit_checks_green` passed the literal `live`, justified by the claim that every call sits under a record that "reported a non-terminal status word".
The absent-`status:` arm falsifies that claim: it maps a record with NO status word to working/"run active", while `crew_liveness` rules the same record `terminated`, on the ground that an absent status is no evidence of liveness at all.
Two functions in one reader disagreeing about one record is the self-contradiction this branch exists to remove, and the asserted side was the permissive one - an unconfirmed forge answer emitted a liveness claim the record does not support.

The full path now asks the one owner instead of restating its own answer.
The COARSE caller still passes `live`, and that is not the same mistake: its admission test was `COARSE_STATUS=running`, which is genuine liveness that `crew_liveness` cannot read, because a coarse runs-list row carries no steps table and no `status:` key at all.
The rule the two callers now share is that whoever can prove liveness states it, and nobody infers it from a control-flow position.

## Ruled: the liveness override stays shut to a run bearing an outcome word

A review round asked why `fm_crew_run_admits`' liveness override is gated on `fm_crew_terminality` saying `live`, when `fm_crew_terminality` calls ANY non-empty `outcome:` terminal - `checks-passed` included, which the section above models as a still-monitoring state.
The observation is correct and the gate STAYS, with no behaviour change; this is the record of why, so the next reader does not have to re-derive it.

The reason is that admission is ALL-OR-NOTHING.
`fm_crew_run_admits` does not admit a run for the liveness question only: once it says yes, `HAVE_RUN` is 1 and the whole record drives the answer, terminal ranking included.
The file's own header limits what liveness may buy - "Liveness admits a non-terminal verdict on its own" - and with no partial admission available, refusing a run that already bears a terminal word is the only place that limit can be enforced.
Widen it and a run this checkout cannot verify as its own can emit `failed` or `done` off one step row, which is reproduced failures 1 and 2 of this change, the second of them the destructive direction.

For the `checks-passed` case specifically, admitting it here walks back toward the fabricated-working defect removed in commit b8f36e4, described in the section above: a run that had genuinely FINISHED reported `state: working` on every unconfirmed forge read, with no active step and no non-terminal status behind the claim.
One thing must be said precisely rather than overstated: widening this single line would NOT reproduce that defect today, and only because the same commit made `crew_liveness` a second, independent barrier that would still answer `terminated`.
That is exactly why the gate now looks redundant, and it is the same shape as the absorb row in the matrix - two independent gates protecting one property, where mutating either alone changes nothing visible.
The guard that pins the property itself is `test_a_terminated_checks_passed_run_does_not_borrow_a_live_crews_answer`.

The residual is ACCEPTED rather than overlooked, and it is worth stating what it costs.
A `checks-passed` run whose head this checkout cannot resolve reads `unknown` even when an active `ci` row says it is executing, which is a handling turn against acceptance criterion 4.
Reaching it needs BOTH halves of a conjunction: a `checks-passed` run paired with a live ci step, a pairing never once recorded on this fork (see Fixture provenance below on `run_checks_passed`, whose `ci,running` row is explicitly a plausible shape rather than an observed one), AND a head this checkout cannot resolve.
Against that, `unknown` is this reader's governing preference wherever the evidence does not settle it, and the alternative is buying back a regression already paid to remove.
The trade is not worth taking, so the pendulum stays put.

The trigger for revisiting is the same one the fixture note already records: the first time a real `outcome: checks-passed` run is observed, record the ci-step status that actually accompanies it.
If that pairing turns out to be `ci,running` in the field AND the head geometry is routinely unresolvable at that moment, the conjunction above stops being theoretical and this ruling should be re-argued - by giving the override a way to admit a run for liveness ONLY, not by widening `fm_crew_terminality`, which would hand the terminal ranking the same run.

## Ruled: a failed attribution discards the run record

The forge read on the status-log `done:` path is an accepted ruling, and it had a cost that was not visible until it was paid, so it is recorded here rather than quietly patched.

`axi status` is REPO-scoped, and the model already says a `branch:` mismatch means THIS TASK HAS NO RUN, never "use that one".
The record was nonetheless left in place after a failed attribution: `RUN_SOURCE` was initialised to `full` BEFORE any ownership test ran, so a mismatch left it saying `full` over another task's record, and `crew_pr_url` read that sibling's `pr:` field.
A merged sibling PR then made this crew emit a landing claim for a PR that was never its own - the exact false-landing shape this whole change exists to remove, arriving by a route the change itself opened.

Before the ruling, a runless crew reading its own status log never consulted the run record at all, so a stale sibling record had no way to reach a verdict; routing that path through the forge gave it one.
The ruling stands - a self-reported `done` is the weakest evidence here and needs the forge most - and the price of it is that every read of the run record now has to prove ownership first.
The fix discards `RUN_OUT` and `RUN_OBJECT` at the point attribution fails, rather than testing ownership at each reader, because the next reader added would have to remember the test.

## Ruled: the source of a done claim never exempts it from the forge

The forge-read invariant was stated before it was true.
A crew with no attributed run whose status log's last line reads `done:` emitted `state: done` with no forge read at all - reachable whenever the run was reaped, aged past `FM_CREW_STATE_RUNS_LIMIT`, or failed to bind.

A worker's own `done:` line is not better evidence than a run record.
It is WORSE, because it is a self-report, and criterion 3 confirms a landing claim before it is emitted regardless of who claimed it.
The decisive argument is downstream: `bin/fm-inactive-reconcile.sh` matches the WORD and drops everything else, so `done` from a status log and `done` from a run record are indistinguishable by the time a captain sees them.
The source can never be a reason to exempt a path.

That path now asks, through `fm_crew_reported_done_verdict`.
The cost is one bounded read on a path that only fires when a `done:` line already exists.

All eight paths that can emit `done` are enumerated in `bin/fm-crew-state.sh`'s header beside the invariant, so the next reader checks a list rather than re-deriving one.
The invariant itself is worded about the CALL and not the ANSWER, deliberately: `unanswerable` and a kind-permitted `no-pr` still settle `done` without a confirmation, and a sentence that claimed otherwise would be the sixth false invariant this branch has had to correct.

## Forge-read bound

`fm_crew_forge_pr_state` is the only outbound call this reader makes, and `FM_CREW_STATE_FORGE_TIMEOUT` bounds it.
The library default is 10 seconds and every caller with a fleet to get through narrows it: 3 seconds in `bin/fm-fleet-snapshot.sh`, and at most a third of what remains in `bin/fm-inactive-reconcile.sh`.
The loose default is for the interactive single-task read, where one person is waiting for one answer and a slow answer is cheaper than a wrong one.
Deliberately keeping the default and the narrowed bound at DIFFERENT numbers is also what makes the snapshot's choice falsifiable at all, as the matrix note above records.

The measurements both bounds rest on, on 2026-08-22:

Command: `gh pr view <n> --repo <owner/repo> --json state,mergeStateStatus`, against a real GitHub PR, five consecutive runs.
Elapsed: 0.53s, 0.59s, 0.59s, 0.61s, 0.53s.

Worst case 0.61s, so 3s is roughly five times the worst observed call.
An independent re-measurement on 2026-08-23, 15 sequential calls of the same shape against this repo, ranged 0.55s to 0.96s with a worst observed call of 0.96s and a typical ~0.60s, which 3s still covers at about 3x.
The spread between the two sessions is why the headroom is a multiple of the worst observation rather than a small margin on it, and `bin/fm-fleet-snapshot.sh` records the same two figures where it pins its own per-task bound.
That is one host with warm `gh` auth: the figure is a headroom choice, not a latency guarantee, and a cold or unauthenticated `gh` is exactly the case the bound exists for.
What the choice protects is the caller, not the call: `bin/fm-inactive-reconcile.sh` runs `bin/fm-crew-state.sh` inside a 10-second aggregate budget for a whole scan, so a bound equal to that budget lets one hung call starve every remaining child.
At 3 seconds a fully hung call leaves that scan most of its budget, and the scan narrows the bound further to at most a third of what it has left, skipping the read entirely when the remainder cannot spare a whole second.
Skipping is safe by construction: an unread merge state is a TRANSIENT non-answer, and no path resolves one to `done` at all, let alone to a landing.
That is the precondition recorded above, and it is what makes any of these bounds safe to tighten - shortening the wait trades a delayed receipt for a delayed one, never for a false one.

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

The same unobserved shape is why `run_checks_passed_terminated` exists beside it rather than replacing it.
`run_checks_passed` pins `status: running`, which is what a monitoring run looks like, and that single fixture was what made the borrowed liveness claim look safe: no case in the suite held a checks-passed run that had TERMINATED, so nothing could see the verdict that shape produced.
The second fixture pins `status: completed` with no active step, and the two are kept together because the verdict now differs between them and one fixture cannot show a difference.
Neither is a claim about which shape a real `checks-passed` run has - the rule is falsified against BOTH, so whichever one turns out to be real, the answer for it is already pinned.

`run_running_other_task_with_pr` is synthetic and is the one fixture whose whole content is a foreign task's: a live run on another branch carrying a real PR url.
Every earlier fallback fixture carried an empty `pr:`, which is precisely why the sibling-PR leak was invisible to the suite for as long as it was.

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
