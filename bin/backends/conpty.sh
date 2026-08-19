#!/usr/bin/env bash
# bin/backends/conpty.sh - the Windows ConPTY session-provider adapter
# (EXPERIMENTAL).
#
# Design and empirical basis: docs/conpty-backend.md, and the feasibility gate
# recorded in data/winfm-conpty-spike/report.md. This is the Windows answer to
# "there is no tmux here": a ConPTY session daemon plus a named-pipe control
# surface, standing in for the tmux server and the tmux binary respectively.
# Session provider ONLY - the worktree provider stays treehouse, exactly as for
# herdr, zellij and cmux.
#
# WHY A DAEMON. `CreatePseudoConsole` returns handles owned by the CALLING
# process and destroys the pseudoconsole when that process exits, taking the
# child with it. So firstmate cannot hold the ConPTY itself: the session would
# die with the first firstmate restart, which is the one thing a session
# provider must survive. One daemon per task owns the ConPTY and serves a
# newline-delimited-JSON protocol on `\\.\pipe\fmpty-<scoped-id>`. A named pipe
# is a MACHINE-SCOPED kernel object, not a process-local handle, so reattach
# after a restart is structural rather than a trick - and it is not
# node-specific either: the spike drove a live agent from PowerShell 5.1.
#
#   tmux client -> unix socket -> tmux server -> pty
#   this adapter -> named pipe -> session daemon -> ConPTY
#
# The daemon and its stateless client live in bin/backends/conpty/ (a node
# program, mirroring bin/backends/herdr-eventwait.py's precedent for a non-shell
# backend helper). Their runtime dependencies are pinned in that directory's
# package.json and are NOT vendored, because node-pty ships a platform-specific
# prebuilt binary; `npm install --omit=dev` there is part of setup.
#
# NO JSON PARSER IS REQUIRED. The client's `--plain` mode projects each answer
# to the one scalar this adapter needs, so unlike herdr/zellij/cmux this backend
# does not add a `jq` dependency to a Windows host.
#
# WHAT THIS ADAPTER GIVES THAT tmux DOES NOT:
#   - a direct busy measurement. The daemon sits on the pty byte stream, so
#     output activity is known continuously and for free; tmux has to infer it
#     by hashing pane content across polls (fm-watch.sh's "two consecutive
#     identical hashes").
#   - a durable byte transcript per session, which outlives both the screen
#     buffer and the daemon, and is the recovery artifact after a crash.
# And what it gives that only tmux otherwise gives: a TRUE cursor row, so this
# is the second backend (and the first non-tmux one) that can declare
# `cursor=1` to the shared composer classifier.
#
# HOW FOREGROUND SCOPING IS RECOVERED. tmux scopes liveness to the pane tty's
# FOREGROUND process group, which is how a harness-named process idling in the
# BACKGROUND of an otherwise idle pane still classifies `dead`. A ConPTY console
# has a process list and no foreground concept, so that set cannot be narrowed
# the same way - but the shell can be asked the same question directly. The
# session shell is launched with fm-shell-integration.bash as its rcfile, which
# has bash emit OSC 133 prompt marks; the daemon reads them off the pty stream it
# already parses and treats "the shell is at a prompt" as tmux treats a
# foreground group holding nothing but a shell. The rcfile exports its hooks, so
# the worktree provider's subshell - where a task's agent actually runs - keeps
# marking too; that is what makes the last mark the innermost shell's answer
# rather than a stale one from before `treehouse get`. A session that emits no
# mark - an older bash, or a non-bash session shell - falls back to the process
# list and the screen, never to a false `dead`.
#
# Requires: node (already a universal firstmate tool), the installed
# dependencies in bin/backends/conpty/node_modules, and a Windows host. The
# adapter refuses loudly rather than degrading when any of those is absent.

# FM_HOME fallback: every real caller sets FM_HOME as a global before sourcing
# fm-backend.sh (which sources this file); this exists only so this file's own
# unit tests, which source it directly, resolve sanely. Mirrors
# bin/backends/cmux.sh's and bin/backends/zellij.sh's identical fallback.
FM_BACKEND_CONPTY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_CONPTY_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_CONPTY_ROOT/bin/fm-backend-hometag-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_CONPTY_ROOT/bin/fm-composer-lib.sh"

