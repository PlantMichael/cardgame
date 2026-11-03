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

test('human and named-bot opening choices survive PostgreSQL reload and administrative replay', {
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
  for (const [i, variant] of ['coin', 'five_cards', 'token', 'bot_coin'].entries()) {
    const bot = variant === 'bot_coin';
    const selection = bot ? 'coin' : variant;
    const players = [];
    for (const [seat, faction, idx] of [['a', 'green', 0], ['b', 'crimson', 1]]) {
      const { rows } = await pool.query('INSERT INTO players(username,password_hash,salt) VALUES($1,$2,$3) RETURNING id', [`opening_${i}_${seat}`, 'test', 'test']);
      players.push(rows[0].id);
      await pool.query('INSERT INTO decks(player_id,name,faction_idx,card_ids) VALUES($1,$2,$3,$4)', [rows[0].id, seat, idx, JSON.stringify(buildDeck([faction, 'generic']))]);
    }
    if (bot) await pool.query('INSERT INTO ranked_bot_accounts(bot_id,player_id,profile) VALUES($1,$2,$3)',
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
    const choice = manager.sessions.get(id).views[second ? 'b' : 'a'].pending_choice;
    await command(second, { type: 'answer_choice', choice_id: choice.id, selection });
    for (let j = 0; j < 2; j++) await command(j, { type: 'mulligan', card_uids: [] });
    const expected = manager.sessions.get(id).lastHash;
    const saved = new PgStore(pool);
    const [row] = (await saved.loadActiveMatches()).filter(r => r.match_id === id);
    assert.equal(row.mode, bot ? 'ranked_bots' : 'authoritative');
    assert.equal(row.actions.length, 3);
    assert.equal((await replay(pool, id)).ok, true, 'actual administrative replay preserves the mode and hash');
    await host.request('drop', { match_id: id });
    // Only reload this fixture's active match; prior iterations are finished.
    const settled = [];
    const resumed = new MatchManager({ store: saved, host, cards: loadCards(), settle: async (_sess, result) => { settled.push(result); return {}; }, log: { warn() {}, error() {} } });
    await resumed.resume();
    assert.equal(resumed.sessions.get(id).status, 'active');
    assert.equal(resumed.sessions.get(id).lastHash, expected);
    if (bot) {
      await pool.query('UPDATE ranked_matches SET engine_version=$1 WHERE match_id=$2', [host.engineVersion - 1, id]);
      await host.request('drop', { match_id: id });
      await resumed.resume();
      const old = (await pool.query('SELECT status,end_reason,engine_version FROM ranked_matches WHERE match_id=$1', [id])).rows[0];
      assert.deepEqual(old, { status: 'voided', end_reason: 'voided_fault', engine_version: host.engineVersion - 1 });
      assert.equal(resumed.byPlayer.has(players[0]), false);
      assert.equal(resumed.byPlayer.has(players[1]), false);
      assert.equal(settled.length, 0, 'persisted old-policy games cannot award a result');
    } else await saved.setStatus(id, { status: 'finished' });
    await host.request('drop', { match_id: id });
  }
});
