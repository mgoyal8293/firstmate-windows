#!/usr/bin/env node
'use strict';
// fmpty.js - the ConPTY session CLIENT: firstmate's `tmux` binary analogue.
//
// A FRESH, unrelated process on every invocation. It holds no state and knows
// nothing but the session id; everything it can see, it sees through the
// daemon's named pipe. That is deliberate and it is the whole point: because the
// client keeps no handle on the session, a firstmate that restarted - or a
// PowerShell script, or the shell adapter - reattaches with exactly the same
// authority as the process that spawned the session.
//
//   node fmpty.js spawn    --id <id> --cmd <exe> [--arg a]... [--cwd d]
//                          [--cols N] [--rows N] [--state DIR] [--harness NAME]
//   node fmpty.js capture   --id <id> [--lines N]   (tmux capture-pane -p -S -N)
//   node fmpty.js tail      --id <id> --lines N     (last N viewport rows)
//   node fmpty.js ansi      --id <id>               (capture-pane -e -p)
//   node fmpty.js composer  --id <id>               (row-exact styled screen + cursor)
//   node fmpty.js cursor    --id <id>               (#{cursor_y})
//   node fmpty.js cwd       --id <id>               (#{pane_current_path})
//   node fmpty.js state     --id <id>               (fm_backend_agent_state)
//   node fmpty.js busy      --id <id>               (bytesIn / lastDataAgeMs)
//   node fmpty.js send      --id <id> --text "..."  (literal, no submit)
//   node fmpty.js key       --id <id> --key Enter
//   node fmpty.js resize    --id <id> --cols N --rows N
//   node fmpty.js info      --id <id>
//   node fmpty.js exists    --id <id>               (exit 0 = pipe answers)
//   node fmpty.js health    --id <id>               (live | crashed | clean | absent)
//   node fmpty.js verify    --id <id>               (recorded-pid identity check)
//   node fmpty.js restart   --id <id>               (relaunch a CRASHED session)
//   node fmpty.js kill      --id <id>
//   node fmpty.js doctor                            (dependency preflight; no --id)
//
// `--plain` projects the answer to the ONE scalar the shell adapter needs,
// which is why bin/backends/conpty.sh requires no JSON parser: adding a jq
// dependency to a Windows host to read a field this program already knows would
// be a setup burden bought for nothing.
//
// Exit codes: 0 success, 1 operation failed or session absent, 2 usage error.

const fs = require('fs');
const net = require('net');
const path = require('path');
const { spawn } = require('child_process');
const lib = require('./fmpty-lib.js');

const DAEMON = path.join(__dirname, 'fmpty-daemon.js');
const argv = process.argv.slice(2);
const cmd = argv.shift();
const o = { args: [] };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--id') o.id = argv[++i];
  else if (a === '--cwd') o.cwd = argv[++i];
  else if (a === '--cmd') o.cmd = argv[++i];
  else if (a === '--arg') o.args.push(argv[++i]);
  else if (a === '--lines') o.lines = parseInt(argv[++i], 10);
  else if (a === '--text') o.text = argv[++i];
  else if (a === '--text-file') o.textFile = argv[++i];
  else if (a === '--key') o.key = argv[++i];
  else if (a === '--cols') o.cols = parseInt(argv[++i], 10);
  else if (a === '--rows') o.rows = parseInt(argv[++i], 10);
  else if (a === '--state') o.state = argv[++i];
  else if (a === '--harness') o.harness = argv[++i];
  else if (a === '--scrollback') o.scrollback = parseInt(argv[++i], 10);
  else if (a === '--timeout') o.timeout = parseInt(argv[++i], 10);
  else if (a === '--plain') o.plain = true;
  else if (a === '--max-age') o.maxAge = parseInt(argv[++i], 10);
  else { usage('unknown argument ' + a); }
}

function usage(msg) {
  process.stderr.write('fmpty: ' + msg + '\n');
  process.exit(2);
}
if (!cmd) usage('a command is required');

// doctor: prove the DAEMON's runtime dependencies actually load, before a spawn
// commits to them. It has to run from this file rather than from a `node -e` in
// the caller's shell, because node resolves modules relative to the running
// script's directory - an eval in the caller's cwd looks for node_modules there
// and reports a missing dependency that is in fact installed correctly.
if (cmd === 'doctor') {
  const need = ['node-pty', '@xterm/headless', '@xterm/addon-serialize'];
  const bad = [];
  for (const m of need) {
    try { require(m); } catch (e) { bad.push(m + ': ' + (e && e.message || e).split('\n')[0]); }
  }
  if (bad.length) {
    process.stderr.write('fmpty doctor: dependencies not loadable from ' + __dirname + '\n');
    for (const b of bad) process.stderr.write('  ' + b + '\n');
    process.stderr.write("hint: run 'npm install --omit=dev' in " + __dirname + '\n');
    process.exit(1);
  }
  process.stdout.write('ok\n');
  process.exit(0);
}

