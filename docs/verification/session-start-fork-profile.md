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

## The nesting margin, and why it is 32 s on Windows

The runtime bound governs the BOUNDED CHILD.
The harness kills the PARENT, and the parent spends time outside that child at both ends, so the hook's wall time is prologue + bound + banner.
A margin sized only for the equal-deadline race covers neither end, and the operator who does exactly what the truncation banner tells them - raise `FM_SESSION_START_TIMEOUT` to the printed ceiling - then loses the banner outright on MSYS.
`FM_SESSION_START_NESTING_MARGIN` in [`../../bin/fm-session-start-bound-lib.sh`](../../bin/fm-session-start-bound-lib.sh) is therefore per platform, by the same `uname -s` arms as the default budget.

### Four derivations retracted, in order

The first counted 22 subprocesses on the DEFAULT path and landed on 3 s.
That is WRONG and must not be cited: the default Windows bound is 300 s against a ceiling in the 330s, so the default path can never reach the ceiling, and only a CLAMPED bound ever equals it.
The 2574 ms end-to-end corroboration recorded beside it is retracted with it, for the same reason - it timed the default-path pattern.

The second counted the clamped path as 11 (default pre-fork) + 6 (clamped extra) + 15 (banner) = 32.
That decomposition NO LONGER DESCRIBES THE CODE: after the cap and hook-context dedups, `fm_session_start_bind_budget` derives the cap whenever ANY explicit bound is set, so there is no "only when clamped" extra to separate out, and the clamped and unclamped parent sides measure the same.

The third was the per-creation cost that produced a 4 s margin: 46.5 ms per pure subshell fork and 80.8 ms per fork+exec, presented as an IDLE floor.
**Those figures were not taken at idle.**
Twenty-one orphaned competitor processes from two earlier timed-out measurement runs were still on the box, reparented to PID 1, and were not noticed until afterwards.
They are kept named rather than deleted so nobody re-derives from them, and they are superseded entirely by the sweep below.

The fourth was a **13.1 s direct idle parent side**, which produced a 22 s margin.
It too was inflated by uncontrolled box load.
The clean idle value is **2.06 s**, from the 9-sample dataset below, and 13.1 s must not be cited.

### What the parent side actually costs, measured end to end

Method, and each part of it is load-bearing:

- `LD_PRELOAD` interposer on `fork`, `execve` and `posix_spawn`, one record per call. Process creations are the FORK records plus the SPAWN records; EXEC is exec-after-fork and would double-count every ordinary command. The interposer is committed as [`../../tests/fixtures/forkcount.c`](../../tests/fixtures/forkcount.c) and built at test time.
- Validated against a known-count program before use: 7 creations asked for, 7 counted. A built-but-miscounting instrument fails the suite rather than skipping - and that is now true rather than merely stated, because the two conditions carry different exit statuses and the caller raises the failure from outside the command substitution that would otherwise swallow it (M26 below).
- The two sides are separated by ENV INHERITANCE, not by a process tree. The bounded child is launched through `env FM_SESSION_START_STAGE_FILE=...`, so `getenv("FM_SESSION_START_STAGE_FILE")` is the exact discriminator: absent is the parent side the margin owes, present is the bounded child. A ppid walk does NOT work here - the digest detaches its network stage, the subtree reparents, and the walk fragments; tried, and it silently reported 0 child forks against 5743 real ones.
- The clamp is forced cheaply by pointing `FM_SESSION_START_REGISTRATION_ROOT` at a synthetic root whose SessionStart timeout is 2 s, so the ceiling is 1 s and the whole clamped path plus the truncation banner really runs in about a second.

Result, on the Linux box this suite runs on:

| Quantity | Value |
|---|---|
| Parent-side process creations | **39**, deterministic across three runs |
| of which exec-backed | 20 |
| of which pure subshell forks | 19 |
| `posix_spawn` calls | 0 |

A second reviewer measured **40** on the same method with the same synthetic root: 20 exec-backed and 20 pure.
The exec-backed halves match exactly, so both measured the same path; the spread is one bash subshell.
Both numbers are kept rather than reconciled.

**The count is not written down.**
[`../../tests/fm-session-start-hook-nesting.test.sh`](../../tests/fm-session-start-hook-nesting.test.sh) rebuilds the interposer, revalidates it, reruns the clamped path and recounts, then fails when the count RISES above the highest figure on record.

### The per-creation cost on the target, measured cleanly

