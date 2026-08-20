# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-07-29 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 52939 | `tests/fm-x-mode.test.sh` |
| 48294 | `tests/fm-backend-herdr.test.sh` |
| 46788 | `tests/fm-arm-pretool-check.test.sh` |
| 34207 | `tests/fm-cd-pretool-check.test.sh` |
| 30771 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 25365 | `tests/fm-crew-state.test.sh` |
| 15674 | `tests/fm-test-run.test.sh` |
| 15422 | `tests/fm-herdr-lab.test.sh` |
| 9065 | `tests/fm-composer-ghost.test.sh` |
| 8564 | `tests/fm-pr-merge.test.sh` |
| 6251 | `tests/fm-grok-harness.test.sh` |
| 5644 | `tests/fm-send-popup-settle.test.sh` |
| 5237 | `tests/fm-lint.test.sh` |
| 4816 | `tests/fm-tmux-submit-busy.test.sh` |
| 2945 | `tests/fm-pi-primary-types.test.sh` |
| 2911 | `tests/fm-send-settle.test.sh` |
| 2875 | `tests/fm-review-diff.test.sh` |
| 2747 | `tests/fm-send-strict.test.sh` |
| 2224 | `tests/fm-brief.test.sh` |
| 855 | `tests/fm-spawn-batch.test.sh` |
| 703 | `tests/fm-supervision-instructions.test.sh` |
| 581 | `tests/fm-ensure-agents-md.test.sh` |
| 248 | `tests/fm-transition-lib.test.sh` |
| 64 | `tests/fm-composer-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 162436 ms (~162.4 s) |
| `portable-parallel-2` | 13 | 162754 ms (~162.8 s) |
| imbalance | | 318 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The hints came from the `fm-test-timing-portable-serial` artifacts of green run [32159215212](https://github.com/mgoyal8293/firstmate-windows/actions/runs/32159215212) on 2026-08-19, where the lane ran 116 scripts in 2539694 ms of serial work.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.

Hints affect balance, not coverage: the coverage guard keeps the partition complete and disjoint whatever they say.
Past the job cap, however, a stale hint stops being merely a slower shard.
A shard that overruns `timeout-minutes` is cancelled and reports no verdict at all, which a required check can never turn green and which is indistinguishable from a hang.
That is what happened on 2026-08-19, through two mechanisms that are easy to conflate and are not the same.

The lane total was under-counted by stale values on scripts that already had hints.
Those 71 scripts were packed at 1147781 ms against a real 1744890 ms, hiding 597 s: `tests/fm-session-start.test.sh` was hinted at 37289 ms and measures 152852 ms, `tests/fm-teardown.test.sh` at 23237 ms against 94337 ms, `tests/fm-sessionstart-nudge.test.sh` at 264 ms against 67672 ms.
The 45 scripts with no hint were, in aggregate, packed slightly high rather than low: 45 x 20000 = 900000 ms against a real 794804 ms, 105 s of slack.
So packing believed the lane was 2047781 ms (34.13 min, 8.53 min per shard) against a real 2539694 ms (42.33 min, 10.58 min per shard), and the whole 8.20-minute undercount came from stale values on already-hinted scripts, not from the unhinted set.

Per-shard balance went wrong for the other reason.
An unhinted script is packed at the flat default wherever its real duration sits, so `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` went into a bin sized for 20 s carrying 157 s of work, misplacing 137 s into one shard.
That is why shard 4 specifically overflowed while the lane total was under-counted at the same time.
On red run [32142691561](https://github.com/mgoyal8293/firstmate-windows/actions/runs/32142691561) on `main` the day before, the measured spread was 7.72 minutes for shard 2 to 14.68 minutes for shard 4 against a packing that believed all four were 8.5 minutes.

This overflow was accumulated serial runtime, not the fork-cost sensitivity behind the watcher-suite flake of the same week; `docs/verification/watcher-arm-test-budgets.md` owns that ruling.

`bin/fm-test-run.sh --check-coverage` reports `unmeasured_serial=<n>` and names any selected serial script still packed at the flat default, so a missing measurement is visible in every CI run rather than surfacing later as an unbalanced shard.
Read that counter for exactly what it says.
It reports whether any selected serial script is packed at the default, so `unmeasured_serial=0` means no script is packed at the default - it does **not** mean the hints are current.
An already-hinted script can quadruple while the count stays at zero, which is what happened here: the lane's script count was stable, the count was zero throughout, and most of the hidden time was in values the guard never looks at.
Nothing currently detects a stale value on a script that already has a hint; `fm-test-weight-drift-detector` is the filed follow-up that will compare measured durations against the table.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of4` | 30 | 634929 ms (~10.58 min) |
| `portable-serial-2of4` | 30 | 634931 ms (~10.58 min) |
| `portable-serial-3of4` | 30 | 634917 ms (~10.58 min) |
| `portable-serial-4of4` | 26 | 634917 ms (~10.58 min) |
| imbalance | | 14 ms |

