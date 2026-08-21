#!/usr/bin/env bash
# tests/fm-backend-conpty.test.sh - fake-client unit tests for the Windows
# ConPTY session-provider adapter (bin/backends/conpty.sh), verified against
# real claude 2.1.220 on Windows 10.0.26200 with node-pty 1.1.0
# (docs/conpty-backend.md, docs/verification/runtime-backends.md "conpty").
#
# Convention mirrors tests/fm-backend-cmux.test.sh and
# tests/fm-backend-zellij.test.sh: a small LOG-based canned-response fake stands
# in for the real binary. Here the fake is `node`, because this adapter's whole
# runtime surface is one node client - which also means these tests run on any
# platform, with FM_BACKEND_CONPTY_ALLOW_NON_WINDOWS lifting only the host gate
# and nothing else.
#
# The real-Windows evidence that these fakes stand in for lives in
# docs/verification/runtime-backends.md; a fake can prove the adapter's own
# decisions, never ConPTY's behaviour.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-conpty-tests)

# make_node_fakebin: a `node` stub that records every invocation (one line,
# unit-separated args) and answers from $FM_CONPTY_RESPONSES/<command>.out,
# keyed by the CLIENT SUBCOMMAND rather than by call order. Keying by name and
# not by an ordered queue is deliberate: this adapter calls `exists` as a
# readiness pre-flight before almost every other operation, so an ordered queue
# would make each test encode that call count and break whenever a pre-flight
# moved.
make_node_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/node" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_CONPTY_LOG:?}"
RESP="${FM_CONPTY_RESPONSES:?}"
# argv: <script> <command> [flags...]; the client script path is argv[1].
script=${1:-}
cmd=${2:-}
{
  printf '%s' "$script"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

if [ -f "$RESP/$cmd.exit" ]; then
  [ -f "$RESP/$cmd.out" ] && cat "$RESP/$cmd.out"
  exit "$(cat "$RESP/$cmd.exit")"
fi
if [ -f "$RESP/$cmd.out" ]; then
  cat "$RESP/$cmd.out"
  exit 0
fi
exit 0
SH
  chmod +x "$fb/node"
  printf '%s' "$fb"
}

# load_adapter: source the adapter into THIS shell with a private home, a fake
# node on PATH, and the host gate lifted.
load_adapter() {  # <case-dir>
  local case_dir=$1 fb
  fb=$(make_node_fakebin "$case_dir")
  mkdir -p "$case_dir/home/state/conpty" "$case_dir/repo/bin/backends/conpty"
  export FM_CONPTY_LOG="$case_dir/calls.log"
  export FM_CONPTY_RESPONSES="$case_dir/resp"
  mkdir -p "$FM_CONPTY_RESPONSES"
  : > "$FM_CONPTY_LOG"
  export PATH="$fb:$PATH"
  export FM_ROOT_OVERRIDE="$ROOT"
  export FM_HOME="$case_dir/home"
  export FM_BACKEND_CONPTY_STATE="$case_dir/home/state/conpty"
  export FM_BACKEND_CONPTY_ALLOW_NON_WINDOWS=1
  # shellcheck source=bin/backends/conpty.sh
  . "$ROOT/bin/backends/conpty.sh"
}

# load_interface: source the shared dispatcher with a private home. Separate
# from load_adapter because these cases exercise bin/fm-backend.sh's own
# registration and endpoint validation, not the adapter's behaviour.
load_interface() {  # <case-dir>
  local case_dir=$1
  export FM_ROOT_OVERRIDE="$ROOT"
  export FM_HOME="$case_dir/home"
  mkdir -p "$FM_HOME"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
}

resp() {  # <command> <payload>
  printf '%s\n' "$2" > "$FM_CONPTY_RESPONSES/$1.out"
}
resp_exit() {  # <command> <code>
  printf '%s\n' "$2" > "$FM_CONPTY_RESPONSES/$1.exit"
}
calls_for() {  # <command> -> matching log lines
  grep -F "$(printf '\x1f')$1$(printf '\x1f')" "$FM_CONPTY_LOG" 2>/dev/null || true
}

