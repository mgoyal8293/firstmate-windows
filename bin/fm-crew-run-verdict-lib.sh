#!/usr/bin/env bash
# fm-crew-run-verdict-lib.sh - the state model for turning ONE no-mistakes run
# record into a crew verdict, plus the evidence gates that stop a wrong verdict
# from being emitted.
#
# Sourced, never executed. bin/fm-crew-state.sh is the only caller; this file
# owns the model so the rules below live in one place instead of being spread
# through that script's control flow. It composes with three libraries the caller
# must source rather than restating any of them: bin/fm-nm-run-lib.sh owns the
# TOON scalar read, bin/fm-pr-lib.sh owns PR/MR URL identity, and
# bin/fm-timeout-lib.sh owns the bound on the one forge read.
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
#   * outcome checks-passed, or a ci-step log tail reading green while the run
#     monitors                                    -> done, checks green, PR ready
#     for review, through fm_crew_checks_green_verdict. That word is a statement
#     about the CHECKS, so it is CI evidence in its own right and needs no
#     corroborating ci-step row. Where merge is left to the captain the ci step
#     stays `running` for the whole monitor phase, so requiring one would
#     withhold the very signal a captain waits for. It is NOT exempt from the
#     forge read, though: green checks prove CI ran and say nothing about where
#     the PR ended up, so a forge-confirmed CLOSE settles failed here too.
#   * a run that TERMINATED - outcome passed, status completed with no outcome
#     word, or a coarse runs-list `completed` row - goes through ONE ranking,
#     fm_crew_terminal_verdict, which both paths call so they cannot rank the same
#     evidence differently: a forge-confirmed MERGE settles done whatever the ci
#     step says, a forge-confirmed CLOSE is the terminal NON-landing and settles
#     failed, and the merged/closed words are emitted ONLY from that live answer
#     (fm_crew_forge_pr_state); else this run's own `ci` step recorded `completed`
#     settles done with no landing claimed; else unknown, with the detail naming
#     the terminated run, the ci word (or its absence) that settled it and the
#     forge's own answer. A path with no steps table to read says so by passing
#     FM_CREW_CI_NO_STEP_DETAIL, which is missing evidence inside that one
#     ranking rather than a second ranking. See fm_crew_terminal_verdict for the
#     amended acceptance criterion behind the merge rule, for why a close is not
#     a landing, and for why unknown rather than `parked` is the honest word when
#     nothing settles it.
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
# A STATE WORD MUST BE HONEST STANDALONE. This governs every state-word choice
# in this file, and it is not a style preference: consumers drop the detail at
# the captain-facing boundary. bin/fm-inactive-reconcile.sh builds its captain
# presentation from the state word and the PR alone, so a word that carries a
# false implication once its detail is stripped becomes a false claim to the
# captain no matter how careful the detail line was. When that happens the fix is
# to make the WORD honest, never to teach one more consumer to read the fine
# print: a state word that lies while a payload tells the truth is a trap for the
# next reader, and the trap is sprung by the consumer that did not get the memo.
#
# Three rulings in this file are instances of that one rule:
#   1. `parked` reused for a terminated run. The word already meant "parked at a
#      gate the worker can respond to", so consumers that clear an answered
#      decision on leaving `parked` stopped clearing it. Ruled: `unknown`.
#   2. `done` for a terminated run whose CI evidence is absent. `outcome: passed`
#      means the PIPELINE completed, so the word claimed a validation that never
#      happened. Ruled: `unknown`.
#   3. `done` for a forge-confirmed CLOSE, ranked with a merge as one "landing".
#      A closed-unmerged PR is the OPPOSITE of a landing - the work will never
#      land - and stripped of its "PR closed" detail it presented ABANDONED work
#      to the captain as a success. Ruled: `failed`.
#
# Ruling 3 was first applied only to fm_crew_terminal_verdict, and the same false
# success promptly turned up one route over: `outcome: checks-passed` reached
# `done` without ever asking the forge. That is the shape of this failure - a word
# is made honest on the path it was caught on, while a sibling path still emits
# it - so the rule is now enforced as a property of the READER rather than of one
# ranking: bin/fm-crew-state.sh never emits `done` without asking the forge where
# the PR ended up, and fm_crew_checks_green_verdict answers for every route that
# reaches `done` with green checks. When you add a path that can say `done`, that
# is the invariant to satisfy.
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
#
# bin/fm-nm-run-lib.sh owns the TOON scalar shape and the caller sources it, so
# this only narrows WHAT is read to the run record's own scalars. Restating that
# reader here would give the same records two owners, and a later change to the
# shape would land in one of them.
fm_crew_run_field() {  # <run-output> <key>
  fm_nm_field "$(fm_crew_run_scalars "$1")" "$2"
}

