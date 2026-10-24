'use strict';
// SC-001/SC-002: a modified client can only send commands; none of these may
// change the match. Each case is applied to a live match and the full state
// hash is compared before and after.
const test = require('node:test');
const assert = require('node:assert/strict');
const net = require('net');
const { godotBin, hostSession, startMatchHost, buildDeck } = require('./helpers');

const skip = godotBin() ? false : 'GODOT_BIN is not set';

async function readyMatch(s, id) {
  await s.create(id, { seed: 99, first: 'a' });
  let r = await s.cmd(id, 'a', { type: 'mulligan', card_uids: [] }, 0);
  assert.equal(r.ok, true);
  r = await s.cmd(id, 'b', { type: 'mulligan', card_uids: [] }, 1);
  assert.equal(r.ok, true);
  return r;
}

test('200+ cheating attempts change nothing', { skip }, async () => {
  const s = await hostSession();
  try {
    const ready = await readyMatch(s, 'c1');
    const handA = ready.views.a.host_state.hand;
    const handB = ready.views.b.guest_state.hand;
    const hashOf = async () => (await s.client.request('view', { match_id: 'c1', seat: 'a' })).state_hash;
    const baseline = await hashOf();
    const seqNow = ready.seq;

    // Each case: [label, seat, cmd, expectSeqOverride?]
    const cases = [];
    const add = (label, seat, cmd, seq) => cases.push({ label, seat, cmd, seq: seq === undefined ? seqNow : seq });

    // 1. Out of turn: seat b acts while it is a's turn.
    for (const type of ['end_turn', 'play_creature', 'play_stratagem', 'attack', 'pilot', 'concede_not']) {
      for (const card of handB.slice(0, 4)) {
        add(`b out of turn: ${type}`, 'b', { type, card_uid: card.uid, attacker_instance_id: 'x', pilot_instance_id: 'x', target_instance_id: 'y' });
      }
    }
    // 2. Playing a card from the OTHER seat's hand (uids leaked by guessing).
    for (const card of handB.slice(0, 5)) add('a plays b\'s card', 'a', { type: 'play_creature', card_uid: card.uid, at_index: -1 });
    for (const card of handA.slice(0, 5)) add('b plays a\'s card', 'b', { type: 'play_creature', card_uid: card.uid, at_index: -1 });
    // 3. Guessed / fabricated uids and ids.
    for (let i = 1; i <= 30; i++) add('fabricated uid', 'a', { type: 'play_creature', card_uid: `host-c${200 + i}`, at_index: -1 });
    for (let i = 0; i < 20; i++) add('fabricated attacker', 'a', { type: 'attack', attacker_instance_id: `g_001#host${900 + i}`, target_player_id: 'guest' });
    // 4. Forged actor: b claims to be the host (a) - the host must overwrite it.
    for (const type of ['end_turn', 'concede_x']) add('forged actor host', 'b', { type, actor: 'host' });
    add('forged actor in answer', 'b', { type: 'answer_choice', actor: 'host', choice_id: 'choice-1', selection: '' });
    add('forged actor plays', 'b', { type: 'play_creature', actor: 'host', card_uid: handA[0].uid, at_index: -1 });
    // 5. Forged results / extra fields riding along on a legal-looking command.
    for (const extra of [{ winner: 'a' }, { winner_id: 'host' }, { won: true }, { hero_health: 99 }, { game_over: true }, { current_phase: 3 }, { rng: 1 }, { state_hash: 'x' }]) {
      add(`extra field ${Object.keys(extra)[0]}`, 'b', { type: 'end_turn', ...extra });
    }
    // 6. Malformed / hostile command bodies.
    const junk = [null, 0, 1, 'end_turn', [], {}, { type: '' }, { type: null }, { type: 5 }, { type: 'END_TURN' }, { type: 'end_turn ' },
      { type: 'execute' }, { type: 'set_state' }, { type: 'draw' }, { type: 'concede\0' }, { type: ['end_turn'] }, { type: { x: 1 } },
      { type: '../../etc/passwd' }, { type: 'answer_choice' }, { type: 'mulligan' }, { type: 'attack' }];
    for (const j of junk) for (const seat of ['a', 'b']) add(`junk command ${JSON.stringify(j)}`, seat, j);
    // 7. Answering choices that do not exist.
    for (const id of ['', 'choice-1', 'choice-0', 'choice-9999', 'x', null, 7]) {
      for (const seat of ['a', 'b']) add('answer with no choice open', seat, { type: 'answer_choice', choice_id: id, selection: 'anything' });
    }
    // 8. Second mulligans and mulligans of fabricated cards.
    for (const seat of ['a', 'b']) {
      add('second mulligan empty', seat, { type: 'mulligan', card_uids: [] });
      add('second mulligan with cards', seat, { type: 'mulligan', card_uids: [(seat === 'a' ? handA : handB)[0].uid] });
      add('mulligan fabricated', seat, { type: 'mulligan', card_uids: ['x', 'y'] });
    }
    // 9. Pilot / attack with other seat's pieces and heroes.
    for (const t of ['host', 'guest', '', 'a', 'b']) add('attack hero without attacker', 'a', { type: 'attack', attacker_instance_id: '', target_player_id: t });
    for (const t of ['x', '', 'guest#', null]) add('pilot nothing', 'a', { type: 'pilot', pilot_instance_id: t, target_instance_id: t });
    // 10. Stale sequence numbers on otherwise-legal commands.
    for (const seq of [seqNow - 2, seqNow - 1, seqNow + 1, seqNow + 5, 0, -1, 'x']) add(`stale seq ${seq}`, 'a', { type: 'end_turn' }, seq);
    // 11. Hostile argument types on legal-looking commands.
    for (const idx of [-5, 999, 1e9, 'x', null, [], {}]) {
      add(`out-of-turn play with at_index ${JSON.stringify(idx)}`, 'b', { type: 'play_creature', card_uid: handB[0].uid, at_index: idx });
    }
    for (const uid of [null, 5, [], {}, '', ' ', 'host-c', 'guest-c', '\u0000']) {
      add(`play with uid ${JSON.stringify(uid)}`, 'a', { type: 'play_creature', card_uid: uid, at_index: -1 });
      add(`stratagem with uid ${JSON.stringify(uid)}`, 'a', { type: 'play_stratagem', card_uid: uid, target_instance_id: '', target_player_id: '' });
    }
    for (let i = 0; i < 20; i++) {
      add('stratagem on fabricated target', 'a', { type: 'play_stratagem', card_uid: `host-c${300 + i}`, target_instance_id: `x#${i}`, target_player_id: 'guest' });
    }
    assert.ok(cases.length >= 200, `only ${cases.length} cheating cases defined`);

    let accepted = 0;
    for (const c of cases) {
      const r = await s.cmd('c1', c.seat, c.cmd, c.seq);
      if (r.ok) { accepted += 1; console.log('ACCEPTED:', c.label, JSON.stringify(c.cmd)); }
    }
    assert.equal(accepted, 0, 'no cheating attempt may be accepted');
    assert.equal(await hashOf(), baseline, 'the match state is byte-identical after every attempt');
    const after = await s.client.request('view', { match_id: 'c1', seat: 'a' });
    assert.equal(after.seq, seqNow, 'and the sequence number never advanced');
    console.log(`${cases.length} cheating cases refused, state unchanged`);
  } finally { s.stop(); }
});