Measured on `MINGW64_NT-10.0-26200`, bash 5.2.37, 22 cores.
N=40 process creations per sample, timed with `date +%s%N`; competitors are fork-heavy bash loops.
The harness kills every competitor on ANY exit path through a trap, and each run prints its own pre-run and post-run stale-competitor count; both read 0 on every run below.
That self-cleaning trap is precisely the fix for what corrupted the retracted figures.

The "modelled parent side" column is a MODEL, not a direct timing: it applies the measured per-creation costs to the measured parent-side mix of 20 exec-backed plus 20 pure creations.

Sweep A, box otherwise idle:

| Competitors | Pure | Exec | Modelled parent side |
|---|---|---|---|
| 0 | 25.1 ms | 37.8 ms | 1258 ms |
| 4 | 58.3 ms | 101.9 ms | 3204 ms |
| 8 | 51.4 ms | 105.6 ms | 3140 ms |
| 16 | 113.9 ms | 316.7 ms | 8612 ms |
| 24 | 2497.5 ms | 397.2 ms | 57894 ms |

Sweep B, 3 repeats per point, taken while the validation pipeline was itself running on the same box - realistic concurrent load rather than a synthetic-only condition:

| Competitors | Repeat | Pure / Exec | Modelled parent side |
|---|---|---|---|
| 12 | r1 | 606.5 / 425.9 ms | 20648 ms |
| 12 | r2 | 317.9 / 445.0 ms | 15258 ms |
| 12 | r3 | 224.6 / 620.8 ms | 16908 ms |
| 16 | r1 | 267.7 / 641.2 ms | 18178 ms |
| 16 | r2 | 244.9 / 765.6 ms | 20210 ms |
| 16 | r3 | 296.6 / 783.8 ms | 21608 ms |

**What this establishes.**
Under EVERY contended condition modelled, 4 s is EXCEEDED: 3.1-3.2 s at 4-8 competitors is already about 80% of it, 8.6 s at 16 on an otherwise idle box is 2.15x it, and 15.3-21.6 s under real concurrent load is 4-5x it.
The direct timing below is harsher still, so 4 s was not merely unproven - it was too small, and the earlier "sufficiency is unknown" framing is out of date in the other direction.

### The parent side, timed DIRECTLY on the box - the authoritative dataset

This supersedes the model, the retracted figures and the older 30.6 / 44.5 / 61.7 / 124.0 ms per-fork curve.
The model above is an inference; this is a wall clock on the real script.

Method: the real [`../../bin/fm-session-start.sh`](../../bin/fm-session-start.sh) on `MINGW64_NT-10.0-26200`, bash 5.2.37, 22 cores.
Each sample uses a fresh empty throwaway `FM_HOME` and a synthetic registration declaring a 10 s SessionStart timeout, so the ceiling is 6 s and an explicit `FM_SESSION_START_TIMEOUT=9999` is genuinely CLAMPED to it; parent side = total elapsed minus the 6 s bound.
Competitors are fork-heavy bash loops killed by a trap on every exit path.
The truncation banner was VERIFIED PRESENT on all 9 samples, so a run whose bound failed to fire could never be silently averaged in, and the run self-reported a stale-competitor count of 0 afterwards.

| Competitors | Parent side, 3 samples | Mean | Worst |
|---|---|---|---|
| 0 | 2.10 s, 2.13 s, 1.95 s | 2.06 s | 2.13 s |
| 8 | 14.89 s, 8.28 s, 7.83 s | 10.3 s | 14.89 s |
| 16 | 31.20 s, 19.78 s, 21.44 s | 24.1 s | **31.20 s** |

**24 competitors is deliberately excluded from the derivation.**
It is past the 22-core count and thrashes - the earlier per-creation sweep measured 2497.5 ms per pure fork there, a 57.9 s modelled parent side.
No fixed margin can cover a thrashing regime, so deriving from it would be meaningless.
The exclusion is recorded rather than the sample deleted, because deleting an inconvenient sample is how a measurement becomes a story.

**The model's standing, corrected.**
At idle the model (1.26 s) and the direct measurement (2.06 s) agree to within the same order, so it is a reasonable idle proxy.
Under contention it UNDERSTATES badly: 8.6 s modelled against a 24.1 s measured mean at 16 competitors, about 2.8x low.
So no margin may be re-derived downward from it; the sweep stays as the cost-input record, not as the source of the number.

