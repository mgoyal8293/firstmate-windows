#!/usr/bin/env bash
# fm-upstream-sync.sh - report whether this Windows port can take upstream's
# latest, WITHOUT ever landing it.
#
# Usage:
#   fm-upstream-sync.sh [options]
#
# Options:
#   --upstream <remote>   upstream remote name          (default: upstream)
#   --upstream-ref <ref>  upstream ref to take          (default: <remote>/HEAD, else <remote>/main)
#   --base <ref>          the ref being merged INTO     (default: origin/main)
#   --tests <mode>        changed | all | none | <lane> (default: changed)
#   --json <path>         also write a machine-readable report
#   --keep                keep the scratch worktree for inspection
#   --no-fetch            skip the fetch (use the refs already on disk)
#   -h, --help            print this header
#
# Exit status: 0 the merge is clean AND the selected tests passed; 1 conflicts;
# 2 clean merge but tests failed; 3 the run could not be performed.
#
# Requires a committer identity (git user.name and user.email): the dry run's
# `git merge --no-ff --no-commit` records a merge state and git refuses without
# one. A run that has none is reported BLOCKED, quoting git's own reason under
# `git reported:`, rather than papered over - a bare CI checkout is exactly the
# environment that produces it.
#
# WHY THIS NEVER MERGES
#
# This is a fork of an actively developed upstream, and its Windows delta is
# expressed as `case "$(uname -s)" in MINGW*|MSYS*)` arms added inside existing
# functions precisely so git can merge upstream's changes around them. A merge
# that git resolves textually can still be semantically wrong here: upstream
# changing a function this port has added an arm to produces a CLEAN merge whose
# Windows arm no longer runs. An auto-merge would land that silently and it would
# surface at the worst possible moment - the next time someone needed the fleet
# lock on Windows. So this reports and stops; a human takes the merge.
#
# Everything happens in a throwaway worktree on a scratch branch. The checkout
# the operator is sitting in is never touched, and nothing is ever pushed.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

UPSTREAM_REMOTE=upstream
UPSTREAM_REF=
BASE_REF=origin/main
TESTS=changed
JSON_OUT=
KEEP=0
FETCH=1

die() { echo "error: $*" >&2; exit 3; }

usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//;$d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --upstream) UPSTREAM_REMOTE=${2-}; shift 2 || die "--upstream needs a value" ;;
    --upstream-ref) UPSTREAM_REF=${2-}; shift 2 || die "--upstream-ref needs a value" ;;
    --base) BASE_REF=${2-}; shift 2 || die "--base needs a value" ;;
    --tests) TESTS=${2-}; shift 2 || die "--tests needs a value" ;;
    --json) JSON_OUT=${2-}; shift 2 || die "--json needs a value" ;;
    --keep) KEEP=1; shift ;;
    --no-fetch) FETCH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$UPSTREAM_REMOTE" ] || die "--upstream cannot be empty"
[ -n "$BASE_REF" ] || die "--base cannot be empty"

git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "$ROOT is not a git worktree"
git -C "$ROOT" remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 \
  || die "no remote named '$UPSTREAM_REMOTE'; add it with: git -C $ROOT remote add $UPSTREAM_REMOTE <url>"

