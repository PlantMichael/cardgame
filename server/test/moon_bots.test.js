'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { Pool } = require('pg');
const { initLegacySchema } = require('../schema_legacy');
const { initBotSchema, normalizeBotMatch, saveBotMatch } = require('../bot_matches');
const { jobAt, runWorker, simulate, writeState, readState } = require('../bot_worker');
const { createRelayServer } = require('../card_winrates');
const { disposableDatabase, PROJECT_DIR } = require('./helpers');

test('schedule covers each pairing, both first players and every faction combination', () => {
  const jobs = Array.from({ length: 500 }, (_, i) => jobAt(i));
  const pairs = new Map();
  for (const j of jobs) {
    const key = `${j.a}/${j.b}`;
    if (!pairs.has(key)) pairs.set(key, new Set());
    pairs.get(key).add(`${j.factionA}/${j.factionB}/${j.first}`);
  }
  assert.equal(pairs.size, 10);
  for (const seen of pairs.values()) assert.equal(seen.size, 50);
});

test('a policy upgrade saves an older completed pending simulation without relabeling or replaying it', {
  skip: !process.env.DATABASE_URL || !disposableDatabase() ? 'requires disposable DATABASE_URL' : false,
  timeout: 15000,
}, async t => {
  const admin = new Pool({connectionString:process.env.DATABASE_URL,ssl:false});
  const schema = `moon_pending_${process.pid}`;
  await admin.query(`CREATE SCHEMA ${schema}`);
  const url = new URL(process.env.DATABASE_URL); url.searchParams.set('options', `-c search_path=${schema}`);
  const pool = new Pool({connectionString:url.href,ssl:false});
  const dir = await fs.mkdtemp(path.join(os.tmpdir(),'moon-worker-test-'));
  t.after(async()=>{
    await pool.end(); await admin.query(`DROP SCHEMA ${schema} CASCADE`); await admin.end();
    assert.equal(path.dirname(dir),path.resolve(os.tmpdir()));
    assert.ok(path.basename(dir).startsWith('moon-worker-test-'));
    await fs.rm(dir,{recursive:true,force:true});
  });
  const starters = require('../../data/starters.json');
  const result = { a:{id:'io',name:'Io',version:'1.0',level:10,style:'tempo'},
    b:{id:'ganymede',name:'Ganymede',version:'1.0',level:1,style:'random'},
    deckA:starters[0].card_ids,deckB:starters[1].card_ids,factionA:0,factionB:1,
    first:'a',winner:'a',seed:17,turns:3,rulesVersion:3,engineVersion:2 };
  assert.throws(()=>normalizeBotMatch(result),/wrong release/, 'new producer validation stays current');
  const pending = {id:randomUUID(),result};
  const file = path.join(dir,'state.json');
  await writeState(file,{cursor:2,pending});
  const worker = {pool,stateDir:dir,matches:1,godotBin:'must-not-replay-a-finished-game',signal:t.signal,log:()=>{}};
  assert.equal(await runWorker(worker),1);
  assert.deepEqual((await pool.query('SELECT result FROM bot_matches WHERE match_id=$1',[pending.id])).rows[0].result,result);
  assert.deepEqual(await readState(file),{cursor:3});
  await writeState(file,{cursor:2,pending});
  assert.equal(await runWorker(worker),1);
  assert.equal((await pool.query('SELECT count(*) AS n FROM bot_matches')).rows[0].n,'1');
});

