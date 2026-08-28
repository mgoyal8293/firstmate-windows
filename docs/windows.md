# Firstmate on Windows

This repository is a Windows port of firstmate.
It is one repo, not a rewrite: every platform difference is an added
`case "$(uname -s)" in MINGW*|MSYS*)` arm, or a capability probe, inside the function that already owned the behaviour, and a whole self-contained mechanism is a new `bin/fm-*-lib.sh` that owner sources.
That is deliberate - git merges added arms and new files cleanly, while rewritten files conflict on every upstream touch until the port is unmaintainable.
[`CONTRIBUTING.md`](../CONTRIBUTING.md) "Windows-port changes" owns that rule; keep new work in that shape.

The target runtime is Git for Windows (MSYS2/MINGW64 bash), not WSL.
WSL runs upstream firstmate unchanged and needs none of this.

## What is fixed here

Six failures stopped firstmate before any of its own logic was reached.
Each is fixed at exactly one owner:

| Failure | Owner | Substitute |
|---|---|---|
| `ln -s` silently makes a recursive COPY, so every fleet lock spins forever | `bin/fm-proc-lib.sh` | exports `MSYS=winsymlinks:nativestrict` on source; `bin/fm-bootstrap.sh` then PROVES a symlink can be made, through the detectors in `bin/fm-symlink-preflight-lib.sh` |
| MSYS `ps` rejects `-o`, so every process-table read fails on call one | `bin/fm-proc-lib.sh` | `fm_proc_field` reads the `/proc/<pid>/{ppid,pgid,sid,exename,cmdline}` files, with `ps -o` as the non-`/proc` fallback. Fixes harness detection, teardown, the watcher and the process-event runner; does **not** by itself fix the session lock - see "How the session lock is owned" below |
| `lsof` is absent, so teardown reaps nothing - and Windows then physically refuses to delete the worktree the unreaped agent sits in | `bin/fm-teardown.sh`, `bin/fm-lock-proc-lib.sh` | a bounded `/proc/*/cwd` (and `/proc/*/fd`) scan, which also sees the native Windows children MSYS spawned |
| `chmod` is a no-op on `noacl` mounts, so no PR can be merged and no watcher check can be armed | `bin/fm-file-mode-lib.sh` | the exact-mode assertion is capability-gated; see the security note below |
| A stored process identity was read through `ps -o lstart= -o command=` in a second place, so a secondmate's missed-report guard could never read its own sender | `bin/fm-proc-lib.sh` | `fm_pid_identity` moved here from `bin/fm-wake-lib.sh` and `bin/fm-pending-reply-lib.sh`'s private copy is gone. The pending-reply record now tags the stored identity's format and verifies an untagged one against the reader that wrote it, so records already on disk are not read as dead senders |
| The `/proc` cwd and fd-target compare matched raw spellings, so a short (8.3) `%TEMP%` component - the spelling GitHub's Windows runners use - made the scan report NOBODY under a directory a live process was sitting in | `bin/fm-proc-lib.sh` | `fm_proc_cwd_prefixes` resolves the caller's directory through a `cygpath -m -l` probe and scans both spellings, so one location reachable under a mount alias or a short name is recognised as one. A match is what makes `bin/fm-teardown.sh` REFUSE to delete a worktree a live process occupies, and what makes `bin/fm-lock-lib.sh` read a held lock as live rather than stale; before it, teardown could delete that worktree out from under the process. Without `cygpath` the caller's spelling stays the only verdict |

`python3` on a stock Windows box is a Microsoft Store app execution alias: it resolves on PATH and then exits 49 without running, so `command -v python3` was a presence check standing in for a capability check.
[`../bin/fm-python-lib.sh`](../bin/fm-python-lib.sh) is the one owner of the answer - it runs each of `python3`, `python`, and `py -3` and takes the first that reports major version 3 or newer - and every caller in this repo goes through it, including the `bin/fm-doc-audience-check.sh` gate the contributor guidelines mandate, which could not run here at all before.
One caller is deliberately left alone: `bin/fm-remote-entrypoint.sh` must resolve its own real path before it can source anything, and it already falls back through `realpath`.
That is the only exclusion: even `bin/backends/herdr-workspace-move.py`, which keeps its own `#!/usr/bin/env python3` shebang so a human can still run it directly, is invoked by firstmate through the resolved interpreter, so the workspace.move capability gate and the transport it certifies can never disagree about which Python answers.
[`verification/windows-python-probe.md`](verification/windows-python-probe.md) records the evidence.

There is no tmux on Windows either, so multi-agent work runs on the ConPTY
session provider (`bin/backends/conpty.sh`, [`conpty-backend.md`](conpty-backend.md)).
It is an experimental spawn backend and is never chosen by runtime
auto-detection - select it explicitly with `config/backend`.

Two further Windows-specific failures live in that backend rather than in the
shared scripts, and are fixed at one owner each:

