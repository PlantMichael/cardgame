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
const { initSchema, PgStore } = require('../authoritative/schema');
const { profiles } = require('../bot_matches');
const { computeOutcome } = require('../authoritative/settle');
const { provisionRankedBots } = require('../ranked_bot_accounts');
const { runRankedBots, rankedBotSessions } = require('../ranked_bot_worker');
const { ratingBandAt, matchQueuedPlayers } = require('../ranked_queue');
const { rankedAILevel } = require('../ranked_bot_ai');
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
  async take(type, matchId = null, timeout = 15000) {
    return until(() => { const i = this.messages.findIndex(m => m.type === type && (!matchId || m.match_id === matchId)); return i < 0 ? null : this.messages.splice(i, 1)[0]; }, type, timeout);
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

test('ranked AI difficulty follows named tiers and Legend', () => {
  for (let bracket = 0; bracket < 21; bracket++) {
    assert.equal(rankedAILevel(bracket, false), [3,3,3,4,4,4,5,5,5,6,6,6,7,7,7,8,8,8,9,9,9][bracket]);
    assert.equal(rankedAILevel(bracket, true), 10);
  }
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
  assert.deepEqual(await rankedBotSessions(pool, accounts), accounts, 'legacy services keep their existing refusal path');
  await pool.query("UPDATE players SET rating=100,ranked_losses=9 WHERE username='Ganymede'");
  await initLegacySchema(pool); await initSchema(pool); await initSchema(pool);
  await pool.query(`INSERT INTO ranked_matches (match_id,status,rules_version,seed,first_seat,deck_a,deck_b)
    VALUES ('legacy_row','finished',3,1,'a','["g_001"]','["cr_002"]')`);
  await pool.query('ALTER TABLE ranked_matches DROP COLUMN bot_a, DROP COLUMN bot_b, DROP COLUMN engine_version');
  await initSchema(pool); await initSchema(pool);
  assert.deepEqual((await pool.query("SELECT mode,bot_a,bot_b,engine_version FROM ranked_matches WHERE match_id='legacy_row'")).rows[0],
    { mode: 'authoritative', bot_a: null, bot_b: null, engine_version: null });
  const legacy = { id:'ganymede',name:'Ganymede',version:'1.0',level:1,style:'random' };
  const owned = (await pool.query('SELECT bot_id,player_id FROM ranked_bot_accounts')).rows;
  const ganyId = owned.find(b => b.bot_id === 'ganymede').player_id;
  await pool.query('UPDATE ranked_bot_accounts SET profile=$1 WHERE bot_id=$2', [legacy,'ganymede']);
  const store = new PgStore(pool);
  await store.createMatch({ match_id:'old_policy',rules_version:3,seed:17,first_seat:'a',
    seat_a_player_id:owned.find(b=>b.bot_id==='io').player_id,seat_b_player_id:ganyId,
    deck_a:['g_001'],deck_b:['cr_002'],mode:'ranked_bots',bot_a:profiles[0],bot_b:legacy,engine_version:2 });
  const again = await provisionRankedBots(pool);
  assert.equal((await pool.query('SELECT count(*) AS n FROM players')).rows[0].n, '4');
  const gany = (await pool.query("SELECT rating,ranked_losses FROM players WHERE username='Ganymede'")).rows[0];
  assert.deepEqual(gany, { rating: 100, ranked_losses: 9 });
  assert.ok(again.every(a => !accounts.some(old => old.token === a.token)));
  assert.deepEqual((await pool.query("SELECT player_id,profile FROM ranked_bot_accounts WHERE bot_id='ganymede'")).rows[0],
    { player_id:ganyId, profile:{...legacy,version:'1.1',level:4,style:''} });
  const resumed = await rankedBotSessions(pool, again);
  assert.deepEqual(resumed.find(a=>a.id==='ganymede').active_match,{id:'old_policy',profile:legacy});
  assert.deepEqual((await store.loadActiveMatches())[0].bot_b,legacy, 'provisioning never relabels old matches');
  await store.createMatch({...(await store.loadActiveMatches())[0],match_id:'duplicate_policy'});
  await assert.rejects(rankedBotSessions(pool,again), /multiple active matches/);
  await store.setStatus('duplicate_policy',{status:'voided'});
  await pool.query('UPDATE ranked_matches SET bot_b=$1 WHERE match_id=$2',[profiles[0],'old_policy']);
  await assert.rejects(rankedBotSessions(pool,again), /identity mismatch/);
  await store.setStatus('old_policy',{status:'finished'});
  assert.deepEqual(await rankedBotSessions(pool,again),again, 'completed matches cannot retain an old policy');
});

test('four real ranked clients queue, play, settle normally, reconnect and publish a separate ranked cohort', {
  skip: dbSkip || (!process.env.GODOT_BIN ? 'requires GODOT_BIN' : false), timeout: 480000,
}, async t => {
  const { pool, url, cleanup } = await database(t, 'ranked_bots_live', false);
  await initSchema(pool);
  const probeAccounts = await provisionRankedBots(pool);
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'ranked-bots-relay-test-'));
  // Checked-out worker connections use this proxy. Map protocol backend PIDs
  // through local loopback ports, which also works across Docker's DB-side NAT.
  const transports = new Set();
  const target = new URL(url);
  const lockProxy = net.createServer(front => {
    const back = net.connect(Number(target.port), target.hostname);
    const pair = { front, back, blackholed: false };
    transports.add(pair);
    front.pipe(back); back.pipe(front);
    front.on('error', () => back.destroy());
    front.on('close', () => { back.destroy(); transports.delete(pair); });
    back.on('error', () => { if (!pair.blackholed) front.destroy(); });
    back.on('close', () => { if (!pair.blackholed) front.end(); });
  });
  await new Promise(resolve => lockProxy.listen(0, '127.0.0.1', resolve));
  const lockUrl = new URL(url); lockUrl.hostname = '127.0.0.1'; lockUrl.port = String(lockProxy.address().port);
  const lockPool = new Pool({ connectionString: lockUrl.href, ssl: false, query_timeout: 10000 });
  lockPool.on('connect', client => {
    const pair = [...transports].find(p => p.front.remotePort === client.connection.stream.localPort);
    if (pair) pair.backendPid = client.processID;
  });
  const workerPool = { connect: () => lockPool.connect(), query: (...args) => pool.query(...args) };
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
          result.rows[0]?.bot_profile && values[0] !== process.env.QUEUE_FAULT_SKIP && failed.size < 4 && !failed.has(values[0])) {
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
        APPDATA: tmp, XDG_DATA_HOME: tmp, PROJECT_DIR, QUEUE_FAULT_SKIP: probeAccounts[0].token }, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
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
    await lockPool.end();
    for (const { front, back } of transports) { front.destroy(); back.destroy(); }
    await new Promise(resolve => lockProxy.close(resolve));
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
  human.send({ type: 'resume_session' });
  const resumed = await human.take('login_result');
  assert.equal(resumed.success, true);
  const liveRulesVersion = resumed.rules_version;
  assert.ok(Number.isInteger(liveRulesVersion) && liveRulesVersion > 0, 'use the rules advertised by the actual relay/host handshake');
  human.send({ type: 'save_deck', name: 'human', faction_idx: 0, card_ids: ['g_001', 'g_002'] });
  assert.equal((await human.take('save_deck_result')).success, true);
  human.send({ type: 'ranked_bot_ai_start', match_id: 'ai_1_1' });
  assert.equal((await human.take('ranked_bot_ai_ready')).success, false, 'a human token cannot enter the bot AI path');
  const probe = await Client.open(wsUrl); clients.push(probe); probe.token = probeAccounts.find(a => a.id === 'io').token;
  await pool.query("UPDATE players SET rank_bracket=20,rank_in_legend=true WHERE username='Io'");
  probe.send({ type: 'ranked_bot_ai_start', match_id: 'ai_1_2' });
  assert.equal((await probe.take('ranked_bot_ai_ready')).ai_level, 10, 'relay selects Legend difficulty from the persisted rank');
  probe.send({ type: 'queue_ranked', deck_name: 'Sapiens Starter', rules_version: liveRulesVersion });
  assert.equal((await probe.take('ranked_refused')).reason, 'in_ai_match');
  const starters = require('../../data/starters.json');
  const probeSummary = { player_deck: starters[0].card_ids, opponent_deck: starters[1].card_ids,
    ai_level: 10, ai_version: 3, rules_version: liveRulesVersion, turns: 1, first_player: 'player' };
  for (const invalid of [{ ai_match: { ...probeSummary, ai_level: 3 } },
    { ai_match: { ...probeSummary, player_deck: ['g_001'] } },
    { token: probeAccounts.find(a => a.id === 'callisto').token, ai_match: probeSummary }]) {
    probe.send({ type: 'report_ranked_result', match_id: 'ai_1_2', won: true, ...invalid });
    assert.equal((await probe.take('ranked_result_ack')).success, false, 'wrong difficulty, invalid deck or different account cannot consume an AI admission');
  }
  assert.equal((await pool.query('SELECT count(*) AS n FROM ranked_settlements')).rows[0].n, '0');
  probe.send({ type: 'ranked_bot_ai_cancel', match_id: 'ai_1_2' }); probe.ws.terminate();
  await pool.query('DELETE FROM sessions WHERE token=ANY($1::text[])', [probeAccounts.map(a => a.token)]);
  await pool.query("UPDATE players SET rank_bracket=0,rank_in_legend=false WHERE username='Io'");
  human.send({ type: 'queue_ranked', deck_name: 'human', rules_version: liveRulesVersion, bot_profile: { id: 'io', version: '1.0' } });
  let workerFailure;
  const startWorker = () => {
    workerFailure = undefined;
    worker = runRankedBots({ pool: workerPool, godotBin: process.env.GODOT_BIN, relayUrl: wsUrl, signal: stop.signal,
      onEvent: e => events.push(e), log: () => {} });
    worker.catch(e => { workerFailure = e; });
  };
  startWorker();
  const statusUrl = httpUrl + '/data/bots/status.json';
  const fleet = await until(async () => {
    const data = await (await fetch(statusUrl)).json();
    return data.bots?.every(b => b.activity === 'playing_ai') ? data : null;
  }, 'fresh workers start with rank-matched AI and expose their actual activity', 20000);
  const { validStatus } = await import('../../website/bots-core.mjs');
  assert.ok(validStatus(fleet));
  assert.deepEqual(fleet.bots.map(b => b.id), ['io','callisto','europa','ganymede']);
  const found = await human.take('ranked_match_found', null, 180000);
  assert.equal(found.server_run, true);
  assert.ok(found.opponent_name.endsWith(`[Bot ${found.opponent_bot.version}]`));
  assert.ok(['io', 'callisto', 'europa', 'ganymede'].includes(found.opponent_bot.id));
  human.send({ type: 'match_join', match_id: found.match_id });
  const view = await human.take('match_view', found.match_id);
  const first = (await pool.query('SELECT * FROM ranked_matches WHERE match_id=$1', [found.match_id])).rows[0];
  assert.equal(view.view.opening_bonus.player_id, first.first_seat === 'a' ? 'guest' : 'host', 'human/bot ranked match has the same second-player opening');
  const opponentId = first[view.seat === 'a' ? 'seat_b_player_id' : 'seat_a_player_id'];
  const aiOutcome = (await pool.query(`SELECT match_id,won,outcome,ai_match FROM ranked_settlements WHERE player_id=$1 AND ai_match IS NOT NULL ORDER BY settled_at LIMIT 1`, [opponentId])).rows[0];
  const aiOnly = await (await fetch(httpUrl + '/data/stats/deck-matchups.json?mode=all&days=29')).json();
  assert.ok(aiOnly.games > 0 && aiOnly.decks.every(d => d.testers === 0), 'bot AI games feed pooled results without inventing human testers');
  assert.equal((await (await fetch(httpUrl + `/data/stats/deck-matchups.json?mode=ranked_ai&aiLevel=3&rulesVersion=${liveRulesVersion}&aiVersion=2`)).json()).games, 0, 'the human-only AI filter excludes bot-controlled games');
  const retriedAI = await Client.open(wsUrl); clients.push(retriedAI);
  retriedAI.token = (await pool.query('SELECT token FROM sessions WHERE player_id=$1 ORDER BY created_at DESC LIMIT 1', [opponentId])).rows[0].token;
  retriedAI.send({ type: 'ranked_bot_ai_start', match_id: aiOutcome.match_id });
  assert.equal((await retriedAI.take('ranked_bot_ai_ready')).settled, true, 'completed admission can reconnect after a lost acknowledgment');
  retriedAI.send({ type: 'report_ranked_result', match_id: aiOutcome.match_id, won: !aiOutcome.won });
  const replayedAI = await retriedAI.take('ranked_result_ack');
  assert.equal(replayedAI.replayed, true);
  assert.equal((await pool.query('SELECT count(*) AS n FROM ranked_settlements WHERE match_id=$1', [aiOutcome.match_id])).rows[0].n, '1');
  assert.deepEqual((await pool.query('SELECT outcome FROM ranked_settlements WHERE match_id=$1', [aiOutcome.match_id])).rows[0].outcome, aiOutcome.outcome);
  retriedAI.ws.terminate();
  human.send({ type: 'match_concede', match_id: found.match_id });
  const lost = await human.take('match_over', found.match_id);
  assert.equal(lost.ranked_outcome.success, true);
  assert.equal(lost.ranked_outcome.rank_lp, 0); assert.equal(lost.ranked_outcome.ranked_losses, 1);
  assert.equal(lost.ranked_outcome.rating, 984, 'human takes the normal equal-rating Elo loss');
  const humanId = (await pool.query("SELECT id FROM players WHERE username='ranked_human'")).rows[0].id;
  assert.equal(first.mode, 'ranked_bots');
  assert.equal(first[view.seat === 'a' ? 'bot_a' : 'bot_b'], null, 'client-supplied bot fields cannot change identity');
  assert.equal(first[view.seat === 'a' ? 'bot_b' : 'bot_a'].version, profiles.find(p=>p.id===found.opponent_bot.id).version);
  assert.ok(aiOutcome.ai_match.bot_profile, 'the actual AI completion precedes normal queue entry');
  assert.equal(aiOutcome.ai_match.ai_level, 3);
  assert.equal(aiOutcome.outcome.rating, 1000, 'local ranked AI never moves matchmaking Elo');
  const expectedBot = computeOutcome(aiOutcome.outcome, true, 1000);
  const wonRow = (await pool.query('SELECT rating,rank_lp,ranked_wins FROM players WHERE id=$1', [opponentId])).rows[0];
  assert.deepEqual(wonRow, { rating: expectedBot.rating, rank_lp: expectedBot.rank_lp, ranked_wins: expectedBot.ranked_wins }, 'bot receives normal full ranked win after its AI game');

  // A human win receives ordinary rewards too, through a canonical concede.
  human.send({ type: 'queue_ranked', deck_name: 'human', rules_version: liveRulesVersion });
  const secondFound = await human.take('ranked_match_found', null, 180000);
  human.send({ type: 'match_join', match_id: secondFound.match_id });
  const secondView = await human.take('match_view', secondFound.match_id);
  const secondMatch = (await pool.query('SELECT * FROM ranked_matches WHERE match_id=$1', [secondFound.match_id])).rows[0];
  const secondOpponentId = secondMatch[secondView.seat === 'a' ? 'seat_b_player_id' : 'seat_a_player_id'];
  const before = (await pool.query('SELECT * FROM players WHERE id=$1', [humanId])).rows[0];
  const beforeOpp = (await pool.query('SELECT rating FROM players WHERE id=$1', [secondOpponentId])).rows[0];
  const botToken = (await pool.query('SELECT token FROM sessions WHERE player_id=$1 ORDER BY created_at DESC LIMIT 1', [secondOpponentId])).rows[0].token;
  const scriptedBot = await Client.open(wsUrl); clients.push(scriptedBot); scriptedBot.token = botToken;
  scriptedBot.send({ type: 'ranked_bot_ai_start', match_id: 'ai_1_3' });
  const activeRefusal = await scriptedBot.take('ranked_bot_ai_ready');
  assert.equal(activeRefusal.success, false); assert.equal(activeRefusal.active_match_id, secondFound.match_id);
  scriptedBot.send({ type: 'match_join', match_id: secondFound.match_id }); await scriptedBot.take('match_view', secondFound.match_id);
  scriptedBot.send({ type: 'match_concede', match_id: secondFound.match_id });
  const win = await human.take('match_over', secondFound.match_id);
  const expected = computeOutcome(before, true, beforeOpp.rating);
  for (const key of ['rating', 'rank_lp', 'ranked_wins', 'ranked_losses']) assert.equal(win.ranked_outcome[key], expected[key]);

  await until(() => {
    if (workerFailure) throw workerFailure;
    return ['io', 'callisto', 'europa', 'ganymede'].every(id => events.filter(e => e.event === 'queued' && e.bot === id).length >= 2);
  }, 'all four retry queue entry after transient database failure', 180000);
  for (const id of ['io','callisto','europa','ganymede']) {
    const own = events.filter(e => e.bot === id);
    assert.equal(own.find(e => e.event === 'ai_started').ai_level, 3);
    const aiDone = own.findIndex(e => e.event === 'completed' && e.opponent === 'ranked_ai');
    assert.ok(aiDone >= 0 && aiDone < own.findIndex(e => e.event === 'queued'));
  }
  await until(() => ['io','callisto','europa','ganymede'].some(id => {
    const own = events.filter(e => e.bot === id), done = own.findIndex(e => e.event === 'completed' && !e.opponent);
    return done >= 0 && own.slice(done + 1).some(e => e.event === 'ai_started');
  }), 'queue completion returns to AI', 180000);

  const inFlight = await until(async () => {
    const ids = (await pool.query("SELECT match_id FROM ranked_matches WHERE status='active' AND mode='ranked_bots'")).rows.map(r => r.match_id);
    return ids.length ? ids : null;
  }, 'an actual queue match is available for restart recovery', 180000);
  const restartIndex = events.length;
  stop.abort(); await worker;
  scriptedBot.ws.terminate();
  const offline = await until(async () => {
    const data = await (await fetch(statusUrl)).json();
    return data.bots?.every(b => b.activity === 'offline') ? data : null;
  }, 'closed actual worker sockets leave offline status', 15000);
  const savedRanks = (await pool.query(`SELECT b.bot_id,p.rank_bracket,p.rank_in_legend,p.rank_legend_rating,p.rank_lp
    FROM ranked_bot_accounts b JOIN players p ON p.id=b.player_id`)).rows;
  for (const bot of offline.bots) {
    const saved = savedRanks.find(r => r.bot_id === bot.id);
    assert.deepEqual(bot.rank, { bracket: saved.rank_bracket, inLegend: saved.rank_in_legend,
      legendRating: saved.rank_legend_rating, lp: saved.rank_lp });
  }
  stop = new AbortController(); startWorker();
  await until(() => { if (workerFailure) throw workerFailure; return inFlight.every(id => events.slice(restartIndex).some(e => e.event === 'joined' && e.match_id === id)); }, 'fresh worker rejoins existing matches');

  // Real bot-v-bot games must progress and finish without scripted commands.
  const finished = await until(async () => {
    if (workerFailure) throw workerFailure;
    const rows = (await pool.query("SELECT * FROM ranked_matches WHERE mode='ranked_bots' AND status='finished' AND bot_a IS NOT NULL AND bot_b IS NOT NULL AND end_reason='completed'")).rows;
    return rows.length ? rows : null;
  }, 'autonomous bot-v-bot completion', 210000);
  assert.ok(finished[0].facts.turns > 1);
  const initialActions = (await pool.query('SELECT kind,command FROM ranked_match_actions WHERE match_id=$1 ORDER BY seq LIMIT 3', [finished[0].match_id])).rows;
  assert.equal(initialActions[0].kind, 'answer', 'bot answers its opening rather than timing out');
  assert.equal(initialActions[0].command.type, 'answer_choice');
  assert.ok(initialActions.slice(1).every(a => a.command.type === 'mulligan'), 'both mulligans follow the bot opening answer');
  const active = (await pool.query("SELECT * FROM ranked_matches WHERE status='active' AND mode='ranked_bots' LIMIT 1")).rows[0];
  if (active) {
    const playerId = active.bot_a ? active.seat_a_player_id : active.seat_b_player_id;
    const token = (await pool.query('SELECT token FROM sessions WHERE player_id=$1 ORDER BY created_at DESC LIMIT 1', [playerId])).rows[0].token;
    const reconnect = await Client.open(wsUrl); clients.push(reconnect); reconnect.token = token;
    reconnect.send({ type: 'queue_ranked', deck_name: 'Moon Bot 1.0', rules_version: liveRulesVersion });
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
  assert.equal(ranked.mode, 'ranked'); assert.equal(ranked.methodology.source, 'mixed');
  assert.ok(ranked.bots.some(b => b.id === 'standard' && b.level === 3));
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
  assert.ok(humanCards.cards.some(c => c.matches > 0), 'ranked bot seats contribute to the shared card statistics');
  const combined = await (await fetch(`http://127.0.0.1:${proxy.address().port}/data/stats/deck-matchups.json?mode=all`)).json();
  assert.ok(combined.games >= 3, 'real worker results reach the existing stats page feed');
  const page = await import('../../website/stats-core.mjs');
  assert.ok(page.validateSnapshot(combined));
  for (const bad of ['?mode=bad', '?mode=ranked&mode=simulation', '?mode=ranked&days=0']) assert.equal((await fetch(route + bad)).status, 400);
  const snapshots = (await pool.query('SELECT bot_a,bot_b FROM ranked_matches WHERE match_id=$1', [first.match_id])).rows[0];
  await pool.query("UPDATE ranked_bot_accounts SET profile=jsonb_set(profile,'{version}','\"2.0\"')");
  assert.deepEqual((await pool.query('SELECT bot_a,bot_b FROM ranked_matches WHERE match_id=$1', [first.match_id])).rows[0], snapshots);
  const historical = await (await fetch(route + '?mode=ranked&days=31')).json();
  assert.ok(historical.bots.filter(b => !['human','standard'].includes(b.id)).every(b => b.version === profiles.find(p=>p.id===b.id).version), 'fresh HTTP read uses historical snapshots rather than current registry');
  await pool.query('UPDATE ranked_settlements SET won=NOT won WHERE match_id=$1 AND player_id=$2', [first.match_id, humanId]);
  const contradictory = await (await fetch(route + '?mode=ranked&days=32')).json();
  assert.equal(contradictory.bots.filter(b => b.id === 'human').reduce((n, b) => n + b.matches, 0), 1, 'contradictory settlements exclude the whole match');
  await pool.query('UPDATE ranked_settlements SET won=NOT won WHERE match_id=$1 AND player_id=$2', [first.match_id, humanId]);
  for (const profile of profiles) await pool.query('UPDATE ranked_bot_accounts SET profile=$1 WHERE bot_id=$2',[profile,profile.id]);
  const playingAI = await until(async () => {
    const status = await (await fetch(statusUrl)).json();
    return status.bots?.find(b => b.activity === 'playing_ai');
  }, 'local AI game for session revocation proof', 180000);
  const expired = (await pool.query(`SELECT s.token FROM sessions s JOIN ranked_bot_accounts b ON b.player_id=s.player_id
    WHERE b.bot_id=$1 ORDER BY s.created_at DESC LIMIT 1`, [playingAI.id])).rows[0];
  assert.ok(expired);
  await pool.query('DELETE FROM sessions WHERE token=$1', [expired.token]);
  const authFailure = await until(() => workerFailure, 'revoked session forces supervised recovery', 25000);
  assert.match(authFailure.message, /session or profile was refused/);
  await assert.rejects(worker, /session or profile was refused/);
  const authRestart = events.length;
  stop = new AbortController(); startWorker();
  await until(() => { if (workerFailure) throw workerFailure; return events.slice(authRestart).some(e => ['joined','ai_started'].includes(e.event)); }, 'fresh sessions resume the next opponent after revocation');
  const owner = (await pool.query("SELECT pid FROM pg_locks WHERE locktype='advisory' AND classid=731204 AND objid=2 AND granted")).rows;
  assert.equal(owner.length, 1);
  const lockTransport = [...transports].find(pair => pair.backendPid === owner[0].pid);
  assert.ok(lockTransport, 'fault targets the actual lock-owning DB transport');
  lockTransport.blackholed = true;
  lockTransport.front.unpipe(lockTransport.back); lockTransport.back.unpipe(lockTransport.front);
  lockTransport.back.destroy();
  await until(async () => !(await pool.query('SELECT 1 FROM pg_locks WHERE pid=$1 AND locktype=\'advisory\'', [owner[0].pid])).rowCount, 'blackholed connection releases actual DB lock');
  await until(() => workerFailure, 'lock heartbeat stops worker despite silently open socket', 15000);
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
