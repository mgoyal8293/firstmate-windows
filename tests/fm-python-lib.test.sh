#!/usr/bin/env bash
# Contract tests for bin/fm-python-lib.sh - the single owner of "which Python 3
# actually runs here" - and for the call sites that used to answer that question
# with `command -v python3`.
#
# The whole fixture is one shim: a `python3` that RESOLVES on PATH, prints the
# Microsoft Store install advert, and exits 49. That is exactly what a stock
# Windows box ships as an app execution alias, and it reproduces on any host, so
# these are ordinary portable regressions and not Windows-gated ones.
#
# Every case below is falsifiable: put the presence check back and the case
# fails. `docs/verification/windows-python-probe.md` records that demonstration
# with its exact output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-python-lib.sh"
DOC_CHECK="$ROOT/bin/fm-doc-audience-check.sh"
ENSURE="$ROOT/bin/fm-ensure-agents-md.sh"
KIMI_HOOK="$ROOT/bin/fm-kimi-turnend-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-python-lib)

assert_present "$LIB" "bin/fm-python-lib.sh is missing"

fm_python3 || fail "these tests need a working python3 on the host"
# Absolute, because every fixture below shadows the interpreter's own name on
# PATH; a wrapper that re-invoked it by name would find the stub it is standing
# in for.
REAL_PY=("${FM_PYTHON3_CMD[@]}")
REAL_PY[0]=$(command -v "${REAL_PY[0]}") \
  || fail "could not resolve an absolute path for ${FM_PYTHON3_CMD[0]}"

STORE_ADVERT='Python was not found; run without arguments to install from the Microsoft Store, or disable this shortcut from Settings > Apps > Advanced app settings > App execution aliases.'

# store_stub <dir> <name>: the Microsoft Store app-execution alias, to the byte
# that matters - it resolves, it prints the advert, and it exits 49.
store_stub() {
  local dir=$1 name=$2
  mkdir -p "$dir"
  cat >"$dir/$name" <<SH
#!/usr/bin/env bash
echo '$STORE_ADVERT'
exit 49
SH
  chmod +x "$dir/$name"
}

# real_python_as <dir> <name> [<first-arg>]: the host's real interpreter under a
# different name, optionally requiring a leading argument the way the Windows
# \`py\` launcher requires \`-3\`.
real_python_as() {
  local dir=$1 name=$2 required=${3:-}
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    if [ -n "$required" ]; then
      # shellcheck disable=SC2016 # A printf FORMAT for the generated wrapper.
      printf '[ "${1:-}" = %q ] || { echo "py: no such option" >&2; exit 2; }\n' "$required"
      printf 'shift\n'
    fi
    printf 'exec'
    printf ' %q' "${REAL_PY[@]}"
    printf ' "$@"\n'
  } >"$dir/$name"
  chmod +x "$dir/$name"
}

python2_stub() {
  local dir=$1 name=$2
  mkdir -p "$dir"
  cat >"$dir/$name" <<'SH'
#!/usr/bin/env bash
# A Python 2: it starts, so `-c 'pass'` succeeds, but sys.version_info[0] is 2
# and every payload in this repo needs 3.
case "$*" in
  *"version_info[0] >= 3"*) exit 1 ;;
esac
exit 0
SH
  chmod +x "$dir/$name"
}

# broken_payload_python <dir> <name>: an interpreter that STARTS and reports
# major version 3, so the probe rightly accepts it, and then dies with an
# unexpected status on any real payload - a signal, or a broken stdlib on a
# half-installed Python. An interpreter that ran and answered nothing is not
# evidence about anything a caller asked.
broken_payload_python() {
  local dir=$1 name=$2
  mkdir -p "$dir"
  cat >"$dir/$name" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"version_info[0] >= 3"*) exit 0 ;;
esac
echo "Fatal Python error: init_import_site: failed to import the site module" >&2
exit 70
SH
  chmod +x "$dir/$name"
}

# crashing_payload_python <dir> <name>: an interpreter that clears the version
# probe - which needs only the builtin `sys` - and then dies with a traceback
# inside a real payload, so it exits 1 exactly like a payload that ran and
# answered "no". A status cannot tell those two apart; only the payload's own
# sentinel can.
crashing_payload_python() {
  local dir=$1 name=$2
  mkdir -p "$dir"
  cat >"$dir/$name" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"version_info[0] >= 3"*) exit 0 ;;
