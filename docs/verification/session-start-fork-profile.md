# Session-start subprocess profile

Repeatable evidence for how many subprocesses one session start creates, where they come from, and what the reductions in `bin/fm-proc-lib.sh`, `bin/fm-wake-lib.sh`, `bin/fm-cursor-lib.sh` and `bin/fm-session-lock-lib.sh` actually removed.
The runtime bound those numbers justify is owned by [`../../bin/fm-session-start-bound-lib.sh`](../../bin/fm-session-start-bound-lib.sh), and the port's fixed-here list by [`../windows.md`](../windows.md).
This page records evidence only.

Date: 2026-08-23.
Comparison base: `main` at `6d7dc9a`.
Linux box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2, 22 cores, bash 5.2.21.
Windows numbers quoted for context were measured separately on Windows 11, Git Bash MINGW64_NT-10.0-26200.

## Why this is measured on Linux

The defect is a Windows one: a subprocess costs about 42 ms under MSYS against about 1 ms here, so the same digest that finishes in seconds on Linux takes over a minute there.
But the *count* is the same on both, and the count is what the code controls, so it is measurable here without a Windows box - and a Linux timing run would say nothing, because the per-fork penalty is the whole effect.
Every number below is a count of process creations, not a timing.

## How the count is taken

`/proc/stat`'s `processes` counter is host-global and this box runs other work: an idle 5 s sample showed 198 forks of ambient noise, which is the same order as the thing being measured.
So the count is taken per process tree with an `LD_PRELOAD` interposer on `fork`, `execve` and `posix_spawn` that appends one line per call with the caller's `/proc/self/cmdline`, giving both a total and its attribution.
It is validated against a known-count program before use:

```console
$ FORKCOUNT_LOG=v.log LD_PRELOAD=./forkcount.so bash -c \
    'for i in 1 2 3 4 5; do /bin/true; done; x=$(/bin/echo hi); : $(/bin/date +%s)'
$ grep -c '^FORK' v.log ; grep -c '^EXEC' v.log
7
7
```

Seven process creations were asked for and seven were counted.

Two measurement rules matter and were both violated by earlier attempts at this:

- The deferred network stage (`bin/fm-startup-network.sh`) is detached and keeps appending to the log after the digest returns, so a count taken immediately is short. Every figure below is taken after the stage settles, and that stage's forks are reported separately because they are concurrent and not on the blocking path.
- Each variant is measured on its **own pristine home** and its own clone checked out as a branch named `main`. Comparing a `git archive` export against a real checkout attributes the worktree-tangle check's `git` calls to the change under test, and comparing two runs against one shared home attributes the first run's one-time migration markers to it. Both mistakes were made and both inflated a delta by tens of forks.
- Run 1 on a fresh home differs from runs 2 and 3, which are identical to the fork. The steady state is what a daily user pays, so it is the figure quoted.

## Blocking-path forks, empty home, steady state

An empty home is the floor: no tasks, no projects, an absent backlog, nothing to reconcile and nothing to sync.

| Variant | Blocking-path forks | Detached network stage | Total |
|---|---|---|---|
| `main` at `6d7dc9a` | 1012 | 555 | 1567 |
| after the runtime-bound change | 1016 | 559 | 1575 |
| after the subprocess reductions | 817 | 432 | 1249 |

The bound change costs 4 forks: one `uname` for the platform default and its command substitution.
The reductions remove 199 forks from the blocking path, 19.6%, and 127 more from the concurrent stage, which shares the same libraries.
Both of those figures are against the 1016 row - the tree the reductions were actually applied to - and not against `main`; against `main`'s 1012 the same end state is 195 fewer forks and 19.3%.

At the 42 ms measured under MSYS, 199 forks is about 8 s off a 72 s floor.
That is a real improvement and it is not a fix on its own, which is why the bound was raised as well.

### Re-measurement, and an offset worth recording

The table above was taken once, early in the branch.
It was re-taken later on the same box with the same method and a rebuilt interposer, over `6d7dc9a`, `45e6708`, `c1725d0`, `f07110f` and the final tree, each on its own pristine home and its own clone checked out as `main`:

| Variant | Blocking-path forks | Detached network stage | Total |
|---|---|---|---|
| `main` at `6d7dc9a` | 976 | 535 | 1511 |
| `45e6708`, `f07110f`, final tree | 789 | 416 | 1205 |

The percentage reproduces and the absolutes do not: 976 to 789 is 187 forks and 19.2%, against the 19.3% the table above records for `main`, while both absolute counts land about 30 lower.
A host-global fork counter was already rejected here for exactly this reason, and the per-tree interposer still sees whatever the digest's own children find on PATH, which is not identical between two sessions weeks apart.
So the RATIO is the durable result and the absolute floor is only reproducible against its own run.
Both readings are kept rather than one overwriting the other, because a single number silently replaced is how a measured claim turns into remembered prose.

