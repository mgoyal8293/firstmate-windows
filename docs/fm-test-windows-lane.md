# Firstmate Windows CI lane

`.github/workflows/windows-ci.yml` runs the lanes.
`bin/fm-test-run.sh` owns the lane's membership and shard count.
This file records the measurements those two are built on.

Every number here was measured under Git for Windows MINGW64 bash
(`MINGW64_NT-10.0-26200`, bash 5.2.37, git 2.50.1.windows.1, ShellCheck 0.11.0),
from a frozen checkout, with `MSYS=winsymlinks:nativestrict`.

## Why this lane is not the Linux lane with more shards

Git Bash pays 14-18x more per process than Linux, because every `fork` is an
MSYS process-creation emulation rather than a kernel `fork`.
That multiplier does not fall evenly: it is worst on short scripts, where fixed
process-startup cost dominates.

The consequence is arithmetic, not opinion.
`portable-serial` is a derived remainder of 115 scripts.
Its recorded duration hints cover 69 of them and total 1143762 ms; the other 46
carry the 20000 ms default, so the lane is roughly 34 minutes of Linux work.
At 16x that is about **9 hours**.

Sharding cannot fix this, because the longest single script sets a floor no
shard count can lower.
`tests/fm-pr-check-security.test.sh` alone is 199573 ms on Linux -
`docs/fm-test-portable-shards.md` already calls it "the floor for any shard
count" - which is roughly **53 minutes** on Windows in one indivisible unit.

So the Windows lane carries a **measured subset**, sharded, rather than the
whole suite.

## Membership rule

A script joins the lane when it exits 0 with no failed assertion on Git Bash.
A gate skip counts as green: that is the test declining to run, which it does on
Linux too.

The list is **enumerated, not derived**.
The Linux serial lane is derived on purpose, so a newly added test lands in a
required lane by default.
Here that same default would drop an unported test straight into a green gate
and turn it red, which is what this fork is trying to get away from.
A new test joins this lane once it is measured green on Windows.

The coverage guard still proves the lane is real: every listed script exists,
the shards are disjoint, and together they equal the list exactly.
It deliberately does **not** fold the Windows lane into the
parallel + serial + Herdr partition of `tests/*.test.sh`, because the Windows
lane is a subset overlay of that inventory rather than another part of it.

## Checkout must be LF

Git for Windows defaults `core.autocrlf=true`, and this repo has no
`.gitattributes` to override it.
A CRLF working tree makes ShellCheck reject **every** shell file with SC1017
("Literal carriage return"), so the lint gate fails on line 1 of everything and
reports nothing about the code.

Measured, on the same tree:

| checkout | `bin/fm-lint.sh` |
|---|---|
| `core.autocrlf=true` (Git for Windows default) | fails - SC1017 on all 304 files |
| `core.autocrlf=false`, `core.eol=lf` | **passes, rc=0** |

Both lanes therefore set `core.autocrlf=false` and `core.eol=lf` *before*
`actions/checkout`, then assert the working tree really is LF and fail loudly if
it is not.

## The harness PATH

16 test files run the code under test with `BASE_PATH` as its only `PATH`,
defaulting to `/usr/bin:/bin:/usr/sbin:/sbin` and overridable through
`FM_TEST_BASE_PATH`.
On MINGW64 that default list holds almost none of the toolchain, so the code
under test sees a machine with no `git` and the assertions fail for the
harness's reasons rather than the code's:

```
git  -> /mingw64/bin/git
gh   -> /c/Program Files/GitHub CLI/gh
node -> /c/nvm4w/nodejs/node        (a developer machine; different on the runner)
jq   -> /c/Users/<user>/AppData/Local/.../jq
```

The lane builds `FM_TEST_BASE_PATH` from `command -v` at run time rather than
from literal paths, so a runner-image change - a new Node directory, a relocated
`gh` - cannot silently empty it again.
`tests/fm-remote-doctor.test.sh` hardcodes `BASE_PATH` with no override and is
not fixed here.

## Lint lane

`bin/fm-lint.sh` was unrunnable on Windows before this work:
`bin/fm-install-shellcheck.sh` only knew Linux and Darwin archives, and
`bin/fm-lint.sh` exits 127 without ShellCheck.
`bin/fm-lint-workflows.sh` needs actionlint for the same reason.

Both installers now have a pinned Windows arm.
Both Windows assets are zips holding a bare `.exe`, not `.tar.{xz,gz}` holding a
versioned directory, and GNU tar cannot read zip - hence a separate extract arm
rather than a different archive name.

Measured: **rc=0 in 5m35s** for 304 shell files plus 4 workflow files, with
`fm-lint.sh` at its 2-worker cap.

## Lane composition

Measured by running all 95 candidate scripts serially from a frozen checkout
with a 180-second per-script bound, plus dedicated longer runs for the three
scripts that bound exceeded.

| | scripts |
|---|---:|
| candidates measured | 98 |
| **in the lane (exit 0, no failed assertion)** | **45** |
| failing on Windows, excluded | 41 |
| still unresolved (hit the 180s bound, no failure seen) | 12 |

