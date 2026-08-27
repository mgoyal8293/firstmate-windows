# Windows session-lock and process-table read cost

Repeatable evidence for what a session-lock ownership check costs under MSYS, and what the fork removal in [`../../bin/fm-proc-lib.sh`](../../bin/fm-proc-lib.sh) and the memo in [`../../bin/fm-session-token-lib.sh`](../../bin/fm-session-token-lib.sh) actually removed.
The ownership design itself is owned by [`../windows.md`](../windows.md) "How the session lock is owned", and the subprocess *counts* behind the same class of defect by [`session-start-fork-profile.md`](session-start-fork-profile.md).
This page records timings only.

Date: 2026-08-27.
Comparison base: `main` at `4c5336c`.
Windows host: Windows 11 Pro 10.0.26200, Git for Windows MINGW64_NT-10.0-26200, bash 5.2.37(1)-release.
Measured from WSL2 by invoking Git Bash by full path (`/mnt/c/Program Files/Git/bin/bash.exe`), because this box sets `interop.appendWindowsPath=false`.

## Why this is measured on Windows and not on Linux

The whole effect is the per-fork penalty: a subprocess costs about 1 ms on Linux and about 42 ms under MSYS, so a Linux timing run would show nothing and a fork *count* would not show how much of a turn is spent.
Both libraries were copied to a staging directory on a local NTFS volume and sourced from Git Bash there, so no `\\wsl.localhost` path is on the measured path.

## How the numbers are taken

Two shapes, because they answer different questions and one of them flatters the change.

- **In-process loop.** `date +%s%N` around N repeated calls in one already-sourced shell, divided by N.
  This is the honest figure for the process-table read, and a *dishonest* one for the memoised predicate: after the first call in a loop every later one is a memo hit, so the mean understates the cold call a fresh process actually makes.
- **Two checks, fresh process.** A new `bash -c` per iteration that sources `bin/fm-session-lock-lib.sh` and makes two `fm_session_lock_owned_by_self` calls.
  Nothing is carried between iterations, so the memo is exercised once cold and once warm.
  This is the shape of the stale-lock recovery path in `bin/fm-claude-stop-autoarm.sh`, not of a steady-state turn: its second ownership check sits inside `if [ "$RECOVER_SESSION_LOCK" -eq 1 ]` and is reached only when the first check has failed and the recorded lock pid is dead.

The `.lock` fixture holds a pid that is not this process's ancestor, so the check runs to a verdict rather than short-circuiting.

## The harnesses, so this page can be re-run

The staging directory these runs used is gone, so both harnesses are reproduced here rather than referenced.
Stage a copy of `bin/` from each revision being compared on a local NTFS volume, not under a `\\wsl.localhost` path, and invoke Git Bash by full path because this box sets `interop.appendWindowsPath=false`.
Point `<state-dir>` at a fixture whose `.lock` holds a pid that is not the caller's ancestor.

The in-process loop harness, which produces the component-costs table and the contract block:

```sh
#!/usr/bin/env bash
# measure.sh <bin-dir> <state-dir>
BIN=$1 STATE=$2
. "$BIN/fm-proc-lib.sh"
. "$BIN/fm-session-lock-lib.sh"

time_loop() {  # <n> <label> <command...>
  local n=$1 label=$2 start end i
  shift 2
  start=$(date +%s%N)
  for ((i = 0; i < n; i++)); do "$@" >/dev/null 2>&1; done
  end=$(date +%s%N)
  awk -v ns="$((end - start))" -v n="$n" -v l="$label" \
    'BEGIN { printf "%s %.2f ms\n", l, ns / n / 1000000 }'
}

field_through_subst() { local v; v=$(fm_proc_field $$ ppid); }

time_loop 30 'fm_proc_field ppid direct'  fm_proc_field $$ ppid
time_loop 30 'fm_proc_field ppid $( )'    field_through_subst
time_loop 30 'fm_proc_field comm direct'  fm_proc_field $$ comm
time_loop 15 'fm_harness_ancestry_pids'   fm_harness_ancestry_pids
time_loop 15 'fm_session_ancestry_unavailable'  fm_session_ancestry_unavailable
time_loop 15 'fm_session_lock_owned_by_self'    fm_session_lock_owned_by_self "$STATE"

show()   { local l=$1 out rc; shift; out=$("$@" 2>&1); rc=$?; printf '%s=[%s] rc=%s\n' "$l" "$out" "$rc"; }
refuse() { local l=$1 out rc; shift; out=$("$@" 2>&1); rc=$?; printf '%s rc=%s out=[%s]\n' "$l" "$rc" "$out"; }

show ppid fm_proc_field $$ ppid
show comm fm_proc_field $$ comm
printf 'args=[%s]\n' "$(fm_proc_field $$ args 2>&1)"
printf 'pgid=[%s] sid=[%s]\n' "$(fm_proc_field $$ pgid 2>&1)" "$(fm_proc_field $$ sid 2>&1)"
refuse dead-pid   fm_proc_field 999999 ppid
refuse empty-pid  fm_proc_field '' ppid
refuse nonnum-pid fm_proc_field abc ppid
refuse bad-field  fm_proc_field $$ nosuchfield
refuse ancestry_unavailable fm_session_ancestry_unavailable
```

The fresh-process harness, which produces the two-check and source-only rows:

```sh
#!/usr/bin/env bash
# perturn.sh <bin-dir> <state-dir> <checks: 0 or 2>
BIN=$1 STATE=$2 CHECKS=$3
start=$(date +%s%N)
for i in $(seq 1 10); do
  bash -c '
    . "$1/fm-session-lock-lib.sh"
    [ "$3" -eq 0 ] && exit 0
    fm_session_lock_owned_by_self "$2" >/dev/null 2>&1
    fm_session_lock_owned_by_self "$2" >/dev/null 2>&1
  ' _ "$BIN" "$STATE" "$CHECKS"
done
end=$(date +%s%N)
awk -v ns="$((end - start))" 'BEGIN { printf "%.1f ms per iteration\n", ns / 10 / 1000000 }'
```

