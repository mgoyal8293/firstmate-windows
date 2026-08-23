#!/usr/bin/env node
'use strict';
// fmpty-daemon.js - the ConPTY session daemon: firstmate's tmux-server analogue
// on Windows.
//
// WHY A DAEMON AT ALL. `CreatePseudoConsole` hands back an HPCON plus pipe
// handles owned by the CALLING process, and the pseudoconsole is destroyed when
// that process exits, taking the child with it. Any design where firstmate
// itself holds the ConPTY therefore cannot survive a firstmate restart, which
// is the one thing a session provider exists to do. So one long-lived daemon
// per task owns the ConPTY, and every client - including a firstmate that
// restarted, or a PowerShell script, or the shell adapter - reaches it over a
// Windows named pipe. A named pipe is a MACHINE-SCOPED kernel object rather
// than a process-local handle, which is what makes reattach structural instead
// of a trick.
//
//   fm-spawn (exits immediately)        firstmate, restarted N times
//         | launches detached                 | each call = a fresh process
//         v                                   v
//   +-----------------------------+  \\.\pipe\fmpty-<id>  +--------------+
//   | session daemon (1 per task) |<----- named pipe -----| any client   |
//   |  * owns the ConPTY (HPCON)  |                       +--------------+
//   |  * headless xterm.js screen |
//   |  * byte transcript on disk  |
//   +--------------+--------------+
//                  | ConPTY
//                  v
//             claude.exe
//
// Usage:
//   node fmpty-daemon.js --id <session-id> --cmd <exe> [--arg a]... [--cwd d]
//                        [--cols N] [--rows N] [--scrollback N] [--state DIR]
//                        [--epoch N] [--transcript-max BYTES]
//
// The client (fmpty.js) is the only thing that normally launches this; it is
// documented here because a daemon that cannot be started by hand cannot be
// debugged by hand.

const fs = require('fs');
const net = require('net');
const path = require('path');
const lib = require('./fmpty-lib.js');
const liveness = require('./fmpty-liveness.js');

// ---------------------------------------------------------------------------
// Dependency resolution
// ---------------------------------------------------------------------------
//
// node-pty carries a prebuilt native binary and its own versioned ConPTY
// (conpty.dll + OpenConsole.exe) rather than depending on whatever the OS ships
// inbox, which is why it needs no compiler and why its behaviour does not drift
// with Windows updates. It is resolved from this directory's own node_modules
// so the daemon does not depend on where it was launched from.
let pty, Terminal, SerializeAddon;
try {
  pty = require('node-pty');
  Terminal = require('@xterm/headless').Terminal;
  SerializeAddon = require('@xterm/addon-serialize').SerializeAddon;
} catch (e) {
  process.stderr.write(
    'fmpty-daemon: missing runtime dependencies (' + (e && e.message) + ').\n' +
    'Run `npm install --omit=dev` in ' + __dirname + '\n');
  process.exit(3);
}

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------
const argv = process.argv.slice(2);
const opt = {
  cols: 120, rows: 40, scrollback: 5000, args: [],
  epoch: 1, transcriptMax: 64 * 1024 * 1024,
};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--id') opt.id = argv[++i];
  else if (a === '--cwd') opt.cwd = argv[++i];
  else if (a === '--cmd') opt.cmd = argv[++i];
  else if (a === '--arg') opt.args.push(argv[++i]);
  else if (a === '--cols') opt.cols = parseInt(argv[++i], 10);
  else if (a === '--rows') opt.rows = parseInt(argv[++i], 10);
  else if (a === '--scrollback') opt.scrollback = parseInt(argv[++i], 10);
  else if (a === '--state') opt.state = argv[++i];
  else if (a === '--epoch') opt.epoch = parseInt(argv[++i], 10) || 1;
  else if (a === '--transcript-max') opt.transcriptMax = parseInt(argv[++i], 10);
  else if (a === '--harness') opt.harness = argv[++i];
  else { process.stderr.write('fmpty-daemon: unknown argument ' + a + '\n'); process.exit(2); }
}
if (!opt.id || !opt.cmd) {
  process.stderr.write('usage: fmpty-daemon.js --id <id> --cmd <exe> [--cwd d] [--arg a]...\n');
  process.exit(2);
}
for (const k of ['cols', 'rows', 'scrollback', 'transcriptMax']) {
  if (!Number.isInteger(opt[k]) || opt[k] <= 0) {
    process.stderr.write('fmpty-daemon: --' + k + ' must be a positive integer\n');
    process.exit(2);
  }
}
try { lib.validateSessionId(opt.id); } catch (e) {
  process.stderr.write('fmpty-daemon: ' + e.message + '\n');
  process.exit(2);
}

const PATHS = lib.sessionPaths(opt.id, opt.state);
const PIPE = lib.pipePath(opt.id);
const NONCE = lib.newNonce();
const STARTED = new Date().toISOString();
lib.ensureDir(PATHS.dir);

// ---------------------------------------------------------------------------
// Logging - bounded, never fatal
// ---------------------------------------------------------------------------
let logFd = null;
try { logFd = fs.openSync(PATHS.log, 'a'); } catch (_) { logFd = null; }
function log() {
  if (logFd === null) return;
  try {
    fs.writeSync(logFd, '[' + new Date().toISOString() + '] ' +
      Array.prototype.join.call(arguments, ' ') + '\n');
  } catch (_) { /* a log write must never take the session down */ }
}