### The derivation, and why the conservatism is free

Worst directly measured non-thrashing parent side = **31.20 s**, at 16 fork-heavy competitors.
Rounded up, the MSYS margin is **32 s**.
Off Windows it stays 1 s: creations cost about 1 ms there, and 1 s is the strict-inequality margin the equal-deadline race needs.

**The derived ceiling becomes 360 - 32 = 328 s, and the Windows DEFAULT budget is 300 s - still below it.**
So default behaviour is COMPLETELY UNCHANGED by this margin.
The clamp only ever bites an operator who has explicitly raised `FM_SESSION_START_TIMEOUT` above 328 s.
A large margin therefore costs an ordinary session start nothing at all, which is precisely why the conservative value is the right one rather than a finely tuned smaller one.

This closes the margin question.
It is not to be re-derived or refined without evidence that actively contradicts the dataset above.

### One consumer of the margin, and a carried deadline

The margin has exactly ONE consumer: `fm_session_start_bind_ceiling` subtracts it to derive the highest bound the clamp will allow.
Nothing else reads it.

The banners do NOT reconstruct the kill second from it, and that is a correctness property rather than a tidiness one.
They used to add the margin back to the cap, which reproduces the deadline only while `ceiling = deadline - margin` holds - and the sub-margin branch cannot satisfy that, because no non-negative ceiling can when the registration is smaller than the margin.
So `fm_session_start_cap` carries the deadline it actually read as the third field of its spec (`<seconds> <source> <deadline>`, with `0` on the `default` arm where none was read), and `fm_session_start_budget_advisory` and `fm_session_start_bound_remedy` print that field.
There is no second place the number can be derived, so the two cannot drift.

A second literal margin anywhere still moves the ceiling and still fails `test_the_clamp_and_the_banner_agree_on_the_margin`, which is what M8 below falsifies.

## One bound for the digest and the detached worker

`bin/fm-startup-network.sh` keeps offering its result for inline delivery for exactly as long as the digest could still be running.
That has always been meant as one bound; it is now one RESOLUTION as well, and the difference is a real defect that this branch introduced and this round closes.

The worker is detached with stdio on `/dev/null`, so `[ -t 2 ]` is false inside it and `fm_session_start_hook_context` can never answer `direct` there.
Re-resolving `FM_SESSION_START_TIMEOUT` in the worker therefore does not reproduce the digest's bound, it reproduces the CLAMP.
The failing sequence is the one the truncation banner itself prescribes: rerun from a terminal with the timeout raised above the ceiling, and the digest runs at the raised value while the worker stops offering inline delivery at the ceiling - silently, for the rest of the run.
The result is not lost, it still surfaces as a durable wake, but it stops arriving in the digest the operator is sitting in front of.

`bin/fm-session-start.sh` now resolves the bound once and exports it as `FM_SESSION_START_RESOLVED_BOUND` on the same `env` that forks the bounded child, which the worker inherits.
`fm_session_start_delivery_bound` prefers it and falls back to a local resolution only when there is no digest to inherit from, which is the standalone case.

## The runtime bound IS enforced on MSYS: 12 of 12

An earlier round recorded this as an OPEN, high-severity observation: with the bound clamped to 6 s, three of four runs reached 34.1 s, 270.6 s and 261.0 s with no truncation banner.
**That observation is WITHDRAWN.** It was the measurement harness, not the shipped code.

What a correctly cleaned harness shows, on `MINGW64_NT-10.0-26200`:

- The bound fired on **12 of 12** samples - 3 diagnostic runs plus the 9-sample timed sweep above. The clamp resolves to 6 s and the truncation banner printed on every one.
- `fm_run_timed` was also exercised directly: `rc=124` at about 2.2 s on 5 of 5 repeats against a 2 s bound, including against a child that installs `trap "" TERM`, so the `-k` kill path works too.

This is kept as a positive Windows result rather than deleted, because it is the opposite of what the earlier round concluded and because it is real verification of acceptance criteria 1 and 2 on the target platform.
The retracted samples are named here so nobody re-derives an enforcement doubt from them.

## Windows verification: what is measured there, and what is NOT

Acceptance criterion 6 for this work says the change must be verified on the real Windows box, and that a clean Linux run is necessary but not sufficient.
This section exists so nobody has to infer from the rest of the page which half is which.
As it stands, **criterion 6 is not satisfied by this document alone.**

Windows-measured, on `MINGW64_NT-10.0-26200`, bash 5.2.37, 22 cores:

