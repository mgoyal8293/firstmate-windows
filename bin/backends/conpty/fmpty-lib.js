'use strict';
// fmpty-lib.js - shared vocabulary for the ConPTY session provider.
//
// Both the daemon (fmpty-daemon.js) and the stateless client (fmpty.js) need
// the SAME answers to "what is this session called", "where does its durable
// state live" and "is this recorded pid still the process we recorded". Those
// answers are here so the two programs cannot drift: a client that computed a
// different pipe name than the daemon bound would silently look at nothing and
// report the session absent, which is precisely the failure mode that licenses
// a duplicate agent onto a live worktree.
//
// Nothing in this file talks to a pty or a pipe; it is pure naming, paths and
// process identity.

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');

// ---------------------------------------------------------------------------
// Session naming
// ---------------------------------------------------------------------------
//
// The Windows named-pipe namespace is MACHINE-GLOBAL: `\\.\pipe\<name>` is one
// flat namespace shared by every process and every logon session on the box.
// Two firstmate homes that both spawn a task called `crew1` would therefore
// fight over one pipe, and the loser's client would drive the winner's agent.
// The session id is scoped with the caller-supplied home tag (the shell adapter
// passes bin/fm-backend-hometag-lib.sh's value) for exactly the reason
// cmux/zellij scope their window titles, and the same relocation caveat
// applies: moving a firstmate install changes the tag and orphans old pipes.
//
// Pipe names are limited to 256 characters and may not contain a backslash;
// everything outside a conservative safe set is rejected rather than escaped,
// so a hostile or merely surprising id can never address a different pipe than
// the one the caller thinks it named.
const SESSION_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,110}$/;

function validateSessionId(id) {
  if (typeof id !== 'string' || !SESSION_ID_RE.test(id)) {
    throw new Error(
      'invalid session id ' + JSON.stringify(id) +
      ' (allowed: 1-111 chars of [A-Za-z0-9._-], first char alphanumeric)'
    );
  }
  return id;
}

function pipePath(id) {
  return '\\\\.\\pipe\\fmpty-' + validateSessionId(id);
}

// ---------------------------------------------------------------------------
// Durable state
// ---------------------------------------------------------------------------
//
// A session's durable artifacts outlive the daemon on purpose. `session.json`
// is the recovery record (launch spec, epoch, nonce, how the last daemon left);
// `transcript.log` is the byte-exact pty stream, which is the ONLY artifact
// that survives a daemon crash with the agent's own output in it.
function stateRoot(explicitRoot) {
  if (explicitRoot) return explicitRoot;
  if (process.env.FM_CONPTY_STATE) return process.env.FM_CONPTY_STATE;
  return path.join(os.homedir(), '.fm-conpty');
}

function sessionDir(id, explicitRoot) {
  return path.join(stateRoot(explicitRoot), validateSessionId(id));
}

function sessionPaths(id, explicitRoot) {
  const dir = sessionDir(id, explicitRoot);
  return {
    dir: dir,
    record: path.join(dir, 'session.json'),
    transcript: path.join(dir, 'transcript.log'),
    log: path.join(dir, 'daemon.log'),
    stderr: path.join(dir, 'daemon.stderr'),
  };
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

// readRecord: the durable session record, or null. Never throws on a corrupt
// or half-written file - a caller that cannot read the record must fall back
// to "no record", not crash, because this is the recovery path.
function readRecord(id, explicitRoot) {
  try {
    const raw = fs.readFileSync(sessionPaths(id, explicitRoot).record, 'utf8');
    const rec = JSON.parse(raw);
    return rec && typeof rec === 'object' ? rec : null;
  } catch (_) {
    return null;
  }
}

// writeRecord: atomic replace via same-directory rename. A torn record is
// indistinguishable from a crashed daemon by a later reader, and would make
// crash recovery report the wrong thing, so it must never be observable.
function writeRecord(id, rec, explicitRoot) {
  const p = sessionPaths(id, explicitRoot);
  ensureDir(p.dir);
  const tmp = p.record + '.' + process.pid + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(rec, null, 2));
  fs.renameSync(tmp, p.record);
}

function newNonce() {
  return crypto.randomBytes(16).toString('hex');
}

// ---------------------------------------------------------------------------
// Process identity
// ---------------------------------------------------------------------------
//
// Windows recycles pids aggressively, and the spike hit it twice by accident
// (a dead launcher's pid came back as `msedgewebview2.exe`). A bare
// `is pid 40000 alive` therefore proves NOTHING about whether it is still the
// process that was recorded, and a liveness probe built on one would eventually
// report a stranger as the agent - the single worst outcome available here,
// because "agent alive" suppresses recovery.
//
// An identity is the triple (pid, name, startTicks). `startTicks` is the
// process creation time in .NET ticks; it is the field that makes the triple
// unforgeable by recycling, since a recycled pid necessarily started later than
// the process that previously held it.
//
// COST NOTE, measured on the target machine (Windows 10.0.26200, node 22.18):
//   tasklist.exe /FO CSV /NH              ~410-450 ms   name only, all pids
//   tasklist.exe /FO CSV /NH /FI "PID eq" ~175 ms       name only, one pid
//   powershell Get-Process (all)          ~625 ms       name + start ticks
//   powershell Get-CimInstance Win32_Process ~1100 ms   name + creation date
//   tasklist.exe /V                       ~38 000 ms    never use this
// The daemon therefore batches: one Get-Process sweep answers every unknown pid
// at once, and the result is cached per pid for that pid's lifetime.

