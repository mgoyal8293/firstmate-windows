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

## The nesting margin, and why it is 3 s on Windows

The runtime bound governs the BOUNDED CHILD.
The harness kills the PARENT, and the parent spends time outside that child at both ends, so the hook's wall time is prologue + bound + banner.
A margin sized only for the equal-deadline race covers neither end, and the operator who does exactly what the truncation banner tells them - raise `FM_SESSION_START_TIMEOUT` to the printed ceiling - then loses the banner outright on MSYS.
`FM_SESSION_START_NESTING_MARGIN` in [`../../bin/fm-session-start-bound-lib.sh`](../../bin/fm-session-start-bound-lib.sh) is therefore per platform, by the same `uname -s` arms as the default budget.

### What the margin owes

Counted with the same `LD_PRELOAD` interposer described above, validated against the same known-count program before use, and counted rather than grepped:

| Side of the bound | Work | Subprocesses |
|---|---|---|
| Before the fork | `bin/fm-session-start.sh`'s `SCRIPT_DIR`/`FM_ROOT` resolution, the `fm-session-start-bound-lib.sh`, `fm-timeout-lib.sh` and `fm-session-lock-lib.sh` sources with their transitive prologues, and the stage-file `mktemp` | ~10 |
| After the kill | `fm_session_stage_last`, the pending-stage `awk`/`tr` pipeline, `fm_session_start_bound_remedy` and `fm_session_stage_render` | ~12 |
| | | **22** |

The count is portable and is taken on Linux; only the per-fork cost is not.

### The per-fork cost on the target

Measured on the box the defect lives on: `MINGW64_NT-10.0-26200`, bash 5.2.37, 22 cores.
The pattern being timed is that same 22-subprocess shape, run against fork-heavy competitors:

| Competing fork-heavy processes | Per fork | The 22-subprocess pattern |
|---|---|---|
| 0 | 30.6 ms | 639 ms |
| 3 | 44.5 ms | 903 ms |
| 6 | 61.7 ms | 1316 ms |
| 12 | 124.0 ms | 2574 ms |

**Pure CPU load was the wrong model and was discarded.**
Four busy-loop burners made forks FASTER, 25 ms against 30 ms idle, through frequency boost.
The real competitor is a test lane, which contends for PROCESS CREATION, and MSYS serialises that - hence fork-heavy competitors rather than CPU burners.

### The derivation, and what it does not claim

22 subprocesses x 124.0 ms = 2728 ms, ceiling to whole seconds = **3 s**.
Off Windows the margin stays 1 s: forks cost about 1 ms here, so the same product is well under a second, and 1 s is the strict-inequality margin the equal-deadline race needs.

The corroboration is reported the way it came out.
The direct pattern timing at 12 competitors was 2574 ms, which is LOWER than the 2728 ms count-times-cost product, so the chosen 3 s is the conservative side of two independent instruments that agree.

What this does NOT claim: the per-fork cost rises with contention, so no fixed margin is safe at unbounded contention.
3 s covers the measured worst case on that box.
It is not a proof of sufficiency.

### One value, read by both the clamp and the banner

`fm_session_start_hook_ceiling` subtracts the margin to derive the highest bound it will allow, and `fm_session_start_budget_advisory` and `fm_session_start_bound_remedy` add it back to name the second the harness will actually kill at.
A second literal anywhere would let the number the operator is told diverge from the number in force, which is the failure the margin exists to prevent, so mutation M8 below is what holds them together.

## What the per-platform margin cost, measured

Same interposer, counting process creations for the library alone rather than for a whole session start, since that is where the change is:

| Path | Before | After |
|---|---|---|
| Parent: source the library and resolve the DEFAULT bound | 4 forks, 1 exec | 4 forks, 1 exec |
| Bounded child: source the library only | 0 | 2 forks, 1 exec |
| Parent: source and clamp an explicit over-cap bound | 5 forks, 1 exec | 8 forks, 2 exec |
| The truncation banner's remedy | 3 forks, 1 exec | 7 forks, 2 exec |

The `uname -s` moved from `fm_session_start_default_budget`'s body to a single resolution when the file is sourced, so the parent's default path is unchanged.
The bounded child, which sources the library for its stage marks and never asks for a bound, now pays that `uname` too: **3 process creations it did not pay before**, against the 789 the blocking path costs, which is 0.4%.
That is the price of the margin being a plain variable that the clamp and the banner both read, and it is recorded rather than rounded away.
The clamp and remedy paths cost more because they now go through one owner of "what caps this bound and why" instead of two ad-hoc derivations; both run only when an explicit `FM_SESSION_START_TIMEOUT` is set or after a truncation, so no ordinary session start reaches either.

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
M7 falsifies the margin's SHAPE - that the Windows arm exists and covers the measured product - and not the 2728 ms input itself, which is a measurement and is falsifiable only by re-measuring on the target box.
M8 catches a second margin that DISAGREES with the first; it cannot catch both sites being changed to the same wrong value, which is why the derivation above is recorded rather than only asserted.

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
