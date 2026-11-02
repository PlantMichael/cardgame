'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { readFileSync } = require('node:fs');
const { Pool } = require('pg');
const { initLegacySchema } = require('../schema_legacy');
const { initSchema, PgStore } = require('../authoritative/schema');
const { PgSettleRepo, settleRankedMatch } = require('../authoritative/settle');
const { loadCards } = require('../authoritative/decks');
const { normalizeAIRecord } = require('../ranked_ai_record');
const { provisionRankedBots } = require('../ranked_bot_accounts');
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
  await ai('ai_1_1', A, B, true, { first_player: 'player', card_plays: { player: { g_001: 2 }, opponent: { cr_002: 1 } } });
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
  for (const invalid of ['?mode=unknown', '?mode=all&aiLevel=4', '?mode=all&aiVersion=1', '?days=0', '?days=366', '?aiLevel=11', '?rulesVersion=3&rulesVersion=4',
    '?aiVersion=', '?player_id=1', '?mode=authoritative_pvp&aiLevel=10']) {
    for (const origin of [upstream, catalog]) assert.equal((await get(invalid, origin)).status, 400, invalid);
  }
  assert.equal((await get('', catalog, 'HEAD')).text, '');
  assert.equal((await get('', catalog, 'OPTIONS')).status, 204);
  assert.equal((await get('', catalog, 'POST')).status, 405);
  assert.equal((await get()).headers.get('access-control-allow-origin'), '*');
  assert.equal((await data('?mode=authoritative_pvp')).games, 0, 'AI-only installation supports an empty PvP view');

  const aiPool = await data('?mode=all&rulesVersion=3');
  assert.equal(aiPool.games, 8, 'combined view includes all AI policies/levels and missing-policy history without PvP tables');
  assert.ok(aiPool.decks.every(d => d.role === 'combined'));
  assert.equal((await data('?mode=all')).filters.rulesVersion, 4, 'combined latest still resolves a real rules version');
  await initSchema(pool);
  const store = new PgStore(pool);
  async function pvp(id, deckA, deckB, winner, first = 'a', facts = null, status = 'finished', extra = {}) {
    const match = { match_id: id, rules_version: 3, seed: 1, first_seat: first,
      seat_a_player_id: people[0], seat_b_player_id: people[1], deck_a: deckA, deck_b: deckB, ...extra };
    await store.createMatch(match);
    await store.setStatus(id, { status, winner_seat: winner, end_reason: 'completed', facts });
    await pool.query('UPDATE ranked_matches SET ended_at = $2 WHERE match_id = $1', [id, new Date(clock)]);
    await settleRankedMatch(new PgSettleRepo(pool), { matchId: id, seats: { a: match.seat_a_player_id, b: match.seat_b_player_id }, winner, endReason: 'completed' });
  }
  await pvp('pvp_a', A, B, 'a', 'a', { turns: 12, seats: { a: { card_plays: { g_001: 3, g_002: 1, g_003: 2 } }, b: { card_plays: { cr_002: 1 } } } });
  await pvp('pvp_b', B, A, 'a', 'b');
  await pvp('pvp_mirror', A, A, 'b', 'a', { turns: 9, seats: { a: { deck_cards: [{ card_id: 'g_001', played_copies: 1 }, { card_id: 'g_002', played_copies: 0 }] }, b: { deck_cards: [{ card_id: 'g_001', played_copies: 0 }, { card_id: 'g_002', played_copies: 2 }] } } });
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

  await ai('ai_4_4', A, B, true, { ai_level: 4 });
  const pooled = await data('?mode=all&rulesVersion=3');
  assert.equal(pooled.games, 12, 'AI and canonical PvP games pool once, including low difficulty and old policies');
  assert.deepEqual(pooled.filters, { mode: 'all', days: 30, rulesVersion: 3, aiVersion: null, aiLevel: null });
  assert.deepEqual(pooled.availableFilters.aiLevels, []);
  assert.deepEqual(pooled.availableFilters.aiVersions, []);
  assert.equal(pooled.methodology.rolesSeparated, false);
  assert.equal(pooled.methodology.source, 'mixed');
  assert.ok(pooled.decks.every(d => d.role === 'combined'));
  const combinedA = pooled.decks.find(d => d.id === aHuman.id);
  assert.deepEqual([combinedA.matches, combinedA.wins, combinedA.losses, combinedA.testers], [13, 7, 6, 2]);
  assert.equal(combinedA.turnSamples, 12);
  assert.equal(combinedA.averageTurns, 137 / 12);
  const combinedMirror = pooled.matchups.find(m => m.deckId === aHuman.id && m.opponentDeckId === aHuman.id);
  assert.deepEqual([combinedMirror.matches, combinedMirror.wins, combinedMirror.losses], [4, 2, 2]);
  assert.equal(pooled.decks.reduce((n,d) => n+d.matches,0), pooled.games*2);
  assert.equal(pooled.decks.reduce((n,d) => n+d.wins,0), pooled.games);
  assert.deepEqual(pooled.playStats, { totalSeats: 24, trackedSeats: 6, completeSeats: 4,
    cards: [{ id: 'cr_002', plays: 2 }, { id: 'g_001', plays: 6 }, { id: 'g_002', plays: 3 }, { id: 'g_003', plays: 2 }] });
  assert.deepEqual(await data('?mode=all&rulesVersion=3', upstream), pooled, 'both HTTP boundaries preserve the public pool and coverage');

  // Real registered bot identities and canonical settlements feed the existing
  // combined API, including bot-only rows with zero distinct human testers.
  await provisionRankedBots(pool);
  const bots = (await pool.query('SELECT player_id,profile FROM ranked_bot_accounts ORDER BY bot_id')).rows;
  const io = bots.find(b => b.profile.id === 'io'), callisto = bots.find(b => b.profile.id === 'callisto');
  const release = JSON.parse(readFileSync(path.join(root, 'data/cards.json'), 'utf8'));
  const fullDeck = color => release.cards.filter(c => c.collectible && !c.isToken && c.color === color)
    .flatMap(c => Array(c.rarity === 'LEGENDARY' ? 1 : 2).fill(c.id)).slice(0, 40);
  const C = fullDeck('GREEN'), D = fullDeck('CRIMSON');
  assert.equal(C.length, 40); assert.equal(D.length, 40);
  const cardId = C[0];
  const cardsBefore = await (await fetch(catalog + '/data/stats/card-winrates.json')).json();
  const beforeCard = cardsBefore.cards.find(c => c.id === cardId);
  const botMeta = { mode: 'ranked_bots', rules_version: 777, engine_version: 2,
    seat_a_player_id: io.player_id, seat_b_player_id: callisto.player_id, bot_a: io.profile, bot_b: callisto.profile };
  const facts = { turns: 7, seats: { a: { card_plays: { [cardId]: 2 } }, b: { card_plays: {} } } };
  await pvp('bots_only', C, D, 'a', 'a', facts, 'finished', botMeta);
  clock += 60001;
  const botOnly = await data('?mode=all&rulesVersion=777');
  assert.equal(botOnly.games, 1);
  assert.ok(botOnly.decks.every(d => d.testers === 0));
  assert.ok(botOnly.matchups.every(m => m.testers === 0));
  assert.deepEqual(await data('?mode=all&rulesVersion=777', upstream), botOnly);
  const page = await import('../../website/stats-core.mjs');
  assert.ok(page.validateSnapshot(botOnly), 'the actual stats page accepts a bot-only combined snapshot');
  const metric = page.cardMetrics(botOnly, [cardId])[0];
  assert.equal(metric.inDecks, 0.5); assert.equal(metric.deckWinRate, 1); assert.equal(metric.timesPlayed, 2);
  assert.equal((await data('?mode=authoritative_pvp&rulesVersion=777')).games, 0, 'explicit human PvP remains separate');
  const cId = botOnly.decks.find(d => d.cards.some(c => c.id === cardId)).id;
  await pvp('human_bot', C, D, 'b', 'a', { ...facts, turns: 9 }, 'finished',
    { ...botMeta, seat_a_player_id: people[0], seat_b_player_id: io.player_id, bot_a: null, bot_b: io.profile });
  await pvp('bot_mirror', C, C, 'b', 'b', { turns: 11 }, 'finished', botMeta);
  await pvp('bot_contradictory', C, D, 'a', 'a', facts, 'finished', botMeta);
  await pool.query("UPDATE ranked_settlements SET won=NOT won WHERE match_id='bot_contradictory' AND player_id=$1", [io.player_id]);
  clock += 60001;
  const combinedBots = await data('?mode=all&rulesVersion=777');
  assert.equal(combinedBots.games, 3, 'each canonical bot game counts once and contradictory settlements never count');
  const shared = combinedBots.decks.find(d => d.id === cId);
  assert.deepEqual([shared.matches, shared.wins, shared.losses, shared.testers], [4, 2, 2, 1], 'same exact human/bot list merges without counting bot accounts as people');
  const botMirror = combinedBots.matchups.find(m => m.deckId === cId && m.opponentDeckId === cId);
  assert.deepEqual([botMirror.matches, botMirror.wins, botMirror.testers], [2, 1, 0]);
  assert.equal(combinedBots.playStats.trackedSeats, 4); assert.equal(combinedBots.playStats.completeSeats, 4);
  const combinedCards = await (await fetch(catalog + '/data/stats/card-winrates.json')).json();
  const afterCard = combinedCards.cards.find(c => c.id === cardId);
  assert.equal(afterCard.matches - beforeCard.matches, 4); assert.equal(afterCard.wins - beforeCard.wins, 2);
  assert.ok(combinedCards.methodology.modes.includes('ranked_bots'));
  const sqlCard = (await pool.query(readFileSync(path.join(PROJECT_DIR, 'server/tools/card-winrates.sql'), 'utf8'))).rows.find(c => c.card_id === cardId);
  assert.deepEqual([Number(sqlCard.games), Number(sqlCard.wins)], [afterCard.matches, afterCard.wins]);
  assert.ok(!JSON.stringify(combinedBots).includes('player_id') && !JSON.stringify(combinedBots).includes('Io'));

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
    SELECT 'ai_' || (n+7000000) || '_9',$1,true,'{}',$2,$3 FROM generate_series(1,25000) n`, [people[0], record, new Date(clock)]);
  await pool.query(`INSERT INTO ranked_matches (match_id,mode,status,end_reason,rules_version,seed,first_seat,
      seat_a_player_id,seat_b_player_id,deck_a,deck_b,winner_seat,ended_at)
    SELECT 'stress_pvp_'||n,'authoritative','finished','completed',999,1,'a',$1,$2,$3,$4,'a',$5
    FROM generate_series(1,25000) n`, [people[0],people[1],JSON.stringify(A),JSON.stringify(B),new Date(clock)]);
  await pool.query(`INSERT INTO ranked_settlements (match_id,player_id,won,outcome,settled_at)
    SELECT 'stress_pvp_'||n,person,won,'{}',$3 FROM generate_series(1,25000) n
    CROSS JOIN (VALUES ($1::integer,true),($2::integer,false)) AS seats(person,won)`, [people[0],people[1],new Date(clock)]);
  clock += 60001;
  assert.equal((await get('?mode=all&rulesVersion=3')).status, 503, 'the union ceiling applies before version filtering');
  assert.equal((await get(slice)).status, 200, 'each individual source remains within its own limit');
  assert.equal((await get('?mode=authoritative_pvp&rulesVersion=3')).status, 200);
  await pool.query(`INSERT INTO ranked_settlements (match_id,player_id,won,outcome,ai_match,settled_at)
    SELECT 'ai_' || (n+8000000) || '_9',$1,true,'{}',$2,$3 FROM generate_series(1,25001) n`, [people[0], record, new Date(clock)]);
  clock += 60001;
  assert.equal((await get(slice)).status, 503, 'source ceiling fails honestly rather than silently truncating history');
});