# Overridable for the same reason FM_BACKEND_CONPTY_CLIENT is: a test needs to
# point the dependency probe at a fixture directory rather than at the running
# checkout's own bin/backends/conpty.
FM_BACKEND_CONPTY_DIR="${FM_BACKEND_CONPTY_DIR:-$FM_BACKEND_CONPTY_ROOT/bin/backends/conpty}"
FM_BACKEND_CONPTY_CLIENT="${FM_BACKEND_CONPTY_CLIENT:-$FM_BACKEND_CONPTY_DIR/fmpty.js}"

# Default geometry. 120x40 matches the spike's verified size and is wide enough
# that a harness composer is not wrapped into an ambiguous shape.
FM_BACKEND_CONPTY_COLS="${FM_BACKEND_CONPTY_COLS:-120}"
FM_BACKEND_CONPTY_ROWS="${FM_BACKEND_CONPTY_ROWS:-40}"
FM_BACKEND_CONPTY_SCROLLBACK="${FM_BACKEND_CONPTY_SCROLLBACK:-5000}"

# fm_backend_conpty_node: the node binary. Deliberately NOT hardcoded to
# `node.exe`: under Git Bash `node` resolves to the native Windows binary
# already, and a test harness may substitute its own.
fm_backend_conpty_node() {
  if [ -n "${FM_BACKEND_CONPTY_NODE:-}" ]; then
    printf '%s' "$FM_BACKEND_CONPTY_NODE"
    return 0
  fi
  command -v node >/dev/null 2>&1 || return 1
  printf 'node'
}

# fm_backend_conpty_winpath: translate a POSIX path into the Windows form the
# node binary actually understands. node.exe is a NATIVE Windows program: handed
# `/d/AI/x` it looks for a directory literally named `d` off the current drive
# root. Git Bash's own argument mangling is not a substitute - it is heuristic,
# it differs between MSYS builds, and it is disabled wholesale by this adapter
# (see fm_backend_conpty_client) precisely so message text is never mangled.
# Falls back to the input unchanged when no translator exists, which is the
# right answer on a host where the path is already native.
fm_backend_conpty_winpath() {  # <path>
  local p=$1
  [ -n "$p" ] || return 0
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$p" 2>/dev/null && return 0
  fi
  if command -v wslpath >/dev/null 2>&1; then
    wslpath -w "$p" 2>/dev/null && return 0
  fi
  printf '%s' "$p"
}

# fm_backend_conpty_state_dir: where the daemon keeps each session's durable
# record and transcript. Home-scoped so two firstmate homes never share a
# session directory, and overridable for tests.
fm_backend_conpty_state_dir() {
  printf '%s' "${FM_BACKEND_CONPTY_STATE:-$FM_HOME/state/conpty}"
}

# fm_backend_conpty_client: run the stateless client.
#
# MSYS2_ARG_CONV_EXCL='*' is load-bearing, not defensive clutter. Git Bash
# rewrites any argument that merely LOOKS like a POSIX path before handing it to
# a native binary, which would corrupt exactly the payloads that matter most
# here - a steer whose text contains `/usr/bin/x`, or a brief mentioning an
# absolute path. Every path this adapter passes is translated explicitly by
# fm_backend_conpty_winpath instead, so turning the heuristic off loses nothing
# and removes a whole class of silent message corruption.
fm_backend_conpty_client() {  # <client-args...>
  local node state
  node=$(fm_backend_conpty_node) || return 1
  state=$(fm_backend_conpty_winpath "$(fm_backend_conpty_state_dir)")
  MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 \
    "$node" "$(fm_backend_conpty_winpath "$FM_BACKEND_CONPTY_CLIENT")" \
    "$@" --state "$state"
}

