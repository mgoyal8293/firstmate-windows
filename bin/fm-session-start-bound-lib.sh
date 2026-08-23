#!/usr/bin/env bash
# fm-session-start-bound-lib.sh - the single owner of the session-start runtime
# bound: its per-platform default, its stage breadcrumbs, and how a truncated
# startup attributes the time it spent.
#
# Sourced, never executed. bin/fm-session-start.sh owns the digest and the nine
# stage names; this file owns only the bound around them.
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
  case "${FM_PLATFORM_UNAME_OVERRIDE:-$(uname -s 2>/dev/null || printf unknown)}" in
    MINGW*|MSYS*|CYGWIN*) printf '300\n' ;;
    *) printf '120\n' ;;
  esac
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
fm_session_start_resolve_budget() {  # [explicit-seconds]
  local explicit=${1:-} fallback
  fallback=$(fm_session_start_default_budget)
  case "$explicit" in
    ''|*[!0-9]*|0) printf '%s\n' "$fallback" ;;
    *) printf '%s\n' "$explicit" ;;
  esac
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
  local file=${1:-} line=
  [ -n "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '') continue ;; esac
    printf '%s\n' "${line%%	*}"
  done < "$file" | tail -n 1
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
