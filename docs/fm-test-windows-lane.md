# Firstmate Windows CI lane

`.github/workflows/windows-ci.yml` runs the lanes.
`bin/fm-test-run.sh` owns the lane's membership and shard count.
This file records the measurements those two are built on.

Every number here was measured under Git for Windows MINGW64 bash (`MINGW64_NT-10.0-26200`, bash 5.2.37, git 2.50.1.windows.1, ShellCheck 0.11.0), from a frozen checkout, with `MSYS=winsymlinks:nativestrict`.

The repository has grown since, and the 2026-08 upstream intake grew it by more than a script or two: `portable-serial` is larger than the count these figures were measured at - [fm-test-portable-shards.md](fm-test-portable-shards.md) owns the live lane size - and the canonical lint set is now 331 shell files, counted with `CI=true bin/fm-lint.sh --list-files` at this head.
Every figure below is deliberately left as measured rather than restated to the live count; the lane has only gained scripts, so the growth widens the arithmetic below rather than undercutting any conclusion drawn from it.

## Why this lane is not the Linux lane with more shards

Git Bash pays 14-18x more per process than Linux, because every `fork` is an MSYS process-creation emulation rather than a kernel `fork`.
That multiplier does not fall evenly: it is worst on short scripts, where fixed process-startup cost dominates.

