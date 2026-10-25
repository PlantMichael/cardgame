'use strict';
// Frame budgets (spec 003 T074, the security review of the new surface).
//
// Two separate limits, for two separate costs:
//   * per socket, in relay_wire: spent BEFORE the session lookup, so a flood of
//     match frames from an unauthenticated socket is not a flood of database
//     queries and audit rows.
//   * per seat, in the manager: every message type, because a join costs a host
//     round trip and a ping costs a reply - not only commands.
const test = require('node:test');
const assert = require('node:assert/strict');
const { Authoritative } = require('../authoritative/relay_wire');
const { MatchManager } = require('../authoritative/match_manager');
const { MemoryStore } = require('../authoritative/memory_store');
const { FRAMES_PER_SECOND, ACTIONS_PER_SECOND } = require('../authoritative/protocol');

test('a socket can only spend its frame budget, and each socket has its own', () => {
  const a = new Authoritative({ pool: null, manager: { sessions: new Map() } });
  const ws = {};
  let allowed = 0;
  for (let i = 0; i < FRAMES_PER_SECOND * 3; i++) if (a.allowFrame(ws)) allowed += 1;
  assert.equal(allowed, FRAMES_PER_SECOND, 'the burst is the budget, not more');
  assert.equal(a.allowFrame({}), true, 'a different socket starts with its own budget');
});

test('a verified token is cached for that socket only, and only that token', () => {
  const a = new Authoritative({ pool: null, manager: { sessions: new Map() } });
  const ws = {};
  assert.equal(a.cachedPlayer(ws, 'tok'), null);
  a.rememberPlayer(ws, 'tok', 42);
  assert.equal(a.cachedPlayer(ws, 'tok'), 42);
  assert.equal(a.cachedPlayer(ws, 'other-token'), null, 'another token is looked up again');
  assert.equal(a.cachedPlayer({}, 'tok'), null, 'another socket is looked up again');
});

// A manager with one match and a host that answers everything, so the only
// thing that can refuse a message is the rate limit.
function managerWithMatch(now) {
  const views = { a: { active_player_id: 'host', turn_number: 1, pending_choice: {}, mulligan_pending: {} },
    b: { active_player_id: 'host', turn_number: 1, pending_choice: {}, mulligan_pending: {} } };
  const host = {
    ready: true, rulesVersion: 1, requests: [],
    request: async (op) => {
      host.requests.push(op);
      if (op === 'view') return { ok: true, seq: 0, view: views.a, state_hash: 'h' };
      return { ok: true, seq: 1, state_hash: 'h', views, events: { a: [], b: [] } };
    },
  };
  const store = new MemoryStore({ decks: { 'p1:d': { faction_idx: 0, card_ids: ['x'] }, 'p2:d': { faction_idx: 0, card_ids: ['x'] } } });
  const cards = new Map([['x', { id: 'x', color: 'GREEN', rarity: 'COMMON', card_type: 'CREATURE', cost: 1 }]]);
  const manager = new MatchManager({ store, host, cards, settle: null, now, log: { warn() {}, error() {} } });
  return { manager, host, store };
}

test('pings and joins spend the seat budget too', async () => {
  let t = 1000;
  const { manager, host } = managerWithMatch(() => t);
  const created = await manager.createMatch({ matchId: 'rk_1', a: { playerId: 'p1', deckName: 'd' }, b: { playerId: 'p2', deckName: 'd' } });
  assert.equal(created.ok, true, JSON.stringify(created));

  const sent = [];
  const conn = { send: (o) => sent.push(o), close() {} };
  for (let i = 0; i < ACTIONS_PER_SECOND * 2; i++) {
    await manager.handleMessage('p1', { type: 'match_ping', match_id: 'rk_1' }, conn);
  }
  const clocks = sent.filter((m) => m.type === 'match_clock').length;
  const limited = sent.filter((m) => m.type === 'match_error' && m.reason === 'rate_limited').length;
  assert.equal(clocks, ACTIONS_PER_SECOND, 'the seat answers its budget worth of pings');
  assert.equal(limited, ACTIONS_PER_SECOND, 'the rest are refused as rate_limited');

  // The budget refills with time, and a join costs a token (and a host view).
  t += 1000;
  host.requests.length = 0;
  await manager.handleMessage('p1', { type: 'match_join', match_id: 'rk_1' }, conn);
  assert.ok(host.requests.includes('view'), 'the join was served');
  t += 1000;
  for (let i = 0; i < ACTIONS_PER_SECOND + 5; i++) {
    await manager.handleMessage('p1', { type: 'match_join', match_id: 'rk_1' }, conn);
  }
  assert.ok(sent.filter((m) => m.type === 'match_error' && m.reason === 'rate_limited').length > ACTIONS_PER_SECOND,
    'a join flood is rate-limited rather than hammering the host');
});