# Status word of one step in a run's `steps[N]{step,status,...}` table, e.g.
# `ci`. Empty when the run record has no row for that step.
#
# The recorded tables are unpadded and unquoted, but this column decides done
# versus unknown for every full-path terminal pass, so it tolerates surrounding
# whitespace and quoting rather than depending on that: `ci, completed,0,4221`
# must not read as a missing pass. bin/fm-nm-run-lib.sh owns the trim-and-unquote
# and the readers of the same table in bin/fm-crew-state.sh are written the same
# way.
fm_crew_step_status() {  # <run-output> <step-name>
  fm_nm_strip_quotes "$(printf '%s\n' "$1" \
    | sed -n "s/^[[:space:]]*$2[[:space:]]*,\([^,]*\),.*/\1/p" \
    | head -1)"
}

# The first RUNNING or FIXING row of a run's `active_steps[N]{...}` table, as
# "<step>|<status>|<active_for>|<last_activity>". Empty when the run has no
# active step, which is the daemon's own statement that nothing is executing.
#
# Columns are read by NAME from the table header rather than by position, each
# split value is trimmed before the status word is compared - a padded
# `test, running, 3m38s` must not silently stop the liveness override - and the
# row is split quote-aware, because `last_activity` is a quoted free-text field
# that routinely contains commas of its own:
#   review,fixing,1h27m,"9m52s ago: log: I'll review the changes, then...","2010043",fix 3
#
# The table ends at a blank line, a line with no comma, or ANY following TOON
# table header. That last one matters because a header carries commas inside its
# braces (`steps[9]{step,status,findings,duration_ms}:`), so without it a table
# emitted after active_steps is read as active_steps rows under active_steps'
# column names - which would report a `steps` row as the live activity. The
# recorded field order puts `steps` first, and this reader does not depend on it.
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
      if (row ~ /^[A-Za-z_][A-Za-z0-9_]*\[[0-9]+\]\{/) { in_table = 0; next }
      # Quote-aware field split: a comma inside double quotes is data.
      nval = 0; cur = ""; inq = 0
      for (i = 1; i <= length(row); i++) {
        c = substr(row, i, 1)
        if (c == "\"") { inq = !inq; continue }
        if (c == "," && !inq) { val[++nval] = cur; cur = ""; continue }
        cur = cur c
      }
      val[++nval] = cur
      for (i = 1; i <= nval; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val[i])
      }
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
#
# The status and the sha are the row's first and third fields, but the PR url is
# found by SHAPE, not by column index. It is load-bearing on this path - a coarse
# `completed` row reads done only on a forge-confirmed merge or close - and the
# date column has been described both as one field and as two, so any fixed index
# is one layout change away from handing a timestamp to the URL owner and leaving
# every completed row unknown forever with "PR url not recognized". A field
# starting `http://` or `https://` cannot be confused with a status word, a
# branch, a sha or a date; bin/fm-pr-lib.sh still rules on whether it is a PR or
# MR at all.
fm_crew_runs_newest_row_for_branch() {  # <runs-output> <branch>
  printf '%s\n' "$1" | awk -v want="$2" '
    { sub(/^[[:space:]]+/, "") }
    $2 == want {
      url = ""
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^https?:\/\//) { url = $i; break }
      }
      printf "%s|%s|%s\n", $1, $3, url
      exit
    }
  '
}