// CRASH RESISTANCE. The spike's daemon exited on any uncaught exception, which
// turns a recoverable bug in a rarely-taken branch into total session loss -
// and unlike `tmux kill-server` there is no decade of production hardening
// behind this code. A daemon that stays up with one broken operation is
// strictly better than one that takes a live agent down with it, so the
// default is to log and keep serving. `beginShutdown` is the ONLY intentional
// exit path.
process.on('uncaughtException', (e) => {
  log('UNCAUGHT', (e && e.stack) || String(e));
  try { writeRecord(); } catch (_) {}
});
process.on('unhandledRejection', (e) => {
  log('UNHANDLED_REJECTION', (e && e.stack) || String(e));
});

// ---------------------------------------------------------------------------
// Durable session record
// ---------------------------------------------------------------------------
//
// This is the crash-recovery artifact's index. `shutdown` starts as `running`
// and only ever becomes `clean` on the intentional path, so a record still
// reading `running` with no live pipe is positive evidence that the daemon
// died without being asked to - which the client reports as `crashed` rather
// than silently as `absent`.
let exited = null;              // {exitCode, signal, at} once the pty child ends
let shutdownState = 'running';
let bytesIn = 0;
let lastDataAt = 0;
let transcriptBytes = 0;

function record() {
  return {
    schema: 1,
    id: opt.id,
    epoch: opt.epoch,
    nonce: NONCE,
    pipe: PIPE,
    daemon: {
      pid: process.pid,
      name: 'node.exe',
      startTicks: SELF_START_TICKS,
    },
    child: childIdentity,
    spec: {
      cmd: opt.cmd,
      args: opt.args,
      cwd: opt.cwd || process.cwd(),
      cols: opt.cols,
      rows: opt.rows,
      scrollback: opt.scrollback,
      harness: opt.harness || '',
      state: opt.state || '',
    },
    transcript: PATHS.transcript,
    log: PATHS.log,
    startedAt: STARTED,
    shutdown: shutdownState,
    exited: exited,
    updatedAt: new Date().toISOString(),
  };
}
function writeRecord() {
  try { lib.writeRecord(opt.id, record(), opt.state); } catch (e) { log('record write failed', String(e)); }
}

// The daemon's own creation time, so a later reader can tell this process from
// a stranger that inherited its pid. Resolved once, asynchronously, so startup
// is never blocked on a ~600 ms PowerShell sweep.
let SELF_START_TICKS = '0';
lib.snapshotIdentities((err, map) => {
  if (!err && map && map[process.pid]) SELF_START_TICKS = map[process.pid].startTicks;
  identityMap = (!err && map) ? map : identityMap;
  identityMapAt = Date.now();
  writeRecord();
});

// ---------------------------------------------------------------------------
// Transcript - the crash-recovery artifact
// ---------------------------------------------------------------------------
//
// Every pty byte is appended verbatim. This is what makes a daemon crash
// survivable in the only sense it CAN be: the ConPTY dies with its creator, so
// the agent cannot be resurrected, but everything it printed is still on disk
// and firstmate's recovery can read what happened.
//
// Bounded: an overnight session must not fill the disk. At the cap the file is
// rotated to `.1` (one generation kept) so the recent past always survives
// while total usage stays bounded at roughly 2x the cap.
let transcriptFd = null;
function openTranscript() {
  try {
    transcriptFd = fs.openSync(PATHS.transcript, 'a');
    transcriptBytes = fs.fstatSync(transcriptFd).size;
  } catch (e) { log('transcript open failed', String(e)); transcriptFd = null; }
}
function rotateTranscript() {
  try {
    if (transcriptFd !== null) { fs.closeSync(transcriptFd); transcriptFd = null; }
    fs.renameSync(PATHS.transcript, PATHS.transcript + '.1');
  } catch (e) { log('transcript rotate failed', String(e)); }
  transcriptBytes = 0;
  openTranscript();
}
function appendTranscript(buf) {
  if (transcriptFd === null) return;
  try {
    fs.writeSync(transcriptFd, buf);
    transcriptBytes += buf.length;
    if (transcriptBytes >= opt.transcriptMax) rotateTranscript();
  } catch (e) { log('transcript write failed', String(e)); }
}
openTranscript();

// ---------------------------------------------------------------------------
// ConPTY
// ---------------------------------------------------------------------------
const ptyProc = pty.spawn(opt.cmd, opt.args, {
  name: 'xterm-256color',
  cols: opt.cols,
  rows: opt.rows,
  cwd: opt.cwd || process.cwd(),
  env: Object.assign({}, process.env, { TERM: 'xterm-256color' }),
  useConpty: true,
});
log('daemon start pid=' + process.pid, 'ppid=' + process.ppid, 'epoch=' + opt.epoch,
  'pipe=' + PIPE, 'child=' + ptyProc.pid, 'cmd=' + opt.cmd);

// The pty child's identity. node-pty holds an open handle to this process for
// its own exit wait, and Windows will not recycle a pid while any handle to the
// process object remains open - so for as long as this daemon lives, this pid
// cannot become a stranger. The name and start ticks are recorded anyway,
// because the RECORD outlives the daemon and a later reader has no such
// guarantee.
let childIdentity = { pid: ptyProc.pid, name: '', startTicks: '0' };
lib.snapshotIdentities((err, map) => {
  if (!err && map && map[ptyProc.pid]) {
    childIdentity = Object.assign({ pid: ptyProc.pid }, map[ptyProc.pid]);
    writeRecord();
  }
});

