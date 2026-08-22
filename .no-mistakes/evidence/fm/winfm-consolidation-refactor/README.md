# Test evidence: winfm consolidation refactor (pure move of six Windows mechanisms)

Every artifact here is a BEFORE/AFTER pair: the same harness run against the base
commit `f129f8d` and the target commit `4dc0b13`. The claim under test is that the
move changes no behaviour, so an identical transcript is the evidence.

| Mechanism moved | Artifact | Result |
| --- | --- | --- |
| 1+2 session token and its acquisition branch | `lock-cli-matrix.{before,after}.txt` | all 7 `fm-lock.sh status` verdicts and all 6 acquisition outcomes byte-identical |
| 2 claim-lock re-check ordering | `claim-lock-recheck.txt` | refused before and after; deleting the re-check makes the same race ACQUIRE |
| 3 file-mode capability probe | `file-mode-fail-closed.txt` | production verdicts unchanged; the added guard is falsifiable |
| 4 /proc lsof substitute | `lock-staleness.{before,after}.txt` | staleness proof identical, and discriminating |
| 5 path helpers and GOTMPDIR | `path-helpers.{before,after}.txt`, `gotmpdir.{before,after}.txt` | identical |
| 6 symlink/skills preflight | `bootstrap-preflight.{before,after}.txt` | identical PLATFORM diagnostics from a real `fm-bootstrap.sh` run |

Also here:

- `friction-measurement.txt` - the audit's own metric, reproduced (it matches the
  audit report exactly at its snapshot commit), before/after, per commit, and per
  owner file.
- `changed-mapping.txt` - `fm-test-run.sh --changed` refused on this branch; fixed
  by giving the previously untested preflight detectors colocated coverage.
- `preflight-coverage.txt` - that new coverage, plus the two mutations that make it fail.
- `targeted-suite.log` - the 15 targeted suites.

Each `*.sh` here is the harness that produced the matching `.txt`, re-runnable as
`<harness>.sh <fm-root>`.
