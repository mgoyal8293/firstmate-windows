# ConPTY runtime backend

`conpty` is an experimental, explicitly-selected, spawn-capable session provider for **Windows**, where tmux does not exist.
It replaces the session provider only; Treehouse remains the worktree provider, exactly as for herdr, zellij, and cmux.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

Unlike every other backend, `conpty` has no third-party multiplexer behind it.
Firstmate ships the session daemon itself, in [`bin/backends/conpty/`](../bin/backends/conpty/), because Windows offers nothing to adopt: a raw pseudoconsole is destroyed when its creating process exits, so a session provider has to own a process that outlives the caller.
The control surface is a named pipe speaking newline-delimited JSON, and it is deliberately not node-specific: PowerShell 5.1 has been verified driving a live session end to end with no node involved, which matters because firstmate's backends are shell scripts.

## Setup

Pick `conpty` when firstmate runs on Windows.
It is unsuitable anywhere else and refuses to start on a non-Windows host rather than degrading.

Prerequisites:

- Windows 10 1809 or newer (ConPTY's floor). Active evidence uses 10.0.26200.
- Node 20 or newer, already part of firstmate's universal toolchain.
- The daemon's pinned runtime dependencies, installed once: `npm install --omit=dev` in `bin/backends/conpty`.
  They are not vendored because node-pty ships a platform-specific prebuilt binary.
- Git for Windows, for the shell each task session starts in.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

No JSON parser is required.
Unlike herdr, zellij, and cmux, this backend adds no `jq` dependency: the session client projects every answer the adapter reads to a plain scalar.

Select it by putting `conpty` in a local `config/backend`, by exporting `FM_BACKEND=conpty`, or by telling the first mate in chat.
It is never auto-detected — there is no ambient session to detect, because each task's daemon is its own container.

A spawn refuses, before creating a session or a worktree, when the host is not Windows, when `node` is absent, when the daemon's dependencies are not installed, or when the task's session id is already live.
Verify setup by spawning a small task and confirming its metadata contains `backend=conpty` and a `conpty_session=` line.

Routine supervision is unchanged: `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> ...` work exactly as on tmux.
There is nothing to attach to and nothing to focus — a session is a background daemon, not a window.

### Diagnosing a host

`node bin/backends/conpty/fmpty.js doctor` reports whether the daemon's dependencies load, from the daemon's own directory.
Run it before filing a spawn failure; it distinguishes "not installed" from "installed but not loadable".

## Task shape and metadata

One daemon per task, one ConPTY per daemon, one session id per task.

The caller-facing label stays `fm-<id>`.
The session's real name is scoped by firstmate home — `fm-<hometag>-<id>` — and that scoped name is both the endpoint target and the pipe name.
Scoping is not cosmetic here.
The Windows named-pipe namespace is **machine-global**: one flat namespace shared by every process and every logon session, confirmed directly by listing `\\.\pipe\` from an unrelated process and seeing every live firstmate session.
Two homes that both spawned a task called `crew1` would otherwise contend for one pipe, and the loser's client would drive the winner's agent.
The hometag derivation is shared with cmux and zellij ([`bin/fm-backend-hometag-lib.sh`](../bin/fm-backend-hometag-lib.sh)) and carries the same caveat: relocating an install changes the tag and orphans its old sessions.

Task metadata:

```text
backend=conpty
window=fm-<hometag>-<id>
conpty_session=fm-<hometag>-<id>
endpoint_task_id=<id>
```

`window` and `conpty_session` are the same identifier because a conpty endpoint is a single atom, not a composite; teardown refuses any record where they disagree.
Session ids are stable across firstmate restarts, and recovery authority is the pipe, never a stored pid.

## Current operation and safety

**Identity is the pipe, not a pid.**
Windows recycles pids aggressively — the feasibility spike hit it twice by accident, once watching a dead launcher's pid come back as `msedgewebview2.exe`.
Every liveness answer here is therefore reached without consulting a recorded pid: the daemon replies to a ping with the session id and a per-generation nonce, so a recycled pid cannot impersonate a live session.
Where a recorded pid genuinely must be checked, `fmpty.js verify` validates the full identity triple (pid, executable name, process creation time) and reports `match`, `match-weak`, `mismatch`, or `gone` rather than a boolean, because a name-only match really is weaker.

**Liveness combines two independent sources.**
The primary source is the ConPTY console process list, the closest Windows analogue of tmux's `ps -t <pane_tty>`.
Names are resolved together with process start times, cached per pid, and evicted the moment a pid leaves the list, so a recycled pid can never inherit the previous occupant's cached name.
The screen is the second source, and it exists to narrow the foreground gap described under Active limits: a console naming a harness while the screen shows a bare shell prompt reports `ambiguous`, not `alive`, and a console showing only shells while the screen shows an agent composer reports `ambiguous`, not `dead`.
Only `dead` and `missing` license recovery, so every genuinely conflicting reading resolves to `ambiguous` — a false `dead` is the one outcome that can launch a duplicate agent onto a live worktree.

**Liveness is answered fresh, not from whatever was cached.**
A stale read is refreshed before the verdict is computed, and a caller arriving during an in-flight sweep waits for that sweep rather than being handed the value it was trying to escape.
The probe is kept warm on a bounded interval while anybody is asking and stops on its own afterwards, so an idle overnight session costs nothing.
Measured: a warm read is ~50 ms end to end, against ~1.6–2.0 s for the spike's cold probe.

**Worktree discovery reads the shell's own title.**
Windows has no `/proc/<pid>/cwd`, so the daemon parses the OSC 0/2 title Git Bash already emits (`MINGW64:/d/path`) for free.
That source goes sticky once a harness takes the title over, which is exactly why `fm-spawn` polls cwd **before** launching the harness.
A shell whose prompt sets no title falls back to an active marker-delimited `pwd` probe, mirroring zellij's and cmux's workaround; the probe writes to the session, so it is only used when the passive source has nothing.

**Sending is literal, submission is separate.**
Text is typed once and never retyped; only the Enter is retried, driven by the shared verify-and-retry core.
Text is passed to the client **through a file**, never on the command line: a Windows command line is length-bounded and quotes differently from the shell, so a multi-line brief on the argument path is a portability trap.
Git Bash's automatic path mangling is disabled for every client invocation (`MSYS2_ARG_CONV_EXCL`), and paths are translated explicitly with `cygpath` instead, so a steer mentioning `/usr/bin/env` arrives unmodified.
Supported keys are `Enter`, `Escape`, `Tab`, `Space`, `BSpace`, the arrows, `Home`/`End`, `PageUp`/`PageDown`, `C-<letter>` and `M-<char>`.

**Composer classification is a thin adapter.**
This backend contributes only a capture and a capability descriptor; every shape and verdict is owned by [`bin/fm-composer-lib.sh`](../bin/fm-composer-lib.sh).
It declares `styled=1 cursor=1`, making it the second backend able to declare both and the first that is not tmux.
The cursor row is real — xterm.js's `buffer.active.cursorY` — so the classifier anchors on the shape containing the cursor and can read a long wrapped composer line as genuine pending input, where a cursorless backend can only fall back to the bottom-most shape.
The styled screen is rendered row by row rather than through a serializer, because the serializer joins wrapped rows to preserve reflow and the classifier indexes the screen **by** the cursor row; one output line per buffer row is what keeps the two aligned.
The cursor row and the screen come from a single client call, so they cannot straddle a redraw.
Only an exact `empty` verdict confirms delivery.

**Capture follows tmux's semantics.**
`capture` is `capture-pane -p -S -<lines>`: that many rows of scrollback above the viewport top **plus** the whole viewport, not the last N rows.
Note that while a harness holds the alternate screen — claude does — no scrollback exists to read, in xterm.js exactly as in a real terminal and exactly as tmux behaves on an alt-screen pane.
The session's durable transcript is the route to deeper history.

**Busy state is measured, not inferred.**
The daemon owns the pty byte stream, so it knows how long it has been since the session last produced output.
tmux has to infer the same thing by hashing pane content across polls; here it is a direct reading, and `-1` (no output ever) is reported as `unknown` rather than folded into an age comparison.

**Cleanup reaps the console set, not the process tree.**
This is a correctness requirement rather than an implementation detail: the spike proved `claude.exe` is attached to the pty console while **not** being a descendant of the daemon, because its parent chain ran through an `sh.exe` that had already exited.
A parent-tree kill would leave the live agent behind.
Verified on a real session: daemon, shell, and agent all reaped, zero orphans.

**A crash is detected, not guessed.**
Each session keeps a durable record whose `shutdown` field starts at `running` and only ever becomes `clean` on the intentional path.
So `fmpty.js health` distinguishes four states, and firstmate acts differently on each: `live`, `clean` (asked to stop — ordinary teardown), `crashed` (died unasked), and `absent`.
A crashed session's transcript is the only surviving evidence of what the agent was doing, and `fmpty.js restart` rebuilds the session from the recorded launch spec into a new epoch, rotating that transcript aside rather than appending to it.

Restart is deliberately explicit and deliberately not called recovery.
The pseudoconsole is destroyed with its creating process, so a dead daemon means a dead agent; a supervisor that silently respawned the daemon would hand firstmate a fresh empty shell wearing a live session's name, which is worse than an honest failure because it looks like success.
Verified: killing the daemon with `taskkill /F` left **no** orphaned agent — daemon, shell, and `claude.exe` all terminated with the pseudoconsole — so a crash cannot strand a process holding a worktree.

Regression safety for this adapter's own tests is in `tests/fm-backend-conpty.test.sh`, which fakes the client and therefore runs on any platform.

## Active limits

- conpty is experimental and newer than every other adapter here; tmux remains the verified reference backend.
- **Liveness is console-scoped, not foreground-scoped.** tmux deliberately relies on foreground-process-group scoping so a harness-named process idling in the *background* of an otherwise idle pane still classifies `dead`. A ConPTY console has a process list but no foreground concept, so that case cannot be detected the same way. It is narrowed by the screen as a second source, which catches it whenever the session is sitting at a recognisable shell prompt; a background harness under a prompt the screen heuristic does not recognise still classifies `alive`. The failure direction is the safe one — recovery is suppressed rather than a duplicate agent launched — but it is a real fidelity gap against tmux.
- **No control verb reaches an agent here, because two stale allowlists exclude conpty.** Both gates live in `bin/fm-control-lib.sh` and neither names this backend: `fm_control_backend_state_verified` gates `exit` and `relaunch` and still lists only `tmux` and `herdr`, while the key matrix `fm_control_backend_supports_key` gates `interrupt` and lists only `tmux`, `herdr`, `zellij`, `cmux`, and `orca`. So `bin/fm-control.sh <id> exit` refuses rather than report a stop it cannot prove, and `interrupt` refuses too, with `harness claude interrupts with Escape, which the conpty backend cannot deliver; refusing to send a different key` (from `bin/fm-control.sh`; derived from source, not exercised in the end-to-end Windows run recorded in [`windows.md`](windows.md) "Run end to end on Windows"). Both refusals are false negatives rather than absent capabilities: this adapter implements a recovery-grade agent-state classifier (`fm_backend_conpty_agent_state`, dispatched from `bin/fm-backend.sh` and validating pid identity by name and start time), and it does deliver Escape (`fm_backend_conpty_normalize_key` and `fm_backend_conpty_send_key`). The `exit` refusal's own wording compounds this, since it blames a missing classifier that conpty in fact has. The exit refusal was measured end to end on a real session and names the backend; stopping the agent then falls to `bin/fm-teardown.sh`'s reaper, which force-kills the leaked worktree processes. There is no graceful agent shutdown on this backend yet, tracked as `winfm-conpty-graceful-stop` (queued in firstmate-windows), with `winfm-conpty-limits-rnd` separately investigating whether native Windows facilities can close it.
- **A session does not survive a Windows sign-out.** The daemon, its shell, and the agent all run in the interactive logon session (measured: SessionId 4 on the verification host), and Windows terminates a session's processes at logoff. The control surface is not the limitation — the pipe namespace is machine-global, verified directly — the process lifetime is. Locking the workstation, closing the launching terminal, and restarting firstmate all leave a session running; only an actual sign-out, reboot, or shutdown ends it. **This was not verified by a live sign-out** (see below).
- Running the daemon outside the interactive logon session, so it survives sign-out, would need a scheduled task registered with "run whether the user is logged on or not". That path is **untested** and is not implemented here; it also has an unresolved question of its own, since a harness running outside the interactive session may not find the credentials it expects in the user profile.
- Sessions are not shared between firstmate homes, and a home's sessions become unreachable if the install is relocated (the hometag changes).
- No native event push: the watcher uses its poll loop, the same permanent fallback tmux uses.
- Secondmate spawns on this backend are not yet designed or verified.
- Scrollback while a harness holds the alternate screen is zero by construction; deep history comes from the transcript, which is capped and rotated (one generation kept) so an overnight session cannot fill the disk.
- **Teardown does not remove a completed task's session directory.** `bin/fm-teardown.sh` retires the task's own records but has no conpty cleanup at all, so `state/conpty/<session>/` and its `transcript.log` survive on any host. That transcript is deliberately durable evidence rather than a leak, but nothing prunes the directory afterwards, so one accumulates per completed task, tracked as `winfm-conpty-transcript-dir-accumulation`.
- Windows itself is not a firstmate CI platform, so this adapter's real-host evidence is a recorded manual pass, not a gate that reruns on every change.

### The sign-out test that was not run

A live sign-out would have terminated the logon session running the verification work itself, and signing the machine's owner out is a disruptive action taken on their behalf.
The finding above is therefore established by mechanism — measured session membership plus Windows' documented session teardown at logoff — and not by observation.

To settle it in about two minutes on a machine that is free to sign out:

```sh
# 1. spawn a task on conpty, then note the session id
bin/fm-spawn.sh ...            # or: node bin/backends/conpty/fmpty.js spawn --id t1 --cmd 'C:\Program Files\Git\bin\bash.exe' --arg -i
# 2. sign out of Windows completely (not lock, not disconnect), then sign back in
# 3. ask the session whether it is still there
node bin/backends/conpty/fmpty.js health --id t1
#    live    -> sessions survive sign-out; this limit can be struck
#    crashed -> the daemon was terminated with the logon session, as expected
```

Report the result back into this section either way.

## Regression entry points

```sh
tests/fm-backend-conpty.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#conpty) records the active version matrix and the real-host lifecycle evidence.