The three later commits measure identically to `45e6708` on the blocking path, so the runtime bound, the stage marks and the harness-ceiling clamp cost nothing on the default path - which is what deriving the ceiling only for an explicit override was for.
The per-platform nesting margin added after them does cost 3 process creations in the bounded child, measured and broken down under "What the per-platform margin cost" below.

## Where the forks were, ranked

Attribution came from a second, independent instrument: `bash` xtrace with `PS4` carrying `${BASH_SOURCE[0]}` and `${LINENO}`, inherited by every child through `SHELLOPTS=xtrace` and a `BASH_XTRACEFD` the children inherit.
The two instruments agree on the total within the noise of the detached stage.

Ranked call sites on `main`, blocking path, steady state:

| Count | Site | Cost |
|---|---|---|
| 69 | `fm-proc-lib.sh` `fm_proc_field`'s `ps` fallback | one `ps` per process field read |
| 41 | `fm-proc-lib.sh` prologue `uname -s` | the file was sourced 42 times per session start |
| 42 | `fm-wake-lib.sh` `fm_lock_link_owner`'s `readlink` | 3 per lock acquisition, 14 acquisitions |
| 24 + 24 | `fm-session-lock-lib.sh` `basename` and `grep -qE` in the harness classifier | once per process while walking ancestry |
| 21 | `fm-session-lock-lib.sh` `fm_proc_field ... \| tr -d ' '` | a subshell plus a `tr` exec per ancestry step |
| 21 | `fm-cursor-lib.sh` `basename` in its process classifier | once per candidate process |
| ~12 each | `fm-wake-lib.sh` prologue `dirname`, `uname`, `mkdir -p` | the file was sourced 13 times per session start |

The dominant pattern was not one hot loop.
It was **libraries re-sourced from inside functions**, each re-running a prologue: 158 library source events per session start, `bin/fm-proc-lib.sh` alone 42 times, each paying its own `uname`.
That is not what the task expected to find and it is where the largest single win was.

One trap this file exists to record: `grep -c uname bin/fm-lock.sh` returns 0, and `bin/fm-lock.sh` forks `uname` four times.
The forks come from libraries it sources. A count derived from grepping source text is a hypothesis about a call site, never a measurement of a call.

## Which substitutions are actually free

Counted, 100 iterations each, same instrument:

| Form | Forks per call |
|---|---|
| `x=$(cat f)` | 1 fork + 1 exec |
| `x=$(<f)` | 0 |
| `read -r x < f` | 0 |
| `x=$(dirname /a/b)` | 1 fork + 1 exec |
| `x=${p%/*}` | 0 |
| `x=$(basename /a/b)` | 1 fork + 1 exec |
| `x=${p##*/}` | 0 |
| `x=$(printf hi)` | 1 fork, 0 exec |

Two results decide how the reductions are written.
A command substitution forks even around a shell builtin, so `$(...)` is never free.
And `$(<f)` is free only *without* a redirection on it: `$(<f 2>/dev/null)` measured 2 forks per call, because the redirection defeats bash's special case, and it does not suppress the error either.
So an unreadable file is handled by testing `[ -r f ]` first - a builtin - rather than by redirecting stderr.
The test and the read are two steps, so a file deleted between them still spills bash's own error; that is suppressed by putting the `2>/dev/null` on the enclosing `{ ...; }` group, where it is an fd save and restore, and `{ x=$(<f); } 2>/dev/null` measured 0 forks per call on this same instrument.

The harness-timeout ceiling that clamps an explicit `FM_SESSION_START_TIMEOUT` costs one `awk` over the registrations, and it is derived only when such an override is set, so every count above - all taken with no override - is unchanged by it.

## The contended lock path, which no count above reaches

Every figure above is an UNCONTENDED empty home, and that is a real blind spot rather than a caveat.
`fm_lock_acquire_wait` re-enters `fm_lock_try_acquire` every 100 ms until the lock frees, and each of those iterations read `$lockdir/pid` through `$(cat f)`; on an uncontended home `fm_lock_try_create` succeeds immediately and that read is never reached, so the profile could not have ranked it.

Measured directly instead, with the same interposer: one waiter polling a lock held by a live process, 20 poll iterations.

| Variant | Forks | `cat` execs |
|---|---|---|
| before the pid-read conversion | 177 | 20 |
| after | 137 | 0 |

Two forks per poll iteration, which is one `$(cat f)`: the substitution's subshell and `cat` itself.
Converting those reads leaves the uncontended steady state at 789 exactly - unchanged, as expected, since it never executes them - so this is a win that is invisible to the headline number and is recorded here rather than folded into it.
At the 42 ms a fork costs under MSYS that is about 84 ms per second of waiting, paid by whichever session is second to the lock.

