#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed to this crew's branch, else the pane
# busy-signature) and reconciles the possibly-stale log against it. Code identity
# is a QUALIFIER on that run, not a precondition for reading it - see step 2.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|remote-endpoint|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind + delivery mode from
#      state/<id>.meta. A meta recording remote_host= is a remote secondmate:
#      its worktree and endpoint live on that host, so the local worktree and
#      pane reads are skipped and the remote host is asked for the endpoint's
#      recovery-grade state (fm-on.sh + fm-remote-secondmate-control.sh state).
#      alive falls through to the routed status log; dead/missing report the
#      remote verdict; an unreachable or unreadable remote reports
#      unknown-remote, never a false gone/dead.
#   2. Matching no-mistakes run for this crew? ONE candidate is considered - the
#      branch's newest run - and bin/fm-crew-run-verdict-lib.sh owns the whole
#      model: how that candidate is selected, what its code binding is allowed
#      to support, and which verdict its evidence settles. Read that file's
#      header before changing anything in this section; every rule there exists
#      because its absence produced a real wrong verdict in one of the two
#      unsafe directions. The run-step is AUTHORITATIVE once admitted:
#      running/fixing -> working, ci -> working, awaiting_approval/fix_review ->
#      parked (with gate findings), failed/cancelled -> failed, and
#      checks-passed -> done, since that word is itself a statement about the
#      checks - though green checks prove only that CI ran, so that arm still
#      asks the forge where the PR ended up: a confirmed close reads failed, and
#      an unconfirmed answer reads working for a crew the record still shows
#      executing and unknown for one that has terminated, since liveness is
#      established (crew_liveness) rather than assumed from the route
#      (fm_crew_checks_green_verdict). `passed` is not even that much: it says
#      only that the PIPELINE completed, so every
#      terminated run goes through one ranking (fm_crew_terminal_verdict) - a
#      forge-confirmed merge reads done whatever the ci step says, a
#      forge-confirmed close reads failed because a closed-unmerged PR is the
#      opposite of a landing, else this run's own `ci,completed` reads done
#      unless the forge answer is unconfirmed, else unknown, because a terminated
#      run whose validation cannot be established is exactly "I cannot tell", not
#      a gate anyone can respond to. The coarse
#      runs-list path carries no steps table at all, and passes that into the
#      same ranking as missing evidence rather than ranking the evidence a
#      second way. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see nm_ci_checks_state) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating. That
#      override answers to the same owner, so a closed PR reads failed there too.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this crew (pre-validation, or kind=scout): fall back to the
#      recorded backend's pane busy state, then the status log's last line only
#      when its verb maps to a recognized run-state. Decision-only events such as
#      `resolved` never become current state or detail. A `done:` verb there is a
#      landing claim like any other, so it asks the forge too - the invariant
#      below admits no exemption for the source of a claim.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log.
#
# Read-only: nothing here writes fleet state, and every command it runs is a
# query. Not process-free, though - at most ONE outbound `gh pr view` per
# invocation, bounded by FM_CREW_STATE_FORGE_TIMEOUT and skipped entirely when
# FM_CREW_STATE_NO_FORGE is truthy. Skipping does not merely weaken the detail:
# an unread merge state is an UNCONFIRMED answer, and no path resolves one to
# `done` (see the invariant below, and fm_crew_forge_answer_class for the split).
#
# THE FORGE-READ INVARIANT, owned here and pointed at from everywhere else that
# needs it. It is a rule about the CALL, not about the ANSWER and not about the
# word:
#
#   Every path that COULD emit `done` ASKS the forge first. No other path asks.
#
# Asking is not the same as being answered, and the invariant deliberately claims
# only the asking. A path that asked can still emit `done` on an answer that
# confirmed nothing - a provider with no client here, or a task with no PR at all
# - because those are gaps no read will ever close, and refusing forever is the
# worse failure. What such a path may NOT do is emit `done` while an answer
# exists that it simply does not have.
#
# Nor does the word tell you whether the call happened, and reading it that way
# is how an earlier wording of this paragraph came to be false: a path that asked
# can resolve to `failed` (the forge confirmed a close), to `working` (it did not
# answer, but the crew is demonstrably still monitoring) or to `unknown` (it did
# not answer and nothing else is known). Those words are PRODUCED by the call,
# not evidence that none was made. What is true is the converse - a crew whose
# state could never be `done` never asks, so a routine heartbeat over a crew that
# is validating, parked at a gate, or already failed on its own outcome makes no
# forge call at all.
#
# The paths that can emit `done`, all eight of which ask:
#   1. full path, `outcome: checks-passed`      -> fm_crew_checks_green_verdict
#   2. full path, `outcome: passed`             -> fm_crew_terminal_verdict
#   3. full path, `status: completed`           -> fm_crew_terminal_verdict
#   4. full path, ci step running + green log   -> fm_crew_checks_green_verdict
#   5. coarse runs-list `completed` row         -> fm_crew_terminal_verdict
#   6. coarse path, ci-ready status log         -> fm_crew_checks_green_verdict
#   7. full path, ci-ready status log           -> fm_crew_checks_green_verdict
#   8. NO run, status log's own `done:` verb    -> fm_crew_reported_done_verdict
#
# Why the invariant is worth its cost: every `done` is a claim a consumer may act
# on with the DETAIL STRIPPED - bin/fm-inactive-reconcile.sh presents the state
# word and the PR alone - so a `done` that never asked is how abandoned work
# reaches a captain as a success.
#
# One invocation never makes two calls because the answer is MEMOISED
# (crew_ask_forge), not because the done-capable paths are mutually exclusive.
# They are not, and believing they were is what quietly doubled the bound every
# budgeted caller below had measured: a checks-passed run whose read came back
# unconfirmed stays `working`, and a `working` run with a ci-ready status log
# then asked a second time. A caller running this script inside a budget of its own
# (bin/fm-inactive-reconcile.sh) narrows that bound to a share of what it has
# left, or skips the read, through those same two knobs; bin/fm-fleet-snapshot.sh
# and bin/fm-classify-lib.sh's crew_absorb_class each narrow it to a fixed 3s,
# and the doubling cost the last of those twice per crew polled. Always exits 0 on a successful read
# regardless of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# Every endpoint read here is dispatched (fm_backend_target_exists,
# fm_backend_capture, fm_busy_classify), so no session provider's own library is
# sourced directly; bin/fm-backend.sh loads the adapter the task actually
# records, and that adapter loads whatever it needs.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# The ONE owner of PR/MR URL identity, for the forge confirmation below. Sourcing
# it costs nothing here: it initialises variables and pulls bin/fm-proc-lib.sh,
# which bin/fm-backend.sh above has already loaded.
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-crew-run-verdict-lib.sh
. "$SCRIPT_DIR/fm-crew-run-verdict-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (nm_runs_newest_row_for_branch, below) scans. Generous enough to still find a
# branch's own run on a busy multi-crew fleet without listing the entire
# history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
# Bound on the ONE forge read this script ever makes: the merged/closed
# confirmation taken before any `done` is emitted (fm_crew_forge_pr_state).
# FM_CREW_STATE_NO_FORGE=1 skips it, and skipping is an UNCONFIRMED answer, which
# no path resolves to `done` - see the forge-read invariant in this file's header
# for what each kind of non-answer licenses.
#
# 10s here, and DELIBERATELY LOOSER than any budgeted caller uses. This default
# serves the interactive single-task read, where the whole cost is one person
# waiting for one answer and a slow answer is cheaper than a wrong one - the
# answer this read produces is what stops abandoned work reading as a success.
# THREE callers narrow it, and that is the whole set - check this list rather
# than re-deriving one, and add to it when a fourth appears:
#   * bin/fm-fleet-snapshot.sh - a fixed 3s per task.
#   * bin/fm-inactive-reconcile.sh - a share of the aggregate budget it has left,
#     or a skip when what remains cannot spare the read.
#   * bin/fm-classify-lib.sh - crew_absorb_class, a fixed 3s per crew. This is
#     the HIGHEST-FREQUENCY caller: bin/fm-watch.sh reaches it once per crew in a
#     poll loop with no aggregate budget above it, so it is the one that decides
#     what this reader's widened forge use actually costs.
# Each figure is recorded where it is chosen, with the measurement behind it.
#
# The call itself is nowhere near either figure. `gh pr view --json
# state,mergeStateStatus` against a real GitHub PR in this repo measured 0.53s
# 0.59s 0.59s 0.61s 0.53s over five consecutive runs on 2026-08-22 (worst 0.61s),
# and 0.55s to 0.96s over fifteen on 2026-08-23 (worst 0.96s, typical ~0.60s).
# Both are ONE host with warm `gh` auth, so these are headroom choices, not
# latency guarantees, and the spread between the two sessions is why the headroom
# is a multiple of the worst observation rather than a margin on it. Re-measure
# before changing either figure.
#
# Nothing is lost by waiting: a read that runs out of time is a TRANSIENT
# non-answer, and no path resolves one to `done` (see fm_crew_terminal_verdict),
# so a tighter bound trades a delayed answer for a delayed receipt, never for a
# false one.
FM_CREW_STATE_FORGE_TIMEOUT=${FM_CREW_STATE_FORGE_TIMEOUT:-10}
case "$FM_CREW_STATE_FORGE_TIMEOUT" in ''|*[!0-9]*|0) FM_CREW_STATE_FORGE_TIMEOUT=10 ;; esac
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
HARNESS=$(meta_value harness)
REMOTE_HOST=$(meta_value remote_host)
[ -n "$KIND" ] || KIND=ship