| Failure | Owner | Substitute |
|---|---|---|
| A ConPTY console has no foreground process group, so a harness merely ATTACHED to the console reads as one that is RUNNING the session - which makes "the agent stopped" unprovable, so `fm-control exit` and `relaunch` had nothing to stand on | `bin/backends/conpty/fm-shell-integration.bash` | the session shell answers the foreground question itself, with OSC 133 prompt marks the daemon reads off the pty stream it already parses. The two carriers are exported, so a shell nested by hand continues the chain instead of going silent; the agent itself runs in the marked session shell, because `bin/fm-spawn.sh` leases the worktree and `cd`s into it on this backend rather than letting `treehouse get` host the task in a provider subshell |
| `treehouse get` opens `$SHELL` and falls back to `%COMSPEC%`, so a session whose `SHELL` is absent gets cmd.exe, which announces no OSC 0 title and can emit no prompt mark. The spawn path is out of its reach - acquisition runs `treehouse get --lease` in a command substitution and opens no shell - so what remains exposed is every other tool in the session that consults `$SHELL` | `bin/backends/conpty/fm-shell-integration.bash` | `SHELL` is repaired when no Windows executable image stands behind it - the value, or the value plus `.exe`, must begin with the PE magic `MZ`, which is what a native launcher needs to start it. Probed, not keyed on a platform name, and a `SHELL` that a native launcher can start is the operator's and is left alone |

`bin/fm-proc-lib.sh` owns the process-table reads and platform capability, including the `fm_pid_identity` that callers store next to a pid and compare later.
The fifth row was produced by a second copy of that read: it kept working on Linux, so nothing surfaced until MSYS answered it with nothing.
One narrower variant remains outside that owner, `task_process_identity` in `bin/fm-teardown.sh`, which is the same `/proc` stat field-22 parse with a `ps -o lstart=` fallback but prints its own shape and omits the cmdline, and it is outside the scope of this change.
Prefer capability detection over a platform name wherever the question is really "does this work here?" - `/proc` presence, chmod round-trip, symlink creation.
Reserve the `uname -s` arms for behaviour that is genuinely platform-specific.

## The session-start runtime bound is raised here, because a truncated startup is not supervising

`bin/fm-session-start.sh` runs its whole digest as one bounded child.
When that bound is hit the digest truncates, and the stages it loses are the wake-queue drain, the supervision operating instructions and the whole context digest - so a truncated startup is a session that looks started and is not steering, which is a supervision failure rather than a slow banner.

A subprocess costs about 1 ms on Linux and about 42 ms under MSYS, so the identical digest that finishes in seconds here takes over a minute there, and one portable bound cannot be right for both.
On a Windows 11 box under Git Bash, on a home with no tasks, no projects and an absent backlog - the floor, with nothing to reconcile and nothing to sync - the digest took 72 s and 76 s, already 60% of the old 120 s bound before any real work exists in the home.
One run of that same empty home with a test lane competing for CPU took 123 s and truncated; because it truncated, 123 s is a lower bound on what that run needed rather than what it would have taken.

So the default bound is now per platform: 120 s as before, and 300 s under MSYS, MINGW and Cygwin.
[`../bin/fm-session-start-bound-lib.sh`](../bin/fm-session-start-bound-lib.sh) is the one owner of that resolution and records the reasoning behind the number.

**Where 300 s comes from: it is pinned between two bounds measured on the box, not picked for roundness.**
Bounded ABOVE at 328 s by the harness ceiling derived on that box - the 360 s shortest registered session-start timeout minus the 32 s nesting margin below.
Past 328 s the clamp starts biting an ordinary default run and the margin that keeps the truncation banner alive is what gets spent, so that is a hard limit on how far the bound can go without giving up the property the raise exists to protect.
Bounded BELOW at 123 s by the worst run actually observed - the empty home that truncated - which 300 s clears by 2.4x; and because that run truncated, the true multiple is smaller than 2.4x by an unmeasured amount.

