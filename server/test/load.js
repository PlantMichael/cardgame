'use strict';
// Load test for server-run ranked matches (specs/003-authoritative-ranked-server,
// T073). NOT part of `npm test`: it needs a real Godot binary and takes minutes.
//
//   GODOT_BIN=<godot> node test/load.js [--matches=100] [--turns=16] [--budget-ms=300]
//
// It drives the real path a client takes - validateClientMessage -> MatchManager
// -> Godot match host -> store -> match_ack - for N matches at once through one
// host process, with bots that answer choices, play creatures, attack and end
// turns. The store is the in-memory one: this measures the rules host and the
// relay's own work, not Postgres (SC-003 is about accepted-action latency).
//
// It reports p50/p95/max accepted-action latency and the host process's memory
// and CPU, and exits non-zero if p95 is over the budget.
const assert = require('assert');
const { execFile } = require('child_process');
const { HostProcess } = require('../authoritative/host_process');
const { MatchManager } = require('../authoritative/match_manager');
const { MemoryStore } = require('../authoritative/memory_store');
const { loadCards, validateDeck } = require('../authoritative/decks');

const arg = (name, dflt) => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? Number(hit.split('=')[1]) : dflt;
};
const MATCHES = arg('matches', 100);
const TURNS = arg('turns', 16);
const BUDGET_MS = arg('budget-ms', 300);

const FACTIONS = [['GREEN', 0], ['CRIMSON', 1]];

/** Two legal 30-card decks built from the shipped card files. */
function buildDecks(cards) {
  const out = [];
  for (const [color, factionIdx] of FACTIONS) {
    const pool = [...cards.values()].filter(
      (c) => (c.color === color || c.color === 'GENERIC') && !c.is_token && c.rarity !== 'LEGENDARY');
    pool.sort((a, b) => a.cost - b.cost || (a.id < b.id ? -1 : 1));
    const ids = [];
    for (const c of pool) {
      if (ids.length >= 30) break;
      ids.push(c.id, c.id); // two copies, the per-card maximum
    }
    const v = validateDeck(ids.slice(0, 30), factionIdx, cards);
    assert.ok(v.ok, `built an illegal ${color} deck: ${v.error}`);
    out.push({ faction_idx: factionIdx, card_ids: v.cardIds });
  }
  return out;
}

/** One bot's socket: collects what the manager sends and resolves waiters. */
class BotConn {
  constructor() {
    this.acks = new Map();     // client_seq -> { ok, reason }
    this.waiters = new Map();  // client_seq -> resolve
    this.view = null;
    this.seq = 0;
    this.over = null;
  }
  send(obj) {
    switch (obj.type) {
      case 'match_view': this.view = obj.view; this.seq = obj.seq; break;
      case 'match_over': this.over = obj; break;
      case 'match_ack': this._settle(obj.client_seq, { ok: true }); break;
      case 'match_error': this._settle(obj.client_seq, { ok: false, reason: obj.reason }); break;
      default: break;
    }
  }
  _settle(clientSeq, result) {
    if (clientSeq === undefined) return;
    const w = this.waiters.get(clientSeq);
    if (w) { this.waiters.delete(clientSeq); w(result); } else this.acks.set(clientSeq, result);
  }
  wait(clientSeq) {
    const have = this.acks.get(clientSeq);
    if (have) { this.acks.delete(clientSeq); return Promise.resolve(have); }
    return new Promise((resolve) => this.waiters.set(clientSeq, resolve));
  }
  close() {}
}

// How often each refusal reason came back: a dumb bot tries illegal attacks, and
// those round trips are load too, so they are reported rather than hidden.
const REFUSALS = new Map();

const pct = (sorted, p) => (sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))] : 0);
const mine = (view, seat) => (seat === 'a' ? view.host_state : view.guest_state);
const theirs = (view, seat) => (seat === 'a' ? view.guest_state : view.host_state);

class Bot {
  constructor(manager, matchId, playerId, seat, conn, defs, samples) {
    Object.assign(this, { manager, matchId, playerId, seat, conn, defs, samples });
    this.clientSeq = 0;
    this.refused = 0;
  }

  /**
   * Sends one command and times it; only accepted actions become samples.
   * A bot plays far faster than a person, so it can trip the seat's 20
   * actions/s budget on a small run: it waits out a rate_limited refusal once
   * rather than reporting it as load.
   */
  async act(cmd) {
    const r = await this._send(cmd);
    if (r.ok || r.reason !== 'rate_limited') return r;
    await new Promise((resolve) => setTimeout(resolve, 80));
    return this._send(cmd);
  }