45 + 41 + 12 = 98. One of the 41, `tests/fm-teardown.test.sh`, has its cause
isolated below; the other 40 are recorded but not chased.

Total lane cost: **61.9 min** of serial Git Bash work.
The longest single script is `tests/fm-decision-hold-lifecycle.test.sh` at 860s,
which is the floor no shard count can lower - so 4 shards is the useful maximum
here, not 8 or 16. Beyond 4 the floor binds and extra runners buy nothing.

| shard | scripts | measured |
|---|---:|---:|
| `windows-1of4` | 7 | 930s (15.5 min) |
| `windows-2of4` | 9 | 929s (15.5 min) |
| `windows-3of4` | 15 | 928s (15.5 min) |
| `windows-4of4` | 14 | 927s (15.4 min) |
| imbalance | | 3s |

`timeout-minutes: 40` is a hang tripwire with roughly 3x margin over a healthy
15.5-minute shard, not the expected end of the lane. GitHub's Windows runners are
slower than the machine these numbers came from.

## The fork-cost multiplier is not a single number

The 14-18x headline holds for mid-sized scripts, but the ratio grows as a script
does more process work, because MSYS process creation - not the test's own logic -
dominates. Measured against this repo's recorded Linux durations:

| script | Linux | Git Bash | ratio |
|---|---:|---:|---:|
| `fm-decision-hold-lifecycle` | 30.8s | 860s | 27.9x |
| `fm-crew-state` | 25.4s | 171s | 6.7x |
| `fm-brief` | 2.2s | 21s | 9.5x |
| `fm-composer-lib` | 0.064s | 119s | ~1860x |

This is why the lane's balance uses measured Windows durations rather than Linux
hints scaled by a constant: a constant multiplier mis-sizes both ends.

## Scripts excluded, and why

41 scripts fail on Windows. Only `fm-teardown` was in scope here; the other 40
fail for reasons this PR does not address, each outside the files this work owns. They are recorded rather than silently dropped so the
next port task has a worklist. Two causes are worth naming because they are
shared:

- **The restricted-PATH toolbin pattern.** Several tests symlink MSYS binaries
  into a private directory and then run the code under test with PATH restricted
  to it, which makes `msys-2.0.dll` unreachable (see the `fm-crew-state`
  isolation below). `tests/fm-lint.test.sh` and
  `tests/fm-subagent-pretool-check.test.sh` both use it.
- **Directory-mode assertions.** MSYS mounts `/tmp` `noacl`, so `mkdir -m 700`
  fails and `stat -c '%a'` always reports 755. Any check requiring a 700
  round-trip refuses (see the `fm-teardown` isolation below).

12 more hit the 180-second measuring bound with no failed assertion, so they are
unresolved rather than failing - candidates for the lane once measured properly.

## The three previously unisolated failures

### `fm-crew-state.test.sh` - a harness defect, not timing

`make_no_timeout_toolbin` symlinks tools into a private directory and callers run
the code under test with PATH restricted to that directory. On Windows an MSYS or
MINGW binary locates its runtime DLL *through PATH*, Windows' last-resort DLL
search location, so dropping the real bin directory makes `msys-2.0.dll`
unreachable and the linked `bash` dies with `error while loading shared
libraries` before running.

| toolbin | PATH | result |
|---|---|---|
| symlink to bash | full | runs |
| symlink to bash | toolbin only | **error while loading shared libraries** |
| symlink + `msys-2.0.dll` alongside | toolbin only | runs |
| exec wrapper | toolbin only | runs |

Fixed with the exec wrapper, not by copying DLLs: `git` is mingw64-linked and
needs a different DLL set than the `/usr/bin` tools.
Before: 38 ok / 1 failed. After: **rc=0, 49 ok** (the fix also unblocked 11
assertions the abort had hidden).

### `fm-wake-queue.test.sh` - fork cost, measured

`wait_for_exit` was instrumented to report observed latency for the watcher's
start-poll-print-exit cycle:

| | first signal | second signal | bound | headroom |
|---|---:|---:|---:|---:|
| Linux | 1.6s | 1.5s | 4.0s | 2.5x |
| Git Bash | 10.4s | 8.9s | 4.0s | exceeded 2.6x |

The Windows bound is 30s, giving Windows the same ~2.5x headroom over its own
measured worst case that Linux has over its own. Scaled in a Windows arm so the
Linux tripwire keeps its sensitivity.
Before: 4 ok / 1 failed. After: **rc=0, 19 ok**.

### `fm-teardown.test.sh` - isolated, fix belongs elsewhere

Re-measured on current HEAD first: still fails identically (9 ok / 1 failed),
so the merged mode and `lsof` fixes did not cover it. The cause is neither:

```
error: herdr session presentation lock could not be resolved for task-x1
```

`fm_backend_herdr_presentation_lock_namespace_valid` in `bin/backends/herdr.sh`
requires `stat -c '%a'` to report 700 on a `mkdir -m 700` directory. On MSYS:

```
mkdir -m 700          -> "cannot change permissions ... Permission denied"
stat -c %a            -> 755, before and after an explicit chmod 700
id -u == stat -c %u   -> the owner check passes; only the mode fails
```

