# Scheduled drift check, run as CI runs it

The three transcripts below come from executing the real step bodies parsed out of
`.github/workflows/upstream-sync.yml` (`python3 -c 'yaml.safe_load(...)'`, then each
step's `run:` script verbatim) against a fresh clone of `mgoyal8293/firstmate-windows`
that fetches the real upstream `kunchenguid/firstmate`.
Committer identity is stripped the way a bare `actions/checkout` leaves it:
`env -u HOME -u GIT_AUTHOR_* -u GIT_COMMITTER_* GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=<user.useConfigOnly=true>`.
`TESTS=none` only, because a conflicted merge never reaches the test phase and so the
test selection cannot change the verdict; `Install pinned ShellCheck` is skipped for the
same reason.
Step order comes from the workflow itself: checkout, add upstream remote, **give the
scratch merge a committer identity**, install ShellCheck, dry-run, publish, upload, fail.

## 1. Before this change (base commit 54a8125, workflow with no identity step)

This is the nightly failure being fixed: no verdict at all, and no clue why.

```
== job: Upstream merge dry run  (before-fix-base-commit) ==
### step: Add upstream remote
### step: Give the scratch merge a committer identity  (NOT PRESENT in this job)
### step: Dry-run the upstream merge

upstream:  upstream/main (1231b6ae7fd4)
base:      origin/main (54a81254aa26)
new upstream commits not in base: 29
port commits not in upstream:     10

BLOCKED: the merge could not be attempted (no conflicted paths reported). Inspect with --keep.

dry-run step exit code: 3
job result: FAILED - "upstream is not cleanly takeable right now; see the report above"
```

## 2. Target commit's script, identity step removed from the job

Same clone, same script, the one new workflow step taken back out.
The script still refuses and still exits 3, and now the report names the cause instead
of discarding it.

```
### step: Give the scratch merge a committer identity  (NOT PRESENT in this job)
### step: Dry-run the upstream merge

upstream:  upstream/main (1231b6ae7fd4)
base:      origin/main (54a81254aa26)
new upstream commits not in base: 29
port commits not in upstream:     10

BLOCKED: the merge could not be attempted (no conflicted paths reported). Inspect with --keep.
git reported:
  Committer identity unknown

  *** Please tell me who you are.

  Run

    git config --global user.email "you@example.com"
    git config --global user.name "Your Name"

  to set your account's default identity.
  Omit --global to set the identity only in this repository.

  fatal: no email was given and auto-detection is disabled

dry-run step exit code: 3
job result: FAILED - "upstream is not cleanly takeable right now; see the report above"
```

## 3. Target commit, full job including the identity step

The identity step is the only difference from transcript 2, and the check now reaches a
real verdict against real upstream.

```
== job: Upstream merge dry run  (after-fix-with-identity) ==
### step: Add upstream remote
### step: Give the scratch merge a committer identity
  local identity now: firstmate upstream freshness <firstmate-upstream-freshness@users.noreply.github.com>
### step: Dry-run the upstream merge

upstream:  upstream/main (1231b6ae7fd4)
base:      origin/main (54a81254aa26)
new upstream commits not in base: 29
port commits not in upstream:     10

CONFLICTS: 29 upstream commit(s) do not merge cleanly. Resolve by hand in a real branch; conflicted paths:
  - .github/workflows/ci.yml
  - bin/fm-supervise-daemon.sh
  - bin/fm-test-run.sh
  - docs/documentation-audiences.json
  - docs/fm-test-portable-shards.md
  - tests/fm-pending-reply.test.sh
  - tests/fm-pi-watch-extension.test.sh

dry-run step exit code: 1
job result: FAILED - "upstream is not cleanly takeable right now; see the report above"
```

`CONFLICTS` (exit 1) is the intended, legitimately red outcome: 29 upstream commits and
the same 7 conflicting paths the change describes, reported plainly rather than made
green.
Reconciling them is out of scope here.

The per-scenario `GITHUB_STEP_SUMMARY` markdown (what a reviewer opens on the run page),
the uploaded `upstream-sync.txt`, and the machine-readable `upstream-sync.json` are
alongside this file.
