'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const path = require('node:path');
const fs = require('node:fs/promises');
const os = require('node:os');
const net = require('node:net');
const WebSocket = require('ws');
const { Pool } = require('pg');
const { initLegacySchema } = require('../schema_legacy');
const { initSchema } = require('../authoritative/schema');
const { computeOutcome } = require('../authoritative/settle');
const { provisionRankedBots } = require('../ranked_bot_accounts');
const { runRankedBots } = require('../ranked_bot_worker');
const { ratingBandAt, matchQueuedPlayers } = require('../ranked_queue');
const { disposableDatabase, PROJECT_DIR, killTree } = require('./helpers');

async function until(predicate, label, timeout = 120000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const result = await predicate(); if (result) return result;
    await new Promise(r => setTimeout(r, 100));
  }
  throw new Error(`Timed out: ${label}`);
}
async function database(t, prefix, autoCleanup = true) {
  const admin = new Pool({ connectionString: process.env.DATABASE_URL, ssl: false });
  const schema = `${prefix}_${process.pid}`;
  await admin.query(`CREATE SCHEMA ${schema}`);
  const url = new URL(process.env.DATABASE_URL); url.searchParams.set('options', `-c search_path=${schema}`);
  const pool = new Pool({ connectionString: url.toString(), ssl: false, max: 8, query_timeout: 10000 });
  const cleanup = async () => { await pool.end(); await admin.query(`DROP SCHEMA ${schema} CASCADE`); await admin.end(); };
  if (autoCleanup) t.after(cleanup);
  await initLegacySchema(pool);
  return { pool, url: url.toString(), cleanup };
}
class Client {
  constructor(ws) { this.ws = ws; this.messages = []; ws.on('message', raw => this.messages.push(JSON.parse(raw))); }
  static async open(url) { const ws = new WebSocket(url); const c = new Client(ws); await once(ws, 'open'); return c; }
  send(value) { this.ws.send(JSON.stringify({ token: this.token, ...value })); }
  async take(type, matchId = null) {
    return until(() => { const i = this.messages.findIndex(m => m.type === type && (!matchId || m.match_id === matchId)); return i < 0 ? null : this.messages.splice(i, 1)[0]; }, type, 15000);
  }
}

test('normal ranked bands widen without a cap and do not special-case bot ratings', () => {
  assert.equal(ratingBandAt(0, 0), 100); assert.equal(ratingBandAt(0, 10000), 700);
  const a = {}, b = {}, paired = [];
  const queue = new Map([[a, { playerId: 1, rating: 100, queuedAt: 0 }], [b, { playerId: 2, rating: 3100, queuedAt: 0 }]]);
  matchQueuedPlayers(queue, (...p) => paired.push(p), 1000);
  assert.equal(paired.length, 0);
  matchQueuedPlayers(queue, (...p) => paired.push(p), 50000);
  assert.equal(paired.length, 1, 'even Ganymede and a much stronger account can pair after waiting');
  assert.equal(queue.size, 0);
});

test('invalid worker URLs fail without logging connection credentials', async () => {
  const child = spawn(process.execPath, [path.join(PROJECT_DIR, 'server/ranked_bot_worker.js')], {
    env: { ...process.env, DATABASE_URL: 'postgres://user:synthetic-secret@invalid host/db' },
    stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
  });
  let output = '';
  child.stdout.on('data', d => { output += d; }); child.stderr.on('data', d => { output += d; });
  const [code] = await once(child, 'close');
  assert.equal(code, 1); assert.match(output, /Invalid URL/); assert.ok(!output.includes('synthetic-secret'));
});

