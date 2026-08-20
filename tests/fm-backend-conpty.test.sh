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
  # THE ARMING WIRE. Everything gap 2 reads off the pty depends on this one pair
  # of arguments reaching the spawn: without them the session shell emits no
  # prompt mark, liveness silently reverts to the screen fallback, and `exit`
  # goes back to refusing instead of proving a stop. Asserted against the args
  # the fake client actually received, and as an ADJACENT pair, because
  # `--rcfile` separated from its path would arm some other file.
  rcpath=$(fm_backend_conpty_winpath "$ROOT/bin/backends/conpty/fm-shell-integration.bash")
  us=$(printf '\x1f')
  assert_contains "$spawn_call" "$us--arg$us--rcfile$us--arg$us$rcpath$us" \
    "spawn armed the shell integration rcfile"
  pass "create_task spawns a home-scoped shell session and confirms it answers before reporting success"
) || exit 1

# The CR guard, read from the spawn it produces rather than from the source. A
# Windows checkout made with core.autocrlf=true rewrites the rcfile's line
# endings, and bash sourcing a CR-bearing file prints syntax errors into the
# very screen the composer classifier reads. No rcfile is the safe outcome, so
# the spawn must simply carry no --rcfile at all.
(
  CASE="$TMP_ROOT/create-rcfile-cr"; mkdir -p "$CASE"
  load_adapter "$CASE"
  FM_BACKEND_CONPTY_SHELL='C:\fake\bash.exe'

  # A CR-bearing copy of the tracked file, in a case-local root the adapter
  # resolves the rcfile from. Only the rcfile lookup reads this at call time.
  # awk, not `sed -i 's/$/\r/'`: bare -i and a \r replacement are both GNU
  # extensions, and on a BSD sed the copy would silently stay LF and fail this
  # case against a correct implementation.
  crorig="$ROOT/bin/backends/conpty/fm-shell-integration.bash"
  crcopy="$CASE/repo/bin/backends/conpty/fm-shell-integration.bash"
  awk '{ printf "%s\r\n", $0 }' "$crorig" > "$crcopy" \
    || fail "could not build the CR-bearing copy"
  # Self-check by BYTE COUNT: a CRLF copy is exactly one byte per line longer
  # than its LF original. Reading a line back and looking for the CR does not
  # work here - msys opens the file in text mode and strips it, so on Windows
  # that check reports "no CR" for a file od -c shows as CRLF and the case then
  # fails against a correct implementation. Not the implementation's own
  # `grep -Uq` predicate either, which would make this circular.
  crexpect=$(( $(wc -c < "$crorig") + $(wc -l < "$crorig") ))
  crgot=$(( $(wc -c < "$crcopy") ))
  [ "$crgot" -eq "$crexpect" ] \
    || fail "the copy is $crgot bytes, not the $crexpect a CRLF rewrite produces, so this case would prove nothing"
  FM_BACKEND_CONPTY_ROOT="$CASE/repo"

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

  fm_backend_conpty_create_task fm-crlf1 /tmp/proj >/dev/null || fail "create_task failed with a CR-bearing rcfile"
  spawn_call=$(calls_for spawn)
  [ -n "$spawn_call" ] || fail "no spawn reached the client"
  case "$spawn_call" in
    *--rcfile*) fail "a CR-bearing rcfile was still armed, so the session shell would source a file bash cannot parse" ;;
  esac
  assert_contains "$spawn_call" 'bash.exe' "the session still starts, unarmed, rather than failing the spawn"
  pass "create_task refuses to arm a CR-bearing rcfile and spawns the session unarmed instead"
) || exit 1

# The non-bash arm. An operator-pinned FM_BACKEND_CONPTY_SHELL that is not bash
# would reject --rcfile outright, so the flag must not be offered to it.
(
  CASE="$TMP_ROOT/create-rcfile-nonbash"; mkdir -p "$CASE"
  load_adapter "$CASE"
  FM_BACKEND_CONPTY_SHELL='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

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

  fm_backend_conpty_create_task fm-ps1 /tmp/proj >/dev/null || fail "create_task failed on a pinned non-bash shell"
  spawn_call=$(calls_for spawn)
  [ -n "$spawn_call" ] || fail "no spawn reached the client"
  case "$spawn_call" in
    *--rcfile*) fail "a bash-only flag was handed to a non-bash session shell" ;;
  esac
  pass "create_task does not offer --rcfile to a pinned non-bash session shell"
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

