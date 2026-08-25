#!/usr/bin/env bash
# fm-session-start-bound-lib.sh - the single owner of the session-start runtime
# bound: its per-platform default, its stage breadcrumbs, and how a truncated
# startup attributes the time it spent.
#
# Sourced, never executed. bin/fm-session-start.sh owns the digest and the ten
# stage names in its SESSION_START_STAGES; this file owns only the bound around
# them.
#
# WHY THIS EXISTS. bin/fm-session-start.sh runs its whole digest as one bounded
# child. When that bound is hit the digest truncates, and a truncated startup has
# not drained its wake queue and has not printed its supervision instructions, so
# it is a session that looks started and is not supervising (AGENTS.md sections 3
# and 8). Two separate defects followed from having a single portable bound with
# no attribution:
#
#   1. The default bound was one number for every platform. A fork costs about
#      1 ms on Linux and about 42 ms under MSYS, so the identical digest that
#      finishes in seconds on Linux takes over a minute on Git Bash, and a
#      120 s bound that is generous on one platform is marginal on the other.
#      fm_session_start_default_budget resolves that per platform.
#   2. The truncation banner told the operator to "report the slow stage" while
#      nothing measured a stage, so the one question the banner asks could not be
#      answered without re-running the whole startup by hand under tracing.
#      fm_session_stage_mark records the entry instant of every stage and
#      fm_session_stage_render turns those marks into per-stage elapsed times.
#
# ZERO FORKS ON THE MEASURED PATH, WHICH IS THE POINT. The thing being measured
# is a path whose cost IS its subprocess count, so an instrument that forked per
# stage would inflate the number it exists to report. fm_session_stage_mark is a
# builtin printf and an append redirection reading the EPOCHREALTIME builtin, so
# it spawns nothing. bin/fm-timing-lib.sh is deliberately NOT reused here despite
# owning a superset record format: its fm_timing_record sanitizes through four
# command substitutions per record, which is about five forks per call, and it is
# inert unless FM_TIMING_LOG is set, whereas these marks must always be present
# because a truncation cannot be reproduced on demand.
#
# RECORD FORMAT, one line per stage entered, append-only:
#   <stage-name> <TAB> <EPOCHREALTIME as read, or empty>
# The raw clock string is stored unparsed on purpose: parsing costs shell work on
# the measured path, and the renderer runs once, after the bound was already hit,
# where a single awk is free. A shell without EPOCHREALTIME (bash 3.2) records an
# empty stamp, which the renderer reports as unmeasured rather than as zero.
set -u

# The `uname -s` every platform arm in this file is resolved against, read ONCE
# when the file is sourced.
#
# FM_PLATFORM_UNAME_OVERRIDE still wins at CALL time in
# fm_session_start_default_budget, which is the seam every platform-arm test
# drives; caching the host's answer here only removes the `uname` that arm used
# to fork on every call. It is also what lets the nesting margin below stay a
# single variable, readable by the clamp and by the banner alike, while still
# answering per platform: that margin is bound from this string rather than from
# a fresh `uname` on every read.
#
# Assigned once per shell rather than once per source: this file is sourced by
# both the parent and the bounded child, and re-running a prologue per source is
# the exact pattern docs/verification/session-start-fork-profile.md ranks as the
# largest single source of forks on this path.
if [ -z "${FM_SESSION_START_PLATFORM:-}" ]; then
  FM_SESSION_START_PLATFORM=${FM_PLATFORM_UNAME_OVERRIDE:-$(uname -s 2>/dev/null || printf unknown)}
fi

# The default runtime bound in seconds for this platform.
#
# FM_PLATFORM_UNAME_OVERRIDE is the same test seam bin/fm-proc-lib.sh uses, for
# the same reason: it is the only way the Windows arm gets regression coverage
# from a POSIX runner, and this arm would otherwise be verified on no CI at all.
#
# WORST OBSERVED CASE: 123 s, AND IT TRUNCATED. That is the number this value has
# to clear, it is stated here at the definition rather than only in the evidence
# document, and every figure below is measured on MINGW64_NT-10.0-26200.
#
# 300 s ON MSYS/MINGW/CYGWIN IS PINNED BETWEEN TWO MEASURED BOUNDS rather than
# picked for roundness, and both bounds were measured on the target box:
#
#   BOUNDED ABOVE at 328 s by fm_session_start_hook_ceiling on that box - the
#   360 s shortest digest-tier registration minus the 32 s nesting margin the
#   contention sweep derives there. Above 328 s the clamp starts biting an
#   ordinary default run and the margin that keeps the truncation banner alive is
#   what gets spent, so this is a hard ceiling on how far the bound can go
#   without giving up the property the raise exists to protect. 300 s sits under
#   it with the clamp inert on the default path, which is checked on all twelve
#   platform arms by tests/fm-session-start-hook-nesting.test.sh.
#
#   BOUNDED BELOW at 123 s by the worst run actually observed - the empty home
#   that truncated. 300 s is 2.4x that. Because it truncated, 123 s is a lower
#   bound on what the run needed, so the true multiple is smaller than 2.4x by an
#   unmeasured amount. The untruncated empty-home floor is 72 s and 76 s, and
#   64-70 s after the subprocess reductions in this branch.
#
# So the value is derived from measurement in the only sense measurement supports
# here: it is the largest bound that leaves the banner margin intact, and it is
# well clear of every completion time and every truncation ever seen on the box.
# It is NOT derived from a contended full-startup timing, because there is not
# one - see the honest position below.
#
# WHY 120 s WAS TOO SMALL - the original observations, which stand unretracted.
# On a Windows 11 box under Git Bash, on a home with no tasks, no projects and an
# absent backlog - the floor, with nothing to reconcile and nothing to sync:
# 72 s and 76 s to complete, already 60% of the old 120 s bound before any real
# work exists in the home. One run of that same empty home with a test lane
# competing for CPU took 123 s and TRUNCATED, and because it truncated 123 s is a
# lower bound on what that run needed rather than what it would have taken.
# That is the whole case for raising the bound, and it is sound.
#
# WHAT THE RAISE IS NOT JUSTIFIED BY, stated because an earlier version of this
# comment claimed it. It used to reason that 300 s is 3.9x the worst observed
# idle floor and at least 2.4x the truncated run, "which leaves the observed load
# factor room to compound with a populated home". THAT REASONING IS WITHDRAWN.
# This branch has since measured a load factor of about 5x on the parent side
# alone - 2.06 s idle, 10.3 s mean at 8 fork-heavy competitors, 24.1 s mean at 16,
# from the 9-sample sweep in docs/verification/session-start-fork-profile.md.
# A 5x load factor does not comfortably compound inside a 3.9x headroom, so the
# sentence asserted headroom the measurements do not support.
#
# SO THE HONEST POSITION: the headroom of 300 s against a CONTENDED, POPULATED
# home is NOT established by measurement. There is no clean full-startup-to-
# completion timing under contention on the current tree; figures that once
# appeared to supply one came from the same harness whose bound-enforcement
# anomaly was retracted as an artifact, so they are withdrawn and must not be
# cited. A populated home also does strictly more work than the empty one that
# produced every number above.
#
# What protects the case where 300 s is NOT enough is not this number at all - it
# is the truncation path: the bound bites, the banner prints, and the stage that
# did not finish is named. The nesting margin below is what keeps that banner
# from being lost, and that is the property this port actually establishes.
# Raising the bound does not make the subprocess count that forced it acceptable.
fm_session_start_default_budget() {
  case "${FM_PLATFORM_UNAME_OVERRIDE:-$FM_SESSION_START_PLATFORM}" in
    MINGW*|MSYS*|CYGWIN*) printf '300\n' ;;
    *) printf '120\n' ;;
  esac
}