## On the Windows box itself

The count above is portable; these are the numbers from the platform the defect lives on.
Windows 11 build 10.0.26200, `MINGW64_NT-10.0-26200`, bash 5.2.37, git 2.50.1.windows.1, both trees exported to `C:` and driven through one hidden `powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden` invocation per batch.

The per-platform default resolves as intended there, which no Linux run can show:

```console
$ . bin/fm-session-start-bound-lib.sh
$ fm_session_start_default_budget      ; # 300
$ fm_session_start_resolve_budget ''   ; # 300
$ fm_session_start_resolve_budget 45   ; # 45
$ fm_session_start_resolve_budget abc  ; # 300
```

Elapsed on an empty home, steady state: 74 s before, 64-70 s after.
That is directional only, not a precise figure - other work was running on the box during these runs, and it is the reason the fork count rather than a stopwatch is the measurement of record.
All ten sections are present in the completed digest after the change and `SUPERVISION INSTRUCTIONS` is absent before it, which is what that stage's missing header looked like in practice.

The attribution is what changed most visibly. At a 40 s bound, before:

```
●  It stopped during the "lock" stage, so everything above is COMPLETE
●    lock bootstrap wake-queue supervision-instructions read-once fleet-state network-checks context next-step
```

and after:

```
●  Where the time went, per stage (ms), so the slow stage is named:
●    startup                  start=+0       elapsed=9898
●    lock                     start=+9898    elapsed=30102  <- did not finish
```

That `startup` figure is the finding this instrumentation paid for immediately.
It is this script's own setup - one harness probe, the library sources and the tasks-axi compatibility probe - and it costs **9.9 s on Windows against 312 ms on Linux**, a factor of 32.
That figure is a LOWER bound on the window: when it was taken, the mark sat after three of the library sources, so their cost fell outside the stage. The mark has since been moved ahead of every source but `bin/fm-session-start-bound-lib.sh`, which defines the mark itself, so the window the stage now reports is wider than the one measured here and has not been re-measured on Windows.
Before the `startup` stage existed, a truncation inside that window could only report the stage as `unknown` and list no lost stages at all, which is the case where the banner explains least.
The final stage's elapsed is bounded by the remaining budget rather than measured, because the child was killed inside it; it is a lower bound on that stage, which is why it is marked as not finished.

## The nesting margin, and why it is 4 s on Windows

The runtime bound governs the BOUNDED CHILD.
The harness kills the PARENT, and the parent spends time outside that child at both ends, so the hook's wall time is prologue + bound + banner.
A margin sized only for the equal-deadline race covers neither end, and the operator who does exactly what the truncation banner tells them - raise `FM_SESSION_START_TIMEOUT` to the printed ceiling - then loses the banner outright on MSYS.
`FM_SESSION_START_NESTING_MARGIN` in [`../../bin/fm-session-start-bound-lib.sh`](../../bin/fm-session-start-bound-lib.sh) is therefore per platform, by the same `uname -s` arms as the default budget.

### The first derivation measured the wrong path, and is retracted

This page previously derived the margin from a 22-subprocess pattern and landed on 3 s.
That derivation is WRONG and must not be cited.
It counted the DEFAULT path - the parent's prologue plus the post-kill banner - but the default path can never reach the ceiling: the Windows default bound is 300 s against a ceiling in the 350s, so a truncation AT the ceiling only ever happens to a bound that was CLAMPED down to it.
Clamping is precisely the path that additionally derives the cap before forking the child, which the default path skips entirely.
So the pattern that has to be covered is the clamped one, and it is strictly larger than the one that was measured.

The 2574 ms end-to-end corroboration recorded with that derivation is retracted with it, for the same reason: it timed the 22-subprocess default-path pattern, so it corroborates a count that is not the one the margin owes.

### What the margin owes, on the path that actually reaches the ceiling

Counted with the same `LD_PRELOAD` interposer described above, validated against the same known-count program before use, and counted rather than grepped.
Process creations, re-counted on the current tree after both the cap and the hook-context derivations were deduplicated:

| Side of the bound | Work | Subprocesses |
|---|---|---|
| Before the fork | `bin/fm-session-start.sh`'s `SCRIPT_DIR`/`FM_ROOT` resolution, the `fm-session-start-bound-lib.sh`, `fm-timeout-lib.sh` and `fm-session-lock-lib.sh` sources with their transitive prologues, `fm_session_start_bind_budget` on the default path, and the stage-file `mktemp` | 11 |
| Before the fork | what a CLAMPED bound additionally pays: the registration glob, the `awk` over the registration JSONs, and the advisory only a clamp emits | 6 |
| After the kill | `fm_session_stage_last`, the pending-stage `awk`/`tr` pipeline, `fm_session_start_bound_remedy` and `fm_session_stage_render` | 15 |
| | | **32** |

