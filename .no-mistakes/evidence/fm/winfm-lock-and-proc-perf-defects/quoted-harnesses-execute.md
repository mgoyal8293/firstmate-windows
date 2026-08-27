# The record's quoted harnesses were extracted from the page and executed

The reframed docs/verification/windows-session-lock-cost.md leads with fork and
process-table read COUNTS and claims two things about them: that the counts are the
durable, platform-independent evidence, and that the harnesses quoted in the page's
own fenced blocks "run as quoted" despite the whitespace normalisation the page
discloses.

Both claims are checked here by machine-extracting the three ```sh blocks straight
out of the tracked Markdown, writing them to disk unmodified, and running them
against v0 (main at 4c5336c) and v1 (this branch's head). No harness was retyped or
reconstructed from memory.

Host: WSL2 Linux, bash 5.2.21. A count is not load-dependent, which is the whole
reason the page rests on counts rather than on the Windows milliseconds.

Extraction: 6 fenced sh blocks found in the page, 3 identified as the counting
harnesses and written out verbatim as count-forks.sh, count-walks.sh, count-ps.sh.
All three executed without a single edit.

## 1. One fm_proc_field scalar read: 3 child processes -> 0

The SIGCHLD counter calibrates itself against three known shapes before it measures,
inside the same run, so a miscounting trap is caught rather than believed.

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

All three calibration lines land on their expected values, so the counter is trusted
for the rows beneath it. The four scalar fields reach 0. `args` keeps its one child
because it pipes through `tr` to turn NUL separators into spaces, which is not a
scalar read and is untouched.

## 2. Three ownership checks in one process: 3 ancestry walks -> 1, verdicts unchanged

The second row is the case the accepted deviation turns on: Windows, an ancestry walk
that DOES resolve, and a non-owning token in the environment. Reordering to consult
the token first would answer `not-owned` there. Both variants answer `owned` three
times, so the memo demonstrably cannot make the decision a reordering would have made.

```console
=== AS SHIPPED (4c5336c) ===
walk unresolved, no token              walks: 3 verdicts: not-owned not-owned not-owned
walk RESOLVES, non-owning token        walks: 3 verdicts: owned owned owned
=== FIXED (HEAD) ===
walk unresolved, no token              walks: 1 verdicts: not-owned not-owned not-owned
walk RESOLVES, non-owning token        walks: 1 verdicts: owned owned owned
```

## 3. One real bin/fm-lock.sh run: 36 -> 24 process-table reads

Not a library call in a harness. The actual CLI, under the Windows platform seam,
against a throwaway home, detached with `setsid --fork` so the tree reparents to init
and the ancestry walk is in the state a real Windows invocation puts it in. A counting
`ps` shim sits ahead of the real one on PATH and delegates, so the run under test is
unmodified and still gets real answers.

```console
=== AS SHIPPED (4c5336c) ===
--- acquire, NO session token in the environment ---
exit=1 reads=36
  | error: no firstmate session token in this environment, so this session cannot prove it owns this home - on Windows ownership is a per-session token, never process ancestry, because a native harness never appears in MSYS's /proc. Only Claude Code exports one today (CLAUDE_CODE_SESSION_ID); under any other harness a Windows firstmate stays read-only - run firstmate from Claude Code, or continue read-only (docs/windows.md 'How the session lock is owned')
--- acquire, WITH a Claude session token ---
exit=0 reads=24
  | lock acquired: session token
state/.lock          -> [3503289]
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
state/.lock          -> [3503616]
state/.lock.session  -> [6f0d2a5e-winfm-demo-0001]
--- status ---
exit=0 reads=0
  | lock: held by this session's token
```

The refusal run is where the 36 -> 24 drop lands, because that is the path asking the
predicate twice. With a Claude session token present both variants print
`lock acquired: session token`, write a plain numeric pid to `state/.lock`, and report
`lock: held by this session's token` on the following `status`.

Normalising only the per-run pid and the read count, the two operator-facing
transcripts diff clean:

```console
$ diff -u v0.normalised v1.normalised
OPERATOR-FACING TRANSCRIPTS: BYTE-IDENTICAL (pid and read count normalised)
```

## Every recorded count reproduced exactly

Each console block above is character-for-character what the tracked record quotes,
apart from the per-run pid in the `state/.lock` line. The page's leading claim and the
"as run" heading both hold.

## The timings still apply to this bin/ code

The record says run 1's Windows timings were taken on `01d468f` and that every bin/
change since has been comment-only, so the figures still describe the shipped code:

```console
$ git diff 01d468f..HEAD -- bin/ | grep '^[+-]' | grep -v '^[+-][[:space:]]*#'
(no non-comment line changes)
```
