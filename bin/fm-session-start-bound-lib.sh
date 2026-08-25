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
# 300 s on MSYS/MINGW/Cygwin is a margin over measurement, and the measurement is
# censored, so the reasoning is recorded here rather than left as a round number.
# Observed on a Windows 11 box under Git Bash, on a home with no tasks, no
# projects and an absent backlog - the floor, with nothing to reconcile and
# nothing to sync: 72 s and 76 s to complete, already 60% of the old 120 s bound
# before any real work exists in the home. One run of that same empty home with a
# test lane competing for CPU took 123 s and TRUNCATED - and because it truncated,
# 123 s is a lower bound on what that run needed, not what it would have taken.
# So the load factor is at least 1.7x, its true value is unknown, and a populated
# home does strictly more work than the empty one that produced every number
# above. 300 s is 3.9x the worst observed idle floor and at least 2.4x the one
# observed over-budget run, which leaves the observed load factor room to compound
# with a populated home while still bounding a genuinely wedged startup to five
# minutes rather than forever. It is a margin over a censored observation, not a
# measured maximum, and raising the bound does not make the subprocess count that
# forced it acceptable.
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
# 4 s ON MSYS/MINGW/CYGWIN IS NOT ESTABLISHED AS SUFFICIENT, AND ITS COST INPUT
# IS NOT ESTABLISHED EITHER. Read that before treating it as a headroom figure.
#
# It was derived as 26 measured subprocesses x 124.0 ms per creation = 3224 ms,
# ceiling to whole seconds. Both halves of that product have since moved:
#
#   - The parent-side count is no longer 26 and is no longer written down. It is
#     derived at test time by tests/fm-session-start-hook-nesting.test.sh, which
#     builds tests/fixtures/forkcount.c, validates it against a known-count
#     program, and counts a real clamped-and-truncated run - so the live number is
#     whatever that guard reports. It measures 39 on the box that runs this suite
#     and was measured at 40 by a second reviewer, split about evenly between
#     exec-backed creations and pure subshell forks. That count is Linux, from a
#     validated instrument, and stands.
#   - The PER-CREATION COST ON MSYS IS RETRACTED. Figures of 46.5 ms per pure
#     subshell fork and 80.8 ms per fork+exec were recorded here as an IDLE floor,
#     and the ~2546 ms and ~10.3 s conclusions were drawn from them. They were not
#     taken at idle: 21 orphaned competitor processes from two earlier timed-out
#     measurement runs were still on the box, reparented to PID 1, and were not
#     noticed until afterwards. Those numbers therefore have NO KNOWN CONTENTION
#     LEVEL and are not a floor, an upper bound, or a curve point. They are kept
#     named rather than deleted, the way the retracted 22 and 26 counts are, so
#     nobody re-derives from them.
#   - What that leaves: the per-creation cost of this path on MSYS is currently
#     UNMEASURED, so 4 s is neither shown to be sufficient nor shown to be
#     insufficient. It is the last derived value and nothing more.
#   - Pure CPU load was the WRONG model and was discarded: 4 busy-loop burners
#     made creations FASTER, 25 ms against 30 ms idle, through frequency boost.
#     The real competitor is a test lane, which contends for PROCESS CREATION,
#     and MSYS serialises that. That methodological finding survives the
#     retraction because it is about which competitor to use, not about a value.
#
# WHERE THAT LEAVES THIS NUMBER. A clean contention curve is being re-measured on
# a quiesced box, and the margin is to be set from its worst measured point with
# the contention level recorded beside it. Until it lands, nothing in this tree
# asserts that 4 s covers the parent side, and
# docs/verification/session-start-fork-profile.md records both the retraction and
# the open question. What the suite does guard is the count not RISING while that
# is unresolved, because every creation added to the parent side is time this
# margin may well not have.
#
# WHICH PATH THE COUNT IS TAKEN ON, because a first attempt got exactly that
# wrong. It counted the DEFAULT path, 22 subprocesses, and landed on 3 s. The
# default path can never reach the ceiling: the Windows default bound is 300 s and
# the ceiling is in the 350s, so the only bound that ever EQUALS the ceiling is a
# CLAMPED one. That earlier 22 is wrong and must not be cited.
#
# THE DEDUPS ARE CORRECTNESS DEPENDENCIES OF THIS NUMBER, not tidy-ups. The cap
# and the hook-context probe were each derived twice in the parent before the
# bounded child was forked; fm_session_start_bind_budget and
# fm_session_start_bind_context are what hold each to one derivation. Undo either
# and the count rises into a margin that has no room for it.
#
# THE CLAMP AND THE BANNER READ THIS ONE VARIABLE, which is a requirement and not
# a tidiness preference. fm_session_start_hook_ceiling subtracts it to derive the
# highest bound it will allow; fm_session_start_budget_advisory and
# fm_session_start_bound_remedy add it back to name the deadline the harness will
# actually kill at. Each of the three binds it first, so all three read the same
# variable resolved against the same platform within the same call. A second
# literal or a second derivation anywhere would let the number the operator is
# told diverge from the number in force, which is the failure this margin exists
# to prevent.
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
    MINGW*|MSYS*|CYGWIN*) FM_SESSION_START_NESTING_MARGIN=4 ;;
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
fm_session_start_hook_ceiling() {
  local root dir min f
  fm_session_start_bind_margin
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
  if [ "$min" -gt "$FM_SESSION_START_NESTING_MARGIN" ]; then
    printf '%s\n' "$((min - FM_SESSION_START_NESTING_MARGIN))"
    return 0
  fi
  # A REGISTRATION SMALLER THAN THE MARGIN IS STILL A DEADLINE THAT WAS READ, and
  # conflating it with "nothing could be read" fails OPEN on the one path this
  # function exists to close. The unreadable answer sends the caller to the
  # platform default, which on MSYS is 300 s - so a registration declaring 3 s
  # would produce a cap of 300 s, three hundred seconds above a kill this shell
  # successfully read, and both operator messages would say no registration could
  # be read when one was. So the smallest thing genuinely known is returned
  # instead: one second under the deadline that was read, which keeps the strict
  # inequality the margin's portable arm is built on, or 1 s when even that is not
  # available.
  #
  # What this does NOT pretend: at a registration this small the parent's own
  # prologue and banner cannot fit in the gap on any platform, so the banner may
  # still be lost. It is returned anyway because it is strictly better than a cap
  # above the kill, and because a registration this small is a misconfiguration
  # the nesting suite's floor already refuses for every tracked harness.
  [ "$min" -gt 1 ] && { printf '%s\n' "$((min - 1))"; return 0; }
  printf '1\n'
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
# applies. Prints "<seconds> <source>", where source is one of:
#   harness - the shortest registered digest-tier hook timeout, minus the nesting
#             margin. The number the machine will really give.
#   default - no registration could be read AT ALL, so this platform's default
#             stands in for the deadline this shell cannot see.
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
  local context=${1:-} ceiling
  if [ -z "$context" ]; then
    fm_session_start_bind_context
    context=$FM_SESSION_START_CONTEXT
  fi
  [ "$context" != none ] || return 1
  if ceiling=$(fm_session_start_hook_ceiling); then
    printf '%s harness\n' "$ceiling"
  else
    printf '%s default\n' "$(fm_session_start_default_budget)"
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
# `<seconds> <source>`, or the literal `none` for a positively established
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
fm_session_start_budget_advisory() {  # <requested> <effective> [context] [cap-spec]
  local requested=${1:-} effective=${2:-} context=${3:-} cap=${4:-} capsource=none
  fm_session_start_bind_margin
  case "$requested" in ''|*[!0-9]*) return 0 ;; esac
  case "$effective" in ''|*[!0-9]*|0) return 0 ;; esac
  requested=$((10#$requested))
  [ "$requested" -gt "$effective" ] || return 0
  [ -n "$context" ] || context=$(fm_session_start_hook_context)
  [ -n "$cap" ] || cap=$(fm_session_start_cap "$context") || cap=none
  [ "$cap" = none ] || capsource=${cap##* }
  printf '●  FM_SESSION_START_TIMEOUT=%ss was CLAMPED to %ss.\n' "$requested" "$effective"
  case "$capsource" in
    harness)
      printf '●  A registered session-start hook is killed by the harness after %ss, and that\n' \
        "$((effective + FM_SESSION_START_NESTING_MARGIN))"
      printf '●  kill takes this script with the digest, printing no truncation banner at all.\n'
      ;;
    default)
      printf '●  No harness session-start registration could be read from this deployment, so\n'
      printf '●  the hook timeout that would kill this script is unknown here and the bound\n'
      printf '●  falls back to this platform default rather than to the value asked for.\n'
      ;;
  esac
  case "$context" in
    binds) printf '●  A kill deadline is established for this run.\n' ;;
    none) : ;;
    *) printf '●  It could not be established that nothing kills this run on a clock, so it is\n'
       printf '●  treated as bounded: an unprovable "nothing kills me" is what loses the banner.\n' ;;
  esac
  case "$capsource" in
    harness) printf '●  Raise the SessionStart timeouts in the harness registrations to go higher.\n' ;;
    default) printf '●  Restore the harness registrations beside bin/ to go higher.\n' ;;
  esac
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
fm_session_start_bound_remedy() {  # <effective-budget> [context]
  local effective=${1:-} context=${2:-} cap capvalue capsource
  fm_session_start_bind_margin
  case "$effective" in ''|*[!0-9]*) effective=0 ;; esac
  if [ -z "$context" ]; then
    fm_session_start_bind_context
    context=$FM_SESSION_START_CONTEXT
  fi
  if ! cap=$(fm_session_start_cap "$context"); then
    printf '●  If it truncates again, raise FM_SESSION_START_TIMEOUT and report the slow\n'
    printf '●  stage - a stage that cannot finish inside the bound is a fleet problem, not a\n'
    printf '●  reporting detail.\n'
    return 0
  fi
  capvalue=${cap%% *}
  capsource=${cap##* }
  if [ "$effective" -lt "$capvalue" ]; then
    printf '●  If it truncates again, raise FM_SESSION_START_TIMEOUT - to at most %ss, above\n' "$capvalue"
    if [ "$capsource" = harness ] && [ "$context" = binds ]; then
      printf '●  which the harness kills this hook after %ss and prints no banner at all - and\n' \
        "$((capvalue + FM_SESSION_START_NESTING_MARGIN))"
    elif [ "$capsource" = harness ]; then
      printf '●  which this run cannot establish it will survive: nothing here proved a kill\n'
      printf '●  deadline binds, and the shortest registered session-start timeout in this\n'
      printf '●  checkout is %ss, so that is the largest bound it is safe to assume - and\n' \
        "$((capvalue + FM_SESSION_START_NESTING_MARGIN))"
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
      "$((capvalue + FM_SESSION_START_NESTING_MARGIN))"
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
      "$((capvalue + FM_SESSION_START_NESTING_MARGIN))"
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
