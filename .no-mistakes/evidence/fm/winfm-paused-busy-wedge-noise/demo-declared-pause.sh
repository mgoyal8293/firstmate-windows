#!/usr/bin/env bash
# Evidence demo (test-phase harness; not tracked material): drive the REAL
# bin/fm-watch.sh over a simulated firstmate home and print what the captain
# actually experiences - supervisor wakes, the durable wake queue, and the
# watcher's triage log - for a worker that honestly declared a bounded wait
# while its harness is busy, and for workers that must still escalate.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-declared-pause-demo)

seen_sig() { stat -c '%s:%Y' "$1" 2>/dev/null; }
record_pi_busy() {
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" --source pi-ext --event agent-start
}
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Acknowledge one stopped watcher cycle exactly as the captain's re-arm does, so
# the NEXT poll round is not woken by the unrelated post-downtime resurface
# check. Mirrors tests/fm-watch-triage.test.sh's ack_stopped_cycle.
ack_stopped_cycle() {
  local state=$1 err sequence generation
  err="$state/.demo-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation"
}

hdr() { printf '\n================================================================\n%s\n================================================================\n' "$1"; }
sub() { printf '\n--- %s\n' "$1"; }

# build_worker <case> <id> <status line> -> echoes "<dir>|<state>|<fakebin>|<window>|<key>"
build_worker() {
  local case=$1 id=$2 status=$3 dir state fakebin window key
  dir=$(make_case "$case"); state="$dir/state"; fakebin="$dir/fakebin"
  window="fleet:$id"
  printf 'Running the release suite (output redirected to build.log)' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/$id.meta"
  record_pi_busy "$state" "$id" >/dev/null
  printf '%s\n' "$status" > "$state/$id.status"
  printf '%s' "$(seen_sig "$state/$id.status")" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "$(cat "$dir/pane.txt")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  touch -t 200001010000 "$state/$id.meta"   # no completed turn for >1h
  printf '%s\n' "$dir|$state|$fakebin|$window|$key"
}

# poll_once <dir> <state> <fakebin> <window> <key> <label>
# Ages the wedge timer past the 240s escalation threshold (i.e. ~4 minutes have
# passed with the pane rendering nothing), runs the real watcher, and reports
# whether the captain got woken.
RESURFACE=3600
poll_once() {
  local dir=$1 state=$2 fakebin=$3 window=$4 key=$5 label=$6 out pid
  out="$dir/watch.$label.out"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_BUSY_TURN_MAX_SECS=3600 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS="$RESURFACE" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  if wait_for_exit "$pid" 40; then
    printf 'poll %-8s -> SUPERVISOR WOKEN (watcher exited, costs a supervisor turn)\n' "$label"
    printf '              wake reason delivered: %s\n' "$(tr '\n' ' ' < "$out")"
    [ ! -s "$state/.wake-queue" ] ||
      printf '              queued for the captain: %s\n' "$(tr '\t' ' ' < "$state/.wake-queue")"
  else
    reap "$pid"
    printf 'poll %-8s -> absorbed, no wake (watcher still supervising; captain not interrupted)\n' "$label"
  fi
  ack_stopped_cycle "$state" >/dev/null 2>&1 || true
}

show_state() {  # <state> <key> <id>
  local state=$1 key=$2
  printf 'wedge escalation count for this worker: %s\n' "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)"
  if [ -s "$state/.watch-triage.log" ]; then
    printf 'watcher triage log:\n'; sed 's/^/    /' "$state/.watch-triage.log"
  fi
}

run_scenario() {  # <watcher-label> <case> <id> <status>
  local label=$1 case=$2 id=$3 status=$4 fields dir state fakebin window key
  fields=$(build_worker "$case" "$id" "$status")
  IFS='|' read -r dir state fakebin window key <<< "$fields"
  printf 'worker %s  harness=pi (busy: agent-start, no completed turn for >1h)\n' "$window"
  printf 'pane (frozen, nothing rendered): %s\n' "$(cat "$dir/pane.txt")"
  printf 'last status line the worker declared: %s\n\n' "$status"
  poll_once "$dir" "$state" "$fakebin" "$window" "$key" "t+4min"
  poll_once "$dir" "$state" "$fakebin" "$window" "$key" "t+8min"
  poll_once "$dir" "$state" "$fakebin" "$window" "$key" "t+12min"
  printf '\n'
  show_state "$state" "$key"
  printf '%s\n' "$state" > /tmp/nm-demo-last-state
}

printf 'firstmate declared-pause vs wedge-escalation: end-to-end watcher transcript\n'
printf 'date: %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')"
printf 'watcher under test: %s\n' "$(readlink -f "$WATCH")"
printf 'fleet knobs: FM_STALE_ESCALATE_SECS=240 (wedge timer), FM_PAUSE_RESURFACE_SECS=3600 (pause recheck),\n'
printf '             FM_BUSY_TURN_MAX_SECS=3600 (completed-turn bound)\n'

hdr "SCENARIO 1 - the measured defect: a worker that DECLARED a bounded external wait, harness busy"
run_scenario watcher busy-paused-demo ci-wait 'paused: waiting on the upstream CI run to finish (~40min)'

hdr "SCENARIO 2 - must still escalate: same frozen busy pane, NO declared wait"
run_scenario watcher busy-undeclared-demo frozen 'working: running the release suite'

hdr "SCENARIO 3 - must still escalate: the declaration is LIFTED while the pane stays frozen"
fields=$(build_worker busy-lifted-demo lifted 'paused: waiting on the upstream CI run to finish (~40min)')
IFS='|' read -r dir state fakebin window key <<< "$fields"
printf 'worker %s declared a wait, then the wait ended and the worker resumed logging work.\n\n' "$window"
poll_once "$dir" "$state" "$fakebin" "$window" "$key" "paused"
printf '\n... the wait ends: the worker resumes logging work, but its pane stays frozen ...\n\n'
printf 'working: resumed, applying the upstream fix\n' >> "$state/lifted.status"
printf '%s' "$(seen_sig "$state/lifted.status")" > "$state/.seen-lifted_status"
poll_once "$dir" "$state" "$fakebin" "$window" "$key" "lifted"
printf '              (pause tracking dropped; the ordinary wedge timer restarts here: .stale-since=%s)\n' \
  "$( [ -s "$state/.stale-since-$key" ] && echo running || echo missing)"
printf '\n... 4 more minutes of a frozen pane, now with no declaration standing ...\n\n'
poll_once "$dir" "$state" "$fakebin" "$window" "$key" "lifted+4min"
printf '\n'
show_state "$state" "$key"

hdr "SCENARIO 4 - absorbed, never silenced: the declared wait itself ages past the long recheck window"
fields=$(build_worker busy-recheck-demo ci-recheck 'paused: waiting on an upstream release to be published')
IFS='|' read -r dir state fakebin window key <<< "$fields"
# Backdate the declaration itself so the long PAUSE_RESURFACE window has elapsed.
touch -m -d "@$(( $(date +%s) - 500 ))" "$state/ci-recheck.status"
printf '%s' "$(seen_sig "$state/ci-recheck.status")" > "$state/.seen-ci-recheck_status"
printf 'worker %s has held the same declared wait for longer than the recheck window.\n\n' "$window"
RESURFACE=240
poll_once "$dir" "$state" "$fakebin" "$window" "$key" "recheck"
printf '\n... the captain confirms and re-arms; the wait is still standing ...\n\n'
poll_once "$dir" "$state" "$fakebin" "$window" "$key" "recheck+1"
RESURFACE=3600
printf '\n'
show_state "$state" "$key"
