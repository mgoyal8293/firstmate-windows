#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, portable lane composition, proven-isolated --jobs, timing markers,
# JSON artifacts, coverage guard, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"

# These fixtures validate the runner's JSON with an interpreter of their own.
# tests/lib.sh resolved one by executing it, so the Windows Store alias cannot
# be mistaken for it here either.
fm_python3 || fail "these tests need a working python3 to validate the runner's JSON artifacts"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

test_list_all_exact_suite_coverage() {
  local listed expected missing extra f
  listed=$("$RUNNER" --list --all | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh; do
      [ -f "$f" ] || continue
      printf 'tests/%s\n' "$(basename "$f")"
    done | LC_ALL=C sort
  )
  [ -n "$listed" ] || fail "--list --all printed nothing"
  missing=$(LC_ALL=C comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  extra=$(LC_ALL=C comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  [ -z "$missing" ] || fail "--list --all missing scripts: $missing"
  [ -z "$extra" ] || fail "--list --all unexpected scripts: $extra"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = \
    "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] \
    || fail "--list --all must not duplicate scripts"
  pass "exact suite coverage: --all lists every tests/*.test.sh once"
}

test_family_selection() {
  local listed line
  listed=$("$RUNNER" --list --family pure-contract-unit)
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  pass "family selection returns a proper subset of the suite"
}

test_single_script_selection() {
  local listed
  listed=$("$RUNNER" --list tests/fm-lint.test.sh)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "single-script list expected tests/fm-lint.test.sh, got: $listed"
  pass "single-script selection lists exactly that path"
}

test_changed_file_selection_is_conservative() {
  local listed all_count fam_count listed_count
  # A path-mapped pure unit should not expand to --all.
  listed=$("$RUNNER" --list --family pure-contract-unit)
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] || fail "changed-informed pure family still full suite"
  # Directly exercise --changed: empty or partial selection is ok; must not
  # exceed the suite and must never silently become --all by accident.
  listed=$("$RUNNER" --list --changed --base HEAD 2>/dev/null || true)
  if [ -n "$listed" ]; then
    listed_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$listed_count" -le "$all_count" ] || fail "changed selection larger than suite"
  fi
  # A single test path selects only that script (same contract as a
  # tests/*.test.sh change entry in the map).
  listed=$("$RUNNER" --list tests/fm-brief.test.sh)
  [ "$listed" = "tests/fm-brief.test.sh" ] \
    || fail "test-file-only change contract should select one script"
  pass "changed-file selection stays conservative (never silent full suite)"
}

init_changed_fixture_repo() {
  local repo=$1 script
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  # The runner sources the shared Python probe, so the fixture repo needs it too.
  cp "$ROOT/bin/fm-python-lib.sh" "$repo/bin/fm-python-lib.sh"
  for script in \
    fm-brief.test.sh \
    fm-ask-user-authority.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-daemon.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-secondmate-safety.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-pr-merge.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-backend-orca.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/unmapped-source.sh"
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p "$repo/.agents/skills/example" "$repo/.claude" "$repo/.pi/extensions" "$repo/src"
  : >"$repo/.agents/skills/example/SKILL.md"
  : >"$repo/.claude/settings.json"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "shared helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
  git -C "$repo" add tests/lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm helper-change

  printf '\n' >>"$repo/tests/fm-backend-herdr-eventwait.test.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" "eventwait test selects Herdr coverage"
  assert_contains "$listed" "tests/fm-backend.test.sh" "eventwait test selects backend coverage"
  git -C "$repo" add tests/fm-backend-herdr-eventwait.test.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm eventwait-change

  printf '\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-daemon.test.sh" "supervisor target selects daemon coverage"
  assert_contains "$listed" "tests/fm-afk-return.test.sh" "supervisor target selects afk coverage"
  git -C "$repo" add bin/fm-supervisor-target-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm supervisor-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-ask-user-authority.test.sh" "skill source selects pure contract coverage"
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "Claude and Pi source selects hook coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  printf '\n' >>"$repo/src/unmapped.ts"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unmapped changed source must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: src/unmapped.ts' "$tmp/err" \
    || fail "unmapped changed source failure is not actionable: $(cat "$tmp/err")"
  rm -rf "$tmp"
  pass "changed selection covers dependents and fails closed for unmapped source"
}

test_changed_shared_python_library_selects_test_library_dependents() {
  local tmp repo listed rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-pylib.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  # tests/lib.sh sources bin/fm-python-lib.sh, so a suite that never names the
  # library still breaks when the probe does. None of the fixture suites names
  # it; a basename-only scan would find no consumer at all and fail closed.
  printf '\n' >>"$repo/bin/fm-python-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>"$tmp/err") || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "the shared Python library has no changed-test mapping (rc=$rc): $(cat "$tmp/err")"
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" \
    "the shared Python library does not select its transitive test-library dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" \
    "the shared Python library does not select snapshot coverage"
  rm -rf "$tmp"
  pass "a change to the shared Python library selects every test-library dependent"
}

test_empty_selection_emits_summary() {
  local tmp repo out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  out=$(cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
    || fail "empty valid changed selection must pass"
  [ "$out" = "FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0" ] \
    || fail "empty selection summary is missing or non-deterministic: $out"
  json="$tmp/artifacts/timing.json"
  "${FM_PYTHON3_CMD[@]}" -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"] == {"duration_ms": 0, "failed": 0, "skipped_gate": 0, "total": 0}
assert doc["scripts"] == []
assert doc["families"] == []
' "$json" || { rm -rf "$tmp"; fail "empty selection JSON summary is wrong"; }
  rm -rf "$tmp"
  pass "empty changed selection emits deterministic text and JSON summaries"
}

test_timing_markers_and_json() {
  local tmp fixture out json begin_n end_n summary
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timing.XXXXXX")
  fixture="$tmp/ok.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$fixture"
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$out" || true)
  [ "$begin_n" -eq 1 ] || fail "expected one FM_TEST_BEGIN, got $begin_n"
  [ "$end_n" -eq 1 ] || fail "expected one FM_TEST_END, got $end_n"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$out" \
    || fail "BEGIN line missing family/expected_gate_skip: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || fail "END line missing exit/duration/gate_skip: $(grep '^FM_TEST_END' "$out")"
  summary=$(grep '^FM_TEST_SUMMARY ' "$out" || true)
  assert_contains "$summary" "total=1" "summary total"
  assert_contains "$summary" "failed=0" "summary failed"
  assert_contains "$summary" "skipped_gate=0" "summary skipped_gate"
  grep -q '^FM_TEST_SLOWEST rank=1 ' "$out" \
    || fail "expected FM_TEST_SLOWEST rank=1"
  [ -f "$json" ] || fail "JSON timing artifact was not written"
  "${FM_PYTHON3_CMD[@]}" -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" \
    || fail "JSON timing artifact is not valid JSON"
  "${FM_PYTHON3_CMD[@]}" -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert "scripts" in doc and len(doc["scripts"]) == 1, doc
assert doc["scripts"][0]["exit"] == 0
assert doc["scripts"][0]["gate_skip"] is False
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_aggregate_exit_behavior() {
  local tmp pass_f fail_f rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  set +e
  "$RUNNER" "$pass_f" "$fail_f" >"$tmp/out.txt" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate exit must be non-zero when any script fails"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out.txt" \
    || fail "summary should report total=2 failed=1: $(grep FM_TEST_SUMMARY "$tmp/out.txt")"
  # All-green stays 0.
  set +e
  "$RUNNER" "$pass_f" >"$tmp/out2.txt" 2>"$tmp/err2.txt"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "aggregate exit must be 0 when every script passes"; }
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_gate_skip_accounting() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "gate-skip fixture must exit 0 from the runner"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  "${FM_PYTHON3_CMD[@]}" -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting is honest and non-failing"
}

test_fail_on_gate_skip_token() {
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  "$RUNNER" --fail-on-gate-skip 'herdr not found' "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-gate-skip must make herdr-not-found a hard failure"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-gate-skip: $(grep FM_TEST_SUMMARY "$out")"
  grep -q 'required gate skip token' "$tmp/err.txt" \
    || fail "runner must log the required gate skip token"
  rm -rf "$tmp"
  pass "fail-on-gate-skip converts herdr-not-found into a hard failure"
}

test_exclude_family() {
  local listed
  listed=$("$RUNNER" --list --all --exclude-family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "exclude-family real-herdr-gated left a real-herdr script"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-lint.test.sh' \
    || fail "exclude-family must retain pure-contract-unit scripts"
  # Explicit family mode still works; exclude of a different family is a no-op.
  listed=$("$RUNNER" --list --family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "family real-herdr-gated must list smoke test"
  pass "exclude-family drops the named primary family after selection"
}

test_portable_shard_union_and_coverage_guard() {
  local s1 s2 proven serial herdr all_count union_count overlap out first
  s1=$("$RUNNER" --list --lane portable-parallel-1)
  s2=$("$RUNNER" --list --lane portable-parallel-2)
  proven=$("$RUNNER" --list --proven-isolated)
  serial=$("$RUNNER" --list --lane portable-serial)
  herdr=$("$RUNNER" --list --family real-herdr-gated)
  [ -n "$s1" ] && [ -n "$s2" ] || fail "portable parallel shards must be non-empty"
  # Shards disjoint.
  overlap=$(LC_ALL=C comm -12 <(printf '%s\n' "$s1" | LC_ALL=C sort) <(printf '%s\n' "$s2" | LC_ALL=C sort) || true)
  [ -z "$overlap" ] || fail "portable parallel shards overlap: $overlap"
  # Union of shards equals proven-isolated.
  [ "$(printf '%s\n' "$s1" "$s2" | LC_ALL=C sort -u)" = \
    "$(printf '%s\n' "$proven" | LC_ALL=C sort -u)" ] \
    || fail "shard union must equal proven-isolated set"
  # No herdr in portable lanes.
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "portable lanes must not include real-herdr-gated smoke"
  printf '%s\n' "$herdr" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "herdr family must include smoke"
  out=$("$RUNNER" --check-coverage)
  assert_contains "$out" "FM_TEST_COVERAGE ok" "coverage guard success marker"
  # The guard also reports how many serial scripts are packed at the default
  # weight because nothing has measured them. That count is what an operator
  # reads to decide whether the shard balance can be trusted: an unmeasured
  # script is packed as if it were average, and enough of them silently push
  # one shard past its job cap, where it is cancelled with no verdict at all
  # rather than merely running slow. Pinned so the field cannot quietly vanish.
  printf '%s\n' "$out" | grep -Eq 'FM_TEST_COVERAGE ok .* unmeasured_serial=[0-9]+$' \
    || fail "coverage guard must report an unmeasured serial count: $out"
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  union_count=$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$union_count" = "$all_count" ] \
    || fail "union of lanes ($union_count) must equal --all ($all_count)"
  # No duplicates across the four partitions.
  [ "$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" = "0" ] \
    || fail "lanes must not duplicate scripts"
  # LPT order: first script of shard 1 is the longest proven script.
  first=$(printf '%s\n' "$s1" | head -n 1)
  [ "$first" = "tests/fm-x-mode.test.sh" ] \
    || fail "shard 1 must start with the longest proven script, got $first"
  pass "portable shard union, disjointness, and coverage guard hold"
}

unmeasured_serial_count() { # <coverage guard stdout>
  printf '%s\n' "$1" | sed -n 's/.*unmeasured_serial=\([0-9]*\).*/\1/p'
}

test_unmeasured_serial_report_names_the_unhinted_script() {
  local sandbox out err rc baseline count expected
  # The report the guard added is only exercised against a lane that actually
  # contains an unmeasured script. A sandbox root gives it one: the runner
  # resolves its own root from its location and derives the serial lane from
  # tests/*.test.sh, so a copy beside a mirrored inventory drives the real guard
  # and one added script is the only difference between the two runs below.
  sandbox=$(coverage_guard_sandbox fm-test-run-unmeasured) \
    || fail "could not create sandbox root"

  # Baseline first, so the assertion is the delta this case creates and not the
  # production tree's own hint coverage. A newly added test legitimately has no
  # measured duration until it has run once in CI, so an absolute count here
  # would red this required lane for adding a test - the same self-inflicted
  # false red the guard reports rather than refuses in order to avoid.
  out=$("$sandbox/bin/fm-test-run.sh" --check-coverage 2>"$sandbox/baseline-err.txt")
  rc=$?
  [ "$rc" = 0 ] || fail "coverage guard must pass on the mirrored sandbox: $out $(cat "$sandbox/baseline-err.txt")"
  baseline=$(unmeasured_serial_count "$out")
  case $baseline in
    ''|*[!0-9]*) fail "coverage guard did not report an unmeasured serial count: $out" ;;
  esac

  : > "$sandbox/tests/fm-zzz-unmeasured-probe.test.sh"
  out=$("$sandbox/bin/fm-test-run.sh" --check-coverage 2>"$sandbox/err.txt")
  rc=$?
  err=$(cat "$sandbox/err.txt")
  # Reported, never refused: an unmeasured script must not fail the guard.
  [ "$rc" = 0 ] || fail "unmeasured serial script must not fail the coverage guard: $out $err"
  assert_contains "$out" "FM_TEST_COVERAGE ok" "coverage guard success marker in sandbox"
  # The count must move with the lane, not be a constant: swapped comm operands
  # or a divergent sort order leave it at the baseline for a lane that gained an
  # unmeasured script.
  count=$(unmeasured_serial_count "$out")
  expected=$((baseline + 1))
  [ "$count" = "$expected" ] \
    || fail "one added unhinted script must raise unmeasured_serial from $baseline to $expected, got $count: $out"
  printf '%s\n' "$err" | grep -Fq 'tests/fm-zzz-unmeasured-probe.test.sh' \
    || fail "guard must name the unhinted serial script on stderr: $err"
  # And a hinted script must not be swept in with it.
  printf '%s\n' "$err" | grep -Fq 'tests/fm-pr-check-security.test.sh' \
    && fail "guard named a measured script as unmeasured: $err"
  rm -rf "$sandbox"
  pass "coverage guard counts and names serial scripts with no measured duration"
}

test_portable_serial_shards_partition_the_serial_lane() {
  local lanes count serial shard listed union dups shard_lane total cap
  lanes=$("$RUNNER" --list-lanes)
  count=$(printf '%s\n' "$lanes" | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  [ "$count" -ge 2 ] || fail "expected at least two portable serial shard lanes, got $count"
  printf '%s\n' "$lanes" | grep -q "^portable-serial-1of${count}\$" \
    || fail "shard lane names must carry the shard count ${count}: $lanes"

  serial=$("$RUNNER" --list --lane portable-serial | LC_ALL=C sort)
  union=""
  shard=1
  while [ "$shard" -le "$count" ]; do
    shard_lane="portable-serial-${shard}of${count}"
    listed=$("$RUNNER" --list --lane "$shard_lane")
    [ -n "$listed" ] || fail "$shard_lane selected no tests"
    union=$(printf '%s\n%s' "$union" "$listed")
    shard=$((shard + 1))
  done
  union=$(printf '%s\n' "$union" | grep -v '^$' || true)

  dups=$(printf '%s\n' "$union" | LC_ALL=C sort | uniq -d || true)
  [ -z "$dups" ] || fail "portable serial shards run the same script twice: $dups"
  [ "$(printf '%s\n' "$union" | LC_ALL=C sort)" = "$serial" ] \
    || fail "portable serial shards must exactly cover the portable serial lane"

  # Every shard carries a real share of the lane, so no degenerate partition
  # leaves one runner doing nearly all of the work the split exists to spread.
  total=$(printf '%s\n' "$serial" | wc -l | tr -d ' ')
  cap=$((total * 6 / 10))
  shard=1
  while [ "$shard" -le "$count" ]; do
    listed=$("$RUNNER" --list --lane "portable-serial-${shard}of${count}" | wc -l | tr -d ' ')
    [ "$listed" -ge 2 ] \
      || fail "portable-serial-${shard}of${count} holds only $listed script(s)"
    [ "$listed" -le "$cap" ] \
      || fail "portable-serial-${shard}of${count} holds $listed of $total scripts"
    shard=$((shard + 1))
  done

  # Assignment is deterministic across invocations.
  [ "$("$RUNNER" --list --lane "portable-serial-1of${count}")" = \
    "$("$RUNNER" --list --lane "portable-serial-1of${count}")" ] \
    || fail "portable serial shard membership must be deterministic"
  pass "portable serial shards are a deterministic disjoint cover of the serial lane"
}

test_portable_serial_shard_lane_refusals() {
  local tmp count rc other
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-shard-lane.XXXXXX")
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  other=$((count + 1))

  # A lane built for a different shard count must refuse rather than run a
  # partial suite: this is what keeps a CI matrix from silently dropping tests.
  set +e
  "$RUNNER" --list --lane "portable-serial-1of${other}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "mismatched shard count must refuse (exit 2), got $rc"
  [ ! -s "$tmp/out" ] || fail "mismatched shard count must not list tests"
  grep -Fq "configured for $count" "$tmp/err" \
    || fail "mismatch refusal must name the configured count: $(cat "$tmp/err")"

  set +e
  "$RUNNER" --list --lane "portable-serial-$((count + 1))of${count}" >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "out-of-range shard index must refuse (exit 2), got $rc"
  grep -Fq "outside 1..$count" "$tmp/err2" \
    || fail "range refusal message missing: $(cat "$tmp/err2")"

  set +e
  "$RUNNER" --list --lane portable-serial-1 >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "shard lane without a count must refuse (exit 2), got $rc"
  rm -rf "$tmp"
  pass "portable serial shard lanes refuse mismatched, out-of-range, and countless names"
}

test_windows_shard_lane_refusals() {
  local tmp count rc other
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-windows-lane.XXXXXX")
  count=$("$RUNNER" --list-lanes | grep -c '^windows-[0-9]*of[0-9]*$')
  other=$((count + 1))

  # .github/workflows/windows-ci.yml builds the lane name from
  # ${{ strategy.job-total }} precisely so a matrix that disagrees with
  # WINDOWS_SHARDS fails loudly instead of running part of the lane.
  set +e
  "$RUNNER" --list --lane "windows-1of${other}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "mismatched windows shard count must refuse (exit 2), got $rc"
  [ ! -s "$tmp/out" ] || fail "mismatched windows shard count must not list tests"
  grep -Fq "configured for $count" "$tmp/err" \
    || fail "windows mismatch refusal must name the configured count: $(cat "$tmp/err")"

  set +e
  "$RUNNER" --list --lane "windows-${other}of${count}" >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "out-of-range windows shard index must refuse (exit 2), got $rc"
  [ ! -s "$tmp/out2" ] || fail "out-of-range windows shard index must not list tests"
  grep -Fq "outside 1..$count" "$tmp/err2" \
    || fail "windows range refusal message missing: $(cat "$tmp/err2")"

  set +e
  "$RUNNER" --list --lane windows-1 >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "windows shard lane without a count must refuse (exit 2), got $rc"
  [ ! -s "$tmp/out3" ] || fail "countless windows shard lane must not list tests"
  grep -Fq "unknown lane 'windows-1'" "$tmp/err3" \
    || fail "countless windows lane refusal message missing: $(cat "$tmp/err3")"
  rm -rf "$tmp"
  pass "windows shard lanes refuse mismatched, out-of-range, and countless names"
}

# FM_TEST_COVERAGE_WINDOWS is the guard's machine-read status line, so it is
# parsed into fields here rather than matched as text: unmeasured_windows= and
# windows= are distinct fields that a substring match conflates.
windows_coverage_field() {  # <coverage guard stdout> <field>
  printf '%s\n' "$1" | awk -v f="$2" '
    $1 == "FM_TEST_COVERAGE_WINDOWS" {
      for (i = 2; i <= NF; i++) {
        n = index($i, "=")
        if (n > 0 && substr($i, 1, n - 1) == f) print substr($i, n + 1)
      }
    }
  '
}

# The guard reads its unhinted members out as a diagnostic block: a `log` header
# line, then the names. Both lane reporters print that same shape, so the windows
# one has to be isolated before its names mean anything - the probe below is a
# real file in the sandbox, so the derived serial lane reports it too.
windows_unhinted_block() {  # <coverage guard stderr>
  printf '%s\n' "$1" | awk '
    index($0, "windows lane members with no measured duration") { inblock = 1; next }
    inblock && /^fm-test-run: / { inblock = 0 }
    inblock { print }
  '
}

# A sandbox root the REAL guard runs in: the runner resolves its own root from
# its location, so a copy beside a mirrored inventory drives the production code
# path while one edit is the only difference from the shipped tree. Shared by the
# serial and windows coverage cases, so the mirrored shape stays one definition.
coverage_guard_sandbox() {  # <slug> -> echoes sandbox root
  local sandbox f
  sandbox=$(fm_test_tmproot "$1") || return 1
  mkdir -p "$sandbox/bin" "$sandbox/tests" || return 1
  cp "$RUNNER" "$sandbox/bin/fm-test-run.sh" || return 1
  cp "$ROOT/bin/fm-test-isolation-proof.sh" "$sandbox/bin/fm-test-isolation-proof.sh" || return 1
  # Both mirrored scripts source the shared Python probe.
  cp "$ROOT/bin/fm-python-lib.sh" "$sandbox/bin/fm-python-lib.sh" || return 1
  for f in "$ROOT"/tests/*.test.sh; do
    : > "$sandbox/tests/$(basename "$f")" || return 1
  done
  printf '%s\n' "$sandbox"
}

test_windows_coverage_report_counts_the_shipped_lane() {
  local dir out err rc lane_count shard_count windows shards unmeasured
  dir=$(fm_test_tmproot fm-test-run-wincoverage) || fail "could not create a fixture root"
  set +e
  out=$("$RUNNER" --check-coverage 2>"$dir/err.txt")
  rc=$?
  set -e
  err=$(cat "$dir/err.txt")
  [ "$rc" = 0 ] || fail "coverage guard must pass on the shipped lists: $out $err"
  # The Windows lane is a separate overlay with its own report, so a Linux-lane
  # verdict says nothing about it.
  printf '%s\n' "$out" \
    | grep -Eq '^FM_TEST_COVERAGE_WINDOWS ok windows=[0-9]+ windows_shards=[0-9]+ unmeasured_windows=[0-9]+$' \
    || fail "guard must report windows=, windows_shards= and unmeasured_windows=: $out"
  # The sizes must be the lane's own, not constants the report could print for
  # any inventory.
  lane_count=$("$RUNNER" --list --lane windows | wc -l | tr -d ' ')
  shard_count=$("$RUNNER" --list-lanes | grep -c '^windows-[0-9]*of[0-9]*$')
  windows=$(windows_coverage_field "$out" windows)
  shards=$(windows_coverage_field "$out" windows_shards)
  unmeasured=$(windows_coverage_field "$out" unmeasured_windows)
  [ "$windows" = "$lane_count" ] \
    || fail "reported windows=$windows must equal the lane's $lane_count members: $out"
  [ "$shards" = "$shard_count" ] \
    || fail "reported windows_shards=$shards must equal the $shard_count shard lanes: $out"
  # Zero because the lane's admission rule is that a member joins once it is
  # measured green on Windows (docs/fm-test-windows-lane.md), and the counter
  # below proves this zero can move.
  [ "$unmeasured" = 0 ] \
    || fail "every windows lane member must carry a measured hint, got unmeasured_windows=$unmeasured: $err"
  rm -rf "$dir"
  pass "coverage guard reports the windows lane size, shard count, and unmeasured members"
}

test_unmeasured_windows_report_names_the_unhinted_member() {
  local sandbox runner out err rc baseline count expected probe hinted block
  probe=tests/fm-zzz-windows-probe.test.sh
  hinted=tests/fm-decision-hold-lifecycle.test.sh
  sandbox=$(coverage_guard_sandbox fm-test-run-unmeasured-windows) \
    || fail "could not create sandbox root"
  runner="$sandbox/bin/fm-test-run.sh"

  # Baseline first, so the assertion is this case's delta rather than the shipped
  # tree's own hint coverage.
  set +e
  out=$("$runner" --check-coverage 2>"$sandbox/baseline-err.txt")
  rc=$?
  set -e
  [ "$rc" = 0 ] \
    || fail "coverage guard must pass on the mirrored sandbox: $out $(cat "$sandbox/baseline-err.txt")"
  baseline=$(windows_coverage_field "$out" unmeasured_windows)
  case $baseline in
    ''|*[!0-9]*) fail "sandbox guard did not report an unmeasured windows count: $out" ;;
  esac

  # Admit a member to the hand-written lane list without measuring it - the exact
  # drift between the two parallel lists that this counter exists to see - and
  # leave windows_weight_hints alone.
  : > "$sandbox/$probe"
  awk -v probe="$probe" '
    { print }
    /^list_windows\(\) \{$/ { inlist = 1 }
    inlist && /^  cat <</ { print probe; inlist = 0 }
  ' "$runner" > "$sandbox/patched.sh" || fail "could not build the patched sandbox runner"
  cmp -s "$runner" "$sandbox/patched.sh" \
    && fail "the fixture must actually admit an unhinted member to the sandbox lane list"
  cat "$sandbox/patched.sh" > "$runner" || fail "could not install the patched sandbox runner"

  set +e
  out=$("$runner" --check-coverage 2>"$sandbox/err.txt")
  rc=$?
  set -e
  err=$(cat "$sandbox/err.txt")
  # Reported, never refused, for the same reason the serial counter is: a member
  # legitimately has no measurement until it has run once.
  [ "$rc" = 0 ] || fail "an unhinted windows member must not fail the coverage guard: $out $err"
  assert_contains "$out" "FM_TEST_COVERAGE_WINDOWS ok" "windows coverage marker in sandbox"
  count=$(windows_coverage_field "$out" unmeasured_windows)
  expected=$((baseline + 1))
  # A count that cannot move proves nothing: swapped comm operands or a divergent
  # sort order leave it at the baseline for a lane that just gained an unhinted
  # member.
  [ "$count" = "$expected" ] \
    || fail "one unhinted member must raise unmeasured_windows from $baseline to $expected, got $count: $out"
  # Bound to the windows reporter's own listing: naming is a separate claim from
  # counting, and stderr as a whole cannot tell the two reporters apart.
  printf '%s\n' "$err" | grep -Fq 'windows lane members with no measured duration' \
    || fail "guard must print its windows unhinted listing: $err"
  block=$(windows_unhinted_block "$err")
  printf '%s\n' "$block" | grep -Fqx "$probe" \
    || fail "the windows listing must name the unhinted member, got '$block': $err"
  # And a measured member must not be swept in with it.
  printf '%s\n' "$err" | grep -Fq "$hinted" \
    && fail "guard named a measured windows member as unmeasured: $err"
  rm -rf "$sandbox"
  pass "coverage guard counts and names windows lane members with no measured duration"
}

test_windows_shards_must_cover_the_windows_lane() {
  local sandbox runner out err rc dropped
  # The lightest lane member, so dropping it cannot empty a shard and trip the
  # earlier empty-shard refusal instead of the partition check under test.
  dropped=tests/fm-gitignore-config.test.sh
  sandbox=$(coverage_guard_sandbox fm-test-run-windows-partition) \
    || fail "could not create sandbox root"
  runner="$sandbox/bin/fm-test-run.sh"

  set +e
  out=$("$runner" --check-coverage 2>"$sandbox/baseline-err.txt")
  rc=$?
  set -e
  [ "$rc" = 0 ] \
    || fail "coverage guard must pass on the mirrored sandbox: $out $(cat "$sandbox/baseline-err.txt")"

  # Lose one member from the shard assignment while the lane still lists it. The
  # shipped code reads one list on both sides, so the only way to prove the check
  # would catch a lost member is to make the two sides genuinely disagree.
  awk -v drop="$dropped" '
    /^run_coverage_guard\(\) \{$/ {
      print "windows_assignments() {"
      print "  lane_assignments \"$WINDOWS_SHARDS\" list_windows windows_weight_for | grep -Fv \"" drop "\""
      print "}"
    }
    { print }
  ' "$runner" > "$sandbox/patched.sh" || fail "could not build the patched sandbox runner"
  cmp -s "$runner" "$sandbox/patched.sh" \
    && fail "the fixture must actually drop a member from the windows shard assignment"
  cat "$sandbox/patched.sh" > "$runner" || fail "could not install the patched sandbox runner"

  set +e
  out=$("$runner" --check-coverage 2>"$sandbox/err.txt")
  rc=$?
  set -e
  err=$(cat "$sandbox/err.txt")
  [ "$rc" -ne 0 ] \
    || fail "windows shards that do not cover the lane must refuse, got exit 0: $out"
  printf '%s\n' "$err" | grep -Fq 'windows shards must equal the windows lane' \
    || fail "the refusal must name the windows partition check: $err"
  printf '%s\n' "$err" | grep -Fq "$dropped" \
    || fail "the refusal must name the member the shards lost: $err"
  assert_not_contains "$out" "FM_TEST_COVERAGE_WINDOWS ok" \
    "a refused windows partition must not also report a coverage line"
  rm -rf "$sandbox"
  pass "coverage guard refuses windows shards that do not cover the windows lane"
}

test_jobs_requires_proven_isolated() {
  local tmp rc shard_lane
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --lane portable-serial >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with portable-serial must refuse (exit 2), got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err" \
    || fail "--jobs refusal message missing: $(cat "$tmp/err")"
  set +e
  "$RUNNER" --jobs 2 tests/fm-watcher-lock.test.sh >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs on watcher-lock must refuse, got $rc"
  # Sharding across runners never relaxes the serial rule inside one shard.
  shard_lane=$("$RUNNER" --list-lanes | grep -m1 '^portable-serial-[0-9]*of[0-9]*$')
  set +e
  "$RUNNER" --jobs 2 --lane "$shard_lane" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with a portable serial shard must refuse, got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err3" \
    || fail "shard --jobs refusal message missing: $(cat "$tmp/err3")"
  rm -rf "$tmp"
  pass "--jobs refuses non-proven / stateful selections"
}

test_jobs_parallel_scheduler_and_failure_propagation() {
  local tmp repo runner evidence fake_bin a b c d rc begin_n end_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-sched.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  c=tests/fm-lint.test.sh
  d=tests/fm-supervision-instructions.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$runner"
  cp "$ROOT/bin/fm-python-lib.sh" "$repo/bin/fm-python-lib.sh"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  # The slow fixture blocks on the replacement fixture's own signal rather than
  # a wall-clock sleep, so a loaded machine cannot let it finish first and turn
  # a correct scheduler into a failure. The bounded deadline is only there so a
  # scheduler that really does wait for the oldest worker still reports instead
  # of hanging.
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
if [ -n "${SCHED_WAIT_FOR_REPLACEMENT:-}" ]; then
  waited=0
  while [ ! -e "$SCHED_EVIDENCE/replacement-started" ] && [ "$waited" -lt 600 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
fi
touch "$SCHED_EVIDENCE/slow-done"
echo "ok - slow fixture"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "ok - fast fixture"
SH
  cat >"$repo/$c" <<'SH'
#!/usr/bin/env bash
# Read the evidence before releasing the slow fixture, so the release can never
# race ahead of the check it is being used to make.
if [ -e "$SCHED_EVIDENCE/slow-done" ]; then
  touch "$SCHED_EVIDENCE/replacement-started"
  echo "not ok - scheduler waited for oldest worker"
  exit 1
fi
touch "$SCHED_EVIDENCE/replacement-started"
echo "ok - replacement fixture started before slow fixture finished"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  PATH="$fake_bin:$PATH" SCHED_EVIDENCE="$evidence" SCHED_WAIT_FOR_REPLACEMENT=1 \
    "$runner" --jobs 2 --json "$tmp/timing.json" \
    "$a" "$b" "$c" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "jobs=2 must refill the first completed slot"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$tmp/out" || true)
  [ "$begin_n" -eq 3 ] || fail "expected 3 BEGIN markers, got $begin_n"
  [ "$end_n" -eq 3 ] || fail "expected 3 END markers, got $end_n"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || fail "summary missing for jobs run: $(grep FM_TEST_SUMMARY "$tmp/out")"
  "${FM_PYTHON3_CMD[@]}" -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==0
assert "jobs=2" in doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "jobs JSON artifact wrong"; }

  # Non-proven path is refused before any worker starts (no race masking).
  cat >"$tmp/fail.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate fail"
exit 1
SH
  chmod +x "$tmp/fail.test.sh"
  set +e
  "$runner" --jobs 2 "$a" "$tmp/fail.test.sh" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "jobs with non-proven fail fixture must refuse before run, got $rc"

  # Parallel failure propagation stays inside the private runner fixture.
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate proven-set fail"
exit 1
SH
  chmod +x "$repo/$b"
  set +e
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "jobs aggregate must be non-zero when a proven worker fails"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out4" \
    || { rm -rf "$tmp"; fail "jobs failure summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out4")"; }

  cat >"$repo/$d" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found" >&2
exit 0
SH
  chmod +x "$repo/$d"
  set +e
  "$runner" --jobs 2 --fail-on-gate-skip 'herdr not found' "$d" >"$tmp/out5" 2>"$tmp/err5"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "parallel stderr gate skip must hard-fail"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out5" \
    || { rm -rf "$tmp"; fail "parallel stderr hard-fail summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out5")"; }

  "$runner" --jobs 2 "$d" >"$tmp/out6" 2>"$tmp/err6" \
    || { rm -rf "$tmp"; fail "ordinary parallel stderr gate skip must remain successful"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates; non-proven refused"
}

test_herdr_ci_family_run_has_a_step_timeout() {
  # The required Herdr lane's hang tripwire is the family-run *step* bound, not
  # the 75-minute job cap. Parse the workflow as YAML so nested `with.name`
  # artifact keys cannot masquerade as the step contract.
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .github/workflows/ci.yml as YAML"
  local json job_timeout step_timeout
  json=$(ruby -ryaml -rjson -e '
doc = YAML.load_file(ARGV[0])
job = doc.fetch("jobs").fetch("tests-herdr")
step = job.fetch("steps").find { |s|
  s.is_a?(Hash) && s["name"] == "Run real-Herdr family (serial, required)"
}
raise "missing family-run step" if step.nil?
raise "family-run step has no timeout-minutes" unless step.key?("timeout-minutes")
puts JSON.generate(
  "job_timeout" => job.fetch("timeout-minutes"),
  "step_timeout" => step.fetch("timeout-minutes")
)
' "$ROOT/.github/workflows/ci.yml") \
    || fail "could not parse tests-herdr timeouts from ci.yml"
  job_timeout=$("${FM_PYTHON3_CMD[@]}" -c 'import json,sys; print(json.load(sys.stdin)["job_timeout"])' <<<"$json") \
    || fail "could not read job timeout from parsed workflow"
  step_timeout=$("${FM_PYTHON3_CMD[@]}" -c 'import json,sys; print(json.load(sys.stdin)["step_timeout"])' <<<"$json") \
    || fail "could not read step timeout from parsed workflow"
  [ "$job_timeout" = 75 ] \
    || fail "tests-herdr job backstop must stay 75 minutes, got $job_timeout"
  [ "$step_timeout" = 20 ] \
    || fail "family-run step timeout must be 20 minutes, got $step_timeout"
  [ "$step_timeout" -lt "$job_timeout" ] \
    || fail "family-run step timeout must be below the job backstop"
  pass "Herdr CI family-run step times out at 20 min under a 75 min job backstop"
}

# Build a bin/ + tests/ tree the LF guard can scan: <crlf-count> files under bin/
# carry CRLF, everything else is LF. <name-pad> pads each CRLF filename so the
# scan's own output can be made larger than a pipe buffer.
lfguard_tree() {  # <dir> <crlf-count> <name-pad>
  local dir=$1 count=$2 pad=$3 name i=0
  mkdir -p "$dir/bin" "$dir/tests"
  printf 'echo lf\n' > "$dir/bin/ok.sh"
  printf 'echo lf\n' > "$dir/tests/ok.test.sh"
  name=$(printf "%${pad}s" '' | tr ' ' 'n')
  while [ "$i" -lt "$count" ]; do
    printf 'echo crlf\r\n' > "$dir/bin/${name}${i}.sh"
    i=$((i + 1))
  done
}

# Run the extracted step script the way GitHub runs a `shell: bash` step, from
# inside <dir>. Prints combined output; the caller reads the status separately.
lfguard_run() {  # <guard-script> <dir>
  ( cd "$2" && bash --noprofile --norc -eo pipefail "$1" 2>&1 )
}

test_windows_ci_lf_guard_never_reports_lf_without_a_clean_scan() {
  # .github/workflows/windows-ci.yml's "Assert the working tree is LF" step is
  # the tripwire that stops a CRLF checkout from surfacing as 300 bogus SC1017
  # errors. Parse the workflow as YAML and execute the step's REAL script under
  # GitHub's own invocation (`bash --noprofile --norc -eo pipefail`), so this
  # pins the step's behavior rather than the text of the file.
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .github/workflows/windows-ci.yml as YAML"
  local tmp guard out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-lfguard.XXXXXX")
  guard="$tmp/guard.sh"
  workflow_step_script "$ROOT/.github/workflows/windows-ci.yml" \
    "Assert the working tree is LF" "$guard" every-job \
    || { rm -rf "$tmp"; fail "could not extract the LF assertion step from windows-ci.yml"; }
  [ -s "$guard" ] || { rm -rf "$tmp"; fail "the extracted LF assertion script is empty"; }

  # An LF tree passes and says so.
  lfguard_tree "$tmp/lf" 0 4
  set +e
  out=$(lfguard_run "$guard" "$tmp/lf"); rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "LF tree must pass the guard, got exit $rc: $out"; }
  case "$out" in
    *'working tree is LF'*) : ;;
    *) rm -rf "$tmp"; fail "LF tree must report the tree is LF, got: $out" ;;
  esac

  # A handful of CRLF files: small enough that even a naive pipeline sees them.
  lfguard_tree "$tmp/small" 2 4
  set +e
  out=$(lfguard_run "$guard" "$tmp/small"); rc=$?
  set -e
  [ "$rc" -eq 1 ] || { rm -rf "$tmp"; fail "a CRLF tree must fail the guard, got exit $rc: $out"; }
  case "$out" in
    *'::error::working tree contains CRLF'*) : ;;
    *) rm -rf "$tmp"; fail "a CRLF tree must emit the CRLF error annotation, got: $out" ;;
  esac

  # THE REGRESSION. 600 CRLF files with long names make the scan's own output
  # ~118 KB, larger than a pipe buffer. Piping that scan into `head -5` lets head
  # close the pipe, kills the scan with SIGPIPE, and `-o pipefail` promotes that
  # to the pipeline's status - so the guard used to print five offending
  # filenames and then declare "working tree is LF" and exit 0.
  lfguard_tree "$tmp/big" 600 185
  set +e
  out=$(lfguard_run "$guard" "$tmp/big"); rc=$?
  set -e
  case "$out" in
    *'working tree is LF'*)
      rm -rf "$tmp"
      fail "guard reported the tree is LF while 600 CRLF files were present (SIGPIPE fail-open)" ;;
  esac
  [ "$rc" -eq 1 ] || { rm -rf "$tmp"; fail "a large CRLF tree must fail the guard, got exit $rc"; }
  case "$out" in
    *'::error::working tree contains CRLF'*) : ;;
    *) rm -rf "$tmp"; fail "a large CRLF tree must emit the CRLF error annotation, got: $out" ;;
  esac

  # A scan that could not complete is not a pass either: the guard must never
  # certify a tree it failed to read.
  lfguard_tree "$tmp/partial" 0 4
  rm -rf "$tmp/partial/tests"
  set +e
  out=$(lfguard_run "$guard" "$tmp/partial"); rc=$?
  set -e
  case "$out" in
    *'working tree is LF'*)
      rm -rf "$tmp"
      fail "guard certified the tree as LF although the scan could not read tests/: $out" ;;
  esac
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "an unscannable tree must not exit 0"; }
  case "$out" in
    *'::error::the CRLF scan did not complete'*) : ;;
    *) rm -rf "$tmp"; fail "an incomplete scan must say so, got: $out" ;;
  esac

  rm -rf "$tmp"
  pass "windows-ci LF guard detects CRLF at any scale and refuses to certify an unfinished scan"
}

# A `grep` that reproduces, on this host, what the CR pattern actually did on a
# Windows runner. <mode> picks the direction:
#   empty - a lone-CR argument arrives as the EMPTY pattern, so every file
#           matches. MEASURED on windows-latest (runner image 20260810.198.2,
#           git 2.55.0.windows.3, Git Bash): that is what the lane's inline
#           `$(grep -rlU $'\r' ...)` did - 306 of 306 shell files reported as
#           CRLF on a tree od and perl both prove is LF.
#   blind - a lone-CR argument can never match, the direction an MSYS
#           text-mode read produces. This is the dangerous one: the tree really
#           is CRLF and the scan says it is clean.
crstub_bin() {  # <dir> <mode>
  local dir=$1 mode=$2 real
  real=$(command -v grep) || fail "grep must be resolvable to build the CR stub"
  mkdir -p "$dir"
  cat > "$dir/grep" <<STUB
#!/usr/bin/env bash
args=()
cr=\$'\r'
for a in "\$@"; do
  if [ "\$a" = "\$cr" ]; then
    case $mode in
      empty) args+=('') ;;
      *)     args+=('zzz-this-pattern-never-matches-zzz') ;;
    esac
  else
    args+=("\$a")
  fi
done
exec $real "\${args[@]}"
STUB
  chmod +x "$dir/grep"
}

test_windows_ci_lf_steps_refuse_an_unusable_cr_detector() {
  # THE REGRESSION. This step looked for CR with an inline `$'\r'` inside a
  # command substitution. Under Git Bash that pattern reaches grep EMPTY, so the
  # guard condemned all 306 tracked shell files on a provably-LF tree and five
  # Windows jobs went red at a step that named the wrong cause. The same class of
  # breakage in the other direction would have this step certify a CRLF tree as
  # LF, so both directions are exercised below.
  #
  # A detector that cannot tell a CRLF file from an LF one must therefore say so
  # by name and refuse, rather than pass its verdict on the tree off as fact.
  # The step's REAL script runs here under GitHub's own invocation, with a
  # `grep` on PATH that reproduces each measured direction.
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .github/workflows/windows-ci.yml as YAML"
  local tmp guard bash_bin mode tree out rc
  bash_bin=$(command -v bash) || fail "bash must be resolvable to run the extracted steps"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-crstub.XXXXXX")
  guard="$tmp/guard.sh"
  workflow_step_script "$ROOT/.github/workflows/windows-ci.yml" \
    "Assert the working tree is LF" "$guard" \
    || { rm -rf "$tmp"; fail "could not extract the LF assertion step from windows-ci.yml"; }

  crstub_bin "$tmp/stub-empty" empty
  crstub_bin "$tmp/stub-blind" blind
  # An LF tree for the empty-pattern direction (which used to condemn it) and a
  # CRLF tree for the blind direction (which used to certify it).
  lfguard_tree "$tmp/lf" 0 4
  lfguard_tree "$tmp/crlf" 2 4

  for mode in empty blind; do
    case $mode in
      empty) tree=$tmp/lf ;;
      *)     tree=$tmp/crlf ;;
    esac
    set +e
    out=$(cd "$tree" && PATH="$tmp/stub-$mode:$PATH" \
      "$bash_bin" --noprofile --norc -eo pipefail "$guard" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] \
      || { rm -rf "$tmp"; fail "the LF assertion step must refuse a $mode CR detector, got exit 0: $out"; }
    case "$out" in
      *'::error::the CR detector is not usable in this shell'*) : ;;
      *) rm -rf "$tmp"; fail "the LF assertion step must name the unusable $mode CR detector, got: $out" ;;
    esac
    case "$out" in
      *'working tree is LF'*)
        rm -rf "$tmp"
        fail "the LF assertion step certified the tree through a $mode CR detector: $out" ;;
    esac
    # And it refuses before touching anything: a detector it cannot trust is not
    # licensed to rewrite the tree it was pointed at.
    [ "$(cat "$tree/bin/ok.sh")" = 'echo lf' ] \
      || { rm -rf "$tmp"; fail "the LF assertion step rewrote a file through a $mode CR detector"; }
  done

  # And the real grep on this host passes the same calibration, so the guard is
  # a statement about the detector rather than a permanent refusal.
  set +e
  out=$(cd "$tmp/lf" && "$bash_bin" --noprofile --norc -eo pipefail "$guard" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || { rm -rf "$tmp"; fail "a usable CR detector must still certify an LF tree, got exit $rc: $out"; }

  rm -rf "$tmp"
  pass "windows-ci LF steps refuse a CR detector that cannot tell CRLF from LF"
}

# Extract the `run` script of the step named <step> from <workflow>, requiring
# that every job carrying it spells it identically, and write it to <out>.
# Pass `every-job` as the fourth argument to additionally require that no job is
# missing the step - what a lane needs from a tripwire it cannot afford one job
# to ship without.
workflow_step_script() {  # <workflow> <step-name> <out> [every-job]
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
want = ARGV[1]
jobs = doc.fetch("jobs")
scripts = jobs.filter_map { |name, job|
  step = job.fetch("steps").find { |s| s.is_a?(Hash) && s["name"] == want }
  next nil if step.nil?
  step.fetch("run")
}
raise "no job carries a step named #{want.inspect}" if scripts.empty?
if ARGV[2] == "every-job" && scripts.size != jobs.size
  raise "every job must carry a step named #{want.inspect}"
end
raise "#{want.inspect} must be one spelling, not per-job variants" unless scripts.uniq.size == 1
print scripts.first
' "$1" "$2" "${4:-}" > "$3"
}

# A bin/ directory holding ONLY the named tools, as stubs, plus the coreutils the
# harness-PATH step itself shells out to. Making it the step's whole world - both
# its ambient PATH and its seed - is what lets a tool be genuinely unreachable,
# which the real /usr/bin can never be made to be.
lfharness_bin() {  # <dir> <tool>...
  local dir=$1 tool real shell
  shift
  mkdir -p "$dir"
  shell=$(command -v bash) || fail "bash must be resolvable to stage the harness coreutils"
  for real in dirname tr sed grep printf env; do
    tool=$(command -v "$real" 2>/dev/null) || continue
    # A shell builtin resolves to a bare name with no binary behind it, and
    # neither a link nor a wrapper can stand in for one.
    case "$tool" in
      /*) ;;
      *) continue ;;
    esac
    # On Windows an MSYS binary finds msys-2.0.dll through PATH, so a symlink
    # reached through a PATH carrying only the link's own directory exits before
    # it runs; an exec wrapper keeps the real binary running from its own
    # directory. Same technique and reason as stage_tool_for_restricted_path in
    # tests/fm-windows-portability.test.sh and make_no_timeout_toolbin in
    # tests/fm-crew-state.test.sh.
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*)
        printf '#!%s\nexec "%s" "$@"\n' "$shell" "$tool" > "$dir/$real"
        chmod +x "$dir/$real"
        ;;
      *)
        ln -sf "$tool" "$dir/$real"
        ;;
    esac
  done
  for tool in "$@"; do
    printf '#!/usr/bin/env bash\necho %s stub\n' "$tool" > "$dir/$tool"
    chmod +x "$dir/$tool"
  done
}

test_windows_ci_harness_path_fails_on_an_unreachable_tool() {
  # .github/workflows/windows-ci.yml's "Resolve the test harness PATH" step
  # publishes FM_TEST_BASE_PATH, the only PATH 16 test files give the code under
  # test. If a runner-image move leaves a tool the suite asserts on unreachable
  # through that PATH, the lane runs against a machine the harness has
  # misdescribed and fails for the harness's reasons rather than the code's.
  #
  # Executes the step's REAL script under GitHub's own invocation
  # (`bash --noprofile --norc -eo pipefail`), so this pins behavior rather than
  # the text of the file.
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .github/workflows/windows-ci.yml as YAML"
  local tmp step out rc all bash_bin published
  all="git node gh jq perl"
  bash_bin=$(command -v bash) || fail "bash must be resolvable to run the extracted step"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-harnesspath.XXXXXX")
  step="$tmp/step.sh"
  workflow_step_script "$ROOT/.github/workflows/windows-ci.yml" \
    "Resolve the test harness PATH" "$step" \
    || { rm -rf "$tmp"; fail "could not extract the harness PATH step from windows-ci.yml"; }
  [ -s "$step" ] || { rm -rf "$tmp"; fail "the extracted harness PATH step is empty"; }

  # Every asserted-on tool present: the step must succeed and publish the PATH.
  # shellcheck disable=SC2086 # deliberate word splitting of the tool list
  lfharness_bin "$tmp/full" $all
  set +e
  out=$(FM_HARNESS_PATH_SEED="$tmp/full" GITHUB_ENV="$tmp/env-full" \
    PATH="$tmp/full" "$bash_bin" --noprofile --norc -eo pipefail "$step" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "a complete toolchain must pass the harness PATH step, got exit $rc: $out"; }
  published=$(cat "$tmp/env-full" 2>/dev/null || true)
  case "$published" in
    "FM_TEST_BASE_PATH=$tmp/full"*) : ;;
    *) rm -rf "$tmp"; fail "a passing step must publish FM_TEST_BASE_PATH seeded from the fixture, got: $published" ;;
  esac

  # THE REGRESSION. jq unreachable: the step used to print "UNREACHABLE" in its
  # table and exit 0 anyway, publishing a PATH it had just shown to be unusable.
  lfharness_bin "$tmp/nojq" git node gh perl
  set +e
  out=$(FM_HARNESS_PATH_SEED="$tmp/nojq" GITHUB_ENV="$tmp/env-nojq" \
    PATH="$tmp/nojq" "$bash_bin" --noprofile --norc -eo pipefail "$step" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || { rm -rf "$tmp"; fail "an unreachable asserted-on tool must fail the step, got exit 0: $out"; }
  case "$out" in
    *'::error::harness PATH cannot reach: jq'*) : ;;
    *) rm -rf "$tmp"; fail "the failure must name the unreachable tool, got: $out" ;;
  esac
  case "$out" in
    *"PATH was: $tmp/nojq"*) : ;;
    *) rm -rf "$tmp"; fail "the failure must print the PATH it built, got: $out" ;;
  esac
  [ ! -s "$tmp/env-nojq" ] \
    || { rm -rf "$tmp"; fail "a failing step must not publish FM_TEST_BASE_PATH, got: $(cat "$tmp/env-nojq")"; }

  # Two casualties: the complete table prints before the verdict, so one run
  # diagnoses the whole runner-image move rather than the first tool to break.
  lfharness_bin "$tmp/nogh" git node jq
  set +e
  out=$(FM_HARNESS_PATH_SEED="$tmp/nogh" GITHUB_ENV="$tmp/env-nogh" \
    PATH="$tmp/nogh" "$bash_bin" --noprofile --norc -eo pipefail "$step" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "two unreachable tools must fail the step, got exit 0: $out"; }
  case "$out" in
    *'::error::harness PATH cannot reach: gh perl'*) : ;;
    *) rm -rf "$tmp"; fail "the failure must name every unreachable tool, got: $out" ;;
  esac
  local tool
  for tool in $all; do
    case "$out" in
      *"$tool"*) : ;;
      *) rm -rf "$tmp"; fail "the reachability table must list $tool before the verdict, got: $out" ;;
    esac
  done

  rm -rf "$tmp"
  pass "windows-ci harness PATH step fails, and names the tools, when the built PATH cannot reach them"
}

test_aggregate_json() {
  local tmp a b
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  cat >"$tmp/a.json" <<'JSON'
{
  "run_id": "a",
  "selection": "lane=portable-parallel-1",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:01:00Z",
  "summary": {"total": 1, "failed": 0, "skipped_gate": 0, "duration_ms": 1000},
  "scripts": [{"path": "tests/a.test.sh", "family": "pure-contract-unit", "duration_ms": 1000, "exit": 0, "gate_skip": false}]
}
JSON
  cat >"$tmp/b.json" <<'JSON'
{
  "run_id": "b",
  "selection": "lane=portable-serial",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:02:00Z",
  "summary": {"total": 2, "failed": 1, "skipped_gate": 0, "duration_ms": 2000},
  "scripts": [
    {"path": "tests/b.test.sh", "family": "afk", "duration_ms": 1500, "exit": 1, "gate_skip": false},
    {"path": "tests/c.test.sh", "family": "afk", "duration_ms": 500, "exit": 0, "gate_skip": false}
  ]
}
JSON
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json")
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 total=3 failed=1" "aggregate summary line"
  "${FM_PYTHON3_CMD[@]}" -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["kind"]=="aggregate"
assert doc["summary"]["lanes"]==2
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==1
assert doc["summary"]["critical_path_duration_ms"]==2000
assert len(doc["scripts"])==3
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

# The Microsoft Store ships a `python3` alias that RESOLVES on PATH, prints an
# install advert, and exits 49. `command -v python3` therefore reported success
# and every subsequent call failed, which took out whole Windows runs rather than
# degrading - so the shared probe in bin/fm-python-lib.sh executes each
# candidate and asks for the major
# version. Both halves matter: `-c 'pass'` also succeeds under Python 2, and the
# timing payloads are Python-3-only.
#
# Reproducible on any host, which is why this is a real regression test and not a
# Windows-gated one: a stub that resolves and exits non-zero is the whole fixture.
# Measured against the pre-fix logic, `command -v python3` selects that stub and
# now_ms emits the advert TEXT where a millisecond count belongs.
#
# What this asserts is the INVARIANT, not one of the two legitimate outcomes,
# because which one you get depends on whether the host has a real `python` to
# fall back to: with an interpreter the artifact is written and valid, without one
# `--json` refuses by name (rc 2, "requires a working python3"). Both are correct.
# The defect being fenced out is the third possibility - trusting the broken
# interpreter, so the advert reaches the timing surface or a corrupt artifact is
# written - and every assertion below holds in either legitimate branch.
test_python3_probe_rejects_a_resolvable_but_broken_interpreter() {
  local tmp stub json out rc dur
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-py3probe.XXXXXX")
  stub="$tmp/stub"
  json="$tmp/timing.json"
  out="$tmp/out.txt"
  mkdir -p "$stub"
  cat >"$stub/python3" <<'SH'
#!/usr/bin/env bash
echo "Python was not found; run without arguments to install from the Microsoft Store."
exit 49
SH
  chmod +x "$stub/python3"
  cat >"$tmp/ok.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$tmp/ok.test.sh"

  set +e
  PATH="$stub:$PATH" "$RUNNER" --json "$json" "$tmp/ok.test.sh" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e

  # 1. The advert must never reach any output surface, whichever branch is taken.
  ! grep -qi 'Microsoft Store' "$out" \
    || { rm -rf "$tmp"; fail "the broken interpreter's output leaked into the timing stream"; }
  if [ -f "$json" ]; then
    ! grep -qi 'Microsoft Store' "$json" \
      || { rm -rf "$tmp"; fail "the broken interpreter's output leaked into the artifact"; }
  fi

  # 2. The suite itself still ran, and every duration it reported is an integer -
  #    which is precisely what the pre-fix probe turned into advert text.
  grep -q '^ok - fixture$' "$out" \
    || { rm -rf "$tmp"; fail "the fixture did not run: $(cat "$out")"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || { rm -rf "$tmp"; fail "END line has no integer duration_ms: $(grep '^FM_TEST_END' "$out")"; }
  grep -Eq '^FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=[0-9]+$' "$out" \
    || { rm -rf "$tmp"; fail "summary has no integer duration_ms: $(grep '^FM_TEST_SUMMARY ' "$out")"; }

  # 3. Exactly one of the two legitimate outcomes, and never a corrupt artifact.
  if [ "$rc" -eq 0 ]; then
    [ -f "$json" ] || { rm -rf "$tmp"; fail "runner reported success but wrote no artifact"; }
    dur=$(sed -n 's/.*"duration_ms"[[:space:]]*:[[:space:]]*\([0-9-]*\).*/\1/p' "$json" | head -1)
    case "$dur" in
      ''|*[!0-9]*) rm -rf "$tmp"; fail "artifact duration_ms is not a non-negative integer: '$dur'" ;;
    esac
  else
    grep -q 'requires a working python3' "$tmp/err.txt" \
      || { rm -rf "$tmp"; fail "refused for an unexplained reason (rc=$rc): $(cat "$tmp/err.txt")"; }
    [ ! -f "$json" ] \
      || { rm -rf "$tmp"; fail "refused to emit a valid artifact but left one behind"; }
  fi
  rm -rf "$tmp"
  pass "python3 probe rejects a resolvable but broken interpreter"
}

# Git Bash's default locale made `comm` reject input that `sort` had produced,
# because the two disagreed on collation - so every comm input and every comm in
# run_coverage_guard is pinned to LC_ALL=C.
#
# Honest limit, stated because it decides the shape of this test: the collation
# DIFFERENCE itself cannot be provoked on a host carrying only C, C.utf8 and
# POSIX, and installing a locale is not this suite's business. So rather than a
# test that would pass whether or not the pin exists - which is worse than no
# test - this executes the real guard through a recording `comm` on PATH and
# holds the invariant the fix actually established: no comm in the guard runs on
# an unpinned collation. Drop a single LC_ALL=C and this fails by name.
test_coverage_guard_pins_every_comm_to_a_c_collation() {
  local tmp stub log real unpinned n
  real=$(command -v comm) || fail "comm must be resolvable to test the coverage guard"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-commpin.XXXXXX")
  stub="$tmp/stub"
  log="$tmp/lc.log"
  mkdir -p "$stub"
  # Records the collation it was handed, then behaves exactly like comm so the
  # guard reaches its real verdict rather than being altered by observation.
  cat >"$stub/comm" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${LC_ALL-UNSET}" >>"$log"
exec "$real" "\$@"
SH
  chmod +x "$stub/comm"

  # LC_ALL deliberately unset in the parent, so an unpinned call records UNSET
  # instead of quietly inheriting a value that would mask the defect.
  env -u LC_ALL PATH="$stub:$PATH" "$RUNNER" --check-coverage >"$tmp/out.txt" 2>&1 \
    || { rm -rf "$tmp"; fail "coverage guard must pass: $(cat "$tmp/out.txt")"; }

  [ -s "$log" ] \
    || { rm -rf "$tmp"; fail "the guard invoked no comm at all - this test would prove nothing"; }
  n=$(grep -c . "$log")
  unpinned=$(grep -vFx 'C' "$log" | sort -u | tr '\n' ' ')
  [ -z "$unpinned" ] \
    || { rm -rf "$tmp"; fail "$n comm calls, some on an unpinned collation: $unpinned"; }
  rm -rf "$tmp"
  pass "coverage guard pins every comm to a C collation ($n calls)"
}

test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_changed_file_selection_is_conservative
test_changed_dependency_selection_and_unmapped_failure
test_changed_shared_python_library_selects_test_library_dependents
test_empty_selection_emits_summary
test_timing_markers_and_json
test_python3_probe_rejects_a_resolvable_but_broken_interpreter
test_coverage_guard_pins_every_comm_to_a_c_collation
test_aggregate_exit_behavior
test_gate_skip_accounting
test_fail_on_gate_skip_token
test_exclude_family
test_portable_shard_union_and_coverage_guard
test_portable_serial_shards_partition_the_serial_lane
test_unmeasured_serial_report_names_the_unhinted_script
test_portable_serial_shard_lane_refusals
test_windows_shard_lane_refusals
test_windows_coverage_report_counts_the_shipped_lane
test_unmeasured_windows_report_names_the_unhinted_member
test_windows_shards_must_cover_the_windows_lane
test_jobs_requires_proven_isolated
test_jobs_parallel_scheduler_and_failure_propagation
test_herdr_ci_family_run_has_a_step_timeout
test_windows_ci_lf_guard_never_reports_lf_without_a_clean_scan
test_windows_ci_lf_steps_refuse_an_unusable_cr_detector
test_windows_ci_harness_path_fails_on_an_unreachable_tool
test_aggregate_json