Those four numbers are the packer's own arithmetic over the table above, not a measurement.

Measured on green run [32259417831](https://github.com/mgoyal8293/firstmate-windows/actions/runs/32259417831), the first real lane run with the refreshed hints: all four shards passed, the worst shard fell to 11.67 min from the 13.43 min it took on run [32159215212](https://github.com/mgoyal8293/firstmate-windows/actions/runs/32159215212) - the run whose artifacts supplied these weights - and the spread roughly halved.
The overflow was removed rather than relocated - no other shard took up the time the worst one gave back.
The two "before" figures above are two different runs, not one quantity stated twice: 14.68 min is shard 4 on red run 32142691561, and 13.43 min is the worst shard on green run 32159215212.

Script time alone does not reach the cap, which is why the weights are only most of the story.
The job wall clock adds runner setup and checkout on top of it.
On run 32142691561, `Behavior portable serial 4` ran 13:29:51Z to 13:44:41Z - 14m50s of wall clock against 14m41s of script time, about 9s of overhead.
The job that was actually cancelled is run [32222210223](https://github.com/mgoyal8293/firstmate-windows/actions/runs/32222210223) on `fm/winfm-tmux-leakage`, where the same shard ran 06:09:14Z to 06:24:29Z - 15m15s of wall clock, conclusion `cancelled`, no verdict at all.
Script time was already within roughly 20 seconds of the cap and ordinary job overhead tipped it over, so judge the remaining margin against script-time weights with that overhead included.

The single longest script in the lane, `tests/fm-pr-check-security.test.sh` at 236511 ms, is the floor for any shard count.
It was already hinted before the 2026-08-19 refresh, so it was never part of the unhinted set above.

Refresh the hints by downloading the per-shard timing artifacts from a green CI run, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the measured `path`/`duration_ms` pairs, and updating the table above:

```sh
gh run download <run-id> -R mgoyal8293/firstmate-windows --pattern 'fm-test-timing-portable-serial-*' -D /tmp/fm-serial
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*.json | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

Refresh from a green run, because a lane that failed part-way records a truncated duration for the script that failed.
Refresh whenever `--check-coverage` reports a non-zero `unmeasured_serial`, whenever the lane has grown, whenever a shard's measured duration approaches the job cap, and otherwise periodically.
A zero `unmeasured_serial` is not an all-clear: it says only that no script is packed at the default, and nothing yet detects a stale value on a script that already has a hint (`fm-test-weight-drift-detector`).

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports, rather than refuses, `unmeasured_serial=<n>` and the names behind it: a newly added test legitimately has no measured duration until it has run once, but an unmeasured script is packed as if it were average, and enough of them unbalance a shard.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-4 | job `timeout-minutes: 15` | The measured worst shard on run [32259417831](https://github.com/mgoyal8293/firstmate-windows/actions/runs/32259417831) was 11.67 minutes of script time, so the cap is a hang tripwire with about 1.3x margin - and the job wall clock adds runner setup and checkout on top of that, which is what tipped the cancelled job over. Refresh the weights, or split the lane further, before that margin is spent. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finish around 7 minutes, so the step bound is the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
