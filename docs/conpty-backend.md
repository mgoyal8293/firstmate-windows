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
  That prebuilt `win32-x64` binding is also why the install needs no Visual Studio or node-gyp toolchain on Windows.
- Git for Windows, for the shell each task session starts in.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

No JSON parser is required.
Unlike herdr, zellij, and cmux, this backend adds no `jq` dependency: the session client projects every answer the adapter reads to a plain scalar.

Select it by putting `conpty` in a local `config/backend`, by exporting `FM_BACKEND=conpty`, or by telling the first mate in chat.
It is never auto-detected — there is no ambient session to detect, because each task's daemon is its own container.

`bin/fm-bootstrap.sh` runs that same dependency probe on a conpty home and reports `MISSING: conpty-backend-deps` with the install command, so a home missing it is no longer reported healthy.

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

**Liveness asks the shell which process owns the foreground, and the console list who is attached.**
The console process list is the closest Windows analogue of tmux's `ps -t <pane_tty>`: names are resolved together with process start times, cached per pid, and evicted the moment a pid leaves the list, so a recycled pid can never inherit the previous occupant's cached name.
On its own that list cannot say which attached process is actually *running* the session, because a ConPTY console has no foreground process group and no `tcgetpgrp` equivalent.
The shell answers that directly instead: the session shell is launched with [`fm-shell-integration.bash`](../bin/backends/conpty/fm-shell-integration.bash) as its rcfile, which has bash emit OSC 133 semantic prompt marks (the FinalTerm/FTCS sequences Microsoft documents for Windows Terminal shell integration), and the daemon tracks the last one as it parses the pty stream it already owns.
A shell at a prompt means nothing else is in charge, so a harness still attached is not running the session — exactly what tmux reads off a foreground process group holding nothing but a shell.
The marks cost nothing per poll: no syscall, no process sweep, no PowerShell.

The agent runs in the shell that carries the marks.
A bare `treehouse get` opens the pooled worktree in a provider subshell that lives for the whole task, which used to host the agent one level below the marked shell; on this backend `fm-spawn` leases the slot (`treehouse get --lease --lease-holder firstmate-<id>`) and `cd`s into it in the session shell instead.
The two hooks are still exported, so a shell nested inside the session by hand continues the chain rather than going silent — but nothing on the firstmate path is nested any more, so no foreign rc file sits between firstmate and the mark.

The verdict table is [`fmpty-liveness.js`](../bin/backends/conpty/fmpty-liveness.js), kept separate from the daemon so it is testable on any platform.
The screen is now only the fallback, read when a session has emitted no mark at all — a bash predating `PS0` (4.4), a non-bash session shell, a nested shell whose own rc files overwrite the carriers.
Silence is never read as `dead`.
Only `dead` and `missing` license recovery, so every genuinely conflicting reading resolves to `ambiguous` — a false `dead` is the one outcome that can launch a duplicate agent onto a live worktree.