if (!o.id) usage('--id is required');
try { lib.validateSessionId(o.id); } catch (e) { usage(e.message); }

const PIPE = lib.pipePath(o.id);
const TIMEOUT_MS = Number.isInteger(o.timeout) && o.timeout > 0 ? o.timeout : 10000;

// ---------------------------------------------------------------------------
// RPC
// ---------------------------------------------------------------------------
function rpc(req, cb) {
  let sock;
  try { sock = net.connect(PIPE); } catch (e) { return cb(e); }
  let acc = '';
  let settled = false;
  const done = (err, res) => { if (settled) return; settled = true; try { sock.end(); } catch (_) {} cb(err, res); };
  const to = setTimeout(() => { try { sock.destroy(); } catch (_) {} done(new Error('timeout talking to ' + PIPE)); }, TIMEOUT_MS);
  sock.on('connect', () => { try { sock.write(JSON.stringify(req) + '\n'); } catch (e) { clearTimeout(to); done(e); } });
  sock.on('data', (d) => {
    acc += d.toString('utf8');
    const nl = acc.indexOf('\n');
    if (nl < 0) return;
    clearTimeout(to);
    try { done(null, JSON.parse(acc.slice(0, nl))); } catch (e) { done(new Error('bad response: ' + e.message)); }
  });
  sock.on('error', (e) => { clearTimeout(to); done(e); });
  sock.on('close', () => { clearTimeout(to); done(new Error('pipe closed with no response')); });
}

function fail(e) {
  process.stderr.write('ERR ' + ((e && e.message) || String(e)) + '\n');
  process.exit(1);
}
function emit(obj) { process.stdout.write(JSON.stringify(obj) + '\n'); }

// ---------------------------------------------------------------------------
// spawn - the detached daemon launch
// ---------------------------------------------------------------------------
//
// THE DETACHMENT RECIPE IS LOAD-BEARING. A naive
// `spawn(detached: true, stdio: 'ignore')` still leaks the ancestor's stdio pipe
// handle into the grandchild, and the whole launching pipeline then blocks until
// the grandchild exits - measured in the spike at a full 2 minutes, with the
// wrapper returning 55 ms AFTER the child had already died. Explicit
// FILE-BACKED stdio is what makes the launcher return in ~230 ms: there is no
// inherited pipe left for anyone to wait on.
function doSpawn() {
  if (!o.cmd) usage('--cmd is required for spawn');
  const paths = lib.sessionPaths(o.id, o.state);

  // Refuse to spawn onto a live session. The pipe is a machine-scoped kernel
  // object and doubles as the mutex, so the daemon would refuse anyway with
  // EADDRINUSE - but refusing here gives the caller a clear answer instead of a
  // detached process that dies silently in a log file.
  rpc({ op: 'ping' }, (err, res) => {
    if (!err && res && res.ok) {
      process.stderr.write('error: session ' + o.id + ' is already live (epoch ' + res.epoch + ')\n');
      process.exit(1);
    }
    launch(paths);
  });
}

function launch(paths) {
  lib.ensureDir(paths.dir);
  const prev = lib.readRecord(o.id, o.state);
  const epoch = prev && Number.isInteger(prev.epoch) ? prev.epoch + 1 : 1;

  let errFd;
  try { errFd = fs.openSync(paths.stderr, 'a'); } catch (e) { return fail(e); }

  const dargs = [DAEMON, '--id', o.id, '--cmd', o.cmd, '--epoch', String(epoch)];
  if (o.cwd) dargs.push('--cwd', o.cwd);
  for (const a of o.args) dargs.push('--arg', a);
  if (o.cols) dargs.push('--cols', String(o.cols));
  if (o.rows) dargs.push('--rows', String(o.rows));
  if (o.scrollback) dargs.push('--scrollback', String(o.scrollback));
  if (o.state) dargs.push('--state', o.state);
  if (o.harness) dargs.push('--harness', o.harness);

  const child = spawn(process.execPath, dargs, {
    detached: true,
    windowsHide: true,
    stdio: ['ignore', errFd, errFd],
  });
  child.on('error', (e) => fail(e));
  child.unref();
  emit({ ok: true, daemonPid: child.pid, pipe: PIPE, epoch: epoch, session: paths.dir });
  process.exit(0);
}