- The direct 9-sample parent-side sweep the 32 s margin is derived from: 0, 8 and 16 competitors with three samples each, truncation banner verified present on every one. This is the measurement of record.
- The earlier per-creation contention sweep (Sweep A and Sweep B), kept as the cost-input record. It is a reasonable idle proxy and understates by about 2.8x under contention, so no margin may be re-derived downward from it.
- ~~The earlier per-fork contention curve, 30.6 / 44.5 / 61.7 / 124.0 ms~~ and ~~the 46.5 / 80.8 ms per-creation figures~~ - both SUPERSEDED by that sweep, and the second was taken with 21 orphaned competitors still running. Kept named so nobody re-derives from them.
- The elapsed figures for an empty home, 74 s before the subprocess reductions and 64-70 s after, and the 72 s / 76 s / 123 s runs the raised bound is argued from.
- The per-stage attribution a truncated startup prints, including the 9.9 s `startup` stage.
- `fm_session_start_default_budget` and `fm_session_start_resolve_budget` answering `300` / `300` / `45` / `300`.
- **The clamped path timed directly across three contention levels**, 9 samples at 0, 8 and 16 competitors with the truncation banner verified present on every one, giving the 31.20 s worst non-thrashing parent side the 32 s margin rests on.
- **That the runtime bound is enforced**, 12 of 12, plus `fm_run_timed` returning rc=124 on 5 of 5 against a 2 s bound including against a child that installs `trap "" TERM`, so the `-k` kill path works too.
- ~~A full, untruncated session start at the Windows default bound: 57.5 s / 48.0 s at 0 competitors, 240.7 s / 264.0 s at 8, 80-88% of the budget consumed~~ - **WITHDRAWN.** Those runs came from the same harness whose bound-enforcement anomaly was retracted as an artifact, so they are not trustworthy and must not be cited. They are named here rather than deleted so nobody resurrects them.

NOT yet exercised on MINGW64, and this is the outstanding step:

- The 32 s nesting margin actually in force, and the 328 s ceiling it derives there rather than the portable one. Note this changes nothing for a default run: the Windows default budget is 300 s, already below 328 s.
- The fail-closed fallback to the platform default when no registration can be read.
- The deadline predicate: that a transport declaring no kill deadline keeps its full bound and is never pointed at another harness's registrations.
- `fm_session_start_bind_budget` and `fm_session_start_bind_context`, which assign rather than print, and the two-argument `fm_session_start_resolve_budget`.
- The `FM_SESSION_START_RESOLVED_BOUND` handover that `bin/fm-startup-network.sh`'s `delivery_budget` now depends on.
- The parent-side creation count. It is derived at test time on Linux and the count is portable, but it has not been re-confirmed on the target, and the interposer's `LD_PRELOAD` mechanism is not available under MSYS - the guard skips there with an explicit message rather than passing silently.
- **A clean full-startup-to-completion timing under contention.** The figures that once stood here are withdrawn above, and no replacement was taken. This is why the headroom of the 300 s default against a contended, populated home is an open question rather than a measured result - see the provenance in [`../../bin/fm-session-start-bound-lib.sh`](../../bin/fm-session-start-bound-lib.sh).

Criterion 6 is therefore PARTLY discharged by real execution rather than still wholly owed: the direct 9-sample clamped parent-side sweep, the 12-of-12 bound-enforcement result, the direct `fm_run_timed` check and the clean per-creation contention sweeps were all run on the box against the current shape.
What is listed above as not yet exercised there is still not exercised there, and the claim is not upgraded past what was actually run.

Why the rest is not in this document: this pipeline runs on Linux, and the worker that would run the probe cannot read the pipeline-owned commits, so the remaining Windows behaviour runs have to happen against the pushed branch instead.
Those are owed before this work is reported complete, and until they are recorded here the Linux evidence on this page is explicitly not a substitute for them.

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

**M13's quoted figures are RETRACTED inputs, and its guard no longer exists.**
The line it printed cites a 3 s margin, a 32-subprocess clamped path and a 124 ms per-fork cost; all three are retracted above - the 32-subprocess decomposition no longer describes the code, and the 124.0 ms curve is superseded by the clean sweep.
The case it names, `test_the_nesting_margin_covers_the_windows_clamped_path`, was removed when the count guard replaced it; the surviving margin case asserts only that both arms exist and the Windows one is strictly larger.
So this row is the record of what was run at the time, not a citable derivation and not a live guard.

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

