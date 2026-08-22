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
#     task worktree never fetched. Admits a NON-TERMINAL verdict on geometry
#     alone - enough to report the task alive - and a TERMINAL one only once
#     ownership is positively proven (fm_crew_pipeline_ownership_proven).
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
#   * outcome checks-passed                       -> done, checks green, PR ready
#     for review. That word is a statement about the CHECKS, so it is CI evidence
#     in its own right and needs no corroborating ci-step row. Where merge is
#     left to the captain the ci step stays `running` for the whole monitor
#     phase, so requiring one would withhold the very signal a captain waits for.
#   * outcome passed, ci COMPLETED                -> done, and the merged/closed
#     claim is emitted ONLY when the forge confirms it (fm_crew_forge_pr_state)
#   * outcome passed, ci NOT COMPLETED            -> NOT done. `passed` says only
#     that the PIPELINE completed, so it can hide a skipped ci step - the
#     destructive direction. CI evidence is a WHITELIST here: only this run's own
#     `ci` step recorded as `completed` proves that CI ran. Skipped, absent, or
#     any other status word is the ABSENCE of that evidence, and it reports
#     parked: it needs a ruling, not a landing. Same rule for a run whose status
#     is `completed` with no outcome word at all.
#     See fm_crew_terminal_pass_verdict.
#   * a coarse runs-list `completed` row carries no steps table at all, so it can
#     never satisfy that whitelist: it reads done only when the forge confirms
#     merged or closed, and parked otherwise. See
#     fm_crew_coarse_completed_verdict.
#
# PROVING PIPELINE OWNERSHIP. An unresolvable head is refused a terminal verdict
# on geometry alone because geometry cannot tell "the pipeline pushed commits we
# have not fetched" from "the branch tip was rewritten and the old head pruned".
# `axi status` settles that itself, at no extra process cost: invoked from the
# task worktree - which is how this reader always invokes it - its answer carries
# a `branch_sync:` block whose `pipeline.run`, `pipeline.current_head`,
# `pipeline.pushed_head` and `local.head` state which run owns this branch, what
# head it has advanced to, and which checkout the block describes. No `axi sync`
# call is involved, and none should be: `axi sync` without `--check` APPLIES a
# plan, which a read-only current-state reader must never do.
#
# Three equalities have to hold before that block may widen anything, and each
# closes a different way of being wrong:
#   * pipeline.run equals this run's id, so a binding for a DIFFERENT run can
#     never vouch for this one;
#   * pipeline.current_head or pipeline.pushed_head equals the run head under
#     test, so the block is about the head we could not resolve;
#   * local.head equals this worktree's HEAD, so the block describes THIS
#     checkout.
# Anything missing, empty, or mismatched leaves the conservative refusal in
# place, so the proof only ever adds attribution and never removes it.
#
# Observed: the block is present for a live pipeline-owned run, and absent when
# the invoking worktree's branch has no push binding at all (a runless branch
# gets no block even though `axi status` still answers with another branch's
# run - which is exactly what the pipeline.run equality is for). Its persistence
# for a TERMINAL run on its own branch is expected but not yet observed here, and
# `axi sync --recover`'s own contract - returning custody of a branch stranded by
# a terminal run - is the reason to expect it. Where it is absent the terminal
# refusal simply stands, so that gap costs a handling turn and nothing else.
# docs/verification/crew-state-verdicts.md owns refreshing that observation.
#
# Everywhere the evidence does not settle the question, the answer is the
# conservative one. A tool that says "I do not know" costs a handling turn; a
# tool that says "merged" when nothing merged costs the work.
set -u

# --- run record parsing -----------------------------------------------------