# --- liveness decision: the foreground source and its fallback ---------------
#
# The recovery-grade classifier's own decision table, exercised through
# bin/backends/conpty/fmpty-liveness.js with real node rather than through the
# daemon, which cannot run anywhere but Windows. `dead` and `missing` are the
# only verdicts that license recovery, so these cases deliberately drive the two
# sources apart and assert which one wins.
#
# The real-Windows evidence these portable cases stand in for is recorded in
# docs/verification/runtime-backends.md "conpty".
(
  CASE="$TMP_ROOT/liveness"; mkdir -p "$CASE"
  LIVENESS="$ROOT/bin/backends/conpty/fmpty-liveness.js"
  if ! command -v node >/dev/null 2>&1; then
    fail "node is absent, so the conpty liveness decision cannot be exercised"
  fi

  # verdict <json-facts> -> "<state>|<why>"
  verdict() {
    node -e '
      const l = require(process.argv[1]);
      const v = l.decideAgentState(JSON.parse(process.argv[2]));
      process.stdout.write(v.state + "|" + v.why);
    ' "$LIVENESS" "$1"
  }
  # facts <extra-json-fields> -> a complete fact object. Composed with printf
  # rather than by concatenating quoted fragments, so the quoting stays readable
  # and shellcheck can see it.
  facts() { printf '{"listAvailable":true,"listSource":"get-process",%s}' "$1"; }

  out=$(verdict '{"exited":{"exitCode":0}}')
  [ "${out%%|*}" = missing ] || fail "an exited pty child must be missing, got $out"
  out=$(verdict '{"listAvailable":false,"listSource":"timeout"}')
  [ "${out%%|*}" = unreadable ] || fail "an unreadable process list must not be a verdict, got $out"
  assert_contains "$out" 'timeout' "the unreadable reason names how the list failed"

  # THE CASE THE PROCESS LIST ALONE GETS WRONG. Identical process facts; the only
  # difference is the shell's own answer about the foreground. Both verdicts are
  # asserted, so this cannot go quietly vacuous if the marker source ever stops
  # arriving: with no marker an attached harness reads `alive`, with `at-prompt`
  # it reads `dead`, and that divergence IS the fidelity gap being closed.
  bg='"agentName":"claude.exe","sawShell":true'
  out=$(verdict "$(facts "$bg"',"prompt":"unknown","screen":"unknown"')")
  [ "${out%%|*}" = alive ] || fail "with no marker an attached harness stays alive, got $out"
  out=$(verdict "$(facts "$bg"',"prompt":"at-prompt"')")
  [ "${out%%|*}" = dead ] || fail "a harness attached while the shell is at a prompt is dead, got $out"
  assert_contains "$out" 'claude.exe' "the dead reason names the harness it decided against"
  assert_contains "$out" 'not in the foreground' "the dead reason states why that harness does not count"

  out=$(verdict "$(facts "$bg"',"prompt":"running"')")
  [ "${out%%|*}" = alive ] || fail "a harness with a foreground command running is alive, got $out"

  # No harness and the shell at a prompt is the postcondition bin/fm-control.sh
  # exit proves. It has to be reachable while other non-shell processes are still
  # attached to the console - a lingering harness child, a tool the operator
  # started - none of which is a shell-only process list.
  out=$(verdict "$(facts '"agentName":"","sawShell":true,"sawOther":true,"prompt":"at-prompt"')")
  [ "${out%%|*}" = dead ] || fail "an agent-free session at a prompt must be dead, got $out"

  # A foreground command with no recognised harness is NOT a stopped agent: it
  # could be an unrecognised harness build. Narrowing to ambiguous is what keeps
  # a duplicate agent off a live worktree.
  out=$(verdict "$(facts '"agentName":"","sawShell":true,"sawOther":true,"prompt":"running"')")
  [ "${out%%|*}" = ambiguous ] || fail "an unrecognised foreground command must be ambiguous, got $out"

  # The fallback table, reached only when no marker has ever arrived.
  out=$(verdict "$(facts '"agentName":"claude.exe","prompt":"unknown","screen":"shell"')")
  [ "${out%%|*}" = ambiguous ] || fail "a harness contradicted by the screen is ambiguous, got $out"
  out=$(verdict "$(facts '"agentName":"","sawShell":true,"sawOther":false,"prompt":"unknown","screen":"unknown"')")
  [ "${out%%|*}" = dead ] || fail "a shell-only list with no marker is dead, got $out"
  out=$(verdict "$(facts '"agentName":"","sawShell":true,"sawOther":false,"prompt":"unknown","screen":"agent"')")
  [ "${out%%|*}" = ambiguous ] || fail "a shell-only list the screen contradicts is ambiguous, got $out"
  out=$(verdict "$(facts '"agentName":"","sawShell":false,"sawOther":true,"prompt":"unknown","screen":"unknown"')")
  [ "${out%%|*}" = ambiguous ] || fail "a list that is neither harness nor shell-only is ambiguous, got $out"
  pass "conpty liveness: the shell's prompt mark settles the foreground, and silence falls back instead of inferring dead"

  # The marker state machine, fed the way the daemon feeds it: raw pty text in
  # arbitrary chunks.
  track() {
    node -e '
      const l = require(process.argv[1]);
      const t = l.createPromptTracker();
      for (const c of JSON.parse(process.argv[2])) t.feed(c);
      process.stdout.write(t.state() + "|" + t.lastMark() + "|" + t.marks());
    ' "$LIVENESS" "$1"
  }
  # The ESC is written as a JSON \u001b escape: a raw control byte is not legal
  # inside a JSON string, and the daemon's own feed is decoded text either way.
  out=$(track '["\u001b]133;C;fmpty=1\u0007"]')
  [ "$out" = 'running|C|1' ] || fail "a tagged C mark must read running, got $out"
  out=$(track '["\u001b]133;C;fmp","ty=1\u0007"]')
  [ "$out" = 'running|C|1' ] || fail "a mark split across chunks must still be read, got $out"
  out=$(track '["\u001b]133;C;fmpty=1\u0007","\u001b]133;D;0;fmpty=1\u001b\\"]')
  [ "$out" = 'at-prompt|D|2' ] || fail "a string-terminated D mark must read at-prompt, got $out"
  # An untagged mark is somebody else's. A harness announcing "command finished"
  # while it is itself alive is the one direction that could produce a false dead.
  out=$(track '["\u001b]133;C;fmpty=1\u0007","\u001b]133;D;0\u0007"]')
  [ "$out" = 'running|C|1' ] || fail "an untagged mark must be ignored, got $out"
  out=$(track '[""]')
  [ "$out" = 'unknown||0' ] || fail "a session with no mark must be unknown, got $out"
  pass "conpty liveness: the marker tracker reads split marks, both terminators, and ignores untagged ones"

  # The screen is the FALLBACK source, and it is a rendered-surface reading - what
  # it matches is what a vendor draws - so both of its reproduced defects are
  # pinned here rather than left to a single manual observation.
  screen() {
    node -e '
      const l = require(process.argv[1]);
      process.stdout.write(l.classifyScreenRows(JSON.parse(process.argv[2])));
    ' "$LIVENESS" "$1"
  }
  out=$(screen '["johns@John MINGW64 /c/x","$ ",""]')
  [ "$out" = shell ] || fail "a bare shell prompt should read shell, got $out"
  # Blind on a sparse screen: the content sits at the TOP of the viewport, so a
  # fixed count of rows taken from the bottom is all blank. The rows below stand
  # in for a 40-row viewport holding three lines.
  sparse='["johns@John MINGW64 /c/x","$ ","","","","","","","","","","","","","","","","",""]'
  out=$(screen "$sparse")
  [ "$out" = shell ] || fail "a prompt near the top of an otherwise blank viewport should still read shell, got $out"
  # A prompt matched anywhere in a block: a leftover MINGW64 line in scrollback
  # must not make a session that is NOT at a prompt read as one. These rows carry
  # no agent glyph, so the agent arm cannot answer first and the shell arm is the
  # one under test: matching the block returns `shell` (the reproduced defect,
  # which narrows an attached harness from alive to ambiguous), matching the
  # bottom-most row alone returns `unknown`.
  out=$(screen '["johns@John MINGW64 /c/x","$ some-tool","working..."]')
  [ "$out" = unknown ] || fail "a prompt left in scrollback above a running command should not read shell, got $out"
  # And the agent's own bottom-most shape still wins over the same leftover line.
  out=$(screen '["johns@John MINGW64 /c/x","$ claude","starting","","❯  (esc to interrupt)"]')
  [ "$out" = agent ] || fail "an agent composer below a leftover prompt line should read agent, got $out"
  out=$(screen '["", "", ""]')
  [ "$out" = unknown ] || fail "a blank screen should read unknown, got $out"
  out=$(screen '["some output with no prompt and no composer"]')
  [ "$out" = unknown ] || fail "an unrecognisable screen should read unknown, got $out"
  pass "conpty liveness: the fallback screen reading survives a sparse viewport and a prompt left in scrollback"
) || exit 1

