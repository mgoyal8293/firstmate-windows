'use strict';
// fmpty-liveness.js - the ConPTY backend's liveness decision, kept in one
// dependency-free module.
//
// WHY IT IS ITS OWN FILE. The daemon cannot run anywhere but Windows: it needs
// node-pty's prebuilt binary and a real ConPTY. Its liveness verdict, though, is
// pure logic over a handful of facts, and that verdict is what decides whether
// firstmate is allowed to recover a task - so it is the part that most needs a
// regression test on every platform CI runs. Splitting it out is what lets the
// liveness block of tests/fm-backend-conpty.test.sh - the decideAgentState,
// createPromptTracker and classifyScreenRows cases - exercise the real decision
// with plain node instead of asserting it by reading the daemon's source. The
// real-host end of that coverage is the opt-in guard
// tests/fm-conpty-liveness-live-e2e.test.sh.
//
// TWO SOURCES, AND WHY THE PROMPT MARKER LEADS. tmux scopes liveness to the
// pane tty's FOREGROUND process group, which is how a harness-named process
// idling in the BACKGROUND of an otherwise idle pane still classifies `dead`. A
// ConPTY console has a process list but no foreground concept and no
// `tcgetpgrp` equivalent, so that set cannot be narrowed the same way.
//
// The substitute is not a Win32 call but a question the shell can answer about
// itself: IS THE SHELL AT A PROMPT? OSC 133 semantic prompt marking (the
// FinalTerm/FTCS sequences Microsoft documents for Windows Terminal shell
// integration) has bash say so on the pty stream the daemon already parses:
//
//   OSC 133 ; A   start of prompt    -> the shell owns the foreground
//   OSC 133 ; B   end of prompt      -> the shell owns the foreground
//   OSC 133 ; C   command started    -> a command owns the foreground
//   OSC 133 ; D   command finished   -> the shell owns the foreground
//
// `at-prompt` therefore means exactly what tmux reads off a foreground process
// group holding nothing but a shell: nothing else is in charge, so a harness
// still attached is not running the session. That is the fidelity gap closed,
// and it costs nothing per poll - the marker is tracked as the bytes arrive,
// with no syscall, no process sweep, and no PowerShell.
//
// The markers are emitted by BASH, not by the harness, so whatever the agent
// draws - the alternate screen, a full redraw, an erase-display - is
// irrelevant. That is why this source is robust where the screen heuristic is
// not.
//
// WHICH shell emits them is deliberately not narrowed. The rcfile exports its
// two hooks, so every interactive bash in the session marks itself and the last
// mark is the INNERMOST shell's answer - the same thing tmux reads when it
// scopes to a pane's foreground process group. On the firstmate path that is
// the session shell itself: `fm-spawn` leases the worktree and `cd`s into it on
// this backend rather than sending a bare `treehouse get`, whose provider
// subshell used to host the agent one level down and, measured on real Windows,
// froze the last mark at `C` for the task's whole life whenever that subshell's
// own rc files reassigned PROMPT_COMMAND.
//
// FAIL SAFE WHEN THE SIGNAL IS ABSENT. A session that has emitted no marker -
// an older Git Bash whose bash predates PS0, a shell that ignored the rcfile, a
// non-bash session shell - reports `unknown`, and the verdict falls back to the
// process-list-plus-screen table this backend shipped with. Silence is never
// read as `dead`: a false `dead` is the one outcome that can launch a duplicate
// agent onto a live worktree.

// The marker vocabulary. `fmpty=1` is a firstmate-private discriminator carried
// as an ordinary FTCS parameter, and a marker WITHOUT it is ignored.
//
// It exists because the harness writes to this stream too. A harness that
// emitted its own OSC 133 marks - none of the verified ones does, checked
// against real transcripts - would otherwise be able to announce `D` (command
// finished) while it is itself alive, which is the one direction that could
// produce a false `dead`. Requiring a parameter only firstmate's own rcfile
// writes makes that collision impossible by construction, rather than by vendor
// behaviour a release could change.
//
// The tag does not need to be session-unique. A nested shell DOES inherit the
// hooks - that is the point above - but a nested shell is part of this session,
// and its answer about the foreground is the one that matters. What the tag has
// to exclude is a marker from something that is not a firstmate-armed shell at
// all, and the environment is not a route into that: a process the harness
// spawns with its own output captured never reaches this stream. Verified
// against a real Claude Code 2.1.220 running a real Bash tool call: the mark
// count did not move and the verdict stayed `alive`.
const FM_MARK_TAG = 'fmpty=1';
const PROMPT_RUNNING = 'running';
const PROMPT_AT_PROMPT = 'at-prompt';
const PROMPT_UNKNOWN = 'unknown';