Both derivations the parent used to run twice now run once.
The cap was deduplicated first; the hook-context probe after it, because `fm_session_start_cap` resolved the context inside a command substitution, so the answer died with the subshell exactly as the cap had, and the advisory then probed a second time in the parent.
`fm_session_start_bind_context` binds it instead and `bin/fm-session-start.sh` threads it to the advisory, so the pre-fork window pays for one probe.

Measured effect of that second dedup, same interposer, same box:

| Path | Before | After |
|---|---|---|
| Clamped pre-fork prologue | 19 forks | 17 forks |
| Post-kill banner | 16 forks | 15 forks |
| Clamped path, total | 35 | 32 |

### The count history, kept rather than overwritten

Three counts of this path exist and they do not agree, so all three stay on the page.
26 is what the margin was derived from.
31 came from an independent re-measurement on this box with the same interposer, and 32 was argued for separately.
**32 is what the current tree measures**, after both dedups, so the measurement and the most pessimistic argued figure have converged.
That does not move the margin, for the reason below, but a single number silently replaced is how a measured claim turns into remembered prose.

### The per-fork cost on the target

Measured on the box the defect lives on: `MINGW64_NT-10.0-26200`, bash 5.2.37, 22 cores.
The pattern being timed replicates that same subprocess shape, run against fork-heavy competitors:

| Competing fork-heavy processes | Per fork |
|---|---|
| 0 | 30.6 ms |
| 3 | 44.5 ms |
| 6 | 61.7 ms |
| 12 | 124.0 ms |

**Pure CPU load was the wrong model and was discarded.**
Four busy-loop burners made forks FASTER, 25 ms against 30 ms idle, through frequency boost.
The real competitor is a test lane, which contends for PROCESS CREATION, and MSYS serialises that - hence fork-heavy competitors rather than CPU burners.

### The derivation, its slack, and what it does not claim

26 subprocesses x 124.0 ms = 3224 ms, ceiling to whole seconds = **4 s**.
Off Windows the margin stays 1 s: forks cost about 1 ms here, so the same product is well under a second, and 1 s is the strict-inequality margin the equal-deadline race needs.

**Why 4 s survives the disputed count.**
Every count on record lands on the same answer:

| Count | x 124.0 ms | Ceiling | Slack at 4 s |
|---|---|---|---|
| 26 (derivation) | 3224 ms | 4 s | 776 ms |
| 28 | 3472 ms | 4 s | 528 ms |
| 30 (before the dedup) | 3720 ms | 4 s | 280 ms |
| 31 (earlier re-measurement) | 3844 ms | 4 s | 156 ms |
| 32 (**measured on the current tree**) | 3968 ms | 4 s | 32 ms |

So the choice of 4 s does not depend on resolving whether the count is 26 or 32.
The SLACK does, and the current tree sits at the pessimistic end of it: **32 ms**, not the 776 ms the derivation's own count would have implied.
That is the honest headline of this section - the margin is sufficient against the worst measured per-fork cost, and it is not roomy.
The two dedups are what keep it sufficient at all: together they removed 3 process creations from exactly this path, and without them the count is 35 and the product 4340 ms, which is over the margin.
They are correctness dependencies of this number rather than performance niceties, and anything that adds a subprocess to the pre-fork window or the banner has to be weighed against those 32 ms.
[`../../tests/fm-session-start-hook-nesting.test.sh`](../../tests/fm-session-start-hook-nesting.test.sh) holds the margin to the WORST count on record rather than the one it was derived from, so a shrunk margin fails there even if the optimistic count is the true one.

What this does NOT claim: the per-fork cost rises with contention, so no fixed margin is safe at unbounded contention.
4 s covers the measured worst case on that box.
It is not a proof of sufficiency.

### One value, read by both the clamp and the banner

`fm_session_start_hook_ceiling` subtracts the margin to derive the highest bound it will allow, and `fm_session_start_budget_advisory` and `fm_session_start_bound_remedy` add it back to name the second the harness will actually kill at.
A second literal anywhere would let the number the operator is told diverge from the number in force, which is the failure the margin exists to prevent, so mutation M8 below is what holds them together.

## One bound for the digest and the detached worker

`bin/fm-startup-network.sh` keeps offering its result for inline delivery for exactly as long as the digest could still be running.
That has always been meant as one bound; it is now one RESOLUTION as well, and the difference is a real defect that this branch introduced and this round closes.