esac
cat >/dev/null
echo "Traceback (most recent call last):" >&2
echo "ModuleNotFoundError: No module named 'os'" >&2
exit 1
SH
  chmod +x "$dir/$name"
}

# chatty_payload_python <dir> <name>: an interpreter that clears the version
# probe and then exits 0 on a real payload while printing something that is not
# an answer - a wrapper's own banner, a truncated write, a blank line. Nothing
# failed, so no status can describe it; only the absent sentinel can.
chatty_payload_python() {
  local dir=$1 name=$2
  mkdir -p "$dir"
  cat >"$dir/$name" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"version_info[0] >= 3"*) exit 0 ;;
esac
cat >/dev/null
echo "pyenv: activating virtualenv"
exit 0
SH
  chmod +x "$dir/$name"
}

# probe_in <bindir>: run one fresh fm_python3 probe with <bindir> prepended,
# echoing the resolved command or REFUSED.
probe_in() {
  local bindir=$1
  # shellcheck disable=SC2016 # Deliberately expanded by the child shell, not here.
  PATH="$bindir:$PATH" "$(command -v bash)" -c '
    . "$1/bin/fm-python-lib.sh"
    if fm_python3; then printf "%s\n" "$FM_PYTHON3"; else printf "REFUSED\n"; fi
  ' _ "$ROOT"
}

# --- the probe itself -------------------------------------------------------

test_probe_rejects_the_store_stub_and_refuses_when_nothing_runs() {
  local bin resolved
  bin="$TMP_ROOT/only-stub"
  store_stub "$bin" python3
  store_stub "$bin" python
  store_stub "$bin" py
  resolved=$(probe_in "$bin")
  [ "$resolved" = REFUSED ] \
    || fail "a resolvable-but-broken python3 was accepted as an interpreter: '$resolved'"
  pass "the probe refuses a python3 that resolves on PATH and then exits 49"
}

test_probe_falls_through_the_store_stub_to_a_real_python() {
  local bin resolved
  bin="$TMP_ROOT/stub-plus-python"
  store_stub "$bin" python3
  real_python_as "$bin" python
  resolved=$(probe_in "$bin")
  [ "$resolved" = python ] \
    || fail "the probe should have fallen through the stub to python, got '$resolved'"
  pass "the probe falls through a broken python3 to a real python"
}