# The wrappers whose registration RUNS the bounded digest, and therefore whose
# hook timeout has to outlive the bound. bin/fm-sessionstart-nudge.sh is
# deliberately absent: it prints one short instruction and returns, so its 10 s
# registration is correct and must never be allowed to lower the ceiling below.
# tests/fm-session-start-hook-nesting.test.sh reads this list rather than keeping
# a second copy, because two copies drift the day a fourth transport lands.
FM_SESSION_START_DIGEST_WRAPPERS='fm-session-start.sh fm-sessionstart-run.sh fm-sessionstart-cursor.sh'

# The margin, in seconds, between the digest's own bound and the shortest harness
# hook timeout that has to outlive it. Per platform, by the same `uname -s` arms
# and the same FM_PLATFORM_UNAME_OVERRIDE seam as the default budget above,
# because what the margin has to cover is per platform too.
#
# WHAT THE MARGIN OWES, AND WHY 1 s DID NOT COVER IT. The bound governs the
# BOUNDED CHILD's runtime, but the harness kills the PARENT, and the parent
# spends time outside that child on both sides of it. Before the fork:
# bin/fm-session-start.sh's SCRIPT_DIR/FM_ROOT resolution, the
# fm-session-start-bound-lib.sh, fm-timeout-lib.sh and fm-session-lock-lib.sh
# sources - the last pulling fm-cursor-lib.sh, fm-proc-lib.sh and
# fm-session-token-lib.sh with their own prologues - and the stage-file mktemp.
# After the kill, the entire banner: fm_session_stage_last, the pending-stage
# awk/tr pipeline, fm_session_start_bound_remedy and fm_session_stage_render. So
# the hook's wall time is prologue + bound + banner, and a margin sized only for
# the equal-deadline race covers neither end. An operator doing exactly what the
# banner tells them - raise FM_SESSION_START_TIMEOUT to the printed ceiling -
# would then lose the banner outright on the platform this port exists for.
#
# 1 s OFF WINDOWS is the strict-inequality margin and is unchanged: at equal
# deadlines which process dies first is a race, and losing that race loses the
# whole banner. tests/fm-session-start-hook-nesting.test.sh asserts that same
# strictness.
#
# 32 s ON MSYS/MINGW/CYGWIN IS DERIVED FROM THE WORST DIRECTLY MEASURED
# NON-THRASHING PARENT SIDE ON THE TARGET BOX.
#
# THE CONSERVATISM IS FREE, AND THAT IS THE FIRST THING TO KNOW. The derived
# ceiling is 360 - 32 = 328 s. The Windows DEFAULT budget is 300 s, which is
# still below 328 s, so DEFAULT BEHAVIOUR IS COMPLETELY UNCHANGED by this
# margin. The clamp only ever bites an operator who has explicitly raised
# FM_SESSION_START_TIMEOUT above 328 s. A large margin therefore costs an
# ordinary session start nothing at all, which is why the conservative value is
# the right one rather than a finely tuned smaller one.
#
# THE DERIVATION.
#   Worst directly measured non-thrashing parent side = 31.20 s, at 16
#   fork-heavy competitors on a 22-core box. Rounded up = 32 s.
#
# THE DATASET, and it supersedes the model, the retracted figures and the older
# per-fork curve. Direct wall-clock timing of the REAL bin/fm-session-start.sh on
# MINGW64_NT-10.0-26200, bash 5.2.37, 22 cores. Each sample: a fresh empty
# throwaway FM_HOME; a synthetic registration declaring a 10 s SessionStart
# timeout, so the ceiling is 6 s and an explicit 9999 is genuinely CLAMPED to it;
# parent side = total elapsed minus the 6 s bound. Competitors are fork-heavy
# bash loops killed by a trap on every exit path. The truncation banner was
# VERIFIED PRESENT on all 9 samples, so a run whose bound failed to fire could
# never be silently averaged in, and the run self-reported a stale-competitor
# count of 0 afterwards.
#
#   competitors   parent side, 3 samples          mean      worst
#     0           2.10 s, 2.13 s, 1.95 s          2.06 s    2.13 s
#     8           14.89 s, 8.28 s, 7.83 s         10.3 s    14.89 s
#    16           31.20 s, 19.78 s, 21.44 s       24.1 s    31.20 s
#
# 24 COMPETITORS IS DELIBERATELY EXCLUDED from the derivation. It is past the
# 22-core count and thrashes - the earlier per-creation sweep measured 2497.5 ms
# per pure fork there, a 57.9 s modelled parent side. No fixed margin can cover a
# thrashing regime, so deriving from it would be meaningless. The exclusion is
# recorded rather than the sample deleted, because deleting an inconvenient
# sample is how a measurement becomes a story.
#
# THE MODEL IS CORROBORATION AT IDLE AND UNRELIABLE UNDER LOAD. Applying measured
# per-creation costs to the measured 20-exec/20-pure parent-side mix puts the
# idle parent side at 1.26 s against a directly measured 2.06 s, which is the
# same order and a reasonable idle proxy. Under contention it UNDERSTATES badly:
# 8.6 s modelled against a 24.1 s measured mean at 16 competitors, about 2.8x
# low. So no margin may be re-derived downward from the model, and the sweep it
# came from is kept as the cost-input record rather than as the source of this
# number.
#
# 1 s OFF WINDOWS is unchanged: creations cost about 1 ms there, and 1 s is the
# strict-inequality margin the equal-deadline race needs.
#
# THE CLAMP AND THE BANNER READ THIS ONE VARIABLE, which is a requirement and not
# a tidiness preference. fm_session_start_bind_ceiling subtracts it to derive the
# highest bound it will allow, and it is the ONLY place that arithmetic happens.
#
# The banners do NOT add it back. They used to, and that was a defect: adding the
# margin to the cap only reproduces the deadline while ceiling = deadline - margin
# holds, which the sub-margin branch cannot satisfy. fm_session_start_cap now
# carries the deadline it actually read as its third field, and
# fm_session_start_budget_advisory and fm_session_start_bound_remedy print that
# field, so the second an operator is told is the second a registration declared
# rather than a number reconstructed from two others.
#
# RESOLVED AT CALL TIME, THROUGH THE SAME SEAM AS THE BUDGET, and that symmetry
# is load-bearing rather than cosmetic. fm_session_start_default_budget consults
# FM_PLATFORM_UNAME_OVERRIDE every time it is called; when this margin was a
# source-time constant instead, an in-process
# `FM_PLATFORM_UNAME_OVERRIDE=MINGW... fm_session_start_resolve_budget ...` got
# the Windows BUDGET and the HOST's MARGIN. Cases written to exercise the Windows
# arm were then quietly checking a number that arm never uses, which is the
# vacuous-guard shape this branch has already been bitten by twice. Binding it
# rather than printing it keeps that call-time resolution free of a subshell, so
# the pre-fork window the margin itself pays for does not grow to measure it.
fm_session_start_bind_margin() {
  case "${FM_PLATFORM_UNAME_OVERRIDE:-$FM_SESSION_START_PLATFORM}" in
    MINGW*|MSYS*|CYGWIN*) FM_SESSION_START_NESTING_MARGIN=32 ;;
    *) FM_SESSION_START_NESTING_MARGIN=1 ;;
  esac
}

