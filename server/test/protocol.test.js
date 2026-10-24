'use strict';
// Match host protocol (contracts/match-host-ipc.md): authentication, lifecycle,
// ordering. Needs GODOT_BIN; skipped without it.
const test = require('node:test');
const assert = require('node:assert/strict');
const net = require('net');
const { godotBin, hostSession, startMatchHost, buildDeck } = require('./helpers');

const skip = godotBin() ? false : 'GODOT_BIN is not set';

test('an unauthenticated or wrongly authenticated connection is dropped', { skip }, async () => {
  const host = await startMatchHost();
  try {
    for (const first of [{ op: 'create', rid: 1 }, { op: 'hello', rid: 1, secret: 'wrong' }, { op: 'hello', rid: 1 }]) {
      const s = net.connect(host.port, '127.0.0.1');
      await new Promise((r) => s.once('connect', r));
      s.write(JSON.stringify(first) + '\n');
      const got = await new Promise((resolve) => {
        let data = '';
        s.on('data', (d) => { data += d; });
        s.on('close', () => resolve(data));
        setTimeout(() => resolve('timeout'), 4000);
      });
      assert.equal(got, '', `connection should close silently for ${JSON.stringify(first)}`);
      s.destroy();
    }
    const g = net.connect(host.port, '127.0.0.1');
    await new Promise((r) => g.once('connect', r));
    g.write('not json at all\n');
    const closed = await new Promise((resolve) => { g.on('close', () => resolve(true)); setTimeout(() => resolve(false), 4000); });
    assert.equal(closed, true, 'garbage closes the connection');
    g.destroy();
  } finally { host.stop(); }
});

test('create, views, mulligan phase, play', { skip }, async () => {
  const s = await hostSession();
  try {
    const made = await s.create('m1');
    assert.equal(made.ok, true, JSON.stringify(made).slice(0, 300));
    assert.equal(made.seq, 0);
    assert.match(made.state_hash, /^[0-9a-f]{64}$/);
    assert.ok(made.views.a.host_state.hand.length > 0, 'seat a sees its own hand');
    assert.equal(made.views.a.guest_state.hand.length, 0, 'and not the other');
    assert.ok(made.views.b.guest_state.hand.length > 0);
    assert.equal(made.views.b.host_state.hand.length, 0);
    assert.deepEqual(made.views.a.mulligan_pending, { host: true, guest: true });

    const early = await s.cmd('m1', 'a', { type: 'end_turn' }, 0);
    assert.equal(early.ok, false);
    assert.match(early.error, /mulligan/);

    const badUid = await s.cmd('m1', 'a', { type: 'mulligan', card_uids: ['nope'] }, 0);
    assert.equal(badUid.ok, false, 'a mulligan naming a card not in hand is refused');

    const keepA = await s.cmd('m1', 'a', { type: 'mulligan', card_uids: [] }, 0);
    assert.equal(keepA.ok, true);
    assert.equal(keepA.seq, 1);
    const twice = await s.cmd('m1', 'a', { type: 'mulligan', card_uids: [] }, 1);
    assert.equal(twice.ok, false, 'no second mulligan');
    const waiting = await s.cmd('m1', 'a', { type: 'end_turn' }, 1);
    assert.equal(waiting.ok, false, 'turn actions wait for the other seat to mulligan');

    const hand = made.views.b.guest_state.hand;
    const swapB = await s.cmd('m1', 'b', { type: 'mulligan', card_uids: [hand[0].uid] }, 1);
    assert.equal(swapB.ok, true);
    assert.equal(swapB.views.b.guest_state.hand.length, hand.length, 'a swap keeps the hand size');
    assert.equal(swapB.views.b.guest_state.hand.some((c) => c.uid === hand[0].uid), false, 'the swapped card left the hand');
    assert.deepEqual(swapB.views.a.mulligan_pending, {});

    const wrongSeat = await s.cmd('m1', 'b', { type: 'end_turn' }, 2);
    assert.equal(wrongSeat.ok, false);
    const ok = await s.cmd('m1', 'a', { type: 'end_turn' }, 2);
    assert.equal(ok.ok, true);
    assert.equal(ok.seq, 3);
    assert.ok(ok.events.a.some((e) => e.type === 'turn_end'));
    const view = await s.client.request('view', { match_id: 'm1', seat: 'a' });
    assert.equal(view.seq, 3, 'a refused command did not advance the sequence');
  } finally { s.stop(); }
});

