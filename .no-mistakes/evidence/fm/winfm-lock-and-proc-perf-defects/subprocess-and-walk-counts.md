# What the two defects cost, counted rather than timed

The Windows timings live in docs/verification/windows-session-lock-cost.md and were taken
on the author's Windows host. This machine is WSL2 Linux, where a fork is about 1 ms
instead of about 42 ms, so a timing run here would show nothing. The COUNTS below are
the platform-independent half of the same two defects, measured against the base commit
and against HEAD with the identical harness.

## Defect 2: subprocesses created by one fm_proc_field call

Counted with a SIGCHLD trap, calibrated against three known shapes before it is trusted.

```console
===== AS SHIPPED (base 4c5336c) =====
counter calibration on this host (bash 5.2.21(1)-release):
  calibration $(< file)                    children=0 (expected 0) OK
  calibration $(cat file)                  children=1 (expected 1) OK
  calibration external /bin/true           children=1 (expected 1) OK

  fm_proc_field 4242 ppid  value=[1]                      children: direct=3  through $( )=1
  fm_proc_field 4242 pgid  value=[4242]                   children: direct=3  through $( )=1
  fm_proc_field 4242 sid   value=[4242]                   children: direct=3  through $( )=1
  fm_proc_field 4242 comm  value=[/c/nvm4w/nodejs/node]   children: direct=3  through $( )=1
  fm_proc_field 4242 args  value=[/c/nvm4w/nodejs/node claude.js] children: direct=3  through $( )=1

===== FIXED (HEAD 038449c) =====
counter calibration on this host (bash 5.2.21(1)-release):
  calibration $(< file)                    children=0 (expected 0) OK
  calibration $(cat file)                  children=1 (expected 1) OK
  calibration external /bin/true           children=1 (expected 1) OK

  fm_proc_field 4242 ppid  value=[1]                      children: direct=0  through $( )=1
  fm_proc_field 4242 pgid  value=[4242]                   children: direct=0  through $( )=1
  fm_proc_field 4242 sid   value=[4242]                   children: direct=0  through $( )=1
  fm_proc_field 4242 comm  value=[/c/nvm4w/nodejs/node]   children: direct=0  through $( )=1
  fm_proc_field 4242 args  value=[/c/nvm4w/nodejs/node claude.js] children: direct=1  through $( )=1
```

Three children per scalar read become zero: two were the `$(fm_proc_root)` command
substitutions, one was the fork plus exec of `cat`. That is the audit's "three MSYS forks
plus one exec per call". `args` keeps one child because it still pipes through `tr`,
which the change did not touch. The "through \$( )" column is the caller's own
substitution, which hides its inner children from this counter and is a constant on both sides.

## Defect 1: ancestry walks one process runs while checking session ownership

Driven through fm_session_lock_owned_by_self, the entry point bin/fm-claude-stop-autoarm.sh,
bin/fm-turnend-guard-cursor.sh and bin/fm-startup-network.sh all call. Three checks in one
process is the multi-check shape the memo exists for.

```console
===== AS SHIPPED (base 4c5336c) =====
platform seam: MINGW64_NT-10.0-26200
three ownership checks in ONE process -> ancestry walks run: 3
verdicts: not-owned not-owned not-owned 

===== FIXED (HEAD 038449c) =====
platform seam: MINGW64_NT-10.0-26200
three ownership checks in ONE process -> ancestry walks run: 1
verdicts: not-owned not-owned not-owned 
```

Three walks become one, and every verdict is unchanged. On the Windows host that walk
was measured at 392.73 ms fixed / 746.70 ms as shipped, so each saved call is about 0.4 s.

## The case the accepted deviation turns on: Windows where the walk DOES resolve

Reordering to try the token first would have changed this verdict. Memoising cannot,
because a process's own ancestry is fixed for its lifetime. A non-owning token is in the
environment for this run, so a reorder would have been visible as "not-owned".

```console
===== AS SHIPPED (base 4c5336c) =====
ancestry resolves and includes the lock pid -> owned owned owned 
===== FIXED (HEAD 038449c) =====
ancestry resolves and includes the lock pid -> owned owned owned 
```
