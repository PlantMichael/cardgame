'use strict';
// MatchManager against the REAL Godot match host with an in-memory store:
// seats, the log-before-ack command path, clocks, disconnects, forfeits,
// settlement hand-off and resume after a host restart. Needs GODOT_BIN.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { godotBin } = require('./helpers');
const { HostProcess } = require('../authoritative/host_process');
const { MatchManager } = require('../authoritative/match_manager');
const { MemoryStore } = require('../authoritative/memory_store');
const { loadCards, validateDeck } = require('../authoritative/decks');

const skip = godotBin() ? false : 'GODOT_BIN is not set';
const cards = loadCards();

function legalDeck(color, size = 30) {
  const pool = [...cards.values()].filter((c) => !c.is_token && (c.color === color || c.color === 'GENERIC'));
  pool.sort((x, y) => x.cost - y.cost || (x.id < y.id ? -1 : 1));
  const deck = [];
  for (const c of pool) {
    const copies = c.rarity === 'LEGENDARY' ? 1 : 2;
    for (let i = 0; i < copies && deck.length < size; i++) deck.push(c.id);
  }
  assert.equal(validateDeck(deck, color === 'GREEN' ? 0 : 1, cards).ok, true);
  return deck;
}

class FakeConn {
  constructor(name) { this.name = name; this.sent = []; this.closed = false; }
  send(o) { this.sent.push(o); }
  close() { this.closed = true; }
  of(type) { return this.sent.filter((m) => m.type === type); }
  last(type) { const l = this.of(type); return l[l.length - 1]; }
}

let host;
test.before(async () => {
  if (skip) return;
  host = new HostProcess({ log: { warn() {}, error() {} } });
  await host.start();
});
test.after(async () => { if (host) await host.stop(); });

function setup(overrides = {}) {
  let clock = 1_000_000;
  const store = new MemoryStore({
    decks: {
      '1:green': { faction_idx: 0, card_ids: legalDeck('GREEN') },
      '2:crimson': { faction_idx: 1, card_ids: legalDeck('CRIMSON') },
      '3:green': { faction_idx: 0, card_ids: legalDeck('GREEN') },
    },
  });
  const settled = [];
  const manager = new MatchManager({
    store, host, cards, now: () => clock,
    config: { turnSeconds: 10, mulliganSeconds: 10, graceSeconds: 5, ...overrides.config },
    settle: async (sess, result) => { settled.push({ id: sess.id, ...result }); return { 1: { rank: 'moved' }, 2: { rank: 'moved' } }; },
    log: { warn() {}, error() {} },
  });
  return { store, manager, settled, advance: (s) => { clock += s * 1000; }, now: () => clock };
}

let n = 0;
async function startedMatch(ctx) {
  const id = `rk_t${++n}`;
  const made = await ctx.manager.createMatch({ matchId: id, a: { playerId: 1, deckName: 'green' }, b: { playerId: 2, deckName: 'crimson' } });
  assert.equal(made.ok, true, JSON.stringify(made));
  const ca = new FakeConn('a');
  const cb = new FakeConn('b');
  await ctx.manager.handleMessage(1, { type: 'match_join', match_id: id }, ca);
  await ctx.manager.handleMessage(2, { type: 'match_join', match_id: id }, cb);
  return { id, ca, cb, first: made.firstSeat };
}
const cmd = (ctx, player, conn, id, seq, c) => ctx.manager.handleMessage(player, { type: 'match_command', match_id: id, client_seq: seq, cmd: c }, conn);

async function doMulligans(ctx, m) {
  await cmd(ctx, 1, m.ca, m.id, 1, { type: 'mulligan', card_uids: [] });
  await cmd(ctx, 2, m.cb, m.id, 1, { type: 'mulligan', card_uids: [] });
}

test('decks come from the database and are validated; clients cannot supply one', { skip }, async () => {
  const ctx = setup();
  assert.equal((await ctx.manager.createMatch({ matchId: 'x1', a: { playerId: 1, deckName: 'missing' }, b: { playerId: 2, deckName: 'crimson' } })).error, 'invalid_deck');
  ctx.store.decks['1:cheat'] = { faction_idx: 0, card_ids: Array(30).fill('g_001') };
  const r = await ctx.manager.createMatch({ matchId: 'x2', a: { playerId: 1, deckName: 'cheat' }, b: { playerId: 2, deckName: 'crimson' } });
  assert.equal(r.error, 'invalid_deck');
  assert.equal(r.detail, 'deck_too_many_copies');
  ctx.store.decks['1:wrong'] = { faction_idx: 1, card_ids: legalDeck('GREEN') };
  assert.equal((await ctx.manager.createMatch({ matchId: 'x3', a: { playerId: 1, deckName: 'wrong' }, b: { playerId: 2, deckName: 'crimson' } })).detail, 'deck_wrong_faction');
  assert.equal(ctx.store.matches.size, 0, 'no match row for a refused deck');
});

