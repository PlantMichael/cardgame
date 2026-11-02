'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { Pool } = require('pg');
const { initLegacySchema } = require('../schema_legacy');
const { initSchema, PgStore } = require('../authoritative/schema');
const { settleRankedMatch, PgSettleRepo } = require('../authoritative/settle');
const { provisionRankedBots } = require('../ranked_bot_accounts');
const { createBotPresence, BOT_STATUS_PATH } = require('../bot_status');
const { createRelayServer } = require('../card_winrates');
const { disposableDatabase, PROJECT_DIR } = require('./helpers');

test('owned bot status crosses storage, presence, catalog and page without leaking account or match data', {
  skip: !process.env.DATABASE_URL || !disposableDatabase() ? 'requires disposable DATABASE_URL' : false,
}, async t => {
  const admin = new Pool({ connectionString: process.env.DATABASE_URL, ssl: false });
  const schema = `bot_status_${process.pid}`;
  await admin.query(`CREATE SCHEMA ${schema}`);
  const url = new URL(process.env.DATABASE_URL); url.searchParams.set('options', `-c search_path=${schema}`);
  const pool = new Pool({ connectionString: url.href, ssl: false });
  const servers = []; let wss;
  t.after(async () => {
    if (wss) await new Promise(r => wss.close(r));
    for (const s of servers) { s.closeAllConnections(); await new Promise(r => s.close(r)); }
    await pool.end(); await admin.query(`DROP SCHEMA ${schema} CASCADE`); await admin.end();
  });
  await initLegacySchema(pool); await initSchema(pool);
  let clock = Date.now(), match = null;
  const queue = new Map(), owner = { matchOf: () => match, creatingPlayers: new Set(), host: { ready: true } };
  const presence = createBotPresence({ queue, manager: () => owner });
  let reads = 0; const query = pool.query.bind(pool);
  pool.query = (...args) => { if (args[0]?.text?.includes('SELECT b.bot_id,p.id')) reads++; return query(...args); };
  const relay = createRelayServer({ pool, botActivity: presence.activity, now: () => clock });
  wss = relay.wss; servers.push(relay.server);
  await new Promise(r => relay.server.listen(0, '127.0.0.1', r));
  const upstream = `http://127.0.0.1:${relay.server.address().port}`;
  const { createCatalogServer } = await import('../../catalog/src/server.mjs');
  const proxy = createCatalogServer(path.join(PROJECT_DIR, 'catalog/public'), { statsOrigin: upstream }); servers.push(proxy);
  await new Promise(r => proxy.listen(0, '127.0.0.1', r));
  const catalog = `http://127.0.0.1:${proxy.address().port}`;
  const { validStatus, rankDisplay } = await import('../../website/bots-core.mjs');
  async function snapshot(origin = catalog) {
    const response = await fetch(origin + BOT_STATUS_PATH); assert.equal(response.status, 200);
    const data = await response.json(); assert.ok(validStatus(data)); return data;
  }
  async function io() { clock += 5001; return (await snapshot()).bots.find(b => b.id === 'io'); }
  const empty = await snapshot();
  assert.deepEqual(empty.bots.map(b => b.id), ['io','callisto','europa','ganymede']);
  assert.ok(empty.bots.every(b => b.activity === 'not_started' && b.rank === null));
  assert.equal(rankDisplay(empty.bots[0].rank).name, 'Not ranked yet');
  await provisionRankedBots(pool);
  const bots = (await pool.query('SELECT bot_id,player_id,profile FROM ranked_bot_accounts')).rows;
  const a = bots.find(b => b.bot_id === 'io'), b = bots.find(b => b.bot_id === 'callisto');
  assert.equal((await io()).activity, 'offline');
  const ws = { readyState: 1 };
  presence.remember(ws, a.player_id, presence.begin(ws));
  assert.equal((await io()).activity, 'idle');
  queue.set(ws, { playerId: a.player_id }); assert.equal((await io()).activity, 'queued');
  queue.clear(); owner.creatingPlayers.add(a.player_id); assert.equal((await io()).activity, 'joining');
  owner.creatingPlayers.clear();
  match = { status: 'waiting', hostDown: false, seats: { a: { playerId: a.player_id, conn: {}, disconnectedAt: null } } };
  assert.equal((await io()).activity, 'joining');
  match.status = 'active'; assert.equal((await io()).activity, 'playing');
  match.hostDown = true; assert.equal((await io()).activity, 'reconnecting');
  match.hostDown = false; match.seats.a.disconnectedAt = clock;
  assert.equal((await io()).activity, 'reconnecting');
  match.status = 'finished'; assert.equal((await io()).activity, 'idle', 'finished tombstones are not playing');
  match = null;
  const old = presence.begin(ws), newer = presence.begin(ws);
  presence.remember(ws, b.player_id, newer); presence.remember(ws, a.player_id, old);
  assert.equal((await io()).activity, 'offline', 'late authentication cannot replace a newer identity');
  assert.equal((await snapshot()).bots.find(row => row.id === 'callisto').activity, 'idle', 'the newer identity is preserved');
  const late = presence.begin(ws); presence.forget(ws); presence.remember(ws, a.player_id, late);
  assert.equal((await io()).activity, 'offline', 'completion after close cannot resurrect presence');
  const denied = presence.begin(ws); presence.remember(ws, a.player_id, denied); presence.reject(ws, denied);
  assert.equal((await io()).activity, 'offline', 'failed rebinding removes the authenticated presence');
  ws.readyState = 3; presence.remember(ws, a.player_id, presence.begin(ws));
  assert.equal((await io()).activity, 'offline');

  const store = new PgStore(pool);
  for (let i = 0; i < 3; i++) {
    const id = `status_rank_${i}`;
    await store.createMatch({ match_id: id, rules_version: 3, seed: 1, first_seat: 'a', mode: 'ranked_bots',
      seat_a_player_id: a.player_id, seat_b_player_id: b.player_id, deck_a: ['g_001'], deck_b: ['cr_002'], bot_a: a.profile, bot_b: b.profile, engine_version: 2 });
    await store.setStatus(id, { status: 'finished', winner_seat: 'a', end_reason: 'completed' });
    await settleRankedMatch(new PgSettleRepo(pool), { matchId: id, seats: { a: a.player_id, b: b.player_id }, winner: 'a', endReason: 'completed' });
  }
  const promoted = await io();
  assert.deepEqual(promoted.rank, { bracket: 1, inLegend: false, legendRating: 0, lp: 13 });
  assert.equal(rankDisplay(promoted.rank).name, 'Orbital II');
  await pool.query('UPDATE players SET rank_bracket=20,rank_in_legend=true,rank_legend_rating=500,rank_lp=0 WHERE id=$1', [a.player_id]);
  const legend = await io(); assert.equal(rankDisplay(legend.rank).name, 'Celestial');
  assert.deepEqual(await snapshot(upstream), await snapshot());
  clock += 5001; const beforeReads = reads;
  await Promise.all(Array.from({ length: 8 }, () => snapshot()));
  assert.equal(reads - beforeReads, 1, 'concurrent refreshes share the bounded rank lookup');
  for (const origin of [upstream, catalog]) {
    assert.equal((await fetch(origin + BOT_STATUS_PATH + '?player_id=1')).status, 400);
    assert.equal((await fetch(origin + BOT_STATUS_PATH, { method: 'POST' })).status, 405);
    assert.equal((await fetch(origin + BOT_STATUS_PATH, { method: 'OPTIONS' })).status, 204);
    const head = await fetch(origin + BOT_STATUS_PATH, { method: 'HEAD' });
    assert.equal(await head.text(), ''); assert.equal(head.headers.get('cache-control'), 'no-store');
    const text = JSON.stringify(await snapshot(origin));
    for (const secret of ['player_id', 'match_id', 'status_rank_', 'token', 'password', 'rating"', 'seed', 'deck']) assert.ok(!text.includes(secret), secret);
  }
  await pool.query('ALTER TABLE ranked_bot_accounts RENAME TO status_temporarily_unavailable'); clock += 5001;
  assert.equal((await fetch(catalog + BOT_STATUS_PATH)).status, 503, 'a failed lookup never fabricates offline bots');
  await pool.query('ALTER TABLE status_temporarily_unavailable RENAME TO ranked_bot_accounts');
  assert.equal((await snapshot()).bots.length, 4, 'failure is not cached');
});
