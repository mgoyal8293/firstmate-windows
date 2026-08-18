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
Linux too. But a script that can *only* skip on this runner, because the tool it
needs is not installed there, is left out - see the five green-by-skip scripts
below.

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

Every candidate directory is converted to POSIX form with `cygpath -u` before it
enters that string, at the single `add_dir` chokepoint. PATH is colon-separated,
so a Windows-form entry splits at its drive-letter colon: `C:\npm\prefix` becomes
a bare relative `C` plus a `\npm\prefix` that MSYS reads as root-relative and
that does not exist. `npm prefix -g` prints exactly that form, because npm
resolves through native node - so the npm global bin, the entry that exists
because `npm install -g` puts `tasks-axi` there, was the one entry the step
failed to add. `cygpath` is probed rather than assumed, and the step now prints
every entry and fails on a surviving single-letter or backslash entry, so this
cannot regress silently. The `windows-behavior` job installs no ShellCheck: no
lane member runs it, and `windows-lint` already proves that installer on the
runner.
All 16 test files that build a restricted PATH honour `FM_TEST_BASE_PATH` as of
`1baa477`, `tests/fm-remote-doctor.test.sh` among them, so nothing here needs an
override added. Where such a test still fails on Windows the cause is the
`$TOOLS` prefix of `ln -sf` symlinks, not the base path - the same restricted-PATH
MSYS-DLL pattern named under "Scripts excluded, and why" below.

## Lint lane

`bin/fm-lint.sh` was unrunnable on Windows before this work:
`bin/fm-install-shellcheck.sh` only knew Linux and Darwin archives, and
`bin/fm-lint.sh` exits 127 without ShellCheck.
`bin/fm-lint-workflows.sh` needs actionlint for the same reason.

Both installers now have a pinned Windows arm.
Both Windows assets are zips holding a bare `.exe`, not `.tar.{xz,gz}` holding a
versioned directory, and GNU tar cannot read zip - hence a separate extract arm
rather than a different archive name.

Measured: **rc=0 in 5m35s** for 304 shell files plus 5 workflow files, with
`fm-lint.sh` at its 2-worker cap.

## Lane composition

Measured by running all 98 candidate scripts serially from a frozen checkout
with a 180-second per-script bound, plus dedicated longer runs for the three
scripts that bound exceeded.

| | scripts |
|---|---:|
| candidates measured | 98 |
| measured green (exit 0, no failed assertion) | 45 |
| of those, green only because they gate-skip on the runner - dropped | 5 |
| **in the lane** | **40** |
| failing on Windows, excluded | 41 |
| still unresolved (hit the 180s bound, no failure seen) | 12 |

45 + 41 + 12 = 98. One of the 41, `tests/fm-teardown.test.sh`, has its cause
isolated below; the other 40 are recorded but not chased.

### The five green-by-skip scripts are not lane members

`tests/fm-afk-inject-e2e.test.sh`, `tests/fm-backend-tmux-smoke.test.sh` and
`tests/fm-tmux-agent-liveness.test.sh` exit early on `command -v tmux`;
`tests/fm-backend-herdr-focus-flash-e2e.test.sh` on `command -v herdr`;
`tests/fm-claude-stop-autoarm-live-e2e.test.sh` unless `FM_CLAUDE_LIVE_E2E=1`.
The job installs none of that, so on `windows-latest` those five can only skip.
They are dropped from the lane rather than carried, and neither tmux nor herdr is
installed on the runner - not needing tmux is the point of this port.

Dropping them loses no Windows coverage, because they never executed anything
there. What it buys is honesty about what the lane runs: a dropped member is
visible in `list_windows`, whereas a member that silently skips every run is
invisible, and there would be no signal if the runner image later lost a tool.
That is the same principle behind the Linux serial lane's "Require tmux for e2e
tests" step (`.github/workflows/ci.yml`), which hard-fails so those scripts
cannot quietly skip on a required gate. The Windows lane reaches it from the
other direction: no tool, no member.

Total lane cost: **61.9 min** of serial Git Bash work (3,714,000 ms of hints).
The longest single script is `tests/fm-decision-hold-lifecycle.test.sh` at 860s,
which is the floor no shard count can lower - so 4 shards is the useful maximum
here, not 8 or 16. Beyond 4 the floor binds and extra runners buy nothing.