# --- session-id scoping -----------------------------------------------------
(
  CASE="$TMP_ROOT/scoping"; mkdir -p "$CASE"
  load_adapter "$CASE"

  tag=$(fm_backend_conpty_home_label)
  [ -n "$tag" ] || fail "hometag is empty"
  scoped=$(fm_backend_conpty_scoped_id fm-crew1)
  [ "$scoped" = "fm-$tag-crew1" ] || fail "scoped id was '$scoped', expected 'fm-$tag-crew1'"
  # A bare label (no fm- prefix) must land on the same id, or a caller that
  # passed the short form would address a different pipe than one that did not.
  [ "$(fm_backend_conpty_scoped_id crew1)" = "$scoped" ] || fail "bare label did not scope identically"
  pass "session ids are scoped by firstmate home (the pipe namespace is machine-global)"
) || exit 1

# --- target parsing ---------------------------------------------------------
(
  CASE="$TMP_ROOT/parse"; mkdir -p "$CASE"
  load_adapter "$CASE"

  fm_backend_conpty_parse_target 'fm-firstmate-abc12345-crew1' || fail "rejected a valid target"
  [ "$FM_BACKEND_CONPTY_SESSION" = 'fm-firstmate-abc12345-crew1' ] || fail "did not set the session global"
  # A conpty target is ONE atom. Anything that could address a different pipe -
  # a colon, a path separator, a space, an empty value - is refused rather than
  # sanitized, because a silently rewritten id names some other session.
  # shellcheck disable=SC2016 # These are literal candidate ids, not expansions.
  for bad in '' 'a:b' 'a/b' 'a\b' 'a b' 'a;b' '../x' 'a$b'; do
    if fm_backend_conpty_parse_target "$bad"; then
      fail "accepted an invalid target: '$bad'"
    fi
  done
  pass "target parsing accepts one atom and refuses anything that could address another pipe"
) || exit 1

# --- host gate --------------------------------------------------------------
(
  CASE="$TMP_ROOT/platform"; mkdir -p "$CASE"
  load_adapter "$CASE"

  unset FM_BACKEND_CONPTY_ALLOW_NON_WINDOWS
  case "$(uname -s)" in
    CYGWIN*|MINGW*|MSYS*|Windows_NT)
      pass "host gate: running ON Windows, refusal path not applicable"
      ;;
    *)
      out=$(fm_backend_conpty_platform_check 2>&1) && fail "platform check passed on a non-Windows host"
      assert_contains "$out" "requires a Windows host" "platform refusal names the requirement"
      assert_contains "$out" "use tmux" "platform refusal names the alternative"
      pass "host gate refuses a non-Windows host loudly instead of failing later in a pty error"
      ;;
  esac
) || exit 1

# --- key vocabulary ---------------------------------------------------------
(
  CASE="$TMP_ROOT/keys"; mkdir -p "$CASE"
  load_adapter "$CASE"

  [ "$(fm_backend_conpty_normalize_key enter)" = Enter ] || fail "enter did not normalize"
  [ "$(fm_backend_conpty_normalize_key Escape)" = Escape ] || fail "Escape did not normalize"
  [ "$(fm_backend_conpty_normalize_key esc)" = Escape ] || fail "esc did not normalize"
  [ "$(fm_backend_conpty_normalize_key ctrl-c)" = C-c ] || fail "ctrl-c did not normalize"
  [ "$(fm_backend_conpty_normalize_key Ctrl+U)" = C-u ] || fail "Ctrl+U did not normalize"
  # An unrecognized key passes through untouched so the daemon, not this table,
  # owns the refusal - one vocabulary, one place to be wrong.
  [ "$(fm_backend_conpty_normalize_key F5)" = F5 ] || fail "unknown key was rewritten"
  pass "key vocabulary normalizes the spellings callers vary on and passes the rest through"
) || exit 1

