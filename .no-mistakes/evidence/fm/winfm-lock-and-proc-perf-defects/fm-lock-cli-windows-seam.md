# fm-lock.sh, end to end under the Windows platform seam

The real CLI, run detached against a throwaway home so the tree reparents to init
(the shape tests/fm-session-lock-ancestry.test.sh uses), with a counting shim on PATH
in front of ps so every process-table read the run makes is recorded.
Host: WSL2 Linux, bash 5.2.21. The seam drives the Windows arms from a POSIX runner.

## No session token in the environment: the refusal a non-Claude Windows session reads

```console
===== AS SHIPPED (base 4c5336c) =====
$ bin/fm-lock.sh          # Windows seam, no session token in the environment
  error: no firstmate session token in this environment, so this session cannot prove it owns this home - on Windows ownership is a per-session token, never process ancestry, because a native harness never appears in MSYS's /proc. Only Claude Code exports one today (CLAUDE_CODE_SESSION_ID); under any other harness a Windows firstmate stays read-only - run firstmate from Claude Code, or continue read-only (docs/windows.md 'How the session lock is owned')
  exit status: 1
  process-table reads made by this single run: 36

===== FIXED (HEAD 038449c) =====
$ bin/fm-lock.sh          # Windows seam, no session token in the environment
  error: no firstmate session token in this environment, so this session cannot prove it owns this home - on Windows ownership is a per-session token, never process ancestry, because a native harness never appears in MSYS's /proc. Only Claude Code exports one today (CLAUDE_CODE_SESSION_ID); under any other harness a Windows firstmate stays read-only - run firstmate from Claude Code, or continue read-only (docs/windows.md 'How the session lock is owned')
  exit status: 1
  process-table reads made by this single run: 24
```

Same message, same exit status, a third fewer process-table reads.
bin/fm-lock.sh is the repeat-predicate path the intent names: it asks
fm_session_ancestry_unavailable twice, and the memo answers the second from a variable.

## With a Claude session token: the acquisition a Windows captain depends on

```console
===== AS SHIPPED (base 4c5336c) =====
$ CLAUDE_CODE_SESSION_ID=6f0d2a5e-winfm-demo-0001 bin/fm-lock.sh
  lock acquired: session token
  exit status: 0
  state/.lock          -> [3109418]  (plain numeric pid, as before)
  state/.lock.session  -> [6f0d2a5e-winfm-demo-0001]
$ bin/fm-lock.sh status
  lock: held by this session's token

===== FIXED (HEAD 038449c) =====
$ CLAUDE_CODE_SESSION_ID=6f0d2a5e-winfm-demo-0001 bin/fm-lock.sh
  lock acquired: session token
  exit status: 0
  state/.lock          -> [3109656]  (plain numeric pid, as before)
  state/.lock.session  -> [6f0d2a5e-winfm-demo-0001]
$ bin/fm-lock.sh status
  lock: held by this session's token
```