| shard | scripts | predicted |
|---|---:|---:|
| `windows-1of4` | 6 | 929s (15.5 min) |
| `windows-2of4` | 8 | 929s (15.5 min) |
| `windows-3of4` | 13 | 928s (15.5 min) |
| `windows-4of4` | 13 | 928s (15.5 min) |
| imbalance | | 1s |

**`windows-4of4` was run end to end on Git Bash to check that sum against
reality: rc=0, 14/14 scripts, 0 failures, 2 gate skips, wall 932s (15.5 min)**
against 927s predicted - 0.5% out, which is what makes the other three shards'
predicted figures trustworthy. That run was taken before the five green-by-skip
scripts were dropped, so it covered 14 scripts including the 2 that skipped;
the same shard is now 13 scripts and 928s, and the drop moves no measured work.

`timeout-minutes: 40` is a hang tripwire with roughly 2.6x margin over a healthy
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

One wall-clock bound in that file then needed scaling, because the wrapper costs
a second MSYS process per tool call. `test_no_timeout_uses_perl_bound` bounds the
perl-bounded `no-mistakes` lookup, measured around exactly the command the
assertion wraps with the bound neutralised so the run completes:

| platform | run 1 | run 2 | run 3 | worst | bound | headroom |
|---|---:|---:|---:|---:|---:|---:|
| Linux | 1.246s | 1.258s | 1.264s | 1.264s | 5s | 4.0x |
| Git Bash | 3.429s | 4.219s | 4.605s | 4.605s | 25s | 5.4x |

The 5s bound failed on Windows by a hair rather than an order of magnitude: the
assertion compares integer `$SECONDS`, so a true 4.605s reads as `elapsed=5` and
`[ 5 -lt 5 ]` is false. That was the whole failure. 25s is deliberately more than
parity headroom because the Windows figure is far less stable - a 34% spread
across three runs against 1.4% on Linux - and a GitHub Windows runner is slower
than the machine these came from. Scaled in a `MINGW*|MSYS*` arm so the Linux
tripwire keeps its 5s sensitivity. With the bound neutralised the script is
**rc=0, 49 ok / 0 not ok** on Git Bash, so this bound was the single remaining
Windows failure in the file and the exec-wrapper fix holds.

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

## Two things that stopped the runner itself on Windows

Neither is about a test. Both stopped `bin/fm-test-run.sh` before any test ran,
and both were present at HEAD with no Windows lane involved.

### `--check-coverage` exited 1 on a locale mismatch

```
comm: file 2 is not in sorted order
comm: input is not in sorted order
```

Every `comm` input in `run_coverage_guard` - and in the runner's own
`tests/fm-test-run.test.sh` - is produced by `LC_ALL=C sort`, but
`comm` validates its inputs' order using the **ambient** locale. Git Bash
defaults to `en_US.UTF-8`, whose collation differs from C, so `comm` rejected
correctly-sorted input and the guard failed for the locale's reasons rather than
the inventory's. This is also why `tests/fm-test-run.test.sh` failed on Windows.

Fixed by matching the comparison locale to the sort locale, in the guard and in
that test. That is correct on every platform - sort with `LC_ALL=C`, compare with
`LC_ALL=C` - so it is one fix rather than a platform arm. The worklist below
still records `tests/fm-test-run.test.sh` as failing because that is what the
sweep measured; this is its cause, and it is fixed.

### A capability probe that lied about Python

```
$ bin/fm-test-run.sh --lane windows-4of4 --json shard4.json
Python was not found; run without arguments to install from the Microsoft Store...
rc=49
```

Windows ships Microsoft Store "app execution aliases" for `python` and `python3`.
They **resolve on PATH**, so `command -v python3` succeeds, but every invocation
prints that install prompt and exits 49. The probe reported a working interpreter
and then every call failed, so the run died rather than degrading - and `now_ms`
would have injected the prompt text into the run's own output.

`fm_test_python3` probes by actually executing the interpreter, caches the answer,
and also accepts `python`, often the only real interpreter on a Windows machine -
but only a Python 3 one, since the runner's own JSON payloads need `pathlib` and
`open(..., encoding=)`, and a bare `-c 'pass'` would let a Python 2 through.
Executing the interpreter is the only probe that answers the question being asked,
so this too is one fix rather than a platform arm.

The general lesson for the rest of this port: on Windows, `command -v` is not
evidence a tool works.