test_probe_resolves_the_multi_word_windows_launcher() {
  local bin resolved out
  bin="$TMP_ROOT/launcher-only"
  store_stub "$bin" python3
  store_stub "$bin" python
  real_python_as "$bin" py -3
  resolved=$(probe_in "$bin")
  [ "$resolved" = "py -3" ] \
    || fail "the probe should have resolved the multi-word launcher 'py -3', got '$resolved'"
  # And the resolved answer must be INVOKABLE as more than one word: a single
  # string would word-split by accident or run bare `py`, which is a different
  # interpreter selection.
  # shellcheck disable=SC2016 # Deliberately expanded by the child shell, not here.
  out=$(PATH="$bin:$PATH" "$(command -v bash)" -c '
    . "$1/bin/fm-python-lib.sh"
    fm_python3 || exit 1
    "${FM_PYTHON3_CMD[@]}" -c "print(\"LAUNCHER-RAN\")"
  ' _ "$ROOT")
  [ "$out" = LAUNCHER-RAN ] \
    || fail "the resolved multi-word launcher did not run: '$out'"
  pass "the probe resolves and can invoke a multi-word 'py -3' launcher"
}

test_probe_rejects_a_python_2() {
  local bin resolved
  bin="$TMP_ROOT/python2-only"
  store_stub "$bin" python3
  python2_stub "$bin" python
  store_stub "$bin" py
  resolved=$(probe_in "$bin")
  [ "$resolved" = REFUSED ] \
    || fail "a Python 2 was accepted, but every payload here needs Python 3: '$resolved'"
  pass "the probe rejects an interpreter that starts but reports major version 2"
}

test_resourcing_the_library_keeps_an_already_resolved_interpreter() {
  local bin out
  bin="$TMP_ROOT/resource-twice"
  store_stub "$bin" python3
  real_python_as "$bin" python
  # Two sources in one shell is the ordinary case, not a contrived one:
  # bin/backends/herdr.sh sources this library at adapter load inside a shell
  # whose caller already sourced and probed it. If the second source resets the
  # cache, the caller's "yes" answer expands to nothing and its first argument
  # runs as the command name.
  # shellcheck disable=SC2016 # Deliberately expanded by the child shell, not here.
  out=$(PATH="$bin:$PATH" "$(command -v bash)" -c '
    . "$1/bin/fm-python-lib.sh"
    fm_python3 || { printf "PROBE-FAILED\n"; exit 0; }
    . "$1/bin/fm-python-lib.sh"
    "${FM_PYTHON3_CMD[@]}" -c "print(\"SURVIVED\")"
  ' _ "$ROOT" 2>&1)
  [ "$out" = SURVIVED ] \
    || fail "re-sourcing the library lost the resolved interpreter: '$out'"
  pass "re-sourcing the library keeps an interpreter the shell already resolved"
}

test_clearing_the_probe_flag_still_forces_a_re_probe() {
  local first second out
  first="$TMP_ROOT/reprobe-first"
  second="$TMP_ROOT/reprobe-second"
  store_stub "$first" python3
  real_python_as "$first" python
  real_python_as "$second" python3
  # The re-source guard must protect the cache without freezing it: a test that
  # moves PATH under the library still has to be able to ask again.
  # shellcheck disable=SC2016 # Deliberately expanded by the child shell, not here.
  out=$(PATH="$first:$PATH" "$(command -v bash)" -c '
    . "$1/bin/fm-python-lib.sh"
    fm_python3 || exit 1
    printf "%s\n" "$FM_PYTHON3"
    PATH="$2:$PATH"
    FM_PYTHON3_PROBED=
    . "$1/bin/fm-python-lib.sh"
    fm_python3 || exit 1
    printf "%s\n" "$FM_PYTHON3"
  ' _ "$ROOT" "$second" 2>&1)
  [ "$out" = "python
python3" ] \
    || fail "clearing FM_PYTHON3_PROBED no longer forces a re-probe: '$out'"
  pass "clearing FM_PYTHON3_PROBED still forces a re-probe under a moved PATH"
}

test_refusal_names_the_candidates_and_the_store_alias() {
  local bin out
  bin="$TMP_ROOT/refusal-text"
  store_stub "$bin" python3
  store_stub "$bin" python
  store_stub "$bin" py
  # shellcheck disable=SC2016 # Deliberately expanded by the child shell, not here.
  out=$(PATH="$bin:$PATH" "$(command -v bash)" -c '
    . "$1/bin/fm-python-lib.sh"
    fm_python3 || fm_python3_refuse probe-test
  ' _ "$ROOT" 2>&1) || true
  assert_contains "$out" 'python3' "the refusal does not name the python3 candidate"
  assert_contains "$out" 'py -3' "the refusal does not name the py -3 candidate"
  assert_contains "$out" 'App execution aliases' \
    "the refusal does not tell a Windows reader why their on-PATH python3 is not one"
  pass "the refusal names every candidate tried and the Store-alias cause"
}

# --- the call sites ---------------------------------------------------------

test_doc_audience_check_refuses_instead_of_dying_on_the_stub() {
  local bin out rc=0
  bin="$TMP_ROOT/doc-check-stub"
  store_stub "$bin" python3
  store_stub "$bin" python
  store_stub "$bin" py
  out=$(PATH="$bin:$PATH" "$DOC_CHECK" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the documentation gate reported success with no interpreter at all"
  [ "$rc" -ne 49 ] \
    || fail "the documentation gate still dies with the Store stub's own exit 49"
  case "$out" in
    *"Microsoft Store"*"App execution aliases"*) ;;
    *) fail "the documentation gate's refusal is not actionable: $out" ;;
  esac
  assert_contains "$out" 'fm-doc-audience-check' \
    "the refusal does not say which command refused"
  pass "the documentation gate refuses with an actionable message instead of dying rc=49"
}

test_doc_audience_check_runs_when_only_python_is_real() {
  local bin out rc=0
  bin="$TMP_ROOT/doc-check-python"
  store_stub "$bin" python3
  real_python_as "$bin" python
  out=$(PATH="$bin:$PATH" "$DOC_CHECK" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "the documentation gate did not run behind a stubbed python3 (rc=$rc): $out"
  assert_contains "$out" 'fm-doc-audience-check: ok' \
    "the documentation gate did not report its normal ok line: $out"
  pass "the documentation gate runs when the only real interpreter is named python"
}

# fixture_pointer_worktree <dir>: an AGENTS.md plus a CLAUDE.md symlink that
# reaches it only through a path realpath must resolve - the exact case the
# interpreter is consulted for.
#
# Returns 1 when this filesystem cannot produce a real symlink. A stock Windows
# checkout is exactly that: `ln -s` there copies the target instead, and the
# `[ -L "$CLAUDE" ]` test at the top of is_correct_claude_symlink then short
# circuits, which is precisely why the defect this fences is LATENT on Windows
# until `core.symlinks` is enabled. Reporting that as a skip is honest; letting
# the fixture silently become two real files and asserting on the resulting
# unrelated conflict is not.
fixture_pointer_worktree() {
  local dir=$1
  mkdir -p "$dir/nested"
  printf '# Fixture\n' >"$dir/AGENTS.md"
  ln -s "nested/../AGENTS.md" "$dir/CLAUDE.md" 2>/dev/null || return 1
  [ -L "$dir/CLAUDE.md" ] || return 1
}

no_symlinks_note() {
  printf 'note: %s: this filesystem cannot create a real symlink, so the CLAUDE.md pointer case cannot be staged here (enable core.symlinks on Windows to exercise it)\n' \
    "$1" >&2
}

test_ensure_agents_md_does_not_read_a_dead_interpreter_as_a_wrong_pointer() {
  local bin dir out rc=0
  bin="$TMP_ROOT/ensure-stub"
  dir="$TMP_ROOT/ensure-wt"
  store_stub "$bin" python3
  real_python_as "$bin" python
  fixture_pointer_worktree "$dir" || {
    no_symlinks_note "correct-pointer case"
    return 0
  }
  out=$(PATH="$bin:$PATH" "$ENSURE" "$dir" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a correct CLAUDE.md pointer was rejected behind a stubbed python3 (rc=$rc): $out"
  case "$out" in
    *conflict*) fail "a correct pointer was reported as a conflict: $out" ;;
  esac
  pass "a correct CLAUDE.md pointer survives a python3 that resolves and then fails"
}

test_ensure_agents_md_reports_undeterminable_rather_than_a_false_conflict() {
  local bin dir out rc=0
  bin="$TMP_ROOT/ensure-none"
  dir="$TMP_ROOT/ensure-none-wt"
  store_stub "$bin" python3
  store_stub "$bin" python
  store_stub "$bin" py
  # No realpath either, so the question is genuinely unanswerable. The point of
  # the case is that an unanswerable question must not be answered "wrong
  # pointer".
  cat >"$bin/realpath" <<'SH'
#!/usr/bin/env bash
echo "realpath: unavailable in this fixture" >&2
exit 127
SH
  chmod +x "$bin/realpath"
  fixture_pointer_worktree "$dir" || {
    no_symlinks_note "undeterminable-pointer case"
    return 0
  }
  out=$(PATH="$bin:$PATH" "$ENSURE" "$dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unanswerable pointer question was reported as success: $out"
  case "$out" in
    *conflict*) fail "an unanswerable pointer question was reported as a conflict: $out" ;;
  esac
  assert_contains "$out" 'cannot determine' \
    "the refusal does not say the question could not be answered: $out"
  pass "an undeterminable CLAUDE.md pointer is reported as undeterminable, never as a conflict"
}

test_ensure_agents_md_asks_realpath_when_the_interpreter_answers_nothing() {
  local bin dir out rc=0
  bin="$TMP_ROOT/ensure-broken-payload"
  dir="$TMP_ROOT/ensure-broken-payload-wt"
  store_stub "$bin" python3
  broken_payload_python "$bin" python
  store_stub "$bin" py
  fixture_pointer_worktree "$dir" || {
    no_symlinks_note "interpreter-answered-nothing case"
    return 0
  }
  out=$(PATH="$bin:$PATH" "$ENSURE" "$dir" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a correct pointer was refused although realpath could answer it (rc=$rc): $out"
  case "$out" in
    *conflict*) fail "a correct pointer was reported as a conflict: $out" ;;
  esac
  pass "an interpreter that ran and answered nothing still lets realpath settle the pointer"
}

test_ensure_agents_md_names_the_interpreter_when_nothing_can_answer() {
  local bin dir out rc=0
  bin="$TMP_ROOT/ensure-broken-payload-no-realpath"
  dir="$TMP_ROOT/ensure-broken-payload-no-realpath-wt"
  store_stub "$bin" python3
  broken_payload_python "$bin" python
  store_stub "$bin" py
  cat >"$bin/realpath" <<'SH'
#!/usr/bin/env bash
echo "realpath: unavailable in this fixture" >&2
exit 127
SH
  chmod +x "$bin/realpath"
  fixture_pointer_worktree "$dir" || {
    no_symlinks_note "interpreter-answered-nothing refusal case"
    return 0
  }
  out=$(PATH="$bin:$PATH" "$ENSURE" "$dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unanswerable pointer question was reported as success: $out"
  case "$out" in
    *conflict*) fail "an unanswerable pointer question was reported as a conflict: $out" ;;
  esac
  assert_contains "$out" 'cannot determine' \
    "the refusal does not say the question could not be answered: $out"
  assert_contains "$out" 'exited with status 70' \
    "the refusal does not name the status the interpreter that ran died with: $out"
  assert_not_contains "$out" 'no working Python 3 found' \
    "the refusal blames a missing interpreter although one was found and ran: $out"
  pass "the refusal names the interpreter that ran instead of claiming none was found"
}

test_ensure_agents_md_does_not_invent_a_status_for_a_silent_payload() {
  local bin dir out rc=0
  bin="$TMP_ROOT/ensure-chatty-payload"
  dir="$TMP_ROOT/ensure-chatty-payload-wt"
  store_stub "$bin" python3
  chatty_payload_python "$bin" python
  store_stub "$bin" py
  cat >"$bin/realpath" <<'SH'
#!/usr/bin/env bash
echo "realpath: unavailable in this fixture" >&2
exit 127
SH
  chmod +x "$bin/realpath"
  fixture_pointer_worktree "$dir" || {
    no_symlinks_note "silent-payload refusal case"
    return 0
  }
  out=$(PATH="$bin:$PATH" "$ENSURE" "$dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unanswerable pointer question was reported as success: $out"
  case "$out" in
    *conflict*) fail "an unanswerable pointer question was reported as a conflict: $out" ;;
  esac
  assert_contains "$out" 'exited 0' \
    "the refusal does not say the interpreter exited cleanly: $out"
  assert_contains "$out" 'EQ or NE' \
    "the refusal does not say what answer was missing: $out"
  assert_not_contains "$out" 'exited with status' \
    "the refusal invents a failing exit status for an interpreter that exited 0: $out"
  assert_not_contains "$out" 'no working Python 3 found' \
    "the refusal blames a missing interpreter although one was found and ran: $out"
  pass "a payload that exits 0 without an answer is not reported as a failing exit status"
}

test_ensure_agents_md_does_not_read_a_crashed_payload_as_a_wrong_pointer() {
  local bin dir out rc=0
  bin="$TMP_ROOT/ensure-crashing-payload"
  dir="$TMP_ROOT/ensure-crashing-payload-wt"
  store_stub "$bin" python3
  crashing_payload_python "$bin" python
  store_stub "$bin" py
  fixture_pointer_worktree "$dir" || {
    no_symlinks_note "crashed-payload case"
    return 0
  }
  out=$(PATH="$bin:$PATH" "$ENSURE" "$dir" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a payload that crashed with status 1 was read as a wrong pointer (rc=$rc): $out"
  case "$out" in
    *conflict*) fail "a crashed comparison payload was reported as a conflict: $out" ;;
  esac
  pass "an exit status of 1 from a crashed payload is not read as evidence about the pointer"
}

test_herdr_workspace_mover_runs_through_the_resolved_interpreter() {
  local bin out rc=0
  bin="$TMP_ROOT/herdr-mover"
  store_stub "$bin" python3
  real_python_as "$bin" python
  # No override, so this is the repo's own mover, whose `#!/usr/bin/env python3`
  # shebang would find the Store stub and exit 49 - the interpreter the
  # workspace.move capability gate just rejected. Invoked with no arguments the
  # routed mover must reach the script's own argument check (exit 2) instead.
  # shellcheck disable=SC2016 # Deliberately expanded by the child shell, not here.
  out=$(PATH="$bin:$PATH" "$(command -v bash)" -c '
    unset FM_BACKEND_HERDR_WORKSPACE_MOVER
    . "$1/bin/backends/herdr.sh"
    fm_backend_herdr_workspace_mover_cmd || { printf "NO-INTERPRETER\n"; exit 1; }
    "${FM_BACKEND_HERDR_MOVER_CMD[@]}"
  ' _ "$ROOT" 2>&1) || rc=$?
  case "$out" in
    *"Microsoft Store"*)
      fail "the workspace mover ran under the Store stub its own capability gate rejects: $out"
      ;;
  esac
  [ "$rc" -ne 49 ] || fail "the workspace mover still dies with the Store stub's exit 49: $out"
  [ "$rc" -eq 2 ] \
    || fail "the routed workspace mover did not reach its own argument check (rc=$rc): $out"
  pass "the herdr workspace mover runs through the resolved interpreter, not its shebang"
}

test_kimi_hook_refuses_cleanly_on_the_stub() {
  local bin home out rc=0
  bin="$TMP_ROOT/kimi-stub"
  home="$TMP_ROOT/kimi-home"
  store_stub "$bin" python3
  store_stub "$bin" python
  store_stub "$bin" py
  mkdir -p "$home/.kimi-code"
  printf 'model = "test"\n' >"$home/.kimi-code/config.toml"
  out=$(HOME="$home" PATH="$bin:$PATH" "$KIMI_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the Kimi hook installed itself with no working interpreter"
  [ "$rc" -ne 49 ] || fail "the Kimi hook still dies with the Store stub's own exit 49"
  assert_contains "$out" 'refused' "the Kimi hook did not refuse by name: $out"
  case "$out" in
    *"Microsoft Store"*) ;;
    *) fail "the Kimi hook's refusal does not explain the on-PATH python3: $out" ;;
  esac
  cmp -s <(printf 'model = "test"\n') "$home/.kimi-code/config.toml" \
    || fail "the refused Kimi hook install changed the captain's config bytes"
  pass "the Kimi hook refuses cleanly, and writes nothing, when python3 is a Store stub"
}

test_probe_rejects_the_store_stub_and_refuses_when_nothing_runs
test_probe_falls_through_the_store_stub_to_a_real_python
test_probe_resolves_the_multi_word_windows_launcher
test_probe_rejects_a_python_2
test_resourcing_the_library_keeps_an_already_resolved_interpreter
test_clearing_the_probe_flag_still_forces_a_re_probe
test_refusal_names_the_candidates_and_the_store_alias
test_doc_audience_check_refuses_instead_of_dying_on_the_stub
test_doc_audience_check_runs_when_only_python_is_real
test_ensure_agents_md_does_not_read_a_dead_interpreter_as_a_wrong_pointer
test_ensure_agents_md_reports_undeterminable_rather_than_a_false_conflict
test_ensure_agents_md_asks_realpath_when_the_interpreter_answers_nothing
test_ensure_agents_md_names_the_interpreter_when_nothing_can_answer
test_ensure_agents_md_does_not_invent_a_status_for_a_silent_payload
test_ensure_agents_md_does_not_read_a_crashed_payload_as_a_wrong_pointer
test_herdr_workspace_mover_runs_through_the_resolved_interpreter
test_kimi_hook_refuses_cleanly_on_the_stub