The consequence is arithmetic, not opinion.
`portable-serial` is a derived remainder of 117 scripts.
The 116 of them that carry a measured hint total 2539694 ms, so the lane is 42.33 minutes of Linux work.
Those weights are measured on green run [32159215212](https://github.com/mgoyal8293/firstmate-windows/actions/runs/32159215212) at head `580d64fb`, refreshed by the change that landed as df66e63; `docs/fm-test-portable-shards.md` owns them.
At 14-18x that is about **9.9 to 12.7 hours**, or 11.3 hours at 16x.

Sharding cannot fix this, because the longest single script sets a floor no shard count can lower.
`tests/fm-pr-check-security.test.sh` alone is 236511 ms on Linux - `docs/fm-test-portable-shards.md` already calls it "the floor for any shard count" - which is roughly **55 to 71 minutes** on Windows, 63 minutes at 16x, in one indivisible unit.

So the Windows lane carries a **measured subset**, sharded, rather than the whole suite.

## Membership rule

A script joins the lane when it exits 0 with no failed assertion on Git Bash.
A gate skip counts as green: that is the test declining to run, which it does on Linux too.
But a script that can *only* skip on this runner, because the tool it needs is not installed there, is left out - see the six green-by-skip scripts below.

The list is **enumerated, not derived**. The Linux serial lane is derived on purpose, so a newly added test lands in a required lane by default.
Here that same default would drop an unported test straight into a green gate and turn it red, which is what this fork is trying to get away from.
A new test joins this lane once it is measured green on Windows.

The coverage guard still proves the lane is real: every listed script exists, the shards are disjoint, and together they equal the list exactly.
It deliberately does **not** fold the Windows lane into the parallel + serial + Herdr partition of `tests/*.test.sh`, because the Windows lane is a subset overlay of that inventory rather than another part of it.

## Checkout must be LF

Git for Windows defaults `core.autocrlf=true`.
A CRLF working tree makes ShellCheck reject **every** shell file with SC1017 ("Literal carriage return"), so the lint gate fails on line 1 of everything and reports nothing about the code.

Measured, on the same tree:

| checkout | `bin/fm-lint.sh` |
|---|---|
| `core.autocrlf=true` (Git for Windows default) | fails - SC1017 on all 304 files |
| `core.autocrlf=false`, `core.eol=lf` | **passes, rc=0** |

The root `.gitattributes` owns this invariant with `* text=auto eol=lf`, so a plain `git clone` on Windows lands as LF whatever the operator's `core.autocrlf` says - CI, a local clone, and an upstream sync checkout all get the same tree.
That matters because this repo is published for other Windows users to clone, and a first run that emits SC1017 on all 304 files with no hint why is exactly the experience the port exists to prevent.
`assets/banner.png` is pinned `binary` in the same file rather than left to `text=auto` content sniffing; it is the only non-text tracked blob.

Both lanes *additionally* set `core.autocrlf=false` and `core.eol=lf` *before* `actions/checkout`.
That belt-and-braces pin stays: it keeps the lane honest even against a tree whose `.gitattributes` was changed.

Those pins plus the root `.gitattributes` are the whole of the invariant.
The lane verifies it and does not try to repair it: an `Assert the working tree is LF` step runs straight after checkout, and a tree it condemns is a tree the lane refuses to run on rather than one it rewrites.

A `Restore the working tree as LF` repair step existed here for three runs and was removed.
It was built on the premise that the runner's tree lands as CRLF, and that premise is false: `perl -0777` and `tr -dc '\r' | wc -c` both report **zero** CR bytes across all 306 tracked shell files on the runner.
Its own output is the clearest proof - it restored all 306 files byte-for-byte from the object store, then stripped CR from all 306 with `tr -d '\r'`, and the scan still reported 306.
A tree that has just had every CR byte removed cannot contain CR, so what the step measured was never the tree.

The pin is what does the work, measured against this branch on real Windows with Git for Windows' own default `core.autocrlf=true`:

| clone | `.gitattributes` | CR-carrying shell files | ShellCheck |
|---|---|---|---|
| shipped | present | **0** | clean |
| control | removed | **306** | `bin/fm-lint.sh` exits 2 with **32,273** SC1017 findings |

The control landing 306 CRLF files is what makes it a real control, and the 32,273 findings are the actual consequence of losing the pin: the lint gate fails on line 1 of everything and says nothing about the code.
It is *not* that scripts stop running - the shebang lands as `#!/usr/bin/env bash` plus a CR and still executes, because MSYS tolerates it.


### The CR detector itself was the bug

The measurement above - *all 306* tracked shell files carrying CR on a tree whose blobs are provably LF, with two independent conversion-free repairs unable to remove a single one - had one honest explanation, and it was not the tree.

MEASURED on windows-latest (runner image 20260810.198.2, git 2.55.0.windows.3, Git Bash), against a tree `od` and `perl` both show is LF:

| detector | clean tree | same tree + 1 CRLF file |
|---|---|---|
| `$(grep -rlU $'\r' bin tests --include='*.sh')` (inline) | **306** files | 307 files |
| `$(grep -rl '' bin tests --include='*.sh')` (empty pattern) | 306 files | 307 files |
| `cr=$'\r'; $(grep -rlU "$cr" ...)` (variable) | **0** files | **exactly that file** |
| `perl -0777 -ne 'print if /\r/'` | 0 files | exactly that file |
| `awk '/\r/'` | 0 files | **0 files** - blind to CR |

Spelled inline as `$'\r'` inside a command substitution, the CR pattern reaches `grep` **empty** under Git Bash, and an empty pattern matches every line of every file - which is why the count matched `grep -rl ''` exactly.
The lane was reporting a false positive no repair could ever clear, and it turned five Windows jobs red at a step that named the wrong cause three runs running.

So the CR byte now travels in a variable and is double-quoted at every use.
`awk` is not an alternative in either direction: on MSYS it reads through a text-mode conversion and cannot see CR at all, which is the fail-open direction.

A detector that cannot be trusted must also not be allowed to pass its verdict off as fact, so the step **calibrates** it first: a fixture of one CRLF file and one LF file, scanned in the shell that is about to scan the tree, which must come back naming exactly the CRLF one.
Anything else is a named `::error::` and the step refuses - it neither certifies the tree nor condemns it on the strength of an answer it cannot rely on.
`tests/fm-test-run.test.sh` holds both directions by putting a `grep` on `PATH` that reproduces each measured failure - CR-as-empty-pattern and CR-blind - and requiring the step to refuse by name and leave the tree under test untouched.

Once the detector has been calibrated, the assertion *verifies* the invariant and fails loudly if it does not hold.
It captures the scan and then judges it, rather than piping the recursive `grep` into `head`.
GitHub runs `shell: bash` steps with `-o pipefail`, so the pipeline form let `head` close the pipe, kill `grep` with SIGPIPE, and turn the guard's own non-zero status into a reported "working tree is LF" - on a CRLF tree.
A scan that does not complete is now an error too.
`tests/fm-test-run.test.sh` executes the step's real script against fixture trees to hold this: an LF tree, a small CRLF tree, a CRLF tree whose scan output is larger than a pipe buffer, and a tree it cannot finish scanning - which it must fail on rather than certify.

## The harness PATH

16 test files run the code under test with `BASE_PATH` as its only `PATH`, defaulting to `/usr/bin:/bin:/usr/sbin:/sbin` and overridable through `FM_TEST_BASE_PATH`.
On MINGW64 that default list holds almost none of the toolchain, so the code under test sees a machine with no `git` and the assertions fail for the harness's reasons rather than the code's:

```
git  -> /mingw64/bin/git
gh   -> /c/Program Files/GitHub CLI/gh
node -> /c/nvm4w/nodejs/node        (a developer machine; different on the runner)
jq   -> /c/Users/<user>/AppData/Local/.../jq
```

The lane builds `FM_TEST_BASE_PATH` from `command -v` at run time rather than from literal paths, so a runner-image change - a new Node directory, a relocated `gh` - cannot silently empty it again.

Every candidate directory is converted to POSIX form with `cygpath -u` before it enters that string, at the single `add_dir` chokepoint.
PATH is colon-separated, so a Windows-form entry splits at its drive-letter colon: `C:\npm\prefix` becomes a bare relative `C` plus a `\npm\prefix` that MSYS reads as root-relative and that does not exist.
`npm prefix -g` prints exactly that form, because npm resolves through native node - so the npm global bin, the entry that exists because `npm install -g` puts `tasks-axi` there, was the one entry the step failed to add.
`cygpath` is probed rather than assumed, and the step prints every entry and fails on a surviving single-letter or backslash entry, so this cannot regress silently.

The step then checks that the PATH it built can actually **reach** `git`, `node`, `gh`, `jq` and `perl` - the tools the suite asserts on - and **fails the job** if any is unreachable, naming the tools and printing the PATH so a runner-image move is diagnosable from the log alone.
The complete table prints first, so one run shows every casualty rather than stopping at the first.
This is the same trade the Linux lane makes with its hard-failing "Require tmux for e2e tests" step: collecting exactly the evidence needed to fail and then exiting 0 leaves the lane running against a machine the harness has misdescribed, and the resulting red shard blames the code for the harness's problem.

The earlier per-tool loop that prints `note: <tool> not on PATH` stays advisory, deliberately.
It asks a different question - does a candidate exist in the *ambient* PATH while the harness PATH is being assembled - over a wider list that includes `curl`, `openssl`, `tar` and `npx`, which are collected opportunistically and which no lane member asserts on.
Making that fatal would redden the lane for a tool nothing needs.
The reachability check is the single authority.

`FM_TEST_BASE_PATH` is published to `$GITHUB_ENV` only after both verdicts pass, so a PATH that failed validation is never handed to the lane.
The seed list is overridable through `FM_HARNESS_PATH_SEED` so `tests/fm-test-run.test.sh` can execute the step's real script against a controlled toolchain and prove the unreachable case fails; CI never sets it and gets the literal seed.

The `windows-behavior` job installs no ShellCheck: no lane member runs it, and `windows-lint` already proves that installer on the runner.
All 16 test files that build a restricted PATH honour `FM_TEST_BASE_PATH` as of `1baa477`, `tests/fm-remote-doctor.test.sh` among them, so nothing here needs an override added.
Where such a test still fails on Windows the cause is the `$TOOLS` prefix of `ln -sf` symlinks, not the base path - the same restricted-PATH MSYS-DLL pattern named under "Scripts excluded, and why" below.

## Lint lane

`bin/fm-lint.sh` was unrunnable on Windows before this work: `bin/fm-install-shellcheck.sh` only knew Linux and Darwin archives, and `bin/fm-lint.sh` exits 127 without ShellCheck.
Its default path then runs `bin/fm-lint-workflows.sh`, which needs actionlint for the same reason - so both pinned installers have to be present, or the gate exits 127 at the first linter it cannot find.

Both installers now have a pinned Windows arm.
Both Windows assets are zips holding a bare `.exe`, not `.tar.{xz,gz}` holding a versioned directory, and GNU tar cannot read zip - hence a separate extract arm rather than a different archive name.

Measured: **rc=0 in 5m35s** for 304 shell files plus 5 workflow files, with `fm-lint.sh` at its 2-worker cap.

### The `unzip` dependency is measured, not assumed

Those extract arms hard-require `unzip`, and both exit with `need unzip to extract` when it is missing - so `windows-lint` would die at its first install step.
Review flagged that dependency as unverified, correctly: the claim was asserted in a comment with no evidence behind it.
It is measured on both surfaces that matter.

| surface | `unzip` | commonly suggested substitutes |
|---|---|---|
| `windows-latest` runner | present - proven by the run below | - |
| Git for Windows (`MINGW64_NT-10.0-26200`) | `/usr/bin/unzip`, UnZip 6.00 | `bsdtar` **absent**, `7z` **absent** |

On the runner it is proven by the Windows CI run that first went green: run `32273090934`, job `Lint (Windows)` (`96133978008`).
`Install pinned ShellCheck` and `Install pinned actionlint` both succeeded, and the job log then records both binaries *executing* and reporting their own versions - `fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)` and `fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)`.
A `.exe` that ran is proof its zip was extracted, so that single run evidences the whole arm.

A fallback onto `bsdtar`, `7z`, or `python -m zipfile` was considered and **rejected**: it would trade a dependency measured present on both surfaces for ones measured absent on both, and add an untested path to a step that demonstrably works.
On this repo `python` availability is itself a probe this port had to fix, since Windows' Store alias resolves on PATH and exits 49 - so `python -m zipfile` is the weakest of the three.

Recorded here because a reviewer raised this as unverified on inputs that predated run `32273090934`; the evidence postdates the review rather than contradicting it.

## Lane composition

Measured by running all 98 candidate scripts serially from a frozen checkout with a 180-second per-script bound, plus dedicated longer runs for the three scripts that bound exceeded.

| | scripts |
|---|---:|
| candidates measured | 98 |
| measured green (exit 0, no failed assertion) | 45 |
| of those, green only because they gate-skip on the runner - dropped | 6 |
| **admitted to the lane by this campaign** | **39** |
| failing on Windows, excluded | 41 |
| still unresolved (hit the 180s bound, no failure seen) | 12 |

45 + 41 + 12 = 98.
One of the 41, `tests/fm-teardown.test.sh`, has its cause isolated below; the other 40 are recorded but not chased.

The lane now enumerates **42** members. Three were admitted after this campaign closed and were never among its 98 candidates.

`tests/fm-python-lib.test.sh` was measured on its own terms, green twice through the runner on the captain's Git Bash box at 11512 ms and 11129 ms, and the lower of those is its hint.
That is a floor measured on one developer machine rather than a figure from a CI runner, and GitHub's Windows runners are slower, so treat it the way the shard predictions below are treated: good enough to pack a shard with, not a promise about wall time.

### `fm-session-start-bound` and `fm-session-start-hook-nesting`, and why they belong here specifically

These two own the Windows session-start bound: the per-platform default, the nesting margin, and the harness ceiling the clamp is derived from.
They are on this lane for a reason stronger than "they pass there" - **their Linux runs are structurally unable to see a whole class of defect in them.**

The Windows arm's other coverage is `FM_PLATFORM_UNAME_OVERRIDE` on a POSIX runner, and an assertion written against *the ambient host* rather than against a second overridden arm is green on every Linux runner by construction, because on Linux the host and the override really do differ.
One such assertion shipped: the anti-vacuity guard in `tests/fm-session-start-bound.test.sh` compared the MINGW ceiling against the host's, which on MINGW64 are legitimately the same number, and it fired a false failure only there.
It was caught by a hand-run WSL-interop session rather than by CI.
Lane membership is what stops the next one needing a human on a Windows box.

Measured on `MINGW64_NT-10.0-26200`, msys 3.6.3-7674c51e.x86_64, bash 5.2.37(1)-release, 22 cores, run directly under Git Bash from a Windows-visible stage with a real git index:

| script | runs | green | hint (lowest green) |
|---|---|---|---:|
| `tests/fm-session-start-bound.test.sh` | 34795 / 36516 / 36743 ms | 3/3, 25 assertions each | **34795** |
| `tests/fm-session-start-hook-nesting.test.sh` | 13439 / 14080 / 18088 ms | 3/3, 9 assertions each | **13439** |

Same caveat as `fm-python-lib` above: a developer-box floor, not a runner promise.

**Two admission caveats belong with these, and neither is hypothetical.**

`fm-session-start-hook-nesting` **requires `jq`** and hard-fails without it rather than skipping - deliberately, because a skip there would hide an inverted nesting the suite exists to catch.
So its membership presupposes `jq` on the runner. It is present on `windows-latest` and was present on the box above (`jq-1.8.1`); if a future image drops it, this member fails the lane loudly instead of going quiet, which is the intended direction.

The same suite's parent-side fork-count assertion **skips** on this platform, and that is correct rather than a hole: there is no working `LD_PRELOAD` interposer under MSYS, so it prints `parent-side creation count: SKIPPED - the interposer could not be built or preloaded on this box` plus an explicit `UNMEASURED here and this assertion did not run` note.
Confirmed on the box above. The fork count stays a Linux measurement; adding the suite to this lane does not turn that skip into a lane failure, and it must not be "fixed" into one.

**Admitting `fm-session-start-bound` also required fixing two real Windows-only failures in it**, both in the end-to-end case that asserts each stage prints its header before its own output:

- On MSYS the session lock is owned by a per-session token rather than by process ancestry (see [`windows.md`](windows.md#how-the-session-lock-is-owned) "How the session lock is owned"), and this suite's fixture strips every harness marker on purpose - so the `LOCK` stage legitimately prints its read-only banner instead of an `acquired`/`held` line. The body pattern covered only the POSIX shapes. That is product behaviour, not a fixture defect, so the pattern now covers the read-only shape too.
- `skipped (read-only session)` is printed by **two** stages, `WAKE QUEUE` and `NETWORK CHECKS` (`bin/fm-session-start.sh:755` and `:916`), and the helper's contract is that a body pattern matches a line only its *own* stage emits. Searching globally, the network-checks pattern matched the wake-queue's line and reported the header as arriving 70 lines late. Both patterns are now qualified past the shared prefix. Only these two stages share it, so the collision class is closed rather than patched at the one call site that happened to fail.

Neither failure is reachable on Linux, because there the fixture acquires the lock and no stage prints a read-only line at all - which is the second half of why these two suites are worth the lane's budget.

### The six green-by-skip scripts are not lane members

`tests/fm-afk-inject-e2e.test.sh`, `tests/fm-backend-tmux-smoke.test.sh` and `tests/fm-tmux-agent-liveness.test.sh` exit early on `command -v tmux`; `tests/fm-backend-herdr-focus-flash-e2e.test.sh` on `command -v herdr`; `tests/fm-claude-stop-autoarm-live-e2e.test.sh` unless `FM_CLAUDE_LIVE_E2E=1`; `tests/fm-pi-primary-types.test.sh` on `command -v tsc`.
The job installs none of that, so on `windows-latest` those six can only skip.
They are dropped from the lane rather than carried, and neither tmux nor herdr is installed on the runner - not needing tmux is the point of this port.

`fm-pi-primary-types` is the one that was measured as a lane member first.
The behavior job installs only `tasks-axi`, never TypeScript, so the script exits at its `tsc` guard with a single `skip: tsc not found for Pi extension typecheck` line and **zero** `ok`/`not ok` assertions - a 1000 ms member that proves nothing about Windows.
It is out.
`tests/fm-calm-pi-extension.test.sh` looks similar and is *not* in this list: without the global `@earendil-works/pi-coding-agent` package it skips most of its cases, but still executes two real assertions that do not need it - Pi calm compatibility evidence never rejecting a newer-than-0.82.0 Pi while failing closed on a missing or malformed version, and missing Pi presentation class exports reaching the independent adapter degradation path.
It stays a member.

Dropping them loses no Windows coverage, because they never executed anything there.
What it buys is honesty about what the lane runs: a dropped member is visible in `list_windows`, whereas a member that silently skips every run is invisible, and there would be no signal if the runner image later lost a tool.
That is the same principle behind the Linux serial lane's "Require tmux for e2e tests" step (`.github/workflows/ci.yml`), which hard-fails so those scripts cannot quietly skip on a required gate.
The Windows lane reaches it from the other direction: no tool, no member.

Total lane cost: **62.9 min** of serial Git Bash work (3,772,746 ms of hints across 42 members).
The longest single script is `tests/fm-captain-hold-lifecycle.test.sh` at 860s, which is the floor no shard count can lower - so 4 shards is the useful maximum here, not 8 or 16.
Beyond 4 the floor binds and extra runners buy nothing.

That 860s is inherited rather than freshly measured, and it is provisional until the lane runs again.
It was measured on `tests/fm-decision-hold-lifecycle.test.sh`, the script upstream replaced with `tests/fm-captain-hold-lifecycle.test.sh` in the 2026-08 intake, and the hint in `bin/fm-test-run.sh` was carried across the rename rather than re-measured.
It is kept because it is a real measurement of a real predecessor and remains the best available packing basis: dropping it would move `unmeasured_windows` off zero and degrade shard balance without making anything more true.
`winfm-remeasure-captain-hold-windows` is the filed follow-up that will replace it with a Git Bash measurement of the current file.

The replacement is not a pure rename, and its size reads differently depending on how it is measured, so all three readings are recorded here with their methods rather than one being chosen:

- Blob to blob, diffing the two files' contents directly: 765 insertions, 714 deletions - about 65% of the new file's 1184 lines.
- Path to path across the intake, `git diff 3903bec..HEAD` over the two paths: 1184 insertions and 1133 deletions, which are exactly the new and old files' line counts, because git does not pair the paths as a rename at its default 50% similarity threshold. At `-M10%` it does pair them, reporting `similarity index 32%` and the same 765 / 714.
- Test functions: 16 to 17 counting `test_*()` definitions, or 32 to 34 counting definitions plus their invocations. Same file, two denominators.

The run recorded further down reports 16 ok, which is the predecessor's definition count rather than the current file's 17 - the clearest single sign that the figure predates the file it is now filed under.
The defect worth carrying forward is not the carried hint but how it stayed invisible: `--check-coverage` reports `unmeasured_windows=0` by checking that every listed name has a row in `windows_weight_hints`, so a name-keyed record survives a content change that invalidates it and a measured claim outlives its measurement with the guard still green.
For the same reason, read the totals above as pre-intake for part of the lane: 13 of the 42 members changed content in `3903bec..HEAD`, counted per member with `git diff --quiet`, so the 62.9 min total and this 860s floor describe the content those members carried before the intake.

| shard | scripts | predicted |
|---|---:|---:|
| `windows-1of4` | 7 | 943.8s (15.7 min) |
| `windows-2of4` | 8 | 943.0s (15.7 min) |
| `windows-3of4` | 13 | 943.0s (15.7 min) |
| `windows-4of4` | 14 | 943.0s (15.7 min) |
| imbalance | | 844 ms |

Those four rows are the packer's own output for the current hint list, not a hand estimate: admitting the two session-start suites (48,234 ms) added 12s to each shard and re-assigned scripts across all four, which is what the greedy packer does with any admission.

**`windows-4of4` was run end to end on Git Bash to check that sum against reality: rc=0, 14/14 scripts, 0 failures, 2 gate skips, wall 932s (15.5 min)** against 927s predicted - 0.5% out, which is what makes the other three shards' predicted figures trustworthy.
That run was taken before the six green-by-skip scripts were dropped, so it covered 14 scripts including the 2 that skipped; the same shard is now 13 scripts and 931s, and the drop moves no measured work.
Note that the packer is greedy over the hint list, so admitting a member re-assigns scripts across all four shards rather than only the one it lands in: `windows-4of4` no longer holds exactly the scripts that were run end to end.
What that run evidences is that a shard's hint sum predicts its wall time to within 0.5%, which is the claim the other three rows rest on, and that does not depend on which scripts made up the sum.

`timeout-minutes: 40` is a hang tripwire with roughly 2.5x margin over a healthy 15.7-minute shard, not the expected end of the lane.
GitHub's Windows runners are slower than the machine these numbers came from.

### The hints those shards are packed from

`windows_weight_hints` in `bin/fm-test-run.sh` holds the measured Git Bash duration for each of the 42 members - 3,772,746 ms in total - and a member with no entry there is packed at the flat `WINDOWS_DEFAULT_WEIGHT_MS`, 95205 ms, the per-script mean of the 39 members the campaign above admitted.

`--check-coverage` reports `unmeasured_windows=<n>` and names the members behind it, for the same reason it reports `unmeasured_serial` for the Linux serial lane: a member packed at the default is what unbalances a shard, and a Windows shard that overruns `timeout-minutes: 40` is cancelled with no verdict rather than merely slow.
On the shipped lane it is **0**, and it should stay there: this lane's admission rule already requires a member to be measured green on Windows, so an unhinted member is one admitted without the measurement its own rule demands.
Read that zero as narrowly as its serial counterpart in [fm-test-portable-shards.md](fm-test-portable-shards.md) - it says no member is packed at the default, not that the hints are still current.

Refresh from a green run of this lane, whose four shards each upload their own timing artifact:

```sh
gh run download <run-id> -R mgoyal8293/firstmate-windows --pattern 'fm-test-timing-windows-*' -D /tmp/fm-windows
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-windows/*.json | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

Green matters because a shard that failed part-way records a truncated duration for the script that failed; update the shard table above from the packer's own arithmetic afterwards.

## The fork-cost multiplier is not a single number

The 14-18x headline is a central tendency, not a constant: measured per script it spans roughly 10x to 24x.
The Linux column below is measured on this WSL2 development box by a full-suite run at head `c96c301`; the Git Bash column is this lane's own measured Windows weights.
That head is a pre-rebase tip of this branch, so a fresh clone will not resolve it, but all four scripts are byte-identical at the current head.
The two columns come from different machines, so read the ratios as the size of the fork-cost gap rather than a controlled single-machine comparison.

| script | Linux | Git Bash | ratio |
|---|---:|---:|---:|
| `fm-captain-hold-lifecycle` | 82.6s | 860s | 10.4x |
| `fm-crew-state` | 9.7s | 171s | 17.6x |
| `fm-brief` | 1.2s | 21s | 17.1x |
| `fm-composer-lib` | 5.0s | 119s | 23.8x |

The `fm-captain-hold-lifecycle` row carries the inherited figures described above: both of its columns were measured on the pre-rename `fm-decision-hold-lifecycle.test.sh`, and both are provisional pending `winfm-remeasure-captain-hold-windows`.

Note what this does **not** show: the ratio does not simply grow with a script's process work.
The longest member here, `fm-captain-hold-lifecycle` at 860s, has the *lowest* ratio of the four, and the shortest, `fm-brief`, sits mid-range.
An earlier revision of this table asserted the opposite on the strength of a 0.064s Linux figure for `fm-composer-lib`; that figure cannot be right, because the script runs 30 passing assertions and measures 5.0s, so the 1860x ratio it implied has been withdrawn.

This is why the lane's balance uses measured Windows durations rather than Linux hints scaled by a constant: the spread is real and it is not predictable from Linux duration, so a constant multiplier mis-sizes members in both directions.

## Scripts excluded, and why

41 scripts fail on Windows.
Only `fm-teardown` was in scope here; the other 40 fail for reasons this PR does not address, each outside the files this work owns.
They are recorded rather than silently dropped so the next port task has a worklist.
Two causes are worth naming because they are shared:

- **The restricted-PATH toolbin pattern.** Several tests symlink MSYS binaries into a private directory and then run the code under test with PATH restricted to it, which makes `msys-2.0.dll` unreachable (see the `fm-crew-state` isolation below).
  `tests/fm-lint.test.sh` and `tests/fm-subagent-pretool-check.test.sh` both use it.
- **Directory-mode assertions.** MSYS mounts `/tmp` `noacl`, so `mkdir -m 700` fails and `stat -c '%a'` always reports 755.
  Any check requiring a 700 round-trip refuses (see the `fm-teardown` isolation below).

12 more hit the 180-second measuring bound with no failed assertion, so they are unresolved rather than failing - candidates for the lane once measured properly.

## The three previously unisolated failures

### `fm-crew-state.test.sh` - a harness defect, not timing

`make_no_timeout_toolbin` symlinks tools into a private directory and callers run the code under test with PATH restricted to that directory.
On Windows an MSYS or MINGW binary locates its runtime DLL *through PATH*, Windows' last-resort DLL search location, so dropping the real bin directory makes `msys-2.0.dll` unreachable and the linked `bash` dies with `error while loading shared libraries` before running.

| toolbin | PATH | result |
|---|---|---|
| symlink to bash | full | runs |
| symlink to bash | toolbin only | **error while loading shared libraries** |
| symlink + `msys-2.0.dll` alongside | toolbin only | runs |
| exec wrapper | toolbin only | runs |

Fixed with the exec wrapper, not by copying DLLs: `git` is mingw64-linked and needs a different DLL set than the `/usr/bin` tools.
Before: 38 ok / 1 failed.
After: **rc=0, 49 ok** (the fix also unblocked 11 assertions the abort had hidden).

One wall-clock bound in that file then needed scaling, because the wrapper costs a second MSYS process per tool call.
`test_no_timeout_uses_perl_bound` bounds the perl-bounded `no-mistakes` lookup, measured around exactly the command the assertion wraps with the bound neutralised so the run completes:

| platform | run 1 | run 2 | run 3 | worst | bound | headroom |
|---|---:|---:|---:|---:|---:|---:|
| Linux | 1.246s | 1.258s | 1.264s | 1.264s | 5s | 4.0x |
| Git Bash | 3.429s | 4.219s | 4.605s | 4.605s | 25s | 5.4x |

The 5s bound failed on Windows by a hair rather than an order of magnitude: the assertion compares integer `$SECONDS`, so a true 4.605s reads as `elapsed=5` and `[ 5 -lt 5 ]` is false.
That was the whole failure. 25s is deliberately more than parity headroom because the Windows figure is far less stable - a 34% spread across three runs against 1.4% on Linux - and a GitHub Windows runner is slower than the machine these came from.
Scaled in a Windows `uname -s` arm so the Linux tripwire keeps its 5s sensitivity.
With the bound neutralised the script is **rc=0, 49 ok / 0 not ok** on Git Bash, so this bound was the single remaining Windows failure in the file and the exec-wrapper fix holds.

### `fm-wake-queue.test.sh` - fork cost, measured

`wait_for_exit` was instrumented to report observed latency for the watcher's start-poll-print-exit cycle:

| | first signal | second signal | bound (iterations) | that bound in wall clock | headroom |
|---|---:|---:|---:|---:|---:|
| Linux | 1.6s | 1.5s | 40 | 4.3s | 2.6x |
| Git Bash | 10.4s | 8.9s | 300 | 61s | 5.8x |

`WATCHER_EXIT_LIMIT` counts poll ITERATIONS, not seconds: `wait_for_exit` does one liveness check plus one fixed `sleep 0.1` per pass, timed against a live pid at 0.106s per iteration on Linux and 0.202s on Git Bash, linear at 40, 100 and 300.
So 40 iterations measures 4.24-4.31s on Linux, and the Windows arm's 300 measures 60.58s - a ~61s bound, not the 30s an earlier draft of this section claimed, and 5.8x headroom over the 10.4s worst case rather than ~2.5x.
The bound is therefore more generous than described, so the tripwire errs safe; it is less sensitive than parity, not closer to flaking.
Before the Windows arm, Git Bash ran the same 40 iterations, which is ~8.1s there rather than Linux's 4.3s, and the 10.4s cycle still overran it.
Scaled in a Windows arm so the Linux tripwire keeps its sensitivity.
Before: 4 ok / 1 failed.
After: **rc=0, 19 ok**.

One nuance, because the mechanism is the reverse of the obvious reading: the fork is not what dominates this loop.
Each iteration also pays a constant 0.1s sleep that does not scale with platform, and that fixed floor dominates the per-iteration total on both platforms.
The fork/`ps` overhead alone - the total minus that sleep - is 6ms on Linux against 102ms on Git Bash, a 17x ratio that sits squarely inside this lane's 14-18x fork-cost thesis, while the per-iteration total only rises 1.9x.
This loop obeys the thesis precisely and illustrates it poorly, so either figure quoted without saying which one it is misleads in one direction or the other.

### `fm-teardown.test.sh` - isolated, fix belongs elsewhere

Re-measured on current HEAD first: still fails identically (9 ok / 1 failed), so the merged mode and `lsof` fixes did not cover it.
The cause is neither:

```
error: herdr session presentation lock could not be resolved for task-x1
```

`fm_backend_herdr_presentation_lock_namespace_valid` in `bin/backends/herdr.sh` requires `stat -c '%a'` to report 700 on a `mkdir -m 700` directory.
On MSYS:

```
mkdir -m 700          -> "cannot change permissions ... Permission denied"
stat -c %a            -> 755, before and after an explicit chmod 700
id -u == stat -c %u   -> the owner check passes; only the mode fails
```

The fix is a capability probe in that one function, plus a note that the mode assertion is not a security property on a `noacl` mount.
That file is outside the files this work owns, so it is flagged rather than changed.

### `fm-captain-hold-lifecycle.test.sh` - confirmed fork cost

Not a failure.
Given a bound longer than the scout's 400s it passes: **rc=0, 16 ok, 0 failed, in 860s** against 82.6s on Linux - a 10.4x multiplier.
It is in the lane, and it is the script that sets the shard floor.
That run measured the script under its pre-rename name, `tests/fm-decision-hold-lifecycle.test.sh`, whose 16 test definitions are the 16 ok above, so both figures are inherited by the current file rather than measured on it and are provisional pending `winfm-remeasure-captain-hold-windows`.

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

Each of these was still passing assertions when the bound cut it, so none is known-broken.
`fm-captain-hold-lifecycle` started in this group and turned out to be pure fork cost once given 860s, so the others deserve the same treatment before anyone calls them failures.
That 860s is the inherited pre-rename measurement noted above, provisional pending `winfm-remeasure-captain-hold-windows`.

## Two things that stopped the runner itself on Windows

Neither is about a test.
Both stopped `bin/fm-test-run.sh` before any test ran, and both were present at HEAD with no Windows lane involved.

### `--check-coverage` exited 1 on a locale mismatch

```
comm: file 2 is not in sorted order
comm: input is not in sorted order
```

Every `comm` input in `run_coverage_guard` - and in the runner's own `tests/fm-test-run.test.sh` - is produced by `LC_ALL=C sort`, but `comm` validates its inputs' order using the **ambient** locale.
Git Bash defaults to `en_US.UTF-8`, whose collation differs from C, so `comm` rejected correctly-sorted input and the guard failed for the locale's reasons rather than the inventory's.
This is also why `tests/fm-test-run.test.sh` failed on Windows.

Fixed by matching the comparison locale to the sort locale, in the guard and in that test.
That is correct on every platform - sort with `LC_ALL=C`, compare with `LC_ALL=C` - so it is one fix rather than a platform arm.
The worklist below still records `tests/fm-test-run.test.sh` as failing because that is what the sweep measured; this is its cause, and it is fixed.

### A capability probe that lied about Python

```
$ bin/fm-test-run.sh --lane windows-4of4 --json shard4.json
Python was not found; run without arguments to install from the Microsoft Store...
rc=49
```

Windows ships Microsoft Store "app execution aliases" for `python` and `python3`.
They **resolve on PATH**, so `command -v python3` succeeds, but every invocation prints that install prompt and exits 49.
The probe reported a working interpreter and then every call failed, so the run died rather than degrading - and `now_ms` would have injected the prompt text into the run's own output.

`fm_python3` in [`../bin/fm-python-lib.sh`](../bin/fm-python-lib.sh) probes by actually executing the interpreter, caches the answer, and also accepts `python`, often the only real interpreter on a Windows machine - but only a Python 3 one, since the runner's own JSON payloads need `pathlib` and `open(..., encoding=)`, and a bare `-c 'pass'` would let a Python 2 through.
It also accepts the multi-word `py -3`, which is why the resolved answer is the argv array `FM_PYTHON3_CMD` rather than a single word.
Executing the interpreter is the only probe that answers the question being asked, so this too is one fix rather than a platform arm.
The runner first carried a private copy of that probe; the copy is gone, and every caller in this repo now reads the one owner.
[`verification/windows-python-probe.md`](verification/windows-python-probe.md) records the measurements and the falsifiability demonstration.

The general lesson for the rest of this port: on Windows, `command -v` is not evidence a tool works.

## Three differences a local Git Bash could not show

Every measurement above was taken on a developer Windows machine, and all three of the following passed there and failed on the GitHub runner.
None is about a test being wrong on Windows in general: each is one environment fact that the local shell happened not to have.

### `%TEMP%` on the runner is a short (8.3) path, and `/proc` does not use it

Git for Windows mounts `/tmp` with `usertemp`, i.e. at whatever `%TEMP%` names.
GitHub's runners spell that with a short component, and MSYS renders `/proc/<pid>/cwd` in its own canonical spelling of the process's Windows cwd - which then comes back through the `cygdrive` mount instead:

```
mount:      C:/Users/<user>/AppData/Local/Temp/FMCI-L~1 on /tmp (usertemp)
fixture:    /tmp/fm-cwd.wdwSxf/wt/sub
/proc says: /c/Users/<user>/AppData/Local/Temp/fmci-longname-probe/fm-cwd.wdwSxf/wt/sub
```

`fm_proc_pids_with_cwd_under` compared those two strings raw, so it reported **nobody** under a directory a live process was sitting in - which its own contract says teardown reads as a proven-empty scan.
Reproduced off-runner by launching a fresh Git Bash with `TEMP` set to a short-name directory; a shell whose `%TEMP%` needs no short name never sees it.

Fixed in `fm_proc_cwd_prefixes`: `cygpath -m -l` resolves the caller's directory through the mount table *and* expands short components, and `cygpath -u` converts that back into the spelling `/proc` reports.
Resolved once per scan, not per pid, so the scan still costs a fixed two forks.
The caller's own spelling is still tried first and still wins, and with no `cygpath` the strict compare remains the only verdict - this can widen a match, never invent one.

### `LANG` is unset on the runner, so `printf '\u2580'` is not a glyph

Bash converts `\uXXXX` through the ambient locale's charset.
With no `LANG` and no `LC_*`, that charset cannot represent U+2580, and bash emits the six characters of the escape instead:

```
$ printf '\u2580\u2580' | od -An -tx1     # runner, LANG unset
 5c 75 32 35 38 30 5c 75 32 35 38 30
$ LC_ALL=C.UTF-8 printf '\u2580\u2580' | od -An -tx1
 e2 96 80 e2 96 80
```

`tests/fm-composer-lib.test.sh` built its herdr half-block rule rows that way, so on the runner it asked `fm_composer_row_has_edge` about a row that was not a rule row at all.
The lib's patterns are literal bytes and were never the problem.
Fixed by writing the fixture's glyphs as literal UTF-8, which is locale-independent in both directions - and which is also what makes that file's `LC_ALL=C` half mean something.

### `RUNNER_TEMP` holds backslashes, and GNU coreutils escapes for that

```
fm-install-shellcheck.sh: checksum mismatch for shellcheck-v0.11.0.zip
  (expected 8a4e35ab...e740e, got \8a4e35ab...e740e)
```

The digest was right; the *line* was escaped.
GNU coreutils prefixes its checksum line with a literal `\` whenever the filename holds a backslash or newline, and the installers digest by filename under `$RUNNER_TEMP`, which is `D:\a\_temp` on a Windows runner.
So the pinned Windows download was rejected for how its path was spelled, and the lint lane died at its first step.

Both installers now digest through **stdin**, which removes the filename from the output entirely.
That is correct on every platform rather than a Windows arm, and `tests/fm-lint.test.sh` and `tests/fm-lint-workflows.test.sh` pin it on any host by pointing `RUNNER_TEMP` at a directory whose name really does hold a backslash.

### The restricted-PATH DLL pattern, and the exec wrapper that fixes it at every site

`tests/fm-windows-portability.test.sh` also builds a deliberately restricted PATH - one directory, holding `readlink` and no `cygpath` - and reached it through a symlink, which is the `$TOOLS` symlink pattern named under "Scripts excluded, and why" above.
`PATH=$dir readlink` exits 127 there, because an MSYS binary finds `msys-2.0.dll` through PATH, and a directory carrying only the link is Windows' last-resort DLL search location with none of those DLLs in it.
The fix is the same everywhere: an exec wrapper, which keeps the real binary running from its own directory where its DLLs sit, so no fixture ever has to know which DLLs a tool needs.

The wrapper is spelled out per file, enumerated here so a site added later has to join a visible list rather than rot against a bare total:

- `tests/fm-crew-state.test.sh` - 1 site, `make_no_timeout_toolbin`, the worked example for the excluded scripts that still carry the symlink form.
- `tests/fm-windows-portability.test.sh` - 1 site, `stage_tool_for_restricted_path`.
- `tests/fm-test-run.test.sh` - 1 site, the coreutils staging inside `lfharness_bin`, added by this change's own review rounds.

Hoisting the three copies into one shared helper is deliberately deferred, not forgotten: `tests/fm-lint.test.sh` and `tests/fm-subagent-pretool-check.test.sh` still carry the unfixed symlink form, so the consolidation waits until every call site exists and can move at once instead of half-migrating.