The worker is detached with stdio on `/dev/null`, so `[ -t 2 ]` is false inside it and `fm_session_start_hook_context` can never answer `direct` there.
Re-resolving `FM_SESSION_START_TIMEOUT` in the worker therefore does not reproduce the digest's bound, it reproduces the CLAMP.
The failing sequence is the one the truncation banner itself prescribes: rerun from a terminal with the timeout raised above the ceiling, and the digest runs at the raised value while the worker stops offering inline delivery at the ceiling - silently, for the rest of the run.
The result is not lost, it still surfaces as a durable wake, but it stops arriving in the digest the operator is sitting in front of.

`bin/fm-session-start.sh` now resolves the bound once and exports it as `FM_SESSION_START_RESOLVED_BOUND` on the same `env` that forks the bounded child, which the worker inherits.
`fm_session_start_delivery_bound` prefers it and falls back to a local resolution only when there is no digest to inherit from, which is the standalone case.

## Windows verification: what is measured there, and what is NOT

Acceptance criterion 6 for this work says the change must be verified on the real Windows box, and that a clean Linux run is necessary but not sufficient.
This section exists so nobody has to infer from the rest of the page which half is which.
As it stands, **criterion 6 is not satisfied by this document alone.**

Windows-measured, on `MINGW64_NT-10.0-26200`, bash 5.2.37, 22 cores:

- The per-fork contention curve the margin is derived from: 30.6 ms idle, 44.5 ms at 3 fork-heavy competitors, 61.7 ms at 6, 124.0 ms at 12.
- The elapsed figures for an empty home, 74 s before the subprocess reductions and 64-70 s after, and the 72 s / 76 s / 123 s runs the raised bound is argued from.
- The per-stage attribution a truncated startup prints, including the 9.9 s `startup` stage.
- `fm_session_start_default_budget` and `fm_session_start_resolve_budget` answering `300` / `300` / `45` / `300`.

All of that was taken BEFORE the fix rounds, so what it verifies is the margin's cost INPUT and the original resolver, not the behaviour those rounds introduced.

NOT yet exercised on MINGW64, and this is the outstanding step:

- The 4 s nesting margin actually in force, and the 356 s ceiling it derives there rather than 359 s.
- The fail-closed fallback to the platform default when no registration can be read.
- `fm_session_start_bind_budget` and `fm_session_start_bind_context`, which assign rather than print, and the two-argument `fm_session_start_resolve_budget`.
- The `FM_SESSION_START_RESOLVED_BOUND` handover that `bin/fm-startup-network.sh`'s `delivery_budget` now depends on.
- The clamped-path subprocess count, which is the Linux count above; the count is portable but it has not been re-confirmed on the target.

Why it is not in this document: this pipeline runs on Linux, and the worker that would run the probe cannot read the pipeline-owned commits, so the Windows behaviour run has to happen against the pushed branch instead.
That run is owed before this work is reported complete, and until it is recorded here the Linux evidence on this page is explicitly not a substitute for it.

## What the per-platform margin cost, measured

Same interposer, counting process creations for the library alone rather than for a whole session start, since that is where the change is:

| Path | Before | After |
|---|---|---|
| Parent: source the library and resolve the DEFAULT bound | 4 forks, 1 exec | 3 forks, 1 exec |
| Bounded child: source the library only | 0 | 2 forks, 1 exec |
| Parent: source, clamp an explicit over-cap bound, and emit the advisory | 13 forks, 3 execs | 7 forks, 2 execs |

The `uname -s` moved from `fm_session_start_default_budget`'s body to a single resolution when the file is sourced, so the parent's default path did not get more expensive - it got one fork cheaper, because `fm_session_start_bind_budget` assigns instead of printing and so no longer needs a command substitution around the resolution.
The clamped row fell twice: to 9 when the cap stopped being derived twice, and to 7 when the hook context stopped being probed twice.
Both derivations run only when an explicit `FM_SESSION_START_TIMEOUT` is set, so no ordinary session start reaches either.
The bounded child, which sources the library for its stage marks and never asks for a bound, now pays that `uname`: **3 process creations it did not pay before**, against the 789 the blocking path costs, which is 0.4%.
That is the price of the margin being a plain variable that the clamp and the banner both read, and it is recorded rather than rounded away.

## Falsification: every guard shown FAILING with its protection removed

"It passes" is not evidence.
Each mutation below was applied to the working tree, the named suite was run, and the file was restored from a byte-for-byte backup afterwards; `git status` is clean of them.
The line quoted is the actual `not ok` the suite printed.