# --- forge confirmation -----------------------------------------------------

# The forge's own word on a PR, as exactly one of:
#   merged | closed | open   the forge answered, optionally followed by
#                            " <mergeStateStatus>"
#   unverified               TRANSIENT non-answer: the client ran and did not
#                            answer - unauthenticated, bounded out, or the PR was
#                            unreadable. A later read can clear it.
#   unqueryable <provider>   STRUCTURAL non-answer: a valid PR/MR URL with no
#                            usable forge client on this host for that provider,
#                            either because this reader knows no client for it
#                            (gitlab) or because the one it knows is not
#                            installed (github with no `gh`). No later read
#                            clears either, so the detail names the provider
#                            instead of letting a permanent condition read as a
#                            passing network failure.
#   unparseable              STRUCTURAL non-answer: not a recognizable PR or MR
#                            URL at all.
#
# A host with no `gh` is as permanent as an unsupported provider - both are "no
# forge client here for <provider>", and the only difference is which side of the
# gap is missing - so an absent binary takes the structural word too. It was the
# transient one once, and on the coarse path, where a `completed` row reads done
# only on a forge-confirmed merge, that made every finished GitHub run on a
# gh-less host read `PR state unverified` forever with no way to tell it from a
# call that will succeed on the next heartbeat.
#
# This is the guard that stops the unsafe direction: a merged-or-closed claim is
# only ever emitted from THIS answer, never inferred from run state. None of the
# three non-answers is a failure to report - each is the honest word for a
# different situation - and none may ever be rendered as a landing.
#
# Withholding the merged claim is the whole of what a non-answer costs. A
# terminal run whose own `ci` step is recorded `completed` still reads done on a
# project this reader cannot query, because that run carries its own CI evidence;
# a run with neither that evidence nor an answer stays unknown, and it now says
# which of the two is missing.
#
# bin/fm-pr-lib.sh owns PR/MR URL identity and bin/fm-timeout-lib.sh owns the
# bound; the caller must source both. Parsing the URL here instead would be a
# second answer to a question that already has an owner, and the two disagreed:
# the owner refuses `http://`, refuses a host merely ending in `github.com`, and
# knows GitLab, none of which a local regex did.
fm_crew_forge_pr_state() {  # <pr-url> <timeout-secs>
  local url=$1 timeout_secs=$2 out state merge_state
  fm_pr_url_parse "$url" || { printf 'unparseable'; return; }
  # One gate for both halves of "no forge client here": a provider with no client
  # in this reader at all, and a provider whose client is simply not installed.
  # shellcheck disable=SC2154 # Set by fm_pr_url_parse in bin/fm-pr-lib.sh.
  case "$FM_PR_PROVIDER" in
    github) command -v gh >/dev/null 2>&1 ;;
    *) false ;;
  esac || { printf 'unqueryable %s' "$FM_PR_PROVIDER"; return; }
  # Same floor as FM_CREW_STATE_FORGE_TIMEOUT's default, which owns the figure
  # and the measurement behind it.
  case "$timeout_secs" in ''|*[!0-9]*|0) timeout_secs=3 ;; esac
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