# --- shell integration: the marks, and the nested shell that must inherit them -
#
# bin/backends/conpty/fm-shell-integration.bash is bash, so its behaviour is
# portable and belongs in CI even though the daemon that reads its output is not.
# What matters here is not that the marks exist but WHERE they come from. The
# firstmate path keeps the agent in the shell this file arms - fm-spawn leases
# the worktree and `cd`s into it rather than letting `treehouse get` host the
# task in a subshell - and these cases pin that the innermost shell is always the
# one answering, including in a shell someone opens by hand, where a mark scheme
# that stopped at the outer shell would leave the last mark saying "a command is
# running" and no stop could ever be proven.
(
  CASE="$TMP_ROOT/shell-integration"; mkdir -p "$CASE"
  RC="$ROOT/bin/backends/conpty/fm-shell-integration.bash"
  H="$CASE/home"; mkdir -p "$H"

  # marks_from <script-fed-to-stdin> -> the tagged mark letters seen, in order.
  # A pipe-fed `bash -i` still prints prompts and still runs PS0 and
  # PROMPT_COMMAND, so the marks are observable with no pty involved.
  marks_from() {
    printf '%s' "$1" | env -i HOME="$H" PATH="$PATH" bash --rcfile "$RC" -i 2>&1 \
      | grep -ao '133;[A-D][^A-Za-z]*fmpty=1' | sed 's/^133;\([A-D]\).*/\1/' | tr -d '\n'
  }

  own=$(marks_from 'true
exit
')
  case "$own" in
    *C*) ;;
    *) fail "the armed shell emitted no command-start mark: '$own'" ;;
  esac
  case "$own" in
    *D*) ;;
    *) fail "the armed shell emitted no command-finished mark: '$own'" ;;
  esac
  pass "conpty shell integration: the armed shell marks both command start and the return to its prompt"

  # PS0 is printed straight to the pty, not handed to readline, so readline's
  # zero-width brackets are not stripped from it the way they are from PS1 -
  # they would reach the terminal, and the durable transcript, as SOH/STX on
  # every command start. Read off the bytes the shell actually emitted.
  raw=$(printf 'true\nexit\n' | env -i HOME="$H" PATH="$PATH" bash --rcfile "$RC" -i 2>&1)
  printf '%s' "$raw" | LC_ALL=C grep -aq $'133;C;fmpty=1\a' \
    || fail "the command-start mark never reached the stream, so this proves nothing"
  if printf '%s' "$raw" | LC_ALL=C grep -aq $'\x01\x1b]133;C'; then
    fail "the command-start mark is preceded by a literal SOH: PS0 does not strip readline's zero-width brackets"
  fi
  if printf '%s' "$raw" | LC_ALL=C grep -aq $'133;C;fmpty=1\a\x02'; then
    fail "the command-start mark is followed by a literal STX: PS0 does not strip readline's zero-width brackets"
  fi
  pass "conpty shell integration: the command-start mark writes no stray control bytes onto the pty"

  # THE DIVERGENCE. Same script twice; the only difference is whether the nested
  # shell inherits the two carriers. Asserting both sides is what stops this from
  # passing vacuously if the export is ever dropped: the nested shell's marks are
  # the ones that let a stop be proven on a real task.
  nested=$(marks_from 'bash -i
true
exit
exit
')
  stripped=$(marks_from 'env -u PS0 -u PROMPT_COMMAND bash -i
true
exit
exit
')
  [ "${#nested}" -gt "${#stripped}" ] \
    || fail "a nested shell added no marks (inherited '$nested' vs stripped '$stripped'), so the chain stops at the outer shell"
  case "$stripped" in
    *D*) ;;
    *) fail "the control case lost the outer shell's own marks too, so it proves nothing: '$stripped'" ;;
  esac
  pass "conpty shell integration: a nested shell continues the mark chain, and stops marking when the carriers are withheld"

  # SHELL is what any tool in the session opens a shell with - `treehouse get`
  # run by hand, and anything else that consults it. An absent or unusable value
  # is replaced, a working one is the operator's and is left alone.
  # Tagged and extracted, not read as the whole of stdout: a distribution's own
  # /etc/bash.bashrc may print a banner into an interactive shell, and this file
  # deliberately sources it.
  probe_shell() {  # <env-assignment>... -> the resulting SHELL
    # SC2016: the single quotes are deliberate - this is the child shell's
    # script, and $SHELL must expand there, not here.
    # shellcheck disable=SC2016
    env -i HOME="$H" PATH="$PATH" "$@" bash --rcfile "$RC" -ic 'printf "__FMSHELL__%s__\n" "$SHELL"' 2>/dev/null \
      | sed -n 's/.*__FMSHELL__\(.*\)__$/\1/p' | tail -1
  }
  out=$(probe_shell)
  case "$out" in
    */bash) ;;
    *) fail "an absent SHELL was not replaced with this shell, got '$out'" ;;
  esac
  out=$(probe_shell SHELL=/no/such/shell)
  case "$out" in
    */bash) ;;
    *) fail "an unresolvable SHELL was left in place, got '$out'" ;;
  esac
  # The consumer is a NATIVE Windows program that CreateProcesses the value, so
  # the question is whether a Windows executable image stands behind it, not
  # whether this msys bash could resolve it. Synthesised here rather than taken
  # from a Windows host, so the case runs anywhere: two bytes are all the probe
  # reads.
  pe="$CASE/captains-shell.exe"
  printf 'MZ' > "$pe"
  out=$(probe_shell SHELL="$pe")
  [ "$out" = "$pe" ] || fail "a value backed by a real executable image must be left alone, got '$out'"
  # msys resolves a bare name to <name>.exe implicitly and a native launcher does
  # not, so the probe has to look through that suffix too.
  out=$(probe_shell SHELL="${pe%.exe}")
  [ "$out" = "${pe%.exe}" ] || fail "a value whose .exe image exists must be left alone, got '$out'"
  # The direction `[ -x ]` got wrong: an executable shebang wrapper passes it,
  # but no native launcher can start a script.
  wrapper="$CASE/wrapper-shell"
  printf '#!/bin/sh\nexec /bin/sh "$@"\n' > "$wrapper"
  chmod +x "$wrapper"
  [ -x "$wrapper" ] || fail "the wrapper is not executable, so it does not stand in for the case"
  out=$(probe_shell SHELL="$wrapper")
  case "$out" in
    */bash) ;;
    *) fail "an executable shebang wrapper no native launcher can start was left in place, got '$out'" ;;
  esac
  pass "conpty shell integration: SHELL is repaired unless a real executable image stands behind it, so treehouse opens a shell it can actually start"

  # THE ARMING GUARD answers "has THIS shell armed", not "did an ancestor arm".
  # A shell someone opens by hand with this rcfile, whose own rc files wiped the
  # inherited carriers, must re-arm; an inherited guard would make it return
  # early and stay silent, defeating the self-healing the whole design leans on.
  # The carriers are withheld to stand in for rc files that overwrote them, and
  # the stripped run above is the control: same withholding, no re-source.
  rearmed=$(marks_from "env -u PS0 -u PROMPT_COMMAND bash --rcfile '$RC' -i
true
exit
exit
")
  [ "${#rearmed}" -gt "${#stripped}" ] \
    || fail "a hand-opened shell that re-sourced this file did not re-arm (re-sourced '$rearmed' vs stripped '$stripped')"

  # AND IT MUST NOT ARM TWICE. With the carriers inherited the mark is already
  # in this shell's PROMPT_COMMAND, so re-sourcing must add nothing: a second
  # copy would emit two D marks per prompt, one more per nesting level, doubling
  # the per-prompt bytes and inflating the promptMarks counter the live guard and
  # the recorded transcript counts read. Same script twice, the only difference
  # being whether the nested shell re-sources this file.
  plain=$(marks_from 'bash -i
true
exit
exit
')
  resourced=$(marks_from "bash --rcfile '$RC' -i
true
exit
exit
")
  [ "$(printf '%s' "$plain" | tr -cd D | wc -c)" = "$(printf '%s' "$resourced" | tr -cd D | wc -c)" ] \
    || fail "re-sourcing with the carriers already armed added marks (plain '$plain' vs re-sourced '$resourced')"
  pass "conpty shell integration: each carrier is armed idempotently, so a re-source heals a wiped one and duplicates nothing"
) || exit 1

pass "conpty adapter unit tests complete"
