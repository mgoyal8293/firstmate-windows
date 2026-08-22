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
61
```

The count is the evidence, not the exit status: a green step does not prove its assertions ran.

## Falsification matrix

Each row removes one guard from a throwaway copy of the tree and runs the single case that claims to protect it.
Every row must fail, and must fail on the named assertion.

| Guard | Mutation | Case | Result |
| --- | --- | --- | --- |
| Only the branch's newest run row is ever examined | let the runs list be scanned past the newest row, taking the first row whose sha binds | `test_superseded_failed_row_does_not_mask_live_row` | fails: `missing: 'state: working'` |
| An unfetched pipeline head still admits a live verdict | `unresolvable` admits nothing | `test_superseded_failed_row_does_not_mask_live_row` | fails: `missing: 'state: working'` |
| An unfetched pipeline head never admits a terminal verdict | `unresolvable` admits everything | `test_terminal_run_at_unfetched_head_is_not_attributed` | fails: `unexpected: 'source: run-step'` |
| An executing step attributes its run regardless of head geometry | drop the liveness override | `test_live_active_step_attributes_run_despite_head_geometry` | fails: `missing: 'state: working'` |
| A skipped `ci` step is never validation | compare the ci step against a status it never has | `test_ci_skipped_pass_never_reads_as_done` | fails: `unexpected: 'state: done'` |
| A merged or closed claim comes only from the forge | restore the `run passed: PR merged/closed` detail | `test_open_pr_is_never_reported_as_merged` | fails: `missing: 'not merged'` |
| An unanswered forge is never rendered as a landing | restore the same detail | `test_unanswered_forge_never_claims_a_landing` | fails: `missing: 'unverified'` |
| `active_steps` columns are split quote-aware | stop treating `"` as a quote | `test_live_run_at_unfetched_head_is_not_replaced_by_older_failed_run` | fails: `missing: 'last activity 3m11s ago'` |
| A proven pipeline head admits its run's terminal verdict | drop the ownership proof | `test_terminal_run_at_proven_pipeline_head_is_attributed` | fails: `missing: 'state: failed'` |
| Ownership requires `pipeline.run` to be this run | drop that equality | `test_branch_sync_for_another_run_does_not_prove_ownership` | fails: `unexpected: 'source: run-step'` |
| Ownership requires the pipeline head to be this run's head | drop that equality | `test_branch_sync_for_another_head_does_not_prove_ownership` | fails: `unexpected: 'source: run-step'` |
| Ownership requires `local.head` to be this checkout | drop that equality | `test_branch_sync_for_another_checkout_does_not_prove_ownership` | fails: `unexpected: 'source: run-step'` |

12 of 12.

The first two rows share a case deliberately: both guards sit on the runs-list path, and the case needs both to hold - one stops the dead run being reached, the other makes the live run usable.
The 7-character floor in `fm_crew_sha_matches` is deliberately absent from the table: it is defensive against a degenerate abbreviation and has no observed trigger, so there is no honest case to pin it with.

## Reproducing the matrix

The mutations are ordinary one-line edits to a copy of `bin/`; nothing in the tree needs to change to re-derive them.
For each row, copy the tree to a scratch directory, apply the mutation named above, run the one case, and confirm it fails on the named assertion.
The case names are the functions in `tests/fm-crew-state.test.sh`; running the file's whole runner list also works and is slower.

## Fixture provenance

The run records in those cases are recorded output from real runs on this fork, not invented shapes:

| Fixture | Run | What it captures |
| --- | --- | --- |
| `run_passed_ci_skipped` | `01M0JMD3H94MKKF7SCM5C5QWR6` | `outcome: passed` with `ci,skipped`, PR open and conflicted |
| `run_passed_ci_completed` | `01M0JASXQ1H4Q5YAZYJT03F1HN` | the same outcome word with `ci,completed` |
| `run_failed_at_local_head` | `01M0EFHKF1A3CJX4KK58HWJ7D2` | the terminal-failed run that masked a live one |
| `run_live_active_step` | `01M0N8J9ET64CBM89W4D663WBZ` | a live `active_steps` row, including its quoted comma-bearing `last_activity` |
| `branch_sync_block` | `01M0N8J9ET64CBM89W4D663WBZ` | the `branch_sync:` field set and shape, read from that run's own task worktree |

`make_pipeline_ahead_topology` builds the geometry those cases need for real - a task worktree plus a separate clone standing in for the pipeline's own - so the run head under test is a genuine commit the checkout cannot resolve rather than a made-up sha.

## Run listings

Both were verified on 2026-08-22 against `no-mistakes` v1.48.0, because run selection depends on which one can find a branch's run:

| Listing | Run ids | Reach |
| --- | --- | --- |
| bare `no-mistakes axi` home view, `runs[N]{id,branch,status,head,pr}` | yes | capped at the 10 most recent runs repo-wide (`count: 10 of 21 total`), no limit flag |
| `no-mistakes runs --limit N` | no | arbitrary, newest-first plain text |

Selection uses the second because finding the branch's run at all outranks richer detail about it.
The first would allow a follow-up `axi status --run <id>` and so give that path the same full step, activity and `branch_sync` evidence the `axi status` path gets, which a coarse row cannot carry; that upgrade is named in `bin/fm-crew-state.sh` as follow-up work rather than done here.

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