**What 300 s is still not justified by, since an earlier version of this page implied otherwise.**
The observations above are the whole case for raising the bound, and they do not establish that 300 s is ENOUGH: this branch has since measured a load factor of about 5x on the parent side alone - 2.06 s idle, 10.3 s mean at 8 fork-heavy competitors, 24.1 s mean at 16 - and a 5x factor does not fit inside the 3.9x headroom 300 s has over the 76 s idle floor.
There is no clean full-startup-to-completion timing under contention on the current tree, and a populated home does strictly more work than the empty one every number above came from.
So the headroom of 300 s against a contended, populated home is an open question, not a measured result.
What protects that case is the truncation path rather than the bound: the bound bites, the banner prints, and the stage that did not finish is named - and the nesting margin below is what keeps that banner from being lost.
An explicit `FM_SESSION_START_TIMEOUT` still wins on every platform, including a value below the raised default; an unusable one falls back to the platform default rather than to a portable constant, because a zero bound disables the deadline outright.
Unusable means NUMERICALLY zero, not the character `0`: `timeout 00 sleep 2` exits 0 after the full two seconds rather than 124, so a zero-padded bound leaves the digest with no deadline at all and a wedged startup never truncates and never prints a banner - the same silent non-supervision the bound exists to remove.
**That fallback is not silent.** The digest names the rejected value and the platform default that replaced it, because an operator who set `FM_SESSION_START_TIMEOUT=0` and was told nothing reads a later truncation as their bound having been too small rather than as never having applied, and spends their next move raising a value that was never in force.
An absent variable prints nothing, since that is the ordinary case rather than a discard.
The one thing it does not win against is the harness: a value above the shortest registered session-start hook timeout is CLAMPED just under it, and the digest says so by name, because above that line the harness kills the hook outright and prints none of the banner - which is what the truncation banner's own "raise `FM_SESSION_START_TIMEOUT`" advice used to invite.
The ceiling is read from the registrations rather than written down, so raising the hook timeouts raises it too and the operator's larger value is then honoured.
The clamp is SCOPED to the runs a kill deadline actually binds, which is not the same question as "is this a hook": it applies when a deadline is positively established, and also when it cannot be established either way, and is skipped only where in-repo evidence positively proves none binds - a direct terminal invocation, or a transport that declares it armed no deadline.
That distinction is a correction rather than a nicety.
The Pi run tier spawns the same wrapper with no timeout, no AbortSignal and no kill, truncating on bytes rather than on a clock, so under the older "is this a hook" reading a Pi session was clamped by a ceiling derived entirely from the Claude, Codex and Cursor registrations - harnesses that were not running - and told a kill second that does not exist there.
Each transport now declares its own deadline status at its own spawn site, and a transport that declares none is never pointed at another harness's registrations.
So the clamp refuses time the machine will not give, or time this process cannot establish that the machine will give; it is not a global cap.
Uncertainty falls to the clamp on purpose: a wrong "a deadline binds" costs bound the operator can recover, while a wrong "nothing kills me" costs the whole banner, so the two errors are not interchangeable and the unprovable negative never drives the unsafe branch.
The same asymmetry decides what happens when no registration can be READ at all - a bin-only deployment, or a box without `awk`: the bound falls back to the platform default rather than being honoured in full, since a bound above a hook timeout this shell cannot see is killed exactly as silently as one above a timeout it can.
The banner then says so instead of quoting a harness deadline nobody read.
The gap between the bound and the shortest registration is per platform too, and it is what pays for the parent's own time: the harness kills the PARENT, which creates processes both before it forks the bounded child and again while printing the banner after the kill, none of which the bound covers.
The path that has to be covered is the CLAMPED one, since the default 300 s bound never reaches the ceiling and only a clamped bound ever equals it.
That count is not written down here or anywhere else: [`../tests/fm-session-start-hook-nesting.test.sh`](../tests/fm-session-start-hook-nesting.test.sh) derives it at test time with the interposer in [`../tests/fixtures/forkcount.c`](../tests/fixtures/forkcount.c) and fails when it rises, so the live number is whatever that guard reports.
The margin there is 32 s against 1 s elsewhere, derived from the worst directly measured non-thrashing parent side on the box: 31.20 s at 16 fork-heavy competitors on 22 cores, across a 9-sample sweep whose truncation banner was verified present on every sample.
**That conservatism is free.** The derived ceiling is 360 - 32 = 328 s, and the Windows default budget is 300 s - still below it - so default behaviour is completely unchanged, and the clamp only ever bites an operator who has explicitly raised `FM_SESSION_START_TIMEOUT` above 328 s.
[`verification/session-start-fork-profile.md`](verification/session-start-fork-profile.md) records the dataset, the 24-competitor thrashing point excluded from the derivation and why, the earlier figures it supersedes - including a 13.1 s idle reading inflated by uncontrolled box load - and which facts are Windows-measured and which are not yet.
The same page records the bound the digest resolves being handed to the deferred network stage rather than re-resolved there, so the window that stage keeps offering inline delivery for cannot fall behind the digest it reports to.
`bin/fm-startup-network.sh` resolves its inline-delivery window through that same owner, so the worker keeps offering its result for exactly as long as the digest it reports to might still be running.
Raising this bound also raised every registered run-tier hook timeout to sit strictly above it, because a harness that kills the hook first takes the parent with the child and there is no truncation banner at all - which is worse than truncating, and is asserted by [`../tests/fm-session-start-hook-nesting.test.sh`](../tests/fm-session-start-hook-nesting.test.sh) against a ceiling derived from the platform arms rather than a quoted number.

Raising a bound does not make the subprocess count that forced it acceptable, so the truncation banner now attributes its own time.
It already named the stage it died in and every stage it never reached; it also asked the operator to "report the slow stage" while nothing measured a stage.
Each stage now records its entry instant, and the banner prints per-stage elapsed times with the unfinished stage marked, so the question the banner asks is answerable from the banner itself.
Those marks are shell builtins reading `EPOCHREALTIME` and spawn nothing: the path being measured is one whose cost *is* its subprocess count, so an instrument that forked per stage would inflate the number it exists to report.
The script's own setup is now a named stage too, because it was outside every stage before and a truncation inside it could only report `unknown` and list no lost stages; on Windows that window is 9.9 s against 312 ms on Linux, which is the first thing the attribution turned up.
`tests/fm-session-start-bound.test.sh` drives the Windows arm from a POSIX runner through `FM_PLATFORM_UNAME_OVERRIDE`, the same seam `bin/fm-proc-lib.sh` uses, which is the only way that arm is covered by CI at all.

## Subprocess count is the Windows cost, so the session-start path spawns fewer

Raising the bound bought margin; it did not make the work cheaper.
A session start on an empty home - no tasks, no projects, an absent backlog - created 1012 subprocesses on the blocking path, which at the 42 ms a fork costs under MSYS is most of that 72 s floor.
[`verification/session-start-fork-profile.md`](verification/session-start-fork-profile.md) records the method, the ranked profile and the before/after counts; the reductions bring that to 817, 195 fewer and a 19.3% cut against the 1012 above, with 127 more removed from the concurrent network stage that shares the same libraries.
The profile quotes the same reductions as 199 forks and 19.6% because it measures them against the 1016 the bound change itself cost, not against `main`'s 1012; both figures are exact and they are not the same baseline.
A later re-measurement on the same box read 976 and 789 for the same two trees - 19.2%, so the ratio reproduces while the absolute floor did not; the profile keeps both readings and explains why the ratio is the durable one.
The lock pid reads on the CONTENDED path are outside every one of those counts, because an uncontended home never reaches them: measured on its own, a waiter polling a held lock pays two forks per 100 ms iteration less than it did, and the uncontended figure is unchanged.

