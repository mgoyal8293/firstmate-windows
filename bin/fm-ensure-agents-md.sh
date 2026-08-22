#!/usr/bin/env bash
# Ensure a project worktree follows the agent-memory file convention.
# AGENTS.md is the real project-intrinsic knowledge file; CLAUDE.md is a
# real regular file whose canonical content is the two-line @AGENTS.md pointer
# that Claude Code inlines at load time. Creates a minimal AGENTS.md skeleton
# when neither file exists, promotes a real CLAUDE.md file when it is the only
# file present (unless it is already the canonical pointer), converts a correct
# CLAUDE.md -> AGENTS.md symlink into the pointer file, and refuses to clobber
# distinct real files or wrong symlinks.
# Owns the canonical "## Maintaining this file" self-governance wording for
# project AGENTS.md files, injecting it idempotently into created skeletons,
# promoted CLAUDE.md files, and any existing AGENTS.md that still lacks it.
# Owns the canonical CLAUDE.md pointer content (the exact two-line @AGENTS.md
# form). A real-file pointer cannot follow a write into AGENTS.md, which is why
# the installer never creates a CLAUDE.md symlink.
# Refuses a case-variant real memory file such as a lowercase agents.md, so the
# pointer's @AGENTS.md import resolves to a real AGENTS.md on a case-sensitive
# filesystem (issue #389). The real-file pointer also eliminates the old
# uppercase-literal-target dangling-symlink hazard that a CLAUDE.md -> AGENTS.md
# link would have carried for that same mismatch.
# This is a worktree utility for crewmates, not a supervision script, so it does
# not call fm-guard.sh.
# Usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]
set -eu

