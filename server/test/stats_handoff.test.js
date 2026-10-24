'use strict';
// SC-009 (spec 003) / spec 002: a server-run match hands the statistics database
// facts the server itself observed - per seat, deck-level, consistent with the
// match - so nothing a client reports is needed to know what was drawn or played.
const test = require('node:test');
const assert = require('node:assert/strict');
const { godotBin, hostSession, buildDeck } = require('./helpers');

const skip = godotBin() ? false : 'GODOT_BIN is not set';

test('the host returns verified per-seat facts when a match ends', { skip }, async () => {
  const s = await hostSession();
  try {
    let snap = await s.create('f1', { seed: 7, first: 'a' });
    assert.equal(snap.ok, true);
    let seq = 0;
    // Keep the opening hands.
    for (const seat of ['a', 'b']) {
      snap = await s.cmd('f1', seat, { type: 'mulligan', card_uids: [] }, seq);
      assert.equal(snap.ok, true, JSON.stringify(snap));
      seq = snap.seq;
    }
    // Seat a ends its turn, then concedes: a short, fully legal match.
    snap = await s.cmd('f1', 'a', { type: 'end_turn' }, seq);
    seq = snap.seq;
    snap = await s.cmd('f1', 'b', { type: 'concede' }, seq);
    assert.equal(snap.ok, true);
    assert.ok(snap.over, 'the match is over');
    assert.equal(snap.over.winner, 'a');
    const facts = snap.over.facts;
    assert.ok(facts, 'facts are returned with the result');
    for (const seat of ['a', 'b']) {
      const f = facts.seats[seat];
      assert.ok(f.deck_cards.length > 0, `seat ${seat} has deck facts`);
      const copies = f.deck_cards.reduce((n, c) => n + c.copies, 0);
      assert.ok(copies >= 1, 'the starting deck is recorded');
      for (const c of f.deck_cards) {
        assert.ok(c.drawn_copies <= c.copies, `${c.card_id}: drawn <= copies`);
        assert.ok(c.kept_copies <= c.drawn_copies, `${c.card_id}: kept <= drawn`);
        assert.ok(c.played_copies <= c.drawn_copies, `${c.card_id}: played <= drawn`);
      }
      const opening = f.deck_cards.reduce((n, c) => n + c.kept_copies, 0);
      assert.ok(opening >= 3, `seat ${seat} kept its opening hand (${opening})`);
    }
    assert.ok(facts.turns >= 1);
  } finally {
    s.stop();
  }
});

test('a replayed match yields the same facts as the live one', { skip }, async () => {
  const s = await hostSession();
  try {
    const deckA = buildDeck();
    const deckB = buildDeck(['crimson', 'generic']);
    let snap = await s.create('f2', { seed: 11, first: 'b', deckA, deckB });
    let seq = 0;
    const actions = [];
    const send = async (seat, cmd) => {
      snap = await s.cmd('f2', seat, cmd, seq);
      assert.equal(snap.ok, true, JSON.stringify(snap));
      seq = snap.seq;
      actions.push({ seat, kind: 'command', cmd });
    };
    await send('a', { type: 'mulligan', card_uids: [] });
    await send('b', { type: 'mulligan', card_uids: [] });
    await send('b', { type: 'end_turn' });
    await send('a', { type: 'concede' });
    const live = snap.over.facts;
    const rep = await s.client.request('replay', {
      match_id: 'f2r', seed: 11, first_seat: 'b', rules_version: s.RULES_VERSION,
      deck_a: deckA, deck_b: deckB, actions,
    });
    assert.equal(rep.ok, true, JSON.stringify(rep));
    assert.deepEqual(rep.over.facts, live, 'replay and live facts agree');
  } finally {
    s.stop();
  }
});