The profile's own finding is that there was no single hot loop.
The dominant cost was **libraries re-sourced from inside functions on poll paths**, each re-running its prologue: 158 library source events per session start, with `bin/fm-proc-lib.sh` alone sourced 42 times and paying its `uname` every time.
That file now carries a source guard keyed on `FM_PLATFORM_UNAME_OVERRIDE` rather than on a bare "already loaded" flag, because everything at its top level is idempotent but the platform seam must still re-resolve - a guard that skipped a seam change would silently make every Windows arm in `../tests/fm-windows-portability.test.sh` test the host platform instead and still report ok.
The remaining reductions replace exec'd helpers with the parameter expansions that answer the same question - `${p%/*}` and `${p##*/}` for `dirname` and `basename`, `[ -r f ] && x=$(<f)` for `$(cat f)` - which is the form [`../bin/fm-path-lib.sh`](../bin/fm-path-lib.sh) already used and documented for this exact reason.

Two counted facts shape how those are written, because both are easy to get backwards.
A command substitution forks even around a shell builtin, so `$(...)` is never free and wrapping a helper in one gives the fork back.
And `$(<f)` is free only without a redirection attached: `$(<f 2>/dev/null)` costs two forks per call rather than zero, because the redirection defeats bash's special case, and it does not even suppress the error.
Which form a given read then takes - `[ -r f ]` first, or `{ x=$(<f); } 2>/dev/null` where the file can vanish between that test and the read, as a pid exiting mid-walk does - is measured and owned by [`verification/session-start-fork-profile.md`](verification/session-start-fork-profile.md).

This is a Windows-motivated fix to portable code, so the count is measured on Linux and the platform only changes what a fork costs.
A Linux timing run would show nothing.

That was a session-start count, and the same class of fix later reached the path a turn pays: one `fm_proc_field` scalar read on the `/proc` path - the read every ancestry walk, reaper and lock check makes here - went from three child processes to none, and the session-lock ownership check stopped paying its ancestry walk more than once per process.
[`verification/windows-session-lock-cost.md`](verification/windows-session-lock-cost.md) records those counts, the Windows timings taken beside them, and what was deliberately left on the table.

## Security note: the private-file mode assertion

`fm_pr_private_file_valid` normally asserts an artifact's exact mode, so a
world-writable watcher check script cannot be swapped in for firstmate's own.
Every Git-for-Windows mount is `noacl`, so modes are synthesised and that
assertion cannot pass at all - which blocked every PR merge, not just polling.

The assertion is now capability-gated: strict wherever `chmod` round-trips,
waived only where it provably cannot.
**This is a real, narrow reduction in the trust binding**, decided deliberately
in preference to remounting Git for Windows with `acl`.
Where it is waived, five assertions still carry the binding: regular file, not a
symlink, link count 1, pinned device, and the SHA-256 content binding, all under
the home's own `state/` directory.
`bin/fm-file-mode-lib.sh` holds the full reasoning; do not re-spell this policy
at a call site.

## Setup

- Clone with symlinks enabled: `git clone -c core.symlinks=true ...`.
  `.claude/skills` is a tracked symlink, and a flattened checkout leaves the harness with zero project skills and no error.
- Enable Windows Developer Mode (or grant `SeCreateSymbolicLinkPrivilege`).
  Without it `MSYS=winsymlinks:nativestrict` makes `ln -s` fail rather than copy - which is the safe failure, but no lock can be acquired.
- Select the ConPTY session provider: put `conpty` in this home's `config/backend`.
  There is no tmux on Windows, and the default `tmux` backend cannot spawn anything here.
- Install the ConPTY daemon's pinned runtime dependencies: `npm install --omit=dev` in `bin/backends/conpty`.
  They are not vendored, so a fresh clone has none and no task can spawn until they are installed.
  [`conpty-backend.md`](conpty-backend.md) owns the rest of that backend's setup, including why the install needs no compiler.
- Run `bin/fm-bootstrap.sh`. It proves all of the above and prints a `PLATFORM:` line naming the exact remedy when the symlink or Developer Mode step is missing, and a `MISSING: conpty-backend-deps` line when the backend's dependencies are not installed.

Run firstmate from Claude Code.
The session lock is owned by a per-session token on Windows (see below), and Claude Code is the only verified harness that exports one today - under any other, this home can read but never spawn, steer, or merge.

## Validating on Windows

`bin/fm-lint.sh` runs here now: both pinned linter installers gained a Windows arm, and `.github/workflows/windows-ci.yml` proves the lint gate plus a measured, sharded subset of the behavior suite on `windows-latest`.
It is a subset on purpose - Git Bash's per-process cost puts the whole suite far outside any job timeout - and its membership is enumerated in `bin/fm-test-run.sh` rather than derived, so a newly added test cannot redden the lane merely by existing before anyone has measured it here.
[`fm-test-windows-lane.md`](fm-test-windows-lane.md) owns that lane's membership, its measurements, and the worklist of scripts that still fail on Windows.

## Staying current with upstream

`bin/fm-upstream-sync.sh` fetches upstream, attempts the merge on a throwaway
worktree, runs tests on the result, and REPORTS.
It never merges.
A clean textual merge can still move the code a Windows arm was guarding, and
landing that silently would surface only when someone next needed Windows to
work.
`.github/workflows/upstream-sync.yml` runs it daily and fails the scheduled run
when upstream is not cleanly takeable.