// ---------------------------------------------------------------------------
// health - the crash-vs-clean-stop discrimination
// ---------------------------------------------------------------------------
//
// "The pipe does not answer" is not one condition, it is three, and firstmate
// needs them apart:
//   live     - the pipe answers; identity confirmed by nonce, no pid involved.
//   clean    - no pipe, and the record says the daemon was asked to stop.
//   crashed  - no pipe, and the record still says `running`: the daemon died
//              without being asked. The ConPTY died with it, so the agent is
//              gone too, and the transcript is the only surviving evidence.
//   absent   - no pipe and no record: this session never existed here.
// Only `crashed` and `clean` describe a session that is genuinely not running,
// which is what makes them safe for a caller to act on.
function doHealth() {
  const rec = lib.readRecord(o.id, o.state);
  rpc({ op: 'ping' }, (err, res) => {
    if (!err && res && res.ok) {
      if (o.plain) { process.stdout.write('live\n'); return process.exit(0); }
      return emit({
        ok: true, health: 'live', id: o.id, nonce: res.nonce, epoch: res.epoch,
        daemonPid: res.daemonPid, pipe: PIPE,
      });
    }
    if (!rec) {
      if (o.plain) process.stdout.write('absent\n');
      else emit({ ok: true, health: 'absent', id: o.id, pipe: PIPE });
      process.exit(1);
    }
    const paths = lib.sessionPaths(o.id, o.state);
    const health = rec.shutdown === 'clean' ? 'clean' : 'crashed';
    if (o.plain) { process.stdout.write(health + '\n'); return process.exit(1); }
    let transcriptBytes = null;
    try { transcriptBytes = fs.statSync(paths.transcript).size; } catch (_) {}
    emit({
      ok: true, health: health, id: o.id, epoch: rec.epoch || null,
      shutdown: rec.shutdown || null, exited: rec.exited || null,
      startedAt: rec.startedAt || null, transcript: paths.transcript,
      transcriptBytes: transcriptBytes, record: paths.record,
      spec: rec.spec || null,
    });
    process.exit(1);
  });
}

// ---------------------------------------------------------------------------
// verify - recorded-pid identity, done honestly
// ---------------------------------------------------------------------------
//
// The reason this exists at all: Windows recycles pids aggressively, and the
// spike hit it twice by accident - a dead launcher's pid came back as
// `msedgewebview2.exe`. Any check that asks only "is pid N alive" will
// eventually answer yes about a stranger and suppress recovery for a session
// that is actually gone.
//
// The primary liveness path never touches a pid (see `health` above); this
// command is for the cases that genuinely have only a recorded pid to go on,
// and it reports match / match-weak / mismatch / gone / unreadable rather than
// collapsing them into a boolean, because `match-weak` really is weaker.
function doVerify() {
  const rec = lib.readRecord(o.id, o.state);
  if (!rec) { emit({ ok: false, error: 'no session record for ' + o.id }); process.exit(1); }
  const targets = [];
  if (rec.daemon && Number.isInteger(rec.daemon.pid)) targets.push(['daemon', rec.daemon]);
  if (rec.child && Number.isInteger(rec.child.pid)) targets.push(['child', rec.child]);
  if (!targets.length) { emit({ ok: false, error: 'no recorded pids in the session record' }); process.exit(1); }

  const out = { ok: true, id: o.id, epoch: rec.epoch || null, results: {} };
  let pending = targets.length;
  for (const [label, ident] of targets) {
    lib.verifyIdentity(ident, (_e, verdict, live) => {
      out.results[label] = {
        pid: ident.pid, recordedName: ident.name || '', recordedStartTicks: ident.startTicks || '0',
        verdict: verdict, liveName: live ? live.name : '', liveStartTicks: live ? live.startTicks : '',
      };
      if (--pending === 0) { emit(out); process.exit(0); }
    });
  }
}