# The DELIVERY MODE travels beside the kind, because an absent PR is a defect for
# one ship mode and the CONTRACT for another. A `mode=local-only` task is
# instructed never to push and never to open a PR - see bin/fm-brief.sh's
# local-only delivery contract, "no remote, no PR, no pipeline" - and it is landed
# by bin/fm-merge-local.sh as a fast-forward, so its missing url is what the brief
# asked for rather than a landing that never happened. Without this field the
# absent url is indistinguishable from the ship task that owed a PR and has none,
# and every local-only crew reads `unknown` forever: it runs no pipeline, so its
# only current-state source is the status log's own `done:`, which is exactly the
# claim the forge question refuses without one.
#
# Left EMPTY when unrecorded, deliberately, rather than defaulted like KIND above.
# KIND's `ship` default is safe because ship is the STRICT answer; any mode
# default would be a permissive guess about a task whose contract was never
# written down. fm_crew_no_pr_class keeps that conservative arm for it.
MODE=$(meta_value mode)

# A torn-down (or never-created) worktree has no current state to read. A
# remote secondmate's recorded worktree is a path on ITS host, so the local
# probe proves nothing for it - the remote arm below reads the true source.
if [ -z "$REMOTE_HOST" ] && { [ -z "$WT" ] || [ ! -d "$WT" ]; }; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the deliberate-external-wait verb (fm-classify-lib.sh's FM_CLASSIFY_PAUSED_VERB):
# a crew with no active run and an idle pane that declared a known external wait
# reports `paused` distinctly, so a supervisor reading this sees a declared pause
# and its reason rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(status_line_verb "$LOG_LINE")

# --- remote secondmate: the true source is the remote endpoint ---------------
# A remote mate's recorded worktree and backend target live on its own host, so
# the local worktree probe above and the local pane reads below would misreport
# a healthy remote mate as gone or dead. Ask the remote host for the endpoint's
# recovery-grade state over the same fm-on.sh transport fm-send uses, then read
# current activity from the routed status log exactly as for a local
# secondmate (an idle endpoint is healthy for a secondmate either way). An
# unreachable host or unreadable endpoint is reported as unknown-remote -
# explicitly NOT proof of death - so a transport blip never reads as a torn
# down or dead mate; only the remote host's own dead/missing verdict may say
# the endpoint is actually gone.
if [ -n "$REMOTE_HOST" ]; then
  if ! REMOTE_STATE=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$ID" \
    fm-remote-secondmate-control.sh state "$ID" < /dev/null 2>/dev/null); then
    REMOTE_STATE=
  fi
  REMOTE_STATE=$(printf '%s\n' "$REMOTE_STATE" | tail -1)
  case "$REMOTE_STATE" in
    alive)
      if [ -n "$LOG_VERB" ]; then
        LOG_STATE=$(map_log_state "$LOG_LINE")
        if [ "$LOG_STATE" != unknown ]; then
          emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")${SEP}remote endpoint alive on $REMOTE_HOST"
        fi
      fi
      emit unknown remote-endpoint "alive on $REMOTE_HOST (an idle secondmate is healthy)"
      ;;
    dead|missing)
      emit unknown remote-endpoint "remote endpoint $REMOTE_STATE on $REMOTE_HOST"
      ;;
    '')
      emit unknown remote-endpoint "unknown-remote: $REMOTE_HOST unreachable or endpoint unreadable (not proof of death)"
      ;;
    *)
      emit unknown remote-endpoint "unknown-remote: endpoint state '$REMOTE_STATE' on $REMOTE_HOST (not proof of death)"
      ;;
  esac
