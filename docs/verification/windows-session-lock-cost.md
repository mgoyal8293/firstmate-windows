# Windows session-lock and process-table read cost

Repeatable evidence for what a session-lock ownership check costs under MSYS, and what the fork removal in [`../../bin/fm-proc-lib.sh`](../../bin/fm-proc-lib.sh) and the memo in [`../../bin/fm-session-token-lib.sh`](../../bin/fm-session-token-lib.sh) actually removed.
The ownership design itself is owned by [`../windows.md`](../windows.md) "How the session lock is owned", and the subprocess counts behind the same class of defect by [`session-start-fork-profile.md`](session-start-fork-profile.md).

Date: 2026-08-27.
Comparison base: `main` at `4c5336c`, called v0 below; this branch's head is v1.
Windows host: Windows 11 Pro 10.0.26200, Git for Windows MINGW64_NT-10.0-26200, bash 5.2.37(1)-release.
Measured from WSL2 by invoking Git Bash by full path (`/mnt/c/Program Files/Git/bin/bash.exe`), because this box sets `interop.appendWindowsPath=false`.

## What this page claims, and how strongly

Two kinds of number are recorded here and they do not carry equal weight.

The **fork and process-table read counts** are the durable claim.
A count is exact, it is not load-dependent, and it reproduces on any POSIX host, so nothing about it depends on getting time on the Windows box.
Those counts lead this page.

The **millisecond timings** are illustration, not evidence.
Two runs of the same harnesses on the same Windows host, taken on different days under different load, differ by up to a factor of two in absolute value while their ratios hold.
No timing on this page should be quoted as a fixed cost.

## The counts, which are the durable claim

Measured on a POSIX host (WSL2 Linux), v0 against v1, with the harnesses quoted below.

**One `fm_proc_field` scalar read goes from 3 child processes to 0.**
The three were the two `$(fm_proc_root)` command substitutions, one in `fm_proc_field` itself and one in `fm_proc_msys_fields_readable`, plus the `cat` fork and exec.

```console
=== AS SHIPPED (4c5336c) ===
calibrate: $(< file)                         children: 0 (expect 0)
calibrate: $(cat file)                       children: 1 (expect 1)
calibrate: external /bin/true                children: 1 (expect 1)
--- one fm_proc_field call, by field ---
fm_proc_field 4242 ppid  direct              children: 3
fm_proc_field 4242 pgid  direct              children: 3
fm_proc_field 4242 sid  direct               children: 3
fm_proc_field 4242 comm  direct              children: 3
fm_proc_field 4242 args  direct              children: 3
=== FIXED (HEAD) ===
calibrate: $(< file)                         children: 0 (expect 0)
calibrate: $(cat file)                       children: 1 (expect 1)
calibrate: external /bin/true                children: 1 (expect 1)
--- one fm_proc_field call, by field ---
fm_proc_field 4242 ppid  direct              children: 0
fm_proc_field 4242 pgid  direct              children: 0
fm_proc_field 4242 sid  direct               children: 0
fm_proc_field 4242 comm  direct              children: 0
fm_proc_field 4242 args  direct              children: 1
```

The four scalar fields reach 0.
`args` keeps one child because it pipes through `tr` to turn NUL separators into spaces, which is not a scalar read and is untouched by this change.

**Three ownership checks in one process go from 3 ancestry walks to 1, with every verdict unchanged.**

```console
=== AS SHIPPED (4c5336c) ===
walk unresolved, no token              walks: 3 verdicts: not-owned not-owned not-owned
walk RESOLVES, non-owning token        walks: 3 verdicts: owned owned owned
=== FIXED (HEAD) ===
walk unresolved, no token              walks: 1 verdicts: not-owned not-owned not-owned
walk RESOLVES, non-owning token        walks: 1 verdicts: owned owned owned
```