The fix is a capability probe in that one function, plus a note that the mode
assertion is not a security property on a `noacl` mount. That file is outside
the files this work owns, so it is flagged rather than changed.

### `fm-decision-hold-lifecycle.test.sh` - confirmed fork cost

Not a failure. Given a bound longer than the scout's 400s it passes:
**rc=0, 16 ok, 0 failed, in 860s** against 30.8s on Linux - a 27.9x multiplier.
It is in the lane, and it is the script that sets the shard floor.

### Failing on Windows (worklist, not addressed here)

```
SWEEP_COMPLETE                                          s  ok=    failed=
tests/fm-arm-pretool-check.test.sh                    92s  ok=36  failed=1
tests/fm-backend-herdr.test.sh                        15s  ok=19  failed=1
tests/fm-backend.test.sh                               3s  ok=0   failed=1
tests/fm-busy-adapter-wiring.test.sh                  15s  ok=0   failed=1
tests/fm-control-relaunch.test.sh                     52s  ok=2   failed=1
tests/fm-cursor-harness.test.sh                       13s  ok=8   failed=1
tests/fm-cursor-primary.test.sh                        1s  ok=0   failed=1
tests/fm-daemon.test.sh                              168s  ok=83  failed=1
tests/fm-documentation-audiences.test.sh               2s  ok=0   failed=1
tests/fm-ensure-agents-md.test.sh                      9s  ok=9   failed=1
tests/fm-grok-harness.test.sh                         44s  ok=2   failed=1
tests/fm-herdr-lab.test.sh                            53s  ok=6   failed=1
tests/fm-inactive-reconcile.test.sh                  159s  ok=12  failed=1
tests/fm-kimi-harness.test.sh                          2s  ok=0   failed=1
tests/fm-lint-workflows.test.sh                        7s  ok=7   failed=1
tests/fm-lint.test.sh                                 15s  ok=5   failed=1
tests/fm-muse-harness.test.sh                        138s  ok=10  failed=1
tests/fm-operational-input.test.sh                     6s  ok=5   failed=1
tests/fm-pending-reply.test.sh                        13s  ok=1   failed=1
tests/fm-pi-watch-extension.test.sh                    9s  ok=0   failed=1
tests/fm-pr-check-security.test.sh                     3s  ok=0   failed=1
tests/fm-procevent-when.test.sh                       10s  ok=0   failed=1
tests/fm-procevent.test.sh                            17s  ok=2   failed=1
tests/fm-public-followup.test.sh                       3s  ok=0   failed=1
tests/fm-remote-secondmate-parent-binding.test.sh     19s  ok=1   failed=1
tests/fm-session-lock-ancestry.test.sh                 4s  ok=0   failed=1
tests/fm-session-start.test.sh                        72s  ok=1   failed=1
tests/fm-sessionstart-nudge.test.sh                   11s  ok=7   failed=1
tests/fm-spawn-worktree-settle.test.sh                22s  ok=1   failed=1
tests/fm-startup-network.test.sh                      33s  ok=1   failed=1
tests/fm-subagent-pretool-check.test.sh               30s  ok=12  failed=1
tests/fm-teardown-endpoint-safety.test.sh             47s  ok=5   failed=1
tests/fm-test-run.test.sh                             62s  ok=5   failed=1
tests/fm-turnend-guard.test.sh                        57s  ok=30  failed=1
tests/fm-wake-daemon-lifecycle-e2e.test.sh            14s  ok=0   failed=1
tests/fm-watch-arm.test.sh                           163s  ok=3   failed=1
tests/fm-watch-checkpoint.test.sh                     13s  ok=1   failed=1
tests/fm-watch-triage.test.sh                         19s  ok=9   failed=1
tests/fm-watcher-lock.test.sh                         58s  ok=10  failed=1
tests/fm-x-mode.test.sh                               10s  ok=4   failed=1
```

### Unresolved: hit the 180s measuring bound with no failed assertion

```
tests/fm-bootstrap.test.sh                           ok=3   failed=0
tests/fm-cd-pretool-check.test.sh                    ok=2   failed=0
tests/fm-control.test.sh                             ok=11  failed=0
tests/fm-fleet-sync.test.sh                          ok=16  failed=0
tests/fm-guard-stale-banner.test.sh                  ok=20  failed=0
tests/fm-send-resolve-key.test.sh                    ok=7   failed=0
tests/fm-spawn-dispatch-profile.test.sh              ok=14  failed=0
tests/fm-trace-context-spawn.test.sh                 ok=10  failed=0
tests/fm-update.test.sh                              ok=5   failed=0
tests/fm-wake-drain-open-decisions-cursor.test.sh    ok=2   failed=0
tests/fm-wake-drain-open-decisions.test.sh           ok=6   failed=0
tests/fm-wake-drain-unread-status.test.sh            ok=6   failed=0
```

Each of these was still passing assertions when the bound cut it, so none is
known-broken. `fm-decision-hold-lifecycle` started in this group and turned out
to be pure fork cost once given 860s, so the others deserve the same treatment
before anyone calls them failures.