fi

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose endpoint has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown. Backend-aware
# (fm_backend_of_meta defaults absent backend= to tmux, the P1 contract): a
# herdr task is read through fm_backend_capture instead of a bare tmux probe.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    # fm_backend_target_exists's tmux arm runs the byte-identical probe this
    # arm used to issue inline (`tmux display-message -p -t <target>
    # '#{pane_id}'`), so the tmux verdict is unchanged and this script no
    # longer names a session provider's command itself. The non-tmux arm keeps
    # its capture read deliberately: target_exists is a plain presence probe,
    # while these adapters answer "readable" by actually reading the surface.
    tmux) fm_backend_target_exists "$TASK_BACKEND" "$1" "$EXPECTED_LABEL" ;;
    *) fm_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# crew_busy_verdict: the crew's semantic busy state from the one contract
# owner (bin/fm-busy-lib.sh), as "<busy|idle|unknown> <source>". A converted
# adapter answers from its own lifecycle record; Grok answers from its
# isolated rendered-tail fallback; a herdr crew's native `busy` is accepted
# when no record exists, but its native `idle` is NOT, because agent.get
# reports generation state (idle while a crew blocks on its own long-running
# foreground tool call) rather than turn state.
crew_busy_verdict() {  # <target>
  local tail40=''
  case "$HARNESS" in
    grok*) tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || tail40='' ;;
  esac
  fm_busy_classify "$TASK_BACKEND" "$1" "$HARNESS" "$ID" "$STATE" "$tail40"
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --
# trim, strip_quotes and the bounded nm_run call are thin wrappers over
# bin/fm-nm-run-lib.sh, whose bounded-call and text primitives are shared with
# fm-teardown.sh's pre-teardown run abort. The code-identity attribution rule is
# NOT read from there: bin/fm-crew-run-verdict-lib.sh owns the relation model
# this script binds with, and nm_field's scalar read is scoped by that same owner
# so a `branch_sync:` block can never answer a run-object key.

trim() { fm_nm_trim "$@"; }
strip_quotes() { fm_nm_strip_quotes "$@"; }
nm_run() {  # <args...>
  fm_nm_run "$WT" "$NM_TIMEOUT" "$@"
}