usage() {
  echo "usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]" >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
[ "$#" -le 1 ] || { usage; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-python-lib.sh
. "$SCRIPT_DIR/fm-python-lib.sh"

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)
cd "$DIR"

AGENTS=AGENTS.md
CLAUDE=CLAUDE.md

write_maintenance_section() {
  cat <<'EOF'
## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
EOF
}

write_maintenance_section_with_eol() {
  local eol=$1 line
  while IFS= read -r line; do
    printf '%s%s' "$line" "$eol"
  done < <(write_maintenance_section)
}

# Idempotently append the canonical self-governance section to AGENTS.md when it
# is absent. Sets MAINT_INJECTED=1 when it appends and 0 when the section is
# already present, so callers can report whether the file changed.
MAINT_INJECTED=0
ensure_maintenance_section() {
  MAINT_INJECTED=0
  # -U (binary) is load-bearing: MSYS grep reads in text mode and swallows the
  # CR of a CRLF terminator, so without it the CRLF branches below silently
  # answer "no CRLF" on Windows and firstmate writes LF into a project's CRLF
  # AGENTS.md. GNU grep on Linux and macOS accepts -U and it is a no-op there.
  if grep -UFqx '## Maintaining this file' "$AGENTS" ||
    grep -UFqx $'## Maintaining this file\r' "$AGENTS"; then
    return 0
  fi
  local eol=$'\n' sep=''
  if LC_ALL=C grep -Uq $'\r$' "$AGENTS"; then
    eol=$'\r\n'
  fi
  if [ -s "$AGENTS" ]; then
    if [ -n "$(tail -c 1 "$AGENTS")" ]; then
      sep="${eol}${eol}"
    else
      sep=$eol
    fi
  fi
  {
    printf '%s' "$sep"
    write_maintenance_section_with_eol "$eol"
  } >> "$AGENTS"
  MAINT_INJECTED=1
}

write_skeleton() {
  cat > "$AGENTS" <<'EOF'
# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
EOF
  ensure_maintenance_section
}

# Canonical CLAUDE.md pointer: a real file, never a symlink. Byte-identical
# two-line form so a stray write clobbers only this recoverable pointer.
claude_pointer_content() {
  cat <<'EOF'
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
}

is_canonical_claude_pointer() {
  [ -f "$CLAUDE" ] && [ ! -L "$CLAUDE" ] || return 1
  claude_pointer_content | cmp -s - "$CLAUDE"
}

# Write the canonical pointer as a regular file. Unlink a symlink first so the
# write cannot follow it and destroy AGENTS.md. Never overwrite a distinct real
# file; callers classify that as a conflict before invoking this.
install_claude_pointer() {
  if is_canonical_claude_pointer; then
    return 0
  fi
  if [ -L "$CLAUDE" ]; then
    rm -- "$CLAUDE"
  elif [ -e "$CLAUDE" ]; then
    echo "error: internal: refuse to overwrite existing CLAUDE.md" >&2
    exit 1
  fi
  claude_pointer_content > "$CLAUDE"
}

# 0 = the link resolves to AGENTS.md, 1 = it demonstrably does not,
# 2 = UNDETERMINABLE. The third code exists because the old code had only two:
# it ran `python3` behind `command -v python3` and returned that exit status
# directly, so on Windows - where `python3` resolves to the Microsoft Store
# alias and exits 49 without running - a correct pointer was judged wrong and
# the caller refused a healthy worktree with a false conflict. A failed
# interpreter is not evidence about the symlink, and no caller may read it as any.
# Sets UNDETERMINABLE_CAUSE so a verdict of 2 can name why it could not answer.
UNDETERMINABLE_CAUSE=interpreter
is_correct_claude_symlink() {
  [ -L "$CLAUDE" ] || return 1
  target=$(readlink "$CLAUDE")
  case "$target" in
    "$AGENTS"|"./$AGENTS") return 0 ;;
  esac
  [ -e "$AGENTS" ] || return 1
  UNDETERMINABLE_CAUSE=interpreter
  if fm_python3; then
    UNDETERMINABLE_CAUSE=payload
    # The payload answers on stdout, not through its exit status, because a
    # status cannot say "I did not run": CPython exits 1 on an uncaught
    # traceback, which is indistinguishable from a real "the paths differ", and
    # a signal or a half-installed stdlib produces some other number. Only the
    # EQ or NE sentinel is an answer; anything else - no output, a wrapper's
    # extra chatter, a partial write - falls through to the resolver below.
    answer=$("${FM_PYTHON3_CMD[@]}" - "$CLAUDE" "$AGENTS" <<'PY' || true
import os
import sys
print("EQ" if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else "NE")
PY
    )
    case "$answer" in
      EQ) return 0 ;;
      NE) return 1 ;;
    esac
  fi
  # No usable answer from Python, either because nothing ran or because what ran
  # did not answer: ask the shell's own resolver before giving up, so a box
  # without a working interpreter still gets a real answer rather than a false
  # conflict.
  if command -v realpath >/dev/null 2>&1; then
    resolved_claude=$(realpath "$CLAUDE" 2>/dev/null) || return 2
    resolved_agents=$(realpath "$AGENTS" 2>/dev/null) || return 2
    [ -n "$resolved_agents" ] || return 2
    [ "$resolved_claude" = "$resolved_agents" ] || return 1
    return 0
  fi
  return 2
}

# Report the undeterminable verdict and stop. Kept in one place so both call
# sites refuse identically and neither can slide back into "conflict" wording
# for a question that was never answered.
refuse_undeterminable_symlink() {
  echo "error: cannot determine whether the CLAUDE.md symlink in $DIR resolves to AGENTS.md" >&2
  # Name the cause that actually applies. Printing "no working Python 3 found"
  # when an interpreter was found and ran sends the reader after the wrong
  # problem.
  if [ "${UNDETERMINABLE_CAUSE:-interpreter}" = payload ]; then
    echo "error: fm-ensure-agents-md: $FM_PYTHON3 ran but its path comparison exited with an unexpected status, and realpath could not answer either" >&2
  else
    fm_python3_refuse fm-ensure-agents-md || true
  fi
  exit 1
}