// ---------------------------------------------------------------------------
// Headless screen
// ---------------------------------------------------------------------------
//
// ConPTY emits a byte stream, not a screen; `capture-pane` needs a screen. A
// headless xterm.js gives a real buffer with scrollback AND a true cursor row,
// which is the primitive firstmate's composer classifier wants and which no
// backend other than tmux has been able to supply.
const term = new Terminal({
  cols: opt.cols, rows: opt.rows, scrollback: opt.scrollback,
  allowProposedApi: true, convertEol: false,
});
const serializer = new SerializeAddon();
term.loadAddon(serializer);

// `#{pane_current_path}` has no direct Windows analogue: there is no
// /proc/<pid>/cwd, and reading another process's PEB needs native code. The
// shell already announces its cwd in the OSC 0/2 title, so that is tracked
// passively here for free. It goes deliberately STICKY once a harness takes the
// title over, which is why fm-spawn must poll cwd BEFORE launching the harness;
// the adapter's active pwd probe is the fallback for every other case.
let paneTitle = '';
let paneCwd = '';
let paneCwdAt = 0;
term.onTitleChange((t) => {
  paneTitle = t;
  const m = /^(?:MINGW64|MINGW32|MSYS|CYGWIN):(.*)$/.exec(t);
  if (m) { paneCwd = m[1]; paneCwdAt = Date.now(); }
  else if (/^[A-Za-z]:[\\/]/.test(t)) { paneCwd = t; paneCwdAt = Date.now(); }
});

// The session shell's own answer to "am I at a prompt?", tracked as the bytes
// arrive. This is the foreground source a ConPTY console cannot otherwise
// supply; fmpty-liveness.js owns what the marks mean and
// bin/backends/conpty/fm-shell-integration.bash owns emitting them.
const promptTracker = liveness.createPromptTracker();

ptyProc.onData((d) => {
  const buf = Buffer.from(d, 'utf8');
  bytesIn += buf.length;
  lastDataAt = Date.now();
  appendTranscript(buf);
  promptTracker.feed(d);
  term.write(d);
});
ptyProc.onExit(({ exitCode, signal }) => {
  exited = { exitCode: exitCode, signal: signal, at: new Date().toISOString() };
  log('pty exited code=' + exitCode + ' signal=' + signal);
  procCache.at = 0;               // force a fresh liveness read, do not serve stale `alive`
  writeRecord();
});

// ---------------------------------------------------------------------------
// Screen readers
// ---------------------------------------------------------------------------
function rowText(y) {
  const l = term.buffer.active.getLine(y);
  return l ? l.translateToString(true) : '';
}
function rowsToString(start, end) {
  const out = [];
  for (let y = start; y < end; y++) out.push(rowText(y));
  while (out.length && out[out.length - 1] === '') out.pop();
  return out.join('\n');
}

// capturePlain: `tmux capture-pane -p -S -<lines>` semantics - <lines> rows of
// SCROLLBACK above the viewport top, PLUS the whole viewport. Deliberately not
// "the last N rows": firstmate's callers pass a scrollback depth, and reading
// it as a row count silently truncates the screen they asked to see.
function capturePlain(lines) {
  const buf = term.buffer.active;
  const top = buf.baseY;
  const start = Math.max(0, top - (lines > 0 ? lines : 0));
  return rowsToString(start, top + term.rows);
}

// captureTail: the last <lines> rows ending at the viewport bottom - what
// fm-watch.sh actually consumes when it pipes a capture through `tail -N`.
function captureTail(lines) {
  const buf = term.buffer.active;
  const end = buf.baseY + term.rows;
  return rowsToString(Math.max(0, end - (lines > 0 ? lines : term.rows)), end);
}

