#!/usr/bin/env bash
# fm-crew-run-verdict-lib.sh - the state model for turning ONE no-mistakes run
# record into a crew verdict, plus the evidence gates that stop a wrong verdict
# from being emitted.
#
# Sourced, never executed. bin/fm-crew-state.sh is the only caller; this file
# owns the model so the rules below live in one place instead of being spread
# through that script's control flow.
#
# WHY THIS EXISTS. bin/fm-crew-state.sh used to answer four genuinely different
# situations with the same two words, in both unsafe directions (reproduced with
# real recorded runs, 2026-08-19 through 2026-08-22):
#
#   1. A dead run masked a live one. Run selection filtered candidate runs by
#      code identity and SKIPPED PAST any that did not bind, so when a pipeline
#      advanced the branch to a commit the task worktree had not fetched, the
#      live run failed to bind and an OLDER terminal-failed run still sitting at
#      the local head was selected instead. A healthy, progressing task reported
#      `failed`, which AGENTS.md section 7 treats as terminal.
#   2. `outcome: passed` was reported as `done - run passed: PR merged/closed`
#      for a run whose `ci` step was SKIPPED, on a PR that was open, conflicted
#      and carried zero checks. `outcome: passed` means the pipeline COMPLETED;
#      a skipped ci step is the ABSENCE of validation, not validation. The
#      "PR merged/closed" reason was never read from the forge at all.
#   3. A demonstrably live pipeline (a step actively running, recent activity,
#      live agent pid) reported `unknown - no current-state source available`,
#      because selection had already discarded its run.
#
# THE MODEL.
#
# Candidate selection - ONE candidate, and it is the branch's NEWEST run:
#   * `axi status` (bare) is REPO-scoped, not branch-scoped: it answers with the
#     repo's active-or-most-recent run, which on a multi-crew repo is routinely
#     another task's. Its `branch:` line is the only thing that makes it usable,
#     so a branch mismatch means "this task has no run", never "use that one".
#   * When it DOES name this branch, it is by construction this branch's newest
#     run (a branch cannot have two concurrent runs), so the runs list can only
#     offer the same run again or an older superseded one. Never consult it.
#   * Otherwise the newest row for this branch in `no-mistakes runs` is the
#     candidate. Older rows are superseded by definition and are NEVER examined:
#     stepping past the newest row is exactly how defect 1 happened.
#
# Code identity - a QUALIFIER on the candidate, never a filter that selects a
# different run. fm_crew_head_relation names the geometry; fm_crew_binding_admits
# decides what that geometry may support:
#   * equal / pipeline-ahead (local HEAD is an ancestor of the run head): the run
#     describes this code. Admit any verdict.
#   * unresolvable (the run head is a real sha this checkout does not have): the
#     signature of a pipeline that owns the branch and has pushed commits the
#     task worktree never fetched. Admit only a NON-TERMINAL verdict - enough to
#     report the task alive, never enough to declare it done or failed.
#   * local-ahead / diverged: the run describes other code (a prior run, or a
#     rewritten tip). Admit nothing; fall back to live current-state sources.
#   * absent (the run record carries no head at all): nothing to bind. Admit
#     nothing.
#   * OVERRIDE: a run with an active step (see fm_crew_active_step) is alive
#     right now, and a branch cannot host two concurrent runs, so it is this
#     task's run whatever the head geometry says. Liveness admits a non-terminal
#     verdict on its own.
#
# Verdict - the four situations that used to collapse, kept apart:
#   * an active step running or fixing            -> working, with its activity
#   * a gate awaiting a response                  -> parked at that gate
#   * outcome failed or cancelled                 -> failed
#   * outcome passed/checks-passed, ci COMPLETED  -> done, and the merged/closed
#     claim is emitted ONLY when the forge confirms it (fm_crew_forge_pr_state)
#   * outcome passed/checks-passed, ci SKIPPED    -> NOT done. Nothing validated
#     this work, so it reports parked: it needs a ruling, not a landing.
#
# `no-mistakes axi sync --check` reports `branch_sync.pipeline.current_head` and
# would prove pipeline ownership outright, which is the one thing that could
# safely widen the unresolvable case to admit a TERMINAL verdict too. It is
# deliberately not used: this reader runs on every heartbeat for every crew, and
# `axi sync` without `--check` APPLIES a plan, so a read-only current-state tool
# is the wrong caller for it. The head relation answers the live case, which is
# the case the defect needed, at no extra process cost.
#
# Everywhere the evidence does not settle the question, the answer is the
# conservative one. A tool that says "I do not know" costs a handling turn; a
# tool that says "merged" when nothing merged costs the work.
set -u

# --- run record parsing -----------------------------------------------------

# Status word of one step in a run's `steps[N]{step,status,...}` table, e.g.
# `ci`. Empty when the run record has no row for that step. The table is plain
# comma-separated TOON with no quoting in these columns.
fm_crew_step_status() {  # <run-output> <step-name>
  printf '%s\n' "$1" \
    | sed -n "s/^[[:space:]]*$2,\([^,]*\),.*/\1/p" \
    | head -1 \
    | tr -d '"'
}

