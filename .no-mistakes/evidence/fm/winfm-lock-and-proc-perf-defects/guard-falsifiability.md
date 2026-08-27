# Every new guard shown failing with its protection removed

Each mutation is applied to the working tree, the owning test script is run, and the
mutation is reverted. The worktree is clean afterwards, verified with git status.

## Guard 1 - fm_proc_field stays silent on a pid that vanished mid-walk

Protection: the brace group around `{ value=$(< file); } 2>/dev/null` in bin/fm-proc-lib.sh.
Unlike `cat`, a bare `< file` reports a missing file on the CALLER's stderr, and a pid
vanishing mid-walk is the ordinary case for every ancestry walk and reaper here.

Mutation - drop the brace group from both scalar reads:

```diff
-        { value=$(< "$root/$pid/exename"); } 2>/dev/null || return 1
+        value=$(< "$root/$pid/exename") || return 1
-        { value=$(< "$root/$pid/$field"); } 2>/dev/null || return 1
+        value=$(< "$root/$pid/$field") || return 1
```

FAILS with the protection removed:

```console
not ok - proc-field: a vanished pid must not leak to stderr, got '/home/johns/.no-mistakes/worktrees/72b1fa50e799/01M1269KKYRXJB1T9FG3G0S9JT/bin/fm-proc-lib.sh: line 217: /tmp/fm-proc.rBcEBu/4243/pgid: No such file or directory'
```

PASSES restored:

```console
ok - fm_proc_field: a scalar file that vanished mid-walk returns 1 in silence
```

## Guard 2 - the memo asks the ancestry walk once per process

Protection: the memo in fm_session_ancestry_unavailable in bin/fm-session-token-lib.sh.

Mutation - remove the memo entirely, returning the predicate to its shipped body:

```diff
-  if [ -n "$FM_SESSION_ANCESTRY_MEMO_RC" ] \
-    && [ "$FM_SESSION_ANCESTRY_MEMO_SEAM" = "${FM_PROC_UNAME_S:-}" ]; then
-    return "$FM_SESSION_ANCESTRY_MEMO_RC"
-  fi
-  FM_SESSION_ANCESTRY_MEMO_SEAM=${FM_PROC_UNAME_S:-}
-  FM_SESSION_ANCESTRY_MEMO_RC=1
-  FM_SESSION_ANCESTRY_MEMO_RC=0
```

FAILS with the protection removed - the walk count is the failure message:

```console
not ok - token: the memoised predicate must ask the walk once and answer identically every time, got 'walks=3 verdicts=000'
```

## Guard 3 - the memo is re-resolved when the platform seam changes

Protection: keying the memo on FM_PROC_UNAME_S rather than on a bare "already computed" flag.
Without it, a sticky verdict would silently blind the suite's Windows arms, which are the
only regression coverage those arms get off Windows.

Mutation - keep the memo, drop the seam key:

```diff
-  if [ -n "$FM_SESSION_ANCESTRY_MEMO_RC" ] \
-    && [ "$FM_SESSION_ANCESTRY_MEMO_SEAM" = "${FM_PROC_UNAME_S:-}" ]; then
+  if [ -n "$FM_SESSION_ANCESTRY_MEMO_RC" ]; then
```

FAILS with the protection removed - the Windows verdict is handed to the later Linux call:

```console
ok - fm_session_ancestry_unavailable: asks the ancestry walk once per process and never changes its answer
not ok - token: SECURITY - the memo must be re-resolved when the platform seam changes; expected Windows=0 Linux=1 Windows=0, got '000'
```

Both guards PASS restored:

```console
ok - fm_session_ancestry_unavailable: asks the ancestry walk once per process and never changes its answer
ok - fm_session_ancestry_unavailable: the memo is re-resolved when the platform seam changes, in both directions
```

Worktree after all three mutations were reverted:

```console
$ git status --porcelain
(no output - clean)
```