// ---------------------------------------------------------------------------
// Row-exact styled capture (the composer classifier's input)
// ---------------------------------------------------------------------------
//
// The shared classifier (bin/fm-composer-lib.sh) is given a styled screen AND a
// zero-based cursor row, and it indexes the screen BY that row. So the styled
// capture must be exactly one output line per buffer row, with no joining and
// no trailing-blank trimming - otherwise the cursor points at the wrong shape
// and the verdict silently describes some other part of the screen.
//
// That rules out the serialize addon for this particular read: it deliberately
// joins wrapped rows into one logical line to preserve reflow, which is right
// for a human-facing dump and wrong for a row-indexed one. So the styled screen
// is rendered here, cell by cell, emitting only the SGR states the ghost-text
// stripper actually reads: dim/faint, foreground colour (palette and truecolor),
// and reset.
function sgrForCell(cell, state) {
  const out = [];
  const bold = cell.isBold() ? 1 : 0;
  const dim = cell.isDim() ? 1 : 0;
  const italic = cell.isItalic() ? 1 : 0;
  const underline = cell.isUnderline() ? 1 : 0;
  const inverse = cell.isInverse() ? 1 : 0;
  const invisible = cell.isInvisible() ? 1 : 0;
  const strike = cell.isStrikethrough() ? 1 : 0;

  let fg;
  if (cell.isFgDefault()) fg = 'd';
  else if (cell.isFgRGB()) fg = 'r' + cell.getFgColor();
  else fg = 'p' + cell.getFgColor();
  let bg;
  if (cell.isBgDefault()) bg = 'd';
  else if (cell.isBgRGB()) bg = 'r' + cell.getBgColor();
  else bg = 'p' + cell.getBgColor();

  // Any attribute turning OFF forces a reset, then a re-assert of what stays
  // on. Emitting the individual "off" codes instead would be shorter but has
  // more ways to be wrong, and this output is machine-read, not shipped.
  const turnedOff =
    (state.bold && !bold) || (state.dim && !dim) || (state.italic && !italic) ||
    (state.underline && !underline) || (state.inverse && !inverse) ||
    (state.invisible && !invisible) || (state.strike && !strike) ||
    (state.fg !== 'd' && fg === 'd') || (state.bg !== 'd' && bg === 'd');

  if (turnedOff) {
    out.push('0');
    state.bold = state.dim = state.italic = state.underline = 0;
    state.inverse = state.invisible = state.strike = 0;
    state.fg = 'd'; state.bg = 'd';
  }
  if (bold && !state.bold) { out.push('1'); state.bold = 1; }
  if (dim && !state.dim) { out.push('2'); state.dim = 1; }
  if (italic && !state.italic) { out.push('3'); state.italic = 1; }
  if (underline && !state.underline) { out.push('4'); state.underline = 1; }
  if (inverse && !state.inverse) { out.push('7'); state.inverse = 1; }
  if (invisible && !state.invisible) { out.push('8'); state.invisible = 1; }
  if (strike && !state.strike) { out.push('9'); state.strike = 1; }
  if (fg !== state.fg) {
    if (fg === 'd') out.push('39');
    else if (fg[0] === 'r') {
      const v = cell.getFgColor();
      out.push('38;2;' + ((v >> 16) & 0xff) + ';' + ((v >> 8) & 0xff) + ';' + (v & 0xff));
    } else out.push('38;5;' + cell.getFgColor());
    state.fg = fg;
  }
  if (bg !== state.bg) {
    if (bg === 'd') out.push('49');
    else if (bg[0] === 'r') {
      const v = cell.getBgColor();
      out.push('48;2;' + ((v >> 16) & 0xff) + ';' + ((v >> 8) & 0xff) + ';' + (v & 0xff));
    } else out.push('48;5;' + cell.getBgColor());
    state.bg = bg;
  }
  return out.length ? '\x1b[' + out.join(';') + 'm' : '';
}

function captureStyledViewport() {
  const buf = term.buffer.active;
  const cell = buf.getNullCell();
  const lines = [];
  for (let y = buf.baseY; y < buf.baseY + term.rows; y++) {
    const line = buf.getLine(y);
    if (!line) { lines.push(''); continue; }
    const state = { bold: 0, dim: 0, italic: 0, underline: 0, inverse: 0, invisible: 0, strike: 0, fg: 'd', bg: 'd' };
    let s = '';
    let trailing = '';
    for (let x = 0; x < line.length; x++) {
      line.getCell(x, cell);
      const w = cell.getWidth();
      if (w === 0) continue;              // second half of a wide glyph
      const chars = cell.getChars() || ' ';
      const sgr = sgrForCell(cell, state);
      // Trailing whitespace is buffered rather than emitted, so a row of
      // blank-but-styled cells does not read as content. It is flushed the
      // moment a real glyph follows it.
      if (chars.trim() === '' && !cell.isInverse()) {
        trailing += sgr + chars;
      } else {
        s += trailing + sgr + chars;
        trailing = '';
      }
    }
    if (state.bold || state.dim || state.italic || state.underline ||
        state.inverse || state.invisible || state.strike ||
        state.fg !== 'd' || state.bg !== 'd') s += '\x1b[0m';
    lines.push(s);
  }
  // Exactly term.rows lines, never trimmed: the cursor row indexes into this.
  return lines.join('\n');
}

function cursorInfo() {
  const b = term.buffer.active;
  return {
    x: b.cursorX, y: b.cursorY, baseY: b.baseY, viewportY: b.viewportY,
    rows: term.rows, cols: term.cols, length: b.length,
  };
}

// ---------------------------------------------------------------------------
// Liveness: the ConPTY console process list
// ---------------------------------------------------------------------------
//
// tmux scopes liveness to the pane tty's FOREGROUND process group, which is
// what lets it call a pane with a backgrounded harness `dead`. Windows has
// neither a tty nor a foreground process group. What a ConPTY console does have
// is a process list, and node-pty ships the native GetConsoleProcessList
// binding for it; that is the closest available analogue of `ps -t <pane_tty>`.
//
// Two consequences are handled here and a third is documented as a real gap:
//
//  1. The console list is LIVE by construction - a pid in it is attached to
//     this console right now - but the pid->name resolution that follows is a
//     separate call, and Windows can recycle a pid in between. Names are
//     therefore resolved together with start ticks, cached per pid, and evicted
//     the moment a pid leaves the list, so a recycled pid can never inherit the
//     previous occupant's cached name.
//  2. The probe is EXPENSIVE cold (a forked helper plus a process sweep). It is
//     kept warm on a bounded interval whenever anybody has asked recently, so a
//     watcher polling many sessions reads a warm cache instead of paying ~1 s
//     per session per poll.
//  3. The console list has no foreground concept, so on its own it classifies a
//     harness-named process left running in the BACKGROUND of an otherwise idle
//     session `alive` where tmux would say `dead`. That is why the list is not
//     the only source: the session shell's own OSC 133 prompt marks answer the
//     foreground question directly (fmpty-liveness.js), and the screen stays on
//     as the fallback for a session that emits no marks.
const { fork } = require('child_process');
const PTY_LIB = path.join(path.dirname(require.resolve('node-pty')), '');
const CONSOLE_AGENT = path.join(PTY_LIB, 'conpty_console_list_agent.js');