  async _send(cmd) {
    const clientSeq = ++this.clientSeq;
    const started = process.hrtime.bigint();
    const wait = this.conn.wait(clientSeq);
    await this.manager.handleMessage(
      this.playerId, { type: 'match_command', match_id: this.matchId, client_seq: clientSeq, cmd }, this.conn);
    const r = await wait;
    if (r.ok) this.samples.push(Number(process.hrtime.bigint() - started) / 1e6);
    else { this.refused += 1; REFUSALS.set(r.reason, (REFUSALS.get(r.reason) || 0) + 1); }
    return r;
  }

  async join() {
    await this.manager.handleMessage(this.playerId, { type: 'match_join', match_id: this.matchId }, this.conn);
  }

  async mulligan() {
    const clientSeq = ++this.clientSeq;
    const wait = this.conn.wait(clientSeq);
    await this.manager.handleMessage(
      this.playerId, { type: 'match_mulligan', match_id: this.matchId, client_seq: clientSeq, card_uids: [] }, this.conn);
    return wait;
  }

  cost(card) {
    const def = this.defs.get(card.id);
    return def ? Math.max(0, def.cost - (card.cost_modifier || 0)) : 99;
  }

  /** Answers an open choice; returns false when there was none. */
  async answerChoice() {
    const pc = this.conn.view && this.conn.view.pending_choice;
    if (!pc || !pc.id) return false;
    const selection = String(pc.default !== undefined && pc.default !== null ? pc.default : ((pc.options || [])[0] || ''));
    await this.act({ type: 'answer_choice', choice_id: pc.id, selection });
    return true;
  }

  /** Plays what it can afford, attacks with whatever is ready, ends the turn. */
  async takeTurn() {
    for (let guard = 0; guard < 24; guard++) {
      if (this.conn.over) return;
      if (await this.answerChoice()) continue;
      const me = mine(this.conn.view, this.seat);
      // current_mana is what has been SPENT this turn (PlayerState's convention).
      const available = me.max_mana - me.current_mana;
      const playable = (me.hand || []).find((c) => {
        const def = this.defs.get(c.id);
        return def && def.card_type === 'CREATURE' && this.cost(c) <= available;
      });
      if (!playable) break;
      const r = await this.act({ type: 'play_creature', card_uid: playable.uid, at_index: -1 });
      if (!r.ok) break;
    }
    for (let guard = 0; guard < 12; guard++) {
      if (this.conn.over) return;
      if (await this.answerChoice()) continue;
      const view = this.conn.view;
      const ready = (mine(view, this.seat).board || []).find(
        (m) => !m.has_attacked && !m.is_exhausted && m.current_attack > 0);
      if (!ready) break;
      const enemy = (theirs(view, this.seat).board || [])[0];
      const target = enemy
        ? { target_instance_id: enemy.instance_id }
        : { target_player_id: this.seat === 'a' ? 'guest' : 'host' };
      const r = await this.act({ type: 'attack', attacker_instance_id: ready.instance_id, ...target });
      if (!r.ok) break;
    }
    if (this.conn.over) return;
    await this.answerChoice();
    const ended = await this.act({ type: 'end_turn' });
    if (!ended.ok) { await this.answerChoice(); await this.act({ type: 'end_turn' }); }
  }
}

/**
 * Working-set bytes and CPU seconds of a pid, best effort, cross-platform.
 * The pid and its direct children are summed: on Windows the Godot *console*
 * binary is a small shim that runs the engine as a child process, so measuring
 * the pid alone reports a few megabytes and no CPU.
 *
 * It MUST stay asynchronous. Sampling with execFileSync blocks Node's event
 * loop for as long as the query takes, which lands on the measurement itself:
 * a synchronous PowerShell sample every 2 s turned a p95 of ~120 ms into
 * ~2000 ms of pure measurement overhead.
 */
function processUsage(pid) {
  return new Promise((resolve) => {
    const done = (err, stdout) => {
      if (err) return resolve(null);
      const out = String(stdout).trim().split(/\s+/);
      if (process.platform === 'win32') return resolve({ rssMb: Number(out[0]) / 1048576, cpuSeconds: Number(out[1]) });
      const parts = (out[1] || '0:0:0').split(':').map(Number);
      const secs = parts.length === 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : parts[0] * 60 + parts[1];
      return resolve({ rssMb: Number(out[0]) / 1024, cpuSeconds: secs || 0 });
    };
    if (process.platform === 'win32') {
      execFile('powershell', ['-NoProfile', '-Command',
        `$ids = @(${pid}) + @(Get-CimInstance Win32_Process -Filter "ParentProcessId=${pid}" | ForEach-Object { $_.ProcessId });` +
        ' $ps = $ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue };' +
        ' "$(($ps | Measure-Object WorkingSet64 -Sum).Sum) $((($ps | ForEach-Object { $_.TotalProcessorTime.TotalSeconds }) | Measure-Object -Sum).Sum)"'],
      done);
    } else {
      execFile('ps', ['-o', 'rss=,cputime=', '-p', String(pid)], done);
    }
  });
}