Nothing is carried between iterations of the second harness, so each one pays a cold memo exactly as a fresh hook process does.

## Two-check cost, measured

| Shape | As shipped | Fixed |
|---|---|---|
| Fresh process, source + two ownership checks (n=10) | **3,268.6 ms** | **1,437.7 ms** |
| Fresh process, source only, zero checks (n=10) | 272.0 ms | 308.5 ms |

Subtracting the sourcing cost, the two checks themselves fall from about 2,997 ms to about 1,129 ms, a 2.7x reduction.
The sourcing line is quoted to keep that subtraction honest; the 36 ms difference between its two columns is run-to-run noise on this host, not an effect of the change.
This is the two-check scenario, which is the autoarm stale-lock recovery branch and `current_session_still_ours` in `bin/fm-turnend-guard-cursor.sh`.
Those are the callers that ask `fm_session_lock_owned_by_self` more than once inside one process, which is the shape measured here.
`bin/fm-lock.sh` is a repeat-PREDICATE path and not an instance of this shape: it never calls `fm_session_lock_owned_by_self`, it calls `fm_session_ancestry_unavailable` twice, and no measured figure on this page applies to it.
It is NOT what a steady-state turn pays, and an earlier revision of this page quoted its 1.87 s difference as a per-turn saving.
That claim is retracted here; the corrected per-turn figure is in the next section.

## Steady-state per-turn cost, derived from the rows above

A steady-state turn makes exactly ONE ownership check, because the second check in `bin/fm-claude-stop-autoarm.sh` is gated on the first one having failed.
No one-check run was performed, so the figures here are derived from the measured rows above rather than measured directly, and neither may be quoted as a measurement.

As shipped there is no memo, so the two checks cost about 2,997 ms independently and one check is half of that: **about 1,498 ms**.
Fixed, the memo reduces the second check's ancestry walk to a variable read, so the measured 1,129 ms for two checks is close to the cost of the one cold check: **about 1,129 ms**.
The difference is **roughly 370 ms removed from a steady-state turn**, and all of it is the `fm_proc_field` fork removal, because on a one-check turn the memo has no second call to save.

That 1,129 ms is an over-estimate of a single check rather than an exact one.
`fm_session_lock_owned_by_self` reads `state/.lock` through a `cat` command substitution before it ever reaches the memoised predicate, so the second check still pays a fork of its own that the memo cannot remove.
The residual pushes the true fixed one-check figure down, which makes roughly 370 ms a conservative floor on the steady-state saving rather than a midpoint.
No more precise figure is given, because no one-check run was measured.
The memo's own justification is call count on the multi-check paths, not this per-turn figure.

## Component costs, in-process loop

| Call | As shipped | Fixed | Ratio |
|---|---|---|---|
| `fm_proc_field $$ ppid`, called directly (n=30) | 116.32 ms | 1.34 ms | 87x |
| `fm_proc_field $$ ppid`, through `$( )` as call sites use it (n=30) | 136.57 ms | 27.83 ms | 4.9x |
| `fm_proc_field $$ comm`, called directly (n=30) | 136.92 ms | 1.38 ms | 99x |
| `fm_harness_ancestry_pids` (n=15) | 746.70 ms | 392.73 ms | 1.9x |
| `fm_session_ancestry_unavailable` (n=15, loop-amortised) | 695.08 ms | 47.39 ms | see note |
| `fm_session_lock_owned_by_self` (n=15, loop-amortised) | 830.65 ms | 98.12 ms | see note |

Both amortised rows are loop artifacts and must not be quoted as per-turn savings; the derived per-turn figure above is the claim.

The two `fm_proc_field` rows differ by about one MSYS fork, which is the caller's own command substitution and is outside this function's reach.
That row is why the direct 87x is not the improvement a caller sees: **4.9x is**, and it is the figure that corroborates the 4.5x the audit measured on its own prototype.

## Contract preserved

Both variants were driven through the same inputs in the same run, and the contract-bearing facts were identical between them, so the timing change carries no behaviour change.
Identical across the two runs: `comm`, `ppid`, and all four return-code and silence cases.
`pgid`, `sid` and the `args` line are per-invocation values and are quoted for output SHAPE only, never for equality.
A different process necessarily has a different pgid and sid, and `args` carries the staging path of whichever variant was being measured, so those three lines differed between the runs by nature.
The block below is the fixed run:

```console
ppid=[1] rc=0
comm=[/usr/bin/bash] rc=0
args=[bash ./measure.sh .../bin]
pgid=[2305] sid=[2305]
dead-pid rc=1 out=[]
empty-pid rc=1 out=[]
nonnum-pid rc=1 out=[]
bad-field rc=1 out=[]
ancestry_unavailable rc=0
```

`out=[]` is captured with `2>&1`, so it also proves the vanished-pid and bad-input cases stay silent rather than only returning non-zero.
That silence is what `tests/fm-windows-portability.test.sh` pins portably, because `$(< file)` reports a missing file on the caller's stderr where `cat 2>/dev/null` absorbed it.

## What was deliberately left on the table

`fm_harness_ancestry_pids` is still 392.73 ms because `fm_harness_process_matches` pipes to `grep -qE` twice per ancestry hop, which a bash `[[ =~ ]]` would answer without a subprocess.
It is not done here: that function is the classifier deciding what counts as a harness process, so changing its matching engine is a behaviour risk in the lock path rather than a timing change, and it needs its own task with its own per-harness evidence.
