# Local Test evidence: the Windows end-to-end run record (docs only)

The change is documentation-only by design: it records a real end-to-end firstmate
run performed on the captain's Windows machine. That run itself cannot be re-executed
from this Linux gate worktree (no Windows host, no ConPTY), so its pasted transcripts
are taken as reported. What IS checkable here is every claim the record makes about
how the code behaves, and each of those was exercised against the real scripts.

| Recorded claim | How it was exercised here | Result |
|---|---|---|
| `fm-control.sh <id> exit` refuses on conpty, with the exact message quoted in `docs/windows.md` | real `bin/fm-control.sh` against a conpty task record (`conpty-control-plane-check.sh`) | message reproduced verbatim, exit 1 |
| `relaunch` is gated the same way (`docs/conpty-backend.md` "Active limits") | same fixture, `relaunch --note ...` | refused, exit 1 |
| `interrupt` refuses too, with `harness claude interrupts with Escape, which the conpty backend cannot deliver` | same fixture, agent classified `alive` by the daemon first | message reproduced verbatim; zero keys reached the session |
| Both refusals are false negatives: the adapter does classify agent state and does deliver Escape | `fm_backend_agent_state conpty` and `fm_backend_send_key conpty ... Escape` through the real dispatcher | `alive`; the `key --key Escape` client call was issued |
| Teardown refuses unlanded local-only work, naming the commit at risk and the routes out | real `bin/fm-teardown.sh` on a conpty task with a commit on the branch only (`conpty-teardown-session-dir-check.sh`) | refused with the same wording shape, records preserved |
| Teardown retires the task's records but leaves `state/conpty/<session>/` and its `transcript.log` "on any host" | same fixture after a local fast-forward | `state/<id>.*` gone, session dir and transcript still present - on Linux, confirming "any host" |
| The merged-branch prune path exists and normally deletes the task branch (so the Windows survival is a defect, cause unestablished) | same run, project branches listed before and after | `fm/task-x1` present before, gone after |
| `bin/fm-send.sh` refuses the first steer until the home is named (contract, not a fault) | real `bin/fm-send.sh` with `FM_HOME` unset | refused, exit 1 |
| The session-token lock path behind steps 1 and 6 (acquire on Windows, plain pid in `state/.lock`, SessionEnd release, immediate reacquire) | `tests/fm-session-token.test.sh` | all pass, including "releasing the token lets the very next session acquire without waiting" |
| A project with no reachable `origin` cannot be spawned against | `tests/fm-spawn-pool-base-freshen.test.sh` | "an unreachable origin refuses a potentially stale pooled worktree" passes |
| The new cross-links and doc ownership hold | `tests/fm-documentation-audiences.test.sh` | passes, including local-link resolution |

Not reproducible here: the "harness detection needs no Windows configuration" bullet
depends on the ancestry walk failing, which it does not do on Linux, so that bullet
stands on the recorded Windows run alone.

Files:
- `conpty-control-plane-check.sh` / `conpty-control-plane-transcript.txt`
- `conpty-teardown-session-dir-check.sh` / `teardown-conpty-transcript.txt`
- `fm-send-home-refusal.txt`