### Fourth round: the deadline predicate and the derived count

| # | Guard | Mutation | Suite |
|---|---|---|---|
| M24 | a transport that arms no deadline keeps its full bound | the no-deadline declaration ignored | bound |
| M25 | the parent-side creation count has not risen | one extra `/bin/true` on the parent side | hook-nesting |

```console
$ # M24
not ok - a transport that arms no deadline was clamped from 718s to 359s by a ceiling derived from registrations belonging to harnesses that are not running
$ # M25
not ok - the parent side now execs 21 external commands, above the 20 on record: every one is paid inside the window the nesting margin covers, and that margin is already NOT established as sufficient under contention - so re-derive the margin from a fresh measurement rather than raising this ceiling
```

M25 took two attempts to make honest, and the first attempt is worth recording.
With a single total ceiling set at 40 - the higher of the two measurements on record - one added creation on a box that measures 39 was absorbed and the suite stayed GREEN, which is precisely the direction the guard exists to catch.
The fix was to hold the component the two measurements AGREE on exactly: both counted 20 exec-backed creations, so that is a hard ceiling, and the total keeps the looser one so the guard cannot false-fail on whichever box is right.
An added external command now fails immediately; an added bash subshell on the 39-count box is still absorbed until it exceeds 40, and that residual is stated rather than papered over.

### Fifth round: the instrument's own validation, the Pi declaration and two wording defects

| # | Guard | Mutation | Suite |
|---|---|---|---|
| M26 | a miscounting instrument FAILS rather than skips | the interposer drops two of every three FORK records | hook-nesting |
| M27 | the Pi extension declares that no deadline binds it | the declaration deleted from the spawn options | pi-sessionstart-deadline |
| M28 | the remedy names a kill second only where a deadline was established | the `binds` condition dropped from the wording branch | bound |
| M29 | a registration smaller than the margin still bounds the clamp | that case reports as unreadable again | bound |

```console
$ # M26
not ok - the fork interposer disagreed with the known-count program (7 creations asked for), so every number it would report is untrustworthy: fix or rebuild tests/fixtures/forkcount.c rather than skipping the count guard
$ # M27
not ok - the Pi extension spawned the session start WITHOUT declaring that no kill deadline binds it, so that digest is clamped by the Claude, Codex and Cursor registrations and told a kill second that does not exist under Pi; the wrapper was handed: FIRSTMATE_OP: v1 session-start: FM_SESSION_START_HOOK_DEADLINE=[<unset>]
$ # M28
not ok - the remedy told a run that could not establish any kill deadline that the harness kills it at a specific second, which is the misdirection the Pi transport was fixed for: ●  If it truncates again, raise FM_SESSION_START_TIMEOUT - to at most 359s, above
$ # M29
not ok - a registration of 2s was reported as UNREADABLE, so the clamp falls back to the 300s platform default - a bound above a kill this shell actually read
```

M26 is the one that matters most, because it repairs a guard that could not fail.
The interposer's self-validation called `fail`, but the function is only ever reached through a command substitution, where `fail`'s `exit 1` leaves the subshell rather than the script - so the non-zero landed on the caller's skip branch and a MISCOUNTING instrument was reported as `ok - SKIPPED`, with the script exiting 0 and the lane green.
The sentence on this page claiming otherwise was false as written.
The two conditions now carry different exit statuses: 1 means the instrument cannot be built or preloaded here, which is a real skip, and 2 means it built and miscounted, which the caller turns into a hard failure from outside the substitution.

M28 and M29 were both added with their guards in the same pass, and neither existed before: the first run of M28 against the pre-existing suite stayed GREEN, which is what showed the wording had no coverage at all.

### Sixth round: the advisory's certainty, and the re-derived margin

| # | Guard | Mutation | Suite |
|---|---|---|---|
| M30 | the advisory names a kill second only where a deadline was established | the `binds` condition dropped from the advisory's wording branch | bound |
| M26 | a miscounting instrument FAILS rather than skips | re-run on this tree after the validation seam was removed | hook-nesting |

```console
$ # M30
not ok - the advisory told a run that could not establish any kill deadline that the harness kills it at a specific second: ●  FM_SESSION_START_TIMEOUT=3590s was CLAMPED to 359s.
$ # M26, re-run
not ok - the fork interposer disagreed with the known-count program (7 creations asked for), so every number it would report is untrustworthy: fix or rebuild tests/fixtures/forkcount.c rather than skipping the count guard
```