# Verdict detail for a run that reached a terminal pass. The merged word comes
# from the forge answer or not at all. The lead phrase reports the CI evidence
# level and nothing else: "run passed" only when this run's own ci step was seen
# to complete, and "run completed" for every other level - an absent ci row, a
# recorded `skipped`, any other status word, and the runs-list path that carries
# no steps table at all. So a full-path run with `ci,skipped` whose PR the forge
# confirms merged reads "run completed: PR merged": done on the landing, and the
# lead deliberately withholding a claim that its checks ran.
#
# A forge-confirmed CLOSE never reaches here. It is not a done detail, because it
# is not a landing: fm_crew_terminal_verdict ranks it failed and renders it with
# fm_crew_closed_detail.
fm_crew_done_detail() {  # <forge-answer> <ci-evidence: verified|unverified>
  local answer=$1 word=${1%% *} rest="" qualifier="" lead=run\ completed
  [ "${2:-unverified}" = verified ] && lead=run\ passed
  case "$answer" in *' '*) rest=${answer#* }; qualifier=" ($rest)" ;; esac
  case "$word" in
    merged) printf '%s: PR merged' "$lead" ;;
    open)   printf '%s: PR open, not merged%s' "$lead" "$qualifier" ;;
    unqueryable)
      printf '%s: merge state unreadable here, no forge client for %s' "$lead" "$rest" ;;
    unparseable)
      printf '%s: merge state unreadable, PR url not recognized' "$lead" ;;
    *)      printf '%s: merge state unverified' "$lead" ;;
  esac
}

# Verdict detail for a run whose PR the forge confirms was CLOSED without ever
# being merged: the terminal NON-landing. It names the close explicitly rather
# than leaning on the state word, because the two say different halves of it -
# `failed` says the work is over and did not succeed, this says why.
#
# The lead still reports the CI evidence level, on the same rule the done detail
# uses, so a reader can still tell a closed PR whose checks ran from one whose
# checks never did. Neither changes the verdict: a close settles the run whatever
# the ci step recorded, exactly as a merge does.
fm_crew_closed_detail() {  # <forge-answer> <ci-evidence: verified|unverified>
  local rest="" lead=run\ completed
  [ "${2:-unverified}" = verified ] && lead=run\ passed
  case "$1" in *' '*) rest=${1#* } ;; esac
  printf '%s: PR closed without merging, the work never landed' "$lead"
  case "$rest" in ?*) printf ' (%s)' "$rest" ;; esac
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
    closed) printf ', PR closed without merging' ;;
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
    "$FM_CREW_CI_NO_STEP_DETAIL") printf 'no step detail on the runs-list path' ;;
    '')      printf 'no ci step recorded' ;;
    skipped) printf 'ci SKIPPED' ;;
    *)       printf 'ci %s' "$1" ;;
  esac
}

# Verdict detail for a run that reached a terminal pass with NO CI evidence.
# Never says done and never says merged on its own: nothing validated this work,
# and the run's own claim of passing is not evidence that it did.
#
# This detail carries ALL the precision the blunt `unknown` state word gives up,
# and it is the reason that word is safe to be blunt: it says the run TERMINATED,
# names the <gap> - the ci-step word, or its absence, that settled the question -
# and appends the forge's own answer about the PR. A reader loses nothing.
fm_crew_no_ci_evidence_detail() {  # <gap> <forge-answer>
  printf 'run terminated with %s: no CI evidence, cannot tell whether it passed' "$1"
  fm_crew_forge_suffix "$2"
}

# Sentinel <ci-step-status> for a path that carries NO steps table at all, so it
# cannot answer the ci question either way. The coarse runs-list path passes this;
# no TOON status word can collide with it.
FM_CREW_CI_NO_STEP_DETAIL='(no steps table)'