// The harness vocabulary. Kept deliberately in step with
// fm_backend_tmux_classify_process_name: `muse` is anchored rather than globbed
// because its installed binary is muse-bin-<version> and the bare substring
// `muse` is a common English fragment that would classify musescore as an agent.
const HARNESS_RE = /^(claude|codex|opencode|grok|kimi|pi|pi-signed|pi-launcher|muse|muse-bin-.*|cursor-agent)(\.exe)?$/i;
const SHELL_RE = /^(cmd|bash|sh|dash|zsh|fish|powershell|pwsh|busybox|login|conhost|openconsole)(\.exe)?$/i;

let identityMap = null;           // pid -> {name, startTicks}, batched sweep
let identityMapAt = 0;
const nameCache = new Map();      // pid -> {name, startTicks, validated}
let procCache = { at: 0, list: null, pending: false, source: '' };
const PROC_TTL_MS = 1500;
const IDENTITY_SWEEP_TTL_MS = 30000;

let lastStateReadAt = 0;
let warmTimer = null;

function classifyName(n) {
  const base = String(n || '').replace(/^.*[\\/]/, '');
  if (HARNESS_RE.test(base)) return 'agent';
  if (SHELL_RE.test(base)) return 'shell';
  return 'other';
}

// resolveNames: fill in names for <pids>, using the per-pid cache first and one
// batched sweep for whatever is left. The cache is keyed by pid AND validated
// by start ticks, so an entry is only reused for the same process instance.
function resolveNames(pids, cb) {
  const unknown = pids.filter((p) => !nameCache.has(p));
  const stale = Date.now() - identityMapAt > IDENTITY_SWEEP_TTL_MS;
  if (unknown.length === 0 && !stale) return cb(buildList(pids));

  lib.snapshotIdentities((err, map) => {
    if (!err && map) {
      identityMap = map;
      identityMapAt = Date.now();
      for (const p of pids) {
        const live = map[p];
        if (live) nameCache.set(p, { name: live.name, startTicks: live.startTicks, validated: live.startTicks !== '0' });
      }
      // Evict every pid that is no longer attached to this console, so a later
      // reuse of that pid cannot be answered from a stale entry.
      for (const key of Array.from(nameCache.keys())) {
        if (pids.indexOf(key) === -1) nameCache.delete(key);
      }
      return cb(buildList(pids), 'get-process');
    }
    // PowerShell unavailable: fall back to names only and mark them unvalidated,
    // so `identityValidated` reports false rather than overclaiming.
    lib.snapshotNames((err2, map2) => {
      if (!err2 && map2) {
        for (const p of pids) {
          const live = map2[String(p)];
          if (live) nameCache.set(p, { name: live.name, startTicks: '0', validated: false });
        }
      }
      cb(buildList(pids), err2 ? 'none' : 'tasklist');
    });
  });
}

function buildList(pids) {
  return pids.map((p) => {
    const c = nameCache.get(p);
    return {
      pid: p,
      name: c ? c.name : '',
      startTicks: c ? c.startTicks : '0',
      identityValidated: !!(c && c.validated),
    };
  });
}

// Waiters on the in-flight refresh. A caller that arrives while a sweep is
// already running must wait for THAT sweep's result rather than being handed
// the stale cache it was trying to escape; without this, two near-simultaneous
// liveness reads give different answers for no reason the caller can see.
let refreshWaiters = [];
function refreshProcList(done) {
  if (done) refreshWaiters.push(done);
  if (procCache.pending) return;
  procCache.pending = true;
  let settled = false;
  const finish = (list, source) => {
    if (settled) return;
    settled = true;
    procCache = { at: Date.now(), list: list, pending: false, source: source || '' };
    const waiters = refreshWaiters;
    refreshWaiters = [];
    for (const w of waiters) { try { w(); } catch (e) { log('refresh waiter failed', String(e)); } }
  };
  let agent;
  try {
    // AttachConsole mutates the CALLER's own console, so the console process
    // list must be read in a throwaway helper - node-pty ships exactly that
    // helper, and reusing it avoids a second copy of the same native call.
    //
    // windowsHide is not cosmetic here. The daemon is launched detached and
    // therefore owns no console of its own, so a console child spawned without
    // CREATE_NO_WINDOW gets a BRAND NEW console allocated - a real window that
    // appears on the interactive desktop. This helper runs on the warm loop
    // every 1.2 s for as long as anything is polling liveness, so without this
    // flag a supervised Windows session flashes a console window at the user
    // about once a second. Every other child this backend spawns already sets
    // it (fmpty.js's daemon launch, fmpty-lib.js's two identity sweeps).
    agent = fork(CONSOLE_AGENT, [String(ptyProc.pid)], { stdio: 'ignore', windowsHide: true });
  } catch (e) {
    log('console agent fork failed', String(e));
    return finish(null, 'fork-failed');
  }
  const to = setTimeout(() => { try { agent.kill(); } catch (_) {} finish(null, 'timeout'); }, 6000);
  // `gotMessage` and not `settled`: the helper reports its pid list and THEN
  // exits, while name resolution after that message is asynchronous. Treating
  // the exit itself as failure would race that resolution and discard a list
  // the daemon had already received - which is exactly how liveness first came
  // back `unreadable` on a perfectly healthy session.
  let gotMessage = false;
  agent.on('error', () => { clearTimeout(to); finish(null, 'agent-error'); });
  agent.on('exit', () => { if (!gotMessage) { clearTimeout(to); finish(null, 'agent-exit'); } });
  agent.on('message', (m) => {
    gotMessage = true;
    clearTimeout(to);
    const pids = ((m && m.consoleProcessList) || []).filter((p) => Number.isInteger(p));
    // Never execFileSync here: a synchronous sweep on the daemon's own event
    // loop stalls every pipe client, including a kill request, which is exactly
    // the bug that made the spike's first clean-termination attempt look like a
    // timeout on an operation that had actually succeeded.
    // A second bound on top of the sweeps' own timeouts: if name resolution
    // somehow never calls back, the refresh must still settle, or `pending`
    // stays true and every later liveness read waits on a sweep that will
    // never finish.
    const nameTo = setTimeout(() => finish(null, 'name-timeout'), 20000);
    if (nameTo.unref) nameTo.unref();
    resolveNames(pids, (list, source) => { clearTimeout(nameTo); finish(list, source); });
  });
}