| # | Guard, and the commit that added it | Mutation | Suite |
|---|---|---|---|
| M1 | the registrations outlive the bound (`fd3f716`) | `.claude/settings.json` timeout 360 -> 180, the pre-`fd3f716` value | hook-nesting |
| M2 | the ceiling is derived over every arm (`fd3f716`) | platform matrix shrunk to `Linux` | hook-nesting |
| M3 | the harness ceiling clamp (`ceecac8`) | the clamp removed from `fm_session_start_resolve_budget` | hook-nesting |
| M4 | the remedy is conditional (`ceecac8`) | the remedy always advises the knob | bound |
| M5 | zero-padded bounds rejected (`773687c`) | the base-10 normalisation removed | bound |
| M6 | hook context must be POSITIVE (`773687c`) | no marker, therefore `direct` - the tempting shortcut | bound |
| M12 | the clamp is scoped to hook context (`773687c`) | the direct-run exemption removed | bound |
| M7 | the per-platform nesting margin (this round) | the Windows arm dropped | hook-nesting |
| M8 | one margin, read by clamp and banner alike (this round) | a second literal margin in the banner | hook-nesting |
| M9 | the ceiling fails CLOSED (this round) | the `&&` short-circuit restored | bound |
| M10 | `/dev/null` never reaches the cleanup (this round) | the guard removed | bound |
| M11 | the shortened churner still catches the spill (this round) | the group redirection removed from `fm_lock_read_owner_pid` | watcher-lock |

```console
$ # M1
not ok - .claude/settings.json kills the session-start hook after 180s while the digest may bound itself at 300s: the harness preempts the STARTUP TRUNCATED banner, so an over-budget startup loses its wake-queue drain and supervision instructions with nothing printed
$ # M2
not ok - the ceiling 120s is below the Windows default 300s: the derivation stopped covering the raised arm, which is how a 180s registration passed this check before
$ # M3
not ok - FM_SESSION_START_TIMEOUT=3600 on 'Linux' resolves to 3600s, at or above the 360s harness hook timeout: the harness kills the hook first, so there is no STARTUP TRUNCATED banner, no named stage and no reconcile list
$ # M4
not ok - a run already bounded at the 359s ceiling was still told to raise FM_SESSION_START_TIMEOUT, got: ●  If it truncates again, raise FM_SESSION_START_TIMEOUT - to at most 359s, above
$ # M5
not ok - unusable bound '00' on MINGW must fall back to the 300s platform default, got '00'
$ # M6
not ok - with no marker and no terminal on stderr the context must be 'undetermined', got 'direct'
$ # M12
not ok - a positively established direct run must be honoured IN FULL (3590s), got 359s: the operator's own rerun is the remedy the truncation banner prescribes and nothing kills it at the hook timeout
$ # M7
not ok - the Windows nesting margin is 1s, below the 2728ms the measured 22-subprocess prologue and banner cost at 124ms per fork: the harness kills the parent mid-banner, so a truncation prints no stage and no reconcile list
$ # M8
not ok - the raise advice on the Windows arm must name the 360s registration as the second the harness kills at, got: ●  If it truncates again, raise FM_SESSION_START_TIMEOUT - to at most 357s, above
$ # M9
not ok - with no readable registration an over-default bound must fall back to the 300s platform default, got 3000s: honouring it in full is the same silent kill a wrong 'not a hook' produces
$ # M10
not ok - the cleanup asked rm to delete /dev/null; running as root in a container that removes /dev/null for everything else running in it
$ # M11
not ok - reading the owner pid file while it is deleted underneath spilled to stderr, which bin/fm-session-start.sh merges into the digest with 2>&1: bin/fm-wake-lib.sh: line 362: .../.contend.lock.owner/pid: No such file or directory
```

Two limits of this record, stated rather than left to be discovered.
M7 falsifies the margin's SHAPE - that the Windows arm exists and covers the measured product - and not the input itself, which is a measurement and is falsifiable only by re-measuring on the target box.
The 22-subprocess, 2728 ms input M7 was run against has since been RETRACTED as the wrong path, and M13 below is the same guard re-run against the corrected clamped-path figure; the output above is kept as the record of what was run at the time, not as a citable derivation.
M8 catches a second margin that DISAGREES with the first; it cannot catch both sites being changed to the same wrong value, which is why the derivation above is recorded rather than only asserted.

### Second round: the margin re-derivation, the delivery bound and the real nesting invariant

Same method: applied to the working tree, the named suite run, the file restored from a byte-for-byte backup afterwards.
The line quoted is the actual `not ok` the suite printed.

| # | Guard | Mutation | Suite |
|---|---|---|---|
| M13 | the margin covers the CLAMPED path | margin back to the 3 s the wrong default-path derivation gave | hook-nesting |
| M14 | registrations clear bound-plus-margin | all three registrations lowered 360 -> 302 | hook-nesting |
| M15 | a clamped bound plus its margin fits the registration | the ceiling stops subtracting the margin | hook-nesting |
| M16 | the floor really carries a margin | the floor degenerates to the bare maximum bound | hook-nesting |
| M17 | the detached worker uses the digest's bound | the delivery bound re-resolves from the worker's own context | bound |
| M18 | the parent hands the bound over | `FM_SESSION_START_RESOLVED_BOUND` dropped from the child's `env` | bound |

