# Watcher arm test budget verification

Repeatable evidence for the two timing guarantees the tracked watcher arm suites depend on.
Current behavior of the Pi extension and the OpenCode plugins is owned by their own sources; this page records evidence only.

Date: 2026-08-19.
Node: v22.23.2 on both machines.
Comparison base: `main` at `1baa477`.

## Why a measured budget replaced a literal

`tests/fm-pi-watch-extension.test.sh` compresses the extension's arm-readiness budget, because a successor that hangs is detected only by that budget expiring, once per retry.
The compressed value has to outrun a full cold child start: the extension launches every arm as a login `bash -l`, which sources the system profile before exec'ing the arm script, and the script's first append is what the arm-count assertions read.
When the budget expires first the extension SIGTERMs a successor that has not recorded itself, so the row is lost and the count comes up short.

The literal 250ms cleared that start by roughly 18x on a developer workstation and by less than 1x on a busy CI runner, which is why the failure only ever appeared on CI.

Cost of one cold arm child start, measured with the extension's own spawn shape, `n=120` per row, against the former 250ms literal:

Recorded from a throwaway instrumentation branch that spawned the extension's exact command line and timed it to the arm script's first append, with background spinners standing in for concurrent work on the runner:

```console
# ubuntu-latest, 4 vCPU
LOADCURVE spinners=0  n=120 p50=100 p90=102 p99=133 max=160 over250=0
LOADCURVE spinners=2  n=120 p50=145 p90=148 p99=156 max=173 over250=0
LOADCURVE spinners=4  n=120 p50=300 p90=315 p99=326 max=331 over250=118
LOADCURVE spinners=8  n=120 p50=406 p90=448 p99=487 max=504 over250=120
LOADCURVE spinners=16 n=120 p50=663 p90=759 p99=797 max=800 over250=120
```

The same measurement on a 22-core developer workstation returns `p50=14 max=17` idle and `max=82` under 2x oversubscription, never within 3x of the literal.
That gap is the whole defect: the bound was sized on hardware where process creation is nearly free.

Reproduction of the resulting failure on `ubuntu-latest`, with four background spinners standing in for the rest of a serial shard:

```console
$ PI_HUNG_LOADED_FAILS=150/150
$ WHOLE_FILE_LOADED_FAILS=10/10
Error: expected one successor plus two retries, got 1: arm=65314
```

Every successor was killed before it recorded itself, leaving only the first arm's row.
Unloaded, the same case passed `80/80` and the whole file passed `12/12` on the same runner image, which is why the failure looked intermittent rather than deterministic.

The suite now measures the start cost at load time and keeps five times the worst of five samples, never below 500ms.
Oversizing is safe by construction: the fixtures never emit an established line for a successor, so readiness cannot resolve true however long the budget is, and the budget only decides how long each case waits.

The calibration blocks on the child while the extension's real path observes it asynchronously, so it was checked against that real path rather than assumed equivalent.
Under 3x oversubscription on the workstation, over 40 paired samples, the calibration read `p50=25 max=59` where the asynchronous spawn-to-first-append path read `p50=30 max=61`.
It under-reads by about a fifth at the median and by a twentieth at the tail, which the five-times multiplier absorbs.

### Result

Twenty-five consecutive runs of each affected suite from a frozen checkout at `9a20f7c`, workstation:

```console
PI_WATCH_EXTENSION pass=25 fail=0 of 25
OPERATIONAL_INPUT  pass=25 fail=0 of 25
```

The calibration was stable across those runs, reading 12ms to 17ms and resolving to the 500ms floor every time.
A workstation cannot falsify this defect on its own, because the pre-fix suite also passed 232 consecutive runs here, including under single-CPU contention; the runner rows above are the evidence that matters.

### The fork-cost hypothesis, ruled on

A recorded hypothesis held that this flake was the same fork-cost sensitivity that forced the portable serial lane to be sharded.
It is half right.

Fork cost is the load-dependent input driving the test flake: the child start measured above at 14 ms on a workstation against 300-800 ms under runner load is what overran a fixed observation window.
Fork cost is not what forced the sharding.
That was accumulated serial runtime - stale weight values on already-hinted scripts plus lane growth - recorded in `docs/fm-test-portable-shards.md`.
The two failures share a runner-load flavour, but they have different causes and different fixes, and neither fix would have prevented the other failure.

## Why the session-lock case settles its refusal instead of pausing

