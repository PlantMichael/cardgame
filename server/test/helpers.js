'use strict';
// Shared helpers for the server test suites (node --test test/).
//
// Environment:
//   GODOT_BIN     path to the Godot console binary (required for host tests)
//   DATABASE_URL  a DISPOSABLE Postgres database (DB-backed tests skip without it)
const { spawn } = require('child_process');
const net = require('net');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');

const PROJECT_DIR = path.resolve(__dirname, '..', '..');

function godotBin() {
  return process.env.GODOT_BIN || null;
}

function haveDatabase() {
  return !!process.env.DATABASE_URL;
}

// Starts the Godot match host on a free localhost port and resolves once it
// accepts connections. Returns { port, secret, proc, log(), stop() }.
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
  const deadline = Date.now() + 60000;
  for (;;) {
    if (log.includes('MATCH_HOST_READY') && await canConnect(port)) break;
    if (proc.exitCode !== null) throw new Error('match host exited early:\n' + log);
    if (Date.now() > deadline) { killTree(proc); throw new Error('match host did not start:\n' + log); }
    await new Promise((r) => setTimeout(r, 200));
  }
  return { port, secret, proc, log: () => log, stop: () => killTree(proc) };
}

// On Windows the Godot console binary is a shim that runs the engine as a child
// process: killing the spawned pid alone leaves a live engine behind.
function killTree(proc) {
  if (!proc || proc.exitCode !== null) return;
  if (process.platform === 'win32') {
    try { spawn('taskkill', ['/PID', String(proc.pid), '/T', '/F'], { stdio: 'ignore' }); return; } catch { /* fall through */ }
  }
  proc.kill();
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

// A 30-card deck from the real card files. Host tests do not enforce deck
// rules (the relay does); cards just have to exist and not be tokens.
function buildDeck(files = ['green', 'generic'], size = 30) {
  const cards = [];
  for (const f of files) {
    const list = JSON.parse(fs.readFileSync(path.join(PROJECT_DIR, 'data', 'cards', `${f}.json`), 'utf8'));
    for (const c of list) if (!c.is_token) cards.push(c);
  }
  cards.sort((a, b) => a.cost - b.cost || (a.id < b.id ? -1 : 1));
  const deck = [];
  for (let i = 0; deck.length < size; i++) deck.push(cards[i % Math.min(cards.length, 15)].id);
  return deck;
}

// Starts a host, connects and says hello.
async function hostSession() {
  const host = await startMatchHost();
  const client = new HostClient(host.port);
  await client.connect();
  const hello = await client.request('hello', { secret: host.secret });
  if (!hello.ok) throw new Error('hello failed: ' + JSON.stringify(hello));
  const RULES_VERSION = hello.rules_version;
  return {
    host, client, RULES_VERSION,
    create: (id, opts = {}) => client.request('create', {
      match_id: id, seed: opts.seed ?? 42, first_seat: opts.first ?? 'a',
      deck_a: opts.deckA ?? buildDeck(), deck_b: opts.deckB ?? buildDeck(['crimson', 'generic']),
      rules_version: RULES_VERSION,
    }),
    cmd: (id, seat, cmd, expectSeq) => client.request('command', { match_id: id, seat, cmd, expect_seq: expectSeq }),
    stop: () => { client.close(); host.stop(); },
  };
}

module.exports = { PROJECT_DIR, godotBin, haveDatabase, startMatchHost, HostClient, buildDeck, hostSession };