# Bound once here as well, so the variable is never unset for a reader that takes
# it straight off the sourced library rather than through one of the three
# functions below.
fm_session_start_bind_margin

# The highest bound the harness will actually let a session start reach: the
# SHORTEST timeout any registered digest-tier session-start hook declares, minus
# the nesting margin. Prints nothing and returns non-zero when no registration
# could be read, because refusing to guess is the only safe answer for a number
# whose job is to bound someone else's explicit request.
#
# WHY IT IS DERIVED AND NOT A CONSTANT. The harness kills the hook process, which
# takes this script's PARENT along with the bounded child, so a bound above the
# hook timeout produces no STARTUP TRUNCATED banner, no named stage and no
# reconcile list - the silent non-supervision the bound exists to prevent. A
# hardcoded ceiling would freeze that relationship: an operator who raises the
# hook timeouts must see the ceiling rise with them and get the time they asked
# for. Reading the registrations is what makes the clamp only ever refuse time
# the machine will not give.
#
# WHAT IS READ. The tracked harness registration files, DISCOVERED by glob rather
# than listed, so a fourth harness that lands its own .foo/hooks.json is honoured
# the day it appears. Harness registration directories are dot directories by
# convention - .claude, .codex, .cursor, .grok - and the glob covers one and two
# levels inside them, which is where every one of them sits.
# tests/fm-session-start-hook-nesting.test.sh discovers registrations
# independently, with git, over every tracked JSON file in the checkout, and fails
# if this glob has stopped seeing one of them.
#
# WHY awk AND NOT jq. This runs on the session-start path, where jq is not a
# dependency at all and is genuinely absent on some Git Bash installs - which is
# the platform this whole clamp protects. awk is already required by
# fm_session_stage_render below, so the scanner adds no new dependency and no
# extra process: one awk reads every registration. It is string-aware, so braces
# and escaped quotes inside a command string cannot confuse the depth count, and
# it only reads timeouts from hook objects nested under a `sessionStart` key
# (matched case-insensitively, since Claude and Codex spell it `SessionStart`).
fm_session_start_hook_deadline() {
  local root dir min f
  local -a regs=()
  if [ -n "${FM_SESSION_START_REGISTRATION_ROOT:-}" ]; then
    root=$FM_SESSION_START_REGISTRATION_ROOT
  else
    # The registrations live with the CODE, not with the home, so the root is
    # derived from this file's own path and deliberately not from FM_ROOT: a
    # session pointed at a throwaway home still runs the checkout's hooks.
    dir=${BASH_SOURCE[0]%/*}
    [ "$dir" = "${BASH_SOURCE[0]}" ] && dir=.
    case "$dir" in
      */*) root=${dir%/*}; [ -n "$root" ] || root=/ ;;
      *) root=$dir/.. ;;
    esac
  fi
  # Deliberately NOT memoised. Both callers reach this from inside a command
  # substitution or from a parent that has already forked once, so a cache would
  # be written into a subshell that exits immediately and could never be read -
  # an optimisation claimed in a comment and absent from the code. The real cost
  # is one awk per caller, on the truncation path only and only when an explicit
  # FM_SESSION_START_TIMEOUT is set, so no ordinary session start pays it.
  for f in "$root"/.[!.]*/*.json "$root"/.[!.]*/*/*.json; do
    [ -f "$f" ] && [ -r "$f" ] && regs[${#regs[@]}]=$f
  done
  [ "${#regs[@]}" -gt 0 ] || return 1
  min=$(awk -v wrappers="$FM_SESSION_START_DIGEST_WRAPPERS" '
    function is_digest(cmd,   i, n, parts) {
      n = split(wrappers, parts, " ")
      for (i = 1; i <= n; i++)
        if (parts[i] != "" && index(cmd, parts[i]) > 0) return 1
      return 0
    }
    function close_object(d,   t) {
      if (!inss || cmd[d] == "" || to[d] == "" || !is_digest(cmd[d])) return
      t = to[d] + 0
      if (t > 0 && (min == 0 || t < min)) min = t
    }
    # A JSON string never spans a line, so the scan carries its depth across
    # lines and needs no slurp.
    FNR == 1 { depth = 0; inss = 0; ssdepth = -1; key = ""; delete cmd; delete to }
    {
      line = $0
      len = length(line)
      i = 1
      while (i <= len) {
        ch = substr(line, i, 1)
        if (ch == "\"") {
          s = ""
          i++
          while (i <= len) {
            c = substr(line, i, 1)
            if (c == "\\") { s = s substr(line, i + 1, 1); i += 2; continue }
            if (c == "\"") { i++; break }
            s = s c
            i++
          }
          j = i
          while (j <= len && substr(line, j, 1) ~ /^[ \t]$/) j++
          if (j <= len && substr(line, j, 1) == ":") { key = s; i = j + 1; continue }
          if (tolower(key) == "command") cmd[depth] = s
          key = ""
          continue
        }
        if (ch == "{" || ch == "[") {
          if (!inss && tolower(key) == "sessionstart") { inss = 1; ssdepth = depth }
          key = ""
          depth++
          if (ch == "{") { cmd[depth] = ""; to[depth] = "" }
          i++
          continue
        }
        if (ch == "}" || ch == "]") {
          if (ch == "}") close_object(depth)
          depth--
          if (inss && depth <= ssdepth) { inss = 0; ssdepth = -1 }
          key = ""
          i++
          continue
        }
        if (ch ~ /^[-0-9]$/) {
          num = ""
          while (i <= len && substr(line, i, 1) ~ /^[-+.0-9eE]$/) {
            num = num substr(line, i, 1)
            i++
          }
          if (tolower(key) == "timeout") to[depth] = num
          key = ""
          continue
        }
        i++
      }
    }
    END { if (min > 0) printf "%d\n", min }
  ' "${regs[@]}" 2>/dev/null) || return 1
  case "$min" in ''|*[!0-9]*|0) return 1 ;; esac
  printf '%s\n' "$min"
}

# The highest bound allowed under <deadline>, bound as FM_SESSION_START_CEILING.
#
# BINDS RATHER THAN PRINTS so the one caller on the pre-fork path can have both
# numbers without a second subshell, and so this arithmetic has exactly one owner
# rather than being repeated wherever a ceiling is needed.
#
# A REGISTRATION SMALLER THAN THE MARGIN IS STILL A DEADLINE THAT WAS READ, and
# conflating it with "nothing could be read" fails OPEN on the one path the
# ceiling exists to close. The unreadable answer sends the caller to the platform
# default, which on MSYS is 300 s - so a registration declaring 2 s would produce
# a cap of 300 s, observed on the Windows box: two hundred and ninety-eight
# seconds above a kill this shell successfully read.
#
# SO THE DEADLINE THAT WAS READ IS A HARD UPPER BOUND, and the whole function is
# one expression: the ceiling is the deadline minus the margin, floored at 1.
# That floor is what keeps it MONOTONIC. An earlier shape returned `deadline - 1`
# in the sub-margin band, which was larger but not monotonic: with a 32 s margin a
# 32 s registration yielded 31 while a 33 s one yielded 1, so RAISING a
# registration by a second collapsed the permitted bound. The band just under the
# margin was also the least conservative part of the function, which is exactly
# backwards. Flooring instead gives 1 across that whole band, which is smaller
# but never inverts and never exceeds what was read.
#
# THE ONE INPUT WHERE THIS CANNOT HOLD, stated rather than glossed: at a deadline
# of 1 s the ceiling is also 1 s, because the only integer strictly under 1 is 0
# and a bound of 0 means NO DEADLINE AT ALL - the silent-no-deadline class this
# whole branch exists to close, and the same class the zero-padded-bound rejection
# refuses. So at 1 s the equal-deadline race is unavoidable and the banner may be
# lost. Every other deadline gets a ceiling strictly under it.
#
# What this does NOT pretend: at a registration this small the parent's own
# prologue and banner cannot fit in the gap on any platform, so the banner may
# still be lost there too. It is used anyway because it is strictly better than a
# cap above the kill, and because a registration this small is a misconfiguration
# the nesting suite's floor already refuses for every tracked harness.
fm_session_start_bind_ceiling() {  # <deadline-seconds>
  local deadline=${1:-0}
  fm_session_start_bind_margin
  FM_SESSION_START_CEILING=$((deadline - FM_SESSION_START_NESTING_MARGIN))
  [ "$FM_SESSION_START_CEILING" -ge 1 ] || FM_SESSION_START_CEILING=1
}

# The printing form, for callers that want only the ceiling.
fm_session_start_hook_ceiling() {
  local deadline
  deadline=$(fm_session_start_hook_deadline) || return 1
  fm_session_start_bind_ceiling "$deadline"
  printf '%s\n' "$FM_SESSION_START_CEILING"
}

# Does a KILL DEADLINE bind this process?
#
# Prints exactly one of:
#   binds         - POSITIVELY established: something will kill this process at a
#                   deadline the digest has to finish inside.
#   none          - POSITIVELY established: nothing will.
#   undetermined  - neither could be established.
#
# THE QUESTION IS THE DEADLINE, NOT THE HARNESS, and that distinction is a
# correctness fix rather than a rename. This predicate used to answer "is this a
# hook", and the clamp read that as "a registered hook timeout kills me". Those
# are not the same claim, and the Pi run tier is where they came apart:
# .pi/extensions/fm-primary-turnend-guard.ts spawns bin/fm-sessionstart-run.sh
# with no timeout option, no AbortSignal, no setTimeout and no child.kill - its
# only truncation is byte-based at 512 KiB and it resolves on `close`, so nothing
# kills a Pi session start on a clock. It is still unambiguously a hook. Under the
# old predicate it answered `hook`, was clamped to a ceiling derived from the
# Claude, Codex and Cursor registrations - three harnesses that are not running -
# and was told "a registered session-start hook is killed by the harness after
# 360s", which is false there, with a remedy pointing at registrations that would
# not have bought it a second.
#
# WHICH TIER DECLARES WHAT, and why the declaration lives at the spawn site. The
# file that owns the spawn is the only one that knows whether it armed a deadline,
# so each transport says so for itself through FM_SESSION_START_HOOK_DEADLINE
# rather than having this shell infer it:
#   .claude/settings.json, .codex/hooks.json  - declare "timeout": 360, so a
#                                               deadline BINDS.
#   .cursor/hooks.json                        - declares "timeout": 360, reached
#                                               through bin/fm-sessionstart-cursor.sh,
#                                               so a deadline BINDS.
#   .pi/extensions/fm-primary-turnend-guard.ts - arms no deadline of any kind, and
#                                               declares `none` at its own spawn.
# bin/fm-sessionstart-run.sh defaults the declaration to `binds` for any transport
# that does not set it, so a new harness that forgets to declare is clamped rather
# than released.
#
# WHY BOTH ANSWERS MUST STILL BE POSITIVE. The asymmetry that shaped this is
# unchanged, only its subject is corrected. A wrong `none` hands back the full
# explicit bound on a path something really does kill, which reintroduces the
# silent kill with no banner. A wrong `binds` only costs an operator some bound
# they can recover. So uncertainty is reported as uncertainty and the caller
# resolves it to the safe side, and the tempting shortcut - "no marker, therefore
# nothing kills me" - is still the one inference never made here.
#
# THE TERMINAL TEST USES FD 2, NOT FD 1, and that is load-bearing rather than
# stylistic: fm_session_start_resolve_budget is called inside a command
# substitution, where fd 1 is always a pipe, so `[ -t 1 ]` could never establish a
# terminal and the `none` branch would be dead code on the direct-run path.
# Command substitution does not touch fd 2. An operator who redirects stderr gets
# `undetermined`, which clamps - the safe side, by construction.
#
# THE BINDING FORM IS THE PRIMARY ONE, for the same reason the bound has one: a
# printing function can only be consumed through a command substitution, and a
# subshell discards what it learned. The parent probes this before forking the
# bounded child, and every extra probe there is paid inside the window the nesting
# margin covers, so the answer is bound to a variable that survives the call and
# is then threaded to the cap and to the advisory.
fm_session_start_bind_context() {
  # A transport's own positive declaration outranks every inference below it.
  if [ "${FM_SESSION_START_HOOK_DEADLINE:-}" = none ]; then
    FM_SESSION_START_CONTEXT=none
    return 0
  fi
  if [ "${FM_SESSION_START_HOOK_DEADLINE:-}" = binds ] \
    || [ "${FM_SESSION_START_UNDER_HOOK:-}" = 1 ]; then
    FM_SESSION_START_CONTEXT=binds
    return 0
  fi
  if [ -t 2 ]; then
    FM_SESSION_START_CONTEXT=none
    return 0
  fi
  FM_SESSION_START_CONTEXT=undetermined
}

# The printing form, for callers that want the answer as a value. One predicate,
# not two: it delegates rather than repeating the tests above, so the two forms
# cannot drift apart.
fm_session_start_hook_context() {
  fm_session_start_bind_context
  printf '%s\n' "$FM_SESSION_START_CONTEXT"
}

# The cap actually in force for an explicit bound on this path, and the reason it
# applies. Prints "<seconds> <source> <deadline>", where source is one of:
#   harness - the shortest registered digest-tier hook timeout, minus the nesting
#             margin. The number the machine will really give.
#   default - no registration could be read AT ALL, so this platform's default
#             stands in for the deadline this shell cannot see.
#
# THE DEADLINE IS CARRIED, NOT RECONSTRUCTED, and that is a correctness fix. The
# banners used to name the kill second by adding the margin back to the cap,
# which is only the deadline while ceiling = deadline - margin holds. It does not
# hold on the sub-margin branch, where no non-negative ceiling can satisfy it, so
# a 20 s registration on MSYS produced a ceiling of 19 and a banner announcing a
# kill at 41 s - twenty-one seconds past a deadline this shell had just read. The
# third field is the deadline that was actually read, 0 on the `default` arm
# where none was, and every operator-facing line prints that instead.
# Returns non-zero and prints nothing on a POSITIVELY established direct run,
# where nothing kills this process at a hook timeout and no cap applies.
#
# WHY AN UNREADABLE REGISTRATION SET CAPS RATHER THAN RELEASES. The ceiling used
# to be consulted with `&&`, so a registration set that could not be read - awk
# absent, or a bin-only deployment with no .claude/.codex/.cursor directories
# beside the library - short-circuited and handed back the operator's explicit
# value in full. That is the SAME outcome as a wrong "not a hook": a bound above
# a hook timeout, killed by the harness with no banner at all. The hook-context
# arm already resolves exactly that uncertainty to the safe side, and this one
# missed it. So an unreadable set falls back to the platform default, which is
# the largest bound this file can justify without reading anything, rather than
# to whatever was asked for.
#
# ONE OWNER, BECAUSE THE CLAMP AND THE BANNER MUST NOT DISAGREE.
# fm_session_start_resolve_budget clamps with this, and
# fm_session_start_budget_advisory and fm_session_start_bound_remedy describe the
# result with it. Two derivations of "what caps this" is how an operator gets
# told to raise a knob that is already pinned, or gets a harness deadline quoted
# for a cap that did not come from the harness.
fm_session_start_cap() {  # [hook-context]
  local context=${1:-} deadline
  if [ -z "$context" ]; then
    fm_session_start_bind_context
    context=$FM_SESSION_START_CONTEXT
  fi
  [ "$context" != none ] || return 1
  if deadline=$(fm_session_start_hook_deadline); then
    fm_session_start_bind_ceiling "$deadline"
    printf '%s harness %s\n' "$FM_SESSION_START_CEILING" "$deadline"
  else
    printf '%s default 0\n' "$(fm_session_start_default_budget)"
  fi
}

# The effective runtime bound, given the operator's explicit
# FM_SESSION_START_TIMEOUT (empty when unset).
#
# Precedence, and the whole reason this is one function rather than two
# expressions at the call site: an explicit value always wins, and an UNUSABLE
# explicit value falls back to this platform's default rather than to a portable
# constant. Getting that second case wrong is silent on Linux, where the two
# numbers are equal, and costs a Windows session the raised bound it needs.
# A non-positive or non-numeric bound is not a bound at all - `timeout 0` and the
# perl fallback's `alarm 0` both DISABLE the deadline - so an unusable value must
# resolve to a real default rather than removing the bound.
#
# NUMERICALLY ZERO, not the character `0`. A digits-only case cannot express that:
# `00` and `000` pass any `*[!0-9]*` test and are not the string `0`, and
# `timeout 00 sleep 2` exits 0 after the full two seconds instead of 124 - the
# deadline is entirely absent, so the digest runs UNBOUNDED and a wedged startup
# never truncates and never prints a banner. That is the same silent
# non-supervision an unusable value is supposed to be protected against, so the
# value is normalised through base-10 arithmetic and every spelling of zero lands
# on the platform default. Normalising also canonicalises `07` to `7`, so the
# banner reports the bound the way `timeout` read it.
#
# The one thing an explicit value does NOT win against is the harness. A usable
# value above fm_session_start_cap is CLAMPED to that cap, because above it the
# harness kills the hook first and the operator gets nothing printed at all -
# strictly less than the truncation banner they were trying to avoid. It is
# clamped rather than rejected: someone who asked for MORE time must not be
# handed LESS than the machine can safely give, so an over-cap request lands on
# the cap and never below it.
# fm_session_start_budget_advisory below is what says so on the digest.
#
# THE CLAMP IS SCOPED TO THE PATHS THE CEILING GOVERNS. It applies when
# fm_session_start_hook_context reports `hook` OR `undetermined`, and is skipped
# only on a positively established `direct` run, where nothing kills this process
# at the hook timeout and the operator's own rerun - the remedy this script's own
# truncation banner prescribes - must be allowed the time they asked for. So the
# clamp refuses time the machine will not give, or time this process cannot
# establish that the machine will give; it is not a global cap.
#
# The cap is only derived when there IS an explicit value that could be clamped,
# which keeps the default path - every ordinary session start - at exactly the
# subprocess count it had before. The defaults are guarded instead by
# tests/fm-session-start-hook-nesting.test.sh, which asserts every platform arm
# nests under every registration.
#
# THE CAP MAY BE HANDED IN, and on the path bin/fm-session-start.sh actually
# takes it always is. A caller that has already derived the cap passes it as
# `<seconds> <source> <deadline>`, or the literal `none` for a positively established
# direct run where no cap applies; an empty second argument means "derive it
# here". Deriving it twice is not merely wasteful, it is wasteful in the one
# place that cannot afford it: the derivation costs a hook-context probe, a glob
# and an awk over every registration JSON, and all of it runs in the parent
# BEFORE the bounded child is forked, inside the very window the nesting margin
# has to cover.
fm_session_start_resolve_budget() {  # [explicit-seconds] [cap-spec]
  local explicit=${1:-} cap=${2:-} fallback
  case "$explicit" in
    ''|*[!0-9]*)
      fallback=$(fm_session_start_default_budget)
      printf '%s\n' "$fallback"
      return 0
      ;;
  esac
  explicit=$((10#$explicit))
  if [ "$explicit" -le 0 ]; then
    fallback=$(fm_session_start_default_budget)
    printf '%s\n' "$fallback"
    return 0
  fi
  [ -n "$cap" ] || cap=$(fm_session_start_cap) || cap=none
  if [ "$cap" != none ]; then
    cap=${cap%% *}
    if [ "$explicit" -gt "$cap" ]; then
      printf '%s\n' "$cap"
      return 0
    fi
  fi
  printf '%s\n' "$explicit"
}

# The one entry point bin/fm-session-start.sh uses, and the reason the cap is
# derived exactly once on the path where that matters.
#
# It ASSIGNS rather than prints, which is the whole point. The resolver above is
# a printing function, so its caller reaches it through a command substitution -
# and a subshell discards everything it learned, including the cap it just paid
# four process creations to derive. The advisory then derived the same cap again
# in the parent. Binding the result to variables instead means the derivation
# survives its own call, so the clamp and the advisory read one cap, resolved
# once, and cannot disagree about it.
#
# Sets FM_SESSION_START_BOUND to the bound in force, FM_SESSION_START_CAP to the
# cap spec that produced it - `none` when no cap applies - and
# FM_SESSION_START_CONTEXT to the hook context both were resolved against.
#
# All three are ALWAYS assigned, including on the default path where the last two
# are left empty. The caller runs under `set -u`, so a variable this function can
# return without defining is an unbound-variable abort on every ordinary session
# start, not a missing optimisation. Empty is the "nothing to clamp, so nothing
# was derived" value, and every consumer treats it as "derive it yourself if you
# get that far" - which on the default path none of them do, because the advisory
# returns before it needs either.
# shellcheck disable=SC2034  # Both variables are the return values of this
# function; bin/fm-session-start.sh reads them in the shell that calls it, which
# is the whole reason this assigns rather than prints.
fm_session_start_bind_budget() {  # [explicit-seconds]
  local explicit=${1:-}
  FM_SESSION_START_CAP=
  FM_SESSION_START_CONTEXT=
  case "$explicit" in
    ''|*[!0-9]*)
      FM_SESSION_START_BOUND=$(fm_session_start_default_budget)
      return 0
      ;;
  esac
  if [ "$((10#$explicit))" -le 0 ]; then
    FM_SESSION_START_BOUND=$(fm_session_start_default_budget)
    return 0
  fi
  fm_session_start_bind_context
  FM_SESSION_START_CAP=$(fm_session_start_cap "$FM_SESSION_START_CONTEXT") || FM_SESSION_START_CAP=none
  FM_SESSION_START_BOUND=$(fm_session_start_resolve_budget "$explicit" "$FM_SESSION_START_CAP")
}

# The bound a DETACHED worker must use when its window has to match the digest's.
# bin/fm-startup-network.sh keeps offering its result for inline delivery for
# exactly as long as the digest could still be running, so the two are one bound
# and must now also be one RESOLUTION.
#
# WHY THE WORKER CANNOT RESOLVE IT ITSELF, which is the defect this closes. The
# digest's bound is the operator's FM_SESSION_START_TIMEOUT after a clamp SCOPED
# TO HOOK CONTEXT, and a detached worker cannot observe the context its digest ran
# in: it is launched with stdio on /dev/null, so `[ -t 2 ]` is false there no
# matter what, and fm_session_start_hook_context can never answer `direct` inside
# it. Re-resolving the same variable there does not reproduce the digest's bound,
# it reproduces the clamp. So an operator who does what the truncation banner
# tells them - rerun from a terminal, with FM_SESSION_START_TIMEOUT raised - gets
# a digest bounded at the value they asked for and a worker that stops offering
# inline delivery at the ceiling, for the rest of the run, silently. The result is
# not lost, it still surfaces as a durable wake, but it stops arriving in the
# digest the operator is sitting in front of.
#
# So the digest resolves once and EXPORTS the answer as
# FM_SESSION_START_RESOLVED_BOUND, and this reads it. One resolution, one bound,
# equal by construction rather than by two derivations happening to agree.
#
# The local resolution remains as the fallback, because bin/fm-startup-network.sh
# also runs standalone, where there is no digest to inherit from. An inherited
# value that is not a positive integer takes that same path: a bound that cannot
# be trusted is not a bound to prefer over one this shell can derive.
fm_session_start_delivery_bound() {  # [explicit-seconds]
  local inherited=${FM_SESSION_START_RESOLVED_BOUND:-}
  case "$inherited" in
    ''|*[!0-9]*) : ;;
    *)
      if [ "$((10#$inherited))" -gt 0 ]; then
        printf '%s\n' "$((10#$inherited))"
        return 0
      fi
      ;;
  esac
  fm_session_start_resolve_budget "${1:-}"
}

# The digest lines a clamp owes the operator. Never clamps silently: it names what
# was asked for, what was applied, and what would have happened otherwise, so the
# operator is not left believing a bound that is not in force.
#
# Takes both numbers rather than re-deriving the bound, so it can never disagree
# with the bound that is actually running, and it returns before touching
# anything else when nothing was clamped - which is every ordinary session start,
# and why this costs the default path no subprocess at all. The context is named
# too, because "we know this is a hook" and "we could not establish that this is
# not a hook" are different claims and the operator's next move differs between
# them.
#
# AND THE KILL SECOND IS ONLY STATED AS FACT WHEN A DEADLINE WAS ESTABLISHED,
# for the same reason fm_session_start_bound_remedy does it. This surface is
# printed on EVERY clamped run rather than only after a truncation, so it matters
# more, not less. Under `undetermined` the clamp still applies - that is the
# accepted safe side and does not change - but the library has not established
# that anything kills this run, so it must not name a second the harness "will"
# kill at, and it must not send the operator to raise registrations that may not
# be the ones running. The nudge-tier transports reach exactly this: the agent
# runs bin/fm-session-start.sh through its own tool, with no marker and no
# terminal on fd 2.
#
# WHERE THE CAP CAME FROM IS PART OF THE ADVICE. A cap read from the
# registrations lets this name the exact second the harness kills at; a cap that
# stood in for registrations this shell could not read does not, and quoting one
# anyway would invent a deadline. So the cap is taken from the caller when the
# caller already has it - fm_session_start_bind_budget always does - and asked of
# fm_session_start_cap, the same owner the clamp used, only when it does not.
# Re-deriving it here would run a second hook-context probe, a second glob and a
# second awk over every registration JSON, in the parent, before the bounded
# child is forked; the previous version of this comment claimed the no-re-derive
# property while it was true of the bound and false of the cap beside it.
#
# A DISCARD IS AS LOUD AS A CLAMP, and for the same reason. An UNUSABLE explicit
# value - non-numeric, or any spelling of zero including the zero-padded ones -
# is replaced by the platform default by fm_session_start_resolve_budget, and it
# has to be, because `timeout 0` and `alarm 0` disable the deadline outright and
# a session start with no deadline is the silent non-supervision this whole file
# exists to prevent. But it used to be replaced with nothing said. An operator
# who set FM_SESSION_START_TIMEOUT=0 or =abc believing they had changed the bound
# then read a later truncation as "the bound I set was too small" rather than as
# "the bound I set never applied", and their next move was to raise a value that
# was never in force. So the discard is named, on exactly the same principle as
# the clamp above: what was asked for, what is actually running, and why.
#
# AN EMPTY VALUE IS NOT A DISCARD and stays silent. `${FM_SESSION_START_TIMEOUT:-}`
# reads the same empty string for "unset" as for "set to nothing", so this cannot
# tell the two apart, and warning about the first would put a notice on every
# ordinary session start - which is the surface this file keeps quiet by default.
#
# The default is NAMED FROM `effective` rather than re-derived, for the reason the
# rest of this function takes both numbers: a second derivation can disagree with
# the bound that is actually running, and on this path effective IS the platform
# default fm_session_start_resolve_budget fell back to. It also keeps the discard
# notice free of the subprocess a re-derivation would cost.
fm_session_start_budget_advisory() {  # <requested> <effective> [context] [cap-spec]
  local requested=${1:-} effective=${2:-} context=${3:-} cap=${4:-} capsource=none capdeadline=0 caprest
  local unusable= shown
  case "$effective" in ''|*[!0-9]*|0) return 0 ;; esac
  case "$requested" in
    '') return 0 ;;
    *[!0-9]*) unusable=1 ;;
    *) [ "$((10#$requested))" -gt 0 ] || unusable=1 ;;
  esac
  if [ -n "$unusable" ]; then
    # Echoed back through parameter expansion only - no fork - and flattened so a
    # value carrying newlines or tabs cannot forge extra digest lines around the
    # notice that is reporting it.
    shown=${requested//[[:space:]]/ }
    [ "${#shown}" -le 48 ] || shown="${shown:0:48}..."
    printf '●  FM_SESSION_START_TIMEOUT='"'"'%s'"'"' is not a usable bound and was IGNORED: the\n' "$shown"
    printf '●  session-start bound in force is this platform'"'"'s default of %ss.\n' "$effective"
    printf '●  Set a positive whole number of seconds; zero and non-numeric values would\n'
    printf '●  disable the deadline outright, which loses the truncation banner entirely.\n'
    return 0
  fi
  requested=$((10#$requested))
  [ "$requested" -gt "$effective" ] || return 0
  [ -n "$context" ] || context=$(fm_session_start_hook_context)
  [ -n "$cap" ] || cap=$(fm_session_start_cap "$context") || cap=none
  if [ "$cap" != none ]; then
    caprest=${cap#* }
    capsource=${caprest%% *}
    capdeadline=${caprest#* }
    # A spec without a usable deadline field can only come from a caller that
    # built one by hand, so re-deriving beats printing a fabricated second. 0 is
    # NOT that case: it is the sentinel the `default` arm emits for "no deadline
    # was read", and matching it here re-ran a derivation that had just failed,
    # in the pre-fork window the margin pays for, to produce a number no branch
    # then prints.
    case "$capdeadline" in
      ''|*[!0-9]*) capdeadline=$(fm_session_start_hook_deadline) || capdeadline=0 ;;
    esac
  fi
  printf '●  FM_SESSION_START_TIMEOUT=%ss was CLAMPED to %ss.\n' "$requested" "$effective"
  if [ "$capsource" = harness ] && [ "$context" = binds ]; then
    printf '●  A registered session-start hook is killed by the harness after %ss, and that\n' \
      "$capdeadline"
    printf '●  kill takes this script with the digest, printing no truncation banner at all.\n'
  elif [ "$capsource" = harness ]; then
    printf '●  Nothing here proved a kill deadline binds this run, so %ss is the largest bound\n' "$effective"
    printf '●  it can establish is safe: the shortest registered session-start timeout in this\n'
    printf '●  checkout is %ss, and a bound above it would be killed with no banner at all if\n' \
      "$capdeadline"
    printf '●  one of those registrations is what launched this.\n'
  elif [ "$capsource" = default ]; then
    printf '●  No harness session-start registration could be read from this deployment, so\n'
    printf '●  the hook timeout that would kill this script is unknown here and the bound\n'
    printf '●  falls back to this platform default rather than to the value asked for.\n'
  fi
  case "$context" in
    binds) printf '●  A kill deadline is established for this run.\n' ;;
    none) : ;;
    *) printf '●  It could not be established that nothing kills this run on a clock, so it is\n'
       printf '●  treated as bounded: an unprovable "nothing kills me" is what loses the banner.\n' ;;
  esac
  if [ "$capsource" = harness ] && [ "$context" = binds ]; then
    printf '●  Raise the SessionStart timeouts in the harness registrations to go higher.\n'
  elif [ "$capsource" = harness ]; then
    printf '●  If this run really is under a harness that kills it, raise that harness'"'"'s\n'
    printf '●  SessionStart timeout to go higher.\n'
  elif [ "$capsource" = default ]; then
    printf '●  Restore the harness registrations beside bin/ to go higher.\n'
  fi
}

# The truncation banner's remedy, which has to stay ACTIONABLE. Owned here rather
# than spelled at the call site because it depends on the derived ceiling, and
# because the wrong branch of it is worse than silence: telling an operator to
# raise a knob already pinned at its maximum spends their next move on a no-op
# and reads as though nothing was checked.
#
# Four cases, and the middle two are the reason this exists:
#   no cap applies    - a positively established direct run, where nothing kills
#                       this process at a hook timeout: the original uncapped
#                       advice, and the only case where it is still true.
#   below the cap     - raise it, and here is how far it can actually go.
#   at or above it    - raising it cannot help; say which knob still moves.
#   cap without a read - the registrations could not be read, so the pinned
#                       advice points at restoring them rather than quoting a
#                       harness deadline this shell never saw.
#
# AND THE KILL SECOND IS ONLY STATED AS FACT WHEN A DEADLINE WAS ESTABLISHED.
# Under `undetermined` the clamp still applies - that is the accepted safe side
# and does not change - but the library has NOT established that anything kills
# this run, so the wording must not say the harness "kills this hook after Ns".
# That path is reachable on shipped tiers: the nudge-tier transports ask the
# agent to run bin/fm-session-start.sh through its own tool, which has no hook
# marker and no terminal on fd 2, so it answers `undetermined` - and telling that
# operator to go raise a Claude, Codex or Cursor registration that is not running
# is the same misdirection the Pi transport was fixed for. So the context is
# threaded in the way the advisory already threads it, and on `undetermined` the
# ceiling is described as the largest bound this run can establish is safe.
#
# The cap and the reason both come from fm_session_start_cap, the same owner
# fm_session_start_resolve_budget clamped with, so the number named here is by
# construction the number in force.
#
# THE CAP MAY BE HANDED IN, exactly as the advisory takes it, and on the
# truncation path it always is. Deriving it again here would cost a command
# substitution, the registration glob and an awk over every registration JSON -
# inside the POST-KILL BANNER, which is half of what the nesting margin is
# derived to cover. bin/fm-session-start.sh already holds the spec in
# FM_SESSION_START_CAP, assigned unconditionally by fm_session_start_bind_budget,
# so it passes that rather than paying for it twice. An empty third argument
# still means "derive it here", which is what the default path leaves behind.
fm_session_start_bound_remedy() {  # <effective-budget> [context] [cap-spec]
  local effective=${1:-} context=${2:-} cap=${3:-} capvalue capsource capdeadline caprest
  case "$effective" in ''|*[!0-9]*) effective=0 ;; esac
  if [ -z "$context" ]; then
    fm_session_start_bind_context
    context=$FM_SESSION_START_CONTEXT
  fi
  if [ "$cap" = none ]; then
    cap=""
  elif [ -n "$cap" ]; then
    :
  elif ! cap=$(fm_session_start_cap "$context"); then
    cap=""
  fi
  if [ -z "$cap" ]; then
    printf '●  If it truncates again, raise FM_SESSION_START_TIMEOUT and report the slow\n'
    printf '●  stage - a stage that cannot finish inside the bound is a fleet problem, not a\n'
    printf '●  reporting detail.\n'
    return 0
  fi
  capvalue=${cap%% *}
  caprest=${cap#* }
  capsource=${caprest%% *}
  capdeadline=${caprest#* }
  case "$capdeadline" in
    ''|*[!0-9]*) capdeadline=$(fm_session_start_hook_deadline) || capdeadline=0 ;;
  esac
  if [ "$effective" -lt "$capvalue" ]; then
    printf '●  If it truncates again, raise FM_SESSION_START_TIMEOUT - to at most %ss, above\n' "$capvalue"
    if [ "$capsource" = harness ] && [ "$context" = binds ]; then
      printf '●  which the harness kills this hook after %ss and prints no banner at all - and\n' \
        "$capdeadline"
    elif [ "$capsource" = harness ]; then
      printf '●  which this run cannot establish it will survive: nothing here proved a kill\n'
      printf '●  deadline binds, and the shortest registered session-start timeout in this\n'
      printf '●  checkout is %ss, so that is the largest bound it is safe to assume - and\n' \
        "$capdeadline"
    else
      printf '●  which nothing here can bound it, since no harness registration could be read\n'
      printf '●  from this deployment to say when the hook is killed - and\n'
    fi
    printf '●  report the slow stage: a stage that cannot finish inside the bound is a fleet\n'
    printf '●  problem, not a reporting detail.\n'
    return 0
  fi
  if [ "$capsource" = harness ] && [ "$context" = binds ]; then
    printf '●  FM_SESSION_START_TIMEOUT is ALREADY at the %ss harness ceiling, so raising it\n' "$capvalue"
    printf '●  cannot help: the harness kills this hook after %ss and prints no banner at all.\n' \
      "$capdeadline"
    printf '●  Raise the SessionStart timeouts in the harness registrations, or fix the stage\n'
    printf '●  named above - a stage that cannot finish inside the bound is a fleet problem,\n'
    printf '●  not a reporting detail.\n'
    return 0
  fi
  if [ "$capsource" = harness ]; then
    printf '●  FM_SESSION_START_TIMEOUT is ALREADY at the %ss largest bound this run can\n' "$capvalue"
    printf '●  establish is safe, so raising it cannot help. Nothing here proved a kill\n'
    printf '●  deadline binds this run, so the shortest registered session-start timeout in\n'
    printf '●  this checkout, %ss, is what it is held under.\n' \
      "$capdeadline"
    printf '●  If this run really is under a harness that kills it, raise that harness'"'"'s\n'
    printf '●  SessionStart timeout; otherwise fix the stage named above - a stage that\n'
    printf '●  cannot finish inside the bound is a fleet problem, not a reporting detail.\n'
    return 0
  fi
  printf '●  FM_SESSION_START_TIMEOUT is ALREADY at the %ss cap this deployment can justify,\n' "$capvalue"
  printf '●  so raising it cannot help: no harness registration could be read here, so the\n'
  printf '●  hook timeout that kills this script is unknown and the platform default stands\n'
  printf '●  in for it.\n'
  printf '●  Restore the harness registrations beside bin/, or fix the stage named above - a\n'
  printf '●  stage that cannot finish inside the bound is a fleet problem, not a reporting\n'
  printf '●  detail.\n'
}

# Append the entry instant of <stage> to <file>. Never fails the caller: a
# missing, unset or unwritable breadcrumb file costs the digest nothing, because
# losing an attribution line must not change what a startup prints.
fm_session_stage_mark() {  # <file> <stage>
  local file=${1:-} stage=${2:-} dir
  [ -n "$file" ] && [ -n "$stage" ] || return 0
  # Writability is tested BEFORE the append, with builtins only, because a
  # failed `>>` redirection is reported by the shell itself and a `2>/dev/null`
  # on the printf does not suppress it - the digest would print a raw shell error
  # mid-stage. Suppressing it in a subshell would cost a fork per stage on the
  # one path whose cost is its fork count, so the check is the cheap way to keep
  # a lost attribution line silent.
  if [ -e "$file" ]; then
    [ -w "$file" ] || return 0
  else
    dir=${file%/*}
    [ "$dir" = "$file" ] && dir=.
    [ -n "$dir" ] || dir=/
    [ -d "$dir" ] && [ -w "$dir" ] || return 0
  fi
  printf '%s\t%s\n' "$stage" "${EPOCHREALTIME:-}" >> "$file" 2>/dev/null || true
  return 0
}

# The most recent stage recorded in <file>, or nothing when there is none. This
# is what the truncation banner names as the stage the digest died in.
fm_session_stage_last() {  # <file>
  local file=${1:-} last=
  [ -n "$file" ] && [ -r "$file" ] || return 0
  # `tail` answers this directly, and a command substitution around it handles a
  # final line with no trailing newline. Reading the file in a shell loop and
  # piping it to `tail` would fork a subshell on top of the same `tail` exec, on
  # the one path whose cost is its subprocess count.
  last=$(tail -n 1 "$file" 2>/dev/null) || return 0
  [ -n "$last" ] || return 0
  printf '%s\n' "${last%%	*}"
}

# Per-stage elapsed times for a truncated run. <budget> bounds the final stage,
# which has no successor mark because the child was killed inside it. Prints
# nothing when no stage carries a usable stamp, so an unmeasured run stays quiet
# rather than printing a table of zeros.
fm_session_stage_render() {  # <file> <budget-seconds>
  local file=${1:-} budget=${2:-0}
  [ -n "$file" ] && [ -s "$file" ] || return 0
  case "$budget" in ''|*[!0-9]*) budget=0 ;; esac
  awk -F'\t' -v budget="$budget" '
    {
      raw = $2
      gsub(/,/, ".", raw)
      if (raw !~ /^[0-9]+(\.[0-9]+)?$/) raw = ""
      n++
      name[n] = $1
      ms[n] = (raw == "") ? -1 : int(raw * 1000)
    }
    END {
      if (n == 0) exit 0
      origin = -1
      for (i = 1; i <= n; i++) if (ms[i] >= 0) { origin = ms[i]; break }
      if (origin < 0) exit 0
      printf "●  Where the time went, per stage (ms), so the slow stage is named:\n"
      for (i = 1; i <= n; i++) {
        if (ms[i] < 0) { printf "●    %-24s unmeasured\n", name[i]; continue }
        if (i < n && ms[i + 1] >= 0) elapsed = ms[i + 1] - ms[i]
        else elapsed = (budget * 1000) - (ms[i] - origin)
        if (elapsed < 0) elapsed = 0
        printf "●    %-24s start=+%-7d elapsed=%d%s\n", \
          name[i], ms[i] - origin, elapsed, (i == n ? "  <- did not finish" : "")
      }
    }
  ' "$file" 2>/dev/null || true
  return 0
}