test('a shipped starter deck can be queued by name without being saved', { skip }, async () => {
  const ctx = setup();
  const r = await ctx.manager.createMatch({ matchId: 'st1', a: { playerId: 1, deckName: 'Sapiens Starter' }, b: { playerId: 2, deckName: 'crimson' } });
  assert.equal(r.ok, true, JSON.stringify(r));
});

test('join gives each seat only its own view; both seated -> active', { skip }, async () => {
  const ctx = setup();
  const m = await startedMatch(ctx);
  const va = m.ca.last('match_view');
  const vb = m.cb.last('match_view');
  assert.equal(va.you, 'host');
  assert.equal(vb.you, 'guest');
  assert.ok(va.view.host_state.hand.length > 0 && va.view.guest_state.hand.length === 0);
  assert.ok(vb.view.guest_state.hand.length > 0 && vb.view.host_state.hand.length === 0);
  assert.equal(ctx.store.matches.get(m.id).status, 'active');
  assert.ok(m.ca.last('match_clock').clock.mulligan_remaining_s > 0, 'both seats are told the mulligan clock when the match starts');
  assert.ok(m.cb.last('match_clock').clock.mulligan_remaining_s > 0);
});

test('commands are logged BEFORE they are acknowledged or shown', { skip }, async () => {
  const ctx = setup();
  const order = [];
  const orig = ctx.store.appendAction.bind(ctx.store);
  ctx.store.appendAction = async (a) => { order.push(`log:${a.seq}`); return orig(a); };
  const m = await startedMatch(ctx);
  const send = m.ca.send.bind(m.ca);
  m.ca.send = (o) => { if (o.type === 'match_ack') order.push(`ack:${o.client_seq}`); if (o.type === 'match_view') order.push('view'); send(o); };
  await cmd(ctx, 1, m.ca, m.id, 1, { type: 'mulligan', card_uids: [] });
  const i = (s) => order.indexOf(s);
  assert.ok(i('log:1') >= 0 && i('ack:1') > i('log:1'), `order was ${order}`);
  assert.equal(ctx.store.actions.get(m.id).length, 1);
  assert.match(ctx.store.actions.get(m.id)[0].state_hash, /^[0-9a-f]{64}$/);
});

test('refusals: illegal, duplicate, wrong player, wrong match - all generic, none logged', { skip }, async () => {
  const ctx = setup();
  const m = await startedMatch(ctx);
  await doMulligans(ctx, m);
  const logged = ctx.store.actions.get(m.id).length;
  const first = m.first === 'a' ? [1, m.ca] : [2, m.cb];
  const second = m.first === 'a' ? [2, m.cb] : [1, m.ca];
  await cmd(ctx, second[0], second[1], m.id, 2, { type: 'end_turn' });
  assert.equal(second[1].last('match_error').reason, 'illegal', 'out of turn');
  await cmd(ctx, first[0], first[1], m.id, 2, { type: 'end_turn' });
  assert.equal(first[1].of('match_ack').length >= 1, true);
  await cmd(ctx, first[0], first[1], m.id, 2, { type: 'end_turn' });
  assert.equal(first[1].last('match_error').reason, 'duplicate', 'a replayed client_seq');
  // Someone who is not in the match, and a match that does not exist, look identical.
  const stranger = new FakeConn('s');
  await ctx.manager.handleMessage(99, { type: 'match_command', match_id: m.id, client_seq: 1, cmd: { type: 'end_turn' } }, stranger);
  const nowhere = new FakeConn('n');
  await ctx.manager.handleMessage(99, { type: 'match_command', match_id: 'rk_nope', client_seq: 1, cmd: { type: 'end_turn' } }, nowhere);
  assert.equal(stranger.last('match_error').reason, 'unknown_match');
  assert.equal(nowhere.last('match_error').reason, 'unknown_match');
  assert.equal(ctx.store.actions.get(m.id).length, logged + 1, 'only the one accepted command was logged');
  assert.ok(ctx.store.auditLog.some((a) => a.reason === 'not_a_participant'));
  // Malformed and hostile messages are refused before the rules see them.
  for (const raw of [{ type: 'match_command', match_id: m.id, client_seq: 9, cmd: { type: 'set_state' } }, { type: 'match_command', match_id: '../x', client_seq: 1, cmd: { type: 'end_turn' } }, null, 5, { type: 'x' }]) {
    const c = new FakeConn('h');
    await ctx.manager.handleMessage(1, raw, c);
    assert.equal(c.last('match_error').reason, 'invalid');
  }
});

