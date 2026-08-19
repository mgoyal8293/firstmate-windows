# shellcheck shell=bash
# fm-shell-integration.bash - the rcfile firstmate's ConPTY task sessions run,
# so the shell that holds the session announces whether it is at a prompt.
#
# WHY. A ConPTY console has no foreground process group, so the console process
# list alone cannot tell a harness that is RUNNING the session from one left
# attached in the background - the fidelity gap this backend carried against
# tmux. The shell can simply be asked instead. These are the OSC 133
# (FinalTerm/FTCS) semantic prompt marks Microsoft documents for Windows
# Terminal shell integration, and the session daemon reads them straight off the
# pty stream it already parses, at no polling cost. The decision they feed is
# owned by fmpty-liveness.js, which explains the verdict table.
#
# HOW IT IS LOADED. bin/backends/conpty.sh launches the session shell as
# `bash --rcfile <this file> -i`. That REPLACES ~/.bashrc rather than adding to
# it, so this file sources the system and user files first: the captain's own
# environment, aliases, and the OSC 0 title sequence that this backend's
# worktree discovery depends on all have to survive untouched.
#
# THE MARKS FOLLOW THE SESSION INTO A NESTED SHELL, and they have to. A task
# session does not run its agent in the shell this rcfile armed: `fm-spawn` sends
# `treehouse get`, and the worktree provider opens a SUBSHELL in the pooled
# worktree that lives for the whole task, so the agent is launched one level
# down. That subshell reads its own rc files, not this one. Measured on real
# Windows: with the marks kept shell-local, the armed outer shell emits `C` when
# `treehouse get` starts and then nothing for the rest of the task, so the last
# mark says "a command is running" forever - it never returns to a prompt, and
# `fm-control exit`'s "the agent stopped" postcondition can never be satisfied.
#
# So the two hooks that carry the marks are EXPORTED, and the nested shell
# continues the chain instead of silencing it. Together they read as the
# INNERMOST interactive shell's answer, which is exactly what tmux reads off a
# pane's foreground process group: whoever last spoke is whoever holds the
# foreground.
#
#   PS0             the `C` mark, printed when a command starts
#   PROMPT_COMMAND  the `D` mark, printed before the next prompt is drawn
#
# PS1 is NOT exported, because exporting it does not work here: Git for Windows'
# /etc/bash.bashrc honours an already-exported PS1, and then sources
# /etc/profile.d/git-prompt.sh for every non-login interactive shell, which
# overwrites PS1 unconditionally. PS0 and PROMPT_COMMAND are touched by neither
# file, which is what makes them the durable carriers. A nested shell whose own
# rc files DO overwrite them simply emits no marks, and liveness falls back
# exactly as it does for a session that never armed at all.
#
# THE MARKS ARE TAGGED. Every mark carries `fmpty=1`, and the daemon ignores any
# OSC 133 mark without it. The harness writes to the same stream, so an
# untagged mark from a harness that ships its own shell integration could
# otherwise be read as this shell's - and a harness announcing "command
# finished" while it is alive is the one direction that could produce a false
# `dead`.
#
# IT ARMS ONLY WHEN IT CAN BE HONEST. PS0 - the only hook that fires when a
# command STARTS - needs bash 4.4 or newer. On an older bash there is no way to
# mark a command as running, and marking only the prompt would report a live
# foreground agent as "at a prompt", which is exactly the false `dead` this must
# never produce. So on an older bash this arms nothing at all, the daemon sees
# no mark, and liveness falls back to the process-list-and-screen reading this
# backend shipped with.

# Order matters: the captain's environment first, this file's additions second,
# so nothing here is overwritten by a later PS1 or PROMPT_COMMAND assignment.
if [ -f /etc/bash.bashrc ]; then
  # shellcheck source=/dev/null
  . /etc/bash.bashrc