## How the session lock is owned

The session lock was the last thing keeping a Windows firstmate read-only, and
it needed a different answer from every other process-table read.

**MSYS's `/proc` contains only MSYS processes.** Claude Code on Windows is a
native `claude.exe`, so it never appears there, and the Bash tool subprocess it
spawns reports `ppid = 1`. The ancestry walk terminates on hop one with no
harness found. Measured inside a real session (Claude Code 2.1.220,
MINGW64_NT-10.0-26200): `fm_harness_ancestry_pids` returns nothing and exits 1,
every time.

The chain is recoverable, just not from `/proc`: the Bash tool subprocess reads
`msys_ppid = 1` while its Windows parent chain runs bash -> bash -> bash ->
`claude.exe` -> sh, with `CLAUDECODE=1` present throughout. `ps -W` lists native
processes but reports `PPID 0` for them, so it cannot walk the chain.
`Get-CimInstance Win32_Process` can, and identifies `claude.exe` by both its
name and its install path - but one CIM call costs roughly half a second, and
the Stop hook runs every turn.

The hard part was never reading the chain - it is what the lock then STORES.
Every other caller (`fm_harness_pid_alive`, `fm_session_lock_owned_by_self`,
`kill -0`) treats the recorded value as an MSYS pid, so recording a Windows pid
would put two namespaces behind one field and let a lock-ownership test match the
wrong process.

**So ownership is proved by a per-session token, added alongside the ancestry
path rather than replacing it.**

- The token is a value the harness exports that is stable for one session and
  different in every other, so a process holding it is provably inside that
  session. `bin/fm-session-token-lib.sh` holds the verified source per harness;
  Claude's is `CLAUDE_CODE_SESSION_ID`, measured identical across `SessionStart`,
  the Bash tool's `PreToolUse`, `Stop` and `SessionEnd`, and equal to the
  `session_id` each hook payload carries on stdin.
  **Claude's is the only row there is today**, and the phrasing "per harness"
  describes the shape, not the coverage. The list is written to be extended, but
  no other harness has been verified, so under `codex`, `opencode`, `pi`,
  `pi-signed`, `grok`, `kimi` or `cursor` a Windows firstmate never acquires the
  lock and stays read-only for the whole session - it can inspect, and nothing
  more. Adding a row is separate work, not a widening anyone should do blind:
  each needs evidence that the variable is session-scoped and present in that
  harness's own Windows tool subprocesses, because honouring an unverified one
  would let any process carrying it claim the lock.
- `fm_session_ancestry_unavailable` gates the token path on BOTH the platform and
  an empty walk. The platform half is load-bearing: off Windows an empty walk is
  a real answer, and honouring a token there would let any process carrying the
  variable claim a lock the ancestry walk correctly refuses it. The token path is
  therefore unreachable off Windows.
- No Windows pid is recorded anywhere. `state/.lock` still holds a plain numeric
  MSYS pid, so every existing reader is unchanged and no caller becomes
  namespace-aware; the token lives beside it in `state/.lock.session`.
- Reading a token is an environment lookup plus one small file read, and nothing
  on the token path itself queries the process table.
  The gate in front of it does, exactly once per process: `fm_session_ancestry_unavailable`
  has to prove the walk found nothing before a token may be honoured, so the walk
  is evidence the predicate cannot skip.
  It is memoised instead, because a process's own ancestry is fixed for its
  lifetime while trying the token first would answer a different question in the
  case where the walk does resolve.
  A steady-state turn makes one ownership check, so the memo saves nothing on
  that path; it pays where one process asks more than once, such as the
  stale-lock recovery branch in `bin/fm-claude-stop-autoarm.sh` or the repeated
  current-session checks in `bin/fm-turnend-guard-cursor.sh`.
  [`verification/windows-session-lock-cost.md`](verification/windows-session-lock-cost.md)
  is the evidence: the walk counts the memo removes, and the driven case that
  rules out consulting the token first.

A token proves identity, not liveness, so two things supply the rest:

- `bin/fm-claude-stop-autoarm.sh` touches the token on every `Stop`, which is the
  liveness heartbeat. No vendor artifact could serve instead: Claude Code's
  per-session `session-env` directory and its transcript both survive the process
  and accumulate.
- `bin/fm-claude-sessionend-release.sh` clears the token on `SessionEnd`, so an
  ordinary quit releases the home at once. It clears only a token the ending
  session itself owns.
  `FM_SESSION_TOKEN_STALE_AFTER` (4h) then covers only a crash, and the refusal
  names the one file to delete.

### What was measured on Windows

Real headless Claude Code sessions against a Firstmate home, hooks firing for
real, Claude Code 2.1.220 on MINGW64_NT-10.0-26200:

| Case | Result |
|---|---|
| Fresh session, fresh home | `lock acquired: session token`; `state/.lock` = `153` (a plain MSYS pid), `state/.lock.session` = the session UUID |
| Second tool call, same session | acquires again idempotently, `state/.lock` unchanged |
| `SessionStart` -> two `PreToolUse` -> `Stop` -> `SessionEnd` | one identical session id at every hook; ppid is `1` at every hook |
| `Stop` hook | token mtime advanced `1787048541` -> `1787048604`, so the claim stays fresh per turn |
| `SessionEnd` | token removed, `state/.lock` left at `153` for the unchanged dead-owner reclaim |
| Restart into the same home, seconds later | `lock acquired: session token` immediately - no freshness window to wait out |
| Two overlapping LIVE sessions | the second is refused: `another firstmate session holds the lock for this home`, and the holder's token is not overwritten |
| Home under the Windows temp directory | `lock acquired: session token` - see below |