if [ "$FETCH" -eq 1 ]; then
  git -C "$ROOT" fetch --quiet --prune "$UPSTREAM_REMOTE" \
    || die "could not fetch $UPSTREAM_REMOTE"
  # The base is normally a tracking ref too; a stale one would compare against
  # yesterday's port and report conflicts that no longer exist.
  case "$BASE_REF" in
    */*) git -C "$ROOT" fetch --quiet --prune "${BASE_REF%%/*}" >/dev/null 2>&1 || true ;;
  esac
fi

if [ -z "$UPSTREAM_REF" ]; then
  if git -C "$ROOT" rev-parse --verify --quiet "refs/remotes/$UPSTREAM_REMOTE/HEAD" >/dev/null; then
    UPSTREAM_REF=$(git -C "$ROOT" symbolic-ref --short "refs/remotes/$UPSTREAM_REMOTE/HEAD" 2>/dev/null) \
      || UPSTREAM_REF="$UPSTREAM_REMOTE/main"
  else
    UPSTREAM_REF="$UPSTREAM_REMOTE/main"
  fi
fi

UPSTREAM_SHA=$(git -C "$ROOT" rev-parse --verify --quiet "$UPSTREAM_REF^{commit}") \
  || die "cannot resolve upstream ref '$UPSTREAM_REF'"
BASE_SHA=$(git -C "$ROOT" rev-parse --verify --quiet "$BASE_REF^{commit}") \
  || die "cannot resolve base ref '$BASE_REF'"

AHEAD=$(git -C "$ROOT" rev-list --count "$BASE_SHA..$UPSTREAM_SHA" 2>/dev/null || echo 0)
BEHIND=$(git -C "$ROOT" rev-list --count "$UPSTREAM_SHA..$BASE_SHA" 2>/dev/null || echo 0)

STATUS=
CONFLICTS=
MERGE_ERROR=
TEST_RESULT=skipped
SUMMARY=

WORKTREE=
SCRATCH_BRANCH="fm/upstream-sync-scratch-$$"
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  [ -n "$WORKTREE" ] || return 0
  if [ "$KEEP" -eq 1 ]; then
    echo "scratch worktree kept at: $WORKTREE (branch $SCRATCH_BRANCH)" >&2
    return 0
  fi
  git -C "$ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  git -C "$ROOT" branch -D "$SCRATCH_BRANCH" >/dev/null 2>&1 || true
}
trap cleanup EXIT

emit_json() {
  [ -n "$JSON_OUT" ] || return 0
  local conflicts_json='[]' f first=1
  if [ -n "$CONFLICTS" ]; then
    conflicts_json='['
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ "$first" -eq 1 ] || conflicts_json="$conflicts_json,"
      first=0
      conflicts_json="$conflicts_json\"$(printf '%s' "$f" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
    done <<EOF
$CONFLICTS
EOF
    conflicts_json="$conflicts_json]"
  fi
  cat > "$JSON_OUT" <<EOF
{
  "status": "$STATUS",
  "upstream_ref": "$UPSTREAM_REF",
  "upstream_sha": "$UPSTREAM_SHA",
  "base_ref": "$BASE_REF",
  "base_sha": "$BASE_SHA",
  "commits_ahead": $AHEAD,
  "commits_behind": $BEHIND,
  "tests": "$TEST_RESULT",
  "conflicts": $conflicts_json
}
EOF
}

report() {
  echo
  echo "upstream:  $UPSTREAM_REF ($(printf '%.12s' "$UPSTREAM_SHA"))"
  echo "base:      $BASE_REF ($(printf '%.12s' "$BASE_SHA"))"
  echo "new upstream commits not in base: $AHEAD"
  echo "port commits not in upstream:     $BEHIND"
  echo
  echo "$SUMMARY"
  emit_json
}

if [ "$AHEAD" -eq 0 ]; then
  STATUS=current
  SUMMARY="current: $BASE_REF already contains every commit on $UPSTREAM_REF; nothing to take."
  report
  exit 0
fi

WORKTREE=$(mktemp -d "${TMPDIR:-/tmp}/fm-upstream-sync.XXXXXX") || die "cannot create a scratch directory"
rmdir "$WORKTREE"
git -C "$ROOT" worktree add --quiet --detach "$WORKTREE" "$BASE_SHA" \
  || die "cannot create the scratch worktree"
git -C "$WORKTREE" checkout --quiet -b "$SCRATCH_BRANCH" \
  || die "cannot create the scratch branch"

# --no-ff and --no-commit: the result is inspected, never kept. A merge that
# fast-forwards would hide the fact that nothing was reconciled.
MERGE_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-upstream-sync-merge.XXXXXX") || \
  die "cannot create a scratch file"
if git -C "$WORKTREE" merge --no-ff --no-commit --quiet "$UPSTREAM_SHA" \
  >/dev/null 2>"$MERGE_ERR"; then
  STATUS=clean
else
  CONFLICTS=$(git -C "$WORKTREE" diff --name-only --diff-filter=U 2>/dev/null || true)
  if [ -n "$CONFLICTS" ]; then
    STATUS=conflict
  else
    STATUS=merge_failed
    # A merge that reports no conflicted paths failed for an environmental reason,
    # not a textual one. git's own stderr names it; discarding it turns a one-line
    # diagnosis into a reproduction.
    MERGE_ERROR=$(cat "$MERGE_ERR" 2>/dev/null || true)
  fi
fi
rm -f "$MERGE_ERR"

if [ "$STATUS" = conflict ]; then
  SUMMARY="CONFLICTS: $AHEAD upstream commit(s) do not merge cleanly. Resolve by hand in a real branch; conflicted paths:
$(printf '%s\n' "$CONFLICTS" | sed 's/^/  - /')"
  report
  exit 1
fi

if [ "$STATUS" = merge_failed ]; then
  SUMMARY="BLOCKED: the merge could not be attempted (no conflicted paths reported). Inspect with --keep."
  if [ -n "$MERGE_ERROR" ]; then
    SUMMARY="$SUMMARY
git reported:
$(printf '%s\n' "$MERGE_ERROR" | sed 's/^/  /')"
  fi
  report
  exit 3
fi

# Clean merge. Commit it INSIDE the scratch worktree only, so the tests run
# against the tree a human would actually get. The branch is deleted on exit.
git -C "$WORKTREE" commit --quiet --no-verify \
  -m "scratch: merge $UPSTREAM_REF for freshness check" >/dev/null 2>&1 || true

case "$TESTS" in
  none)
    TEST_RESULT=skipped
    ;;
  changed|all|*)
    if [ ! -x "$WORKTREE/bin/fm-test-run.sh" ]; then
      TEST_RESULT=unavailable
    else
      echo "running tests on the merged tree (--tests $TESTS); this can take a while..." >&2
      case "$TESTS" in
        changed) set -- --changed --base "$BASE_SHA" ;;
        all) set -- --all ;;
        *) set -- --lane "$TESTS" ;;
      esac
      if (cd "$WORKTREE" && ./bin/fm-test-run.sh "$@"); then
        TEST_RESULT=passed
      else
        TEST_RESULT=failed
      fi
    fi
    ;;
esac

case "$TEST_RESULT" in
  passed)
    SUMMARY="CLEAN: $AHEAD upstream commit(s) merge cleanly and the selected tests pass - ready for a human to take.
Take it with:  git checkout -b fm/upstream-merge && git merge $UPSTREAM_REF
Then re-read every Windows arm in the merged files: a clean textual merge does NOT prove upstream did not move the code the arm was guarding."
    report
    exit 0
    ;;
  failed)
    SUMMARY="TESTS FAILED: $AHEAD upstream commit(s) merge cleanly but the selected tests fail on the merged tree. Do NOT take this merge until the failures are understood."
    report
    exit 2
    ;;
  *)
    SUMMARY="CLEAN (untested): $AHEAD upstream commit(s) merge cleanly; tests were $TEST_RESULT."
    report
    exit 0
    ;;
esac
