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
# `bash --rcfile <this file> -i`. That replaces the USER file, ~/.bashrc, and
# only that one - so this file sources ~/.bashrc itself: the captain's own
# environment, aliases, and the OSC 0 title sequence that this backend's
# worktree discovery depends on all have to survive untouched. The SYSTEM file
# is not ours to source. bash runs SYS_BASHRC unconditionally for an interactive
# shell, before the --rcfile and suppressed only by --norc, so sourcing
# /etc/bash.bashrc here would run it a SECOND time and repeat every
# non-idempotent side effect in it and in the /etc/profile.d files it pulls in:
# a doubled PATH prepend, ssh-agent or keychain started twice, and a banner
# printed twice into the very screen the liveness fallback reads to classify
# this session. On a bash built without SYS_BASHRC, sourcing it here would be
# worse rather than better - no other shell on that host reads the system file,
# so the session shell would be the odd one out, which is the opposite of the
# parity this backend exists to reach.
#
# THE MARKS FOLLOW THE SESSION INTO A NESTED SHELL. The two hooks that carry
# them are EXPORTED, so an interactive bash opened BY HAND inside the session
# keeps marking itself instead of going silent, and the last mark reads as the
# INNERMOST interactive shell's answer - exactly what tmux reads off a pane's
# foreground process group: whoever last spoke is whoever holds the foreground.
#
#   PS0             the `C` mark, printed when a command starts
#   PROMPT_COMMAND  the `D` mark, printed before the next prompt is drawn
#
# NO FIRSTMATE PATH PUTS A SHELL BETWEEN THIS ONE AND THE AGENT. It used to: a
# bare `treehouse get` opens the pooled worktree in a provider SUBSHELL that
# lives for the whole task, so the agent started one level down, in a shell that
# reads its own rc files rather than this one. bin/fm-spawn.sh now acquires the
# worktree on this backend with `treehouse get --lease` and `cd`s into it in
# THIS shell, so the agent runs here and no foreign rc file sits between
# firstmate and the mark.
#
# That matters because inheritance is not immunity. A nested shell sources
# /etc/bash.bashrc and ~/.bashrc AFTER inheriting the carriers, and an ordinary
# `PROMPT_COMMAND='history -a'` in one of them destroys the finished-mark
# carrier while leaving PS0 intact: the session then emits `C` and never `D`,
# and the signal freezes at "a command is running". Measured on real Windows
# with the provider subshell in place: a clean HOME gave DABCDCDCDCDABC, a
# clobbering one gave DABCCCCDABC. That is a loud failure to PROVE a stop -
# `fm-control exit` refuses rather than reporting an unproven transition - never
# a false stop, and it is now reachable only in a shell someone opened by hand.
#
# PS1 is NOT exported, because exporting it does not work here: Git for Windows'
# /etc/bash.bashrc honours an already-exported PS1, and then sources
# /etc/profile.d/git-prompt.sh for every non-login interactive shell, which
# overwrites PS1 unconditionally. PS0 and PROMPT_COMMAND are touched by neither
# file, which is what makes them the durable carriers. A nested shell whose own
# rc files overwrite BOTH emits no marks at all, and liveness falls back exactly
# as it does for a session that never armed.
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
# bash has already run the system rc by the time this file is read; only the
# user file was displaced by --rcfile, so only the user file is restored here.
if [ -n "${HOME:-}" ] && [ -f "$HOME/.bashrc" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.bashrc"
fi

# SHELL, so the session's own child tools agree with it about what shell this is.
# A real Git Bash session is a LOGIN shell and /etc/profile sets this; the
# session shell here is deliberately not one, so an absent SHELL reaches every
# tool that consults it. `treehouse get` opens $SHELL and falls back to
# %COMSPEC% when it cannot; measured on real Windows with treehouse 2.1.1, SHELL
# unset gets cmd.exe, which announces no OSC 0 title and can emit no prompt
# mark.
#
# This is DEFENSIVE, not load-bearing for the spawn path. fm-spawn acquires the
# worktree on this backend with `treehouse get --lease` inside a command
# substitution, which opens no shell at all, so worktree discovery reads this
# shell's own `cd` and $SHELL cannot break it. What the repair still protects is
# every other tool in the session that opens $SHELL, and a hand-run
# `treehouse get`.
#
# THE PROBE ASKS WHAT THE NATIVE CONSUMER ASKS. treehouse.exe CreateProcesses
# this value: it cannot run a script and it cannot word-split. `[ -x ]` answers
# a different question - whether THIS msys bash could resolve it - and it
# wrongly accepts a shebang wrapper no native launcher can start. So the test is
# that a real Windows executable image stands behind the value: the file, or the
# file plus the `.exe` msys appends implicitly and a native launcher does not,
# must begin with the PE magic `MZ`. A POSIX-form value is fine and stays -
# /bin/bash and /usr/bin/bash are real .exe images, and treehouse is measured to
# run them.
#
# Probed rather than assumed, and only ever a fallback: a SHELL a native
# launcher can start is the captain's, and is left alone.
_fm_conpty_native_image() {  # <value>
  local p=${1:-}
  [ -n "$p" ] || return 1
  [ -f "$p" ] || p="$p.exe"
  [ -f "$p" ] || return 1
  [ "$(LC_ALL=C head -c 2 "$p" 2>/dev/null)" = MZ ]
}
if ! _fm_conpty_native_image "${SHELL:-}"; then
  export SHELL="${BASH:-/usr/bin/bash}"
fi
unset -f _fm_conpty_native_image

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

# EACH CARRIER IS ARMED IDEMPOTENTLY, AND EACH ANSWERS FOR ITSELF. The question
# asked before every prepend is "does THIS carrier already hold firstmate's
# mark", read off the carrier rather than off a bookkeeping variable. A variable
# cannot answer it correctly in both directions at once: unexported it says
# nothing about a nested shell that inherited the carriers (which then prepends a
# second copy of the finished mark, one more per nesting level, doubling the
# per-prompt bytes and inflating the promptMarks counter), and exported it makes
# a nested shell whose own rc files WIPED the carriers return early and never
# re-arm. Reading the carrier is right for both: a re-source adds nothing, and a
# clobbered carrier heals.
if _fm_conpty_bash_has_ps0; then
  # C: a command has started, so a command owns the foreground. Prepended rather
  # than assigned, behind the same contains-the-mark test the other carriers use,
  # because an operator who sets PS0 in their own rc files would otherwise lose it
  # here and - PS0 being exported so nested shells inherit the carrier - in every
  # nested interactive bash for the session's life. The mark still lands on the
  # stream at command start either way.
  case "${PS0:-}" in
    *'133;C;fmpty=1'*) ;;
    *) PS0='\e]133;C;fmpty=1\a'"${PS0:-}" ;;
  esac
  export PS0

  # A and B bracket the prompt itself. Both are wrapped in \[ \] so bash counts
  # them as zero-width: an unwrapped escape sequence in PS1 corrupts readline's
  # idea of the line length, which would misplace the cursor the composer
  # classifier reads.
  case "${PS1:-}" in
    *'133;A;fmpty=1'*) ;;
    *) PS1='\[\e]133;A;fmpty=1\a\]'"${PS1:-\\s-\\v\\\$ }"'\[\e]133;B;fmpty=1\a\]' ;;
  esac

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
  # environment, so an inherited array is flattened into one list. The join is by
  # NEWLINE, not `; `, because an element carrying a trailing `#` comment would
  # otherwise comment out every element after it on the joined line - measured on
  # bash 5.2 with a two-element array whose first element ended in a comment: the
  # second hook ran zero times. bash evaluates PROMPT_COMMAND as a command list,
  # where a newline is as good a separator as `;`, and newlines survive the
  # export into a child. The elements keep their order, and the only property
  # lost is that bash would have run them as separate commands.
  _fm_conpty_mark_finished='_fm_conpty_status=$?; printf "\033]133;D;%s;fmpty=1\007" "$_fm_conpty_status"; ( exit "$_fm_conpty_status" )'
  _fm_conpty_pc_decl=$(declare -p PROMPT_COMMAND 2>/dev/null || true)
  case "$_fm_conpty_pc_decl" in
    'declare -a'*|'declare -ax'*)
      # SC2178/SC2128: this branch is the only one that reads PROMPT_COMMAND as
      # an array, and it runs only when `declare -p` proved it is one.
      # shellcheck disable=SC2178,SC2128
      _fm_conpty_pc_now=$(printf '%s\n' "${PROMPT_COMMAND[@]}")
      ;;
    *)
      # shellcheck disable=SC2178,SC2128
      _fm_conpty_pc_now=${PROMPT_COMMAND:-}
      ;;
  esac
  case "$_fm_conpty_pc_now" in
    *"$_fm_conpty_mark_finished"*) ;;
    *)
      # `unset` before assigning, because assigning a string to a variable that
      # is STILL DECLARED an array writes element 0 and leaves every later
      # element in place. The flattened copy then lives in element 0 while the
      # originals still run after it, so an rc file that used the documented
      # array form would have its trailing hooks run twice per prompt. Measured
      # on bash 5.2.21 with a two-element operator array, before this unset: two
      # prompts, the first hook ran twice (correct) and the last ran four times.
      unset PROMPT_COMMAND
      if [ -n "$_fm_conpty_pc_now" ]; then
        PROMPT_COMMAND="$_fm_conpty_mark_finished
$_fm_conpty_pc_now"
      else
        PROMPT_COMMAND="$_fm_conpty_mark_finished"
      fi
      export PROMPT_COMMAND
      ;;
  esac
  unset _fm_conpty_pc_decl _fm_conpty_pc_now _fm_conpty_mark_finished
fi

unset -f _fm_conpty_bash_has_ps0