Before `bin/fm-claude-sessionend-release.sh` existed, that restart case was
measured as REFUSED a minute after the first session had exited, which would
have left a Windows home read-only for four hours after every ordinary quit.

#### The process-identity read

Git for Windows bash 5.2.37(1)-release on MINGW64_NT-10.0-26200:

| Case | Result |
|---|---|
| The previous reader's form, `COLUMNS=10000 LC_ALL=C ps -p <pid> -o lstart= -o command=` | rejected, exit 1 |
| `/proc/<pid>/stat` and `/proc/<pid>/cmdline` | both readable |
| Before this change | the sender identity is unreadable, the one recovery attempt is refused with nothing sent, and the record stays at `awaiting_report` |
| With this change | the identity reads in the form `fm-pid-identity.v1 proc-starttime=<ticks> cmdline-hex=<hex>`, the recovery is delivered, the record reaches `recovery_sent`, a live sender reads as alive, and a pid the process table cannot see reads as dead |
| An untagged record within the `FM_PENDING_REPLY_UNVERIFIABLE_SENDER_SECS` bound (900s default) | defers, stays at `recovery_sending`, and the stored identity is byte-identical afterwards because a liveness read never rewrites it |
| An untagged record past that bound | reads as dead, reaches `escalated`, and opens exactly one escalation |
| The sender-identity, previous-format migration and bounded-defer cases of `tests/fm-pending-reply.test.sh` on that host | pass |
| The `fm_pid_identity` case in `tests/fm-windows-portability.test.sh` on that host | passes |

### A second wedge in the same layer: symlink target spelling

Native symlinks made `ln -s` a real link, but MSYS resolves the stored Windows
target back through its mount table, and the spelling it returns need not be the
one passed to `ln -s`. A directory created as
`/c/Users/<user>/AppData/Local/Temp/x/target` reads back as `/tmp/x/target`,
because the mount table aliases the two:

```
$ pwd -P    -> /c/Users/johns/AppData/Local/Temp/fmspell.1290/target
$ readlink  -> /tmp/fmspell.1290/target
```

`fm_lock_points_to_owner` compared those as raw strings, so
`fm_lock_try_create` never validated its own link and `fm_lock_acquire_wait`
spun forever - the wedge the winsymlinks fix removed, reintroduced one layer up.
Any home under a mount-aliased path hits it.

`fm_lock_same_path` (`bin/fm-path-lib.sh`) is the fallback, and it uses
`cygpath`, which owns the mount table. `cd ... && pwd -P` is NOT a resolver
here: it canonicalises symlinked components but leaves the mount alias exactly
as given, so it returns both spellings unchanged (measured). The strict string
compare stays first and stays authoritative; where no `cygpath` exists the
strict compare remains the only verdict, so this can widen a match and never
silently accept an unresolvable one.

It resolves the mount alias and the 8.3 short name, because those are two aliasing layers and `cygpath -m` alone sees through only the first.
`fm_lock_same_path` resolves with `cygpath -m -l`, the same way `fm_proc_cwd_prefixes` (`bin/fm-proc-lib.sh`) does for the `/proc` cwd read described in [`fm-test-windows-lane.md`](fm-test-windows-lane.md).
Measured on Git-for-Windows MINGW64 against one directory reached by both spellings (identical inode):

```
$ cygpath -m    .../Temp/FMPROB~1/xdir  -> C:/Users/johns/AppData/Local/Temp/FMPROB~1/xdir
$ cygpath -m    .../Temp/fmprobe-verylongname-1234/xdir  -> C:/Users/johns/AppData/Local/Temp/fmprobe-verylongname-1234/xdir
$ cygpath -m -l (either spelling)       -> C:/Users/johns/AppData/Local/Temp/fmprobe-verylongname-1234/xdir
```

`%TEMP%` is where this bites, because Git for Windows mounts `/tmp` at whatever it names and GitHub's Windows runners spell it with a short component.
`-l` expands a component only when the path resolves on disk and otherwise returns it unchanged, so an unresolvable pair is still compared as spelled - the refusing direction.

`fm_platform_symlink_probe` (`bin/fm-proc-lib.sh`) is a remaining known instance of the same raw-string spelling compare, is not fixed here, and is tracked as its own separate follow-up, `winfm-symlink-probe-spelling`.

## Run end to end on Windows

Everything above this section was proven one component at a time.
This section records the first run of firstmate as a whole system on Windows: one session taking the lock, spawning a crewmate, supervising it until it woke firstmate, landing its commit, releasing the task, and restarting into the same home.

The run used a scratch home rather than the captain's own, so a bad step could not damage real fleet state.
A fresh clone of this repo served as both code root and home, with `config/backend` set to `conpty` and a purpose-made git project under its `projects/`.
The project was purpose-made deliberately: the crewmate's change had to be a genuine commit in a genuine repository with no path to a real remote.

Claude Code 2.1.220 on MINGW64_NT-10.0-26200, Git for Windows 2.50.1, node v22.18.0, treehouse 2.1.1.