async function main() {
  if (!process.env.GODOT_BIN) {
    console.error('GODOT_BIN is not set; the load test needs a real match host.');
    process.exit(2);
  }
  const cards = loadCards();
  const [deckA, deckB] = buildDecks(cards);
  const decks = {};
  for (let i = 0; i < MATCHES; i++) {
    decks[`p${i}a:load`] = deckA;
    decks[`p${i}b:load`] = deckB;
  }
  const store = new MemoryStore({ decks });
  const quiet = { warn() {}, error: console.error, log() {} };
  const host = new HostProcess({ log: quiet });
  await host.start();
  const manager = new MatchManager({
    store, host, cards, settle: null,
    // The clocks are parked: this measures throughput, not timeouts.
    config: { maxLiveMatches: MATCHES + 10, turnSeconds: 1e6, mulliganSeconds: 1e6, graceSeconds: 1e6 },
    log: quiet,
  });

  const samples = [];
  const bots = [];
  for (let i = 0; i < MATCHES; i++) {
    const id = `ld_${i}`;
    const created = await manager.createMatch({
      matchId: id, a: { playerId: `p${i}a`, deckName: 'load' }, b: { playerId: `p${i}b`, deckName: 'load' },
    });
    assert.ok(created.ok, `match ${id} was not created: ${JSON.stringify(created)}`);
    bots.push(['a', 'b'].map((seat) => new Bot(manager, id, `p${i}${seat}`, seat, new BotConn(), cards, samples)));
  }
  console.log(`created ${MATCHES} matches; host pid ${host.proc.pid}`);

  const usage = [];
  let sampling = false;
  const sampler = setInterval(() => {
    if (sampling) return; // never queue samples behind each other
    sampling = true;
    processUsage(host.proc.pid).then((u) => { sampling = false; if (u) usage.push(u); });
  }, 1000);
  const startedAt = Date.now();

  // Every match runs at the same time; inside a match the seats play in turn order.
  const played = await Promise.all(bots.map(async ([a, b]) => {
    await a.join();
    await b.join();
    await a.mulligan();
    await b.mulligan();
    for (let turn = 0; turn < TURNS; turn++) {
      if (a.conn.over || b.conn.over) break;
      const active = a.conn.view.active_player_id === 'host' ? a : b;
      await active.takeTurn();
    }
    return { over: !!(a.conn.over || b.conn.over), refused: a.refused + b.refused };
  }));
  clearInterval(sampler);

  const elapsed = (Date.now() - startedAt) / 1000;
  const sorted = [...samples].sort((x, y) => x - y);
  const p95 = pct(sorted, 95);
  const finished = played.filter((p) => p.over).length;
  const refused = played.reduce((n, p) => n + p.refused, 0);
  const peak = usage.reduce((m, u) => Math.max(m, u.rssMb), 0);
  const cpu = usage.reduce((m, u) => Math.max(m, u.cpuSeconds), 0);

  console.log('');
  console.log(`matches              ${MATCHES} (${finished} reached game over)`);
  console.log(`accepted actions     ${samples.length} (${refused} refused)`);
  console.log(`wall clock           ${elapsed.toFixed(1)} s  (${(samples.length / elapsed).toFixed(1)} accepted actions/s)`);
  console.log(`latency p50          ${pct(sorted, 50).toFixed(1)} ms`);
  console.log(`latency p95          ${p95.toFixed(1)} ms   (budget ${BUDGET_MS} ms)`);
  console.log(`latency p99          ${pct(sorted, 99).toFixed(1)} ms`);
  console.log(`latency max          ${(sorted[sorted.length - 1] || 0).toFixed(1)} ms`);
  console.log(`refusal reasons      ${[...REFUSALS].map(([k, n]) => `${k}=${n}`).join(' ') || 'none'}`);
  console.log(`host peak memory     ${peak.toFixed(0)} MB`);
  console.log(`host CPU             ${cpu.toFixed(1)} s over ${elapsed.toFixed(1)} s wall (${((cpu / elapsed) * 100).toFixed(0)}% of one core)`);

  await host.stop();
  if (!samples.length) { console.error('\nFAIL: no action was accepted'); process.exit(1); }
  if (p95 > BUDGET_MS) { console.error(`\nFAIL: p95 ${p95.toFixed(1)} ms is over the ${BUDGET_MS} ms budget (SC-003)`); process.exit(1); }
  console.log('\nPASS');
  process.exit(0);
}

main().catch((e) => { console.error(e); process.exit(1); });