const PS_ARGS = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command'];

// Every identity sweep is bounded. Without a timeout a wedged PowerShell or
// tasklist would leave the daemon's refresh permanently in flight: the liveness
// cache would never update again, and callers that (correctly) wait for a fresh
// sweep rather than accept a stale one would wait forever. The failure the
// timeout produces - an unreadable identity - is recoverable; a permanent wedge
// in the probe that recovery depends on is not.
const SWEEP_TIMEOUT_MS = 15000;

// snapshotIdentities: one batched sweep of every process on the box, as
// { pid: {name, startTicks} }. `startTicks` is 0 when the process's start time
// is unreadable (protected/system processes deny it); callers must treat 0 as
// "identity unavailable" rather than as a comparable value.
function snapshotIdentities(cb) {
  const script =
    '$ErrorActionPreference="SilentlyContinue";' +
    '(Get-Process | ForEach-Object { ' +
    '"$($_.Id)`t$($_.ProcessName)`t$(try{$_.StartTime.Ticks}catch{0})" }) -join "`n"';
  execFile('powershell.exe', PS_ARGS.concat([script]),
    { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, windowsHide: true, timeout: SWEEP_TIMEOUT_MS },
    (err, out) => {
      if (err) return cb(err, null);
      const map = Object.create(null);
      for (const line of String(out).split(/\r?\n/)) {
        const parts = line.split('\t');
        if (parts.length < 3) continue;
        const pid = parseInt(parts[0], 10);
        if (!Number.isInteger(pid)) continue;
        const ticks = parts[2].trim();
        map[pid] = {
          // Get-Process reports ProcessName WITHOUT the .exe suffix; the
          // console-process-list path and tasklist both carry it. Normalize to
          // the suffixed form so one classifier sees one vocabulary.
          name: parts[1].trim() ? parts[1].trim() + '.exe' : '',
          startTicks: /^\d+$/.test(ticks) ? ticks : '0',
        };
      }
      cb(null, map);
    });
}

// snapshotNames: the cheap fallback when PowerShell is unavailable or slow -
// names only, no start ticks, so identities built from it are explicitly
// marked unvalidated rather than silently trusted.
function snapshotNames(cb) {
  execFile('tasklist.exe', ['/FO', 'CSV', '/NH'],
    { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, windowsHide: true, timeout: SWEEP_TIMEOUT_MS },
    (err, out) => {
      if (err) return cb(err, null);
      const map = Object.create(null);
      for (const line of String(out).split(/\r?\n/)) {
        const m = /^"([^"]*)","(\d+)"/.exec(line);
        if (m) map[m[2]] = { name: m[1], startTicks: '0' };
      }
      cb(null, map);
    });
}

// identityMatches: does <recorded> still describe the process now holding
// <pid>? Requires the name to match and, when BOTH sides carry a real start
// time, requires those to match too. A missing start time on either side
// downgrades the verdict to name-only, which is reported honestly by
// verifyIdentity below rather than being passed off as a full match.
function identityMatches(recorded, live) {
  if (!recorded || !live) return false;
  const rn = String(recorded.name || '').toLowerCase();
  const ln = String(live.name || '').toLowerCase();
  if (!rn || !ln || rn !== ln) return false;
  const rt = String(recorded.startTicks || '0');
  const lt = String(live.startTicks || '0');
  if (rt !== '0' && lt !== '0') return rt === lt;
  return true;
}

// verifyIdentity: classify a RECORDED identity against live truth.
//   match          - same name and same start time: provably the same process.
//   match-weak     - same name, but one side has no start time: not proof.
//   mismatch       - a different process now holds that pid (recycled).
//   gone           - no process holds that pid.
//   unreadable     - the identity sweep itself failed.
function verifyIdentity(recorded, cb) {
  if (!recorded || !Number.isInteger(recorded.pid)) return cb(null, 'unreadable', null);
  snapshotIdentities((err, map) => {
    const finish = (m) => {
      if (!m) return cb(null, 'unreadable', null);
      const live = m[recorded.pid];
      if (!live) return cb(null, 'gone', null);
      if (!identityMatches(recorded, live)) return cb(null, 'mismatch', live);
      const strong = String(recorded.startTicks || '0') !== '0' && String(live.startTicks || '0') !== '0';
      return cb(null, strong ? 'match' : 'match-weak', live);
    };
    if (!err && map) return finish(map);
    snapshotNames((err2, map2) => finish(err2 ? null : map2));
  });
}

module.exports = {
  SESSION_ID_RE,
  validateSessionId,
  pipePath,
  stateRoot,
  sessionDir,
  sessionPaths,
  ensureDir,
  readRecord,
  writeRecord,
  newNonce,
  snapshotIdentities,
  snapshotNames,
  identityMatches,
  verifyIdentity,
};