The same suite failed a second way, on the same underlying quantity.

`test_opencode_primary_watch_plugin_requires_session_lock` fires two `session.idle` events, the first with a lock this session does not own and the second with one it does.
The plugin's event hook starts the arm decision without awaiting it, and refusing an unowned lock walks the parent-pid chain in `sessionOwnsLock`, spawning `ps` up to eight times.
Each of those spawns costs what a whole child start costs, so on a loaded runner the refusal was still in flight when the case rewrote the lock 120ms later.
`ensureArm`'s single-flight guard then handed the second event the first evaluation's `read-only` result rather than re-deciding, the arm never ran, and the case reported `watch arm did not run after the session lock matched`.

The 120ms pause was the whole dependency: it is longer than eight local spawns and shorter than eight loaded ones.

Counterfactual, with `ps` slowed to 200ms to stand in for what load does to a spawn:

```console
$ PATH=<slow-ps>:$PATH bash <case>          # baseline 1baa477
not ok - OpenCode watch plugin must arm only when this session owns the fleet lock

$ PATH=<slow-ps>:$PATH bash <case>          # fixed
ok - OpenCode watcher plugin requires session lock ownership
```

The case now settles the decision through the coordinator, which coalesces onto the same in-flight evaluation and resolves when it does, so the owned-lock event starts from a finished verdict.
It also asserts the refusal itself, which the pause only implied.

### Result