# --- agent state ------------------------------------------------------------
(
  CASE="$TMP_ROOT/state"; mkdir -p "$CASE"
  load_adapter "$CASE"
  T=fm-firstmate-abc12345-crew1

  for v in alive dead missing ambiguous unreadable; do
    resp state "$v"
    got=$(fm_backend_conpty_agent_state "$T")
    [ "$got" = "$v" ] || fail "agent_state passed '$v' through as '$got'"
  done
  pass "agent_state passes the daemon's full recovery vocabulary through unchanged"

  # A malformed answer must never be trusted as a verdict.
  resp state 'wat'
  resp health 'live'
  [ "$(fm_backend_conpty_agent_state "$T")" = unreadable ] \
    || fail "an unrecognized state word did not degrade to unreadable"
  pass "an unrecognized state word degrades to unreadable, never to a recovery-licensing verdict"

  # No live pipe: the DURABLE RECORD decides. `crashed` and `clean` are both
  # authoritative absence (missing); only those two license recovery.
  #
  # The nonzero exit here is not incidental - the real client deliberately exits
  # 1 for EVERY non-live health so a caller can use it as a test. Modelling that
  # is what makes this case meaningful: an adapter that discards the value on a
  # nonzero exit reports a cleanly stopped session as `unreadable` and silently
  # withholds the recovery `missing` exists to license.
  resp_exit state 1
  : > "$FM_CONPTY_RESPONSES/state.out"
  resp_exit health 1
  for h in crashed clean absent; do
    resp health "$h"
    got=$(fm_backend_conpty_agent_state "$T")
    [ "$got" = missing ] || fail "health '$h' (exit 1, as the real client returns) produced '$got', expected missing"
  done
  rm -f "$FM_CONPTY_RESPONSES/health.exit"
  resp health 'live'
  [ "$(fm_backend_conpty_agent_state "$T")" = unreadable ] \
    || fail "a live pipe with an unreadable state must stay unreadable, not missing"
  pass "with no state answer the durable record decides even though the client exits nonzero, and a contradictory live pipe stays unreadable"

  [ "$(fm_backend_conpty_agent_state 'a:b')" = unreadable ] || fail "a malformed target was not unreadable"
  pass "a malformed target is unreadable, never dead"
) || exit 1

# --- agent_alive collapse ---------------------------------------------------
(
  CASE="$TMP_ROOT/alive"; mkdir -p "$CASE"
  load_adapter "$CASE"
  T=fm-firstmate-abc12345-crew1
  resp state alive;      [ "$(fm_backend_conpty_agent_alive "$T")" = alive ]  || fail "alive"
  resp state dead;       [ "$(fm_backend_conpty_agent_alive "$T")" = dead ]   || fail "dead"
  resp state missing;    [ "$(fm_backend_conpty_agent_alive "$T")" = dead ]   || fail "missing->dead"
  resp state ambiguous;  [ "$(fm_backend_conpty_agent_alive "$T")" = unknown ] || fail "ambiguous->unknown"
  resp state unreadable; [ "$(fm_backend_conpty_agent_alive "$T")" = unknown ] || fail "unreadable->unknown"
  pass "the three-state view collapses only authoritative absence to dead"
) || exit 1

# --- busy state -------------------------------------------------------------
(
  CASE="$TMP_ROOT/busy"; mkdir -p "$CASE"
  load_adapter "$CASE"
  T=fm-firstmate-abc12345-crew1

  resp busy '12345 40'
  [ "$(fm_backend_conpty_busy_state "$T")" = busy ] || fail "recent output did not read busy"
  resp busy '12345 9000'
  [ "$(fm_backend_conpty_busy_state "$T")" = idle ] || fail "quiet session did not read idle"
  # -1 is the daemon's "no output has ever arrived" sentinel; it is not an age,
  # so it must not be compared against the threshold as though it were one.
  resp busy '0 -1'
  [ "$(fm_backend_conpty_busy_state "$T")" = unknown ] || fail "the never-had-output sentinel was treated as an age"
  resp busy 'garbage'
  [ "$(fm_backend_conpty_busy_state "$T")" = unknown ] || fail "unparsable busy output was not unknown"
  pass "busy state is a direct output-age measurement with an explicit unknown"
) || exit 1