**One real `bin/fm-lock.sh` run drops from 36 to 24 process-table reads, with the operator-facing message and exit status byte-identical.**
This is the actual CLI, not a library call in a harness: invoked under the Windows platform seam, against a throwaway home, and detached with `setsid --fork` so the tree reparents to init and the ancestry walk is in the state a real Windows invocation puts it in.

```console
=== AS SHIPPED (4c5336c) ===
--- acquire, NO session token in the environment ---
exit=1 reads=36
  | error: no firstmate session token in this environment, so this session cannot prove it owns this home - on Windows ownership is a per-session token, never process ancestry, because a native harness never appears in MSYS's /proc. Only Claude Code exports one today (CLAUDE_CODE_SESSION_ID); under any other harness a Windows firstmate stays read-only - run firstmate from Claude Code, or continue read-only (docs/windows.md 'How the session lock is owned')
--- acquire, WITH a Claude session token ---
exit=0 reads=24
  | lock acquired: session token
state/.lock          -> [3449241]
state/.lock.session  -> [6f0d2a5e-winfm-demo-0001]
--- status ---
exit=0 reads=0
  | lock: held by this session's token

=== FIXED (HEAD) ===
--- acquire, NO session token in the environment ---
exit=1 reads=24
  | error: no firstmate session token in this environment, so this session cannot prove it owns this home - on Windows ownership is a per-session token, never process ancestry, because a native harness never appears in MSYS's /proc. Only Claude Code exports one today (CLAUDE_CODE_SESSION_ID); under any other harness a Windows firstmate stays read-only - run firstmate from Claude Code, or continue read-only (docs/windows.md 'How the session lock is owned')
--- acquire, WITH a Claude session token ---
exit=0 reads=24
  | lock acquired: session token
state/.lock          -> [3449568]
state/.lock.session  -> [6f0d2a5e-winfm-demo-0001]
--- status ---
exit=0 reads=0
  | lock: held by this session's token
```

The refusal run is where the 36 to 24 drop lands, because that is the path that asks the predicate twice.
With a Claude session token present both variants print `lock acquired: session token`, write a plain numeric pid to `state/.lock`, and report `lock: held by this session's token` on the following `status`.
Normalising only the per-run pid and the read count, the two transcripts diff clean, so the operator-facing output and the exit status are byte-identical across the change.

These are counts and not timings.
They hold on any host, because a count is not load-dependent and does not change with how busy the machine is.
That is why they are the primary evidence on this page and the Windows timings below are illustration.

### The exact counting harnesses, as run

Quoted rather than described, on the same terms as the timing harnesses further down.
The quotation preserves these scripts verbatim except for whitespace: function-body indentation was not preserved, and neither were the column-padding double spaces inside the `printf` format strings.
Bash semantics are unaffected and the scripts run as quoted.

`count-forks.sh` counts child processes with a SIGCHLD trap.
The counter is **calibrated against three known shapes before use**, inside the same run that does the measuring, so a miscounting trap is caught rather than believed: `$(< file)` must report 0, `$(cat file)` must report 1, and an external `/bin/true` must report 1.
All three calibration lines are in the output above.

