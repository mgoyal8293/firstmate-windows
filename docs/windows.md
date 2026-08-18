# Firstmate on Windows

This repository is a Windows port of firstmate.
It is one repo, not a rewrite: every platform difference is an added
`case "$(uname -s)" in MINGW*|MSYS*)` arm, or a capability probe, inside the function that already owned the behaviour.
That is deliberate - git merges added arms cleanly, and rewritten files conflict on every upstream touch until the port is unmaintainable.
Keep new work in that shape.

The target runtime is Git for Windows (MSYS2/MINGW64 bash), not WSL.
WSL runs upstream firstmate unchanged and needs none of this.

## What is fixed here

Four failures stopped firstmate before any of its own logic was reached.
Each is fixed at exactly one owner:

| Failure | Owner | Substitute |
|---|---|---|
| `ln -s` silently makes a recursive COPY, so every fleet lock spins forever | `bin/fm-proc-lib.sh` | exports `MSYS=winsymlinks:nativestrict` on source; `bin/fm-bootstrap.sh` then PROVES a symlink can be made |
| MSYS `ps` rejects `-o`, so every process-table read fails on call one | `bin/fm-proc-lib.sh` | `fm_proc_field` reads the `/proc/<pid>/{ppid,pgid,sid,exename,cmdline}` files, with `ps -o` as the non-`/proc` fallback. Fixes harness detection, teardown, the watcher and the process-event runner; does **not** by itself fix the session lock - see "How the session lock is owned" below |
| `lsof` is absent, so teardown reaps nothing - and Windows then physically refuses to delete the worktree the unreaped agent sits in | `bin/fm-teardown.sh`, `bin/fm-lock-lib.sh` | a bounded `/proc/*/cwd` (and `/proc/*/fd`) scan, which also sees the native Windows children MSYS spawned |
| `chmod` is a no-op on `noacl` mounts, so no PR can be merged and no watcher check can be armed | `bin/fm-pr-lib.sh` | the exact-mode assertion is capability-gated; see the security note below |

There is no tmux on Windows either, so multi-agent work runs on the ConPTY
session provider (`bin/backends/conpty.sh`, [`conpty-backend.md`](conpty-backend.md)).
It is an experimental spawn backend and is never chosen by runtime
auto-detection - select it explicitly with `config/backend`.

`bin/fm-proc-lib.sh` is the one owner of both process-table reads and platform capability.
Prefer capability detection over a platform name wherever the question is really "does this work here?" - `/proc` presence, chmod round-trip, symlink creation.
Reserve the `uname -s` arms for behaviour that is genuinely platform-specific.

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
`bin/fm-pr-lib.sh` holds the full reasoning; do not re-spell this policy at a
call site.

## Setup

- Clone with symlinks enabled: `git clone -c core.symlinks=true ...`.
  `.claude/skills` is a tracked symlink, and a flattened checkout leaves the harness with zero project skills and no error.
- Enable Windows Developer Mode (or grant `SeCreateSymbolicLinkPrivilege`).
  Without it `MSYS=winsymlinks:nativestrict` makes `ln -s` fail rather than copy - which is the safe failure, but no lock can be acquired.
- Run `bin/fm-bootstrap.sh`. It proves both of the above and prints a `PLATFORM:` line naming the exact remedy when either is missing.

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
  session. `bin/fm-session-lock-lib.sh` holds the verified source per harness;
  Claude's is `CLAUDE_CODE_SESSION_ID`, measured identical across `SessionStart`,
  the Bash tool's `PreToolUse`, `Stop` and `SessionEnd`, and equal to the
  `session_id` each hook payload carries on stdin.
- `fm_session_ancestry_unavailable` gates the token path on BOTH the platform and
  an empty walk. The platform half is load-bearing: off Windows an empty walk is
  a real answer, and honouring a token there would let any process carrying the
  variable claim a lock the ancestry walk correctly refuses it. The token path is
  therefore unreachable off Windows.
- No Windows pid is recorded anywhere. `state/.lock` still holds a plain numeric
  MSYS pid, so every existing reader is unchanged and no caller becomes
  namespace-aware; the token lives beside it in `state/.lock.session`.
- Nothing queries the Windows process table, per turn or otherwise. Reading a
  token is an environment lookup plus one small file read.

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