M30 is the same defect as M28 one function over.
The wording rule was applied to the truncation remedy and the advisory was missed, which mattered more rather than less: the remedy prints only after a truncation, the advisory prints on EVERY clamped run, and under `undetermined` it was asserting a harness kill second and pointing at registrations in the same block as the hedge that says neither could be established.
Both surfaces now read the same `context` argument, so they cannot describe the same fact with different certainty.

**The removal of `FM_TEST_FORKCOUNT_EXPECT_VALIDATION` has no mutation, and that is stated rather than dressed up.**
It was dead code - nothing in the repo set it - whose only possible effect was to let a miscounting instrument satisfy the check that exists to catch one.
Deleting a seam nothing uses has no independent failure mode to demonstrate; an attempted mutation that reintroduced it and set it to a wrong value failed for the opposite reason (the expectation no longer matched), which proves nothing about weakening.
The evidence that the validation still bites is M26 above, re-run on this tree after the removal.

### Seventh round: the banner must not name a second past the registration

| # | Guard | Mutation | Suite |
|---|---|---|---|
| M32 | no banner names a kill second past the registration it read | both banners go back to reconstructing it as cap + margin | bound |

```console
$ # M32
not ok - a banner told the operator the harness kills at 41s against a registration declaring 20s, so they are 21s past a deadline this shell had already read; advisory: ●  FM_SESSION_START_TIMEOUT=9999s was CLAMPED to 19s.
```

The invariant `ceiling = deadline - margin` is what let both banners rebuild the kill second by adding the margin back, and the sub-margin branch cannot satisfy it - no non-negative ceiling can, when the registration is smaller than the margin.
So the branch that stopped the CLAMP overstating the bound left the BANNERS overstating the deadline, and raising the margin widened the affected band from registrations of 4 s or less to registrations at or below the margin - now 32 s, which brackets the 10 s the nudge tier already uses.
`fm_session_start_cap` now carries the deadline it read as its third field and every operator-facing line prints that field, so there is no longer a second place the number can be derived.

The mutation was applied to both banner sites at once, because reverting either one alone still leaves the other honest and the case would pass for the wrong reason.

### Eighth round: fixture failure must not masquerade as a missing interposer

| # | Guard | Mutation | Suite |
|---|---|---|---|
| M33a | a fixture-setup failure FAILS the count guard | fixture setup forced to fail, fix in place | hook-nesting |
| M33b | the same failure with the protection removed | fixture setup forced to fail, status back to the skip code | hook-nesting |

```console
$ # M33a - the fix fires, naming the real reason
not ok - the parent-side count fixture could not be set up (temp root or git init failed), so the count guard did not run; this is not a missing interposer and must not be reported as one
$ # M33b - protection removed: the identical failure reports a green SKIP
ok - parent-side creation count: SKIPPED - the interposer could not be built or preloaded on this box
SCRIPT EXIT=0
```

The pair is what makes this falsifiable rather than the single red.
M33b is the defect: a working interposer plus an unusable temp root reports green, blames a toolchain that is fine, and silently drops the only automated guard on the parent-side count.
`count_parent_side_creations` now answers with three distinct statuses - 1 cannot build or preload, 2 built but miscounting, 3 fixture setup failed - and only 1 is a skip.

A first attempt at this mutation forced `return 1` directly and stayed green, correctly: that simulates an unavailable toolchain, which is a legitimate skip. It is recorded here because the mutation that proves nothing is worth naming beside the one that does.

**Three fixes this round have no independent behavioural signature, and that is stated rather than papered over.**
Removing the two dead `fm_session_start_bind_margin` calls deletes a no-op side effect; dropping `0` from the missing-deadline case removes a re-derivation whose result was never printed; and the verification-page rewrite is prose.
None of them changes any output, so none can be falsified by a test, and inventing a guard for them would be exactly the coverage-shaped-nothing this criterion exists to catch.
What protects them is that the behaviour they touch is already guarded: the sentinel path is covered by the `default`-arm cases, and the margin's single-consumer property by M8.

### Ninth round: the ceiling must be monotonic and stay under what it read

| # | Guard | Mutation | Suite |
|---|---|---|---|
| M34 | the ceiling is monotonic in the deadline | the non-monotonic `deadline - 1` sub-margin arm restored | bound |
| M35 | the ceiling is always a usable bound | the floor at 1 removed | bound |