```sh
#!/usr/bin/env bash
# Count the child processes ONE fm_proc_field scalar read creates, against
# whichever bin/ is passed as $1. A count is not load-dependent, so this
# reproduces on any POSIX host and does not need the Windows box.
set -u
BIN=$1

# The counter: bash runs a SIGCHLD trap once per reaped child when job control
# is off and `set -o monitor` is unset, so CHILDREN counts forks the shell made.
CHILDREN=0
trap 'CHILDREN=$((CHILDREN+1))' SIGCHLD

count() { # <label> <command...>
local label=$1; shift
CHILDREN=0
"$@" >/dev/null 2>&1 || true
printf '%-44s children: %d\n' "$label" "$CHILDREN"
}

# CALIBRATION against three known shapes, run BEFORE the measurement, so a
# miscounting trap is caught rather than believed.
CAL=$(mktemp); echo hello > "$CAL"
CHILDREN=0; v=$(< "$CAL"); printf '%-44s children: %d (expect 0)\n' 'calibrate: $(< file)' "$CHILDREN"
CHILDREN=0; v=$(cat "$CAL"); printf '%-44s children: %d (expect 1)\n' 'calibrate: $(cat file)' "$CHILDREN"
CHILDREN=0; /bin/true; printf '%-44s children: %d (expect 1)\n' 'calibrate: external /bin/true' "$CHILDREN"
rm -f "$CAL"; : "$v"

# A fake MSYS /proc, so the scalar-file branch is the one measured on Linux too.
ROOT=$(mktemp -d); PID=4242
mkdir -p "$ROOT/$PID"
printf '1\n' > "$ROOT/$PID/ppid"
printf '%s\n' "$PID" > "$ROOT/$PID/pgid"
printf '%s\n' "$PID" > "$ROOT/$PID/sid"
printf '/usr/bin/bash\n' > "$ROOT/$PID/exename"
printf 'bash\0-c\0:\0' > "$ROOT/$PID/cmdline"
export FM_PROC_ROOT_OVERRIDE=$ROOT
. "$BIN/fm-proc-lib.sh"

echo "--- one fm_proc_field call, by field ---"
for f in ppid pgid sid comm args; do
count "fm_proc_field $PID $f  direct" fm_proc_field "$PID" "$f"
done
rm -rf "$ROOT"
```

`count-walks.sh` counts ancestry walks, and prints the verdict each check reached alongside the count, so a walk saved is only credited when the verdict it would have produced is unchanged.
It wraps `fm_harness_ancestry_pids` after sourcing rather than editing either library to be measured.
One case runs per process, because the memo lives for the life of a process and two cases in one shell would hand the second a warm memo.

```sh
#!/usr/bin/env bash
# Count the ancestry walks THREE fm_session_lock_owned_by_self calls make in ONE
# process, against whichever bin/ is passed as $1, and print each verdict, so a
# walk saved is only credited when the verdict it would have produced is unchanged.
#
# One case per process, invoked as: count-walks.sh <bin> <unresolved|resolves>.
# The memo lives for the life of a process, so running two cases in one shell
# would hand the second a warm memo and report walks: 0 for it - an artifact of
# the harness, not of the change.
set -u
BIN=$1 CASE=$2
export FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200
. "$BIN/fm-session-lock-lib.sh"

# Count the walk by wrapping the walk itself, after sourcing, so neither library
# is edited to be measured.
WALKS=0
eval "fm_harness_ancestry_pids_real() $(declare -f fm_harness_ancestry_pids | tail -n +2)"
fm_harness_ancestry_pids() { WALKS=$((WALKS+1)); fm_harness_ancestry_pids_real "$@"; }

STATE=$(mktemp -d)
case "$CASE" in
unresolved)
# The walk does NOT resolve: no harness ancestor, no token.
LABEL="walk unresolved, no token"
echo 12345 > "$STATE/.lock"
;;
resolves)
# THE CASE THE DEVIATION TURNS ON - Windows where the ancestry walk DOES
# resolve, with a NON-OWNING token present. Reordering to consult the token
# first would answer "not owned" here; the memo must still answer what the
# walk says, which is "owned".
LABEL="walk RESOLVES, non-owning token"
fm_harness_ancestry_pids_real() { printf '%s\n' "$$"; }
echo "$$" > "$STATE/.lock"
printf 'some-other-session\n' > "$(fm_session_token_path "$STATE")"
export CLAUDE_CODE_SESSION_ID=this-session-not-the-owner
;;
esac

V=''
for i in 1 2 3; do
if fm_session_lock_owned_by_self "$STATE" >/dev/null 2>&1; then V="$V owned"; else V="$V not-owned"; fi
done
printf '%-38s walks: %d verdicts:%s\n' "$LABEL" "$WALKS" "$V"
rm -rf "$STATE"
```

`count-ps.sh` puts a counting `ps` shim ahead of the real one on `PATH` and then runs the real CLI through it.
The shim records the call and delegates, so the run under test is unmodified and still gets real answers.

