#!/usr/bin/env bash
# Manual verification of the source-derived limitation recorded in
# docs/conpty-backend.md "Active limits" and cross-referenced from
# docs/windows.md "Run end to end on Windows": on the conpty backend the
# control plane refuses exit, relaunch and interrupt, even though the adapter
# itself classifies agent state and delivers Escape.
#
# Drives the REAL bin/fm-control.sh against a conpty-backed task record, with
# the repo's own sanctioned fake `node` client (tests/fm-backend-conpty.test.sh
# convention) standing in for the Windows daemon.
set -u
ROOT=${1:?usage: conpty-control-plane-check.sh <firstmate-checkout>}
CASE=$(mktemp -d)
trap 'rm -rf "$CASE"' EXIT

SESS=fmhome1-fm-t1
mkdir -p "$CASE/home/state/conpty/$SESS" "$CASE/fakebin" "$CASE/resp" "$CASE/wt" "$CASE/proj"

# fake node client: answers per client subcommand, records every call
cat > "$CASE/fakebin/node" <<'SH'
#!/usr/bin/env bash
set -u
{ printf '%s' "${2:-}"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FM_CONPTY_LOG"
cmd=${2:-}
[ -f "$FM_CONPTY_RESPONSES/$cmd.out" ] && cat "$FM_CONPTY_RESPONSES/$cmd.out"
exit 0
SH
chmod +x "$CASE/fakebin/node"
printf 'alive\n' > "$CASE/resp/state.out"     # recovery-grade classifier says the agent is running
printf '%s\n' "$SESS" > "$CASE/resp/exists.out"

cat > "$CASE/home/state/t1.meta" <<META
window=$SESS
conpty_session=$SESS
endpoint_task_id=t1
backend=conpty
worktree=$CASE/wt
project=$CASE/proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
META

run_control() {
  env PATH="$CASE/fakebin:$PATH" \
      FM_HOME="$CASE/home" FM_GATE_REFUSE_BYPASS=1 \
      FM_BACKEND_CONPTY_ALLOW_NON_WINDOWS=1 \
      FM_BACKEND_CONPTY_STATE="$CASE/home/state/conpty" \
      FM_CONPTY_LOG="$CASE/calls.log" FM_CONPTY_RESPONSES="$CASE/resp" \
      FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=0.05 \
      "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

hr() { printf '\n--- %s\n' "$1"; }

: > "$CASE/calls.log"
hr '$ fm-control.sh t1 exit          (backend=conpty)'
run_control t1 exit; printf '[exit code %s]\n' "$?"

: > "$CASE/calls.log"
hr '$ fm-control.sh t1 relaunch --note "resume the port check"'
run_control t1 relaunch --note 'resume the port check'; printf '[exit code %s]\n' "$?"

: > "$CASE/calls.log"
hr '$ fm-control.sh t1 interrupt     (agent classified alive by the conpty daemon)'
run_control t1 interrupt; printf '[exit code %s]\n' "$?"
printf 'client calls made while interrupting: %s\n' "$(cut -d$'\x1f' -f1 "$CASE/calls.log" | sort -u | tr '\n' ' ')"
printf 'keys delivered to the session: %s\n' "$(grep -c 'key' "$CASE/calls.log" || true)"

hr 'the same adapter, exercised directly: it DOES classify and DOES send Escape'
env PATH="$CASE/fakebin:$PATH" FM_HOME="$CASE/home" \
    FM_BACKEND_CONPTY_ALLOW_NON_WINDOWS=1 \
    FM_BACKEND_CONPTY_STATE="$CASE/home/state/conpty" \
    FM_CONPTY_LOG="$CASE/calls.log" FM_CONPTY_RESPONSES="$CASE/resp" \
    bash -c '
      set -u
      . "'"$ROOT"'/bin/fm-backend.sh"
      : > "$FM_CONPTY_LOG"
      printf "fm_backend_agent_state conpty %s -> %s\n" "'"$SESS"'" "$(fm_backend_agent_state conpty "'"$SESS"'")"
      if fm_backend_send_key conpty "'"$SESS"'" Escape fm-t1 >/dev/null 2>&1; then
        printf "fm_backend_send_key conpty %s Escape -> delivered\n" "'"$SESS"'"
      else
        printf "fm_backend_send_key conpty %s Escape -> FAILED\n" "'"$SESS"'"
      fi
      printf "client call for that key: %s\n" "$(grep -m1 key "$FM_CONPTY_LOG" | tr "\037" " ")"
    '
