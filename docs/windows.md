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
| MSYS `ps` rejects `-o`, so every process-table read fails on call one | `bin/fm-proc-lib.sh` | `fm_proc_field` reads the `/proc/<pid>/{ppid,pgid,sid,exename,cmdline}` files, with `ps -o` as the non-`/proc` fallback. Fixes harness detection, teardown, the watcher and the process-event runner; does **not** by itself fix the session lock - see "Open" below |
| `lsof` is absent, so teardown reaps nothing - and Windows then physically refuses to delete the worktree the unreaped agent sits in | `bin/fm-teardown.sh`, `bin/fm-lock-lib.sh` | a bounded `/proc/*/cwd` (and `/proc/*/fd`) scan, which also sees the native Windows children MSYS spawned |
| `chmod` is a no-op on `noacl` mounts, so no PR can be merged and no watcher check can be armed | `bin/fm-pr-lib.sh` | the exact-mode assertion is capability-gated; see the security note below |

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

## Open: the session lock still cannot be acquired

The `/proc` substitution fixed every process-table read that stays inside the
MSYS process tree - `bin/fm-harness.sh` now answers `claude` instead of
`unknown`, and teardown, the watcher and the process-event runner all read their
fields correctly. The session lock is the one caller it does NOT fix, for a
second reason the port inventory did not know about.

**MSYS's `/proc` contains only MSYS processes.** Claude Code on Windows is a
native `claude.exe`, so it never appears there, and the Bash tool subprocess it
spawns reports `ppid = 1`. The ancestry walk therefore terminates on hop one with
no harness found, and `bin/fm-lock.sh acquire` still refuses - which keeps a
Windows session read-only under `AGENTS.md` section 3.

Measured inside a genuine Windows Claude Code session (2.1.200, `claude -p` with
a SessionStart hook), the chain is recoverable, just not from `/proc`:

```
MSYS pid=89  winpid=12140  msys_ppid=1        CLAUDECODE=1
12140 bash.exe   ppid=10412   .../bash.exe .../probe.sh
10412 bash.exe   ppid=41800   .../bash.exe -c "bash \"$CLAUDE_PROJECT_DIR/probe.sh\""
41800 bash.exe   ppid=34040   .../bash.exe -c "bash \"$CLAUDE_PROJECT_DIR/probe.sh\""
34040 claude.exe ppid=29440   ...\@anthropic-ai\claude-code\bin\claude.exe -p ...
29440 sh.exe     ppid=14864   .../sh.exe /c/.../npm/claude -p ...
```

`ps -W` lists native processes but reports `PPID 0` for them, so it cannot walk
the chain. `Get-CimInstance Win32_Process` can, and identifies `claude.exe` by
both its name and its install path - but one CIM call costs **566 ms**, and the
Stop hook runs it every turn.

This is a design decision, not a missing line of code, and it is the inventory's
own P0 item 3 ("harness ancestry under Windows Claude Code - needs discussion").
The hard part is not reading the chain, it is what the lock then STORES: every
other caller (`fm_harness_pid_alive`, `fm_session_lock_owned_by_self`, `kill -0`)
treats the recorded value as an MSYS pid, and a Windows pid is a different
namespace. Recording one without a namespace tag would let a lock-ownership test
match the wrong process. Options worth weighing: a tagged Windows identity across
the session-lock owner; a single whole-table CIM read cached per hook run; or
leaning on `CLAUDECODE` for detection while finding another way to answer "is
this the session that owns the lock?".

## Not yet ported

- No session provider. There is no tmux on Windows; multi-agent work needs a backend under `bin/backends/`.
- Relay's artifact writes (`x_mode_write_if_changed` in `bin/fm-bootstrap.sh`) still assert exact modes directly. Relay is off unless the home opts in.
- Away mode's daemon launch (`bin/fm-afk-launch.sh`) is unexamined on Windows.
- `fm_pending_reply_pid_identity` (`bin/fm-pending-reply-lib.sh`) still reads sender liveness through `ps -o lstart= -o command=`, which MSYS answers with nothing, so a secondmate's pending reply reads its sender as dead there. The fleet's `/proc` identity (`fm_pid_identity`) is the right substitute but lives in `bin/fm-wake-lib.sh`, which that file sources only inside one function; wiring it needs an owner move rather than a local patch.
- `bin/fm-arm-command-policy.mjs` compares paths with the platform `path` module, which disarms the protected-watcher-script guard on win32.
- The macOS-only surfaces (`bin/backends/herdr.sh`, `bin/fm-remote-job-*.sh`, muse) are deliberately out of scope.
