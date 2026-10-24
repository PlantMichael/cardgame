'use strict';
// The relay glue: flag handling, connection adapters, size cap and routing.
const test = require('node:test');
const assert = require('node:assert/strict');
const { Authoritative, isEnabled, configFromEnv } = require('../authoritative/relay_wire');
const { MAX_FRAME_BYTES } = require('../authoritative/protocol');

function fakeManager() {
  const calls = [];
  return {
    calls,
    sessions: new Map([['rk_known', {}]]),
    createMatch: async (a) => { calls.push(['create', a]); return { ok: true }; },
    handleMessage: async (pid, msg, conn) => { calls.push(['msg', pid, msg, conn]); },
    onClose: (conn) => calls.push(['close', conn]),
  };
}

test('the flag is off unless explicitly set', () => {
  assert.equal(isEnabled({}), false);
  assert.equal(isEnabled({ RANKED_AUTHORITATIVE: '0' }), false);
  assert.equal(isEnabled({ RANKED_AUTHORITATIVE: '1' }), true);
});

test('only match_* messages are routed, and oversize frames are flagged', () => {
  const a = new Authoritative({ pool: null, manager: fakeManager() });
  for (const t of ['match_join', 'match_command', 'match_mulligan', 'match_concede', 'match_ping']) assert.equal(a.isMatchMessage(t), true);
  for (const t of ['relay', 'queue_ranked', 'report_ranked_result', 'match_admin']) assert.equal(a.isMatchMessage(t), false);
  assert.equal(a.frameTooLarge('x'.repeat(MAX_FRAME_BYTES + 1)), true);
  assert.equal(a.frameTooLarge('x'.repeat(100)), false);
});

test('a socket gets one stable adapter, and closing it reaches the manager', async () => {
  const m = fakeManager();
  const a = new Authoritative({ pool: null, manager: m });
  const ws = { close() {} };
  const sent = [];
  const send = (w, o) => sent.push(o);
  await a.route(7, { type: 'match_ping', match_id: 'x' }, ws, send);
  await a.route(7, { type: 'match_ping', match_id: 'x' }, ws, send);
  assert.equal(m.calls[0][3], m.calls[1][3], 'same adapter both times');
  m.calls[0][3].send({ hello: 1 });
  assert.deepEqual(sent, [{ hello: 1 }]);
  a.onClose(ws);
  assert.equal(m.calls.at(-1)[0], 'close');
  a.onClose({}); // a socket that never joined a match is ignored
  assert.equal(m.calls.length, 3);
});

test('pairing passes only player ids and deck names; ownership follows the manager', async () => {
  const m = fakeManager();
  const a = new Authoritative({ pool: null, manager: m });
  await a.pair('rk_1', { playerId: 1, deckName: 'g', rating: 9999, seed: 5 }, { playerId: 2, deckName: 'c' });
  assert.deepEqual(m.calls[0][1], { matchId: 'rk_1', a: { playerId: 1, deckName: 'g' }, b: { playerId: 2, deckName: 'c' } });
  assert.equal(a.owns('rk_known'), true);
  assert.equal(a.owns('rk_other'), false);
});

test('operator settings come from the environment and ignore junk', () => {
  assert.deepEqual(configFromEnv({}), {});
  assert.deepEqual(configFromEnv({ RANKED_MAX_LIVE_MATCHES: '40', RANKED_TURN_SECONDS: '60' }), { maxLiveMatches: 40, turnSeconds: 60 });
  assert.deepEqual(configFromEnv({ RANKED_MAX_LIVE_MATCHES: 'lots', RANKED_TURN_SECONDS: '-5', RANKED_GRACE_SECONDS: '0' }), {});
});