// Pre-warm. Refreshing unconditionally forever would burn a forked process
// every second for the life of an idle overnight session; refreshing only on
// demand makes the first read after a quiet stretch pay the full cold cost
// (the spike saw cache ages reach 19 s). So the warm loop runs only while a
// client has asked within the last WARM_WINDOW_MS, and stops on its own after.
const WARM_INTERVAL_MS = 1200;
const WARM_WINDOW_MS = 90000;
function ensureWarmLoop() {
  if (warmTimer) return;
  warmTimer = setInterval(() => {
    if (Date.now() - lastStateReadAt > WARM_WINDOW_MS || exited) {
      clearInterval(warmTimer); warmTimer = null; return;
    }
    refreshProcList();
  }, WARM_INTERVAL_MS);
  if (warmTimer.unref) warmTimer.unref();
}

// screenSuggestsAgent: the FALLBACK second source for liveness, used only when
// the session has emitted no prompt mark at all - an older bash without PS0, a
// non-bash session shell, a nested shell whose own rc files overwrite the
// carriers. This side only reads the viewport; what the rows MEAN, and the two
// reproduced defects that reading used to have, are owned by
// fmpty-liveness.js's classifyScreenRows so they are testable off Windows.
function screenSuggestsAgent() {
  try {
    const buf = term.buffer.active;
    const bottom = buf.baseY + term.rows - 1;
    const rows = [];
    for (let y = Math.max(0, bottom - (term.rows - 1)); y <= bottom; y++) rows.push(rowText(y));
    return liveness.classifyScreenRows(rows, liveness.SCREEN_TAIL_ROWS);
  } catch (_) {
    return 'unknown';
  }
}

// agentState: the fm_backend_agent_state vocabulary. This function gathers the
// evidence - is the endpoint there at all, does its process set contain a
// verified harness, is the session shell at a prompt, and (only when no prompt
// mark has ever arrived) what the screen looks like - and fmpty-liveness.js's
// decideAgentState owns the verdict, so the whole table is readable in one place
// and testable on any platform.
//
// `dead` and `missing` are the only verdicts that license recovery, so every
// uncertain path resolves to `ambiguous` or `unreadable` instead. A false
// `dead` is the one outcome that can launch a duplicate agent onto a live
// worktree.
// agentStateAsync: refresh FIRST when the cached list is older than the caller's
// freshness bound, and only then decide. The spike answered from whatever was
// cached and kicked off a refresh for next time, which let a read served after
// a quiet stretch describe the session as it was minutes ago (cache ages of
// 19 s were observed there, and 230 s here) - so a session whose agent had
// already died could still be reported `alive`. Liveness is the input to
// recovery decisions; answering it from stale data defeats the probe.
function agentStateAsync(maxAgeMs, cb) {
  lastStateReadAt = Date.now();
  ensureWarmLoop();
  const bound = Number.isInteger(maxAgeMs) && maxAgeMs >= 0 ? maxAgeMs : PROC_TTL_MS;
  const age = procCache.at ? Date.now() - procCache.at : Infinity;
  if (exited || age <= bound) return cb(agentState());
  refreshProcList(() => cb(agentState()));
}

function agentState() {
  if (exited) {
    return { state: 'missing', why: 'pty child exited', exited: exited, procs: [] };
  }
  const list = procCache.list;
  const prompt = promptTracker.state();
  if (!list) {
    return liveness.stateReport({
      verdict: liveness.decideAgentState({ listAvailable: false, listSource: procCache.source }),
      prompt: prompt,
      promptMark: promptTracker.lastMark(),
      promptMarks: promptTracker.marks(),
    });
  }
  let sawShell = false, sawOther = false, agentProc = null;
  for (const p of list) {
    const c = classifyName(p.name);
    if (c === 'agent' && !agentProc) agentProc = p;
    else if (c === 'shell') sawShell = true;
    else if (p.name) sawOther = true;
  }
  // The screen is only ever the fallback now, so it is not read at all while the
  // shell is answering the foreground question itself.
  const screen = prompt === liveness.PROMPT_UNKNOWN ? screenSuggestsAgent() : 'unread';
  const verdict = liveness.decideAgentState({
    listAvailable: true,
    listSource: procCache.source,
    agentName: agentProc ? agentProc.name : '',
    sawShell: sawShell,
    sawOther: sawOther,
    prompt: prompt,
    screen: screen,
  });
  const out = liveness.stateReport({
    verdict: verdict, procs: list, screen: screen,
    prompt: prompt, promptMark: promptTracker.lastMark(), promptMarks: promptTracker.marks(),
  });
  if (agentProc) out.identityValidated = agentProc.identityValidated;
  return out;
}