# The run record with its `branch_sync:` block removed, for scalar key reads.
#
# `axi status` emits the run's own fields under `run:`, its terminal `outcome:`
# and `error:` as top-level siblings, and `branch_sync:` as a separate top-level
# block whose `local:` and `pipeline:` sub-blocks REPEAT key names the run object
# uses - `branch`, `head`, `status`, `run`. A flat key match over the whole
# document therefore cross-reads one section's value as the other's whenever the
# run object omits the key: a record with no `head:` of its own resolves
# `branch_sync.local.head`, which is this worktree's HEAD by construction, so the
# head binding would report `equal` and admit a terminal verdict for a run whose
# code identity was never checked. Every scalar read of the run record goes
# through this first; fm_crew_branch_sync_field is the only reader allowed inside
# the block, and it is indent-scoped in the opposite direction.
fm_crew_run_scalars() {  # <run-output>
  printf '%s\n' "$1" | awk '
    /^[^[:space:]]/ { in_bs = ($0 ~ /^branch_sync:/) }
    !in_bs
  '
}

# Scalar value of a top-level-or-run-object TOON key, read with the branch_sync
# block excluded. Empty when the key is absent from the run record.
fm_crew_run_field() {  # <run-output> <key>
  fm_crew_run_scalars "$1" \
    | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" \
    | head -1
}

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

# --- branch_sync (pipeline ownership) ---------------------------------------

