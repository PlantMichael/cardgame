'use strict';
// End-to-end run of server-authoritative ranked matches through the REAL relay
// process, the REAL Godot match host and a REAL Postgres (spec 003, T050/T062
// as far as a script can take them).
//
// NOT part of `npm test`: it needs a Godot binary, a disposable database and a
// free port, and it takes a couple of minutes.
//
//   GODOT_BIN=<godot> DATABASE_URL=postgres://postgres:pg@127.0.0.1:5432/cardgame_test \
//     node test/e2e_ranked.js [--port=8099] [--turns=60]
//
// What it does NOT cover: these clients speak the websocket protocol directly.
// The Godot client (remote_match_client.gd, its mulligan dialog, choice prompts
// and game-over screen) is still only proven by playing the real game.
const assert = require('assert');
const crypto = require('crypto');
const { spawn } = require('child_process');
const path = require('path');
const WebSocket = require('ws');
const { Pool } = require('pg');
const { initLegacySchema } = require('../schema_legacy');
const { initSchema } = require('../authoritative/schema');
const { loadCards } = require('../authoritative/decks');
const { disposableDatabase, PROJECT_DIR } = require('./helpers');

const arg = (name, dflt) => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? Number(hit.split('=')[1]) : dflt;
};
const PORT = arg('port', 8099);
const MAX_TURNS = arg('turns', 60);
const URL_ = `ws://127.0.0.1:${PORT}`;
const SERVER_DIR = path.join(PROJECT_DIR, 'server');