| Step | Result |
|---|---|
| Session start takes the lock | `bin/fm-session-start.sh` ran from the `SessionStart` hook and printed `lock acquired: session token`. `state/.lock` held a plain MSYS pid and `state/.lock.session` held the session UUID. Bootstrap's mutating sweeps ran (`.pr-check-migration-scan-v1`, `.inactive-outcome-reconcile`, a created `.wake-queue`), and the deferred network stage recorded `locked=1`, so the session was genuinely not read-only |
| Spawn a crewmate on ConPTY | `state/<id>.meta` recorded `backend=conpty` and its `conpty_session`. The crewmate's shell entered the pooled worktree `~/.treehouse/<pool>/1/<project>`, distinct from the project checkout, and the spawn's isolation assertion passed. `GOTMPDIR` was exported into the pane as intended |
| Agent liveness and busy state | `fm_backend_conpty_agent_state` returned `alive` with `why: harness process claude.exe` and `identityValidated: true`, reading the real native process list (`claude.exe`, `sh.exe`, `bash.exe`, `treehouse.exe`) - that attached `treehouse.exe` is the pre-lease topology of the day, which the spawn path no longer produces, and [`conpty-backend.md`](conpty-backend.md) owns what attaches now. `bin/fm-crew-state.sh` reported `state: working · source: pane · harness busy (claude-hook)` while it worked, and `state: done · source: status-log` afterwards |
| Supervise for real | The Stop-hook auto-arm armed the watcher, creating `state/.watch.lock` as a real native symlink to its `.owner.<suffix>` directory. The worker's activity produced four durable `signal:` wake records naming its status and turn-ended files. The session was rewoken, drained them, and acknowledged them with the generation-bound `--ack-through 4 --recovery-generation <gen>`, taking the queue to zero. One steer was delivered through `bin/fm-send.sh` |
| The change lands on the branch | Commit `e255fd7` on `fm/winfm-e2e-typo`, a one-line comment fix, `git diff main..HEAD` exactly one changed line, clean tree, `bash -n` still parsing |
| Teardown refuses unlanded work | With the commit on the branch but not yet on local `main`, `bin/fm-teardown.sh` refused: `REFUSED: local-only worktree <path> has work not yet merged into main and not on any remote`, listed `e255fd7` as the commit at risk, and named the merge, push, and explicit-discard routes out. The task metadata, status log, and live session were all still present afterwards |
| Approved landing | `bin/fm-merge-local.sh` fast-forwarded the project's `main` to `e255fd7` |
| The polite exit was not available | `bin/fm-control.sh <id> exit` refused: `task <id> runs on the conpty backend, which has no recovery-grade agent-state classifier, so 'exit' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done`. On the day of this run a Windows crewmate could not be stopped through the control plane at all. **Since fixed**, and no longer a limit: see the paragraph below the table |
| Clean teardown | After landing, teardown released everything: the task's `state/<id>.*` records were retired, the ConPTY session reported `absent`, and the pooled worktree returned to the pool at a detached HEAD with `fm/winfm-e2e-typo` no longer checked out. Its reaper did the stopping, reporting `reaping leaked worktree process(es)` and then `force-killing leaked worktree process(es)`, and needing a second pass for one survivor |
| Restart into the same home | Sixteen seconds after the previous session exited, with its stale MSYS pid still sitting in `state/.lock` and `state/.lock.session` already cleared by `SessionEnd`, a fresh session reclaimed the home: `bin/fm-lock.sh status` reported `lock: held by this session's token`, and `state/.lock.session` equalled that session's own `CLAUDE_CODE_SESSION_ID`. No four-hour freshness window was waited out |

All six steps completed on the real machine.
A Windows firstmate can therefore take its own home, put a real crewmate on real work, supervise it through a real wake, land the commit, and release the task, which is the whole loop rather than a set of passing parts.
Three gaps came out of it, and the first has since been closed.
On the day of this run there was no way to stop a crewmate politely: the control plane refused every verb on this backend and teardown's reaper was what actually ended the agent.
**That is no longer true, and `winfm-conpty-graceful-stop` is closed rather than queued.**
`exit`, `interrupt` and `relaunch` all work on a genuinely spawned conpty task, demonstrated end to end on real Windows: `fm-control exit` returned in 9 s, the shared classifier read `dead`, the endpoint was still `present`, and the leased worktree was still on disk - so a graceful stop is now the routine way to stop a Windows crewmate, and a force-kill is not the only route.
[`runtime-backends.md`](verification/runtime-backends.md) "The shipped spawn path, end to end on real Windows" records the readings, and [`conpty-backend.md`](conpty-backend.md) explains how the stop is proven.
Teardown does still leave a completed task's ConPTY session directory behind, which [`conpty-backend.md`](conpty-backend.md) "Active limits" owns.
That one does not block the loop.
The third is an outright defect: a merged task branch was left behind in the project (`winfm-merged-branch-prune`).
The run needed no code change of its own: what it produced is this record and those three documented gaps.

### What the run turned up

Most of these are correct behaviour rather than defects, and none were fixed in this run.
A Windows operator meets them in this order.

- **The ConPTY daemon needs one dependency install per checkout.**
  `npm install --omit=dev` in `bin/backends/conpty` took 36 seconds and used prebuilt binaries, so no MSVC toolchain was involved.
  `node bin/backends/conpty/fmpty.js doctor` names each unloadable module with the exact remedy and exits 1 until they load.
- **Crewmate harness detection needs no Windows configuration.**
  `bin/fm-harness.sh` resolves `claude` inside a real session from the `CLAUDECODE=1` marker, which is checked before the ancestry walk that Windows cannot complete.
  Run outside a session it correctly answers `unknown`, and the spawn then refuses by name rather than guessing.
  So `config/crew-harness` is not a Windows prerequisite.