test('client-supplied extra fields never reach the rules', { skip }, async () => {
  const ctx = setup();
  const m = await startedMatch(ctx);
  await doMulligans(ctx, m);
  const [p, c] = m.first === 'a' ? [1, m.ca] : [2, m.cb];
  await cmd(ctx, p, c, m.id, 2, { type: 'end_turn', winner: 'a', actor: 'guest', hero_health: 99 });
  const row = ctx.store.actions.get(m.id).slice(-1)[0];
  assert.deepEqual(row.command, { type: 'end_turn' }, 'the logged command carries only its allowed fields');
});

test('a second connection takes the seat over; the old one is ignored', { skip }, async () => {
  const ctx = setup();
  const m = await startedMatch(ctx);
  const fresh = new FakeConn('a2');
  await ctx.manager.handleMessage(1, { type: 'match_join', match_id: m.id }, fresh);
  assert.equal(m.ca.closed, true, 'the older connection was closed');
  assert.ok(fresh.last('match_view'));
  const before = ctx.store.actions.get(m.id).length;
  await cmd(ctx, 1, m.ca, m.id, 1, { type: 'mulligan', card_uids: [] });
  assert.equal(ctx.store.actions.get(m.id).length, before, 'the old connection can no longer act');
  await cmd(ctx, 1, fresh, m.id, 1, { type: 'mulligan', card_uids: [] });
  assert.equal(ctx.store.actions.get(m.id).length, before + 1);
});

test('turn clock: expiry applies defaults and logs timeout_default; 3 in a row forfeits', { skip }, async () => {
  const ctx = setup();
  const m = await startedMatch(ctx);
  await doMulligans(ctx, m);
  const firstLetter = m.first;
  const loserPlayer = firstLetter === 'a' ? 1 : 2;
  ctx.advance(11);
  await ctx.manager.tick();
  const log = ctx.store.actions.get(m.id);
  assert.equal(log[log.length - 1].kind, 'timeout_default');
  assert.equal(log[log.length - 1].seat, firstLetter, 'the responsible seat was timed out');
  const view = (firstLetter === 'a' ? m.cb : m.ca).last('match_view');
  assert.ok(view.events.some((e) => e.type === 'turn_end'), 'its turn was ended');
  // The OTHER seat now owns the clock; letting it lapse repeatedly forfeits it eventually.
  for (let i = 0; i < 6 && !ctx.settled.length; i++) { ctx.advance(11); await ctx.manager.tick(); }
  assert.equal(ctx.settled.length, 1);
  assert.equal(ctx.settled[0].endReason, 'forfeit_timeout');
  assert.ok(loserPlayer);
});

test('mulligan clock: an unanswered mulligan keeps the hand', { skip }, async () => {
  const ctx = setup();
  const m = await startedMatch(ctx);
  await cmd(ctx, 1, m.ca, m.id, 1, { type: 'mulligan', card_uids: [] });
  ctx.advance(11);
  await ctx.manager.tick();
  const log = ctx.store.actions.get(m.id);
  assert.ok(log.some((a) => a.kind === 'timeout_default' && a.seat === 'b'), 'seat b was defaulted');
  const sess = ctx.manager.sessions.get(m.id);
  assert.deepEqual(sess.views.a.mulligan_pending, {}, 'the mulligan phase is over');
});