test('a forged seat or actor cannot make the other player concede or win', { skip }, async () => {
  const s = await hostSession();
  try {
    await readyMatch(s, 'c2');
    // b "concedes" while claiming to be a: it must be b that loses.
    const r = await s.cmd('c2', 'b', { type: 'concede', actor: 'host' }, 2);
    assert.equal(r.ok, true, 'a concession is always accepted from the seat that sent it');
    assert.equal(r.over.winner, 'a', 'seat b conceded, so a wins - the claimed actor was ignored');
    assert.equal(r.over.reason, 'conceded');
    const after = await s.cmd('c2', 'a', { type: 'end_turn' }, 3);
    assert.equal(after.ok, false, 'nothing is accepted once the match is over');
  } finally { s.stop(); }
});

test('operations on bad matches and seats are refused', { skip }, async () => {
  const s = await hostSession();
  try {
    await readyMatch(s, 'c3');
    for (const seat of ['c', '', 'host', 'guest', null, 3, 'A']) {
      assert.equal((await s.client.request('view', { match_id: 'c3', seat })).ok, false, `view as ${JSON.stringify(seat)}`);
      assert.equal((await s.cmd('c3', seat, { type: 'end_turn' })).ok, false, `command as ${JSON.stringify(seat)}`);
      assert.equal((await s.client.request('timeout', { match_id: 'c3', seat })).ok, false, `timeout as ${JSON.stringify(seat)}`);
    }
    for (const id of ['', 'c4', null, 5, '../c3']) {
      assert.equal((await s.client.request('view', { match_id: id, seat: 'a' })).ok, false);
    }
    assert.equal((await s.client.request('no_such_op', {})).error, 'unknown_op');
    assert.equal((await s.client.request('', {})).error, 'unknown_op');
  } finally { s.stop(); }
});

test('an oversized frame without a newline drops the connection', { skip }, async () => {
  const host = await startMatchHost();
  try {
    const sock = net.connect(host.port, '127.0.0.1');
    await new Promise((r) => sock.once('connect', r));
    sock.on('error', () => {});
    sock.write(JSON.stringify({ op: 'hello', secret: host.secret, rid: 1 }) + '\n');
    await new Promise((r) => setTimeout(r, 300));
    sock.write('x'.repeat(400000));
    const closed = await new Promise((resolve) => { sock.on('close', () => resolve(true)); setTimeout(() => resolve(false), 6000); });
    assert.equal(closed, true);
    // The host survives and still serves others.
    const s2 = require('./helpers');
    const c = new s2.HostClient(host.port);
    await c.connect();
    assert.equal((await c.request('hello', { secret: host.secret })).ok, true);
    c.close();
  } finally { host.stop(); }
});
