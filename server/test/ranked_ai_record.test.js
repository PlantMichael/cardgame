'use strict';
// AI telemetry crosses the real websocket/transaction boundary against a disposable DB.
// Each run owns a private schema; it never truncates another test suite's tables.
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const net = require('node:net');
const path = require('node:path');
const { once } = require('node:events');
const { Pool } = require('pg');
const WebSocket = require('ws');
const { normalizeAIRecord } = require('../ranked_ai_record');
const { initLegacySchema } = require('../schema_legacy');
const { loadCards } = require('../authoritative/decks');
const { disposableDatabase, PROJECT_DIR, killTree } = require('./helpers');

const cards = new Map([...loadCards()].filter(([, card]) => !card.is_token));
const summary = () => ({ player_deck: ['g_001', 'g_002'], opponent_deck: ['cr_002'],
  ai_level: 3, turns: 7, rules_version: 1 });

test('AI summaries bound input and project server-owned provenance', () => {
  const input = { ...summary(), mode: 'authoritative', source: 'server', player_id: 999, verified: true };
  const record = normalizeAIRecord(input, 'ai_1700000000_42', cards);
  assert.deepEqual(record, { ...summary(), mode: 'ranked_ai', source: 'client_reported' });
  input.player_deck.pop();
  assert.equal(record.player_deck.length, 2, 'the accepted lists are snapshots');
  for (const invalid of [null, [], {}, { ...summary(), ai_level: 0 }, { ...summary(), ai_level: 11 },
    { ...summary(), turns: 0 }, { ...summary(), turns: 1.5 }, { ...summary(), turns: 1000001 },
    { ...summary(), rules_version: '1' }, { ...summary(), player_deck: [] },
    { ...summary(), opponent_deck: Array(41).fill('cr_002') },
    { ...summary(), player_deck: ['unknown'] }, { ...summary(), opponent_deck: [null] }]) {
    assert.equal(normalizeAIRecord(invalid, 'ai_1700000000_42', cards), null);
  }
  const tokenId = [...loadCards()].find(([, c]) => c.is_token)[0];
  assert.equal(normalizeAIRecord({ ...summary(), player_deck: [tokenId] }, 'ai_1_2', cards), null);
  for (const id of ['rk_1', 'lobby', 'ai_bad', `ai_${'1'.repeat(100)}_2`]) {
    assert.equal(normalizeAIRecord(summary(), id, cards), null);
  }
});

// Allocate a localhost port without relying on a fixed developer port.
async function freePort() {
  const server = net.createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

// Only localhost test relays are opened; errors are surfaced to the caller.
async function openSocket(url) {
  const ws = new WebSocket(url);
  await once(ws, 'open');
  return ws;
}

// Install the waiter before sending so even an immediate response is captured.
function request(ws, message, responseType = 'ranked_result_ack') {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { ws.off('message', receive); reject(new Error('relay response timed out')); }, 10000);
    function receive(raw) {
      const response = JSON.parse(raw);
      if (response.type !== responseType) return;
      clearTimeout(timer);
      ws.off('message', receive);
      resolve(response);
    }
    ws.on('message', receive);
    ws.send(JSON.stringify({ type: 'report_ranked_result', ...message }));
  });
}