// ---------------------------------------------------------------------------
// Key vocabulary
// ---------------------------------------------------------------------------
const KEYS = {
  Enter: '\r', Escape: '\x1b', Tab: '\t', BSpace: '\x7f', Space: ' ',
  Up: '\x1b[A', Down: '\x1b[B', Right: '\x1b[C', Left: '\x1b[D',
  Home: '\x1b[H', End: '\x1b[F', PageUp: '\x1b[5~', PageDown: '\x1b[6~',
};
function keyToBytes(k) {
  if (Object.prototype.hasOwnProperty.call(KEYS, k)) return KEYS[k];
  let m = /^C-([a-z])$/.exec(k);
  if (m) return String.fromCharCode(m[1].charCodeAt(0) - 96);
  m = /^M-(.)$/.exec(k);
  if (m) return '\x1b' + m[1];
  return null;
}

// ---------------------------------------------------------------------------
// Control protocol
// ---------------------------------------------------------------------------
//
// Newline-delimited JSON over the named pipe. Deliberately language-agnostic:
// the spike proved a PowerShell 5.1 client can drive a live agent over this
// with no node involved, which matters because firstmate's backends are shell
// scripts, not node programs.
const MAX_LINE_BYTES = 4 * 1024 * 1024;

// ASYNC marks an operation whose answer is not available this tick. `handle`
// returns it instead of a response, having taken ownership of `respond`. Only
// liveness needs this today, and it needs it for a real reason: answering from
// a stale cache is worse than making the caller wait ~1 s for the truth.
const ASYNC = Symbol('async');

function handle(req, respond) {
  switch (req.op) {
    case 'ping':
      // The identity oracle. Pids are recycled; this nonce is not. A client
      // that recorded nonce N and is answered with nonce M knows for certain
      // that it is talking to a DIFFERENT daemon generation, without consulting
      // a single pid.
      return { ok: true, pong: true, id: opt.id, nonce: NONCE, epoch: opt.epoch, daemonPid: process.pid };
    case 'info':
      return {
        ok: true, id: opt.id, nonce: NONCE, epoch: opt.epoch,
        daemonPid: process.pid, child: childIdentity,
        cmd: opt.cmd, args: opt.args, cwd: opt.cwd, startedAt: STARTED,
        exited: exited, bytesIn: bytesIn,
        lastDataAgeMs: lastDataAt ? Date.now() - lastDataAt : null,
        // The session shell's prompt marker, reported so a host can tell "the
        // shell says it is at a prompt" from "this session emits no marks and
        // liveness is on its fallback reading".
        prompt: promptTracker.state(), promptMarks: promptTracker.marks(),
        cols: term.cols, rows: term.rows,
        transcript: PATHS.transcript, transcriptBytes: transcriptBytes,
        scrollback: opt.scrollback, bufferLength: term.buffer.active.length,
        // `alternate` means the harness has taken the alt screen (claude does,
        // via ?1049h). The alt screen has NO scrollback by construction - in
        // xterm.js exactly as in a real terminal - so while it is active a
        // capture can only ever see the visible screen, and the durable
        // transcript is the only route to deeper history. tmux behaves the same
        // way on an alt-screen pane, so this is a property of the harness, not
        // a shortfall of this backend; it is reported rather than hidden so a
        // caller can tell "no scrollback exists" from "the read failed".
        bufferType: term.buffer.active.type,
        record: PATHS.record,
      };
    case 'capture':       return { ok: true, text: capturePlain(intOf(req.lines, 0)) };
    case 'tail':          return { ok: true, text: captureTail(intOf(req.lines, term.rows)) };
    case 'capture-ansi':  return { ok: true, text: serializer.serialize({ scrollback: intOf(req.lines, 0) }) };
    case 'composer':      return { ok: true, text: captureStyledViewport(), cursor: cursorInfo() };
    case 'cursor':        return { ok: true, cursor: cursorInfo() };
    case 'current-path':  return { ok: true, path: paneCwd, title: paneTitle, ageMs: paneCwdAt ? Date.now() - paneCwdAt : null };
    case 'agent-state':
      agentStateAsync(intOf(req.maxAgeMs, PROC_TTL_MS), (a) => {
        respond(Object.assign({
          ok: true,
          cacheAgeMs: procCache.at ? Date.now() - procCache.at : null,
          cacheSource: procCache.source,
        }, a));
      });
      return ASYNC;
    case 'busy':
      // The byte counter is a primitive tmux simply does not have: the daemon
      // sits on the pty stream, so output activity is measured continuously and
      // for free, instead of being inferred by hashing pane content across polls.
      return {
        ok: true, bytesIn: bytesIn,
        lastDataAgeMs: lastDataAt ? Date.now() - lastDataAt : null,
        exited: exited,
      };
    case 'send-text': {
      if (exited) return { ok: false, error: 'pty exited' };
      const t = String(req.text == null ? '' : req.text);
      ptyProc.write(t);
      return { ok: true, wrote: Buffer.byteLength(t, 'utf8') };
    }
    case 'send-key': {
      if (exited) return { ok: false, error: 'pty exited' };
      const b = keyToBytes(String(req.key || ''));
      if (b === null) return { ok: false, error: 'unknown key ' + req.key };
      ptyProc.write(b);
      return { ok: true, key: req.key };
    }
    case 'resize': {
      const c = intOf(req.cols, 0), r = intOf(req.rows, 0);
      if (c <= 0 || r <= 0) return { ok: false, error: 'resize needs positive cols and rows' };
      // Resize the SCREEN first and the pty second. The other order lets the
      // child redraw at the new size into a buffer still holding the old one,
      // which shows up as a torn capture for as long as the child takes to
      // repaint - and a torn capture is what the composer classifier reads.
      try { term.resize(c, r); } catch (e) { return { ok: false, error: 'screen resize failed: ' + e.message }; }
      try { ptyProc.resize(c, r); } catch (e) { return { ok: false, error: 'pty resize failed: ' + e.message }; }
      opt.cols = c; opt.rows = r;
      writeRecord();
      return { ok: true, cols: c, rows: r };
    }
    case 'verify-child': {
      // Synchronous answer is impossible (identity needs a process sweep), so
      // this reports what the daemon already knows and the client asks the OS
      // itself for anything stronger. Kept so a client can distinguish "the
      // daemon believes its child is X" from its own independent check.
      return { ok: true, child: childIdentity, exited: exited };
    }
    case 'kill':
      return { ok: true, killing: true, daemonPid: process.pid, childPid: ptyProc.pid };
    default:
      return { ok: false, error: 'unknown op ' + req.op };
  }
}