fm_backend_conpty_tool_check() {
  local node
  node=$(fm_backend_conpty_node) || {
    echo "error: backend=conpty selected but 'node' is not on PATH (required to run the ConPTY session daemon)" >&2
    return 1
  }
  [ -f "$FM_BACKEND_CONPTY_CLIENT" ] || {
    echo "error: backend=conpty selected but the session client is missing at $FM_BACKEND_CONPTY_CLIENT" >&2
    return 1
  }
  [ -d "$FM_BACKEND_CONPTY_DIR/node_modules/node-pty" ] || {
    echo "error: backend=conpty selected but its runtime dependencies are not installed; run 'npm install --omit=dev' in $FM_BACKEND_CONPTY_DIR (see docs/conpty-backend.md 'Setup')" >&2
    return 1
  }
  return 0
}

# fm_backend_conpty_platform_check: refuse on a non-Windows host instead of
# failing later with a confusing pty error. ConPTY is a Windows kernel facility;
# there is no partial support to degrade into.
fm_backend_conpty_platform_check() {
  case "$(uname -s 2>/dev/null || printf unknown)" in
    CYGWIN*|MINGW*|MSYS*|Windows_NT) return 0 ;;
  esac
  if [ -n "${FM_BACKEND_CONPTY_ALLOW_NON_WINDOWS:-}" ]; then
    return 0
  fi
  echo "error: backend=conpty requires a Windows host (ConPTY is a Windows facility); use tmux on Linux/macOS" >&2
  return 1
}

# fm_backend_conpty_version_check: prove the daemon's dependencies actually load
# before a spawn commits to them, rather than discovering it in a detached
# process whose stderr nobody is reading.
fm_backend_conpty_version_check() {
  local node out
  fm_backend_conpty_tool_check || return 1
  node=$(fm_backend_conpty_node) || return 1
  out=$(MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 \
    "$node" "$(fm_backend_conpty_winpath "$FM_BACKEND_CONPTY_CLIENT")" doctor 2>&1) || {
    echo "error: backend=conpty dependencies failed to load: $out" >&2
    echo "hint: run 'npm install --omit=dev' in $FM_BACKEND_CONPTY_DIR" >&2
    return 1
  }
  [ "$out" = ok ] || { echo "error: backend=conpty dependency check returned '$out'" >&2; return 1; }
  return 0
}

# fm_backend_conpty_container_ensure: the spawn-time preflight. There is no
# server to stand up - unlike tmux/herdr/zellij, each task's daemon IS its own
# container, and the named pipe that addresses it is created by that daemon. So
# this only proves the host can run one. Nothing to echo.
fm_backend_conpty_container_ensure() {
  fm_backend_conpty_platform_check || return 1
  fm_backend_conpty_version_check || return 1
  mkdir -p "$(fm_backend_conpty_state_dir)" 2>/dev/null || {
    echo "error: could not create the conpty session state directory $(fm_backend_conpty_state_dir)" >&2
    return 1
  }
  return 0
}

# fm_backend_conpty_home_label / fm_backend_conpty_scoped_id: the Windows named
# pipe namespace is MACHINE-GLOBAL - one flat namespace shared by every process
# and every logon session, verified directly by listing `\\.\pipe\` from an
# unrelated process. Two firstmate homes that both spawn a task called `crew1`
# would therefore contend for one pipe, and the loser's client would silently
# drive the winner's agent. Scoping the pipe name by home is the same fix
# cmux/zellij apply to their shared title namespaces, and it carries the same
# caveat: relocating an install changes the tag and orphans its old pipes.
fm_backend_conpty_home_label() {
  fm_backend_hometag
}

fm_backend_conpty_scoped_id() {  # <fm-task-label>
  local label=$1 rest home
  home=$(fm_backend_conpty_home_label)
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$home" "$rest"
}

# fm_backend_conpty_shell: the shell the task session runs. A task session
# starts as a SHELL, not as the harness, for two reasons the tmux path gets for
# free: `treehouse get` has to run somewhere, and the cwd probe below needs a
# shell to answer it. Git Bash is preferred because firstmate's spawn-time
# commands are POSIX shell.
fm_backend_conpty_shell() {
  local c
  if [ -n "${FM_BACKEND_CONPTY_SHELL:-}" ]; then
    printf '%s' "$FM_BACKEND_CONPTY_SHELL"
    return 0
  fi
  for c in "$SYSTEMDRIVE/Program Files/Git/bin/bash.exe" \
           "/c/Program Files/Git/bin/bash.exe" \
           "C:/Program Files/Git/bin/bash.exe"; do
    [ -x "$c" ] && { fm_backend_conpty_winpath "$c"; return 0; }
  done
  if command -v bash >/dev/null 2>&1; then
    fm_backend_conpty_winpath "$(command -v bash)"
    return 0
  fi
  return 1
}