const dbSkip = !process.env.DATABASE_URL || !disposableDatabase() ? 'requires disposable DATABASE_URL' : false;
test('trusted bot provisioning is atomic, preserves ranks and never adopts a human name', { skip: dbSkip }, async t => {
  const { pool } = await database(t, 'ranked_bot_identity');
  await pool.query("INSERT INTO players (username,password_hash,salt) VALUES ('CALLISTO','synthetic','synthetic')");
  await assert.rejects(provisionRankedBots(pool), /already owned/);
  assert.deepEqual((await pool.query('SELECT username FROM players')).rows.map(r => r.username), ['CALLISTO']);
  assert.equal((await pool.query('SELECT count(*) AS n FROM sessions')).rows[0].n, '0');
  await pool.query("DELETE FROM players WHERE username='CALLISTO'"); // This test owns the synthetic fixture.
  const accounts = await provisionRankedBots(pool);
  assert.deepEqual(accounts.map(a => a.id), ['io', 'callisto', 'europa', 'ganymede']);
  await pool.query("UPDATE players SET rating=100,ranked_losses=9 WHERE username='Ganymede'");
  await initLegacySchema(pool); await initSchema(pool); await initSchema(pool);
  await pool.query(`INSERT INTO ranked_matches (match_id,status,rules_version,seed,first_seat,deck_a,deck_b)
    VALUES ('legacy_row','finished',3,1,'a','["g_001"]','["cr_002"]')`);
  await pool.query('ALTER TABLE ranked_matches DROP COLUMN bot_a, DROP COLUMN bot_b, DROP COLUMN engine_version');
  await initSchema(pool); await initSchema(pool);
  assert.deepEqual((await pool.query("SELECT mode,bot_a,bot_b,engine_version FROM ranked_matches WHERE match_id='legacy_row'")).rows[0],
    { mode: 'authoritative', bot_a: null, bot_b: null, engine_version: null });
  const again = await provisionRankedBots(pool);
  assert.equal((await pool.query('SELECT count(*) AS n FROM players')).rows[0].n, '4');
  const gany = (await pool.query("SELECT rating,ranked_losses FROM players WHERE username='Ganymede'")).rows[0];
  assert.deepEqual(gany, { rating: 100, ranked_losses: 9 });
  assert.ok(again.every(a => !accounts.some(old => old.token === a.token)));
});

