'use strict';
// Supervises the headless Godot match host (scripts/game/match_host.gd): starts
// it on a localhost port with a per-boot secret, speaks the newline-delimited
// JSON IPC (contracts/match-host-ipc.md), pings it, and restarts it if it dies.
// The relay is its only client; the host never sees accounts or the database.
const { spawn } = require('child_process');
const net = require('net');
const path = require('path');
const crypto = require('crypto');
const { EventEmitter } = require('events');

const REQUEST_TIMEOUT_MS = 8000;
const PING_INTERVAL_MS = 5000;
const MAX_MISSED_PINGS = 3;

class HostProcess extends EventEmitter {
  constructor({
    godotBin = process.env.GODOT_BIN,
    projectDir = process.env.PROJECT_DIR || path.resolve(__dirname, '..', '..'),
    log = console,
  } = {}) {
    super();
    this.godotBin = godotBin;
    this.projectDir = projectDir;
    this.log = log;
    this.state = 'down'; // down | starting | ready
    this.rid = 0;
    this.pending = new Map();
    this.buf = '';
    this.missed = 0;
    this.rulesVersion = null;
    this.stopping = false;
  }

  get ready() { return this.state === 'ready'; }

  /**
   * Ends the host process and anything it started. On Windows the Godot
   * *console* binary is a shim that runs the engine as a child, so killing the
   * spawned pid alone leaves a live engine behind (half a gigabyte of it); the
   * whole tree has to go.
   */
  _kill() {
    if (!this.proc || this.proc.exitCode !== null) return;
    if (process.platform === 'win32') {
      try {
        spawn('taskkill', ['/PID', String(this.proc.pid), '/T', '/F'], { stdio: 'ignore' });
        return;
      } catch { /* fall through to the plain kill */ }
    }
    this.proc.kill();
  }

  async start() {
    if (!this.godotBin) throw new Error('GODOT_BIN is not set; cannot start the match host');
    this.stopping = false;
    this.state = 'starting';
    this.secret = crypto.randomBytes(24).toString('hex');
    this.port = 20000 + Math.floor(Math.random() * 20000);
    this.output = '';
    this.proc = spawn(this.godotBin, ['--headless', '--path', this.projectDir, '--', '--match-host', `--port=${this.port}`], {
      env: { ...process.env, MATCH_HOST_SECRET: this.secret },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const collect = (d) => { this.output = (this.output + d).slice(-8000); };
    this.proc.stdout.on('data', collect);
    this.proc.stderr.on('data', collect);
    this.proc.once('exit', (code) => this._onExit(code));

    const deadline = Date.now() + 90000;
    for (;;) {
      if (this.output.includes('MATCH_HOST_READY')) break;
      if (this.proc.exitCode !== null) throw new Error('match host exited during start:\n' + this.output);
      if (Date.now() > deadline) { this._kill(); throw new Error('match host start timed out:\n' + this.output); }
      await new Promise((r) => setTimeout(r, 150));
    }
    await this._connect();
    const hello = await this.request('hello', { secret: this.secret });
    if (!hello.ok) throw new Error('match host refused hello: ' + JSON.stringify(hello));
    this.rulesVersion = hello.rules_version;
    this.state = 'ready';
    this.missed = 0;
    this._pinger = setInterval(() => this._ping(), PING_INTERVAL_MS);
    this._pinger.unref();
    this.emit('ready');
  }

  _connect() {
    return new Promise((resolve, reject) => {
      this.sock = net.connect(this.port, '127.0.0.1');
      this.buf = '';
      this.sock.once('connect', resolve);
      this.sock.once('error', reject);
      this.sock.on('data', (d) => this._onData(d));
      this.sock.on('close', () => this._failAll('host connection closed'));
    });
  }

  _onData(d) {
    this.buf += d.toString('utf8');
    let i;
    while ((i = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, i);
      this.buf = this.buf.slice(i + 1);
      if (!line.trim()) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      const p = this.pending.get(msg.rid);
      if (p) { this.pending.delete(msg.rid); clearTimeout(p.timer); p.resolve(msg); }
    }
  }

  _failAll(reason) {
    for (const [, p] of this.pending) { clearTimeout(p.timer); p.resolve({ ok: false, error: 'host_fault', detail: reason }); }
    this.pending.clear();
  }

  request(op, payload = {}) {
    if (!this.sock || this.sock.destroyed) return Promise.resolve({ ok: false, error: 'host_fault', detail: 'not connected' });
    const rid = ++this.rid;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(rid);
        resolve({ ok: false, error: 'host_fault', detail: 'timeout' });
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(rid, { resolve, timer });
      this.sock.write(JSON.stringify({ op, rid, ...payload }) + '\n');
    });
  }

  async _ping() {
    if (this.state !== 'ready') return;
    const r = await this.request('stats');
    if (r.ok) { this.missed = 0; this.liveMatches = r.live_matches; return; }
    this.missed += 1;
    this.log.warn?.(`match host missed ping ${this.missed}/${MAX_MISSED_PINGS}`);
    if (this.missed >= MAX_MISSED_PINGS) this.restart('missed pings');
  }

  _onExit(code) {
    clearInterval(this._pinger);
    this._failAll('host exited');
    const wasReady = this.state === 'ready';
    this.state = 'down';
    if (!this.stopping) {
      this.log.error?.(`match host exited (code ${code})`);
      this.emit('down', wasReady);
      // Restart in the background; the manager replays active matches on 'ready'.
      setTimeout(() => { if (!this.stopping) this.start().catch((e) => this.log.error?.('host restart failed', e.message)); }, 1000);
    }
  }

  async restart(reason) {
    this.log.warn?.('restarting match host:', reason);
    this._kill();
    // _onExit schedules the new start.
  }

  async stop() {
    this.stopping = true;
    clearInterval(this._pinger);
    if (this.sock) this.sock.destroy();
    this._kill();
    this.state = 'down';
  }
}

module.exports = { HostProcess, REQUEST_TIMEOUT_MS };