# THE ranking for a run that has TERMINATED - `outcome: passed`, `status:
# completed` with no outcome word, or a coarse runs-list `completed` row - as
# "<state>|<detail>". NOT the path for `outcome: checks-passed`, which carries its
# own statement about the checks and is settled before this is reached.
#
# ONE owner, called by BOTH the full `axi status` path and the coarse runs-list
# path. They must not rank this evidence separately: they did once, in opposite
# orders, and the result was that the SAME world state read `done` or `unknown`
# depending only on whether an unrelated crew happened to have started a run,
# which decides which listing answers for this branch. A path that knows less
# says so by passing FM_CREW_CI_NO_STEP_DETAIL as its ci-step status - missing
# evidence fed into this ranking, never a second ranking.
#
# The order, strongest evidence first:
#   1. A forge-confirmed MERGE settles DONE, whatever the ci step says. For the
#      question actually being asked, a merge is STRONGER evidence than ci
#      completion: the merge proves the work LANDED, while ci completion only
#      proves that checks ran. The defect this whole model exists to kill was
#      claiming merged when nothing merged, and a confirmed merge cannot be that
#      defect.
#   1b. A forge-confirmed CLOSE settles FAILED. It is terminal on the same
#      authority as the merge and needs no ci evidence either, but it is the
#      opposite outcome, so it gets the opposite word.
#   2. Otherwise this run's own `ci` step recorded `completed` settles DONE, with
#      the merge state reported as open or unverified and no landing claimed.
#   3. Otherwise UNKNOWN, naming what is missing. `passed` says only that the
#      PIPELINE completed, so it can hide a skipped ci step - the destructive
#      direction - and a skipped step, an absent `ci` row, a record with no steps
#      table, and any other status word are all the ABSENCE of validation.
#
# The acceptance criterion behind rule 1 was AMENDED by the same authority that
# set it, from "a skipped ci step never reads as done" to "a skipped ci step never
# reads as done BY ITSELF". Rule 1 is the amendment; without it, a merged crew on
# a repo with no CI configured (every run records `ci,skipped`) read unknown
# forever, its terminal outcome never reconciled, until an unrelated crew started
# a run and pushed the same world state onto the coarse path, where it read done.
# See docs/verification/crew-state-verdicts.md for that case in full. Rule 1b does
# not touch that amendment: a confirmed MERGE still settles done whatever the ci
# step said, and only a confirmed CLOSE was moved off it.
#
# Rule 1b corrects the RULE, not the implementation of it. The approved rule said
# "a forge-confirmed landing", and the code faithfully implemented that wording -
# but a closed-unmerged PR is the opposite of a landing, because the work will
# never land. Closed is not merged. The decisive consequence is downstream:
# bin/fm-inactive-reconcile.sh builds its captain presentation from the state word
# and the PR alone, so "PR closed" is dropped exactly at the captain-facing
# boundary, and ABANDONED work was presented to the captain as a success. A false
# success is the worst direction this tool can fail in.
#
# The alternative - keep `done` and carry the detail into the reconcile payload -
# was REJECTED. It fixes one consumer and leaves the word itself lying, and a
# state word that lies while a payload tells the truth is a trap for the next
# reader: the next consumer to read the word without the payload springs it. See
# this file's header for the standalone-honesty rule this is the third instance
# of.
#
# `unknown` at rule 3, rather than `parked`, is deliberate too:
#   * unknown is the HONEST word. A terminated run with no CI evidence and no
#     confirmed landing means exactly "I cannot tell whether this passed", which
#     is the principle the whole model rests on - prefer unknown to a confident
#     wrong answer wherever the evidence does not settle it.
#   * `parked` was tried here first and was wrong, because that word already
#     meant "parked at a gate the worker can respond to", and a terminated run is
#     not a gate anyone can respond to. Two meanings in one word is what let them
#     drift.
#   * The overload did real harm, worse than a blunt label: consumers that clear
#     an answered decision when the run moves off `parked` stopped clearing it,
#     so an already-resolved decision could resurface and drive the fleet posture
#     to a captain decision citing a resolved key - a false demand for the
#     captain's attention.
# No precision is lost, because the detail helpers carry it. And unknown is still
# non-terminal, so it cannot license teardown or a captain-facing failure either.
#
# ACCEPTED RESIDUAL, not an oversight. Rule 2 can only ever be satisfied by a path
# that can read a steps table, so one run with `ci,completed` and no confirmed
# landing reads done on the full path and unknown on the coarse one - reachable on
# a GitLab project (always `unqueryable`), on a host with no `gh`, and whenever
# bin/fm-inactive-reconcile.sh skips the forge read because its budget cannot
# spare it. That is NOT the contradiction rule 1 fixed, and the distinction is the
# whole reason it is acceptable: there the two paths held the SAME evidence and
# ranked it differently, which is indefensible; here they hold DIFFERENT evidence,
# because a coarse row cannot see the ci table at all, so each answer is honest
# about what that path actually observed. The direction is conservative - unknown,
# never a false done - and the cost is a delayed presentation receipt, not a wrong
# verdict. The remedy is the filed runs-list upgrade named in bin/fm-crew-state.sh
# (try the home view first and re-query any id it yields, so this path reads the
# same steps table), NOT giving this ranking a second way to guess at ci evidence.
fm_crew_terminal_verdict() {  # <ci-step-status> <forge-answer>
  local ci=$1 answer=$2 evidence=unverified
  [ "$ci" = completed ] && evidence=verified
  case "${answer%% *}" in
    merged)
      printf 'done|%s' "$(fm_crew_done_detail "$answer" "$evidence")"
      return ;;
    closed)
      printf 'failed|%s' "$(fm_crew_closed_detail "$answer" "$evidence")"
      return ;;
  esac
  if [ "$evidence" = verified ]; then
    printf 'done|%s' "$(fm_crew_done_detail "$answer" "$evidence")"
    return
  fi
  printf 'unknown|%s' \
    "$(fm_crew_no_ci_evidence_detail "$(fm_crew_ci_evidence_gap "$ci")" "$answer")"
}