```sh
#!/usr/bin/env bash
# Count the process-table reads ONE REAL bin/fm-lock.sh run makes, against
# whichever bin/ is passed as $1. Not a library call in a harness: the actual
# CLI, under the Windows platform seam, against a throwaway home.
set -u
BIN=$1
HOMEDIR=$(mktemp -d)
SHIM=$(mktemp -d)
COUNT=$SHIM/ps.count
: > "$COUNT"

# The shim: a `ps` earlier on PATH than the real one, which records the call and
# then delegates, so the run under test is unmodified and still gets real answers.
REAL_PS=$(command -v ps)
cat > "$SHIM/ps" <<SHIMEOF
#!/usr/bin/env bash
echo "\$*" >> "$COUNT"
exec "$REAL_PS" "\$@"
SHIMEOF
chmod +x "$SHIM/ps"

# `setsid --fork`, not bare `setsid`: inside a command substitution the shell is
# not a process-group leader, so setsid execs WITHOUT forking, the run keeps this
# harness's ppid, and the ancestry walk climbs into the measuring session and
# resolves. --fork reparents the run to init, which is the state a real Windows
# invocation is in and the state under which the walk cannot answer.
run() { # <label> <args...>
: > "$COUNT"
local rc
setsid --fork env PATH="$SHIM:$PATH" \
FM_PLATFORM_UNAME_OVERRIDE=MINGW64_NT-10.0-26200 \
FM_ROOT_OVERRIDE="$HOMEDIR" \
bash -c 'CLI=$0; OUT=$1; shift; bash "$CLI" "$@" >"$OUT.out" 2>&1; echo $? >"$OUT.rc"' \
"$BIN/fm-lock.sh" "$SHIM/run" "$@" </dev/null
while [ ! -s "$SHIM/run.rc" ]; do sleep 0.05; done
rc=$(cat "$SHIM/run.rc"); rm -f "$SHIM/run.rc"
printf 'exit=%s reads=%s\n' "$rc" "$(wc -l < "$COUNT")"
sed 's/^/  | /' "$SHIM/run.out"
}

echo "--- acquire, NO session token in the environment ---"
unset CLAUDE_CODE_SESSION_ID
run
echo "--- acquire, WITH a Claude session token ---"
export CLAUDE_CODE_SESSION_ID=6f0d2a5e-winfm-demo-0001
run
printf 'state/.lock          -> [%s]\n' "$(cat "$HOMEDIR/state/.lock" 2>/dev/null)"
printf 'state/.lock.session  -> [%s]\n' "$(head -1 "$HOMEDIR/state/.lock.session" 2>/dev/null)"
echo "--- status ---"
run status
rm -rf "$HOMEDIR" "$SHIM"
```

## Decision preservation, which is why this is a memo and not a reordering

The accepted deviation from the brief turns on one case, and that case was driven rather than argued.

The brief asserted that reordering `fm_session_lock_owned_by_self` to consult the session token before walking the ancestry would remove nearly all of the cost.
It would, and it would also change what the check DECIDES on Windows in the case where the ancestry walk does resolve.
So the case to drive is exactly that one: the Windows seam, an ancestry walk that resolves, and a non-owning token present in the environment.
There, ancestry says the lock is ours and the token says it is not, so the two orderings disagree by construction.

Both variants answer `owned` three times:

```console
=== AS SHIPPED (4c5336c) ===
walk RESOLVES, non-owning token        walks: 3 verdicts: owned owned owned
=== FIXED (HEAD) ===
walk RESOLVES, non-owning token        walks: 1 verdicts: owned owned owned
```

That is the executable evidence for choosing memoisation.
A reordering would have answered `not-owned` here and handed the fleet lock a different verdict; the memo cannot, because a process's own ancestry is fixed for its lifetime and the memo only ever replays the answer the walk already gave.
The saving is real in the same run that shows the decision unchanged: the walk count still falls from 3 to 1.