On `ubuntu-latest` under four background spinners, run [32224627637](https://github.com/mgoyal8293/firstmate-windows/actions/runs/32224627637):

```console
SESSION_LOCK=0/150
OPERATIONAL_INPUT=0/25
```

## Why the observation window is derived from the same measurement

Measuring the budget moved the failure rather than removing it, because the budget was only one of two bounds on the same operation.

A hung successor is detected only when the budget expires, once per retry, so a case with `FM_WATCH_REARM_RETRY_LIMIT=2` cannot deliver its wake until three budgets, three retirements and two backoffs have elapsed, plus the child starts around them.
Every driver that waited for that result used a literal `for (let i = 0; i < 500; i += 1)` with a 10ms sleep, about five seconds.
The budget moves with the machine and that window did not, so the two crossed at roughly `(retryLimit + 1) x 5 x child start` against `500 x 10ms` - a child start near 333ms.

On run [32224627637](https://github.com/mgoyal8293/firstmate-windows/actions/runs/32224627637), 150 runs of the case under four background spinners:

```console
PI_HUNG=92/150
# arm child start 328ms measured, readiness budget 1640ms
Error: no wake delivery was observed at all; arm log holds 4 rows
```

All 92 failures carry that identical message, and `arm log holds 4 rows` in every one of them is what rules the budget out: each attempt launched and recorded itself, so nothing was killed early and it was the test's own clock that ran out.
The measured child start across those 92 failures spans 313-352ms, mean 324ms, and the 58 passing runs are below it.

Counterfactual on a workstation, with `bash` shimmed so the extension's own spawn shape pays a runner's fork cost:

```console
$ bash <case>          # baseline, 415-424ms child start
not ok - Pi must deliver the actionable wake after bounded hung-successor recovery
Error: no wake delivery was observed at all; arm log holds 4 rows

$ bash <case>          # derived observation window, same fork cost
ok - Pi hung successor falls back to one typed actionable wake
```

Each case that compresses the budget now derives its deadline from the same measurement, through `fm_recovery_deadline_ms`.
These are upper bounds on waiting rather than sleeps: every driver stops the moment its event lands, so sizing one from the worst case costs nothing on the passing path and only bounds how long a genuine failure takes to report.

### Result

On `ubuntu-latest` under four background spinners, run [32255813826](https://github.com/mgoyal8293/firstmate-windows/actions/runs/32255813826), which scored the same load against both trees:

```console
BASELINE_PI_HUNG=116/150
BASELINE_OC_HUNG=150/150
FIXED_PI_HUNG=0/150
FIXED_OC_HUNG=0/150
FIXED_WHOLE_FILE=0/25
```

Counters read from the run log, not inferred from step colour.

On a workstation, from frozen snapshots, across four fork-cost levels between 10ms and 621ms of child start: 150 consecutive runs of the fixed tree with no failures, against 70 consecutive baseline runs with no passes at 415ms and above.

### The OpenCode arm crosses at the same point

One residual signature took a self-describing assertion to isolate: a wake apparently delivered before any arm had recorded a row, three times in 150 runs.
The ambiguous count meant "no delivery was observed", not "a delivery saw an empty log", and once it said which, it was this same crossing on the OpenCode arm, whose plugin carries the same readiness, retire, backoff and retry-limit defaults and whose driver carried the same literal window.
It is reproduced deterministically by the counterfactual above and passes 150/150 on the runner alongside the Pi case.
An assertion that reports which of two states it saw is what makes a derived bound diagnosable; one that reports only a count is not.

### Every bound coupled to a measurement must be derived from it

When a test bound is derived from a measurement, every bound coupled to it must be derived from the same measurement.
Fixing one side of a two-sided constraint moves the failure; it does not remove it.
A derived bound must also print what it derived, which is what makes it diagnosable from a CI log rather than only from another reproduction.

Applied to the whole file rather than only the cases that failed: every window in `tests/fm-pi-watch-extension.test.sh` that waits on a chain of cold arm children now sizes itself as `<chained child starts> * FM_TEST_ARM_START_BUDGET_MS + FM_TEST_OBSERVE_SLACK_MS`, counting every start in its chain rather than assuming the first lands before the window opens.
The tightest of those was the retry-limit pair, which allowed a literal 250 x 10ms for three chained starts and therefore crossed near 830ms.

Counterfactual on a workstation, with `bash` shimmed so every arm child pays a runner's fork cost, both trees scored on the same shim:

```console
# arm child start 817ms measured, readiness budget 4085ms
$ bash tests/fm-pi-watch-extension.test.sh          # literal windows
not ok - OpenCode established clean closes must honor the continuity retry limit
Error: retry exhaustion was not surfaced:

# arm child start 813ms measured, readiness budget 4065ms
$ bash tests/fm-pi-watch-extension.test.sh          # derived windows
ok - Pi established clean closes stop at the configured retry limit
ok - OpenCode established clean closes stop at the configured retry limit
```

The negative windows moved too - the ones that watch for an arm that must not appear.
A 100ms settle cannot observe an unwanted child that needs 300ms to record itself, so those windows were widest exactly where they were least able to catch anything; each is now one start budget.
Those eight are settle sleeps rather than polled windows, so unlike every other window in the file they are paid in full on the passing path, and the file's comment block says so where a reader will hit it.

The additive term moved for the same reason as the multiplicative one.
`FM_TEST_OBSERVE_SLACK_MS` covers module load, lock checks and prompt delivery, which are per-case process costs and scale with the machine exactly like fork cost, so leaving it a flat 1000 pinned a floor under every window in the file - the one term that would not move with the machine.
It is now three measured cold starts, floored at the 1000ms this evidence was collected at, so a loaded runner widens it and no machine narrows it below the configuration measured above.

Poll cadence is derived from the window too.
A derived window polled at a fixed 10ms gets noisier the slower the machine is: 590 wakeups at the 328ms start measured here and about 1300 at 800ms, each with a `readFileSync` or `existsSync` behind it, on the machine whose load is the thing being measured.
Each poll is now the window divided by `FM_TEST_OBSERVE_POLL_DIVISOR`, which holds it at 64 wakeups per window on any machine.
That buys detection granularity proportional to the window - one 64th of it - instead of an absolute 10ms, and it widens nothing, because every deadline is still computed from the window rather than from the poll.

### Which windows got tighter, and why that is accepted

Deriving every window from one measurement moved most of them in both directions at once, and on a fast machine most of the movement is inward.
The narrower direction is unmeasured - only the wider direction was ever exercised, by the load campaigns above - and it is accepted deliberately rather than reversed, because reversing it would mean re-introducing a literal and that is the defect being fixed.
All 33 polled windows in the file are listed below at the 14ms fork cost of the workstation, where a start budget is its 500ms floor and the slack is its 1000ms floor.

| Before | After | Count | Change |
|---|---|---:|---|
| `250 x 20ms` = 5000ms | 1500ms (one start) | 9 | 3.3x narrower |
| `250 x 20ms` = 5000ms | 2000ms (two starts) | 1 | 2.5x narrower |
| `500 x 10ms` = 5000ms | 1558ms (`fm_recovery_deadline_ms 1 20`) | 6 | 3.2x narrower |
| `500 x 10ms` = 5000ms | 2000ms (two starts) | 1 | 2.5x narrower |
| `500 x 10ms` = 5000ms | 1500ms (one start) | 1 | 3.3x narrower |
| `500 x 10ms` = 5000ms | 5586ms (`fm_recovery_deadline_ms 3 1000`) | 2 | 1.1x wider |
| `250 x 10ms` = 2500ms | 2000ms (two starts) | 6 | 1.25x narrower |
| `250 x 10ms` = 2500ms | 1500ms (one start) | 1 | 1.67x narrower |
| `250 x 10ms` = 2500ms | 2500ms (three starts) | 2 | unchanged |
| `100 x 10ms` = 1000ms | 1500ms (one start) | 4 | 1.5x wider |

So 25 of the 33 node windows are tighter on a workstation than the literals they replace, 6 are wider and 2 are unchanged.
The widest single narrowing is 3.3x, on the nine one-start waits that observe an arm child recording its first row: the external-healthy prompt wait, the owned-lock arm wait, the process-exit child and replacement waits, the three OpenCode arm-log waits, the guard-coordination arm wait, and `waitFor`'s former `attempts = 250` default.
The two windows that widened by design are the hung-successor recovery deadlines, which are the ones that were actually crossing on CI.

The narrowing is a property of a fast machine, not of the fix.
A one-start window is `5 x start + max(1000, 3 x start)`, so it is below the 5000ms literal it replaced for any measured start under 625ms and above it beyond that.
At the 328ms start measured on run 32255813826 a one-start window is 2640ms, still 1.9x tighter than the literal; at the 800ms start in the load curve it is 6400ms, 1.3x wider.
That is the intended shape - the events these windows wait for are one cold child start, so a machine that forks in 14ms should not be given 5s to notice - but no campaign has scored the tighter direction, so it is recorded here as accepted and unmeasured rather than presented as measured.

The last bound of this class was waited on from bash rather than from a node driver: a literal 250 x 20ms giving 5s to observe the arm child's TERM trap appending to the cleanup log.
It is derived now for the same reason as its siblings, as `fm_observe_window_ms 1 1000` - one cold start plus the 1s the fixture's own `while :; do sleep 1; done` defers the trap by.
It was not derived because it had failed: the deferral is about 1.8s at an 800ms fork cost, roughly 2.8x inside the literal, and no false red on it was ever observed.
On a workstation that derivation narrows the bound from 5s to 2.5s, which is accepted and unmeasured - only the wider direction was ever measured here, so the narrowing is recorded rather than widened back, and the margin it keeps is 2.4x against a deferral that is 1s fixed plus one measured start.

One bound in this file runs the other way: it has to OUTRUN a derived interval rather than bound it.
The owned-noop scheduled-retry case needs its continuity retry to fire outside the case, and it probes for `ARM_READY_TIMEOUT_MS + FM_TEST_OBSERVE_SLACK_MS` and then settles for one more budget, so a fixed backoff is overtaken as fork cost rises: the 10000 ms literal it used to carry was 6.7x that probe window on a 14 ms workstation and 3.8x at the 328 ms start measured on run 32255813826, but only 1.6x at the 800 ms worst point of the load curve, and the conservative `2B + slack` the case can actually spend reaches 10400 ms there - past the literal.
It is `4 x (ARM_READY_TIMEOUT_MS + OBSERVE_SLACK_MS)` now, which holds that ratio at every fork cost by construction: 10560 ms at the 328 ms measured start, near the 10000 ms it replaces.
On a 14 ms workstation that narrows the bound from 10000 ms to 6000 ms, which is accepted and unmeasured on the same standard as the other narrowings above - only the wider direction was ever measured - and the margin it keeps there is 3x against the 2000 ms the case can spend.

### The weight hint this change knowingly staled

`bin/fm-test-run.sh` packs `tests/fm-pi-watch-extension.test.sh` at 27802 ms, a hint measured on the pre-fix tree of run [32159215212](https://github.com/mgoyal8293/firstmate-windows/actions/runs/32159215212) at head `580d64fb`, 2026-08-18.
Against that tree the hint now understates by about 29-76 s, and the derivation has two terms, not one.
Both are pure wall clock paid in full on the passing path, and they are additive because they belong to different cases.

The first term is the eight settle sleeps: literals summing to 870 ms were replaced by 8 x `FM_TEST_ARM_START_BUDGET_MS`, which is 8 x 1640 = 13120 ms at the 328 ms start measured on run 32255813826 (delta 12.3 s) and 8 x 4000 = 32000 ms at the 800 ms start in the load curve (delta 31.1 s).

The second term is the arm-readiness budget itself, on the negative-recovery cases that spend it rather than poll it.
Six call sites moved `FM_PI_ARM_READY_TIMEOUT_MS` / `FM_OPENCODE_ARM_READY_TIMEOUT_MS` off the literal 250 ms onto the derived `ARM_READY_TIMEOUT_MS`, which is `ARM_CHILD_START_MS x 5` with a 500 ms floor.
Those are the hung-successor cases, and as the comment above `fm_recovery_deadline_ms` states, they can only conclude *by the budget expiring* - the successor never reports ready - so every one of those expiries is spent in full exactly like a settle sleep.
There are 12 per run of the file, counted by test function so the count stays auditable when the line numbers move: 3 in `test_pi_hung_successor_falls_back_to_typed_wake` (`tests/fm-pi-watch-extension.test.sh:736`), 1 in `test_pi_unretired_successor_falls_back_without_retry` (`:814`), 1 in `test_pi_late_unretired_close_resumes_supervision` (`:896`) across its 2 loop iterations (`for kind in actionable non-actionable`), and 3 + 1 + 1 x 2 again in the three OpenCode counterparts `test_opencode_hung_successor_falls_back_to_typed_wake` (`:2002`), `test_opencode_unretired_successor_falls_back_without_retry` (`:2082`) and `test_opencode_late_unretired_close_resumes_supervision` (`:2166`).
The 2026-08 upstream intake moved those lines and added a case to this file without adding a seventh site that spends the budget, so the six functions and the 12 expiries are unchanged and only the anchors were restated.
Each expiry grew by `ARM_READY_TIMEOUT_MS - 250`, so the term is 12 x 1390 = 16.7 s at the 328 ms start measured on run 32255813826 and 12 x 3750 = 45.0 s at the 800 ms start in the load curve.

Summed, that is about 29 s at the CI-measured start and about 76 s at the load-curve maximum - both computed from those two measured start costs rather than measured as file durations.
The *polled* windows - and only those - add nothing to the figure on the passing path, by construction: a polled driver stops the moment its event lands, so its window bounds how long a failure takes to report rather than spending time when the case passes.
That distinction is exactly why the readiness expiries count and the windows wrapped around them do not.

That is still not a job-cap risk for the lane, but the two terms cannot simply be added to the shard measurement the way they are added to the hint, because the two baselines in play are different trees and are not interchangeable.
That hint's tree, run 32159215212 at head `580d64fb`, was fully pre-fix: six literal `ARM_READY_TIMEOUT_MS=250` sites, no `FM_TEST_ARM_START_BUDGET_MS`, six literal `setTimeout(resolve, 100)`. Both terms above are new in full against it, which is where the 29-76 s comes from.
The 11.67 min worst-shard measurement came from run [32259417831](https://github.com/mgoyal8293/firstmate-windows/actions/runs/32259417831) at head `20b68645`, shard 3 - the shard this file sits in - which already carried the derived readiness budgets, no literal 250 ms site left, but not yet the scaled settle sleeps. The twelve expiries are therefore already inside that 11.67 min at whatever budget *that* run derived, so what is additive over it is the eight settle sleeps in full plus the growth of those twelve expiries above the budget already charged - not both terms in full.
Sizing that needs the budget the measured run itself derived, and the run's own log records it: this file took 40563 ms on shard 3 of run 32259417831 against its 27802 ms packed hint, and a 12761 ms delta spread over 12 expiries that were 250 ms literals in the hint's tree back-solves to a budget of about 1313 ms, i.e. a child start near 263 ms - consistent with the 328 ms measured on run 32255813826.
So the measurement already contains 12 x 1313 + 870 = about 16.6 s of budget-driven wall clock, and at the 800 ms load-curve maximum this tree spends 20 x 4000 = 80.0 s across the same twenty sites. The additive term is the difference, about 63.4 s - the same figure the `file(B) = 23937 + 20B` derivation below gives, 103937 ms at `B = 4000` against the 40563 ms this file actually measured on that shard. That puts the worst case at 11.67 min + 63.4 s = 12.73 min, about 1.18x under the `timeout-minutes: 15` cap this analysis was performed against, with runner setup and checkout on top - and the lane now runs under a `timeout-minutes: 20` cap, so that same 12.73 min sits about 1.57x under the cap in force.
The 12.73 min is an estimate built on two measurements: the 11.67 min shard and the 40563 ms file duration, both from run 32259417831, shard 3. Its `B = 4000` input is the load curve's worst recorded point rather than anything this shard has run at.
Against that, the two margin figures this section states are a different quantity rather than a disagreement: 1.29x (15 / 11.67) is the margin against the raw shard measured on run 32259417831, while 1.18x is the margin once this change's budget growth is charged on top of that same measurement.
Both are stated against the 15-minute cap of that era, which `docs/fm-test-portable-shards.md` and `.github/workflows/ci.yml` then quoted as "about 1.3x"; both files now record the 20-minute cap and no margin figure of their own, so read the pair against that cap as about 1.71x (20 / 11.67) and about 1.57x (20 / 12.73).
A margin is only as good as the baseline it is computed against: name the tree that baseline was measured on, and account for what it already contains before charging anything on top of it.
No `.github/workflows/ci.yml` change and no timeout change is needed for the cost this change adds.
The cap did later move to 20 minutes, in the 2026-08 upstream intake and for the lane growth that intake brought rather than for anything derived here; raising it only widens every margin above.
It is recorded here rather than left for the reader to reconstruct because `docs/fm-test-portable-shards.md` argues in the same breath that a stale hint past the cap costs a cancelled job with no verdict.

`bin/fm-test-run.sh --check-coverage` will not catch this one, and that is the point worth writing down: `unmeasured_serial=0` means no selected serial script is packed at the flat default, not that the hints are current.
This file already had a hint, so the guard never looked at its value - the same blind spot that let the lane overflow accumulate, and the reason `fm-test-weight-drift-detector` is filed as the follow-up that compares measured durations against the table.

### Why the derived budget has no ceiling

`ARM_READY_TIMEOUT_MS` is the measured child start times five with a 500 ms floor and no upper bound, and the budget is paid in full wall clock 20 times per run of this file: the eight settle sleeps plus the twelve readiness expiries above.
Added wall clock is `W = 20B - 3870 ms` over the pre-fix hint baseline, for a budget `B`.
Because `B` is five times the worst of five samples, one scheduling outlier is multiplied by five and then paid twenty times, and nothing clamps the result.

**The margin against the job cap is about 2.7x of measured fork cost, and that is a live maintenance concern rather than comfortable headroom.**
The lane had only 3.33 min of slack under the cap this was written against - 15 min against the 11.67 min worst shard measured on run 32259417831, shard 3 - and it had that much only because the weights were refreshed in this change.
The cap in force is now 20 minutes, so the slack is wider than that and every conclusion below holds with more room rather than less.

Deriving that threshold is where the baseline rule above bites concretely: `B` cannot be varied while the 11.67 min shard measurement is held fixed, because that measurement contains twelve expiries at the budget its own run derived, so treating it as a constant freezes the expiry term at an old budget and silently drops `12 x (B - B_measured)`.
Accounting for that, on run 32259417831, shard 3 - the shard this file sits in - at 11.67 min, this file at 40563 ms against its 27802 ms packed hint, back-solving that run's budget to about 1313 ms:
everything in this file other than the twelve expiry budgets and the eight settle sleeps is about 23.9 s (40563 - 12 x 1313 - 870), so `file(B) = 23937 + 20B` and `shard3(B) = (11.67 min - 40563 ms) + 23937 + 20B`.
Setting that equal to the 900000 ms cap - the 15-minute cap in force when this was derived - gives `B = 10821 ms`, a child start of 2164 ms - about 2.71x the 800 ms worst point of the recorded load curve.
Under the 20-minute cap now in force the same algebra puts that threshold higher, so the figures kept here are the conservative ones and are left as derived rather than restated. The 2164 ms is a derived threshold rather than an observed start cost; the measured inputs behind it are the 11.67 min shard and the 40563 ms file duration from run 32259417831, shard 3.
The answer is not sensitive to the back-solve: assuming the run derived 1640 ms instead gives 2204 ms and 2.75x, so it is about 2.7x either way.

The budget still stays unbounded, and that is a ruling rather than an oversight.
The argument is structural and does not depend on the size of the margin: a ceiling would make the budget stop tracking child start on precisely the slow machine that needs it most, which reintroduces the exact false-red mechanism this change exists to remove.
The failure a ceiling prevents is a slow job; the failure it causes is a wrong verdict.

## Why the guard plugins guard their stdin write

`tests/fm-pi-watch-extension.test.sh` also failed intermittently inside the OpenCode turn-end guard, with a different signature that turned out to be a defect in tracked plugin code rather than in the test.

`runProcess` in `.opencode/plugins/fm-primary-turnend-guard.js` writes the stop-hook payload with `child.stdin.end(input)`.
When the guard exits before draining stdin, that write fails with `EPIPE`.
The error is emitted on the stdin stream, not on the `ChildProcess`, so the plugin's `child.on("error", ...)` handler never saw it and node escalated it to an unhandled error that killed the host session.
`.opencode/plugins/lib/fm-operational-input.js` and `.pi/extensions/fm-primary-turnend-guard.ts` write to a spawned child the same way and carried the same gap.

Observed on a 22-core workstation, 200 runs of the affected case at 10-way concurrency:

```console
$ runs: 200  failures: 7
Error: write EPIPE
    at Writable.end (node:internal/streams/writable:823:17)
    at .opencode/plugins/fm-primary-turnend-guard.js:25:17
```

All three sites now attach a stdin error listener before writing.
The child's exit is already the authoritative result and each site's `close` handler still reports it, so a refused write carries nothing of its own.

`tests/fm-operational-input.test.sh` pins the pattern deterministically rather than by repetition: it points the adapter at an encoder that exits without reading, and passes a body past the pipe capacity so the write cannot complete before the child is gone.

```console
$ bash tests/fm-operational-input.test.sh | tail -2
ok - operational input: an encoder that stops reading fails the call, not the host
ok - operational input: current construction rejects legacy kinds and empty bodies
```

With the stdin listener removed, that assertion fails with the production crash rather than a timing flake:

```console
not ok - a refused encoder body killed the adapter's host: exit 1 - node:events:497
```

The two turn-end guard sites carry the identical one-line guard, and both are pinned deterministically too, in `tests/fm-pi-watch-extension.test.sh`.
Their payload is a fixed 26 bytes, which fits the pipe buffer, so the oversize-body trick does not port and the real race cannot be lost on demand - the parent's first write attempt lands microseconds after the fork and normally beats the child's exit, which is why the campaign above scored only 7 in 200.
Those two cases instead inject the refusal where the kernel would raise it: a loader hook redirects `node:child_process` to a shim that spawns the real guard, with its real exit code and stderr, and replaces only that child's stdin with a stream whose first write fails `EPIPE`.
Each case asserts that the host survives, that no `EPIPE` escapes, and that the guard's blocking verdict still reaches the caller.
Its stderr is checked through a fixture token rather than the guard's own words: both guards prepend the fixed prose `TURN WOULD END BLIND - supervision is off. ` before appending the child's stderr, so asserting anything resembling that sentence would pass on an empty stderr.
Each case also asserts a marker the shim writes at the moment it replaces the child's stdin, because a shim that silently stopped matching would spawn the real guard, write its 26 bytes successfully, still see exit 2, and leave the case green with the listener deleted.

```console
$ bash tests/fm-pi-watch-extension.test.sh | grep 'stdin write is refused'
ok - OpenCode turn-end guard reports its verdict when the stdin write is refused
ok - Pi turn-end guard reports its verdict when the stdin write is refused
```

With either site's stdin listener removed, its case fails with the production crash rather than a timing flake:

```console
not ok - OpenCode turn-end guard let a refused stdin write escape: node:events:497
      throw er; // Unhandled 'error' event
Error: write EPIPE
```

The OpenCode external-healthy case in the same file exercises two of the three sites end to end on the real path that was crashing: `.opencode/plugins/fm-primary-turnend-guard.js` and, through the prompt it builds, `.opencode/plugins/lib/fm-operational-input.js`.
It never loads `.pi/extensions/fm-primary-turnend-guard.ts`, so the Pi site has no end-to-end coverage here and rests entirely on its deterministic case above.

## Refreshing this evidence

The watcher suite measures the start cost itself and prints what it derived as its first line, so the number this page depends on is readable from any run, including a CI log, without reproducing the machine.
It refuses to run when the measurement cannot be taken.

```console
$ bash tests/fm-pi-watch-extension.test.sh | head -1
# arm child start 14ms measured, readiness budget 500ms
$ bash tests/fm-operational-input.test.sh | tail -1
ok - operational input: current construction rejects legacy kinds and empty bodies
```

Compare that first line against a CI log's own first line to see the hardware gap this page records.