# fm_backend_conpty_shell_integration_rcfile: the tracked rcfile that makes the
# session shell announce whether it is at a prompt, as a Windows path, or
# nothing at all when it must not be used.
#
# It refuses on a CR-bearing copy rather than passing it to bash. A Windows
# checkout made with core.autocrlf=true rewrites this file's line endings, and a
# sourced bash file whose lines end in CR does not merely lose the marks - it
# fails mid-file and prints syntax errors into the session the composer
# classifier then reads. No rcfile is the safe outcome: liveness falls back to
# the reading this backend shipped with.
fm_backend_conpty_shell_integration_rcfile() {
  local rc="$FM_BACKEND_CONPTY_ROOT/bin/backends/conpty/fm-shell-integration.bash"
  [ -f "$rc" ] || return 1
  if LC_ALL=C grep -Uq $'\r' "$rc" 2>/dev/null; then
    return 1
  fi
  fm_backend_conpty_winpath "$rc"
}

# fm_backend_conpty_create_task: create the task's session, refusing an existing
# live one. The pipe doubles as the mutex (a second daemon on the same name gets
# EADDRINUSE), so this check is a clear error rather than the only thing
# standing between two daemons and one session id. Echoes the scoped session id,
# which IS the endpoint target.
fm_backend_conpty_create_task() {  # <label> <cwd> -> prints session id
  local label=$1 cwd=$2 sid shell out rc
  local -a rcargs=()
  sid=$(fm_backend_conpty_scoped_id "$label")
  if fm_backend_conpty_client exists --id "$sid" --plain >/dev/null 2>&1; then
    echo "error: conpty session '$sid' already exists" >&2
    return 1
  fi
  shell=$(fm_backend_conpty_shell) || {
    echo "error: backend=conpty could not find a bash for the task session; set FM_BACKEND_CONPTY_SHELL" >&2
    return 1
  }
  # Shell integration is added only for bash, and only as extra arguments: an
  # operator-pinned FM_BACKEND_CONPTY_SHELL that is not bash would reject
  # --rcfile outright, and a session that never gets the flag is exactly the
  # documented fallback rather than a failure.
  case "${shell##*[/\\]}" in
    bash|bash.exe)
      if rc=$(fm_backend_conpty_shell_integration_rcfile); then
        rcargs=(--arg --rcfile --arg "$rc")
      fi
      ;;
  esac
  out=$(fm_backend_conpty_client spawn --id "$sid" \
    --cmd "$shell" "${rcargs[@]+"${rcargs[@]}"}" --arg -i \
    --cwd "$(fm_backend_conpty_winpath "$cwd")" \
    --cols "$FM_BACKEND_CONPTY_COLS" --rows "$FM_BACKEND_CONPTY_ROWS" \
    --scrollback "$FM_BACKEND_CONPTY_SCROLLBACK" 2>&1) || {
    echo "error: conpty spawn failed for '$sid': $out" >&2
    return 1
  }
  # The launcher returns before the daemon has finished binding its pipe, so
  # confirm the session actually answers rather than reporting a success the
  # caller cannot then use.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if fm_backend_conpty_client exists --id "$sid" --plain >/dev/null 2>&1; then
      printf '%s' "$sid"
      return 0
    fi
    sleep 0.5
  done
  echo "error: conpty session '$sid' did not become reachable after spawn; see $(fm_backend_conpty_state_dir)/$sid/daemon.stderr" >&2
  return 1
}

# fm_backend_conpty_parse_target: a conpty target is the scoped session id
# itself - a single atom with no colon, unlike herdr/zellij/cmux composite ids.
# There is nothing to split, so this only validates.
fm_backend_conpty_parse_target() {  # <target>
  local target=$1
  case "$target" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  FM_BACKEND_CONPTY_SESSION=$target
  return 0
}