# --- composer: one read, cursor row and screen together ---------------------
(
  CASE="$TMP_ROOT/composer"; mkdir -p "$CASE"
  load_adapter "$CASE"
  T=fm-firstmate-abc12345-crew1

  caps=$(fm_backend_conpty_composer_caps)
  assert_contains "$caps" 'styled=1' "the styled capability is declared"
  assert_contains "$caps" 'cursor=1' "the true cursor row is declared"
  assert_contains "$caps" 'identity=0' "no identity probe is claimed"
  assert_contains "$caps" 'rows=0' "the capture is the whole visible screen, as tmux does"
  pass "capability descriptor declares styled + true cursor (the first non-tmux backend able to)"

  # The daemon answers "cursor row on line 1, styled screen from line 2". A
  # single read is what keeps the row and the screen from straddling a redraw.
  { printf '1\n'; printf 'header\n'; printf '\xe2\x9d\xaf Reply with this\n'; printf 'footer\n'; } \
    > "$FM_CONPTY_RESPONSES/composer.out"
  v=$(fm_backend_conpty_composer_state "$T")
  [ "$v" = pending ] || fail "typed text under the cursor classified '$v', expected pending"

  { printf '1\n'; printf 'header\n'; printf '\xe2\x9d\xaf\n'; printf 'footer\n'; } \
    > "$FM_CONPTY_RESPONSES/composer.out"
  v=$(fm_backend_conpty_composer_state "$T")
  [ "$v" = empty ] || fail "an empty agent composer classified '$v', expected empty"
  pass "composer verdicts come from the shared classifier, cursor-anchored"

  # A non-numeric or absent cursor row must refuse, never guess: indexing a
  # screen with a bad row silently describes the wrong shape.
  { printf 'NaN\n'; printf '\xe2\x9d\xaf x\n'; } > "$FM_CONPTY_RESPONSES/composer.out"
  [ "$(fm_backend_conpty_composer_state "$T")" = unknown ] || fail "a non-numeric cursor row did not refuse"
  : > "$FM_CONPTY_RESPONSES/composer.out"
  [ "$(fm_backend_conpty_composer_state "$T")" = unknown ] || fail "an empty composer read did not refuse"
  pass "an unusable cursor row refuses loudly instead of classifying the wrong shape"

  n=$(calls_for composer | wc -l)
  [ "$n" -ge 1 ] || fail "the composer read never reached the client"
  assert_contains "$(calls_for composer)" '--plain' "the composer read uses the plain projection (no JSON parser needed)"
  pass "the composer is read in ONE client call, so the row and screen cannot straddle a redraw"
) || exit 1

# --- create_task ------------------------------------------------------------
(
  CASE="$TMP_ROOT/create"; mkdir -p "$CASE"
  load_adapter "$CASE"
  FM_BACKEND_CONPTY_SHELL='C:\fake\bash.exe'

  # exists succeeds => a live session already owns this id.
  resp exists 'present'
  out=$(fm_backend_conpty_create_task fm-dup /tmp/proj 2>&1) && fail "create_task did not refuse a live duplicate"
  assert_contains "$out" 'already exists' "duplicate refusal names the collision"
  [ -z "$(calls_for spawn)" ] || fail "create_task spawned despite the duplicate"
  pass "create_task refuses an existing live session before spawning anything"
) || exit 1

(
  CASE="$TMP_ROOT/create-ok"; mkdir -p "$CASE"
  load_adapter "$CASE"
  FM_BACKEND_CONPTY_SHELL='C:\fake\bash.exe'

  # First `exists` must fail (nothing live), later ones succeed (daemon bound).
  cat > "$CASE/fakebin/node" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_CONPTY_LOG:?}"
cmd=${2:-}
{ printf '%s' "${1:-}"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$LOG"
if [ "$cmd" = exists ]; then
  n=$(grep -c "$(printf '\x1f')exists$(printf '\x1f')" "$LOG")
  [ "$n" -gt 1 ] && { printf 'present\n'; exit 0; }
  printf 'absent\n'; exit 1
fi
exit 0
SH
  chmod +x "$CASE/fakebin/node"

  sid=$(fm_backend_conpty_create_task fm-new1 /tmp/proj) || fail "create_task failed on a free id"
  tag=$(fm_backend_conpty_home_label)
  [ "$sid" = "fm-$tag-new1" ] || fail "create_task returned '$sid'"
  spawn_call=$(calls_for spawn)
  [ -n "$spawn_call" ] || fail "no spawn reached the client"
  assert_contains "$spawn_call" "fm-$tag-new1" "spawn used the home-scoped id"
  assert_contains "$spawn_call" '--cols' "spawn passed a geometry"
  assert_contains "$spawn_call" '--state' "spawn passed the home-scoped state dir"
  # The session must start as a SHELL, not as the harness: treehouse get has to
  # run somewhere, and the cwd probe needs a shell to answer it.
  assert_contains "$spawn_call" 'bash.exe' "the task session starts as a shell"
  pass "create_task spawns a home-scoped shell session and confirms it answers before reporting success"
) || exit 1

