'use strict';
// SC-001: nothing a seat receives may reveal what it is not entitled to see.
// A scripted match is played to a conclusion-ish length by a tiny bot; after
// EVERY step, no frame sent to one seat may contain the uid of any card still
// in the OTHER seat's hand, and no view may carry deck contents or generator state.
const test = require('node:test');
const assert = require('node:assert/strict');
const { godotBin, hostSession } = require('./helpers');

const skip = godotBin() ? false : 'GODOT_BIN is not set';

const own = (view, seat) => (seat === 'a' ? view.host_state : view.guest_state);
const other = (view, seat) => (seat === 'a' ? view.guest_state : view.host_state);

function handUids(snapshot, seat) {
  return own(snapshot.views[seat], seat).hand.map((c) => c.uid);
}

function effectiveCost(card, defs) {
  const base = defs[card.id] ? defs[card.id].cost : 99;
  return Math.min(10, Math.max(1, base + (card.cost_modifier || 0)));
}

test('no frame to either seat reveals the other seat\'s hand, the decks or the generator', { skip }, async () => {
  const fs = require('fs');
  const path = require('path');
  const defs = {};
  for (const f of ['green', 'crimson', 'generic']) {
    for (const c of JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'data', 'cards', `${f}.json`), 'utf8'))) defs[c.id] = c;
  }

  const s = await hostSession();
  try {
    let snap = await s.create('hid', { seed: 2024, first: 'a' });
    assert.equal(snap.ok, true);
    let seq = 0;
    const frames = [];
    const check = (label, snapshot) => {
      frames.push(snapshot);
      for (const viewer of ['a', 'b']) {
        const opponent = viewer === 'a' ? 'b' : 'a';
        const text = JSON.stringify({ view: snapshot.views[viewer], events: snapshot.events[viewer] });
        for (const uid of handUids(snapshot, opponent)) {
          assert.ok(!text.includes(`"${uid}"`), `${label}: seat ${viewer} was sent ${opponent}'s hand card ${uid}`);
        }
        assert.ok(!text.includes('"deck":'), `${label}: a view carried deck contents`);
        assert.ok(!/"rng"|"seed"|"state_hash"/.test(text), `${label}: a view carried generator state or the hash`);
        const opp = other(snapshot.views[viewer], viewer);
        assert.deepEqual(opp.hand, [], `${label}: the opponent hand must be a count only`);
        assert.equal(typeof opp.hand_size, 'number');
      }
    };
    check('create', snap);

    const send = async (seat, cmd) => {
      const r = await s.cmd('hid', seat, cmd, seq);
      if (r.ok) { seq = r.seq; check(`${cmd.type} by ${seat}`, r); snap = r; }
      return r;
    };
    await send('a', { type: 'mulligan', card_uids: [] });
    await send('b', { type: 'mulligan', card_uids: [] });

    // A small bot: answer open choices with their default, play what is affordable, end the turn.
    for (let turn = 0; turn < 24 && !snap.over; turn++) {
      const seat = turn % 2 === 0 ? 'a' : 'b';
      for (let guard = 0; guard < 12 && !snap.over; guard++) {
        const view = snap.views[seat];
        const me = own(view, seat);
        if (view.pending_choice && view.pending_choice.id) {
          const r = await send(seat, { type: 'answer_choice', choice_id: view.pending_choice.id, selection: view.pending_choice.default });
          assert.equal(r.ok, true, JSON.stringify(r));
          continue;
        }
        const available = me.max_mana - me.current_mana;
        const playable = me.hand.find((c) => defs[c.id] && defs[c.id].card_type === 'CREATURE' && effectiveCost(c, defs) <= available);
        if (!playable) break;
        const r = await send(seat, { type: 'play_creature', card_uid: playable.uid, at_index: -1 });
        if (!r.ok) break;
      }
      if (snap.over) break;
      let ended = await send(seat, { type: 'end_turn' });
      if (!ended.ok && snap.views[seat].pending_choice && snap.views[seat].pending_choice.id) {
        const pc = snap.views[seat].pending_choice;
        await send(seat, { type: 'answer_choice', choice_id: pc.id, selection: pc.default });
        ended = await send(seat, { type: 'end_turn' });
      }
    }
    assert.ok(frames.length > 12, `the scripted match produced ${frames.length} frames`);
    const plays = frames.flatMap((f) => f.events.a).filter((e) => e.type === 'play');
    assert.ok(plays.length > 0, 'cards were actually played, so the check covered revealed cards too');
  } finally { s.stop(); }
});
