'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { Pool } = require('pg');
const { initLegacySchema } = require('../schema_legacy');
const { initSchema, PgStore } = require('../authoritative/schema');
const { PgSettleRepo, settleRankedMatch } = require('../authoritative/settle');
const { loadCards } = require('../authoritative/decks');
const { normalizeAIRecord } = require('../ranked_ai_record');
const { createRelayServer } = require('../card_winrates');
const { DECK_STATS_PATH } = require('../deck_matchups');
const { disposableDatabase, PROJECT_DIR } = require('./helpers');

async function listen(server) {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${server.address().port}`;
}

test('exact decks and matchups survive storage, cohort filtering, and both public HTTP boundaries', {
  skip: !process.env.DATABASE_URL || !disposableDatabase() ? 'requires disposable DATABASE_URL' : false,
  timeout: 45000,
}, async t => {
  const admin = new Pool({ connectionString: process.env.DATABASE_URL, ssl: false });
  const schema = `deck_stats_${process.pid}`;
  await admin.query(`CREATE SCHEMA ${schema}`);
  const db = new URL(process.env.DATABASE_URL); db.searchParams.set('options', `-c search_path=${schema}`);
  const pool = new Pool({ connectionString: db.toString(), ssl: false });
  const servers = [], websockets = [];
  t.after(async () => {
    for (const ws of websockets) { for (const client of ws.clients) client.terminate(); await new Promise(r => ws.close(r)); }
    for (const server of servers) { server.closeAllConnections(); await new Promise(r => server.close(r)); }
    await pool.end(); await admin.query(`DROP SCHEMA ${schema} CASCADE`); await admin.end();
  });
  await initLegacySchema(pool);
  const people = (await pool.query(`INSERT INTO players (username,password_hash,salt)
    VALUES ('private_tester_a','synthetic','synthetic'),('private_tester_b','synthetic','synthetic') RETURNING id`)).rows.map(p => p.id);
  const cards = new Map([...loadCards()].filter(([, c]) => !c.is_token));
  const A = ['g_001', 'g_002'], B = ['cr_002', 'cr_003'];
  let clock = Date.UTC(2026, 9, 30, 12);
  async function ai(id, deckA, deckB, won, extras = {}, person = people[0], at = clock) {
    const record = normalizeAIRecord({ player_deck: deckA, opponent_deck: deckB, ai_level: 10,
      rules_version: 3, turns: 11, ai_version: 1, ...extras }, id, cards);
    assert.ok(record);
    await pool.query(`INSERT INTO ranked_settlements (match_id,player_id,won,outcome,ai_match,settled_at)
      VALUES ($1,$2,$3,'{}',$4,$5) ON CONFLICT DO NOTHING`, [id, person, won, record, new Date(at)]);
  }
  await ai('ai_1_1', A, B, true, { first_player: 'player' });
  await ai('ai_1_2', [...A].reverse(), B, false, { turns: 13, first_player: 'opponent' }, people[1]);
  await ai('ai_1_3', B, A, true, { turns: 9 });
  await ai('ai_1_4', A, A, true, { turns: 15, first_player: 'player' });
  await ai('ai_1_1', A, B, true); // repeated delivery is still one match
  await ai('ai_1_5', ['g_001', 'g_001', 'g_002'], B, true); // a different exact list
  await ai('ai_1_6', A, B, false, { ai_version: undefined });
  await ai('ai_1_7', A, B, true, { rules_version: 4, ai_version: 1 });
  await ai('ai_1_8', A, B, true, { rules_version: 3, ai_version: 2 });
  await ai('ai_1_9', A, B, true, { ai_level: 5 });
  await ai('ai_2_1', A, B, true, {}, people[0], clock - 60 * 86400000);
  await ai('ai_2_2', ['gen_str_005'], B, true); // known but unpublished collectible
  await ai('ai_2_3', ['g_001', 'g_001', 'g_001'], B, true); // malformed historical copy count
  await pool.query(`INSERT INTO ranked_settlements (match_id,player_id,won,outcome,ai_match,settled_at)
    VALUES ('ai_2_4',$1,true,'{}',$2,$3)`, [people[0], { mode: 'ranked_ai', source: 'client_reported',
    player_deck: A, opponent_deck: 'malformed', ai_level: 10, rules_version: 3, turns: 10 }, new Date(clock)]);
  const token = [...loadCards()].find(([, card]) => card.is_token)[0];
  await pool.query(`INSERT INTO ranked_settlements (match_id,player_id,won,outcome,ai_match,settled_at)
    VALUES ('ai_2_5',$1,true,'{}',$2,$3)`, [people[0], { mode: 'ranked_ai', source: 'client_reported',
    player_deck: [token], opponent_deck: B, ai_level: 10, rules_version: 3, ai_version: 1, turns: 10 }, new Date(clock)]);

  let reads = 0;
  const query = pool.query.bind(pool);
  pool.query = (...args) => { if (args[0]?.text?.includes('SELECT player_id, won, ai_match')) reads++; return query(...args); };
  const root = path.join(PROJECT_DIR, 'catalog/public');
  const relay = createRelayServer({ pool, publicRoot: root, now: () => clock });
  servers.push(relay.server); websockets.push(relay.wss);
  const upstream = await listen(relay.server);
  const { createCatalogServer } = await import('../../catalog/src/server.mjs');
  const proxy = createCatalogServer(root, { statsOrigin: upstream }); servers.push(proxy);
  const catalog = await listen(proxy);
  async function get(search = '', origin = catalog, method = 'GET') {
    const response = await fetch(origin + DECK_STATS_PATH + search, { method });
    return { status: response.status, headers: response.headers, text: await response.text() };
  }
  async function data(search = '', origin = catalog) {
    const response = await get(search, origin); assert.equal(response.status, 200, response.text); return JSON.parse(response.text);
  }
  const latest = await data();
  assert.deepEqual([latest.filters.rulesVersion, latest.filters.aiVersion], [4, 1], 'latest selectors resolve a real nonrectangular cohort');
  assert.equal(latest.games, 1);
  assert.deepEqual(latest.availableFilters.rulesVersions, [3, 4]);
  assert.deepEqual(latest.availableFilters.aiVersions, [1]);
  assert.deepEqual(latest.availableFilters.aiLevels, [5, 10]);
  assert.equal((await data('?rulesVersion=3')).filters.aiVersion, 2);
  assert.equal((await data('?aiVersion=2')).filters.rulesVersion, 3, 'explicit AI selection conditions latest rules');
  assert.equal((await data('?rulesVersion=3&aiVersion=unknown')).decks.find(d => d.role === 'human').unknownFirst.matches, 1);
  assert.equal((await data('?rulesVersion=999')).games, 0);
  const slice = '?rulesVersion=3&aiVersion=1';
  const stats = await data(slice);
  assert.equal(stats.games, 5);
  assert.equal((await data(slice + '&days=90')).games, 6, 'time filter includes the older saved game explicitly');
  assert.equal((await data(slice + '&aiLevel=5')).games, 1, 'difficulty is a separate population');
  const aHuman = stats.decks.find(d => d.role === 'human' && d.cards.length === 2 && d.cards[0].id === 'g_001' && d.cards[0].copies === 1);
  assert.deepEqual([aHuman.matches, aHuman.wins, aHuman.losses, aHuman.testers], [3, 2, 1, 2]);
  assert.equal(aHuman.winRate, 2 / 3);
  assert.equal(aHuman.averageTurns, 13);
  assert.equal(aHuman.turnSamples, 3);
  assert.deepEqual([aHuman.first.matches, aHuman.first.wins, aHuman.second.matches, aHuman.second.wins], [2, 2, 1, 0]);
  assert.ok(aHuman.winRateInterval.lower < aHuman.winRate && aHuman.winRateInterval.upper > aHuman.winRate);
  const aBot = stats.decks.find(d => d.id === aHuman.id && d.role === 'ai');
  assert.deepEqual([aBot.matches, aBot.wins, aBot.averageTurns], [2, 0, 12], 'AI outcomes stay separate even in a mirror');
  const aVariant = stats.decks.find(d => d.cards[0].id === 'g_001' && d.cards[0].copies === 2);
  assert.notEqual(aVariant.id, aHuman.id);
  const mirror = stats.matchups.find(m => m.deckId === aHuman.id && m.opponentDeckId === aHuman.id && m.role === 'human');
  assert.deepEqual([mirror.matches, mirror.wins], [1, 1]);
  assert.equal(stats.decks.reduce((n, d) => n + d.matches, 0), 2 * stats.games);
  for (const privateText of ['private_tester', 'player_id', 'match_id', 'ai_match', 'ai_1_', 'gen_str_005']) {
    assert.ok(!JSON.stringify(stats).includes(privateText), privateText);
  }
  assert.deepEqual(await data(slice, upstream), stats, 'relay and catalog expose the same public contract');
  for (const invalid of ['?mode=all', '?days=0', '?days=366', '?aiLevel=11', '?rulesVersion=3&rulesVersion=4',
    '?aiVersion=', '?player_id=1', '?mode=authoritative_pvp&aiLevel=10']) {
    for (const origin of [upstream, catalog]) assert.equal((await get(invalid, origin)).status, 400, invalid);
  }
  assert.equal((await get('', catalog, 'HEAD')).text, '');
  assert.equal((await get('', catalog, 'OPTIONS')).status, 204);
  assert.equal((await get('', catalog, 'POST')).status, 405);
  assert.equal((await get()).headers.get('access-control-allow-origin'), '*');
  assert.equal((await data('?mode=authoritative_pvp')).games, 0, 'AI-only installation supports an empty PvP view');

  await initSchema(pool);
  const store = new PgStore(pool);
  async function pvp(id, deckA, deckB, winner, first = 'a', facts = null, status = 'finished') {
    await store.createMatch({ match_id: id, rules_version: 3, seed: 1, first_seat: first,
      seat_a_player_id: people[0], seat_b_player_id: people[1], deck_a: deckA, deck_b: deckB });
    await store.setStatus(id, { status, winner_seat: winner, end_reason: 'completed', facts });
    await pool.query('UPDATE ranked_matches SET ended_at = $2 WHERE match_id = $1', [id, new Date(clock)]);
    await settleRankedMatch(new PgSettleRepo(pool), { matchId: id, seats: { a: people[0], b: people[1] }, winner, endReason: 'completed' });
  }
  await pvp('pvp_a', A, B, 'a', 'a', { turns: 12 });
  await pvp('pvp_b', B, A, 'a', 'b');
  await pvp('pvp_mirror', A, A, 'b', 'a', { turns: 9 });
  await pvp('pvp_unfinished', A, B, 'a', 'a', null, 'active');
  await pvp('pvp_contradictory', A, B, 'a');
  await pool.query("UPDATE ranked_settlements SET won = NOT won WHERE match_id = 'pvp_contradictory'");
  clock += 60001;
  const pvpStats = await data('?mode=authoritative_pvp');
  assert.equal(pvpStats.games, 3);
  assert.ok(pvpStats.decks.every(d => d.role === 'human'));
  const pvpA = pvpStats.decks.find(d => d.id === aHuman.id);
  assert.deepEqual([pvpA.matches, pvpA.wins, pvpA.testers, pvpA.turnSamples], [4, 2, 2, 3]);
  assert.equal(pvpA.averageTurns, 10);
  const pvpMirror = pvpStats.matchups.find(m => m.deckId === aHuman.id && m.opponentDeckId === aHuman.id);
  assert.deepEqual([pvpMirror.matches, pvpMirror.wins, pvpMirror.losses], [2, 1, 1]);

  const beforeReads = reads;
  const concurrent = await Promise.all(Array.from({ length: 8 }, () => data(slice)));
  assert.ok(concurrent.every(result => result.games === 5));
  assert.equal(reads - beforeReads, 1, 'concurrent refreshes share one actual database read');
  await ai('ai_3_1', A, B, false);
  assert.equal((await data(slice)).games, 5, 'successful cached snapshot remains coherent');
  clock += 60001;
  assert.equal((await data(slice)).games, 6, 'expiry reads saved new matches');
  clock += 60001;
  await pool.query('ALTER TABLE ranked_settlements RENAME TO temporarily_unavailable');
  const failed = await get(slice);
  assert.equal(failed.status, 503); assert.equal(failed.headers.get('cache-control'), 'no-store');
  assert.deepEqual(JSON.parse(failed.text), { error: 'deck matchup statistics unavailable' });
  assert.equal((await fetch(catalog + '/data/cards.json')).status, 200);
  await pool.query('ALTER TABLE temporarily_unavailable RENAME TO ranked_settlements');
  assert.equal((await data(slice)).games, 6, 'failure is not cached as empty or stale success');
  const record = normalizeAIRecord({ player_deck: A, opponent_deck: B, rules_version: 999, ai_version: 999, ai_level: 10, turns: 1 }, 'ai_1_1', cards);
  await pool.query(`INSERT INTO ranked_settlements (match_id,player_id,won,outcome,ai_match,settled_at)
    SELECT 'ai_' || (n+7000000) || '_9',$1,true,'{}',$2,$3 FROM generate_series(1,50001) n`, [people[0], record, new Date(clock)]);
  clock += 60001;
  assert.equal((await get(slice)).status, 503, 'source ceiling fails honestly rather than silently truncating history');
});