test('sequence numbers fail closed: stale and duplicate commands are refused', { skip }, async () => {
  const s = await hostSession();
  try {
    await s.create('m2');
    await s.cmd('m2', 'a', { type: 'mulligan', card_uids: [] }, 0);
    await s.cmd('m2', 'b', { type: 'mulligan', card_uids: [] }, 1);
    const stale = await s.cmd('m2', 'a', { type: 'end_turn' }, 1);
    assert.equal(stale.error, 'stale_seq');
    const fine = await s.cmd('m2', 'a', { type: 'end_turn' }, 2);
    assert.equal(fine.ok, true);
    const replayed = await s.cmd('m2', 'a', { type: 'end_turn' }, 2);
    assert.equal(replayed.error, 'stale_seq', 'resending the same command is refused');
  } finally { s.stop(); }
});

test('create validates rules version, decks, tokens and ids', { skip }, async () => {
  const s = await hostSession();
  try {
    const rv = s.RULES_VERSION;
    const base = { seed: 1, first_seat: 'a', rules_version: rv };
    assert.equal((await s.client.request('create', { ...base, match_id: 'v', deck_a: [], deck_b: [], rules_version: 999 })).error, 'rules_version_mismatch');
    assert.equal((await s.client.request('create', { ...base, match_id: 'd', deck_a: ['no_such_card'], deck_b: ['g_001'] })).error, 'invalid_deck');
    assert.equal((await s.client.request('create', { ...base, match_id: 't', deck_a: ['cr_001t'], deck_b: ['g_001'] })).error, 'invalid_deck', 'tokens are not deck cards');
    assert.equal((await s.create('same')).ok, true);
    assert.equal((await s.create('same')).error, 'invalid_match_id', 'a match id cannot be reused');
    assert.equal((await s.create('')).error, 'invalid_match_id');
    assert.equal((await s.client.request('create', { ...base, match_id: 'f', first_seat: 'c', deck_a: buildDeck(), deck_b: buildDeck() })).error, 'invalid_first_seat');
    assert.equal((await s.cmd('nope', 'a', { type: 'end_turn' })).error, 'unknown_match');
  } finally { s.stop(); }
});

test('replay reproduces a live match exactly, step by step', { skip }, async () => {
  const s = await hostSession();
  try {
    await s.create('live', { seed: 777, first: 'b' });
    const log = [];
    const hashes = [];
    const step = async (seat, cmd) => {
      const r = await s.cmd('live', seat, cmd);
      assert.equal(r.ok, true, JSON.stringify(r).slice(0, 200));
      log.push({ seat, kind: 'command', cmd });
      hashes.push(r.state_hash);
    };
    await step('a', { type: 'mulligan', card_uids: [] });
    await step('b', { type: 'mulligan', card_uids: [] });
    for (let i = 0; i < 6; i++) await step(i % 2 === 0 ? 'b' : 'a', { type: 'end_turn' });
    const live = await s.client.request('view', { match_id: 'live', seat: 'a' });
    const deckA = buildDeck();
    const deckB = buildDeck(['crimson', 'generic']);
    const rep = await s.client.request('replay', {
      match_id: 'replayed', seed: 777, first_seat: 'b', rules_version: s.RULES_VERSION,
      deck_a: deckA, deck_b: deckB, actions: log, step_hashes: true,
    });
    assert.equal(rep.ok, true, JSON.stringify(rep).slice(0, 300));
    assert.deepEqual(rep.step_hashes, hashes, 'every step hash matches');
    assert.equal(rep.state_hash, live.state_hash);
    assert.equal(rep.seq, log.length);
    const bad = await s.client.request('replay', {
      match_id: 'tampered', seed: 777, first_seat: 'b', rules_version: s.RULES_VERSION,
      deck_a: deckA, deck_b: deckB,
      actions: [{ seat: 'a', kind: 'command', cmd: { type: 'attack', attacker_instance_id: 'x' } }],
    });
    assert.equal(bad.ok, false);
    assert.equal(bad.error, 'replay_refused');
  } finally { s.stop(); }
});

test('timeouts: an unanswered mulligan keeps the hand; a turn timeout ends the turn', { skip }, async () => {
  const s = await hostSession();
  try {
    await s.create('t1');
    const a = await s.client.request('timeout', { match_id: 't1', seat: 'a' });
    assert.equal(a.ok, true);
    assert.equal(a.kind, 'timeout_default');
    await s.client.request('timeout', { match_id: 't1', seat: 'b' });
    const t = await s.client.request('timeout', { match_id: 't1', seat: 'a' });
    assert.equal(t.ok, true);
    assert.ok(t.events.a.some((e) => e.type === 'turn_end'), 'the actor\'s turn was ended');
  } finally { s.stop(); }
});