**The control plane's verbs work here, and that is what the marks bought.**
This classifier is recovery-grade, so `bin/fm-control.sh <id> exit|interrupt|relaunch` are all available on this backend rather than refusing before they send; [`agent-control.md`](agent-control.md) owns the capability table and the postconditions.
`exit` is a proven stop, not a hopeful one: its postcondition is satisfied only once the shared classifier reads `dead`, so the frozen-`C` failure under "Active limits" makes it refuse rather than report an unproven transition as done.
Demonstrated end to end on real Windows against a genuinely spawned conpty task — `exit` returned in 9 s with the endpoint still `present` and the leased worktree still on disk — so a graceful stop, not a force-kill, is how a Windows crewmate is stopped, closing `winfm-conpty-control-exit` and `winfm-conpty-graceful-stop`.
The readings are in [`runtime-backends.md`](verification/runtime-backends.md), "The shipped spawn path, end to end on real Windows".

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
- **Foreground scoping depends on the session shell being bash, and being able to speak.** The prompt marks that recover tmux's foreground scoping need `PS0`, so bash 4.4 or newer. **That floor was NOT measured on the oldest supported Git for Windows**: what stands behind calling it a rare path is a survey of release notes, not a probe, and a release-notes survey is not a reading. What does hold it is a runtime check rather than a claim about the field — the prompt hook re-checks on every fire that the shell running it can still announce a running command — so the unmeasured case errs one way only: a shell that cannot expand `PS0` emits nothing at all, and recovery is suppressed rather than a live agent being reported as at-prompt. That older bash is one of three ways a session goes mark-less, alongside a session shell that is not bash and rc files that overwrite `PS0` and `PROMPT_COMMAND`; all three fall back to the console list plus the screen. That fallback is usually no longer a dead end for `exit`: because the spawn path leaves no worktree-provider process attached to the console, a session sitting at a recognisable shell prompt with only shells attached reads `dead` there too. Two things it still cannot narrow, both erring the same way — recovery suppressed, never a false stop. A background harness under a prompt the screen heuristic does not recognise classifies `alive`. And the agent arm of that heuristic matches its glyph anywhere in the last six non-blank rows, not just the bottom-most row the shell arm now requires, so a bare `→` or `›` in ordinary command output can hold a mark-less session at `ambiguous` — `exit` and `relaunch` refuse there until the screen scrolls.
- **A shell nested by hand can freeze the signal.** The carriers are inherited, but a nested shell reads its own rc files afterwards, and an ordinary `PROMPT_COMMAND='history -a'` there destroys the finished-mark carrier while leaving `PS0` intact: the session then emits `C` and never `D`, and liveness reports a command running for as long as that shell lives. `exit` refuses rather than claiming an unproven stop, so the failure is loud and never a false `dead`. No firstmate path is nested; this is reachable only in a shell someone opened themselves.
- **The mirror of that — a nested shell that can mark prompts but not commands — is ruled out rather than tolerated.** A rc file that assigns `PS0`, or a nested bash older than 4.4 that inherits `PS0` and never expands it, would leave the prompt hook marking every prompt and nothing marking a running command, which reports a live foreground agent as `at-prompt` and so as `dead` — the unsafe direction. The two carriers are therefore coupled rather than exported as independent facts: the prompt hook re-checks, every time it fires, that the shell running it can still announce a running command — `PS0` still carrying the mark, and a bash new enough to expand `PS0` at all — so the 4.4 floor holds wherever the hook fires rather than only where it was armed. A shell that fails either check emits nothing, the last mark remains the outer shell's `C`, and liveness falls back. What is left in this family is a session shell that destroys its own `PS0` after arming and keeps `PS1`: the prompt brackets still mark, so a command running in that shell can read `at-prompt` until the rcfile is sourced again, which re-arms both carriers.
- **The pool slot is released by an explicit return, not by a dying subshell.** Leasing the worktree is what removes the provider subshell, so the slot is freed by `treehouse return --force <dir>`: `fm-teardown` does it once the task record exists, and `bin/fm-spawn.sh`'s own abort path does it before then. That abort return is holder-scoped with `--if-lease-holder`, which treehouse refuses unless that holder still holds the lease; naming a wrong target would take two firstmate homes sharing one treehouse pool with the same task id, which no firstmate-provisioned layout produces. A release it confirms is silent. Any outcome it cannot confirm — including finding no lease recorded for this task yet, where an acquisition still running in the session may land one afterwards — prints what is known plus the exact reclaim command, and never fails the abort. The abort path releases the lease rather than reclaiming the slot outright: measured on Windows it clears `lease_holder` while the slot still reads `in-use` under the aborted session's own shell, and the slot returns to `available` when that window closes, which is deliberate because a spawn abort must not kill the endpoint holding the evidence of why it aborted. What is left is a crash that reaches neither — that leaves the slot leased, visibly and attributably, because the holder is recorded as `firstmate-<id>`, and one `treehouse return --force <path>` clears it.
- `treehouse get` opens `$SHELL`, falling back to `%COMSPEC%`, and cmd.exe announces no OSC 0 title and emits no prompt mark. This no longer reaches the spawn path: worktree acquisition runs `treehouse get --lease` inside a command substitution, which opens no shell at all, and discovery reads the session shell's own `cd`. The rcfile's `SHELL` repair (the value, or the value plus `.exe`, must begin with the PE magic `MZ`, which is what a native launcher needs to `CreateProcess` it) is therefore defensive cover for every other tool in the session that consults `$SHELL`; a session shell that never loads the rcfile gets no repair at all.
- **A session does not survive a Windows sign-out.** The daemon, its shell, and the agent all run in the interactive logon session (measured: SessionId 4 on the verification host), and Windows terminates a session's processes at logoff. The control surface is not the limitation — the pipe namespace is machine-global, verified directly — the process lifetime is. Locking the workstation, closing the launching terminal, and restarting firstmate all leave a session running; only an actual sign-out, reboot, or shutdown ends it. **This was not verified by a live sign-out** (see below).
- Running the daemon outside the interactive logon session, so it survives sign-out, would need a scheduled task registered with "run whether the user is logged on or not". That path is **untested** and is not implemented here; it also has an unresolved question of its own, since a harness running outside the interactive session may not find the credentials it expects in the user profile.
- Sessions are not shared between firstmate homes, and a home's sessions become unreachable if the install is relocated (the hometag changes).
- No native event push: the watcher uses its poll loop, the same permanent fallback tmux uses.
- Secondmate spawns on this backend are not yet designed or verified.
- **Away mode (`/afk`) is unavailable.** The away-mode daemon must inject into the pane firstmate *itself* runs in, and there is no ConPTY equivalent of `$TMUX_PANE` or `$HERDR_PANE_ID` for firstmate to identify that pane by; a Windows firstmate runs in Windows Terminal or Git Bash, not inside a session this adapter owns. Creating the daemon's own non-visible terminal is a second missing piece: `bin/fm-afk-launch.sh`'s create/close/exists primitives are per-backend, and this adapter's session creation is task-scoped. Both refuse cleanly today rather than degrading, and away mode is the only firstmate capability this costs.
- Scrollback while a harness holds the alternate screen is zero by construction; deep history comes from the transcript, which is capped and rotated (one generation kept) so an overnight session cannot fill the disk.
- **Teardown does not remove a completed task's session directory.** `bin/fm-teardown.sh` retires the task's own records but has no conpty cleanup at all, so `state/conpty/<session>/` and its `transcript.log` survive on any host. That transcript is deliberately durable evidence rather than a leak, but nothing prunes the directory afterwards, so one accumulates per completed task, tracked as `winfm-conpty-transcript-dir-accumulation`.
- No real-host gate reruns this adapter automatically. `.github/workflows/windows-ci.yml` runs `tests/fm-backend-conpty.test.sh` on `windows-latest`, but that test fakes the client. A real ConPTY console, a real daemon, and a real installed harness are covered by the opt-in `tests/fm-conpty-liveness-live-e2e.test.sh`, which has to be run by hand because standard CI has neither harness binaries nor credentials, plus the recorded manual pass above.