```console
$ # M13
not ok - the Windows nesting margin is 3s, below the 3968ms the measured 32-subprocess clamped path costs at 124ms per fork: the harness kills the parent mid-banner, so a truncation prints no stage and no reconcile list
$ # M14
not ok - .claude/settings.json kills the session-start hook after 302s, below the 304s that the largest platform bound plus its own nesting margin needs: the harness preempts the STARTUP TRUNCATED banner mid-print, so an over-budget startup loses its wake-queue drain and supervision instructions with nothing printed
$ # M15
not ok - on 'Linux' a clamped bound of 360s plus its 1s margin is 361s against the 360s shortest registration: an operator who follows the banner's own advice to the printed ceiling has the harness kill the parent mid-banner
$ # M16
not ok - the 300s registration floor does not exceed the 300s maximum default bound, so it carries no margin at all and section 2 is back to the weaker check
$ # M17
not ok - the detached worker resolved 359s while the digest is bounded at 718s: from 359s to 718s the digest is still running and the worker has stopped offering inline delivery, so the result arrives as a durable wake instead of in the digest the operator is waiting on
$ # M18
not ok - the parent forked its bounded child without handing over the 1s bound it resolved, so the detached network worker re-derives its inline-delivery window from its own hook context and can silently stop delivering while the digest is still running
```

M14 is the failing sequence the finding named, and it is worth stating what the previous guard did with it: 302 is greater than the 300 s maximum default bound, so the old `timeout > bound` comparison passed it while the harness would have preempted the banner by up to a margin.
The guard now compares against 304, which is that bound plus the widest platform margin, so the same registration fails.

M3 and M9 from the first round were re-run against the refactored code rather than assumed to still hold, since both functions changed shape.
M3 now fails at the clamped-path invariant rather than at the override section, because that invariant is asserted first:

```console
$ # M3, re-run
not ok - on 'Linux' an over-ceiling override did not resolve to the 359s ceiling the assertion above checked
$ # M9, re-run
not ok - with no readable registration an over-default bound must fall back to the 300s platform default, got 3000s: honouring it in full is the same silent kill a wrong 'not a hook' produces
```

### Third round: the platform seam, the Cursor floor and the second dedup

| # | Guard | Mutation | Suite |
|---|---|---|---|
| M19 | a platform override reaches the MARGIN, not just the budget | the margin goes back to being resolved only at source time | bound, and again in hook-nesting |
| M20 | the Cursor registration clears bound-plus-margin | `.cursor/hooks.json` sessionStart timeout lowered 360 -> 302 | cursor-primary |
| M22 | the clamp lands on the arm's own ceiling | the clamp shifted by a literal, the shape a second margin would produce | hook-nesting |
| M23 | the binder defines every value it returns | the hook context left unbound on the default path | bound |

```console
$ # M19, bound suite
not ok - the MINGW ceiling 359s is not below the host's 359s: the platform override is not reaching the nesting margin, so every MINGW assertion here is checking the host's number
$ # M19, hook-nesting suite
not ok - the MINGW ceiling is not below the Linux one, so the platform arms are not distinguishable here and the loop above proves nothing about Windows
$ # M20
not ok - the session-open timeout must reach bin/fm-session-start.sh's highest default budget plus its nesting margin (304s), or Cursor kills the hook before the truncation banner is printed
$ # M22
not ok - on 'MINGW64_NT-10.0-26200' an over-ceiling override did not resolve to the 356s ceiling the assertion above checked
$ # M23
not ok - fm_session_start_bind_budget '' left one of its return values undefined, so a caller running under 'set -u' aborts before forking the bounded child: _: line 4: FM_SESSION_START_CONTEXT: unbound variable
```

M23 is a regression this round INTRODUCED and the suite caught, recorded because the near-miss is the useful part.
Threading the hook context to the advisory bound it only on the clamped path, so on the default path - every ordinary session start - `bin/fm-session-start.sh` read a variable that was never set, under `set -u`, before forking the bounded child.
The binder now always assigns all three of its return values, and the case above runs a real `set -u` shell that reads every one of them on every input class.

M19 is the one worth reading twice.
Before the seam was made symmetric, an in-process `FM_PLATFORM_UNAME_OVERRIDE=MINGW... fm_session_start_resolve_budget ...` returned the Windows BUDGET beside the HOST's MARGIN, so every case labelled MINGW was checking a ceiling that arm never uses - 359 s where the arm resolves 356 s.
The mutation restores exactly that state, and the cross-arm assertions now added to both suites are what refuse it.
M22's failure message naming `MINGW64_NT-10.0-26200` and 356 s is the same seam working: before this round that case could only ever see the host's number.

