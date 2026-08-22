# shellcheck shell=bash
# Resolve a Python 3 that ACTUALLY RUNS, once per process, for every firstmate
# script that needs one.
#
# `command -v python3` is a presence check, not a capability check, and on
# Windows the difference is the whole bug. Windows 10 and 11 ship Microsoft
# Store "app execution aliases" for `python` and `python3`: 121-byte
# redirectors under %LOCALAPPDATA%\Microsoft\WindowsApps that RESOLVE on PATH,
# so `command -v python3` succeeds, but every invocation prints "Python was not
# found; run without arguments to install from the Microsoft Store" and exits
# 49. A caller that trusted the presence check therefore believed Python was
# available and then died at the point of use - under `set -e` that took the
# caller out rather than degrading it. Probe by EXECUTING instead.
#
# The probe also asserts major version >= 3. `-c 'pass'` succeeds under Python 2
# as well, and firstmate's payloads are Python-3-only (`pathlib`, `tomllib`,
# `open(..., encoding=)`), so an interpreter that merely starts is not an answer.
# One execution settles both questions.
#
# Candidates, in order:
#   python3   the canonical name everywhere except a stock Windows box
#   python    frequently the only real interpreter on Windows, and a Python 2 on
#             some older Unix boxes - which the major-version assertion rejects
#   py -3     the Windows Python launcher, which some installs register instead
#             of putting an interpreter on PATH. It is a MULTI-WORD command, so
#             the resolved answer is an argv array and not a single word; a bare
#             `$FM_PYTHON3 -c ...` would word-split by accident and cannot
#             express it.
#
# The scan is per NAME, not per PATH entry: a shadowed `python3` does not send
# the probe hunting for a second `python3` further down PATH. That is enough for
# the case this exists for, because a real Windows Python install registers
# `python.exe` and the `py` launcher rather than a second `python3`, and each
# extra PATH entry would cost another interpreter startup.
#
# Measured on the captain's box (Windows 11 26200, Git Bash, 2026-08-22):
# `python3` -> rc 49 Store stub; `python` -> rc 0, CPython 3.12; `py -3` -> rc 0,
# CPython 3.12. So `py -3` is not load-bearing there, but it is the documented
# Windows entry point and costs one array element.
#
# Usage:
#   . "$SCRIPT_DIR/fm-python-lib.sh"
#   if fm_python3; then
#     "${FM_PYTHON3_CMD[@]}" -c 'print(1)'
#   else
#     fm_python3_refuse 'my-script'   # prints the actionable message, returns 1
#   fi
#
# The answer lands in FM_PYTHON3 / FM_PYTHON3_CMD rather than on stdout, because
# a `$(fm_python3)` would run in a subshell and re-probe on every call, doubling
# exactly the interpreter startups this cache exists to bound. `fm_python3`
# returns status only.
#
# Set FM_PYTHON3_PROBED= to force a re-probe (tests that move PATH under it).
# Re-sourcing this file in a shell that already has it is a no-op.

# Idempotent guard, the same shape tests/lib.sh uses: this library is sourced
# both by a caller directly and by bin/backends/herdr.sh at adapter load, so one
# shell legitimately sources it twice. Re-running the initializers below would
# wipe an already-resolved FM_PYTHON3_CMD back to an empty array, and a caller
# holding a "yes" answer would then expand nothing in front of its arguments and
# run its first argument as the command. The probe itself is NOT guarded:
# FM_PYTHON3_PROBED= still forces a re-probe, which tests rely on.
if [ -n "${FM_PYTHON_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_PYTHON_LIB_SOURCED=1

# '' = unprobed, 'yes' = FM_PYTHON3_CMD is usable, 'no' = nothing works.
FM_PYTHON3_PROBED=
# The resolved command as a display string ("python3", "py -3"). Empty until a
# successful probe. Do not invoke this; invoke FM_PYTHON3_CMD.
# shellcheck disable=SC2034 # Read by sourcing callers and tests, not by this file.
FM_PYTHON3=
# The resolved command as an argv array. Empty until a successful probe.
FM_PYTHON3_CMD=()

# The candidate list, one command per line, words separated by spaces. Kept as a
# function so the order is stated exactly once and the tests can read it.
fm_python3_candidates() {
  # printf, not a `cat` heredoc: this runs on refusal paths where the caller may
  # have narrowed PATH, and a shell builtin cannot itself go missing.
  printf '%s\n' 'python3' 'python' 'py -3'
}

# fm_python3: resolve a working Python 3 into FM_PYTHON3_CMD.
# Returns 0 with FM_PYTHON3 and FM_PYTHON3_CMD set, 1 when no candidate runs.
fm_python3() {
  local line first
  local -a words
  case "$FM_PYTHON3_PROBED" in
    yes) return 0 ;;
    no) return 1 ;;
  esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Word-split the candidate deliberately: the list is this file's own literal.
    # shellcheck disable=SC2206
    words=($line)
    first=${words[0]}
    command -v "$first" >/dev/null 2>&1 || continue
    "${words[@]}" -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' \
      >/dev/null 2>&1 || continue
    FM_PYTHON3=$line
    FM_PYTHON3_CMD=("${words[@]}")
    FM_PYTHON3_PROBED=yes
    return 0
  done < <(fm_python3_candidates)
  # shellcheck disable=SC2034 # Read by sourcing callers, not by this file.
  FM_PYTHON3=
  FM_PYTHON3_CMD=()
  FM_PYTHON3_PROBED=no
  return 1
}

# fm_python3_refuse [<prefix>]: print the actionable refusal to stderr and
# return 1, so a caller can `fm_python3 || { fm_python3_refuse me; exit 1; }`.
# It names every candidate tried and the Store-alias trap by name, because
# "python3 not found" is the one diagnosis a Windows user will reject as wrong -
# `python3` is right there on their PATH.
fm_python3_refuse() {
  local prefix=${1:-fm-python-lib} line tried=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tried="${tried:+$tried, }$line"
  done < <(fm_python3_candidates)
  printf '%s: refused: no working Python 3 found. Tried: %s.\n' "$prefix" "$tried" >&2
  printf '%s: a name that resolves on PATH is not enough - each candidate was run and had to report major version 3 or newer.\n' \
    "$prefix" >&2
  printf '%s: on Windows, PATH usually carries the Microsoft Store app-execution alias for python3, which exits 49 without running. Install Python 3 from python.org, or turn the alias off under Settings > Apps > Advanced app settings > App execution aliases.\n' \
    "$prefix" >&2
  return 1
}

# fm_python3_run <args...>: run the resolved interpreter, or refuse.
# Returns 127 when no interpreter resolved, which callers that must tell that
# case apart from the payload's own status should pre-empt by calling
# fm_python3 themselves.
fm_python3_run() {
  fm_python3 || return 127
  "${FM_PYTHON3_CMD[@]}" "$@"
}
