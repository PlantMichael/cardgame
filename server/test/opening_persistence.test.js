'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Pool } = require('pg');
const { godotBin, disposableDatabase, buildDeck } = require('./helpers');
const { initLegacySchema } = require('../schema_legacy');
const { initSchema, PgStore } = require('../authoritative/schema');
const { HostProcess } = require('../authoritative/host_process');
const { MatchManager } = require('../authoritative/match_manager');
const { loadCards } = require('../authoritative/decks');
const { replay } = require('../tools/matches');

test('ranked opening choices and named-bot baseline survive PostgreSQL reload and administrative replay', {
  skip: !godotBin() || !disposableDatabase() ? 'requires Godot and disposable Postgres' : false, timeout: 60000,
}, async t => {
  const schema = `opening_${process.pid}_${Date.now()}`;
  const admin = new Pool({ connectionString: process.env.DATABASE_URL, ssl: false });
  await admin.query(`CREATE SCHEMA ${schema}`);
  const pool = new Pool({ connectionString: process.env.DATABASE_URL, ssl: false, options: `-c search_path=${schema}` });
  const host = new HostProcess({ log: { warn() {}, error() {} } });
  t.after(async () => { await host.stop(); await pool.end(); await admin.query(`DROP SCHEMA ${schema} CASCADE`); await admin.end(); });
  await initLegacySchema(pool);
  await initSchema(pool);
  await host.start();
  for (const [i, selection] of ['coin', 'five_cards', 'token', 'baseline'].entries()) {
    const players = [];
    for (const [seat, faction, idx] of [['a', 'green', 0], ['b', 'crimson', 1]]) {
      const { rows } = await pool.query('INSERT INTO players(username,password_hash,salt) VALUES($1,$2,$3) RETURNING id', [`opening_${i}_${seat}`, 'test', 'test']);
      players.push(rows[0].id);
      await pool.query('INSERT INTO decks(player_id,name,faction_idx,card_ids) VALUES($1,$2,$3,$4)', [rows[0].id, seat, idx, JSON.stringify(buildDeck([faction, 'generic']))]);
    }
    if (selection === 'baseline') await pool.query('INSERT INTO ranked_bot_accounts(bot_id,player_id,profile) VALUES($1,$2,$3)',
      ['io', players[0], JSON.stringify({ id: 'io', name: 'Io', version: '1.0', level: 10, style: 'tempo' })]);
    const manager = new MatchManager({ store: new PgStore(pool), host, cards: loadCards(), log: { warn() {}, error() {} } });
    const id = `opening_pg_${i}`;
    const made = await manager.createMatch({ matchId: id, a: { playerId: players[0], deckName: 'a' }, b: { playerId: players[1], deckName: 'b' } });
    assert.equal(made.ok, true, JSON.stringify(made));
    const conns = [{ send() {}, close() {} }, { send() {}, close() {} }];
    for (let j = 0; j < 2; j++) await manager.handleMessage(players[j], { type: 'match_join', match_id: id }, conns[j]);
    let seq = [0, 0];
    const command = (j, cmd) => manager.handleMessage(players[j], { type: 'match_command', match_id: id, client_seq: ++seq[j], cmd }, conns[j]);
    const second = made.firstSeat === 'a' ? 1 : 0;
    if (selection !== 'baseline') {
      const choice = manager.sessions.get(id).views[second ? 'b' : 'a'].pending_choice;
      await command(second, { type: 'answer_choice', choice_id: choice.id, selection });
    } else {
      assert.deepEqual(manager.sessions.get(id).views.a.opening_bonus, {});
    }
    for (let j = 0; j < 2; j++) await command(j, { type: 'mulligan', card_uids: [] });
    const expected = manager.sessions.get(id).lastHash;
    const saved = new PgStore(pool);
    const [row] = (await saved.loadActiveMatches()).filter(r => r.match_id === id);
    assert.equal(row.mode, selection === 'baseline' ? 'ranked_bots' : 'authoritative');
    assert.equal(row.actions.length, selection === 'baseline' ? 2 : 3);
    assert.equal((await replay(pool, id)).ok, true, 'actual administrative replay preserves the mode and hash');
    await host.request('drop', { match_id: id });
    // Only reload this fixture's active match; prior iterations are finished.
    const resumed = new MatchManager({ store: saved, host, cards: loadCards(), log: { warn() {}, error() {} } });
    await resumed.resume();
    assert.equal(resumed.sessions.get(id).status, 'active');
    assert.equal(resumed.sessions.get(id).lastHash, expected);
    await saved.setStatus(id, { status: 'finished' });
    await host.request('drop', { match_id: id });
  }
});