const ESC = '\u001b';
const BEL = '\u0007';
const OSC_OPEN = ESC + ']';
const ST = ESC + '\\';

// A marker can be split across pty chunks, so an incomplete one is carried to
// the next feed. The carry is bounded: a stream that opens an OSC and never
// terminates it must not grow this without limit. Dropping an over-long carry is
// safe - the scanner resynchronises on the next OSC opener, and no marker is
// ever accepted without both its terminator and its tag.
const MAX_CARRY = 512;

// createPromptTracker: the marker state machine. `feed` takes raw pty text in
// arbitrary chunks; `state` answers the foreground question.
function createPromptTracker(opts) {
  const maxCarry = (opts && opts.maxCarry) || MAX_CARRY;
  let carry = '';
  let last = '';
  let accepted = 0;

  function accept(body) {
    // `body` is everything between the OSC opener and the terminator, e.g.
    // "133;C;fmpty=1" or "133;D;0;fmpty=1".
    const parts = body.split(';');
    if (parts.length < 3 || parts[0] !== '133') return;
    const letter = parts[1];
    if (letter !== 'A' && letter !== 'B' && letter !== 'C' && letter !== 'D') return;
    let tagged = false;
    for (let i = 2; i < parts.length; i++) {
      if (parts[i] === FM_MARK_TAG) { tagged = true; break; }
    }
    if (!tagged) return;
    last = letter;
    accepted++;
  }

  function feed(chunk) {
    const s = carry + String(chunk == null ? '' : chunk);
    carry = '';
    let i = 0;
    for (;;) {
      const open = s.indexOf(OSC_OPEN, i);
      if (open === -1) {
        // A trailing ESC may be the first byte of the next chunk's OSC opener.
        carry = s.charAt(s.length - 1) === ESC ? ESC : '';
        return;
      }
      const bel = s.indexOf(BEL, open + OSC_OPEN.length);
      const st = s.indexOf(ST, open + OSC_OPEN.length);
      let end = -1;
      let next = -1;
      if (bel !== -1 && (st === -1 || bel < st)) { end = bel; next = bel + 1; }
      else if (st !== -1) { end = st; next = st + ST.length; }
      if (end === -1) {
        const tail = s.slice(open);
        carry = tail.length <= maxCarry ? tail : '';
        return;
      }
      accept(s.slice(open + OSC_OPEN.length, end));
      i = next;
    }
  }

  function state() {
    if (last === 'C') return PROMPT_RUNNING;
    if (last === 'A' || last === 'B' || last === 'D') return PROMPT_AT_PROMPT;
    return PROMPT_UNKNOWN;
  }

  return {
    feed: feed,
    state: state,
    lastMark: function () { return last; },
    marks: function () { return accepted; },
  };
}