# --- send path --------------------------------------------------------------
(
  CASE="$TMP_ROOT/send"; mkdir -p "$CASE"
  load_adapter "$CASE"
  T=fm-firstmate-abc12345-crew1
  resp exists 'present'

  # Text goes through a FILE, never argv: a Windows command line is
  # length-bounded and quotes differently from the shell, so a multi-line brief
  # on the argument path is a portability trap.
  # shellcheck disable=SC2016 # The literal $PATH is the payload under test.
  fm_backend_conpty_send_literal "$T" 'a "quoted" $PATH and /usr/bin/env' || fail "send_literal failed"
  send_call=$(calls_for send)
  assert_contains "$send_call" '--text-file' "literal text is passed by file"
  assert_not_contains "$send_call" '--text=' "literal text is not passed inline"
  assert_not_contains "$send_call" 'quoted' "the payload never appears on the command line"
  pass "literal text is delivered by file, so no payload is exposed to Windows command-line quoting"

  fm_backend_conpty_send_key "$T" enter || fail "send_key failed"
  assert_contains "$(calls_for key)" 'Enter' "send_key normalized and forwarded the key"
  pass "send_key normalizes then forwards"
) || exit 1

# --- capture ----------------------------------------------------------------
(
  CASE="$TMP_ROOT/capture"; mkdir -p "$CASE"
  load_adapter "$CASE"
  T=fm-firstmate-abc12345-crew1
  resp exists 'present'
  resp capture 'line one
line two'
  out=$(fm_backend_conpty_capture "$T" 40)
  assert_contains "$out" 'line two' "capture returned the screen"
  assert_contains "$(calls_for capture)" '40' "capture forwarded the requested scrollback depth"
  # A non-numeric depth must not reach the client as-is.
  fm_backend_conpty_capture "$T" 'bogus' >/dev/null
  assert_not_contains "$(calls_for capture | tail -1)" 'bogus' "a non-numeric depth was sanitized"
  pass "capture forwards a numeric scrollback depth and sanitizes anything else"
) || exit 1

# --- list_live --------------------------------------------------------------
(
  CASE="$TMP_ROOT/list"; mkdir -p "$CASE"
  load_adapter "$CASE"
  tag=$(fm_backend_conpty_home_label)
  mkdir -p "$FM_BACKEND_CONPTY_STATE/fm-$tag-alpha" \
           "$FM_BACKEND_CONPTY_STATE/fm-$tag-beta" \
           "$FM_BACKEND_CONPTY_STATE/fm-otherhome-gamma"
  resp exists 'present'
  out=$(fm_backend_conpty_list_live)
  assert_contains "$out" "fm-$tag-alpha"$'\t'"fm-alpha" "a live session of this home is listed"
  assert_contains "$out" "fm-$tag-beta"$'\t'"fm-beta" "every live session of this home is listed"
  assert_not_contains "$out" 'gamma' "another home's session is never claimed"
  pass "list_live is scoped to this firstmate home and confirmed by a live ping, never by a stored pid"

  # A directory whose pipe does not answer is a leftover, not a live session.
  resp_exit exists 1
  [ -z "$(fm_backend_conpty_list_live)" ] || fail "a stale session directory was reported live"
  pass "a leftover session directory with no answering pipe is not reported live"
) || exit 1

# --- kill -------------------------------------------------------------------
(
  CASE="$TMP_ROOT/kill"; mkdir -p "$CASE"
  load_adapter "$CASE"
  resp exists 'present'

  fm_backend_conpty_kill 'fm-firstmate-abc12345-crew1' || fail "kill returned nonzero"
  assert_contains "$(calls_for kill)" 'fm-firstmate-abc12345-crew1' "kill named the session"
  # Best-effort, exactly like every other backend's kill: a target that cannot
  # be parsed is not an error to abort teardown on, but it must not reach the
  # client either.
  : > "$FM_CONPTY_LOG"
  fm_backend_conpty_kill 'a:b' || fail "kill on a malformed target must stay best-effort"
  [ -z "$(calls_for kill)" ] || fail "a malformed target reached the client"
  pass "kill is best-effort and never forwards a target it could not parse"
) || exit 1

