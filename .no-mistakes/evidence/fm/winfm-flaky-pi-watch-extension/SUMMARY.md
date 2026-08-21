# Local validation of fm/winfm-flaky-pi-watch-extension

Workstation: 22-core Linux (WSL2), node v22.23.2, bash 5.2.21.
Base = `1baa477` (pre-fix), fixed = `c95cf43` (frozen worktree snapshot).

## 1. The flake does NOT reproduce at this workstation's native fork cost

`tests/fm-pi-watch-extension.test.sh` measures an 11-15 ms child start here, so both
trees pass unloaded. The defect is only reachable once a child start costs what a
loaded runner charges, so it was reproduced with a `bash` shim that makes every
`bash` start pay a fixed cost (`.fm-repro/slowbin/bash`, transient, removed after).

## 2. Reproduced, then fixed, on the exact assertion CI reported

At a 0.3 s shim (measured child start ~630 ms, in the 300-800 ms band the
verification doc records for a loaded runner):

```
FM_TEST_SUMMARY BASELINE_PI_HUNG (1baa477 test file): pass=0 fail=25 of 25
  not ok - Pi must deliver the actionable wake after bounded hung-successor recovery
FM_TEST_SUMMARY BASELINE_OC_HUNG (1baa477 test file): pass=0 fail=25 of 25
  not ok - OpenCode must deliver the actionable wake after bounded hung-successor recovery
FM_TEST_SUMMARY FIXED_PI_HUNG (c95cf43 test file):    pass=25 fail=0 of 25
FM_TEST_SUMMARY FIXED_OC_HUNG (c95cf43 test file):    pass=25 fail=0 of 25
```

"Pi must deliver the actionable wake after bounded hung-successor recovery" is the
assertion named in the original report.

## 3. Twenty-five consecutive whole-file runs from the frozen snapshot

```
FM_TEST_SUMMARY FIXED_WHOLE_FILE (native fork cost, frozen snapshot c95cf43): pass=25 fail=0 of 25
```

32 `ok -` assertions per run, no `not ok`.

## 4. The bound tracks the measurement instead of a literal

One run of the Pi hung-successor case per fork-cost level, first line printed by the
suite itself:

| shim | measured child start | derived readiness budget | derived slack | verdict |
|---|---|---|---|---|
| none  | 11-15 ms | 500 ms (floor) | 1000 ms (floor) | ok |
| 0.02s | 67 ms   | 500 ms (floor) | 1000 ms (floor) | ok |
| 0.1s  | 230 ms  | 1150 ms        | 1000 ms        | ok |
| 0.15s | 331 ms  | 1655 ms        | 1000 ms        | ok |
| 0.3s  | 632 ms  | 3160 ms        | 1896 ms        | ok |
| 0.8s  | 1634 ms | 8170 ms        | 4902 ms        | ok |

That is a 148x span of measured fork cost with no failure. Baseline over the same
span: pass at 0.02/0.05/0.1 s, `0/5` at 0.3 s and `0/5` at 0.8 s - the crossing the
doc predicts near a 333 ms start.

Total fixed-tree runs scored here with zero failures: 100
(25 whole-file + 25 Pi hung + 25 OpenCode hung + 25 across the fork-cost span).

## 5. Sibling cases whose CI failure was never observed also cross with literals

At a 0.8 s shim (1631 ms measured start): baseline fails
`Pi established clean closes must honor the continuity retry limit`, fixed passes
both retry-limit cases. With `ps` slowed to 200 ms instead, baseline fails
`OpenCode watch plugin must arm only when this session owns the fleet lock`,
fixed passes. Both reproduce the counterfactuals recorded in
`docs/verification/watcher-arm-test-budgets.md`.

## 6. The EPIPE defect: all three sites fail before the fix, pass after

Guarded (current tree): the operational-input case and both turn-end guard cases pass.
With `child.stdin.on("error", ...)` deleted from each site in turn, each corresponding
case fails with the production crash (`Unhandled 'error' event` / `write EPIPE`),
not with a timing flake. The tree was restored after every counterfactual.

## 7. Shard overflow: packing scored under one weight table

Same 116-script serial inventory, same LPT algorithm, refreshed measured weights
applied to the shard membership each tree produces:

| shard | base (stale 1baa477 hints) | fixed (refreshed c95cf43 hints) |
|---|---|---|
| 1 | 10.91 min | 10.58 min |
| 2 | 7.76 min  | 10.58 min |
| 3 | 10.25 min | 10.58 min |
| 4 | 13.41 min | 10.58 min |
| **worst** | **13.41 min** | **10.58 min** |

`timeout-minutes: 15` is unchanged in `.github/workflows/ci.yml` (comment-only edit).
`--check-coverage` reports `unmeasured_serial=0`, and when an unhinted script is
present it is named on stderr while the guard still exits 0 (report, never refuse).

## 8. The weight hint this change stales, measured

Whole file, all 32 assertions ok both times:

| fork cost | measured start | duration | hint |
|---|---|---|---|
| native | 14 ms | 20715 ms | 27802 ms |
| 0.15 s shim | 331 ms | 70894 ms | 27802 ms |

At the CI-measured 328-331 ms start the file runs ~43 s over its hint, inside the
29-76 s the verification doc records, and it sits in shard 3 (10.58 min packed,
11.67 min measured on CI) - still under the 15 min cap.