# The first RUNNING or FIXING row of a run's `active_steps[N]{...}` table, as
# "<step>|<status>|<active_for>|<last_activity>". Empty when the run has no
# active step, which is the daemon's own statement that nothing is executing.
#
# Columns are read by NAME from the table header rather than by position, and
# the row is split quote-aware, because `last_activity` is a quoted free-text
# field that routinely contains commas of its own:
#   review,fixing,1h27m,"9m52s ago: log: I'll review the changes, then...","2010043",fix 3
fm_crew_active_step() {  # <run-output>
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*active_steps\[[0-9]+\]\{/ {
      hdr = $0
      sub(/^[^{]*\{/, "", hdr)
      sub(/\}.*$/, "", hdr)
      ncol = split(hdr, col, ",")
      in_table = 1
      next
    }
    in_table {
      row = $0
      sub(/^[[:space:]]+/, "", row)
      if (row == "" || row !~ /,/) { in_table = 0; next }
      # Quote-aware field split: a comma inside double quotes is data.
      nval = 0; cur = ""; inq = 0
      for (i = 1; i <= length(row); i++) {
        c = substr(row, i, 1)
        if (c == "\"") { inq = !inq; continue }
        if (c == "," && !inq) { val[++nval] = cur; cur = ""; continue }
        cur = cur c
      }
      val[++nval] = cur
      step = ""; status = ""; active_for = ""; last_activity = ""
      for (i = 1; i <= ncol && i <= nval; i++) {
        if (col[i] == "step") step = val[i]
        else if (col[i] == "status") status = val[i]
        else if (col[i] == "active_for") active_for = val[i]
        else if (col[i] == "last_activity") last_activity = val[i]
      }
      if (status == "running" || status == "fixing") {
        printf "%s|%s|%s|%s\n", step, status, active_for, last_activity
        exit
      }
    }
  '
}

# One short human phrase for an active step, for the verdict detail line.
fm_crew_active_step_note() {  # <active-step-record>
  local rec=$1 step status active_for last
  [ -n "$rec" ] || return 0
  step=${rec%%|*}; rec=${rec#*|}
  status=${rec%%|*}; rec=${rec#*|}
  active_for=${rec%%|*}
  last=${rec#*|}
  # The recorded last_activity is "<age> ago: <log text>"; only the age is
  # supervisor-relevant, and the log text can be arbitrarily long.
  last=${last%%:*}
  printf 'validating (%s %s' "$step" "$status"
  [ -n "$active_for" ] && printf ', active %s' "$active_for"
  case "$last" in
    *ago) printf ', last activity %s' "$last" ;;
  esac
  printf ')'
}

# --- code identity ----------------------------------------------------------

# Geometry between a run's head and a worktree's HEAD, as one word:
# absent, unresolvable, equal, pipeline-ahead, local-ahead, or diverged.
# See this file's header for what each one is allowed to support.
fm_crew_head_relation() {  # <worktree> <run-head>
  local wt=$1 run_head=$2 local_full run_full
  if [ -z "$run_head" ]; then printf 'absent'; return; fi
  if ! local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null); then
    printf 'absent'; return
  fi
  if ! run_full=$(git -C "$wt" rev-parse --verify -q "${run_head}^{commit}" 2>/dev/null); then
    printf 'unresolvable'; return
  fi
  if [ "$run_full" = "$local_full" ]; then printf 'equal'; return; fi
  if git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    printf 'pipeline-ahead'; return
  fi
  if git -C "$wt" merge-base --is-ancestor "$run_full" "$local_full" 2>/dev/null; then
    printf 'local-ahead'; return
  fi
  printf 'diverged'
}

# 0 when <relation> may support a verdict of <terminality> (terminal|live).
fm_crew_binding_admits() {  # <relation> <terminality>
  case "$1" in
    equal|pipeline-ahead) return 0 ;;
    unresolvable) [ "$2" = live ] && return 0; return 1 ;;
    *) return 1 ;;
  esac
}

# terminal when the run has reached an outcome or a terminal status word, else
# live. A run's terminality decides how much its code binding must prove.
fm_crew_terminality() {  # <run-output>
  local outcome status
  outcome=$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*outcome:[[:space:]]*\(.*\)/\1/p' | head -1 | tr -d '"' )
  if [ -n "$outcome" ]; then printf 'terminal'; return; fi
  status=$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*status:[[:space:]]*\(.*\)/\1/p' | head -1 | tr -d '"')
  case "$status" in
    completed|failed|cancelled) printf 'terminal' ;;
    *) printf 'live' ;;
  esac
}

# 0 when this run record may be attributed to this worktree at all. The single
# entry point for the qualifier rules in this file's header, liveness override
# included.
fm_crew_run_admits() {  # <worktree> <run-output> <run-head>
  local wt=$1 run_out=$2 run_head=$3 relation terminality
  relation=$(fm_crew_head_relation "$wt" "$run_head")
  terminality=$(fm_crew_terminality "$run_out")
  fm_crew_binding_admits "$relation" "$terminality" && return 0
  # Liveness override: an actively executing step is the daemon stating that
  # this run is alive NOW, and one branch cannot host two concurrent runs, so
  # the run is this task's regardless of head geometry. Non-terminal only.
  [ "$terminality" = live ] || return 1
  [ -n "$(fm_crew_active_step "$run_out")" ]
}