test('worker plays actual named bots, persists/replays results and feeds only simulation HTTP stats', {
  skip: !process.env.GODOT_BIN || !process.env.DATABASE_URL || !disposableDatabase() ? 'requires Godot and disposable DATABASE_URL' : false,
  timeout: 240000,
}, async t => {
  const admin = new Pool({ connectionString: process.env.DATABASE_URL, ssl: false });
  const schema = `moon_bots_${process.pid}`;
  await admin.query(`CREATE SCHEMA ${schema}`);
  const url = new URL(process.env.DATABASE_URL); url.searchParams.set('options', `-c search_path=${schema}`);
  const pool = new Pool({ connectionString: url.toString(), ssl: false, query_timeout: 5000 });
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'moon-worker-test-'));
  const servers = [];
  let clock = Date.now() + 60000;
  const root = path.join(PROJECT_DIR, 'catalog/public');
  const { createCatalogServer } = await import('../../catalog/src/server.mjs');
  const { projectBotStats } = await import('../../catalog/src/bot-matchups.mjs');
  const release = JSON.parse(await fs.readFile(path.join(root, 'data/cards.json'), 'utf8'));
  const catalog = new Map(release.cards.filter(c => c.collectible && !c.isToken).map(c => [c.id, c]));
  t.after(async () => {
    for (const [server, wss] of servers) {
      if (wss) await new Promise(r => wss.close(r));
      server.closeAllConnections(); await new Promise(r => server.close(r));
    }
    await pool.end(); await admin.query(`DROP SCHEMA ${schema} CASCADE`); await admin.end();
    assert.equal(path.dirname(dir), path.resolve(os.tmpdir()));
    assert.ok(path.basename(dir).startsWith('moon-worker-test-'));
    await fs.rm(dir, { recursive: true, force: true });
  });
  await initLegacySchema(pool);
  await pool.query("INSERT INTO players (username,password_hash,salt) VALUES ('synthetic_observer','synthetic','synthetic')");
  const relay = createRelayServer({ pool, publicRoot: root, now: () => clock });
  servers.push([relay.server, relay.wss]);
  await new Promise(r => relay.server.listen(0, '127.0.0.1', r));
  const origin = `http://127.0.0.1:${relay.server.address().port}`;
  const proxy = createCatalogServer(root, { statsOrigin: origin }); servers.push([proxy]);
  await new Promise(r => proxy.listen(0, '127.0.0.1', r));
  const publicOrigin = `http://127.0.0.1:${proxy.address().port}`;
  const route = '/data/stats/bot-matchups.json';
  async function stats(originUrl = publicOrigin, suffix = '') {
    const response = await fetch(originUrl + route + suffix);
    const text = await response.text(); assert.equal(response.status, 200, text); return JSON.parse(text);
  }
  assert.equal((await stats()).games, 0, 'a pre-rollout database has honest empty bot stats');
  await initBotSchema(pool); await initBotSchema(pool);
  assert.equal((await pool.query('SELECT username FROM players')).rows[0].username, 'synthetic_observer', 'repeatable additive upgrade preserves populated accounts');
  const before = await (await fetch(origin + '/data/stats/card-winrates.json')).json();
  await writeState(path.join(dir, 'state.json'), { cursor: 2 }); // Io vs Ganymede in real production schedule.
  const worker = { pool, godotBin: process.env.GODOT_BIN, stateDir: dir, matches: 1, pauseMs: 0, signal: t.signal, log: () => {} };
  assert.equal(await runWorker(worker), 1);
  const stored = (await pool.query('SELECT match_id,result FROM bot_matches')).rows[0];
  assert.equal(stored.result.a.name, 'Io'); assert.equal(stored.result.b.name, 'Ganymede');
  assert.equal(stored.result.a.version, '1.0');
  assert.ok(['a', 'b', 'draw'].includes(stored.result.winner));
  assert.equal(stored.result.a.level, 10); assert.equal(stored.result.b.level, 4);
  assert.equal(stored.result.b.version, '1.1'); assert.equal(stored.result.b.style, '');
  assert.equal((await readState(path.join(dir, 'state.json'))).cursor, 3);
  // Simulate a lost acknowledgment: the pending game already exists in PostgreSQL.
  await writeState(path.join(dir, 'state.json'), { cursor: 2, pending: { id: stored.match_id, result: stored.result } });
  assert.equal(await runWorker({ ...worker, godotBin: 'must-not-start-a-second-game' }), 1);
  assert.equal((await pool.query('SELECT count(*) AS n FROM bot_matches')).rows[0].n, '1');
  assert.equal((await readState(path.join(dir, 'state.json'))).cursor, 3);
  await assert.rejects(saveBotMatch(pool, stored.match_id, { ...stored.result, winner: stored.result.winner === 'a' ? 'b' : 'a' }), /different result/);

  // The other two personalities also finish through the actual engine/worker seam.
  const second = await simulate({ a: 'callisto', b: 'europa', factionA: 1, factionB: 2, first: 'b' },
    { godotBin: process.env.GODOT_BIN, signal: t.signal });
  const secondId = randomUUID();
  await saveBotMatch(pool, secondId, second);
  assert.equal(second.a.style, 'combo'); assert.equal(second.b.style, 'aggro');
  const secondSaved = (await pool.query('SELECT result FROM bot_matches WHERE match_id = $1', [secondId])).rows[0].result;
  assert.deepEqual([secondSaved.a.name, secondSaved.a.version, secondSaved.a.level, secondSaved.b.name, secondSaved.b.version, secondSaved.b.level],
    ['Callisto', '1.0', 8, 'Europa', '1.0', 8]);
  for (const bad of [{ winner: '' }, { turns: 0 }, { a: { ...stored.result.a, level: 1 } },
    { deckA: ['gen_str_005', ...stored.result.deckA.slice(1)] }, { deckA: Array(40).fill('g_001') }]) {
    await assert.rejects(saveBotMatch(pool, randomUUID(), { ...stored.result, ...bad }));
  }
  // Draws and historical releases are synthetic saved fixtures based on a real producer result.
  const draw = { ...stored.result, winner: 'draw' };
  await saveBotMatch(pool, randomUUID(), draw);
  for (const delta of [{ rulesVersion: stored.result.rulesVersion + 1 }, { engineVersion: stored.result.engineVersion + 1 },
    { a: { ...stored.result.a, version: '0.9' } }]) {
    await pool.query('INSERT INTO bot_matches (match_id,result) VALUES ($1,$2)', [randomUUID(), { ...stored.result, ...delta }]);
  }
  // Identical compositions for different bots stay separate by profile identity.
  const mirror = { ...stored.result, deckB: stored.result.deckA, factionB: stored.result.factionA };
  await saveBotMatch(pool, randomUUID(), mirror);
  clock += 61000;
  const data = await stats();
  assert.equal(data.games, 7);
  assert.equal(data.bots.reduce((n, b) => n + b.matches, 0), 14);
  assert.equal(data.decks.reduce((n, d) => n + d.matches, 0), 14);
  assert.equal(data.matchups.reduce((n, m) => n + m.matches, 0), 14);
  assert.equal(data.bots.filter(b => b.id === 'io').length, 4, 'rule, engine, and release cohorts do not collapse');
  assert.ok(data.bots.some(b => b.version === '0.9'), 'historical snapshot is not relabeled');
  const drawSeat = data.bots.find(b => b.id === 'ganymede' && b.rulesVersion === stored.result.rulesVersion && b.engineVersion === stored.result.engineVersion);
  assert.equal(drawSeat.draws, 1); assert.equal(drawSeat.winRate, drawSeat.wins / (drawSeat.matches - drawSeat.draws));
  const sameDeck = data.decks.filter(d => JSON.stringify(d.cards) === JSON.stringify(data.decks.find(x => x.botKey.startsWith('io@1.0/')).cards));
  assert.ok(sameDeck.some(d => d.botKey.startsWith('ganymede@')), 'mirror deck retains the other bot identity');
  assert.deepEqual(data, await stats(origin));
  const after = await (await fetch(origin + '/data/stats/card-winrates.json')).json();
  assert.deepEqual(after.cards, before.cards, 'isolated simulations never enter shared card statistics');
  assert.equal((await pool.query('SELECT count(*) AS n FROM ranked_settlements')).rows[0].n, '0');
  assert.equal((await pool.query('SELECT ranked_wins,ranked_losses FROM players')).rows[0].ranked_wins, 0);

  // A database failure must retain the durable pending result for the next run.
  await writeState(path.join(dir, 'state.json'), { cursor: 2, pending: { id: stored.match_id, result: stored.result } });
  await pool.query(`CREATE FUNCTION reject_bot_write() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'synthetic write failure'; END $$;
    CREATE TRIGGER reject_bot_write BEFORE INSERT OR UPDATE ON bot_matches FOR EACH ROW EXECUTE FUNCTION reject_bot_write()`);
  const retryStop = new AbortController();
  assert.equal(await runWorker({ ...worker, signal: retryStop.signal,
    log: line => { if (line.startsWith('Bot attempt failed')) retryStop.abort(); } }), 0);
  assert.equal((await readState(path.join(dir, 'state.json'))).pending.id, stored.match_id);
  await pool.query('DROP TRIGGER reject_bot_write ON bot_matches');
  assert.equal(await runWorker({ ...worker, godotBin: 'must-not-start-a-second-game' }), 1);
  assert.equal((await pool.query('SELECT count(*) AS n FROM bot_matches')).rows[0].n, '7');

  // Hostile upstream data cannot leak extra fields or accept incoherent stats.
  const extra = structuredClone(data); extra.secret = 'private'; extra.bots[0].player_id = 99;
  assert.ok(!JSON.stringify(projectBotStats(extra, catalog, 30)).includes('player_id'));
  for (const mutate of [d => { d.bots[0].wins += 1; }, d => { d.decks[0].cards[0].id = 'gen_str_005'; },
    d => { d.matchups[0].opponentDeckKey = 'missing'; }, d => { d.bots[0].rulesVersion += 1; },
    d => { d.matchups[0].first.matches += 1; }]) {
    const bad = structuredClone(data); mutate(bad); assert.throws(() => projectBotStats(bad, catalog, 30));
  }
  for (const originUrl of [origin, publicOrigin]) {
    for (const bad of ['?days=0', '?days=366', '?days=1&days=2', '?mode=ranked_ai']) assert.equal((await fetch(originUrl + route + bad)).status, 400);
    const head = await fetch(originUrl + route, { method: 'HEAD' }); assert.equal(head.status, 200); assert.equal(await head.text(), '');
    const options = await fetch(originUrl + route, { method: 'OPTIONS' }); assert.equal(options.status, 204); assert.equal(options.headers.get('access-control-allow-origin'), '*');
    assert.equal((await fetch(originUrl + route, { method: 'POST' })).status, 405);
  }
  const lock = await pool.connect();
  await lock.query('SELECT pg_advisory_lock(731204, 1)');
  await assert.rejects(runWorker(worker), /another moon-bot worker/);
  lock.release(true);
  // Abort cleans up an actual engine process and cannot produce an unfinished result.
  const abort = new AbortController();
  const active = simulate({ a: 'io', b: 'callisto', factionA: 0, factionB: 1, first: 'a' }, { godotBin: process.env.GODOT_BIN, signal: abort.signal });
  setTimeout(() => abort.abort(), 200);
  await assert.rejects(active, /bot process failed|stopped/);
  const timed = simulate({ a: 'io', b: 'callisto', factionA: 0, factionB: 1, first: 'a' },
    { godotBin: process.env.GODOT_BIN, signal: new AbortController().signal, timeoutMs: 200 });
  await assert.rejects(timed, /timeout/);
  let reads = 0;
  const query = pool.query.bind(pool);
  pool.query = (...args) => { if (args[0]?.text?.startsWith('SELECT result FROM bot_matches')) reads++; return query(...args); };
  clock += 61000;
  const concurrent = await Promise.all([stats(origin), stats(origin), stats(origin)]);
  assert.equal(reads, 1, 'concurrent snapshots coalesce the real database read');
  assert.deepEqual(concurrent[0], concurrent[1]);
  await stats(origin); assert.equal(reads, 1, 'successful snapshot is cached until expiry');
  await pool.query('ALTER TABLE bot_matches RENAME COLUMN result TO unavailable_result');
  clock += 61000;
  assert.equal((await fetch(publicOrigin + route)).status, 503, 'expiry cannot serve stale success on a database failure');
  await pool.query('ALTER TABLE bot_matches RENAME COLUMN unavailable_result TO result');
  assert.equal((await fetch(publicOrigin + route)).status, 200, 'failed refresh is not cached');
  // A corrupt saved result fails closed rather than partly publishing a deck.
  const corruptId = randomUUID();
  await pool.query('INSERT INTO bot_matches (match_id,result) VALUES ($1,$2)', [corruptId, { ...stored.result, deckA: ['gen_str_005', ...stored.result.deckA.slice(1)] }]);
  clock += 61000;
  assert.equal((await fetch(publicOrigin + route)).status, 503);
  await pool.query('DELETE FROM bot_matches WHERE match_id = $1', [corruptId]);
  await pool.query('INSERT INTO bot_matches (match_id,result) SELECT gen_random_uuid(), $1 FROM generate_series(1,50001)', [stored.result]);
  assert.equal((await fetch(origin + route)).status, 503, 'source ceiling refuses whole data rather than silently truncating');
});