## Why the timings are measured on Windows and not on Linux
The whole effect is the per-fork penalty: a subprocess costs about 1 ms on Linux and about 42 ms under MSYS, so a Linux timing run would show nothing and a fork *count* would not show how much of a turn is spent.
Both libraries were copied to a staging directory on a local NTFS volume and sourced from Git Bash there, so no `\\wsl.localhost` path is on the measured path.

## How the numbers are taken

Two shapes, because they answer different questions and one of them flatters the change.

- **In-process loop.** `date +%s%N` around N repeated calls in one already-sourced shell, divided by N.
  This is the honest figure for the process-table read, and a *dishonest* one for the memoised predicate: after the first call in a loop every later one is a memo hit, so the mean understates the cold call a fresh process actually makes.
- **Two checks, fresh process.** A new `bash -c` per iteration that sources `bin/fm-session-lock-lib.sh` and makes two `fm_session_lock_owned_by_self` calls.
  Nothing is carried between iterations, so the memo is exercised once cold and once warm.
  This is the shape of the stale-lock recovery path in `bin/fm-claude-stop-autoarm.sh`, not of a steady-state turn: its second ownership check sits inside `if [ "$RECOVER_SESSION_LOCK" -eq 1 ]` and is reached only when the first check has failed and the recorded lock pid is dead.

The `.lock` fixture holds a pid that is not this process's ancestor, so the check runs to a verdict rather than short-circuiting.

## The exact timing harnesses, as run

These are the exact scripts as run, quoted rather than described from memory.
The quotation preserves them verbatim except for whitespace: function-body indentation was not preserved, and neither were the column-padding double spaces inside the `printf` and `awk` format strings.
Bash semantics are unaffected and the scripts run as quoted, which the second Windows run below proves - its harnesses were extracted from this page's own fenced blocks and run as landed.
Two of their own labels carry framing this page retracts.
`measure.sh` prints "(per turn)" over the lock-ownership block and `measure-turn.sh` says "per turn" in its header comment and its output label, where the two-check shape is the autoarm recovery path rather than a steady-state turn.
`measure.sh` also prints "must be identical across v0/v1" over the contract block, where only `comm`, `ppid` and the four return-code and silence cases were identical.
Those strings are left unedited because editing them would make the quotation inexact, and the corrected sections of this page are authoritative over the scripts' own labels.
These scripts produced the recorded numbers on the recorded date, and a re-run yields fresh numbers rather than these.

`measure.sh`, which produces the component-costs table and the contract block:

```sh
#!/usr/bin/env bash
# Measure the two audited costs against whichever bin/ is passed as $1.
set -u
BIN=$1
. "$BIN/fm-session-lock-lib.sh"

ms_per() { # <iters> <total_ns>
awk -v n="$1" -v t="$2" 'BEGIN{printf "%.2f", (t/n)/1000000}'
}

bench() { # <label> <iters> <command...>
local label=$1 n=$2; shift 2
local i s e
s=$(date +%s%N)
for ((i=0;i<n;i++)); do "$@" >/dev/null 2>&1 || true; done
e=$(date +%s%N)
printf '%-46s %8s ms/call (n=%s)\n' "$label" "$(ms_per "$n" "$((e-s))")" "$n"
}

echo "uname: $(uname -s) bash: $BASH_VERSION"
echo "--- section 2.1: fm_proc_field ---"
bench "fm_proc_field \$\$ ppid" 30 fm_proc_field "$$" ppid
bench "fm_proc_field \$\$ comm" 30 fm_proc_field "$$" comm
echo "--- section 2.2: lock ownership (per turn) ---"
bench "fm_harness_ancestry_pids" 15 fm_harness_ancestry_pids
bench "fm_session_ancestry_unavailable" 15 fm_session_ancestry_unavailable
STATE=$(mktemp -d); echo 12345 > "$STATE/.lock"
bench "fm_session_lock_owned_by_self" 15 fm_session_lock_owned_by_self "$STATE"
rm -rf "$STATE"
echo "--- contract outputs (must be identical across v0/v1) ---"
printf 'ppid=[%s] rc=%s\n' "$(fm_proc_field "$$" ppid 2>/dev/null)" "$?"
printf 'comm=[%s] rc=%s\n' "$(fm_proc_field "$$" comm 2>/dev/null)" "$?"
printf 'args=[%s]\n' "$(fm_proc_field "$$" args 2>/dev/null)"
printf 'pgid=[%s] sid=[%s]\n' "$(fm_proc_field "$$" pgid 2>/dev/null)" "$(fm_proc_field "$$" sid 2>/dev/null)"
out=$(fm_proc_field 999999 ppid 2>&1); printf 'dead-pid rc=%s out=[%s]\n' "$?" "$out"
out=$(fm_proc_field '' ppid 2>&1); printf 'empty-pid rc=%s out=[%s]\n' "$?" "$out"
out=$(fm_proc_field abc ppid 2>&1); printf 'nonnum-pid rc=%s out=[%s]\n' "$?" "$out"
out=$(fm_proc_field "$$" lstart 2>&1); printf 'bad-field rc=%s out=[%s]\n' "$?" "$out"
fm_session_ancestry_unavailable; printf 'ancestry_unavailable rc=%s\n' "$?"
```