```console
$ # M34
not ok - on MINGW64_NT-10.0-26200 a 33s deadline yields a 1s ceiling where a smaller deadline yielded 31s: raising a registration must never collapse the permitted bound
$ # M35
not ok - the ceiling -30s is not a usable bound
```

The deadline a registration declares is a hard upper bound on anything the library may clamp to, at every value rather than only above the margin.
`fm_session_start_bind_ceiling` is now one expression - the deadline minus the margin, floored at 1 - which is monotonic by construction and strictly under the deadline everywhere it is arithmetically possible.

**The one input where it is not possible, stated rather than glossed.**
At a 1 s deadline the ceiling is also 1 s, because the only integer strictly under 1 is 0 and a bound of 0 means no deadline at all - the silent-no-deadline class this branch exists to close, and the same class the zero-padded-bound rejection refuses.
So the equal-deadline race is unavoidable there and the banner may be lost.
The guard asserts that case explicitly rather than excluding it from the sweep.

The new shape is also more conservative than the one it replaces: across the whole sub-margin band it returns 1 rather than `deadline - 1`.
That is the safe direction, and it removes what was the least conservative part of the function.

**The remedy's cap handover has no independent mutation, and that is stated rather than dressed up.**
Passing `FM_SESSION_START_CAP` into `fm_session_start_bound_remedy` instead of letting it re-derive removes a command substitution, a glob and an awk from the post-kill banner window; both derivations read the same registrations in the same shell, so no output changes and nothing can be falsified by a test.
What covers it is that the derived-here path is unchanged and still exercised: the existing remedy cases pass no cap spec at all.

### What is NOT independently falsifiable, said plainly

**The cap dedup has no guard and cannot have one.**
`fm_session_start_bind_budget` exists so the cap is derived once instead of twice, but a second derivation returns the SAME answer - same context, same registrations - at a higher cost.
There is no observable behaviour to assert, so no mutation of it can be made to fail a test, and adding a case that merely exercised the function would be coverage-shaped and evidence-free.
Its evidence is the measurement above instead: 13 forks to 9 on the clamped path, taken with the validated interposer.
That matters here rather than being a performance footnote, because the margin's slack depends on the count and those four process creations are inside the window the margin pays for.

**The Pi declaration IS guarded now, and the guard's shape is worth naming.**
The library honouring a `none` declaration is proven by M24.
The extension continuing to MAKE that declaration was unguarded for one round: deleting one property from the spawn options returned every Pi session start to being clamped by registrations that are not running, with the whole suite green, because the Pi suites only type-check or copy the file.
`tests/fm-pi-sessionstart-deadline.test.sh` closes it behaviourally rather than by grepping the source: it loads the real extension module, calls its real default export with a Pi-shaped stub, fires the real session_start handler, and replaces only the spawned wrapper with a recorder that reports the environment it was actually handed.
A refactor that moves the declaration still passes; a deleted declaration fails.
What it does NOT cover is Pi itself changing how it invokes the extension, which no test in this repo can observe.

**The margin's SUFFICIENCY at unbounded load has no guard, and cannot have one.**
32 s is derived from the worst NON-THRASHING directly measured point, 31.20 s, and the 24-competitor thrashing regime it excludes is one no fixed margin could cover.
So there is no assertion anywhere that the margin covers every condition, because that is not what the measurement supports.
What IS guarded is the count not rising, which is the other input to the same product, and the derivation itself is recorded with its method and its limits rather than asserted in a test.

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

**Two different interposers appear on this page, and this is the other one.**
The instrument in the block above is the RANKED-PROFILE interposer: about 60 lines, never committed, written to attribute forks to their callers.
It appends `kind<TAB>caller-cmdline<TAB>target`, which is what the `$2 ~ /fm-startup-network/` filter above selects on.
The instrument the parent-side count guard uses is [`../../tests/fixtures/forkcount.c`](../../tests/fixtures/forkcount.c), which IS committed and built at test time; it appends `<FORK|EXEC|SPAWN><TAB><parent|child>` instead, discriminating the two sides of the bound by env inheritance rather than naming callers.
The two record formats are not interchangeable: building the committed fixture and running the filter above finds nothing, because the committed fixture emits no cmdline field.

Both must include `<stdlib.h>` - an implicit `getenv` returns `int` and truncates the pointer on 64-bit, which silently disables logging.