# --- endpoint validation (bin/fm-backend.sh's conpty arm) -------------------
(
  CASE="$TMP_ROOT/endpoint"; mkdir -p "$CASE"
  load_interface "$CASE"

  meta="$CASE/crew1.meta"
  fm_write_meta "$meta" \
    'window=fm-firstmate-abc12345-crew1' \
    'endpoint_task_id=crew1' \
    'worktree=/tmp/wt' \
    'project=/tmp/proj' \
    'backend=conpty' \
    'conpty_session=fm-firstmate-abc12345-crew1'
  fm_backend_validate_task_endpoint "$meta" crew1 || fail "a well-formed conpty endpoint was refused"
  [ "$FM_BACKEND_VALIDATED_BACKEND" = conpty ] || fail "validated backend was not conpty"
  [ "$FM_BACKEND_VALIDATED_TARGET" = 'fm-firstmate-abc12345-crew1' ] || fail "validated target was wrong"
  pass "a well-formed conpty endpoint validates and reports its backend and target"

  # window and conpty_session must agree: they are the same identifier, and a
  # disagreement means the record no longer describes one session.
  fm_write_meta "$meta" \
    'window=fm-firstmate-abc12345-crew1' \
    'endpoint_task_id=crew1' 'worktree=/tmp/wt' 'project=/tmp/proj' 'backend=conpty' \
    'conpty_session=fm-firstmate-abc12345-OTHER'
  out=$(fm_backend_validate_task_endpoint "$meta" crew1 2>&1) && fail "a mismatched session was accepted"
  assert_contains "$out" 'REFUSED' "the mismatch is refused"
  pass "a window that disagrees with conpty_session is refused, preserving task state"

  # A record belonging to another task must never be actioned as this one.
  fm_write_meta "$meta" \
    'window=fm-firstmate-abc12345-crew1' \
    'endpoint_task_id=someone-else' 'worktree=/tmp/wt' 'project=/tmp/proj' 'backend=conpty' \
    'conpty_session=fm-firstmate-abc12345-crew1'
  out=$(fm_backend_validate_task_endpoint "$meta" crew1 2>&1) && fail "another task's endpoint was accepted"
  assert_contains "$out" 'REFUSED' "a foreign task binding is refused"
  pass "an endpoint bound to another task is refused"

  fm_write_meta "$meta" \
    'window=fm-firstmate-abc12345-crew1' \
    'endpoint_task_id=crew1' 'worktree=/tmp/wt' 'project=/tmp/proj' 'backend=conpty'
  out=$(fm_backend_validate_task_endpoint "$meta" crew1 2>&1) && fail "a missing conpty_session was accepted"
  assert_contains "$out" 'REFUSED' "a missing session identifier is refused"
  pass "a conpty record with no session identifier is refused"
) || exit 1

# --- registration in the shared interface -----------------------------------
(
  CASE="$TMP_ROOT/registration"; mkdir -p "$CASE"
  load_interface "$CASE"

  fm_backend_is_known conpty || fail "conpty is not in the known backend set"
  fm_backend_validate conpty || fail "conpty does not validate"
  fm_backend_validate_spawn conpty || fail "conpty is not spawn-capable"
  # No jq: the client projects every answer this adapter reads to a plain
  # scalar, so a Windows host does not need a JSON parser installed.
  tools=$(fm_backend_required_tools conpty)
  assert_contains "$tools" 'treehouse' "treehouse remains the worktree provider"
  assert_not_contains "$tools" 'jq' "conpty requires no JSON parser"
  # conpty must never be auto-detected: there is no ambient session to detect.
  out=$(FM_BACKEND='' fm_backend_detect 2>/dev/null || true)
  [ "$out" != conpty ] || fail "conpty was auto-detected"
  # The dependency that is NOT a PATH command. `node` is universal and says
  # nothing about bin/backends/conpty/node_modules, so the flat tools list above
  # structurally cannot carry this and the sibling hook does.
  dep=$(fm_backend_required_dependency conpty) \
    || fail "conpty declares no non-PATH dependency"
  [ "$dep" = conpty-backend-deps ] || fail "unexpected conpty dependency name: $dep"
  fm_backend_required_dependency tmux >/dev/null 2>&1 \
    && fail "tmux must declare no non-PATH dependency"
  fm_backend_required_dependency_available tmux \
    || fail "a backend with no non-PATH dependency must read as available"
  pass "conpty is registered as a known, spawn-capable, explicitly-selected backend needing no JSON parser"
) || exit 1

pass "conpty adapter unit tests complete"