Invoked as, once per variant, with the staging directory on a local NTFS volume and Git Bash addressed by full path because this box sets `interop.appendWindowsPath=false`:

```console
"/mnt/c/Program Files/Git/bin/bash.exe" -c 'cd /d/AI/winfm-lockperf && ./measure.sh /d/AI/winfm-lockperf/v0/bin'
```

`measure-turn.sh`, which produces the two-check row and the through-`$( )` row:

```sh
#!/usr/bin/env bash
# The real per-turn shape: ONE fresh process that sources the library and makes
# the two ownership checks bin/fm-claude-stop-autoarm.sh makes per turn.
set -u
BIN=$1; N=${2:-10}
STATE=$(mktemp -d); echo 12345 > "$STATE/.lock"
s=$(date +%s%N)
for ((i=0;i<N;i++)); do
bash -c '
. "$1/fm-session-lock-lib.sh"
fm_session_lock_owned_by_self "$2" >/dev/null 2>&1 || true
fm_session_lock_owned_by_self "$2" >/dev/null 2>&1 || true
' _ "$BIN" "$STATE"
done
e=$(date +%s%N)
awk -v n="$N" -v t="$((e-s))" 'BEGIN{printf "per-turn (fresh process, source + 2 owner checks) %8.1f ms (n=%d)\n",(t/n)/1000000,n}'
rm -rf "$STATE"

# And fm_proc_field the way real call sites use it: through a command substitution.
. "$BIN/fm-proc-lib.sh"
s=$(date +%s%N); for ((i=0;i<30;i++)); do v=$(fm_proc_field "$$" ppid); done; e=$(date +%s%N)
awk -v t="$((e-s))" 'BEGIN{printf "fm_proc_field via $( ) as call sites use it %8.2f ms/call (n=30)\n",(t/30)/1000000}'
: "$v"
```

`measure-src.sh`, which produces the source-only row:

```sh
#!/usr/bin/env bash
set -u
BIN=$1; N=10
s=$(date +%s%N)
for ((i=0;i<N;i++)); do bash -c '. "$1/fm-session-lock-lib.sh"' _ "$BIN"; done
e=$(date +%s%N)
awk -v n="$N" -v t="$((e-s))" 'BEGIN{printf "fresh process + source only (zero checks) %8.1f ms (n=%d)\n",(t/n)/1000000,n}'
```

## Two-check cost, measured

Two runs, on the same host by the same method, on different days under different load.

| Shape | Run 1 as shipped | Run 1 fixed | Run 2 as shipped | Run 2 fixed |
|---|---|---|---|---|
| Fresh process, source + two ownership checks (n=10) | **3,268.6 ms** | **1,437.7 ms** | **2,747.1 ms** | **1,002.3 ms** |
| Fresh process, source only, zero checks (n=10) | 272.0 ms | 308.5 ms | 152.0 ms | 154.8 ms |