# Scalar value of <key> inside the <block> sub-block of a run record's
# `branch_sync:` section, e.g. `pipeline current_head` or `local head`. Empty
# when the section, the sub-block, or the key is absent - which is the normal
# answer for a branch with no pipeline push binding.
#
# Read with indent awareness rather than a bare grep on purpose: `branch_sync`
# repeats key names the run block also uses (`branch`, `status`, `run`), so an
# unscoped match would silently cross-read one section's value for another's.
fm_crew_branch_sync_field() {  # <run-output> <block> <key>
  printf '%s\n' "$1" | awk -v blk="$2" -v key="$3" '
    /^branch_sync:/ { in_bs = 1; next }
    in_bs && /^[^[:space:]]/ { exit }
    !in_bs { next }
    /^  [^[:space:]]/ {
      in_blk = ($0 ~ "^  " blk ":[[:space:]]*$")
      next
    }
    in_blk && $0 ~ "^    " key ":" {
      value = $0
      sub("^    " key ":[[:space:]]*", "", value)
      gsub(/"/, "", value)
      print value
      exit
    }
  '
}

# 0 when two commit ids name the same commit, either being abbreviated. A run
# record reports a short head while branch_sync reports the full sha, so an exact
# comparison would never match; a prefix comparison with a floor stops a
# degenerate empty or near-empty value from matching everything.
fm_crew_sha_matches() {  # <sha-a> <sha-b>
  local a=$1 b=$2 short long
  [ -n "$a" ] && [ -n "$b" ] || return 1
  if [ ${#a} -le ${#b} ]; then short=$a; long=$b; else short=$b; long=$a; fi
  [ ${#short} -ge 7 ] || return 1
  case "$long" in "$short"*) return 0 ;; esac
  return 1
}

# 0 when the run record itself proves that the pipeline owns this branch and has
# advanced it to <run-head>. See this file's header for what each equality rules
# out; all three must hold, and an absent branch_sync block proves nothing.
fm_crew_pipeline_ownership_proven() {  # <run-output> <worktree> <run-head>
  local run_out=$1 wt=$2 run_head=$3 run_id bs_run bs_current bs_pushed bs_local local_head
  bs_run=$(fm_crew_branch_sync_field "$run_out" pipeline run)
  [ -n "$bs_run" ] || return 1
  run_id=$(fm_crew_run_field "$run_out" id | tr -d '"')
  [ -n "$run_id" ] && [ "$bs_run" = "$run_id" ] || return 1
  bs_current=$(fm_crew_branch_sync_field "$run_out" pipeline current_head)
  bs_pushed=$(fm_crew_branch_sync_field "$run_out" pipeline pushed_head)
  fm_crew_sha_matches "$bs_current" "$run_head" ||
    fm_crew_sha_matches "$bs_pushed" "$run_head" || return 1
  bs_local=$(fm_crew_branch_sync_field "$run_out" local head)
  local_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  fm_crew_sha_matches "$bs_local" "$local_head"
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
  outcome=$(fm_crew_run_field "$1" outcome | tr -d '"')
  if [ -n "$outcome" ]; then printf 'terminal'; return; fi
  status=$(fm_crew_run_field "$1" status | tr -d '"')
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
  # Ownership proof: geometry could not resolve the run head, but the run record
  # itself shows the pipeline owns this branch and advanced it to exactly that
  # head, from this checkout. That distinguishes an unfetched pipeline head from
  # a pruned rewrite, which is the only reason a terminal verdict was withheld.
  if [ "$relation" = unresolvable ] &&
    fm_crew_pipeline_ownership_proven "$run_out" "$wt" "$run_head"; then
    return 0
  fi
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

# The forge's own word on a PR, as exactly one of:
#   merged | closed | open   the forge answered, optionally followed by
#                            " <mergeStateStatus>"
#   unverified               TRANSIENT non-answer: gh is absent, unauthenticated,
#                            bounded out, or the PR was unreadable. A later read
#                            can clear it.
#   unqueryable <provider>   STRUCTURAL non-answer: a valid PR/MR URL for a
#                            provider this reader has no forge client for. No
#                            later read clears it, so the detail names the
#                            provider instead of letting a permanent condition
#                            read as a passing network failure.
#   unparseable              STRUCTURAL non-answer: not a recognizable PR or MR
#                            URL at all.
#
# This is the guard that stops the unsafe direction: a merged-or-closed claim is
# only ever emitted from THIS answer, never inferred from run state. None of the
# three non-answers is a failure to report - each is the honest word for a
# different situation - and none may ever be rendered as a landing.
#
# Withholding the merged claim is the whole of what a non-answer costs. A
# full-path terminal pass whose own `ci` step is recorded `completed` still reads
# done on a project this reader cannot query, because that run carries its own CI
# evidence; only the coarse runs-list path, which has none to fall back on, stays
# parked there, and it now says why.
#
# bin/fm-pr-lib.sh owns PR/MR URL identity and bin/fm-timeout-lib.sh owns the
# bound; the caller must source both. Parsing the URL here instead would be a
# second answer to a question that already has an owner, and the two disagreed:
# the owner refuses `http://`, refuses a host merely ending in `github.com`, and
# knows GitLab, none of which a local regex did.
fm_crew_forge_pr_state() {  # <pr-url> <timeout-secs>
  local url=$1 timeout_secs=$2 out state merge_state
  fm_pr_url_parse "$url" || { printf 'unparseable'; return; }
  # shellcheck disable=SC2154 # Set by fm_pr_url_parse in bin/fm-pr-lib.sh.
  [ "$FM_PR_PROVIDER" = github ] ||
    { printf 'unqueryable %s' "$FM_PR_PROVIDER"; return; }
  command -v gh >/dev/null 2>&1 || { printf 'unverified'; return; }
  case "$timeout_secs" in ''|*[!0-9]*|0) timeout_secs=10 ;; esac
  # FM_PR_PATH is owner/repository for a github URL, which is what --repo takes.
  out=$(fm_run_timed "$timeout_secs" \
    env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    gh pr view "$FM_PR_NUMBER" --repo "$FM_PR_PATH" \
    --json state,mergeStateStatus 2>/dev/null) \
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
  local answer=$1 word=${1%% *} rest="" qualifier="" lead=run\ completed
  [ "${2:-unverified}" = verified ] && lead=run\ passed
  case "$answer" in *' '*) rest=${answer#* }; qualifier=" ($rest)" ;; esac
  case "$word" in
    merged) printf '%s: PR merged' "$lead" ;;
    closed) printf '%s: PR closed' "$lead" ;;
    open)   printf '%s: PR open, not merged%s' "$lead" "$qualifier" ;;
    unqueryable)
      printf '%s: merge state unreadable here, no forge client for %s' "$lead" "$rest" ;;
    unparseable)
      printf '%s: merge state unreadable, PR url not recognized' "$lead" ;;
    *)      printf '%s: merge state unverified' "$lead" ;;
  esac
}

