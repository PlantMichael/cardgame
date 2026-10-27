'use strict';
// Real PostgreSQL -> relay HTTP -> catalog HTTP, with private synthetic schemas.
const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const path = require('node:path');
const { Pool } = require('pg');
const WebSocket = require('ws');
const { initLegacySchema } = require('../schema_legacy');
const { initSchema, PgStore } = require('../authoritative/schema');
const { settleRankedMatch, PgSettleRepo } = require('../authoritative/settle');
const { loadCards } = require('../authoritative/decks');
const { normalizeAIRecord } = require('../ranked_ai_record');
const { createRelayServer, STATS_PATH } = require('../card_winrates');
const { disposableDatabase, PROJECT_DIR } = require('./helpers');

async function listen(server) {
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  return `http://127.0.0.1:${server.address().port}`;
}

test('published card win rates combine actual starting decks through both HTTP endpoints', {
  skip: !process.env.DATABASE_URL || !disposableDatabase() ? 'requires disposable DATABASE_URL' : false,
  timeout: 30000,
}, async t => {
  const admin = new Pool({ connectionString: process.env.DATABASE_URL, ssl: false });
  const schema = `winrates_${process.pid}`;
  await admin.query(`CREATE SCHEMA ${schema}`);
  const url = new URL(process.env.DATABASE_URL);
  url.searchParams.set('options', `-c search_path=${schema}`);
  const pool = new Pool({ connectionString: url.toString(), ssl: false, query_timeout: 3000 });
  const servers = [];
  const websockets = [];
  t.after(async () => {
    for (const wss of websockets) { for (const ws of wss.clients) ws.terminate(); await new Promise(r => wss.close(r)); }
    for (const server of servers) await new Promise(r => server.close(r));
    await pool.end();
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
  });
  await initLegacySchema(pool);
  const { rows: people } = await pool.query(`INSERT INTO players (username, password_hash, salt)
    VALUES ('winrate_a', 'synthetic', 'synthetic'), ('winrate_b', 'synthetic', 'synthetic') RETURNING id`);
  const [a, b] = people.map(p => p.id);
  const cards = new Map([...loadCards()].filter(([, c]) => !c.is_token));
  async function ai(id, won, deck) {
    const record = normalizeAIRecord({ player_deck: deck, opponent_deck: ['cr_002'],
      ai_level: 1, turns: 10, rules_version: 1 }, id, cards);
    assert.ok(record);
    await pool.query(`INSERT INTO ranked_settlements (match_id, player_id, won, outcome, ai_match)
      VALUES ($1,$2,$3,'{}',$4) ON CONFLICT DO NOTHING`, [id, a, won, record]);
  }
  await ai('ai_1_1', true, ['g_001', 'g_001', 'gen_str_005']);
  await ai('ai_1_2', false, ['g_001', 'g_002']);
  await ai('ai_1_1', true, ['g_001']); // settlement redelivery remains one perspective
  await pool.query(`INSERT INTO ranked_settlements (match_id,player_id,won,outcome) VALUES ('ai_legacy',$1,true,'{}')`, [a]);
  let clock = 1800000000000;
  const root = path.join(PROJECT_DIR, 'catalog/public');
  const { server, wss } = createRelayServer({ pool, publicRoot: root, now: () => clock++ });
  servers.push(server); websockets.push(wss);
  const relay = await listen(server);
  const { createCatalogServer } = await import('../../catalog/src/server.mjs');
  const catalogServer = createCatalogServer(root, { statsOrigin: relay });
  servers.push(catalogServer);
  const catalog = await listen(catalogServer);
  async function get(origin = catalog, method = 'GET') {
    const res = await fetch(origin + STATS_PATH, { method });
    return { status: res.status, headers: res.headers, text: await res.text() };
  }
  function card(body, id) { return JSON.parse(body).cards.find(c => c.id === id); }
  let response = await get();
  assert.equal(response.status, 200);
  assert.deepEqual(card(response.text, 'g_001'), { id: 'g_001', matches: 2, wins: 1, losses: 1, winRate: 0.5 });
  assert.equal(card(response.text, 'g_002').winRate, 0, 'a single loss is published');
  assert.equal(card(response.text, 'cr_002').winRate, null, 'AI opponent deck is excluded');
  assert.equal(JSON.parse(response.text).methodology.minSample, 1);
  for (const origin of [relay, catalog]) {
    const r = await get(origin);
    assert.equal(card(r.text, 'gen_str_005'), undefined, 'private non-token cards are withheld at source and facade');
    assert.ok(!r.text.includes('ai_1_1') && !r.text.includes('winrate_a'));
    assert.equal(r.headers.get('access-control-allow-origin'), '*');
    assert.equal((await get(origin, 'HEAD')).text, '');
    assert.equal((await get(origin, 'OPTIONS')).status, 204);
    assert.equal((await get(origin, 'POST')).status, 405);
  }
  assert.equal((await fetch(relay)).status, 426);
  const socket = new WebSocket(relay.replace('http:', 'ws:'));
  await once(socket, 'open'); socket.terminate();

  await initSchema(pool);
  const store = new PgStore(pool);
  async function pvp(id, status, winner, reason, deckA, deckB) {
    await store.createMatch({ match_id: id, rules_version: 1, seed: 1, first_seat: 'a',
      seat_a_player_id: a, seat_b_player_id: b, deck_a: deckA, deck_b: deckB });
    await store.setStatus(id, { status, winner_seat: winner, end_reason: reason });
    // Canonical settlement producer; non-settling results produce no rows.
    await settleRankedMatch(new PgSettleRepo(pool), { matchId: id, seats: { a, b }, winner, endReason: reason });
  }
  await pvp('mirror', 'finished', 'a', 'completed', ['g_001', 'g_002'], ['g_001']);
  await settleRankedMatch(new PgSettleRepo(pool), { matchId: 'mirror', seats: { a, b }, winner: 'a', endReason: 'completed' });
  await pvp('pending', 'active', 'a', 'completed', ['g_002'], ['g_002']);
  await pvp('voided', 'voided', 'a', 'completed', ['g_002'], ['g_002']);
  await pvp('draw', 'finished', null, 'completed', ['g_002'], ['g_002']);
  // Defensive projection of historical data cannot publish unknown/token IDs.
  const tokenId = [...loadCards()].find(([, c]) => c.is_token)[0];
  await pool.query(`UPDATE ranked_settlements SET ai_match = jsonb_set(ai_match, '{player_deck}', $1::jsonb)
    WHERE match_id = 'ai_1_1'`, [JSON.stringify(['g_001', 'g_001', 'gen_str_005', tokenId, 'unknown_card'])]);
  assert.equal(card((await get()).text, 'g_001').matches, 2, 'successful snapshot cached');
  clock += 60001;
  const concurrent = await Promise.all(Array.from({ length: 8 }, () => get(relay)));
  assert.ok(concurrent.every(r => r.text === concurrent[0].text));
  assert.equal(card(concurrent[0].text, tokenId), undefined);
  assert.equal(card(concurrent[0].text, 'unknown_card'), undefined);
  response = await get();
  assert.deepEqual(card(response.text, 'g_001'), { id: 'g_001', matches: 4, wins: 2, losses: 2, winRate: 0.5 });
  assert.deepEqual(card(response.text, 'g_002'), { id: 'g_002', matches: 2, wins: 1, losses: 1, winRate: 0.5 });

  clock += 60001;
  await pool.query('ALTER TABLE ranked_settlements RENAME TO unavailable_settlements');
  response = await get();
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.text.trim(), '{"error":"card win rates unavailable"}');
  assert.equal((await fetch(catalog + '/healthz')).status, 200);
  assert.equal((await fetch(catalog + '/data/v1/latest.json')).status, 200);
  await pool.query('ALTER TABLE unavailable_settlements RENAME TO ranked_settlements');
  assert.equal((await get()).status, 200, 'failure not cached');

  const missing = createRelayServer({ pool, publicRoot: path.join(root, 'does-not-exist') });
  servers.push(missing.server); websockets.push(missing.wss);
  const missingOrigin = await listen(missing.server);
  assert.equal((await get(missingOrigin)).status, 503);
  const ws = new WebSocket(missingOrigin.replace('http:', 'ws:'));
  await once(ws, 'open'); ws.terminate();
});