Subtracting the sourcing cost, the two checks themselves fall from about 2,997 ms to about 1,129 ms in run 1, and from about 2,595 ms to about 848 ms in run 2.
That is a 2.7x reduction in run 1 and a 3.1x reduction in run 2.
The sourcing line is quoted to keep that subtraction honest; the difference between its two columns is run-to-run noise on this host, not an effect of the change, and it is 36 ms in run 1 and 2.8 ms in run 2.
This is the two-check scenario, which is the autoarm stale-lock recovery branch and `current_session_still_ours` in `bin/fm-turnend-guard-cursor.sh`.
Those are the callers that ask `fm_session_lock_owned_by_self` more than once inside one process, which is the shape measured here.
`bin/fm-lock.sh` is a repeat-PREDICATE path and not an instance of this shape: it never calls `fm_session_lock_owned_by_self`, it calls `fm_session_ancestry_unavailable` twice, and no measured figure on this page applies to it.
It is NOT what a steady-state turn pays, and an earlier revision of this page quoted run 1's 1.87 s difference as a per-turn saving.
That claim is retracted here; the corrected per-turn range is two sections below.

## The second run, and what host load does to these numbers

Run 2 was taken on the same Windows host by the same method, with v0 still `main` at `4c5336c` and v1 this branch's head.
The `bin/` code is byte-identical to the commit run 1 measured: every change since has been comment-only.
The harnesses were extracted from this page's own fenced blocks and run exactly as landed, which is also what proves the quotation executes.

**Every as-shipped row in run 2 landed at 0.52 to 0.84 of its run 1 absolute value.**
Run 1 competed with this repo's own test suites and other concurrent lanes; run 2 was on a quiet host.
The fixed column moves further still in places, down to about 0.41 of run 1, because its absolutes are small enough that fixed overheads dominate them.

**The ratios are what reproduced.**

| Call | Run 1 ratio | Run 2 ratio |
|---|---|---|
| `fm_proc_field $$ ppid`, called directly | 87x | 93x |
| `fm_proc_field $$ comm`, called directly | 99x | 90x |
| `fm_proc_field $$ ppid`, through `$( )` | 4.9x | 8.1x |
| `fm_harness_ancestry_pids` | 1.9x | 1.8x |
| `fm_session_lock_owned_by_self` | 8.5x | 8.0x |

Neither run is the correct one and neither supersedes the other.
Both are recorded because the pair is the finding: the absolutes are load-dependent and the direction and rough magnitude are not.
This is why the counts at the top of this page, and not these timings, are what this change is claimed on.

## Steady-state per-turn cost, derived from the rows above

A steady-state turn makes exactly ONE ownership check, because the second check in `bin/fm-claude-stop-autoarm.sh` is gated on the first one having failed.
No one-check run was performed, so the figures here are derived from the measured rows above rather than measured directly, and none of them may be quoted as a measurement.

As shipped there is no memo, so the two checks cost their two-check total independently and one check is half of it.
Fixed, the memo reduces the second check's ancestry walk to a variable read, so the two-check total is close to the cost of the one cold check.

| Derived from | As shipped, one check | Fixed, one check | Removed |
|---|---|---|---|
| Run 1 | about 1,498 ms | about 1,129 ms | about 370 ms |
| Run 2 | about 1,298 ms | about 848 ms | about 450 ms |

The steady-state saving is therefore **roughly 370 to 450 ms**, and all of it is the `fm_proc_field` fork removal, because on a one-check turn the memo has no second call to save.
The width of that range is host load, not measurement error: the two runs bracket a busy host and a quiet one, and the underlying counts are identical in both.
No single flat figure is given anywhere on this page, because the two runs do not support one.