function intOf(v, dflt) {
  const n = parseInt(v, 10);
  return Number.isInteger(n) && n >= 0 ? n : dflt;
}

const server = net.createServer((sock) => {
  let acc = '';
  sock.on('error', () => { /* a client that hangs up mid-write is routine */ });
  sock.on('data', (chunk) => {
    acc += chunk.toString('utf8');
    if (acc.length > MAX_LINE_BYTES) {
      // A client streaming an unbounded line would otherwise grow this buffer
      // until the daemon dies of memory pressure, taking a live agent with it.
      acc = '';
      try { sock.write(JSON.stringify({ ok: false, error: 'request too large' }) + '\n'); } catch (_) {}
      sock.destroy();
      return;
    }
    let nl;
    while ((nl = acc.indexOf('\n')) >= 0) {
      const line = acc.slice(0, nl);
      acc = acc.slice(nl + 1);
      if (!line.trim()) continue;
      let req, res;
      try { req = JSON.parse(line); } catch (_) {
        try { sock.write(JSON.stringify({ ok: false, error: 'bad json' }) + '\n'); } catch (_) {}
        continue;
      }
      let answered = false;
      const respond = (r) => {
        if (answered) return;
        answered = true;
        try { sock.write(JSON.stringify(r) + '\n'); } catch (_) {}
      };
      // One broken operation must not take the session down; every handler
      // failure becomes an error response, not an exit.
      try { res = handle(req, respond); } catch (e) {
        log('op failed', req && req.op, (e && e.stack) || String(e));
        res = { ok: false, error: String((e && e.message) || e) };
      }
      if (res !== ASYNC) respond(res);
      if (req.op === 'kill') {
        // Answer, flush, and only then leave. Exiting on a timer instead races
        // the flush and makes a kill that actually succeeded look to the client
        // like a timeout.
        try { sock.end(() => beginShutdown()); } catch (_) { beginShutdown(); }
        setTimeout(beginShutdown, 1000).unref();
      }
    }
  });
});

// ---------------------------------------------------------------------------
// Shutdown
// ---------------------------------------------------------------------------
//
// node-pty's Windows kill iterates the CONSOLE process set rather than the
// process tree, which is the correct set and not merely a convenient one: the
// spike proved `claude.exe` is attached to the pty console while NOT being a
// descendant of the daemon (its parent chain ran through an sh.exe that had
// already exited), so a parent-tree kill would have orphaned the live agent.
let shuttingDown = false;
function beginShutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  shutdownState = 'clean';
  log('shutdown requested');
  try { ptyProc.kill(); } catch (e) { log('pty kill failed', String(e)); }
  const done = () => {
    log('shutdown: exiting');
    writeRecord();
    try { server.close(); } catch (_) {}
    try { if (transcriptFd !== null) fs.closeSync(transcriptFd); } catch (_) {}
    process.exit(0);
  };
  if (exited) return setTimeout(done, 50).unref();
  const iv = setInterval(() => { if (exited) { clearInterval(iv); done(); } }, 100);
  setTimeout(() => { clearInterval(iv); log('shutdown: pty exit not observed, forcing'); done(); }, 5000).unref();
}

// A daemon asked to stop by the OS still records that it stopped intentionally,
// so recovery does not report a clean stop as a crash.
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  try { process.on(sig, () => { log('signal ' + sig); beginShutdown(); }); } catch (_) {}
}

server.on('error', (e) => {
  // EADDRINUSE is the pipe doing its job as a mutex: another daemon already
  // owns this session id. Exiting is correct - two daemons on one pipe would
  // give clients a coin flip about which agent they are driving.
  log('server error ' + e.message);
  process.stderr.write('fmpty-daemon: ' + e.message + '\n');
  try { ptyProc.kill(); } catch (_) {}
  process.exit(e && e.code === 'EADDRINUSE' ? 4 : 1);
});

server.listen(PIPE, () => {
  log('listening on ' + PIPE);
  writeRecord();
  refreshProcList();
});