# --- runs-list selection ----------------------------------------------------

# The NEWEST row for <branch> in `no-mistakes runs` output, as
# "<status>|<short-sha>|<pr-url>" ("" when the branch has no row). Rows are
# newest-first, plain text, unquoted: "<status> <branch> <short-sha> <date>
# <time> [<pr-url>]".
#
# Deliberately returns the first match and stops. Continuing past it to find a
# row whose sha binds to the local checkout is defect 1: the newest run is the
# only one that can be current, so a non-binding newest row means "cannot
# attribute", never "try the run before it".
fm_crew_runs_newest_row_for_branch() {  # <runs-output> <branch>
  printf '%s\n' "$1" | awk -v want="$2" '
    { sub(/^[[:space:]]+/, "") }
    $2 == want { printf "%s|%s|%s\n", $1, $3, ($6 == "" ? "" : $6); exit }
  '
}

# --- forge confirmation -----------------------------------------------------

# "<owner>/<repo>|<number>" parsed from a GitHub PR URL; empty when the URL is
# not a recognizable PR.
fm_crew_pr_ref() {  # <pr-url>
  printf '%s' "$1" \
    | sed -n 's#^https\{0,1\}://[^/]*github\.com/\([^/]\{1,\}\)/\([^/]\{1,\}\)/pull/\([0-9]\{1,\}\).*#\1/\2|\3#p'
}

# The forge's own word on a PR: merged, closed, open, or unverified, optionally
# followed by " <mergeStateStatus>". This is the guard that stops the unsafe
# direction: a merged-or-closed claim is only ever emitted from THIS answer,
# never inferred from run state. Unverified is not a failure to report - it is
# the honest answer when gh is absent, unauthenticated, bounded out, or the PR
# is unreadable, and it must never be rendered as a landing.
#
# bin/fm-timeout-lib.sh owns the bound; the caller must source it.
fm_crew_forge_pr_state() {  # <pr-url> <timeout-secs>
  local url=$1 timeout_secs=$2 ref slug number out state merge_state
  ref=$(fm_crew_pr_ref "$url")
  [ -n "$ref" ] || { printf 'unverified'; return; }
  command -v gh >/dev/null 2>&1 || { printf 'unverified'; return; }
  case "$timeout_secs" in ''|*[!0-9]*|0) timeout_secs=10 ;; esac
  slug=${ref%%|*}
  number=${ref#*|}
  out=$(fm_run_timed "$timeout_secs" \
    env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    gh pr view "$number" --repo "$slug" --json state,mergeStateStatus 2>/dev/null) \
    || { printf 'unverified'; return; }
  state=$(printf '%s' "$out" | sed -n 's/.*"state":[[:space:]]*"\([^"]*\)".*/\1/p')
  merge_state=$(printf '%s' "$out" | sed -n 's/.*"mergeStateStatus":[[:space:]]*"\([^"]*\)".*/\1/p')
  case "$state" in
    MERGED) printf 'merged' ;;
    CLOSED) printf 'closed' ;;
    OPEN)   printf 'open' ;;
    *)      printf 'unverified'; return ;;
  esac
  case "$merge_state" in
    ''|UNKNOWN) : ;;
    *) printf ' %s' "$merge_state" ;;
  esac
}

# Verdict detail for a run that reached a terminal pass. The merged/closed words
# come from the forge answer or not at all. The lead phrase distinguishes the two
# evidence levels honestly: "run passed" when this run's own ci step was seen to
# complete, "run completed" when the record carried no step detail to check (the
# runs-list path), because that path cannot rule out a skipped ci step.
fm_crew_done_detail() {  # <forge-answer> <ci-evidence: verified|unverified>
  local answer=$1 word=${1%% *} qualifier="" lead=run\ completed
  [ "${2:-unverified}" = verified ] && lead=run\ passed
  case "$answer" in *' '*) qualifier=" (${answer#* })" ;; esac
  case "$word" in
    merged) printf '%s: PR merged' "$lead" ;;
    closed) printf '%s: PR closed' "$lead" ;;
    open)   printf '%s: PR open, not merged%s' "$lead" "$qualifier" ;;
    *)      printf '%s: merge state unverified' "$lead" ;;
  esac
}

# Verdict detail for a run that reached outcome passed/checks-passed with its ci
# step SKIPPED. Never says done and never says merged: nothing validated this
# work, and the run's own claim of passing is not evidence that it did.
fm_crew_ci_skipped_detail() {  # <forge-answer>
  local answer=$1 word=${1%% *}
  printf 'run completed with ci SKIPPED: no CI evidence'
  case "$word" in
    merged) printf ', PR merged' ;;
    closed) printf ', PR closed' ;;
    open)   printf ', PR still open' ;;
    *)      printf ', PR state unverified' ;;
  esac
  case "$answer" in *' '*) printf ' (%s)' "${answer#* }" ;; esac
}