# THE ranking for a run whose CHECKS are GREEN but which has not terminated -
# `outcome: checks-passed`, and the ci-step log tail that reads green while the
# run monitors the PR - as "<state>|<detail>". The <ready-detail> is the
# ready-for-review signal that path exists to produce, and it survives untouched
# on every answer but one.
#
# TWO DIFFERENT QUESTIONS, and conflating them is exactly how this regresses:
#   * What proves CI RAN? `checks-passed` is a statement about the CHECKS, so it
#     is CI evidence IN ITS OWN RIGHT and needs no corroborating `ci,completed`
#     row. That ruling stands entirely untouched. Where merge is left to the
#     captain the ci step stays `running` for the whole monitor phase, so
#     demanding a completed row would withhold the very signal a captain waits
#     for.
#   * What proves WHERE THE PR ENDED UP? Nothing in the run record does. Green
#     checks say the work is ready to land. They say nothing about whether it
#     landed, and nothing about whether the captain threw it away.
# Green checks answer the first question and are silent on the second, so this
# path is no longer EXEMPT from the forge read - it keeps its own CI evidence and
# gains the forge's answer about the PR, because those are separate facts.
#
# A forge-confirmed CLOSE settles FAILED here, on the same authority and for the
# same reason as rule 1b of fm_crew_terminal_verdict: the work was abandoned and
# will never land. This arm is the worse of the two to get wrong. `done - checks
# green: PR ready for review` does not merely overstate an abandoned branch, it
# actively invites the captain to go and review work that was already thrown
# away, and bin/fm-inactive-reconcile.sh strips the detail before the captain
# ever sees it. See this file's header for the standalone-honesty rule.
#
# Every other answer keeps `done`. A confirmed merge names the merge, through the
# same suffix owner every other detail line uses; an open PR or any non-answer
# leaves the ready-for-review detail exactly as it was, because none of them
# contradicts what green checks proved.
fm_crew_checks_green_verdict() {  # <forge-answer> <ready-detail>
  case "${1%% *}" in
    closed) printf 'failed|%s' "$(fm_crew_closed_detail "$1" verified)" ;;
    merged) printf 'done|%s%s' "$2" "$(fm_crew_forge_suffix "$1")" ;;
    *)      printf 'done|%s' "$2" ;;
  esac
}