// --- tiny check harness ----------------------------------------------------
const checks = [];
function ok(name, cond, detail = '') {
  checks.push({ name, pass: !!cond, detail });
  console.log(`${cond ? 'ok  ' : 'FAIL'}  ${name}${cond || !detail ? '' : `\n        ${detail}`}`);
}
function eq(name, got, want) {
  ok(name, Object.is(got, want) || JSON.stringify(got) === JSON.stringify(want), `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}

// --- a websocket client that speaks the relay's protocol -------------------
class Client {
  constructor(label) {
    this.label = label;
    this.inbox = [];          // notifications nobody is waiting for yet
    this.waiters = [];        // { match, resolve }
    this.viewWaiters = [];    // resolvers for the next match_view
    this.view = null;
    this.seq = -1;
    this.over = null;
    this.voided = null;
    this.opponentGone = 0;
    this.opponentBack = 0;
    this.clientSeq = 0;
    this.refusals = new Map();
  }

  open() {
    this.ws = new WebSocket(URL_);
    this.ws.on('message', (raw) => this._receive(JSON.parse(raw)));
    return new Promise((resolve, reject) => {
      this.ws.once('open', resolve);
      this.ws.once('error', reject);
    });
  }

  _receive(msg) {
    switch (msg.type) {
      case 'match_view': {
        // State, not a notification: it replaces what this client knows and is
        // never queued. An inbox of stale views made a rejoin look like it had
        // been handed seq 1 when the match was already at seq 4.
        this.view = msg.view;
        this.seq = msg.seq;
        const waiting = this.viewWaiters;
        this.viewWaiters = [];
        for (const r of waiting) r(msg);
        return;
      }
      case 'match_clock': return; // display only
      case 'match_over': this.over = msg; break;
      case 'match_voided': this.voided = msg; break;
      case 'opponent_disconnected': this.opponentGone += 1; break;
      case 'opponent_reconnected': this.opponentBack += 1; break;
      default: break;
    }
    const i = this.waiters.findIndex((w) => w.match(msg));
    if (i >= 0) this.waiters.splice(i, 1)[0].resolve(msg);
    else this.inbox.push(msg);
  }

  send(obj) { this.ws.send(JSON.stringify(obj)); }

  /** The next match_view to arrive (never one that has already been applied). */
  nextView(timeoutMs = 15000) {
    return new Promise((resolve, reject) => {
      this.viewWaiters.push(resolve);
      setTimeout(() => {
        const at = this.viewWaiters.indexOf(resolve);
        if (at >= 0) { this.viewWaiters.splice(at, 1); reject(new Error(`${this.label}: no match_view arrived`)); }
      }, timeoutMs).unref?.();
    });
  }

  /**
   * Waits until this client holds the view produced by an action taken at `seq`.
   * The ack and the view are separate frames over a real socket, so a client
   * that decides its next move straight after the ack is reading the board as
   * it was BEFORE its own move - which is how a bot ends up playing out of turn.
   */
  async viewAfter(seq, timeoutMs = 15000) {
    const until = Date.now() + timeoutMs;
    while (this.seq <= seq && !this.over && !this.voided && Date.now() < until) {
      try { await this.nextView(Math.max(250, until - Date.now())); } catch { break; }
    }
  }

  /** Resolves with the first message matching `match` (already-received ones count). */
  expect(match, what, timeoutMs = 20000) {
    const test = typeof match === 'string' ? (m) => m.type === match : match;
    const i = this.inbox.findIndex(test);
    if (i >= 0) return Promise.resolve(this.inbox.splice(i, 1)[0]);
    return new Promise((resolve, reject) => {
      const w = { match: test, resolve };
      this.waiters.push(w);
      setTimeout(() => {
        const at = this.waiters.indexOf(w);
        if (at >= 0) { this.waiters.splice(at, 1); reject(new Error(`${this.label}: timed out waiting for ${what || match}`)); }
      }, timeoutMs).unref?.();
    });
  }

  async register() {
    this.username = 'e2e_' + crypto.randomBytes(4).toString('hex');
    this.password = 'passw0rd!';
    this.send({ type: 'register', username: this.username, password: this.password });
    const r = await this.expect('register_result', 'register_result');
    assert.ok(r.success, `${this.label}: register failed: ${r.message}`);
    this.token = r.token;
    this.playerId = null; // filled from the database
    return r;
  }

  async login() {
    this.send({ type: 'login', username: this.username, password: this.password });
    const r = await this.expect('login_result', 'login_result');
    assert.ok(r.success, `${this.label}: login failed: ${r.message}`);
    this.token = r.token;
    return r;
  }

  queue(deckName, rulesVersion) {
    this.send({ type: 'queue_ranked', token: this.token, deck_name: deckName, rules_version: rulesVersion });
  }

  join(sinceN) {
    const view = this.nextView();
    this.send({ type: 'match_join', token: this.token, match_id: this.matchId, ...(sinceN === undefined ? {} : { since_n: sinceN }) });
    return view;
  }

  /** One ordered action; resolves { ok, reason }. Retries once past the seat's rate limit. */
  async act(frame) {
    const r = await this._send(frame);
    if (r.ok || r.reason !== 'rate_limited') return r;
    await new Promise((res) => setTimeout(res, 120));
    return this._send(frame);
  }

  async _send(frame) {
    const clientSeq = ++this.clientSeq;
    const seqBefore = this.seq;
    this.send({ ...frame, token: this.token, match_id: this.matchId, client_seq: clientSeq });
    const m = await this.expect(
      (x) => (x.type === 'match_ack' || x.type === 'match_error') && x.client_seq === clientSeq,
      `ack for client_seq ${clientSeq}`,
    );
    if (m.type !== 'match_ack') {
      this.refusals.set(m.reason, (this.refusals.get(m.reason) || 0) + 1);
      return { ok: false, reason: m.reason };
    }
    await this.viewAfter(seqBefore);
    return { ok: true };
  }

  mulligan(cardUids = []) { return this.act({ type: 'match_mulligan', card_uids: cardUids }); }
  command(cmd) { return this.act({ type: 'match_command', cmd }); }
  concede() { this.send({ type: 'match_concede', token: this.token, match_id: this.matchId }); }

  close() { try { this.ws.close(); } catch { /* already gone */ } }
}

// --- a bot that can take a turn from a view --------------------------------
const mine = (view, seat) => (seat === 'a' ? view.host_state : view.guest_state);
const theirs = (view, seat) => (seat === 'a' ? view.guest_state : view.host_state);

class Bot {
  constructor(client, seat, defs) { Object.assign(this, { client, seat, defs }); }

  cost(card) {
    const def = this.defs.get(card.id);
    return def ? Math.max(0, def.cost - (card.cost_modifier || 0)) : 99;
  }

  async answerChoice() {
    const pc = this.client.view && this.client.view.pending_choice;
    if (!pc || !pc.id) return false;
    const selection = String(pc.default !== undefined && pc.default !== null ? pc.default : ((pc.options || [])[0] || ''));
    await this.client.command({ type: 'answer_choice', choice_id: pc.id, selection });
    return true;
  }

  /** Plays what it can afford, attacks with whatever is ready, ends the turn. */
  async takeTurn() {
    for (let guard = 0; guard < 24; guard++) {
      if (this.client.over) return;
      if (await this.answerChoice()) continue;
      const me = mine(this.client.view, this.seat);
      const available = me.max_mana - me.current_mana; // current_mana is mana SPENT
      const playable = (me.hand || []).find((c) => {
        const def = this.defs.get(c.id);
        return def && def.card_type === 'CREATURE' && this.cost(c) <= available;
      });
      if (!playable) break;
      const r = await this.client.command({ type: 'play_creature', card_uid: playable.uid, at_index: -1 });
      if (!r.ok) break;
    }
    for (let guard = 0; guard < 12; guard++) {
      if (this.client.over) return;
      if (await this.answerChoice()) continue;
      const view = this.client.view;
      const ready = (mine(view, this.seat).board || []).find((m) => !m.has_attacked && !m.is_exhausted && m.current_attack > 0);
      if (!ready) break;
      const enemy = (theirs(view, this.seat).board || [])[0];
      const target = enemy ? { target_instance_id: enemy.instance_id } : { target_player_id: this.seat === 'a' ? 'guest' : 'host' };
      const r = await this.client.command({ type: 'attack', attacker_instance_id: ready.instance_id, ...target });
      if (!r.ok) break;
    }
    if (this.client.over) return;
    await this.answerChoice();
    const ended = await this.client.command({ type: 'end_turn' });
    if (!ended.ok) { await this.answerChoice(); await this.client.command({ type: 'end_turn' }); }
  }
}

// --- the relay under test --------------------------------------------------
function startRelay(env) {
  const proc = spawn(process.execPath, ['relay.js'], { cwd: SERVER_DIR, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let log = '';
  proc.stdout.on('data', (d) => { log += d; });
  proc.stderr.on('data', (d) => { log += d; });
  return { proc, log: () => log };
}

function killTree(proc) {
  if (!proc || proc.exitCode !== null) return;
  // The relay's own child (the Godot console shim) spawns the engine as a
  // further child on Windows, so the whole tree has to go.
  if (process.platform === 'win32') {
    try { spawn('taskkill', ['/PID', String(proc.pid), '/T', '/F'], { stdio: 'ignore' }); return; } catch { /* fall through */ }
  }
  proc.kill();
}

async function main() {
  const dbUrl = process.env.DATABASE_URL || '';
  if (!process.env.GODOT_BIN) { console.error('GODOT_BIN is not set.'); process.exit(2); }
  if (!disposableDatabase(dbUrl)) {
    console.error('DATABASE_URL must point at a DISPOSABLE database (this script truncates it).');
    process.exit(2);
  }

  const pool = new Pool({ connectionString: dbUrl, ssl: false, max: 4 });
  await initLegacySchema(pool);
  await initSchema(pool);
  await pool.query(`TRUNCATE ranked_match_actions, ranked_match_audit, ranked_matches,
    ranked_settlements, decks, owned_cards, sessions, players RESTART IDENTITY CASCADE`);

  const relay = startRelay({
    ...process.env, PORT: String(PORT), RANKED_AUTHORITATIVE: '1',
    PROJECT_DIR: process.env.PROJECT_DIR || PROJECT_DIR,
    // A short grace window so the disconnect checks do not take a minute.
    RANKED_GRACE_SECONDS: process.env.RANKED_GRACE_SECONDS || '25',
  });
  const defs = loadCards();

  try {
    // 1. The relay boots with the flag on and reports a rules version.
    const deadline = Date.now() + 120000;
    let rulesVersion = null;
    for (;;) {
      const m = /rules version (\d+)/.exec(relay.log());
      if (m && relay.log().includes('Relay server listening')) { rulesVersion = Number(m[1]); break; }
      if (relay.proc.exitCode !== null) throw new Error('relay exited during start:\n' + relay.log());
      if (Date.now() > deadline) throw new Error('relay did not start:\n' + relay.log());
      await new Promise((r) => setTimeout(r, 250));
    }
    ok('the relay starts with RANKED_AUTHORITATIVE=1 and a rules version', rulesVersion > 0, `rules version ${rulesVersion}`);

    const playerIdOf = async (username) => (await pool.query('SELECT id FROM players WHERE username = $1', [username])).rows[0].id;

    // --- Match 1: queued, played to game over, with a reconnect in the middle.
    const a = new Client('A');
    const b = new Client('B');
    await a.open(); await b.open();
    await a.register(); await b.register();
    a.playerId = await playerIdOf(a.username);
    b.playerId = await playerIdOf(b.username);
    ok('two accounts register over the websocket', !!a.token && !!b.token);

    // 2. A client on the wrong rules version is not queued at all.
    a.queue('Sapiens Starter', rulesVersion + 1);
    const refused = await a.expect('ranked_refused', 'ranked_refused for a stale client');
    eq('a stale rules version is refused with update_required', refused.reason, 'update_required');

    // 3. Both queue with a SHIPPED starter deck - neither sends a card list.
    a.queue('Sapiens Starter', rulesVersion);
    b.queue('Moonlight Coven Starter', rulesVersion);
    const [foundA, foundB] = await Promise.all([
      a.expect('ranked_match_found', 'ranked_match_found for A'),
      b.expect('ranked_match_found', 'ranked_match_found for B'),
    ]);
    ok('both players are paired into a server-run match', foundA.server_run === true && foundB.match_id === foundA.match_id,
      JSON.stringify({ a: foundA, b: foundB }));
    a.matchId = foundA.match_id;
    b.matchId = foundB.match_id;

    const created = (await pool.query('SELECT * FROM ranked_matches WHERE match_id = $1', [a.matchId])).rows[0];
    ok('the match is in Postgres before either client has joined',
      created && created.status === 'waiting' && created.deck_a.length === 40 && created.deck_b.length === 40,
      created ? `status=${created.status} deck_a=${created.deck_a.length}` : 'no row');
    ok('the seats in the database are the two real accounts',
      [created.seat_a_player_id, created.seat_b_player_id].sort().join() === [a.playerId, b.playerId].sort().join());

    // 4. Join, mulligan, and check the seats see different hands.
    await a.join();
    await b.join();
    const seatA = a.view.host_state.hand.length ? 'a' : (a.view.guest_state.hand.length ? 'b' : null);
    ok('each seat is told which side it is by what it can see', seatA !== null);
    const seatB = seatA === 'a' ? 'b' : 'a';
    const bots = { [seatA]: new Bot(a, seatA, defs), [seatB]: new Bot(b, seatB, defs) };
    const clients = { [seatA]: a, [seatB]: b };

    const opp = theirs(a.view, seatA);
    ok("a seat never receives the opponent's hand, only its size",
      Array.isArray(opp.hand) && opp.hand.length === 0 && opp.hand_size > 0,
      `hand=${JSON.stringify(opp.hand)} hand_size=${opp.hand_size}`);

    await a.mulligan();
    await b.mulligan();
    ok('both mulligans are accepted and the match becomes active',
      (await pool.query('SELECT status FROM ranked_matches WHERE match_id = $1', [a.matchId])).rows[0].status === 'active');

    // A choice is shown ONLY to the seat that must answer it, and while one is
    // open the other seat's every action is refused - so both bots are offered
    // the chance to clear one before either takes a turn.
    const clearChoices = async () => {
      let any = false;
      for (let guard = 0; guard < 20; guard++) {
        const cleared = (await bots[seatA].answerChoice()) || (await bots[seatB].answerChoice());
        if (!cleared) break;
        any = true;
      }
      return any;
    };

    // 5. Play. Partway through, A drops its socket and comes back on a new one.
    let reconnected = false;
    let stalled = 0;
    let stalledNote = '';
    while (!a.over && !b.over && a.view.turn_number <= MAX_TURNS) {
      if (!reconnected && a.view.turn_number >= 4) {
        const seqBefore = a.seq;
        a.close();
        await b.expect('opponent_disconnected', 'opponent_disconnected at B');
        ok('the opponent is told when a seat drops', b.opponentGone >= 1);
        await a.open();
        await a.login();                      // a fresh session, as a restarted client would
        const back = await a.join(seqBefore);
        ok('a reconnecting seat gets its view back and keeps its seat', back.seq >= seqBefore,
          `seq ${seqBefore} -> ${back.seq}`);
        await b.expect('opponent_reconnected', 'opponent_reconnected at B');
        ok('the opponent is told when the seat comes back', b.opponentBack >= 1);
        reconnected = true;
      }
      await clearChoices();
      if (a.over || b.over) break;
      const active = a.view.active_player_id === 'host' ? 'a' : 'b';
      const seqBefore = a.seq;
      await bots[active].takeTurn();
      if (a.seq === seqBefore) {
        // Neither a choice nor the active seat's turn moved the match: report
        // it rather than spinning out the turn budget.
        if (++stalled >= 3) {
          stalledNote = `stuck at turn ${a.view.turn_number}, seq ${a.seq}, active ${active}, `
            + `pending_choice A=${JSON.stringify((a.view.pending_choice || {}).id || null)} `
            + `B=${JSON.stringify((b.view.pending_choice || {}).id || null)}`;
          break;
        }
      } else stalled = 0;
    }

    const over = a.over || b.over;
    ok('the match reaches game over', !!over,
      over ? `end_reason=${over.end_reason}` : (stalledNote || `stopped at turn ${a.view.turn_number} of ${MAX_TURNS}`));
    if (over) {
      await Promise.all([a.expect('match_over', 'match_over at A'), b.expect('match_over', 'match_over at B')]).catch(() => {});
      ok('exactly one seat is told it won', (a.over.winner_is_me ? 1 : 0) + (b.over.winner_is_me ? 1 : 0) === 1,
        `A=${a.over.winner_is_me} B=${b.over.winner_is_me}`);

      const row = (await pool.query('SELECT * FROM ranked_matches WHERE match_id = $1', [a.matchId])).rows[0];
      eq('the stored match is finished', row.status, 'finished');
      ok('the stored result names a winning seat and a hash', !!row.winner_seat && !!row.final_state_hash,
        `winner_seat=${row.winner_seat} hash=${String(row.final_state_hash).slice(0, 12)}`);
      ok('the match facts for spec 002 are stored', row.facts && typeof row.facts === 'object' && Object.keys(row.facts).length > 0,
        JSON.stringify(row.facts || null).slice(0, 120));

      const acts = (await pool.query(
        'SELECT seq, seat, kind, state_hash FROM ranked_match_actions WHERE match_id = $1 ORDER BY seq', [a.matchId])).rows;
      ok('every accepted action is logged, numbered without a gap', acts.length > 0 && acts.every((r, i) => r.seq === i + 1),
        `${acts.length} actions`);
      ok('every logged action carries a state hash', acts.every((r) => !!r.state_hash));
      eq('the last logged hash is the final hash', acts.at(-1).state_hash, row.final_state_hash);

      const settled = (await pool.query(
        'SELECT player_id, won, outcome FROM ranked_settlements WHERE match_id = $1 ORDER BY player_id', [a.matchId])).rows;
      eq('both players are settled exactly once', settled.length, 2);
      ok('exactly one settlement is a win', settled.filter((r) => r.won).length === 1);
      const winner = a.over.winner_is_me ? a : b;
      const stored = settled.find((r) => r.player_id === winner.playerId);
      ok("the winner's stored outcome is the one their client was shown",
        winner.over.ranked_outcome && stored.outcome.rank_lp === winner.over.ranked_outcome.rank_lp,
        `stored=${JSON.stringify(stored.outcome.rank_lp)} client=${JSON.stringify((winner.over.ranked_outcome || {}).rank_lp)}`);
      const rows = (await pool.query('SELECT id, ranked_wins, ranked_losses FROM players ORDER BY id')).rows;
      ok('one player gained a win and the other a loss',
        rows.filter((r) => r.ranked_wins === 1).length === 1 && rows.filter((r) => r.ranked_losses === 1).length === 1,
        JSON.stringify(rows));

      // 6. A client cannot report its own result for a server-run match.
      a.send({ type: 'report_ranked_result', token: a.token, match_id: a.matchId, won: true });
      const ack = await a.expect('ranked_result_ack', 'ranked_result_ack');
      ok('a client-reported result is refused for a server-run match', ack.success === false, JSON.stringify(ack));
    }
    a.close(); b.close();

    // --- Match 2: a concede settles the other player, immediately.
    const c = new Client('C');
    const d = new Client('D');
    await c.open(); await d.open();
    await c.register(); await d.register();
    c.playerId = await playerIdOf(c.username);
    d.playerId = await playerIdOf(d.username);
    c.queue('Sapiens Starter', rulesVersion);
    d.queue('Junklings Starter', rulesVersion);
    const found2 = await Promise.all([c.expect('ranked_match_found', 'pairing for C'), d.expect('ranked_match_found', 'pairing for D')]);
    c.matchId = found2[0].match_id;
    d.matchId = found2[1].match_id;
    ok('a second match is paired while the first is finished', c.matchId && c.matchId !== a.matchId);
    await c.join(); await d.join();
    await c.mulligan(); await d.mulligan();
    c.concede();
    await Promise.all([c.expect('match_over', 'match_over at C'), d.expect('match_over', 'match_over at D')]);
    eq('conceding ends the match as a concession', c.over.end_reason, 'conceded');
    ok('the conceding player loses and the other wins', c.over.winner_is_me === false && d.over.winner_is_me === true,
      `C=${c.over.winner_is_me} D=${d.over.winner_is_me}`);
    const s2 = (await pool.query('SELECT player_id, won FROM ranked_settlements WHERE match_id = $1', [c.matchId])).rows;
    ok('the concession is settled once per player, the opponent credited',
      s2.length === 2 && s2.find((r) => r.player_id === d.playerId).won === true, JSON.stringify(s2));
    const dRow = (await pool.query('SELECT ranked_wins, rank_lp FROM players WHERE id = $1', [d.playerId])).rows[0];
    ok('the winner of the concession gained ladder progress', dRow.ranked_wins === 1 && dRow.rank_lp > 0, JSON.stringify(dRow));
    c.close(); d.close();

    // 7. Nothing in either match was audited as a refusal the server did not expect.
    const audit = (await pool.query('SELECT reason, count(*)::int AS n FROM ranked_match_audit GROUP BY reason ORDER BY reason')).rows;
    console.log(`\naudit rows: ${audit.map((r) => `${r.reason}=${r.n}`).join(' ') || 'none'}`);
    const refusals = [...a.refusals, ...b.refusals, ...c.refusals, ...d.refusals]
      .reduce((m, [k, n]) => m.set(k, (m.get(k) || 0) + n), new Map());
    console.log(`client refusals: ${[...refusals].map(([k, n]) => `${k}=${n}`).join(' ') || 'none'}`);
  } finally {
    killTree(relay.proc);
    await pool.end();
  }

  const failed = checks.filter((c) => !c.pass);
  console.log(`\n${checks.length - failed.length}/${checks.length} checks passed`);
  if (failed.length) {
    console.error('FAILED:\n' + failed.map((f) => `  - ${f.name}${f.detail ? ` (${f.detail})` : ''}`).join('\n'));
    process.exit(1);
  }
  console.log('PASS');
  process.exit(0);
}

main().catch((e) => { console.error(e); process.exit(1); });