# fm_backend_conpty_target_ready: is the recorded endpoint live? This is a pipe
# ping, which is the strongest available check and involves NO pid: the daemon
# answers with the session id and a per-generation nonce, so a recycled pid can
# never impersonate a live session. When the caller knows the owning task label,
# a stale recorded target is refreshed from that label.
fm_backend_conpty_target_ready() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} expected_id
  fm_backend_conpty_parse_target "$target" || return 1
  if [ -n "$expected_label" ]; then
    expected_id=$(fm_backend_conpty_scoped_id "$expected_label")
    if [ "$expected_id" != "$FM_BACKEND_CONPTY_SESSION" ]; then
      # The recorded target does not belong to the task the caller named.
      # Adopting the label's own session is the recovery path; refusing outright
      # would strand a task whose meta predates a home-tag change.
      fm_backend_conpty_client exists --id "$expected_id" --plain >/dev/null 2>&1 || return 1
      FM_BACKEND_CONPTY_SESSION=$expected_id
      return 0
    fi
  fi
  fm_backend_conpty_client exists --id "$FM_BACKEND_CONPTY_SESSION" --plain >/dev/null 2>&1
}

# fm_backend_conpty_current_path: `#{pane_current_path}`'s analogue. Windows has
# no /proc/<pid>/cwd and reading another process's PEB needs native code, so
# there are two sources and both are used, cheapest first:
#
#   1. the OSC 0/2 title the shell already emits. Git Bash sends
#      `MINGW64:/d/path`, which the daemon parses passively for free. It goes
#      STICKY once a harness takes the title over - verified: after claude
#      started, the title became `* <answer text>` while the last shell-reported
#      path was still correctly retained. That is exactly why fm-spawn polls cwd
#      BEFORE launching the harness.
#   2. an active pwd probe, for any shell whose prompt does not set a title.
#      Mirrors the zellij/cmux marker-probe workaround. It WRITES to the
#      session, so it is only used when the passive source has nothing.
fm_backend_conpty_current_path() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} p out line
  local mb='__FM_CONPTY_CWD_BEGIN__' me='__FM_CONPTY_CWD_END__' in_block=0 chunk='' last=''
  fm_backend_conpty_target_ready "$target" "$expected_label" || return 0
  p=$(fm_backend_conpty_client cwd --id "$FM_BACKEND_CONPTY_SESSION" --plain 2>/dev/null) || p=
  if [ -n "$p" ]; then
    printf '%s' "$p"
    return 0
  fi
  fm_backend_conpty_send_text_line "$target" "printf '%s\\n' '$mb'; pwd; printf '%s\\n' '$me'" "$expected_label" || return 0
  sleep 0.3
  out=$(fm_backend_conpty_capture "$target" 200 "$expected_label") || return 0
  while IFS= read -r line; do
    if [ "$line" = "$mb" ]; then
      in_block=1
      chunk=''
      continue
    fi
    if [ "$line" = "$me" ]; then
      case "$chunk" in /*) last=$chunk ;; esac
      in_block=0
      continue
    fi
    [ "$in_block" -eq 1 ] && chunk="$chunk$line"
  done <<EOF
$out
EOF
  printf '%s' "$last"
}

# fm_backend_conpty_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately, matching every other backend's contract.
#
# The text goes through a FILE rather than argv. A Windows command line is
# length-bounded and its quoting rules are not the shell's, so a multi-line
# brief or a steer containing quotes is a portability trap on the argument path;
# a file has neither problem and costs one write.
fm_backend_conpty_send_literal() {  # <target> <text> [expected-label]
  local target=$1 text=$2 expected_label=${3:-} tf rc
  fm_backend_conpty_target_ready "$target" "$expected_label" || return 1
  tf=$(mktemp "${TMPDIR:-/tmp}/fm-conpty-send.XXXXXX") || return 1
  printf '%s' "$text" > "$tf" || { rm -f "$tf"; return 1; }
  fm_backend_conpty_client send --id "$FM_BACKEND_CONPTY_SESSION" \
    --text-file "$(fm_backend_conpty_winpath "$tf")" >/dev/null 2>&1
  rc=$?
  rm -f "$tf"
  return "$rc"
}

# fm_backend_conpty_normalize_key: map firstmate's key vocabulary onto the
# daemon's. The daemon already speaks tmux's own names for the keys firstmate
# uses, so this only normalizes the spellings callers vary on.
fm_backend_conpty_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'Enter' ;;
    Escape|escape|Esc|esc) printf 'Escape' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'C-c' ;;
    C-u|c-u|ctrl+u|Ctrl+u|Ctrl+U|ctrl-u) printf 'C-u' ;;
    C-d|c-d|ctrl+d|Ctrl+d|Ctrl+D|ctrl-d) printf 'C-d' ;;
    Tab|tab) printf 'Tab' ;;
    Space|space) printf 'Space' ;;
    BSpace|bspace|Backspace|backspace) printf 'BSpace' ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_backend_conpty_send_key() {  # <target> <key> [expected-label]
  local key
  fm_backend_conpty_target_ready "$1" "${3:-}" || return 1
  key=$(fm_backend_conpty_normalize_key "$2")
  fm_backend_conpty_client key --id "$FM_BACKEND_CONPTY_SESSION" --key "$key" >/dev/null 2>&1
}

fm_backend_conpty_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_conpty_send_literal "$1" "$2" "${3:-}" || return 1
  fm_backend_conpty_send_key "$1" Enter "${3:-}"
}

# fm_backend_conpty_capture: bounded plain-text capture with tmux's own
# `capture-pane -p -S -<lines>` semantics: <lines> rows of SCROLLBACK above the
# viewport top PLUS the whole viewport, not "the last <lines> rows".
#
# Note for callers reasoning about depth: while a harness holds the ALTERNATE
# screen (claude does), no scrollback exists to read - in xterm.js exactly as in
# a real terminal, and exactly as tmux behaves on an alt-screen pane. The
# session's durable transcript is the route to deeper history.
fm_backend_conpty_capture() {  # <target> <lines> [expected-label]
  local lines=${2:-0}
  fm_backend_conpty_target_ready "$1" "${3:-}" || return 1
  case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
  fm_backend_conpty_client capture --id "$FM_BACKEND_CONPTY_SESSION" --lines "$lines" 2>/dev/null
}

# fm_backend_conpty_composer_caps: static capability facts, not logic (the
# capability model is owned by bin/fm-composer-lib.sh).
#
# `styled=1 cursor=1` is the notable pair: this is the second backend able to
# declare both, and the first that is not tmux. It matters concretely - with a
# true cursor row the classifier anchors on the shape CONTAINING the cursor and
# can read a long wrapped composer line as genuine pending input, where a
# cursorless backend can only fall back to the bottom-most shape and refuse.
# `rows=0` because the styled capture is the whole visible screen, matching
# tmux's `-S 0 -E -`; the cursor row indexes into exactly those rows.
# `identity=0`: no pi-specific identity probe is wired yet, so the classifier's
# identity sentinel is collapsed to `unknown` below.
fm_backend_conpty_composer_caps() {
  printf 'styled=1\ncursor=1\nidentity=0\nrows=0\n'
}

# fm_backend_conpty_composer_read: one client call returning BOTH the cursor row
# and the styled screen, as "row on line 1, screen from line 2".
#
# One call and not two on purpose: a separate cursor read and screen read can
# straddle a redraw, and the classifier would then index a screen with a cursor
# row that belonged to a different frame - which is precisely how a composer
# verdict comes to describe the wrong shape.
fm_backend_conpty_composer_read() {  # <target> [expected-label]
  fm_backend_conpty_target_ready "$1" "${2:-}" || return 1
  fm_backend_conpty_client composer --id "$FM_BACKEND_CONPTY_SESSION" --plain 2>/dev/null
}

fm_backend_conpty_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local raw cy screen verdict
  raw=$(fm_backend_conpty_composer_read "$1" "${2:-}") || { printf 'unknown'; return 0; }
  [ -n "$raw" ] || { printf 'unknown'; return 0; }
  cy=${raw%%$'\n'*}
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  screen=${raw#*$'\n'}
  verdict=$(fm_composer_classify_screen "$(fm_backend_conpty_composer_caps)" "$screen" "$cy")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

fm_backend_conpty_composer_cursor_row() {  # <target> [expected-label]
  fm_backend_conpty_target_ready "$1" "${2:-}" || return 1
  fm_backend_conpty_client cursor --id "$FM_BACKEND_CONPTY_SESSION" --plain 2>/dev/null
}

# fm_backend_conpty_send_text_submit: type <text> once (raw, unsubmitted), then
# drive the shared verify-and-retry-Enter loop against the shared composer
# verdict. Retries the SUBMISSION only, never the text. Echoes the proof-carrying
# verdict; only exact `empty` confirms delivery.
fm_backend_conpty_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-}
  fm_backend_conpty_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_conpty_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_conpty_send_key fm_backend_conpty_composer_state \
    "$target" "$retries" "$sleep_s" "$expected_label"
}

# fm_backend_conpty_busy_state: a REAL busy signal, which tmux cannot offer. The
# daemon owns the pty stream, so it knows how long it has been since the session
# last produced output - a direct measurement rather than an inference from
# hashing pane content across polls. Prints busy|idle|unknown.
#
# The threshold is deliberately generous: a harness that has gone quiet mid-turn
# (waiting on a model response) must not read as idle, because `idle` is what
# licenses a caller to treat a turn as finished.
FM_BACKEND_CONPTY_IDLE_MS="${FM_BACKEND_CONPTY_IDLE_MS:-2000}"
fm_backend_conpty_busy_state() {  # <target>
  local raw age
  fm_backend_conpty_parse_target "$1" || { printf 'unknown'; return 0; }
  raw=$(fm_backend_conpty_client busy --id "$FM_BACKEND_CONPTY_SESSION" --plain 2>/dev/null) || { printf 'unknown'; return 0; }
  age=${raw##* }
  case "$age" in ''|*[!0-9-]*) printf 'unknown'; return 0 ;; esac
  [ "$age" -ge 0 ] || { printf 'unknown'; return 0; }
  if [ "$age" -lt "$FM_BACKEND_CONPTY_IDLE_MS" ]; then
    printf 'busy'
  else
    printf 'idle'
  fi
}

# fm_backend_conpty_agent_state: recovery-grade agent state. See
# bin/fm-backend.sh's fm_backend_agent_state for the shared vocabulary.
#
# The daemon owns the decision because it owns every source of evidence: the
# ConPTY console process list (with per-pid identity validated by name AND
# process start time, so a recycled pid cannot be reported as the agent), the
# session shell's own OSC 133 prompt marks - the FOREGROUND source, which is
# what scopes a reading to whoever actually holds the console - and the screen,
# which is only the FALLBACK, consulted when no mark has arrived (an unarmed or
# non-bash session shell). Only `dead` and `missing` license recovery, so every
# genuinely conflicting reading resolves to `ambiguous` instead - a false `dead`
# is the one outcome that can launch a duplicate agent onto a live worktree.
#
# A session whose pipe does not answer is classified from the DURABLE RECORD,
# not guessed: `crashed` and `clean` both mean the endpoint is authoritatively
# gone (`missing`), while an unreadable record stays `unreadable`.
fm_backend_conpty_agent_state() {  # <target>
  local target=$1 out health
  fm_backend_conpty_parse_target "$target" || { printf 'unreadable'; return 0; }
  out=$(fm_backend_conpty_client state --id "$FM_BACKEND_CONPTY_SESSION" --plain 2>/dev/null) || out=
  case "$out" in
    alive|dead|missing|ambiguous|unreadable)
      printf '%s' "$out"
      return 0
      ;;
  esac
  # `|| true`, never `|| health=`: the client deliberately exits nonzero for
  # every non-live health so a caller can use it as a test, so clobbering the
  # value on a nonzero exit throws away the very answer being asked for. That
  # bug reported a cleanly stopped session as `unreadable` instead of `missing`,
  # which silently withholds the recovery that `missing` is there to license.
  health=$(fm_backend_conpty_client health --id "$FM_BACKEND_CONPTY_SESSION" --plain 2>/dev/null) || true
  case "$health" in
    live) printf 'unreadable' ;;
    crashed|clean|absent) printf 'missing' ;;
    *) printf 'unreadable' ;;
  esac
}

# Backward-compatible three-state view. The detailed contract is owned by
# fm_backend_agent_state.
fm_backend_conpty_agent_alive() {  # <target>
  case "$(fm_backend_conpty_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_conpty_health: the crash-vs-clean-stop discrimination the other
# backends have no equivalent for. Prints live|crashed|clean|absent.
#
# It exists because "the endpoint does not answer" is three different situations
# and firstmate acts differently on each: a daemon that was asked to stop
# (`clean`) is ordinary teardown, while one that died unasked (`crashed`) means
# the ConPTY went with it and the session's transcript is the only surviving
# evidence of what the agent was doing.
fm_backend_conpty_health() {  # <target>
  fm_backend_conpty_parse_target "$1" || { printf 'absent'; return 0; }
  fm_backend_conpty_client health --id "$FM_BACKEND_CONPTY_SESSION" --plain 2>/dev/null || true
}

# fm_backend_conpty_transcript_path: the durable byte transcript for <target>.
# After a crash this is the recovery artifact - it holds every byte the agent
# ever printed, including history the screen buffer had already dropped and
# everything the alternate screen never kept at all.
fm_backend_conpty_transcript_path() {  # <target>
  fm_backend_conpty_parse_target "$1" || return 1
  printf '%s/%s/transcript.log' "$(fm_backend_conpty_state_dir)" "$FM_BACKEND_CONPTY_SESSION"
}

# fm_backend_conpty_kill: end the task's session, best-effort (mirrors every
# other backend's `kill ... || true` contract).
#
# The daemon's kill iterates the CONSOLE process set rather than the process
# tree, and that is a correctness requirement rather than an implementation
# detail: the spike proved `claude.exe` is attached to the pty console while NOT
# being a descendant of the daemon (its parent chain ran through an sh.exe that
# had already exited), so a parent-tree kill would leave the live agent behind.
# Verified here on a real session: daemon, shell and agent all reaped, zero
# orphans.
fm_backend_conpty_kill() {  # <target> [unused] [expected-label]
  local expected_label=${3:-}
  if [ -n "$expected_label" ]; then
    fm_backend_conpty_target_ready "$1" "$expected_label" || return 0
  else
    fm_backend_conpty_parse_target "$1" || return 0
  fi
  fm_backend_conpty_client kill --id "$FM_BACKEND_CONPTY_SESSION" >/dev/null 2>&1 || true
}

# fm_backend_conpty_list_live: recovery/orphan discovery. Lists every live
# session whose id is scoped to THIS firstmate home, discovered from the durable
# session directory and confirmed by an actual pipe ping - never from a stored
# pid, which Windows may have handed to a stranger. One
# "<session-id>\t<fm-id>" line per live task session.
fm_backend_conpty_list_live() {
  local dir home prefix entry sid plain
  dir=$(fm_backend_conpty_state_dir)
  [ -d "$dir" ] || return 0
  home=$(fm_backend_conpty_home_label)
  prefix="fm-$home-"
  for entry in "$dir"/"$prefix"*; do
    [ -d "$entry" ] || continue
    sid=$(basename "$entry")
    plain=${sid#"$prefix"}
    [ -n "$plain" ] || continue
    fm_backend_conpty_client exists --id "$sid" --plain >/dev/null 2>&1 || continue
    printf '%s\tfm-%s\n' "$sid" "$plain"
  done
}

# fm_backend_conpty_resolve_bare_selector: an ad hoc session name with no
# recorded task, resolved against the live inventory. Mirrors the tmux adapter's
# equivalent fallback.
fm_backend_conpty_resolve_bare_selector() {  # <name>
  local name=$1 sid label
  while IFS=$'\t' read -r sid label; do
    [ -n "$sid" ] || continue
    if [ "$label" = "$name" ] || [ "$label" = "fm-$name" ] || [ "$sid" = "$name" ]; then
      printf '%s' "$sid"
      return 0
    fi
  done <<EOF
$(fm_backend_conpty_list_live)
EOF
  echo "error: no conpty session named $name" >&2
  return 1
}