The fixed one-check figure is an over-estimate of a single check rather than an exact one, in both runs.
`fm_session_lock_owned_by_self` reads `state/.lock` through a `cat` command substitution before it ever reaches the memoised predicate, so the second check still pays a fork of its own that the memo cannot remove.
The residual pushes the true fixed one-check figure down, which makes the 370 to 450 ms range a conservative floor on the steady-state saving rather than a midpoint.
No more precise figure is given, because no one-check run was measured.
The memo's own justification is call count on the multi-check paths, not this per-turn figure.

## Component costs, in-process loop

| Call | Run 1 as shipped | Run 1 fixed | Run 1 ratio | Run 2 as shipped | Run 2 fixed | Run 2 ratio |
|---|---|---|---|---|---|---|
| `fm_proc_field $$ ppid`, called directly (n=30) | 116.32 ms | 1.34 ms | 87x | 71.69 ms | 0.77 ms | 93x |
| `fm_proc_field $$ ppid`, through `$( )` as call sites use it (n=30) | 136.57 ms | 27.83 ms | 4.9x | 93.09 ms | 11.46 ms | 8.1x |
| `fm_proc_field $$ comm`, called directly (n=30) | 136.92 ms | 1.38 ms | 99x | 70.68 ms | 0.79 ms | 90x |
| `fm_harness_ancestry_pids` (n=15) | 746.70 ms | 392.73 ms | 1.9x | 406.63 ms | 228.15 ms | 1.8x |
| `fm_session_ancestry_unavailable` (n=15, loop-amortised) | 695.08 ms | 47.39 ms | see note | 404.84 ms | 19.61 ms | see note |
| `fm_session_lock_owned_by_self` (n=15, loop-amortised) | 830.65 ms | 98.12 ms | 8.5x | 467.97 ms | 58.16 ms | 8.0x |

Both amortised rows are loop artifacts and must not be quoted as per-turn savings; the derived per-turn range above is the claim.

The two `fm_proc_field` rows differ by about one MSYS fork, which is the caller's own command substitution and is outside this function's reach.
That row is why the direct 87x to 93x is not the improvement a caller sees: the through-`$( )` row is, at 4.9x in run 1 and 8.1x in run 2.
Run 1's 4.9x is the figure that corroborates the 4.5x the audit measured on its own prototype, and run 2 moved the furthest of any ratio here, which is itself part of why the counts and not these figures carry the claim.

## Contract preserved

Both variants were driven through the same inputs in the same run, and the contract-bearing facts were identical between them, so the timing change carries no behaviour change.
Identical across the two runs: `comm`, `ppid`, and all four return-code and silence cases.
`pgid`, `sid` and the `args` line are per-invocation values and are quoted for output SHAPE only, never for equality.
A different process necessarily has a different pgid and sid, and `args` carries the staging path of whichever variant was being measured, so those three lines differed between the runs by nature.
The block below is the fixed run:

```console
ppid=[1] rc=0
comm=[/usr/bin/bash] rc=0
args=[bash ./measure.sh .../bin]
pgid=[2305] sid=[2305]
dead-pid rc=1 out=[]
empty-pid rc=1 out=[]
nonnum-pid rc=1 out=[]
bad-field rc=1 out=[]
ancestry_unavailable rc=0
```

`out=[]` is captured with `2>&1`, so it also proves the vanished-pid and bad-input cases stay silent rather than only returning non-zero.
That silence is what `tests/fm-windows-portability.test.sh` pins portably, because `$(< file)` reports a missing file on the caller's stderr where `cat 2>/dev/null` absorbed it.

## What was deliberately left on the table

`fm_harness_ancestry_pids` is still the slowest thing on this page, at 392.73 ms in run 1 and 228.15 ms in run 2, because `fm_harness_process_matches` pipes to `grep -qE` twice per ancestry hop, which a bash `[[ =~ ]]` would answer without a subprocess.
It is not done here: that function is the classifier deciding what counts as a harness process, so changing its matching engine is a behaviour risk in the lock path rather than a timing change, and it needs its own task with its own per-harness evidence.