# The captured run output ($RUN_OUT) with its `branch_sync:` block removed. Every
# reader below that scans the record goes through this and never through
# $RUN_OUT, because that block repeats key names the run object uses - `branch`,
# `head`, `status`, `run` - and describes the branch's PUSH BINDING, which can
# belong to a different run than the one being read. An unscoped match therefore
# lets one section answer the other's question: a `pipeline.status` of
# awaiting_approval reads as this run's own gate and parks a demonstrably running
# pipeline. fm_crew_run_scalars in fm-crew-run-verdict-lib.sh is the one owner of
# that scoping; nm_field composes with it, and the single deliberate reader INSIDE
# the block is that library's ownership proof, which must clear three equalities
# before the block may say anything about this run.
#
# Computed ONCE, into $RUN_OBJECT, when $RUN_OUT is captured: the record does not
# change afterwards, and every reader here would otherwise re-fork awk over the
# same bytes - about fifteen times per classification pass, once per task in
# bin/fm-fleet-snapshot.sh's fleet-wide loop.
RUN_OUT=""
RUN_OBJECT=""
nm_run_object() {
  printf '%s\n' "$RUN_OBJECT"
}
# Scalar value of a TOON key in the run object. bin/fm-nm-run-lib.sh owns the
# TOON scalar read; the scoping is already applied to $RUN_OBJECT.
nm_field() {  # <key>
  fm_nm_field "$RUN_OBJECT" "$1"
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  nm_run_object | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(nm_run_object | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(nm_run_object | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  nm_run_object | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(nm_run_object | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

# The `ci` step's word when that step is EXECUTING, which is what licenses the
# ci-log-green override below. fm_crew_step_status is the OWNER of that column -
# anchored to the `steps` table, keyed by column name, tolerant of padding and
# quoting - so this asks it rather than matching a row shape of its own. A
# private pattern here carried the same two defects that owner exists to prevent:
# an `active_steps` row begins with a step name too, so a `ci,running,2m,...`
# ACTIVE row answered for the step history, and a padded `ci , running` answered
# not at all, silently withholding the ready-for-review signal a captain waits on.
nm_ci_step_status() {
  local step_status
  step_status=$(fm_crew_step_status "$(nm_run_object)" ci)
  case "$step_status" in
    running|fixing) printf '%s' "$step_status" ;;
  esac
}

nm_effective_ci_step_status() {
  local step_status
  if [ "${RUN_STATUS:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(nm_ci_step_status)
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${RUN_STATUS:-}" = ci ]; then
    printf 'running'
  fi
}

# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the captain, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or failed/cancelled if closed). `axi status`'s steps[] table
# never distinguishes "still waiting on checks" from "checks green, waiting on
# merge": both read as plain `ci,running,...`. The only place that transition is
# recorded is the ci step's own log text, e.g. "all CI checks passed - still
# monitoring until merged or closed" or "no CI checks reported - still
# monitoring until merged or closed" (verified against 360+ real run logs under
# ~/.no-mistakes/logs/*/ci.log on the installed v1.32.2 binary, including the
# actual PR #252 run). Reads the ci step's log tail via `axi logs` and scans it
# for the MOST RECENT recognized marker (the log is append-only/chronological,
# so the last match is current): green with nothing red after it means CI is
# green right now, still only waiting on merge/close.
nm_ci_checks_state() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}
# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one
# exists, else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating crews on the same underlying repo). A crew whose branch genuinely
# has no run yet therefore sees another branch's answer here.
#
# Two run listings exist, and neither one dominates the other (both verified
# against the real installed CLI, v1.48.0). The bare `no-mistakes axi` home view
# emits `runs[N]{id,branch,status,head,pr}` - it HAS run ids, which would allow a
# follow-up `axi status --run <id>` for full step, activity and branch_sync
# detail - but it is capped at the 10 most recent runs repo-wide with no limit
# flag, so on a busy multi-crew repo a branch's own run drops off it. The
# top-level `no-mistakes runs --limit N` reaches arbitrarily far back but is
# plain human-oriented text with no run id: newest-first, columns
# "<status> <branch> <short-sha> <date> <time> [<pr-url>]" separated by runs of
# spaces, no quoting.
#
# This path uses `runs` because finding the branch's run at all outranks getting
# richer detail about it, and branch plus coarse status plus that row's own sha
# and PR is what the predicate needs. Worth doing later: try the home view first
# and re-query any id it yields, which would give this path the same full detail
# the `axi status` path gets - including the ci-step and branch_sync evidence a
# coarse row cannot carry - and fall back to `runs` when the branch is off the
# home view's 10-row window.
#
# Echoes the branch's NEWEST row only, as "<status>|<short-sha>|<pr-url>".
# fm-crew-run-verdict-lib.sh owns why nothing older is ever examined.
nm_runs_newest_row_for_branch() {  # <branch>
  local out
  out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
  [ -n "$out" ] || return 0
  fm_crew_runs_newest_row_for_branch "$out" "$1"
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
# scratch worktree); with no branch there is no run to attribute to this crew.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

HAVE_RUN=0
# RUN_SOURCE names WHICH RECORD, IF ANY, THIS TASK OWNS: "full" means $RUN_OUT is
# real `axi status` TOON with step/gate detail whose `branch:` named this crew's
# branch; "coarse" means only a status word, sha and PR came back from the
# runs-list fallback below, so the run-step block skips the TOON field parsing
# entirely for this crew; "none" means attribution never succeeded.
#
# It starts at `none`, and that initial value is load-bearing. It started at
# `full` - before any ownership test had run - so a branch MISMATCH left it
# saying `full` over another task's record, and crew_pr_url below then read the
# SIBLING run's `pr:` field. A merged sibling PR made this crew emit a landing
# claim for a PR that was never its own: the exact false-landing shape this whole
# change exists to remove, arriving through the documented `axi status` is
# REPO-scoped trap - a branch mismatch means THIS TASK HAS NO RUN, never "use
# that one".
#
# That hole was a CONSEQUENCE OF THE RULING that put a forge read on the
# status-log `done:` path, and it is recorded here rather than quietly patched so
# the cost of that ruling stays visible. Before the ruling, a runless crew
# reading its own status log never consulted the run record at all, so a stale
# sibling record could not reach a verdict; routing that path through the forge
# gave the stale record a way out. The ruling stands - a self-reported `done` is
# the weakest evidence here and needs the forge most - and the price of it is
# that every read of the run record now has to prove ownership first.
RUN_SOURCE=none
COARSE_STATUS=""
COARSE_PR=""
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  RUN_OBJECT=$(fm_crew_run_scalars "$RUN_OUT")
  if [ -n "$RUN_OUT" ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ]; then
      # This answer IS this branch's newest run: the CLI reports the repo's
      # active-or-most-recent run, and one branch cannot host two concurrent
      # runs. So the runs list can only offer this same run again or an OLDER,
      # superseded one, and is deliberately NOT consulted from here even when
      # the binding below refuses this run - reaching past the newest run for
      # this branch is precisely how a dead run masked a live one
      # (fm-crew-run-verdict-lib.sh's header owns that whole model).
      RUN_SOURCE=full
      if fm_crew_run_admits "$WT" "$RUN_OUT" "$(strip_quotes "$(nm_field head)")"; then
        HAVE_RUN=1
      fi
    else
      # The active-or-most-recent run is for another branch (the CLI is alive
      # and answered; only the attribution missed) - ask the runs list whether
      # THIS branch has a newest run of its own.
      #
      # DISCARD THE RECORD FIRST, so no reader below can consult a foreign run.
      # A branch mismatch means this task has no run; keeping the bytes around
      # for their `pr:` field is how a sibling's merged PR became this crew's
      # landing claim. Clearing at the source beats testing ownership at each
      # reader, because the next reader added would have to remember the test.
      # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      RUN_OUT=""
      RUN_OBJECT=""
      coarse_row=$(nm_runs_newest_row_for_branch "$CREW_BRANCH")
      if [ -n "$coarse_row" ]; then
        COARSE_STATUS=${coarse_row%%|*}
        coarse_rest=${coarse_row#*|}
        coarse_sha=${coarse_rest%%|*}
        COARSE_PR=${coarse_rest#*|}
        # A coarse row carries no steps and no activity, so its terminality is
        # read from the status word alone.
        case "$COARSE_STATUS" in
          completed|failed|cancelled) coarse_terminality=terminal ;;
          *) coarse_terminality=live ;;
        esac
        if fm_crew_binding_admits \
          "$(fm_crew_head_relation "$WT" "$coarse_sha")" "$coarse_terminality"; then
          HAVE_RUN=1
          RUN_SOURCE=coarse
        fi
      fi
    fi
  fi
fi

# --- run-step authoritative path -------------------------------------------

# The forge's own word on this run's PR: merged, closed, open, unverified, or one
# of the two structural non-answers (optionally with the forge's merge-state
# qualifier). This is the ONLY source a merged-or-closed claim may come from.
# Run state cannot supply it: a run reached
# `outcome: passed` on a PR that was open, conflicted and carried zero checks,
# and the old "PR merged/closed" reason was pure invention (see
# fm-crew-run-verdict-lib.sh's header). Called on exactly the paths that can emit
# `done` and nowhere else; this file's header owns that invariant and states why
# the emitted word is not a way to tell whether the call happened.
#
# `no-pr` is the answer only once crew_pr_url has looked EVERYWHERE a PR url is
# recorded, so it means "this task has no PR", not "this reader did not look" - a
# url this reader failed to find would have hidden a close behind a word that
# never asked. What that absence LICENSES is then decided by the task's recorded
# kind, which travels with the word: a scout has no landing to claim by
# construction, so its `done` is not a landing claim, while a ship task exists to
# land a branch and an absent PR there is the landing question answered badly.

# This task's PR url from every place one is recorded, in decreasing authority:
# the run record's own `pr:` field, the coarse runs-list row, the task meta, then
# the status log the worker writes.
#
# The last two are not redundancy, they are the fix for a real hole. The coarse
# runs-list row NEVER carries a url, so a crew on that path used to reach the
# forge with nothing to ask about and settle `done` unasked - while the very
# status log this same invocation had already read named the PR, and
# bin/fm-inactive-reconcile.sh's pr_for_task then dug that url out and showed it
# to the captain beside the word. Reading it here asks the forge about that url
# before the verdict rather than after it.
#
# The readers that PRESENT a url beside a state word OUGHT to agree with this one
# about WHICH url, because the state word and the PR shown beside it describing
# different pull requests is the same self-contradiction this reader exists to
# remove. There are three in all: this one, pr_for_task in
# bin/fm-inactive-reconcile.sh, and newest_pr_url_in_file in
# bin/fm-fleet-snapshot.sh. They agree on ONE TIER so far, and the rest is
# bounded and accepted rather than closed - do not read the paragraph above as an
# invariant.
#
# The chains are different lengths. This function resolves FOUR tiers: the run
# record's `pr:` when RUN_SOURCE is full, then COARSE_PR, then meta `pr=`, then
# the status log's newest matching url. The other two resolve TWO: meta `pr=`,
# then the status log's newest matching url. Only the LOG tier was aligned, on
# the NEWEST matching url, pull request or merge request alike, because the
# newest is the one that answers "which PR is this crew's current one"; both of
# those readers previously took the FIRST url and matched pull requests only.
#
# So they can still name DIFFERENT PRs for one task whenever meta carries no
# `pr=` while the run record or the coarse row carries a url - the tiers this
# function has and those readers do not. bin/fm-pr-check.sh is the only writer of
# meta `pr=`, so that window is open until firstmate acts on a replacement url.
# Closing it means removing the other selection rules rather than aligning
# another tier - the reader that produced the word supplying the url it asked
# about - and that is deferred as its own follow-up.
crew_pr_url() {
  local url=""
  [ "$RUN_SOURCE" = full ] && url=$(strip_quotes "$(nm_field pr)")
  [ -n "$url" ] || url=$COARSE_PR
  [ -n "$url" ] || url=$(meta_value pr)
  [ -n "$url" ] || url=$(grep -Eo 'https?://[^[:space:])"]+/(pull|merge_requests)/[0-9]+' \
    "$LOG" 2>/dev/null | tail -1 || true)
  printf '%s' "$url"
}
crew_forge_read() {
  local url
  case "$(printf '%s' "${FM_CREW_STATE_NO_FORGE:-}" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) : ;;
    *) printf 'unverified'; return ;;
  esac
  url=$(crew_pr_url)
  # The RECORDED TASK KIND and DELIVERY MODE travel with the answer, because an
  # absent PR means opposite things for different kinds and different modes, and
  # the absent url cannot tell any of them apart. fm_crew_no_pr_class owns the
  # rule: a scout has no landing to claim by construction, a local-only ship was
  # told not to open a PR, and a remote-backed ship with no PR is precisely where
  # a `done` would be wrong.
  #
  # The mode word is APPENDED rather than always present, so an unrecorded mode
  # leaves the descriptor exactly the single-word shape it had before and takes
  # the conservative arm. Emitting an empty third word instead would hand the
  # parser a mode it cannot distinguish from a recorded one.
  if [ -z "$url" ]; then
    printf 'no-pr %s' "$KIND"
    [ -z "$MODE" ] || printf ' %s' "$MODE"
    return
  fi
  fm_crew_forge_pr_state "$url" "$FM_CREW_STATE_FORGE_TIMEOUT"
}

# The memoised answer, and the reason this reader has one. The header promises
# "at most ONE outbound `gh pr view` per invocation", and that promise used to
# rest on the done-capable paths being mutually exclusive - which they are not.
# A checks-passed run whose forge read came back UNCONFIRMED stays `working`, and
# a `working` run with a ci-ready status log falls straight into
# emit_checks_green, which asked again. Two reads is not a wrong verdict, it is a
# broken bound: bin/fm-fleet-snapshot.sh's per-task figure and its recorded
# "3 tasks x 3s = 9s" worst case both assume one call, and silently became 18s.
#
# Memoising restores the recorded figure rather than re-choosing it, and it makes
# the bound structural instead of an emergent property of control flow nobody
# re-checks. $CREW_FORGE_ANSWER is read directly by callers because the read must
# not happen inside a command substitution - a subshell's cache dies with it.
CREW_FORGE_ANSWER=""
CREW_FORGE_ASKED=0
crew_ask_forge() {
  [ "$CREW_FORGE_ASKED" = 1 ] && return 0
  CREW_FORGE_ASKED=1
  CREW_FORGE_ANSWER=$(crew_forge_read)
}

# Whether the run record shows this crew still EXECUTING, as `live` or
# `terminated`, for the green-checks routes that must not claim liveness they
# have not established (fm_crew_checks_green_verdict).
#
# Only two things count as evidence, in the order the model already trusts them:
# the daemon's own active_steps table, which is the authoritative liveness signal
# for a live pipeline, then a non-terminal `status:` word. An ABSENT status is
# not non-terminal - it is no evidence at all - and it answers `terminated`,
# because the governing preference is unknown over a confident wrong answer.
crew_liveness() {
  if [ -n "$(fm_crew_active_step "$(nm_run_object)")" ]; then
    printf 'live'
    return
  fi
  case "$(strip_quotes "$(nm_field status)")" in
    ''|completed|failed|cancelled) printf 'terminated' ;;
    *) printf 'live' ;;
  esac
}

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A crew genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced through signal_reason_is_actionable regardless of this
    # coarse-vs-full distinction, so a real gate is never silently missed.
    case "$COARSE_STATUS" in
      running)   RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      completed)
        # A coarse row carries no steps table, so this path cannot answer the ci
        # question either way - and it says exactly that, by passing the
        # no-step-detail sentinel into the SAME ranking the full path uses. Two
        # rankings for one question is how the two paths came to read `done` and
        # `unknown` for one world state; fm-crew-run-verdict-lib.sh owns the rule.
        crew_ask_forge
        coarse_verdict=$(fm_crew_terminal_verdict "$FM_CREW_CI_NO_STEP_DETAIL" "$CREW_FORGE_ANSWER")
        RUN_STATE=${coarse_verdict%%|*}
        RUN_DETAIL=${coarse_verdict#*|}
        ;;
      failed)    RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled) RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      *)         RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac
  else
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    outcome=$(strip_quotes "$(nm_field outcome)")
    awaiting=$(nm_run_object | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
    gate_status=$(nm_gate_status)
    has_gate=0
    nm_has_gate && has_gate=1

    ci_step_recorded=$(fm_crew_step_status "$(nm_run_object)" ci)
    if [ -n "$outcome" ]; then
      case "$outcome" in
        checks-passed)
          # TWO DIFFERENT QUESTIONS, kept apart here because conflating them is
          # how this regresses. What proves CI RAN: `checks-passed` is a statement
          # about the CHECKS, so it is CI evidence IN ITS OWN RIGHT and still
          # needs no corroborating ci-step row - where merge is left to the
          # captain the ci step stays `running` for the whole monitor phase (see
          # nm_ci_checks_state), so demanding one would withhold exactly the
          # ready-for-review signal the captain is waiting on. That ruling stands
          # untouched. What proves WHERE THE PR ENDED UP: nothing in the run
          # record, which is why this arm is no longer EXEMPT from the forge read.
          # fm_crew_checks_green_verdict owns that second question, and keeps the
          # ready-for-review detail on every answer but a confirmed close.
          #
          # A THIRD question, which this arm alone has to answer for itself: is
          # the crew still alive? The other two green-checks routes sit inside
          # `[ "$RUN_STATE" = working ]`, so their liveness is already
          # established; this one fires on the outcome word, and an outcome word
          # is what makes a run TERMINAL. Reporting `working` for a finished run
          # because the forge happened not to answer would be a liveness claim
          # with nothing behind it, so the record is asked outright.
          crew_ask_forge
          green_verdict=$(fm_crew_checks_green_verdict "$CREW_FORGE_ANSWER" \
            "checks green: PR ready for review" "$(crew_liveness)")
          RUN_STATE=${green_verdict%%|*}
          RUN_DETAIL=${green_verdict#*|}
          ;;
        passed)
          # `outcome: passed` means the PIPELINE completed, not that CI passed, so
          # it never settles this on its own. fm_crew_terminal_verdict owns the ONE
          # ranking every terminated run goes through - a forge-confirmed merge
          # (done) or close (failed), then this run's own `ci,completed`, then
          # unknown - and the coarse path below calls the same function so the two
          # cannot disagree.
          crew_ask_forge
          pass_verdict=$(fm_crew_terminal_verdict "$ci_step_recorded" "$CREW_FORGE_ANSWER")
          RUN_STATE=${pass_verdict%%|*}
          RUN_DETAIL=${pass_verdict#*|}
          ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
      esac
    elif [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if nm_run_object | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: authority decision)"
      fi
    else
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)
          crew_ask_forge
          pass_verdict=$(fm_crew_terminal_verdict "$ci_step_recorded" "$CREW_FORGE_ANSWER")
          RUN_STATE=${pass_verdict%%|*}
          RUN_DETAIL=${pass_verdict#*|}
          ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        "")
          # An ABSENT status word is not a non-terminal one, so this arm cannot
          # assert liveness on its own: crew_liveness owns that question for the
          # whole reader, and it rules such a record terminated unless the
          # daemon's own active_steps table says otherwise. Restating the answer
          # here is what made one record read `working` by this route and
          # `unknown` by the ci-ready one, and the governing preference between
          # those two is unknown over a confident wrong answer.
          if [ "$(crew_liveness)" = live ]; then
            RUN_STATE=working; RUN_DETAIL="run active"
          else
            RUN_STATE=unknown; RUN_DETAIL="run record carries no status word"
          fi
          ;;
        *)              RUN_STATE=working; RUN_DETAIL="run active ($status)" ;;
      esac
      if [ "$RUN_STATE" = working ]; then
        # The daemon's own statement of what is executing right now, and when it
        # last did anything. Preferred over the coarse status word because it is
        # the signal that keeps a demonstrably live pipeline from reading as no
        # information at all.
        active_note=$(fm_crew_active_step_note "$(fm_crew_active_step "$(nm_run_object)")")
        [ -n "$active_note" ] && RUN_DETAIL=$active_note
        CI_STEP_STATUS=$(nm_effective_ci_step_status)
        case "$CI_STEP_STATUS" in
          running)
            CI_LOG_STATE=$(nm_ci_checks_state)
            if [ "$CI_LOG_STATE" = green ]; then
              crew_ask_forge
              green_verdict=$(fm_crew_checks_green_verdict "$CREW_FORGE_ANSWER" \
                "checks green: PR ready for review (still monitoring for merge/close)" live)
              RUN_STATE=${green_verdict%%|*}
              RUN_DETAIL=${green_verdict#*|}
            fi
            ;;
          fixing)
            CI_LOG_STATE=not-ready
            ;;
        esac
      fi
    fi
  fi

  # The crew's own log says its checks went green while the run monitors. Same
  # two questions as the checks-passed arm above, so the same owner answers the
  # second one: the log proves the checks, and only the forge can say where the
  # PR ended up. Routing this through it is what makes the invariant complete -
  # this reader never emits `done` without having asked - and it costs no extra
  # call, because the answer is MEMOISED (crew_ask_forge). It is NOT because
  # these paths and the two above are mutually exclusive: they are not, and that
  # disproved belief is what quietly doubled every budgeted caller's bound. The
  # reachable overlap is a checks-passed run whose read came back unconfirmed,
  # which stays `working` and then falls into this very block.
  #
  # <liveness> is the CALLER'S to establish, because the two callers can prove it
  # in ways the other cannot see. The full path derives it from the run record
  # (crew_liveness); the coarse path asserts `live` because its own admission
  # test was COARSE_STATUS=running, which is genuine liveness that crew_liveness
  # cannot read - a coarse row carries no steps table and no `status:` key.
  #
  # Asserting `live` for both was wrong for one full-path record shape, and
  # wrong in the permissive direction: the absent-`status:` arm above mapped a
  # record with no status word to working/"run active", while crew_liveness rules
  # that same record `terminated` on the ground that an absent status is no
  # evidence at all. Two functions in one reader disagreeing about one record is
  # the self-contradiction this whole change exists to remove, so BOTH sides now
  # ask the one owner - that arm and this call site - instead of restating an
  # answer of their own. With the arm deferring too, no full-path record reaches
  # here `terminated` any more; the derived argument stays because it is the
  # honest expression of who owns liveness, and the property it carried is now
  # guarded at the arm.
  emit_checks_green() {  # <source> <detail> <liveness: live|terminated>
    local verdict
    crew_ask_forge
    verdict=$(fm_crew_checks_green_verdict "$CREW_FORGE_ANSWER" "$2" "$3")
    emit "${verdict%%|*}" "$1" "${verdict#*|}"
  }

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      emit_checks_green status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR" live
    fi
    [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
    if [ "$RUN_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
      CI_LOG_STATE=$(nm_ci_checks_state)
    elif [ "$CI_STEP_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    fi
    if [ "$CI_LOG_STATE" != not-ready ]; then
      emit_checks_green status-log \
        "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR" "$(crew_liveness)"
    fi
  fi

  # Reconcile the status log. A needs-decision/blocked log line that the run-step
  # has moved past (anything but a genuinely parked run) is deterministically
  # stale: the gate resolved and the run resumed or finished.
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
fi

# --- fallback: no run attributed to this crew ------------------------------
# The run-step path above already handled any crew with a run, regardless of pane
# liveness, so a finished-but-pane-closed crew never reaches here. Down here there
# is no run to consult, so a dead/unreadable target means the crew is gone: report
# unknown rather than trusting a possibly-stale status log as the current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
pane_readable "$BACKEND_TARGET" || emit unknown none "backend target gone: $BACKEND_TARGET"

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# state is not meaningful for them; read their state from the status log only.
# Only an exact busy verdict reports working here, and only an exact idle
# verdict permits the status-log fallback below. Missing, malformed, stale, or
# unverified semantic state remains unknown.
if [ "$KIND" != secondmate ]; then
  BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
  case "${BUSY_VERDICT%% *}" in
    busy) emit working pane "harness busy (${BUSY_VERDICT#* })" ;;
    idle) ;;
    *) emit unknown pane "harness state unavailable ($BUSY_VERDICT)" ;;
  esac
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (fm-classify-lib.sh's
# FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a secondmate, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
#
# A `done:` verb is the one state word here that carries a landing claim, so it
# alone consults the forge before it is emitted. The source is not a reason to
# exempt it - it is the reason not to: this is the worker's SELF-REPORT, weaker
# evidence than a run record, and bin/fm-inactive-reconcile.sh matches the WORD
# regardless of source, so an abandoned PR would reach the captain as a success
# by exactly the route a run-backed one no longer can. The call costs one bounded
# read on a path that only fires when a `done:` line already exists.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" = "done" ]; then
    crew_ask_forge
    log_verdict=$(fm_crew_reported_done_verdict "$CREW_FORGE_ANSWER" \
      "$(status_line_note "$LOG_LINE")")
    emit "${log_verdict%%|*}" status-log "${log_verdict#*|}"
  fi
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

emit unknown none "no current-state source available"
