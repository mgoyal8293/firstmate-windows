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
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta.
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
#      an unconfirmed answer reads working, since the crew is still monitoring
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
# The done-capable paths are mutually exclusive, so one invocation never makes
# two calls. A caller running this script inside a budget of its own
# (bin/fm-inactive-reconcile.sh) narrows that bound to a share of what it has
# left, or skips the read, through those same two knobs; bin/fm-fleet-snapshot.sh
# narrows it to a fixed per-task bound. Always exits 0 on a successful read
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
# Every caller with more than one task to get through narrows it: 3s in
# bin/fm-fleet-snapshot.sh, and a share of what remains in
# bin/fm-inactive-reconcile.sh, each recorded where it is chosen.
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
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
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

nm_ci_step_status() {
  local row rest
  row=$(nm_run_object | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
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
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a status word, sha and PR came back from the runs-list fallback above, so the
# run-step block below skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
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
      if fm_crew_run_admits "$WT" "$RUN_OUT" "$(strip_quotes "$(nm_field head)")"; then
        HAVE_RUN=1
      fi
    else
      # The active-or-most-recent run is for another branch (the CLI is alive
      # and answered; only the attribution missed) - ask the runs list whether
      # THIS branch has a newest run of its own.
      # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
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
# recorded, so it means "this task has no PR", not "this reader did not look".
# The difference decides a verdict: a task with no PR has no landing to confirm,
# so its `done` is not a landing claim, while a url this reader failed to find
# would have hidden a close behind a word that never asked.

# This task's PR url from every place one is recorded, in decreasing authority:
# the run record's own `pr:` field, the coarse runs-list row, the task meta, then
# the status log the worker writes.
#
# The last two are not redundancy, they are the fix for a real hole. The coarse
# runs-list row NEVER carries a url, so a crew on that path used to reach the
# forge with nothing to ask about and settle `done` unasked - while the very
# status log this same invocation had already read named the PR, and
# bin/fm-inactive-reconcile.sh's pr_for_task then dug that url out and showed it
# to the captain beside the word. Reading it here is the same lookup that
# consumer already performs, done before the verdict rather than after it.
crew_pr_url() {
  local url=""
  [ "$RUN_SOURCE" = full ] && url=$(strip_quotes "$(nm_field pr)")
  [ -n "$url" ] || url=$COARSE_PR
  [ -n "$url" ] || url=$(meta_value pr)
  [ -n "$url" ] || url=$(grep -Eo 'https?://[^[:space:])"]+/(pull|merge_requests)/[0-9]+' \
    "$LOG" 2>/dev/null | tail -1 || true)
  printf '%s' "$url"
}
crew_forge_answer() {
  local url
  case "$(printf '%s' "${FM_CREW_STATE_NO_FORGE:-}" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) : ;;
    *) printf 'unverified'; return ;;
  esac
  url=$(crew_pr_url)
  [ -n "$url" ] || { printf 'no-pr'; return; }
  fm_crew_forge_pr_state "$url" "$FM_CREW_STATE_FORGE_TIMEOUT"
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
        coarse_verdict=$(fm_crew_terminal_verdict "$FM_CREW_CI_NO_STEP_DETAIL" "$(crew_forge_answer)")
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
          green_verdict=$(fm_crew_checks_green_verdict "$(crew_forge_answer)" \
            "checks green: PR ready for review")
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
          pass_verdict=$(fm_crew_terminal_verdict "$ci_step_recorded" "$(crew_forge_answer)")
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
          pass_verdict=$(fm_crew_terminal_verdict "$ci_step_recorded" "$(crew_forge_answer)")
          RUN_STATE=${pass_verdict%%|*}
          RUN_DETAIL=${pass_verdict#*|}
          ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        "")             RUN_STATE=working; RUN_DETAIL="run active" ;;
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
              green_verdict=$(fm_crew_checks_green_verdict "$(crew_forge_answer)" \
                "checks green: PR ready for review (still monitoring for merge/close)")
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
  # call, because these paths and the two above are mutually exclusive.
  emit_checks_green() {  # <source> <detail>
    local verdict
    verdict=$(fm_crew_checks_green_verdict "$(crew_forge_answer)" "$2")
    emit "${verdict%%|*}" "$1" "${verdict#*|}"
  }

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      emit_checks_green status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
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
      emit_checks_green status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
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
    log_verdict=$(fm_crew_reported_done_verdict "$(crew_forge_answer)" \
      "$(status_line_note "$LOG_LINE")")
    emit "${log_verdict%%|*}" status-log "${log_verdict#*|}"
  fi
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

emit unknown none "no current-state source available"
