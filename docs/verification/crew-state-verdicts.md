# Crew-state verdict guards: falsification record

Maintainer-verification record for the guards in [`bin/fm-crew-run-verdict-lib.sh`](../../bin/fm-crew-run-verdict-lib.sh), which that file's header owns.
Its purpose is narrow: prove the regression cases in `tests/fm-crew-state.test.sh` are not vacuous.
A guard whose test passes with the guard removed protects nothing, and this repo has shipped that mistake before.

Refresh this record by re-running the two commands below after any change to run selection, code binding, or the terminal-pass evidence gates.

## Suite

Date: 2026-08-22.
Base: `7eb1816`.
`no-mistakes` v1.48.0, `gh` 2.x, ShellCheck 0.11.0.

```
$ bash tests/fm-crew-state.test.sh | grep -c '^ok'
57
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

8 of 8.

The first two rows share a case deliberately: both guards sit on the runs-list path, and the case needs both to hold - one stops the dead run being reached, the other makes the live run usable.

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

`make_pipeline_ahead_topology` builds the geometry those cases need for real - a task worktree plus a separate clone standing in for the pipeline's own - so the run head under test is a genuine commit the checkout cannot resolve rather than a made-up sha.