# The forge's own answer as a detail suffix, e.g. ", PR still open (DIRTY)".
# Reports what the forge said and nothing more, so a detail line that carries it
# never turns a non-answer or an open PR into a landing. The two structural
# non-answers are spelled apart from the transient one, because a reader who
# cannot tell them apart waits for a state that will never arrive.
fm_crew_forge_suffix() {  # <forge-answer>
  local answer=$1 word=${1%% *} rest=""
  case "$answer" in *' '*) rest=${answer#* } ;; esac
  case "$word" in
    merged) printf ', PR merged' ;;
    closed) printf ', PR closed' ;;
    open)   printf ', PR still open' ;;
    unqueryable)
      printf ', PR state unreadable here, no forge client for %s' "$rest"
      return 0 ;;
    unparseable)
      printf ', PR url not recognized as a PR or MR'
      return 0 ;;
    *)      printf ', PR state unverified' ;;
  esac
  case "$rest" in ?*) printf ' (%s)' "$rest" ;; esac
  return 0
}

# How this run's `ci` step failed to supply CI evidence, in the words the record
# actually justifies. An absent row is not a skipped row and must not be reported
# as one, and an unrecognized status word is named rather than glossed.
fm_crew_ci_evidence_gap() {  # <ci-step-status>
  case "$1" in
    '')      printf 'no ci step recorded' ;;
    skipped) printf 'ci SKIPPED' ;;
    *)       printf 'ci %s' "$1" ;;
  esac
}

# Verdict detail for a run that reached a terminal pass with NO CI evidence.
# Never says done and never says merged on its own: nothing validated this work,
# and the run's own claim of passing is not evidence that it did. <gap> names why
# the evidence is missing.
fm_crew_no_ci_evidence_detail() {  # <gap> <forge-answer>
  printf 'run completed with %s: no CI evidence' "$1"
  fm_crew_forge_suffix "$2"
}

# The verdict for a run that reached `outcome: passed`, or `status: completed`
# with no outcome word at all, as "<state>|<detail>". NOT the path for
# `outcome: checks-passed`, which carries its own statement about the checks and
# is settled before this is reached.
#
# CI evidence is a WHITELIST, not a blacklist: only this run's own `ci` step
# recorded as `completed` proves that CI ran for this work. A skipped step, an
# absent `ci` row, a record with no steps table at all, and any other status word
# are all the ABSENCE of that evidence, and absence of evidence must never read
# as a pass - reporting done there is the destructive direction, because it
# invites reporting the work as landed and tearing down an unmerged branch.
# Everything outside the whitelist therefore reports `parked`: the run needs a
# ruling, not a landing, and parked is non-terminal so it cannot license teardown
# or a captain-facing failure.
fm_crew_terminal_pass_verdict() {  # <ci-step-status> <forge-answer>
  if [ "$1" = completed ]; then
    printf 'done|%s' "$(fm_crew_done_detail "$2" verified)"
    return
  fi
  printf 'parked|%s' \
    "$(fm_crew_no_ci_evidence_detail "$(fm_crew_ci_evidence_gap "$1")" "$2")"
}

# The verdict for a `completed` row on the coarse runs-list path, as
# "<state>|<detail>".
#
# That row is a status word, a sha and a PR url - there is no steps table on it
# at all, so it can never satisfy the CI-evidence whitelist above and its
# `completed` says only that the pipeline stopped. The one terminal fact still
# available here is the forge's own answer, so a merged or closed PR earns done
# and everything else - open, or any of the three non-answers - reports parked.
# A structural non-answer parks permanently, which is the honest verdict when
# nothing at all proves the run landed; naming it apart from a transient failure
# is what makes that diagnosable rather than silent.
fm_crew_coarse_completed_verdict() {  # <forge-answer>
  case "${1%% *}" in
    merged|closed) printf 'done|%s' "$(fm_crew_done_detail "$1" unverified)" ;;
    *) printf 'parked|%s' \
         "$(fm_crew_no_ci_evidence_detail 'no step detail on the runs-list path' "$1")" ;;
  esac
}
