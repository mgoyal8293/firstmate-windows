# Watcher arm test budget verification

Repeatable evidence for the two timing guarantees the tracked watcher arm suites depend on.
Current behavior of the Pi extension and the OpenCode plugins is owned by their own sources; this page records evidence only.

Date: 2026-08-19.
Status: work in progress. The readiness-budget and stdin-write findings below are
closed and independently verified. The session-lock finding is closed against its
counterfactual but its loaded-runner pass count is still being measured (run
32224627637), so no runner row is recorded for it yet. One failure remains
unisolated; see "Known residual".
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

## Known residual

One failure in this suite is recorded but not isolated: a wake delivered before any arm had recorded a row, three times in 150 runs at a load level that makes the runner roughly three times slower than the real serial shard.
It did not reproduce in 168 workstation runs at 14-way concurrency, so no cause is claimed here.
The assertion now distinguishes an unobserved delivery from a delivery that saw an empty arm log and prints the arm log with it, so the next occurrence carries its own evidence instead of a count.

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

The two turn-end guard sites carry the identical one-line guard and are exercised end to end by the OpenCode external-healthy case in `tests/fm-pi-watch-extension.test.sh`, which is the path that was crashing.

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