`fm_lock_same_path` is the fallback, and it uses `cygpath`, which owns the mount
table. `cd ... && pwd -P` is NOT a resolver here: it canonicalises symlinked
components but leaves the mount alias exactly as given, so it returns both
spellings unchanged (measured). The strict string compare stays first and stays
authoritative; where no `cygpath` exists the strict compare remains the only
verdict, so this can widen a match and never silently accept an unresolvable one.

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
| Agent liveness and busy state | `fm_backend_conpty_agent_state` returned `alive` with `why: harness process claude.exe` and `identityValidated: true`, reading the real native process list (`claude.exe`, `sh.exe`, `bash.exe`, `treehouse.exe`). `bin/fm-crew-state.sh` reported `state: working · source: pane · harness busy (claude-hook)` while it worked, and `state: done · source: status-log` afterwards |
| Supervise for real | The Stop-hook auto-arm armed the watcher, creating `state/.watch.lock` as a real native symlink to its `.owner.<suffix>` directory. The worker's activity produced four durable `signal:` wake records naming its status and turn-ended files. The session was rewoken, drained them, and acknowledged them with the generation-bound `--ack-through 4 --recovery-generation <gen>`, taking the queue to zero. One steer was delivered through `bin/fm-send.sh` |
| The change lands on the branch | Commit `e255fd7` on `fm/winfm-e2e-typo`, a one-line comment fix, `git diff main..HEAD` exactly one changed line, clean tree, `bash -n` still parsing |
| Teardown refuses unlanded work | With the commit on the branch but not yet on local `main`, `bin/fm-teardown.sh` refused: `REFUSED: local-only worktree <path> has work not yet merged into main and not on any remote`, listed `e255fd7` as the commit at risk, and named the merge, push, and explicit-discard routes out. The task metadata, status log, and live session were all still present afterwards |
| Approved landing | `bin/fm-merge-local.sh` fast-forwarded the project's `main` to `e255fd7` |
| The polite exit is not available | `bin/fm-control.sh <id> exit` refused: `task <id> runs on the conpty backend, which has no recovery-grade agent-state classifier, so 'exit' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done`. So a Windows crewmate cannot be stopped through the control plane at all, and [`conpty-backend.md`](conpty-backend.md) "Active limits" owns why |
| Clean teardown | After landing, teardown released everything: the task's `state/<id>.*` records were retired, the ConPTY session reported `absent`, and the pooled worktree returned to the pool at a detached HEAD with `fm/winfm-e2e-typo` no longer checked out. Its reaper did the stopping, reporting `reaping leaked worktree process(es)` and then `force-killing leaked worktree process(es)`, and needing a second pass for one survivor |
| Restart into the same home | Sixteen seconds after the previous session exited, with its stale MSYS pid still sitting in `state/.lock` and `state/.lock.session` already cleared by `SessionEnd`, a fresh session reclaimed the home: `bin/fm-lock.sh status` reported `lock: held by this session's token`, and `state/.lock.session` equalled that session's own `CLAUDE_CODE_SESSION_ID`. No four-hour freshness window was waited out |

All six steps completed on the real machine.
A Windows firstmate can therefore take its own home, put a real crewmate on real work, supervise it through a real wake, land the commit, and release the task, which is the whole loop rather than a set of passing parts.
One real gap came out of it: there is no way to stop a crewmate politely, because the control plane refuses on this backend and teardown's reaper is what actually ends the agent.
That is a reduction against tmux, not a blocker for the loop.
The run needed no code change of its own: what it produced is this record and that one newly documented limit.

### What the run turned up

None of these needed a code change, but a Windows operator meets them in this order.

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
  So the prune ran against a ref it should have removed and the ref survived, which is a real Windows defect that this record had not previously carried.
  Which of the two commands failed is not established, because the detach discards its stderr and the delete discards both its output and its exit status; establishing that is separate work.
  The leftover ref is harmless in itself because it is fully merged.
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

- Relay's artifact writes (`x_mode_write_if_changed` in `bin/fm-bootstrap.sh`) still assert exact modes directly. Relay is off unless the home opts in.
- Away mode's daemon launch (`bin/fm-afk-launch.sh`) is unexamined on Windows.
- `fm_pending_reply_pid_identity` (`bin/fm-pending-reply-lib.sh`) still reads sender liveness through `ps -o lstart= -o command=`, which MSYS answers with nothing, so a secondmate's pending reply reads its sender as dead there. The fleet's `/proc` identity (`fm_pid_identity`) is the right substitute but lives in `bin/fm-wake-lib.sh`, which that file sources only inside one function; wiring it needs an owner move rather than a local patch.
- The macOS-only surfaces (`bin/backends/herdr.sh`, `bin/fm-remote-job-*.sh`, muse) are deliberately out of scope.