# Refuse a case-variant real memory file (issue #389). On a case-insensitive
# filesystem an existing lowercase agents.md satisfies every [ -e AGENTS.md ]
# test below, so the script would emit a CLAUDE.md pointer whose @AGENTS.md
# import dangles once the tree is checked out on a case-sensitive filesystem.
# Reading the real directory entries catches the mismatch on both filesystem
# kinds; surface it for manual reconciliation instead of writing the pointer
# against the wrong name.
for entry in *; do
  if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
    continue
  fi
  if [ "$entry" != "$AGENTS" ]; then
    case "$entry" in
      [Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd])
        echo "conflict: memory file is named $entry in $DIR but the convention is AGENTS.md; rename it to AGENTS.md so CLAUDE.md's @AGENTS.md pointer resolves portably" >&2
        exit 1
        ;;
    esac
  fi
done

if [ -L "$AGENTS" ]; then
  echo "conflict: AGENTS.md is a symlink in $DIR; expected AGENTS.md to be the real file" >&2
  exit 1
fi
if [ -e "$AGENTS" ] && [ ! -f "$AGENTS" ]; then
  echo "conflict: AGENTS.md exists in $DIR but is not a regular file" >&2
  exit 1
fi

if [ -e "$AGENTS" ]; then
  if [ -L "$CLAUDE" ]; then
    SYMLINK_VERDICT=0
    is_correct_claude_symlink || SYMLINK_VERDICT=$?
    [ "$SYMLINK_VERDICT" -ne 2 ] || refuse_undeterminable_symlink
    if [ "$SYMLINK_VERDICT" -eq 0 ]; then
      ensure_maintenance_section
      install_claude_pointer
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer in $DIR"
      else
        echo "updated: replaced CLAUDE.md symlink with @AGENTS.md pointer in $DIR"
      fi
      exit 0
    fi
    echo "conflict: CLAUDE.md is a symlink in $DIR but does not point to AGENTS.md" >&2
    exit 1
  fi
  if [ ! -e "$CLAUDE" ]; then
    ensure_maintenance_section
    install_claude_pointer
    if [ "$MAINT_INJECTED" -eq 1 ]; then
      echo "updated: added ## Maintaining this file to AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer in $DIR"
    else
      echo "wrote: CLAUDE.md @AGENTS.md pointer in $DIR"
    fi
    exit 0
  fi
  if [ -f "$CLAUDE" ]; then
    if is_canonical_claude_pointer; then
      ensure_maintenance_section
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md in $DIR"
      else
        echo "unchanged: AGENTS.md with CLAUDE.md @AGENTS.md pointer in $DIR"
      fi
      exit 0
    fi
    echo "conflict: both AGENTS.md and CLAUDE.md are real files in $DIR; reconcile them manually" >&2
    exit 1
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

if [ -L "$CLAUDE" ]; then
  SYMLINK_VERDICT=0
  is_correct_claude_symlink || SYMLINK_VERDICT=$?
  [ "$SYMLINK_VERDICT" -ne 2 ] || refuse_undeterminable_symlink
  if [ "$SYMLINK_VERDICT" -eq 0 ]; then
    write_skeleton
    install_claude_pointer
    echo "created: AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer in $DIR"
    exit 0
  fi
  echo "conflict: CLAUDE.md is a symlink in $DIR but AGENTS.md is missing and the link does not point to AGENTS.md" >&2
  exit 1
fi

if [ -e "$CLAUDE" ]; then
  if [ -f "$CLAUDE" ]; then
    if is_canonical_claude_pointer; then
      write_skeleton
      echo "created: AGENTS.md and kept CLAUDE.md @AGENTS.md pointer in $DIR"
      exit 0
    fi
    mv "$CLAUDE" "$AGENTS"
    ensure_maintenance_section
    install_claude_pointer
    echo "promoted: moved CLAUDE.md to AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer in $DIR"
    exit 0
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

write_skeleton
install_claude_pointer
echo "created: AGENTS.md and CLAUDE.md @AGENTS.md pointer in $DIR"