test('disconnect: grace, rejoin resumes; expiry forfeits; both gone abandons with no settlement', { skip }, async () => {
  const ctx = setup();
  const m = await startedMatch(ctx);
  await doMulligans(ctx, m);
  ctx.manager.onClose(m.ca);
  assert.ok(m.cb.last('opponent_disconnected'));
  ctx.advance(3);
  await ctx.manager.tick();
  const back = new FakeConn('a3');
  await ctx.manager.handleMessage(1, { type: 'match_join', match_id: m.id }, back);
  assert.ok(back.last('match_view'), 'rejoined within grace and got the current state');
  assert.ok(m.cb.last('opponent_reconnected'));
  assert.equal(ctx.settled.length, 0);

  // Past grace: a forfeit loss for the one who stayed away.
  ctx.manager.onClose(m.cb);
  ctx.advance(6);
  await ctx.manager.tick();
  assert.equal(ctx.settled.length, 1);
  assert.equal(ctx.settled[0].endReason, 'forfeit_disconnect');
  assert.equal(ctx.settled[0].winner, 'a', 'seat a stayed; seat b forfeited');
  assert.equal(back.last('match_over').winner_is_me, true);

  // Both gone: abandoned, nothing settled.
  const ctx2 = setup();
  const m2 = await startedMatch(ctx2);
  await doMulligans(ctx2, m2);
  ctx2.manager.onClose(m2.ca);
  ctx2.manager.onClose(m2.cb);
  ctx2.advance(6);
  await ctx2.manager.tick();
  assert.equal(ctx2.settled.length, 0, 'abandoned matches settle nothing');
  assert.equal(ctx2.store.matches.get(m2.id).end_reason, 'abandoned');
});

test('concede ends the match at once and settles once, from the server\'s own result', { skip }, async () => {
  const ctx = setup();
  const m = await startedMatch(ctx);
  await doMulligans(ctx, m);
  await ctx.manager.handleMessage(1, { type: 'match_concede', match_id: m.id }, m.ca);
  assert.equal(ctx.settled.length, 1);
  assert.deepEqual({ ...ctx.settled[0], facts: undefined }, { id: m.id, winner: 'b', endReason: 'conceded', facts: undefined });
  const facts = ctx.settled[0].facts;
  assert.ok(facts && facts.seats.a.deck_cards.length > 0 && facts.seats.b.deck_cards.length > 0, 'the host verified facts reach settlement');
  assert.deepEqual(ctx.store.matches.get(m.id).facts, facts, 'and are stored with the match for the stats database');
  assert.equal(m.cb.last('match_over').winner_is_me, true);
  assert.equal(m.ca.last('match_over').winner_is_me, false);
  assert.deepEqual(m.ca.last('match_over').ranked_outcome, { rank: 'moved' });
  // Nothing more is accepted, and settlement cannot run twice.
  await ctx.manager.handleMessage(2, { type: 'match_concede', match_id: m.id }, m.cb);
  await cmd(ctx, 2, m.cb, m.id, 5, { type: 'end_turn' });
  assert.equal(ctx.settled.length, 1);
  assert.equal(ctx.store.matches.get(m.id).status, 'finished');
});

test('capacity: no new matches past the live ceiling', { skip }, async () => {
  const ctx = setup({ config: { maxLiveMatches: 1 } });
  await startedMatch(ctx);
  const r = await ctx.manager.createMatch({ matchId: 'rk_full', a: { playerId: 3, deckName: 'green' }, b: { playerId: 2, deckName: 'crimson' } });
  assert.equal(r.error, 'busy');
});

test('resume after a host restart replays the log and the match continues', { skip }, async () => {
  const ctx = setup();
  const m = await startedMatch(ctx);
  await doMulligans(ctx, m);
  const [p, c] = m.first === 'a' ? [1, m.ca] : [2, m.cb];
  await cmd(ctx, p, c, m.id, 2, { type: 'end_turn' });
  const hashBefore = ctx.manager.sessions.get(m.id).lastHash;
  const seqBefore = ctx.manager.sessions.get(m.id).seq;

  const ready = new Promise((r) => host.once('ready', r));
  host.proc.kill();
  await ready;
  await new Promise((r) => setTimeout(r, 500));
  const sess = ctx.manager.sessions.get(m.id);
  assert.equal(sess.hostDown, false, 'the match was restored');
  assert.equal(sess.status, 'active');
  assert.equal(sess.lastHash, hashBefore, 'replay reached exactly the logged state');
  assert.equal(sess.seq, seqBefore);
  // And play goes on.
  const [p2, c2] = m.first === 'a' ? [2, m.cb] : [1, m.ca];
  await cmd(ctx, p2, c2, m.id, 3, { type: 'end_turn' });
  assert.equal(ctx.store.actions.get(m.id).length, seqBefore + 1);
});

test('a log that does not replay to its last hash voids the match with no rank change', { skip }, async () => {
  const ctx = setup();
  const m = await startedMatch(ctx);
  await doMulligans(ctx, m);
  const rows = ctx.store.actions.get(m.id);
  rows[rows.length - 1].state_hash = 'f'.repeat(64); // corrupt the last logged hash
  await ctx.manager.resume();
  assert.equal(ctx.store.matches.get(m.id).status, 'voided');
  assert.equal(ctx.settled.length, 0);
  assert.ok(m.ca.last('match_voided'));
});