- **`bin/fm-send.sh` refuses the first steer until the home is named.**
  That is its documented fail-closed contract rather than a fault, but it is the first thing a steer hits, and the second call with the home named delivered.
- **Claude Code's folder-trust dialog appears on first launch in a fresh pooled worktree**, and firstmate answered it before the worker read its brief.
  This is not Windows-specific; it is the ordinary first-launch gate for an unseen directory.
- **A project with no `origin` cannot be spawned against.**
  `freshen_spawn_worktree_base` in `bin/fm-spawn.sh` fetches `origin` unconditionally and refuses to launch from a possibly stale base.
  That is correct behaviour, and it is not Windows-specific, but a scratch Windows home hits it immediately because the obvious scratch project has no remote.
- **A merged task branch is left behind in the project, and that is a defect.**
  After the local merge and teardown, `fm/winfm-e2e-typo` still existed in the demo project.
  `bin/fm-teardown.sh` has a prune for exactly this: on a non-secondmate task it resolves the worktree's current branch, detaches the worktree, then runs `git branch -D`.
  That path applied to this task and its precondition was met, because the pooled worktree was still on `fm/winfm-e2e-typo` when teardown began, and the worktree reaper runs before the prune rather than after it, so an agent still holding the worktree does not excuse the outcome.
  The prune targeted the ref that survived: `bin/fm-merge-local.sh` resolved `fm/winfm-e2e-typo` in the project's own ref store and fast-forwarded `main` to `e255fd7`, so the pooled worktree and the project share refs, and the only other pooled worktree sat at a detached `b6dcc30`, which rules out a checked-out-elsewhere refusal.
  A control test on the same Windows host, in the same project and pool root, ran teardown's two commands unsilenced with nothing holding the worktree and both succeeded, ending in `Deleted branch fm/prunetest (was e255fd7)`.
  So the prune ran against a ref it should have removed and the ref survived, which is a real defect, observed on Windows, whose platform-specificity is not established.
  The failure was observed only in this run's context, a worktree whose processes had just been force-killed and needed a second reap pass, and nothing here rules out the same failure in the same context off Windows.
  Which of the two commands failed remains unobserved, because the detach discards its stderr and the delete discards both its output and its exit status.
  The cause is not established, and this record deliberately does not argue one.
  What is established is that the prune path applied, its precondition was met, the ref survived, and the same two commands succeeded unsilenced in the control test on the same host, so the defect itself stands.
  The leftover ref is harmless in itself because it is fully merged.
  Tracked as `winfm-merged-branch-prune` (queued, firstmate-windows), which owns both establishing the cause and the fix.
- **`fm-remote-job-reap-orphans` cannot scan this account's processes** and says so during teardown.
  No remote work was involved, and the remote-job scripts are already out of scope below, so the line is benign here rather than a missed reap.
- **Teardown left the ConPTY session directory behind.**
  After this task the session itself was dead and its own `state/<id>.*` records had been retired, but `state/conpty/<session>/` was still there.
  That is not Windows-specific, and [`conpty-backend.md`](conpty-backend.md) "Active limits" owns why.
- **A scripted headless session does not end while a task is live.**
  `claude -p` buffers its transcript until exit, and the Stop-hook arm keeps the session open while `state/*.meta` still names in-flight work, so a one-shot headless firstmate keeps re-arming instead of returning.
  Interactive sessions are the normal shape and are unaffected; this only shapes how a Windows run can be scripted.

### What this run does not prove

- **Only the `claude` harness was exercised.**
  The crewmate and the firstmate session were both Claude Code.
  No other harness adapter was launched on Windows.
- **Only `local-only` delivery was exercised.**
  The change landed through `bin/fm-merge-local.sh` as a local fast-forward.
  Neither the no-mistakes pipeline nor a real PR merge ran on Windows in this run, so `bin/fm-pr-merge.sh` and the watcher's merge poll remain proven only at component level.
- **One task, one worker.**
  No concurrent crewmates, no secondmate, and no away-mode daemon took part.
- Everything already listed under "Not yet ported" below stayed out of scope and is unchanged by this run.

## Not yet ported

- A session token is verified for `claude` only, so under `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi` or `cursor` a Windows firstmate stays read-only for the whole session.
  "How the session lock is owned" above owns why each row needs its own evidence before it may be added.
- Relay's artifact writes (`x_mode_write_if_changed` in `bin/fm-bootstrap.sh`) still assert exact modes directly. Relay is off unless the home opts in.
- Away mode's daemon launch (`bin/fm-afk-launch.sh`) is unexamined on Windows.
- The macOS-only surfaces (`bin/backends/herdr.sh`, `bin/fm-remote-job-*.sh`, muse) are deliberately out of scope.
- The voice and inbox stack that arrived with the 2026-08 upstream intake (`bin/fm-inbox.sh`, `bin/fm-voice-*.py`, `bin/fm_voice_records.py`) is unported.
  `bin/fm-inbox.sh` calls bare `python3` in six places, which is the Microsoft Store execution-alias trap [`../bin/fm-python-lib.sh`](../bin/fm-python-lib.sh) exists to answer, and the stack additionally needs PortAudio and an AWS Bedrock region.
  It is optional and inert until invoked, so the intake took it rather than carrying a divergence; `winfm-inbox-python-capability` is the filed follow-up that routes it through the capability owner.