// ---------------------------------------------------------------------------
// restart - explicit relaunch of a crashed session
// ---------------------------------------------------------------------------
//
// Deliberately NOT automatic, and deliberately not called "recover". The ConPTY
// is destroyed with its creating process, so a dead daemon means a dead agent:
// nothing can bring the old agent back, and a supervisor that silently
// respawned the daemon would hand firstmate a fresh empty shell wearing a live
// session's name. That is worse than an honest failure, because it looks like
// success.
//
// So restart rebuilds the session from the RECORDED launch spec, into a new
// epoch with a new nonce, only when asked, and only when the session is
// genuinely not live. The previous transcript is rotated aside rather than
// appended to, so the crashed generation's output stays readable as its own
// artifact.
function doRestart() {
  const rec = lib.readRecord(o.id, o.state);
  if (!rec || !rec.spec || !rec.spec.cmd) {
    emit({ ok: false, error: 'no launch spec recorded for ' + o.id + '; cannot restart' });
    process.exit(1);
  }
  rpc({ op: 'ping' }, (err, res) => {
    if (!err && res && res.ok) {
      emit({ ok: false, error: 'session ' + o.id + ' is live (epoch ' + res.epoch + '); refusing to restart' });
      process.exit(1);
    }
    const paths = lib.sessionPaths(o.id, o.state);
    try {
      if (fs.existsSync(paths.transcript)) {
        fs.renameSync(paths.transcript, paths.transcript + '.epoch' + (rec.epoch || 0));
      }
    } catch (e) { process.stderr.write('warn: could not rotate transcript: ' + e.message + '\n'); }
    o.cmd = rec.spec.cmd;
    o.args = Array.isArray(rec.spec.args) ? rec.spec.args : [];
    o.cwd = o.cwd || rec.spec.cwd;
    o.cols = o.cols || rec.spec.cols;
    o.rows = o.rows || rec.spec.rows;
    o.scrollback = o.scrollback || rec.spec.scrollback;
    o.harness = o.harness || rec.spec.harness;
    if (!o.state && rec.spec.state) o.state = rec.spec.state;
    launch(lib.sessionPaths(o.id, o.state));
  });
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------
const TEXT_OPS = { capture: 1, ansi: 1, tail: 1 };
const ops = {
  capture:  () => ({ op: 'capture', lines: o.lines || 0 }),
  tail:     () => ({ op: 'tail', lines: o.lines || 0 }),
  ansi:     () => ({ op: 'capture-ansi', lines: o.lines || 0 }),
  composer: () => ({ op: 'composer' }),
  cursor:   () => ({ op: 'cursor' }),
  cwd:      () => ({ op: 'current-path' }),
  state:    () => ({ op: 'agent-state', maxAgeMs: o.maxAge }),
  busy:     () => ({ op: 'busy' }),
  info:     () => ({ op: 'info' }),
  exists:   () => ({ op: 'ping' }),
  kill:     () => ({ op: 'kill' }),
  send:     () => ({ op: 'send-text', text: readText() }),
  key:      () => ({ op: 'send-key', key: o.key }),
  resize:   () => ({ op: 'resize', cols: o.cols, rows: o.rows }),
};

// Long or awkward text comes from a file rather than argv: a Windows command
// line is length-bounded and its quoting rules differ from the shell's, so
// passing a multi-line brief as an argument is a portability trap.
// plain: the one scalar (or one fixed shape) each command reduces to. The
// composer projection is deliberately "cursor row on line 1, styled screen from
// line 2" rather than JSON: the shared classifier wants exactly those two
// things, and a shell reading them with `head -1` / `tail -n +2` cannot get the
// row-to-line alignment wrong the way a JSON unescape could.
function plain(c, r) {
  switch (c) {
    case 'state':    return String(r.state || 'unreadable') + '\n';
    case 'cwd':      return String(r.path || '') + '\n';
    case 'cursor':   return String((r.cursor && r.cursor.y) != null ? r.cursor.y : '') + '\n';
    case 'busy':     return String(r.bytesIn || 0) + ' ' + String(r.lastDataAgeMs == null ? -1 : r.lastDataAgeMs) + '\n';
    case 'exists':   return (r.ok ? 'present' : 'absent') + '\n';
    case 'composer': return String((r.cursor && r.cursor.y) != null ? r.cursor.y : '') + '\n' + (r.text || '') + '\n';
    case 'info':     return String(r.bufferType || '') + '\n';
    default:         return JSON.stringify(r) + '\n';
  }
}

function readText() {
  if (o.textFile) {
    try { return fs.readFileSync(o.textFile, 'utf8'); } catch (e) { fail(e); }
  }
  return o.text == null ? '' : o.text;
}

if (cmd === 'spawn') doSpawn();
else if (cmd === 'health') doHealth();
else if (cmd === 'verify') doVerify();
else if (cmd === 'restart') doRestart();
else if (ops[cmd]) {
  if (cmd === 'key' && !o.key) usage('--key is required');
  if (cmd === 'resize' && (!o.cols || !o.rows)) usage('--cols and --rows are required');
  rpc(ops[cmd](), (err, r) => {
    if (err) {
      // `exists` answers a question rather than reporting a fault: an absent
      // session is a normal answer, not an error to shout about.
      if (cmd === 'exists') { process.stdout.write('absent\n'); process.exit(1); }
      return fail(err);
    }
    if (TEXT_OPS[cmd]) process.stdout.write((r.text || '') + '\n');
    else if (o.plain) process.stdout.write(plain(cmd, r));
    else emit(r);
    process.exit(r && r.ok ? 0 : 1);
  });
} else {
  usage('unknown command ' + cmd);
}