### Tracked items settled here

The items queued against this adapter's liveness reading and its remaining gaps were settled by the prompt-mark work above, and are recorded here so a reader does not have to infer their state from the mechanism.

- **`winfm-conpty-harness-name-shim` is CLOSED**, in the direction that mattered. The complaint was that on an npm-shim install a live `claude` would appear as `node.exe`, which `HARNESS_RE` does not match, so the classifier would report `dead` on a live agent — a false stop, the unsafe direction. That vector is gone because the at-prompt reading is taken **before** any name matching: an unrecognised harness can no longer read `dead` merely for being unrecognised. A positive `alive` still needs a recognised name, and an unrecognised process holding the foreground narrows to `ambiguous` rather than to either extreme — deliberately, matching what tmux reports for a foreground group holding something other than a shell. Checked against a real npm-shim install as well as against the mechanism: `@anthropic-ai/claude-code` 2.1.220 installs a native `bin/claude.exe`, and even the `--ignore-scripts` `cli-wrapper.cjs` fallback `spawnSync`s that same native binary, so `claude.exe` is what the console list reports either way. The readings are in [`runtime-backends.md`](verification/runtime-backends.md).
- **`winfm-conpty-limits-rnd` is RESOLVED**, with an answer rather than by being forgotten. It asked whether a native Windows facility could close these gaps, and both candidates were probed and rejected on evidence: **console control events** (`GenerateConsoleCtrlEvent`) need a process group, which is a creation-time attribute firstmate never holds, and adopting one would have broken `interrupt` — the one verb that already worked; and **job objects**, which terminate rather than ask, so they cannot give a graceful stop at all. Neither is to be revisited. What shipped instead is not a native facility but an inline one: OSC 133 semantic prompt marks read off the pty byte stream the daemon already owns, which is what the section above describes.
- **`winfm-conpty-screen-heuristic-defects` is LEFT OPEN BUT DEMOTED, not retired.** The screen is now only the fallback, read when a session has emitted no mark at all, so nothing on the shipped path depends on it. Both reported defects are fixed: the sparse-screen blindness, settled on a real 40-row terminal where a fresh session's content sits at the top of the viewport, and the `MINGW64`-in-scrollback false positive, since the shell arm now requires the bottom-most row rather than any row. What keeps the item open is the residual described in "Active limits" above — the agent arm still matches its glyph anywhere in the last six non-blank rows — which errs toward `ambiguous` and so suppresses recovery rather than causing a false stop.

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
FM_CONPTY_LIVENESS_LIVE=1 tests/fm-conpty-liveness-live-e2e.test.sh   # Windows only, opt-in
```

The first runs in CI and pins the decision table, the mark chain, and the adapter against a faked client.
The second is the half only a real console can answer - whether an installed harness is recognised by name and whether it writes OSC 133 marks of its own - so run it after any harness upgrade, and after a treehouse upgrade for the lease transition it also covers.

[`verification/runtime-backends.md`](verification/runtime-backends.md#conpty) records the active version matrix and the real-host lifecycle evidence.