test('four real ranked clients queue, play, settle normally, reconnect and publish a separate ranked cohort', {
  skip: dbSkip || (!process.env.GODOT_BIN ? 'requires GODOT_BIN' : false), timeout: 300000,
}, async t => {
  const { pool, url, cleanup } = await database(t, 'ranked_bots_live', false);
  await initSchema(pool);
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'ranked-bots-relay-test-'));
  // Reject each bot's first queue lookup after the real DB read. This leaves
  // the socket healthy while exercising recovery before queue insertion.
  const queueFault = path.join(tmp, 'queue-fault.cjs');
  await fs.writeFile(queueFault, `
    const { Pool } = require(${JSON.stringify(require.resolve('pg'))});
    const query = Pool.prototype.query;
    const failed = new Set();
    Pool.prototype.query = async function(sql, values, ...rest) {
      const result = await query.call(this, sql, values, ...rest);
      if (typeof sql === 'string' && sql.includes('p.rating, b.profile AS bot_profile') &&
          result.rows[0]?.bot_profile && failed.size < 4 && !failed.has(values[0])) {
        failed.add(values[0]);
        throw new Error('synthetic first queue lookup failure');
      }
      return result;
    };
  `);
  const listener = net.createServer(); listener.listen(0, '127.0.0.1'); await once(listener, 'listening');
  const port = listener.address().port; await new Promise(r => listener.close(r));
  let relayLog = '';
  const launchRelay = authoritative => {
    relayLog = '';
    const proc = spawn(process.execPath, ['--require', queueFault, path.join(PROJECT_DIR, 'server/relay.js')], {
      env: { ...process.env, DATABASE_URL: url, PORT: String(port), RANKED_AUTHORITATIVE: authoritative,
        APPDATA: tmp, XDG_DATA_HOME: tmp, PROJECT_DIR }, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
    });
    proc.stdout.on('data', d => { relayLog = (relayLog + d).slice(-12000); });
    proc.stderr.on('data', d => { relayLog = (relayLog + d).slice(-12000); });
    return proc;
  };
  let relay = launchRelay('1');
  const clients = [], events = [];
  let stop = new AbortController();
  let worker;
  t.after(async () => {
    stop.abort(); if (worker) await worker.catch(() => {});
    for (const c of clients) c.ws.terminate();
    if (relay.exitCode === null) { const ended = once(relay, 'exit'); killTree(relay); await ended; }
    assert.equal(path.dirname(tmp), path.resolve(os.tmpdir()));
    assert.ok(path.basename(tmp).startsWith('ranked-bots-relay-test-'));
    await fs.rm(tmp, { recursive: true, force: true });
    await cleanup();
  });
  await until(() => {
    if (relay.exitCode !== null) throw new Error(relayLog);
    return relayLog.includes('Relay server listening');
  }, 'relay startup');
  const wsUrl = `ws://127.0.0.1:${port}`, httpUrl = `http://127.0.0.1:${port}`;
  const human = await Client.open(wsUrl); clients.push(human);
  human.send({ type: 'register', username: 'ranked_human', password: 'synthetic-password' });
  const registered = await human.take('register_result'); assert.equal(registered.success, true); human.token = registered.token;
  human.send({ type: 'save_deck', name: 'human', faction_idx: 0, card_ids: ['g_001', 'g_002'] });
  assert.equal((await human.take('save_deck_result')).success, true);
  human.send({ type: 'queue_ranked', deck_name: 'human', rules_version: 3, bot_profile: { id: 'io', version: '1.0' } });
  let workerFailure;
  const startWorker = () => {
    workerFailure = undefined;
    worker = runRankedBots({ pool, godotBin: process.env.GODOT_BIN, relayUrl: wsUrl, signal: stop.signal,
      onEvent: e => events.push(e), log: () => {} });
    worker.catch(e => { workerFailure = e; });
  };
  startWorker();
  await until(() => {
    if (workerFailure) throw workerFailure;
    return ['io', 'callisto', 'europa', 'ganymede'].every(id => events.filter(e => e.event === 'queued' && e.bot === id).length >= 2);
  }, 'all four retry queue entry after transient database failure');
  const found = await human.take('ranked_match_found');
  assert.equal(found.server_run, true); assert.match(found.opponent_name, /\[Bot 1\.0\]/);
  assert.ok(['io', 'callisto', 'europa', 'ganymede'].includes(found.opponent_bot.id));
  human.send({ type: 'match_join', match_id: found.match_id });
  const view = await human.take('match_view', found.match_id);
  human.send({ type: 'match_concede', match_id: found.match_id });
  const lost = await human.take('match_over', found.match_id);
  assert.equal(lost.ranked_outcome.success, true);
  assert.equal(lost.ranked_outcome.rank_lp, 0); assert.equal(lost.ranked_outcome.ranked_losses, 1);
  assert.equal(lost.ranked_outcome.rating, 984, 'human takes the normal equal-rating Elo loss');
  const humanId = (await pool.query("SELECT id FROM players WHERE username='ranked_human'")).rows[0].id;
  const first = (await pool.query('SELECT * FROM ranked_matches WHERE match_id=$1', [found.match_id])).rows[0];
  assert.equal(first.mode, 'ranked_bots');
  assert.equal(first[view.seat === 'a' ? 'bot_a' : 'bot_b'], null, 'client-supplied bot fields cannot change identity');
  assert.equal(first[view.seat === 'a' ? 'bot_b' : 'bot_a'].version, '1.0');
  const opponentId = first[view.seat === 'a' ? 'seat_b_player_id' : 'seat_a_player_id'];
  const wonRow = (await pool.query('SELECT rating,rank_lp,ranked_wins FROM players WHERE id=$1', [opponentId])).rows[0];
  assert.deepEqual(wonRow, { rating: 1016, rank_lp: 34, ranked_wins: 1 }, 'bot receives normal full ranked win');

  // A human win receives ordinary rewards too, through a canonical concede.
  human.send({ type: 'queue_ranked', deck_name: 'human', rules_version: 3 });
  const secondFound = await human.take('ranked_match_found');
  human.send({ type: 'match_join', match_id: secondFound.match_id });
  const secondView = await human.take('match_view', secondFound.match_id);
  const secondMatch = (await pool.query('SELECT * FROM ranked_matches WHERE match_id=$1', [secondFound.match_id])).rows[0];
  const secondOpponentId = secondMatch[secondView.seat === 'a' ? 'seat_b_player_id' : 'seat_a_player_id'];
  const before = (await pool.query('SELECT * FROM players WHERE id=$1', [humanId])).rows[0];
  const beforeOpp = (await pool.query('SELECT rating FROM players WHERE id=$1', [secondOpponentId])).rows[0];
  const botToken = (await pool.query('SELECT token FROM sessions WHERE player_id=$1 ORDER BY created_at DESC LIMIT 1', [secondOpponentId])).rows[0].token;
  const scriptedBot = await Client.open(wsUrl); clients.push(scriptedBot); scriptedBot.token = botToken;
  scriptedBot.send({ type: 'match_join', match_id: secondFound.match_id }); await scriptedBot.take('match_view', secondFound.match_id);
  scriptedBot.send({ type: 'match_concede', match_id: secondFound.match_id });
  const win = await human.take('match_over', secondFound.match_id);
  const expected = computeOutcome(before, true, beforeOpp.rating);
  for (const key of ['rating', 'rank_lp', 'ranked_wins', 'ranked_losses']) assert.equal(win.ranked_outcome[key], expected[key]);

  const inFlight = (await pool.query("SELECT match_id FROM ranked_matches WHERE status='active' AND mode='ranked_bots'")).rows.map(r => r.match_id);
  assert.ok(inFlight.length > 0);
  const restartIndex = events.length;
  stop.abort(); await worker;
  stop = new AbortController(); startWorker();
  await until(() => { if (workerFailure) throw workerFailure; return inFlight.every(id => events.slice(restartIndex).some(e => e.event === 'joined' && e.match_id === id)); }, 'fresh worker rejoins existing matches');

  // Real bot-v-bot games must progress and finish without scripted commands.
  const finished = await until(async () => {
    if (workerFailure) throw workerFailure;
    const rows = (await pool.query("SELECT * FROM ranked_matches WHERE mode='ranked_bots' AND status='finished' AND bot_a IS NOT NULL AND bot_b IS NOT NULL AND end_reason='completed'")).rows;
    return rows.length ? rows : null;
  }, 'autonomous bot-v-bot completion', 210000);
  assert.ok(finished[0].facts.turns > 1);
  const active = (await pool.query("SELECT * FROM ranked_matches WHERE status='active' AND mode='ranked_bots' LIMIT 1")).rows[0];
  if (active) {
    const playerId = active.bot_a ? active.seat_a_player_id : active.seat_b_player_id;
    const token = (await pool.query('SELECT token FROM sessions WHERE player_id=$1 ORDER BY created_at DESC LIMIT 1', [playerId])).rows[0].token;
    const reconnect = await Client.open(wsUrl); clients.push(reconnect); reconnect.token = token;
    reconnect.send({ type: 'queue_ranked', deck_name: 'Moon Bot 1.0', rules_version: 3 });
    const refused = await reconnect.take('ranked_refused');
    assert.equal(refused.reason, 'already_in_match'); assert.equal(refused.match_id, active.match_id);
    reconnect.send({ type: 'match_join', match_id: active.match_id });
    const resumed = await reconnect.take('match_view');
    assert.ok(resumed.client_seq >= 0);
    reconnect.ws.close();
  }
  const anonymous = await Client.open(wsUrl); clients.push(anonymous);
  anonymous.send({ type: 'register', username: 'EUROPA', password: 'synthetic-password' });
  assert.equal((await anonymous.take('register_result')).success, false);
  await assert.rejects(runRankedBots({ pool, godotBin: process.env.GODOT_BIN, relayUrl: wsUrl }), /another ranked bot worker/);
  const { createCatalogServer } = await import('../../catalog/src/server.mjs');
  const proxy = createCatalogServer(path.join(PROJECT_DIR, 'catalog/public'), { statsOrigin: httpUrl });
  await new Promise(r => proxy.listen(0, '127.0.0.1', r));
  t.after(async () => { proxy.closeAllConnections(); await new Promise(r => proxy.close(r)); });
  const route = `http://127.0.0.1:${proxy.address().port}/data/stats/bot-matchups.json`;
  const response = await fetch(route + '?mode=ranked');
  const body = await response.text(); assert.equal(response.status, 200, body);
  const ranked = JSON.parse(body);
  assert.equal(ranked.mode, 'ranked'); assert.equal(ranked.methodology.source, 'server_verified');
  assert.ok(ranked.games >= 3); assert.ok(ranked.bots.some(b => b.id === 'human' && b.level === null));
  assert.ok(!body.includes('ranked_human') && !body.includes('player_id') && !body.includes('match_id'));
  const { projectBotStats } = await import('../../catalog/src/bot-matchups.mjs');
  const release = JSON.parse(await fs.readFile(path.join(PROJECT_DIR, 'catalog/public/data/cards.json'), 'utf8'));
  const publicCards = new Map(release.cards.filter(c => c.collectible && !c.isToken).map(c => [c.id, c]));
  for (const mutate of [d => { d.bots.find(b => b.id === 'human').level = 1; },
    d => { d.bots.find(b => b.id === 'human').name = 'ranked_human'; }, d => { d.mode = 'simulation'; }]) {
    const bad = structuredClone(ranked); mutate(bad);
    assert.throws(() => projectBotStats(bad, publicCards, 30, 'ranked'));
  }
  assert.equal((await (await fetch(route)).json()).games, 0, 'ranked games never enter simulations');
  assert.equal((await (await fetch(httpUrl + '/data/stats/deck-matchups.json?mode=authoritative_pvp')).json()).games, 0);
  const humanCards = await (await fetch(httpUrl + '/data/stats/card-winrates.json')).json();
  assert.ok(humanCards.cards.every(c => c.matches === 0));
  for (const bad of ['?mode=bad', '?mode=ranked&mode=simulation', '?mode=ranked&days=0']) assert.equal((await fetch(route + bad)).status, 400);
  const snapshots = (await pool.query('SELECT bot_a,bot_b FROM ranked_matches WHERE match_id=$1', [first.match_id])).rows[0];
  await pool.query("UPDATE ranked_bot_accounts SET profile=jsonb_set(profile,'{version}','\"2.0\"')");
  assert.deepEqual((await pool.query('SELECT bot_a,bot_b FROM ranked_matches WHERE match_id=$1', [first.match_id])).rows[0], snapshots);
  const historical = await (await fetch(route + '?mode=ranked&days=31')).json();
  assert.ok(historical.bots.filter(b => b.id !== 'human').every(b => b.version === '1.0'), 'fresh HTTP read uses historical snapshots rather than current registry');
  await pool.query('UPDATE ranked_settlements SET won=NOT won WHERE match_id=$1 AND player_id=$2', [first.match_id, humanId]);
  const contradictory = await (await fetch(route + '?mode=ranked&days=32')).json();
  assert.equal(contradictory.bots.filter(b => b.id === 'human').reduce((n, b) => n + b.matches, 0), 1, 'contradictory settlements exclude the whole match');
  await pool.query('UPDATE ranked_settlements SET won=NOT won WHERE match_id=$1 AND player_id=$2', [first.match_id, humanId]);
  await pool.query("UPDATE ranked_bot_accounts SET profile=jsonb_set(profile,'{version}','\"1.0\"')");
  await until(async () => (await pool.query("SELECT 1 FROM ranked_matches WHERE mode='ranked_bots' AND status='active' LIMIT 1")).rowCount, 'active game for lock-loss proof');
  const expired = (await pool.query(`SELECT s.token FROM sessions s JOIN ranked_bot_accounts b ON b.player_id=s.player_id
    WHERE EXISTS (SELECT 1 FROM ranked_matches m WHERE m.status='active' AND s.player_id IN (m.seat_a_player_id,m.seat_b_player_id)) LIMIT 1`)).rows[0];
  assert.ok(expired);
  await pool.query('DELETE FROM sessions WHERE token=$1', [expired.token]);
  const authFailure = await until(() => workerFailure, 'revoked session forces supervised recovery', 25000);
  assert.match(authFailure.message, /session or profile was refused/);
  await assert.rejects(worker, /session or profile was refused/);
  const authRestart = events.length;
  stop = new AbortController(); startWorker();
  await until(() => { if (workerFailure) throw workerFailure; return events.slice(authRestart).some(e => e.event === 'joined'); }, 'fresh sessions rejoin after revocation');
  const owner = (await pool.query("SELECT pid FROM pg_locks WHERE locktype='advisory' AND classid=731204 AND objid=2 AND granted")).rows;
  assert.equal(owner.length, 1);
  await pool.query('SELECT pg_terminate_backend($1)', [owner[0].pid]);
  await assert.rejects(worker, /database lock lost/);
  assert.equal((await pool.query('SELECT count(*) AS n FROM sessions s JOIN ranked_bot_accounts b ON b.player_id=s.player_id')).rows[0].n, '0');
  assert.equal((await pool.query('SELECT count(*) AS n FROM players')).rows[0].n, '5');
  // No client may accidentally enter the legacy peer-hosted queue.
  const ended = once(relay, 'exit'); killTree(relay); await ended;
  relay = launchRelay('0');
  await until(() => relayLog.includes('Relay server listening'), 'legacy relay startup');
  const decksBefore = (await pool.query('SELECT count(*) AS n FROM decks')).rows[0].n;
  await assert.rejects(runRankedBots({ pool, godotBin: process.env.GODOT_BIN, relayUrl: wsUrl, log: () => {} }), /authoritative-ranked service/);
  assert.equal((await pool.query('SELECT count(*) AS n FROM decks')).rows[0].n, decksBefore, 'legacy refusal occurs before drafting or queueing');
  t.diagnostic(`All four queued; ${finished.length} autonomous match completed; normal human/bot outcomes and private ranked stats verified`);
});