const dbUrl = process.env.DATABASE_URL;
test('real relay records AI summaries atomically and preserves legacy settlement', {
  skip: !dbUrl || !disposableDatabase(dbUrl) ? 'requires a disposable DATABASE_URL' : false,
  timeout: 120000,
}, async (t) => {
  const admin = new Pool({ connectionString: dbUrl, ssl: false });
  const schema = `ranked_ai_${process.pid}`;
  await admin.query(`CREATE SCHEMA ${schema}`);
  const isolatedUrl = new URL(dbUrl);
  isolatedUrl.searchParams.set('options', `-c search_path=${schema}`);
  const pool = new Pool({ connectionString: isolatedUrl.toString(), ssl: false });
  let relay;
  const sockets = [];
  t.after(async () => {
    for (const ws of sockets) ws.terminate();
    if (relay && relay.exitCode === null) {
      const exited = once(relay, 'exit');
      relay.kill();
      await exited;
    }
    await pool.end();
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
  });

  await initLegacySchema(pool);
  const { rows: players } = await pool.query(`INSERT INTO players (username, password_hash, salt)
    VALUES ('ai_tester', 'synthetic', 'synthetic'), ('ai_fail', 'synthetic', 'synthetic') RETURNING id, username`);
  const player = players.find((p) => p.username === 'ai_tester').id;
  const failingPlayer = players.find((p) => p.username === 'ai_fail').id;
  await pool.query('INSERT INTO sessions (token, player_id) VALUES ($1, $2), ($3, $4)',
    ['test-ai-session', player, 'test-ai-failing-session', failingPlayer]);
  await pool.query(`INSERT INTO ranked_settlements (match_id, player_id, won, outcome)
    VALUES ('old_client_game', $1, false, '{"rating":1000}')`, [player]);
  const fresh = await pool.query('SELECT ai_match FROM ranked_settlements WHERE match_id = $1', ['old_client_game']);
  assert.equal(fresh.rows[0].ai_match, null, 'new schema accepts legacy records');
  // Recreate the old shape with a populated row, then exercise the actual boot upgrade twice.
  await pool.query('ALTER TABLE ranked_settlements DROP COLUMN ai_match');
  await initLegacySchema(pool);
  await initLegacySchema(pool);
  assert.deepEqual((await pool.query('SELECT won, ai_match FROM ranked_settlements')).rows,
    [{ won: false, ai_match: null }], 'upgrade preserves existing results and is repeatable');

  const port = await freePort();
  let log = '';
  relay = spawn(process.execPath, [path.join(PROJECT_DIR, 'server', 'relay.js')], {
    env: { ...process.env, DATABASE_URL: isolatedUrl.toString(), PORT: String(port), RANKED_AUTHORITATIVE: '0' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  relay.stdout.on('data', (data) => { log += data; });
  relay.stderr.on('data', (data) => { log += data; });
  const url = `ws://127.0.0.1:${port}`;
  let ws;
  for (let attempt = 0; attempt < 100; attempt++) {
    if (relay.exitCode !== null) throw new Error(`test relay exited: ${log}`);
    try { ws = await openSocket(url); break; } catch { await new Promise((resolve) => setTimeout(resolve, 100)); }
  }
  assert.ok(ws, `test relay started: ${log}`);
  sockets.push(ws);
  const report = { token: 'test-ai-session', match_id: 'ai_1700000000_42', won: true, ai_match: summary() };
  const first = await request(ws, { ...report, player_id: failingPlayer,
    ai_match: { ...summary(), verified: true, source: 'server' } });
  assert.equal(first.success, true);
  const before = (await pool.query('SELECT * FROM ranked_settlements WHERE match_id = $1', [report.match_id])).rows;
  assert.equal(before.length, 1);
  assert.equal(before[0].player_id, player, 'session, not payload identity, owns the record');
  assert.equal(before[0].won, true);
  assert.deepEqual(before[0].ai_match, { ...summary(), mode: 'ranked_ai', source: 'client_reported' });
  assert.equal(first.rating, 1000, 'client-reported AI games do not move matchmaking Elo');
  const replay = await request(ws, { ...report, won: false, ai_match: { ...summary(), turns: 99 } });
  assert.equal(replay.replayed, true);
  assert.deepEqual((await pool.query('SELECT * FROM ranked_settlements WHERE match_id = $1', [report.match_id])).rows, before);
  assert.equal((await pool.query('SELECT ranked_wins FROM players WHERE id = $1', [player])).rows[0].ranked_wins, 1);

  for (const message of [{ ...report, token: 'expired', match_id: 'ai_1_1' },
    { ...report, match_id: 'ai_1_2', ai_match: { ...summary(), player_deck: ['unknown'] } },
    { ...report, match_id: 'rk_fake' }]) {
    assert.equal((await request(ws, message)).success, false);
    assert.equal((await pool.query('SELECT count(*)::int AS n FROM ranked_settlements WHERE match_id = $1', [message.match_id])).rows[0].n, 0);
  }
  const old = await request(ws, { token: report.token, match_id: 'ai_1_3', won: false });
  assert.equal(old.success, true, 'older clients still settle');
  assert.equal((await pool.query('SELECT ai_match FROM ranked_settlements WHERE match_id = $1', ['ai_1_3'])).rows[0].ai_match, null);

  const opponent = await openSocket(url);
  sockets.push(opponent);
  const [paired] = await Promise.all([
    request(ws, { type: 'queue_ranked', token: report.token }, 'ranked_match_found'),
    request(opponent, { type: 'queue_ranked', token: 'test-ai-failing-session' }, 'ranked_match_found'),
  ]);
  const pvp = { ...report, match_id: paired.lobby_id };
  assert.equal((await request(ws, pvp)).success, false, 'a real PvP match cannot receive AI telemetry');
  delete pvp.ai_match;
  const pvpResult = await request(ws, pvp);
  assert.equal(pvpResult.success, true);
  assert.ok(pvpResult.rating > first.rating, 'legacy PvP still uses its server-known opponent rating');
  assert.equal((await pool.query('SELECT ai_match FROM ranked_settlements WHERE match_id = $1', [pvp.match_id])).rows[0].ai_match, null);

  await pool.query(`CREATE FUNCTION reject_ai_test_update() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN IF NEW.username = 'ai_fail' THEN RAISE EXCEPTION 'synthetic settlement failure'; END IF; RETURN NEW; END $$;
    CREATE TRIGGER fail_ai_settlement BEFORE UPDATE ON players FOR EACH ROW EXECUTE FUNCTION reject_ai_test_update()`);
  const failure = { ...report, token: 'test-ai-failing-session', match_id: 'ai_1_4' };
  assert.equal((await request(ws, failure)).success, false);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM ranked_settlements WHERE match_id = $1', [failure.match_id])).rows[0].n, 0);
  assert.equal((await pool.query('SELECT ranked_wins FROM players WHERE id = $1', [failingPlayer])).rows[0].ranked_wins, 0);
  await pool.query('DROP TRIGGER fail_ai_settlement ON players');
  assert.equal((await request(ws, failure)).success, true, 'a failed transaction can be retried');

  if (process.env.GODOT_BIN) {
    const godot = spawn(process.env.GODOT_BIN, ['--headless', '--path', PROJECT_DIR,
      'res://server/test/fixtures/ranked_ai_client.tscn'], {
      env: { ...process.env, AI_TEST_URL: url, AI_TEST_TOKEN: report.token }, stdio: ['ignore', 'pipe', 'pipe'],
    });
    t.after(() => killTree(godot));
    let clientLog = '';
    godot.stdout.on('data', (data) => { clientLog += data; });
    godot.stderr.on('data', (data) => { clientLog += data; });
    const [code] = await once(godot, 'exit');
    assert.equal(code, 0, clientLog);
    const clientRows = (await pool.query(`SELECT won, ai_match FROM ranked_settlements
      WHERE ai_match IS NOT NULL AND match_id NOT IN ('ai_1700000000_42', 'ai_1_4')`)).rows;
    assert.equal(clientRows.length, 1, 'only the ranked local game submitted a summary');
    assert.equal(clientRows[0].won, false);
    assert.deepEqual(clientRows[0].ai_match.player_deck, Array(10).fill('g_001'));
    assert.deepEqual(clientRows[0].ai_match.opponent_deck, Array(10).fill('cr_002'));
    assert.equal(clientRows[0].ai_match.ai_level, 1);
    assert.equal(clientRows[0].ai_match.turns, 7);
    assert.ok(Number.isInteger(clientRows[0].ai_match.rules_version) && clientRows[0].ai_match.rules_version > 0);
  } else {
    t.diagnostic('Godot producer test not run: set GODOT_BIN to enable it');
  }
});
