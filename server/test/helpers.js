'use strict';
// Shared helpers for the server test suites (node --test test/).
//
// Environment:
//   GODOT_BIN     path to the Godot console binary (required for host tests)
//   DATABASE_URL  a DISPOSABLE Postgres database (DB-backed tests skip without it)
const { spawn } = require('child_process');
const net = require('net');
const path = require('path');
const crypto = require('crypto');

const PROJECT_DIR = path.resolve(__dirname, '..', '..');

function godotBin() {
  return process.env.GODOT_BIN || null;
}

function haveDatabase() {
  return !!process.env.DATABASE_URL;
}

// Starts the Godot match host on a free localhost port and resolves once it
// accepts connections. Returns { port, secret, proc, stop() }.
async function startMatchHost() {
  const bin = godotBin();
  if (!bin) throw new Error('GODOT_BIN is not set');
  const secret = crypto.randomBytes(16).toString('hex');
  const port = 20000 + Math.floor(Math.random() * 20000);
  const proc = spawn(bin, ['--headless', '--path', PROJECT_DIR, '--', '--match-host', `--port=${port}`], {
    env: { ...process.env, MATCH_HOST_SECRET: secret },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let log = '';
  proc.stdout.on('data', (d) => { log += d; });
  proc.stderr.on('data', (d) => { log += d; });
  const deadline = Date.now() + 30000;
  for (;;) {
    if (await canConnect(port)) break;
    if (proc.exitCode !== null) throw new Error('match host exited early:\n' + log);
    if (Date.now() > deadline) { proc.kill(); throw new Error('match host did not start:\n' + log); }
    await new Promise((r) => setTimeout(r, 200));
  }
  return { port, secret, proc, log: () => log, stop: () => proc.kill() };
}

function canConnect(port) {
  return new Promise((resolve) => {
    const s = net.connect(port, '127.0.0.1');
    s.once('connect', () => { s.destroy(); resolve(true); });
    s.once('error', () => resolve(false));
  });
}

// Minimal newline-delimited JSON client for the host IPC (contracts/match-host-ipc.md).
class HostClient {
  constructor(port) {
    this.port = port;
    this.rid = 0;
    this.pending = new Map();
    this.buf = '';
  }
  async connect() {
    this.sock = net.connect(this.port, '127.0.0.1');
    await new Promise((res, rej) => { this.sock.once('connect', res); this.sock.once('error', rej); });
    this.sock.on('data', (d) => {
      this.buf += d.toString('utf8');
      let i;
      while ((i = this.buf.indexOf('\n')) >= 0) {
        const line = this.buf.slice(0, i); this.buf = this.buf.slice(i + 1);
        if (!line.trim()) continue;
        const msg = JSON.parse(line);
        const p = this.pending.get(msg.rid);
        if (p) { this.pending.delete(msg.rid); p(msg); }
      }
    });
  }
  request(op, payload = {}) {
    const rid = ++this.rid;
    return new Promise((resolve) => {
      this.pending.set(rid, resolve);
      this.sock.write(JSON.stringify({ op, rid, ...payload }) + '\n');
    });
  }
  close() { this.sock && this.sock.destroy(); }
}

module.exports = { PROJECT_DIR, godotBin, haveDatabase, startMatchHost, HostClient };
