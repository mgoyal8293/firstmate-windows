# Firstmate on Windows

This repository is a Windows port of firstmate.
It is one repo, not a rewrite: every platform difference is an added
`case "$(uname -s)" in MINGW*|MSYS*)` arm, or a capability probe, inside the function that already owned the behaviour.
That is deliberate - git merges added arms cleanly, and rewritten files conflict on every upstream touch until the port is unmaintainable.
Keep new work in that shape.

The target runtime is Git for Windows (MSYS2/MINGW64 bash), not WSL.
WSL runs upstream firstmate unchanged and needs none of this.

## What is fixed here

Five failures stopped firstmate before any of its own logic was reached.
Each is fixed at exactly one owner:

| Failure | Owner | Substitute |
|---|---|---|
| `ln -s` silently makes a recursive COPY, so every fleet lock spins forever | `bin/fm-proc-lib.sh` | exports `MSYS=winsymlinks:nativestrict` on source; `bin/fm-bootstrap.sh` then PROVES a symlink can be made |
| MSYS `ps` rejects `-o`, so every process-table read fails on call one | `bin/fm-proc-lib.sh` | `fm_proc_field` reads the `/proc/<pid>/{ppid,pgid,sid,exename,cmdline}` files, with `ps -o` as the non-`/proc` fallback. Fixes harness detection, teardown, the watcher and the process-event runner; does **not** by itself fix the session lock - see "How the session lock is owned" below |
| `lsof` is absent, so teardown reaps nothing - and Windows then physically refuses to delete the worktree the unreaped agent sits in | `bin/fm-teardown.sh`, `bin/fm-lock-lib.sh` | a bounded `/proc/*/cwd` (and `/proc/*/fd`) scan, which also sees the native Windows children MSYS spawned |
| `chmod` is a no-op on `noacl` mounts, so no PR can be merged and no watcher check can be armed | `bin/fm-pr-lib.sh` | the exact-mode assertion is capability-gated; see the security note below |
| A stored process identity was read through `ps -o lstart= -o command=` in a second place, so a secondmate's missed-report guard could never read its own sender | `bin/fm-proc-lib.sh` | `fm_pid_identity` moved here from `bin/fm-wake-lib.sh` and `bin/fm-pending-reply-lib.sh`'s private copy is gone. The pending-reply record now tags the stored identity's format and verifies an untagged one against the reader that wrote it, so records already on disk are not read as dead senders |

There is no tmux on Windows either, so multi-agent work runs on the ConPTY
session provider (`bin/backends/conpty.sh`, [`conpty-backend.md`](conpty-backend.md)).
It is an experimental spawn backend and is never chosen by runtime
auto-detection - select it explicitly with `config/backend`.

`bin/fm-proc-lib.sh` owns the process-table reads and platform capability, including the `fm_pid_identity` that callers store next to a pid and compare later.
The fifth row was produced by a second copy of that read: it kept working on Linux, so nothing surfaced until MSYS answered it with nothing.
One narrower variant remains outside that owner, `task_process_identity` in `bin/fm-teardown.sh`, which is the same `/proc` stat field-22 parse with a `ps -o lstart=` fallback but prints its own shape and omits the cmdline, and it is outside the scope of this change.
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

#### The process-identity read

Git for Windows bash 5.2.37(1)-release on MINGW64_NT-10.0-26200, and Linux 6.18 for the unchanged-behaviour half:

| Case | Result |
|---|---|
| `COLUMNS=10000 LC_ALL=C ps -p $$ -o lstart= -o command=` on MSYS | rejected, exit 1, `ps: unknown option -- o` |
| `/proc/<pid>/stat` and `/proc/<pid>/cmdline` on the same host | both readable |
| Before this change, sender identity | unreadable, the function returns 1 |
| Before this change, one recovery attempt | refused, nothing sent, the record stays at `awaiting_report`, and a live sender reads as dead |
| After this change, sender identity | `fm-pid-identity.v1 proc-starttime=237978196 cmdline-hex=62617368002e2f7665726966792e7368002d2d64656d6f2d6f6e6c7900` |
| After this change, one recovery attempt | delivered, the record reaches `recovery_sent`, a live sender reads as alive, and a gone pid reads as dead |
| An untagged record on that host | defers on a live pid, the record stays at `recovery_sending` across a poll, and concludes dead on a gone pid |
| Suites on that host | `tests/fm-windows-portability.test.sh` exit 0, `tests/fm-pending-reply.test.sh` exit 0, with the previous-format verification case reporting its guarded skip because that platform's ps cannot produce the old form |
| Off Windows, the identity is byte-identical across the move | `linux-starttime=9894240 cmdline-hex=736c6565700033303000` from both `bin/fm-wake-lib.sh` and `bin/fm-proc-lib.sh`, and `tests/fm-pending-reply.test.sh` passes at origin/main and on this branch |

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

## Not yet ported

- Relay's artifact writes (`x_mode_write_if_changed` in `bin/fm-bootstrap.sh`) still assert exact modes directly. Relay is off unless the home opts in.
- Away mode's daemon launch (`bin/fm-afk-launch.sh`) is unexamined on Windows.
- The macOS-only surfaces (`bin/backends/herdr.sh`, `bin/fm-remote-job-*.sh`, muse) are deliberately out of scope.