fi
if [ -n "${HOME:-}" ] && [ -f "$HOME/.bashrc" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.bashrc"
fi

# SHELL, so the session's own child tools agree with it about what shell this is.
# A real Git Bash session is a LOGIN shell and /etc/profile sets this; the
# session shell here is deliberately not one, so an absent or foreign SHELL
# reaches every tool that consults it. The worktree provider is one such tool and
# it is on this backend's critical path: `treehouse get` opens $SHELL, and falls
# back to %COMSPEC% - cmd.exe - when it cannot. Measured on real Windows with
# treehouse 2.1.1: SHELL unset opens cmd.exe, which announces no OSC 0 title (so
# fm-spawn's worktree discovery never sees the pane leave the project) and can
# emit no prompt mark (so the chain above stops at the outer shell). An inherited
# value that does not resolve here is the same hazard wearing a different hat: a
# firstmate started from WSL exports SHELL=/bin/bash, which is not this host's
# bash, and the provider then opens a subshell that dies immediately.
#
# Probed rather than assumed, and only ever a fallback: a SHELL that resolves to
# an executable is the captain's, and is left alone.
if [ -z "${SHELL:-}" ] || [ ! -x "${SHELL:-}" ]; then
  export SHELL="${BASH:-/usr/bin/bash}"
fi

if [ -n "${_FM_CONPTY_SHELL_INTEGRATION:-}" ]; then
  return 0
fi

# The PS0 floor, checked rather than assumed. BASH_VERSINFO is unset in a
# non-bash shell, which lands in the same "arm nothing" branch.
_fm_conpty_bash_has_ps0() {
  local major=${BASH_VERSINFO[0]:-0} minor=${BASH_VERSINFO[1]:-0}
  case "$major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$minor" in
    ''|*[!0-9]*) minor=0 ;;
  esac
  [ "$major" -gt 4 ] && return 0
  [ "$major" -eq 4 ] && [ "$minor" -ge 4 ] && return 0
  return 1
}

if _fm_conpty_bash_has_ps0; then
  # C: a command has started, so a command owns the foreground.
  PS0='\e]133;C;fmpty=1\a'
  export PS0
  # A and B bracket the prompt itself. Both are wrapped in \[ \] so bash counts
  # them as zero-width: an unwrapped escape sequence in PS1 corrupts readline's
  # idea of the line length, which would misplace the cursor the composer
  # classifier reads.
  PS1='\[\e]133;A;fmpty=1\a\]'"${PS1:-\\s-\\v\\\$ }"'\[\e]133;B;fmpty=1\a\]'

  # D fires before the next prompt is drawn, and is the one mark a nested shell
  # must be able to emit on its own, so it is written as a self-contained command
  # list rather than a call to a function defined here. An exported function
  # would be invisible to a nested shell in POSIX mode (bash does not import
  # functions from the environment there), and a PROMPT_COMMAND naming a function
  # that does not exist prints a "command not found" line into the session on
  # every prompt.
  #
  # The status is captured first and restored last, so prepending this to a
  # PROMPT_COMMAND the captain already had cannot change what that hook sees in
  # $?. PROMPT_COMMAND is a string on every bash that reaches here and an array
  # from 5.1 on; only the string form can cross into a child through the
  # environment, so an inherited array is flattened into one list. The elements
  # keep their order and their separators, and the only property lost is that
  # bash would have run them as separate commands.
  _fm_conpty_mark_finished='_fm_conpty_status=$?; printf "\033]133;D;%s;fmpty=1\007" "$_fm_conpty_status"; ( exit "$_fm_conpty_status" )'
  _fm_conpty_pc_decl=$(declare -p PROMPT_COMMAND 2>/dev/null || true)
  case "$_fm_conpty_pc_decl" in
    'declare -a'*|'declare -ax'*)
      # SC2178/SC2128: this branch is the only one that reads PROMPT_COMMAND as
      # an array, and it runs only when `declare -p` proved it is one.
      # shellcheck disable=SC2178,SC2128
      _fm_conpty_pc_joined=$(printf '%s; ' "${PROMPT_COMMAND[@]}")
      PROMPT_COMMAND="$_fm_conpty_mark_finished; ${_fm_conpty_pc_joined%; }"
      unset _fm_conpty_pc_joined
      ;;
    *)
      # shellcheck disable=SC2178,SC2128
      PROMPT_COMMAND="$_fm_conpty_mark_finished${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
      ;;
  esac
  export PROMPT_COMMAND
  unset _fm_conpty_pc_decl _fm_conpty_mark_finished

  # Exported, so a nested shell that does source this file - a hand-started
  # session, a relaunch - finds the chain already armed and leaves it alone
  # instead of prepending a second copy of the same mark.
  export _FM_CONPTY_SHELL_INTEGRATION=1
fi

unset -f _fm_conpty_bash_has_ps0