// The FALLBACK second source, used only when the session has emitted no prompt
// mark at all. A live harness owns the screen: its composer box or prompt glyph
// is the bottom-most shape, and a session sitting at a bare shell prompt looks
// structurally different. Deliberately conservative - it says `agent`, `shell` or
// `unknown`, and only ever narrows a verdict the process list already made.
//
// It lives here, taking rows rather than reading the terminal itself, because it
// is a RENDERED-SURFACE reading: what it matches is what a vendor draws, so it is
// the part most likely to rot and the part that most needs a regression test on
// every platform. Both of the reproduced defects it used to have are properties
// of how the rows are chosen and matched, so both are testable from here:
//
//   - blind on a sparse screen. A fresh session's content sits at the TOP of the
//     viewport, so a fixed count of rows taken from the viewport BOTTOM was all
//     blank and this returned `unknown` on a session whose prompt was plainly on
//     screen (measured: a verdict that flipped from `alive` to `ambiguous` with
//     the process state held identical and only the screen scrolled). Fixed by
//     taking the bottom-most NON-BLANK rows.
//   - a prompt matched anywhere in a block of rows. A prompt is the bottom-most
//     shape when a shell is prompting, so a leftover prompt line in recent
//     scrollback reported a genuinely-alive foreground agent as `ambiguous`.
//     Fixed by testing for a prompt on the bottom-most row alone.
const AGENT_GLYPH_RE = /[\u276F\u203A\u27E9\u2192]|esc to interrupt|\? for shortcuts|ctrl\+c to (?:exit|quit)/i;
const SHELL_PROMPT_RE = /[$#%][ \t]*$|MINGW64/;
const SCREEN_TAIL_ROWS = 6;

// screenTailRows: up to <limit> bottom-most non-blank rows of <rows>, oldest
// first. Trailing blank rows are skipped rather than counted.
function screenTailRows(rows, limit) {
  const all = Array.isArray(rows) ? rows : [];
  const max = limit || SCREEN_TAIL_ROWS;
  let end = all.length;
  while (end > 0 && String(all[end - 1] == null ? '' : all[end - 1]).trim() === '') end--;
  return all.slice(Math.max(0, end - max), end).map(function (r) {
    return String(r == null ? '' : r);
  });
}

// classifyScreenRows: agent | shell | unknown, from the session's viewport rows
// top-first.
function classifyScreenRows(rows, limit) {
  const tail = screenTailRows(rows, limit);
  if (!tail.length) return 'unknown';
  if (AGENT_GLYPH_RE.test(tail.join('\n'))) return 'agent';
  if (SHELL_PROMPT_RE.test(tail[tail.length - 1])) return 'shell';
  return 'unknown';
}

// decideAgentState: the fm_backend_agent_state verdict for one session, from
// facts the daemon has already gathered. Pure by construction, so the whole
// table is readable in one place.
//
// ev:
//   exited        truthy when the pty child is gone
//   listAvailable false when the console process list could not be read
//   listSource    how the list was resolved, for the unreadable reason string
//   agentName     the name of an attached verified-harness process, or ''
//   sawShell      an attached process is a shell
//   sawOther      an attached process is neither a harness nor a shell
//   prompt        running | at-prompt | unknown   (createPromptTracker)
//   screen        agent | shell | unknown         (the fallback second source)
//
// `dead` and `missing` are the only verdicts that license recovery, so every
// genuinely conflicting reading resolves to `ambiguous` or `unreadable`.
function decideAgentState(ev) {
  const e = ev || {};
  if (e.exited) return { state: 'missing', why: 'pty child exited' };
  if (!e.listAvailable) {
    return {
      state: 'unreadable',
      why: 'console process list unavailable (' + (e.listSource || 'cold') + ')',
    };
  }
  const agentName = e.agentName || '';

  // The shell's own marker settles the foreground question, so it is consulted
  // before the process list's shape and instead of the screen.
  if (e.prompt === PROMPT_AT_PROMPT) {
    return {
      state: 'dead',
      why: agentName
        ? 'the session shell is at a prompt, so ' + agentName + ' is attached but not in the foreground'
        : 'the session shell is at a prompt',
    };
  }
  if (e.prompt === PROMPT_RUNNING) {
    if (agentName) {
      return { state: 'alive', why: 'harness process ' + agentName + ' and a foreground command running' };
    }
    // A foreground command is running but no attached process is a recognised
    // harness. It could be an unrecognised harness build or an ordinary command
    // (`git`, `npm`, `treehouse get`), and this cannot tell them apart, so it
    // narrows to `ambiguous` exactly as tmux does for a foreground group holding
    // something other than a shell.
    return {
      state: 'ambiguous',
      why: 'a foreground command is running but no attached process is a recognised harness',
    };
  }

  // No marker has ever been seen. Fall back to the process-list-and-screen
  // table this backend shipped with, unchanged.
  if (agentName) {
    if (e.screen === 'shell') {
      return {
        state: 'ambiguous',
        why: 'harness process ' + agentName + ' attached but the screen shows a shell prompt',
      };
    }
    return { state: 'alive', why: 'harness process ' + agentName };
  }
  if (e.sawShell && !e.sawOther) {
    if (e.screen === 'agent') {
      return { state: 'ambiguous', why: 'only shells attached but the screen shows an agent composer' };
    }
    return { state: 'dead', why: 'only shells attached' };
  }
  return { state: 'ambiguous', why: 'no harness and not shell-only' };
}

// stateReport: the single owner of what `fmpty state` reports, so the arm taken
// when the console process list cannot be read cannot drift from the full one.
// Two hand-built objects for one contract is how the prompt-mark fields went
// missing from the unreadable arm: they are fed by the pty byte stream and never
// touch the process list, so they are reported whether or not that list answered,
// and a reader that treats an absent count as a failure rather than a retry does
// not lose a whole real-host run to one transient unreadable poll.
function stateReport(f) {
  const src = f || {};
  const verdict = src.verdict || {};
  const out = {
    state: verdict.state,
    why: verdict.why,
    procs: Array.isArray(src.procs) ? src.procs : [],
    prompt: src.prompt,
    promptMark: src.promptMark,
    promptMarks: src.promptMarks,
  };
  if (typeof src.screen === 'string') out.screen = src.screen;
  return out;
}

module.exports = {
  FM_MARK_TAG: FM_MARK_TAG,
  stateReport: stateReport,
  SCREEN_TAIL_ROWS: SCREEN_TAIL_ROWS,
  classifyScreenRows: classifyScreenRows,
  PROMPT_RUNNING: PROMPT_RUNNING,
  PROMPT_AT_PROMPT: PROMPT_AT_PROMPT,
  PROMPT_UNKNOWN: PROMPT_UNKNOWN,
  createPromptTracker: createPromptTracker,
  decideAgentState: decideAgentState,
};