### What is NOT independently falsifiable, said plainly

**The cap dedup has no guard and cannot have one.**
`fm_session_start_bind_budget` exists so the cap is derived once instead of twice, but a second derivation returns the SAME answer - same context, same registrations - at a higher cost.
There is no observable behaviour to assert, so no mutation of it can be made to fail a test, and adding a case that merely exercised the function would be coverage-shaped and evidence-free.
Its evidence is the measurement above instead: 13 forks to 9 on the clamped path, taken with the validated interposer.
That matters here rather than being a performance footnote, because the margin's slack depends on the count and those four process creations are inside the window the margin pays for.

**The per-arm equality inside the override loop is redundant, not load-bearing.**
`[ "$got" -eq "$armcap" ]` compares the resolver's answer against a ceiling derived through the same code on the same arm, so it is an identity in the same way the clamped-path invariant below is.
Deleting that one line leaves the suite green, which is stated here rather than left for someone to discover.
What actually refuses the seam regression is the CROSS-arm assertion beside it - the MINGW ceiling must be strictly below the host's - and M19 is that line failing.
The equality is kept because it extends to all twelve arms a check the later cases make on two, not because it is a second opinion.

**The clamped-path invariant overlaps its neighbours by construction.**
`cap + margin <= min_registration` is an identity given that the ceiling IS `min_registration - margin`, so every mutation of the ceiling is caught by more than one case.
It is asserted first, and over every platform arm rather than the two the equality checks cover, which is what M15 demonstrates - but it is a restatement of the invariant, not an independent probe of it, and it should not be read as a second opinion.

## The truncation fixtures raced the improvement they ship beside

Three cases in `tests/fm-session-start-bound.test.sh` assert what a startup prints when it hits its bound, and the smallest bound `timeout` accepts is 1 s.
Whether the digest against a stubbed toolchain and an empty home outlasts one second is a property of the box, not of the code under test - and this branch keeps making that digest cheaper, so the fixture was racing its own subject.

Measured directly, running the real script against the fixture's shape and counting how often the banner appeared:

| Tree | Truncated |
|---|---|
| before this round's dedups | 6 runs out of 6 |
| after them | 3 runs out of 6 |

So it was not yet flaky when it shipped and it became flaky here, which is the useful part: the failure mode arrives with the next fork saved, not with a bad edit.
The detection stubs now carry a fixed delay, applied after the toolchain is built so the `rm` and `env` recorders those cases add are not slowed with it, and the digest is reliably longer than its bound.
Five consecutive full runs of the suite pass 18 of 18 afterwards, against roughly one failure in three before.

## The lock-pid race case, and what shortening it cost

`tests/fm-watcher-lock.test.sh`'s lock-pid read race churned the pid file 4000 times, and `rm -f` is not a builtin, so that is 4000 process creations: 2.7 s here and, at the 42 ms a fork costs under MSYS, about 168 s for one case on the platform this whole branch is scoped to.
The churn is now bounded by wall clock instead - at most a second, less when bash's whole-second `SECONDS` ticks early - and keeps running past that slice only while an outcome has not been observed.

| | Churn iterations | Wall |
|---|---|---|
| before | 4000 | 2.728 s |
| after | 257 | 0.162 s |

The reduction was checked against the regression rather than assumed harmless.
With the group redirection removed from `fm_lock_read_owner_pid`, the shortened loop still spilled 8804, 19809, 15975, 16756 and 16756 bytes of bash's own `No such file or directory` to stderr on five consecutive runs, and M11 above is that same mutation failing the real suite.

## Reproducing

```console
$ gcc -shared -fPIC -O2 -Wall -o forkcount.so forkcount.c -ldl
$ git clone --no-hardlinks <repo> r && git -C r checkout -B main <ref>
$ mkdir -p h/data h/state h/config h/projects
$ for i in 1 2 3; do
    FM_HOME=h FORKCOUNT_LOG=forks.$i.log LD_PRELOAD=./forkcount.so \
      bash r/bin/fm-session-start.sh >/dev/null 2>&1
    sleep 8
    printf '%s blocking\n' "$(( $(grep -c '^FORK' forks.$i.log) \
      - $(awk -F'\t' '$1=="FORK" && $2 ~ /fm-startup-network/' forks.$i.log | wc -l) ))"
  done
```

Runs 2 and 3 are the steady-state figure.
The interposer is 60 lines and is not committed; it interposes `fork`, `execve` and `posix_spawn`, appends `kind<TAB>caller-cmdline<TAB>target`, and must include `<stdlib.h>` - an implicit `getenv` returns `int` and truncates the pointer on 64-bit, which silently disables logging.
