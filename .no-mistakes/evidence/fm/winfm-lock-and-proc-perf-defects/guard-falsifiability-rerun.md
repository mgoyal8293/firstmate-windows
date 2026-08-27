# All three guards re-falsified at HEAD after the record was reframed

The fix instructions for this round required that no guard be weakened while the
record was restructured. Each guard is re-checked the only way that means anything:
the protection it exists for is removed from a throwaway export of HEAD, the owning
suite is run, and the guard must FAIL. The worktree itself is never mutated.

## Guard 1 - fm_proc_field stays silent on a pid that vanished mid-walk

Protection removed: the brace group around the scalar read in bin/fm-proc-lib.sh,
leaving a bare `value=$(< "$root/$pid/$field") || return 1`. Unlike `cat`, a bare
`< file` reports a missing file on the CALLER's stderr.

```console
$ sed -i 's/{ value=$(< ...); } 2>\/dev\/null || return 1/value=$(< ...) || return 1/' bin/fm-proc-lib.sh
$ bash tests/fm-windows-portability.test.sh
not ok - proc-field: a vanished pid must not leak to stderr, got 'bin/fm-proc-lib.sh: line 217: /tmp/fm-proc.BzbDDt/4243/pgid: No such file or directory'
suite rc=1
```

## Guard 2 - the memo asks the ancestry walk once per process

Protection removed: the memo read, the seam store and the success store deleted from
fm_session_ancestry_unavailable, leaving the original unmemoised body.

```console
$ bash tests/fm-session-token.test.sh
not ok - token: the memoised predicate must ask the walk once and answer identically every time, got 'walks=3 verdicts=000'
suite rc=1
```

The guard reports `walks=3`, which is the count the memo removes, and it reports the
verdicts alongside it so a saved walk is only credited when the answer is unchanged.

## Guard 3 - the memo is keyed on the platform seam, not on a bare computed flag

Protection removed: the seam comparison dropped from the memo's guard condition, so it
becomes a plain "already computed" flag.

```console
$ bash tests/fm-session-token.test.sh
not ok - token: SECURITY - the memo must be re-resolved when the platform seam changes; expected Windows=0 Linux=1 Windows=0, got '000'
suite rc=1
```

`000` is exactly the failure the seam key exists to prevent: the first Windows verdict
handed to the later Linux call, which would silently blind the suite's Windows arms -
the only regression coverage those arms get off Windows.

## Restored

With every protection in place, both suites pass at HEAD: 18/18 in
tests/fm-windows-portability.test.sh and 15/15 in tests/fm-session-token.test.sh, with
no `not ok` lines.
