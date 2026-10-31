'use strict';
// Site accounts: additive schema for Google sign-in, the account snapshot the
// website banner reads, and the resume fix. Real PostgreSQL and a real relay
// process; each run owns a private schema and never touches other suites' tables.
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const net = require('node:net');
const path = require('node:path');
const { once } = require('node:events');
const { Pool } = require('pg');
const WebSocket = require('ws');
const { initLegacySchema } = require('../schema_legacy');
const { disposableDatabase, PROJECT_DIR } = require('./helpers');

const dbUrl = process.env.DATABASE_URL;
const skip = !dbUrl || !disposableDatabase(dbUrl) ? 'requires a disposable DATABASE_URL' : false;

async function freePort() {
  const server = net.createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

// A private schema plus a pool that resolves unqualified names inside it.
async function privateSchema(t, label) {
  const admin = new Pool({ connectionString: dbUrl, ssl: false });
  const schema = `${label}_${process.pid}`;
  await admin.query(`CREATE SCHEMA ${schema}`);
  const url = new URL(dbUrl);
  url.searchParams.set('options', `-c search_path=${schema}`);
  const pool = new Pool({ connectionString: url.toString(), ssl: false });
  t.after(async () => {
    await pool.end();
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
  });
  return { pool, url: url.toString() };
}

test('migration: fresh schema, repeated initialization, and the sign-in constraint', { skip }, async (t) => {
  const { pool } = await privateSchema(t, 'site_fresh');
  await initLegacySchema(pool);
  await initLegacySchema(pool);
  await initLegacySchema(pool);

  // A password player and a Google-only player are both representable...
  await pool.query(`INSERT INTO players (username, password_hash, salt) VALUES ('pw_player', 'h', 's')`);
  await pool.query(`INSERT INTO players (username, google_sub) VALUES ('g_player', 'sub-1')`);
  // ...an account with no way to sign in is not...
  await assert.rejects(pool.query(`INSERT INTO players (username) VALUES ('nobody')`), /players_has_sign_in/);
  // ...and a Google identity belongs to exactly one player.
  await assert.rejects(pool.query(`INSERT INTO players (username, google_sub) VALUES ('dup', 'sub-1')`), /players_google_sub_key/);
  // Linking a second subject to a player that already has one is a plain UPDATE the relay controls;
  // two players cannot share a subject.
  await pool.query(`INSERT INTO players (username, password_hash, salt) VALUES ('other', 'h', 's')`);
  await assert.rejects(pool.query(`UPDATE players SET google_sub = 'sub-1' WHERE username = 'other'`), /players_google_sub_key/);
});

test('migration: a populated legacy database upgrades without changing anything', { skip }, async (t) => {
  const { pool } = await privateSchema(t, 'site_legacy');
  // The players table exactly as deployed before Google sign-in existed.
  await pool.query(`CREATE TABLE players (
      id SERIAL PRIMARY KEY, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, salt TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(), wins INTEGER NOT NULL DEFAULT 0,
      losses INTEGER NOT NULL DEFAULT 0, rating INTEGER NOT NULL DEFAULT 1000,
      rank_bracket INTEGER NOT NULL DEFAULT 0, rank_in_legend BOOLEAN NOT NULL DEFAULT false,
      rank_legend_rating INTEGER NOT NULL DEFAULT 0, rank_lp INTEGER NOT NULL DEFAULT 0,
      ranked_win_streak INTEGER NOT NULL DEFAULT 0, ranked_wins INTEGER NOT NULL DEFAULT 0,
      ranked_losses INTEGER NOT NULL DEFAULT 0, currency INTEGER NOT NULL DEFAULT 0,
      dust INTEGER NOT NULL DEFAULT 0, last_daily_reward_at DATE, pfp_id TEXT NOT NULL DEFAULT '')`);
  await pool.query(`INSERT INTO players (username, password_hash, salt, wins, rank_bracket, rank_lp, currency, dust, pfp_id)
    VALUES ('veteran', 'hash-v', 'salt-v', 12, 7, 55, 340, 910, 'warrior.png')`);
  const before = (await pool.query('SELECT * FROM players')).rows;
  await initLegacySchema(pool);
  await initLegacySchema(pool);
  const after = (await pool.query('SELECT * FROM players')).rows;
  assert.equal(after.length, 1);
  for (const key of Object.keys(before[0])) assert.deepEqual(after[0][key], before[0][key], key);
  assert.equal(after[0].google_sub, null);
  const decks = await pool.query(`INSERT INTO decks (player_id, name, faction_idx, card_ids) VALUES ($1, 'd', 1, '["g_001"]') RETURNING name`, [after[0].id]);
  assert.equal(decks.rows[0].name, 'd', 'dependent tables created and usable after the upgrade');
});

test('relay: account snapshot, resume keeps the portrait, Google-only rows refuse passwords', { skip, timeout: 120000 }, async (t) => {
  const { pool, url } = await privateSchema(t, 'site_relay');
  await initLegacySchema(pool);
  await pool.query(`INSERT INTO players (username, google_sub, pfp_id, currency, dust, rank_bracket, rank_lp, ranked_win_streak, rating)
    VALUES ('g_only', 'sub-9', 'owl.png', 123, 456, 5, 33, 4, 1337)`);

  const port = await freePort();
  let log = '';
  const relay = spawn(process.execPath, [path.join(PROJECT_DIR, 'server', 'relay.js')], {
    env: { ...process.env, DATABASE_URL: url, PORT: String(port), RANKED_AUTHORITATIVE: '0' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  relay.stdout.on('data', (d) => { log += d; });
  relay.stderr.on('data', (d) => { log += d; });
  const sockets = [];
  t.after(async () => {
    for (const ws of sockets) ws.terminate();
    if (relay.exitCode === null) { const exited = once(relay, 'exit'); relay.kill(); await exited; }
  });
  let ws;
  for (let attempt = 0; attempt < 100 && !ws; attempt++) {
    if (relay.exitCode !== null) throw new Error(`test relay exited: ${log}`);
    try { const s = new WebSocket(`ws://127.0.0.1:${port}`); await once(s, 'open'); ws = s; }
    catch { await new Promise((r) => setTimeout(r, 100)); }
  }
  assert.ok(ws, `relay started: ${log}`);
  sockets.push(ws);

  const ask = (message, type) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => { ws.off('message', receive); reject(new Error(`no ${type} reply`)); }, 10000);
    function receive(raw) {
      const reply = JSON.parse(raw);
      if (reply.type !== type) return;
      clearTimeout(timer); ws.off('message', receive); resolve(reply);
    }
    ws.on('message', receive);
    ws.send(JSON.stringify(message));
  });

  // A Google-only player cannot be signed into with any password, including empty.
  for (const password of ['', 'anything', 'x'.repeat(200)]) {
    const refused = await ask({ type: 'login', username: 'g_only', password }, 'login_result');
    assert.equal(refused.success, false);
    assert.equal(refused.message, 'Invalid username or password.');
  }

  // Registration and login still work for password accounts.
  const registered = await ask({ type: 'register', username: 'site_user', password: 'correct horse' }, 'register_result');
  assert.equal(registered.success, true);
  assert.equal((await ask({ type: 'login', username: 'site_user', password: 'wrong password' }, 'login_result')).success, false);
  const login = await ask({ type: 'login', username: 'site_user', password: 'correct horse' }, 'login_result');
  assert.equal(login.success, true);

  // The portrait survives a session resume (the old resume query omitted it).
  assert.equal((await ask({ type: 'set_pfp', token: login.token, pfp_id: 'knight.png' }, 'set_pfp_result')).success, true);
  const resumed = await ask({ type: 'resume_session', token: login.token }, 'login_result');
  assert.equal(resumed.success, true);
  assert.equal(resumed.pfp_id, 'knight.png');

  // The snapshot carries everything the banner and profile need, from the database.
  await pool.query(`UPDATE players SET currency = 77, dust = 88, rank_bracket = 3, rank_lp = 41,
    ranked_win_streak = 2, ranked_wins = 9, ranked_losses = 4, wins = 5, losses = 6 WHERE username = 'site_user'`);
  const snap = await ask({ type: 'get_account_snapshot', token: login.token, request_id: 'req-1' }, 'account_snapshot_result');
  assert.equal(snap.success, true);
  assert.equal(snap.request_id, 'req-1', 'the request id is echoed so stale replies can be ignored');
  assert.deepEqual(snap.account, {
    player_id: snap.account.player_id, username: 'site_user', pfp_id: 'knight.png', wins: 5, losses: 6,
    rank_bracket: 3, rank_in_legend: false, rank_legend_rating: 0, rank_lp: 41, ranked_win_streak: 2,
    ranked_wins: 9, ranked_losses: 4, currency: 77, dust: 88, google_linked: false, has_password: true,
  });
  assert.ok(Number.isInteger(snap.account.player_id));
  const text = JSON.stringify(snap);
  for (const secret of ['"salt"', '"password_hash"', '"google_sub"', '"token"']) assert.ok(!text.includes(secret), `no ${secret} in the snapshot`);
  assert.ok(!('rating' in snap.account), 'the hidden matchmaking rating is not the visible rank');

  // A linked Google-only player reports its link status and no password.
  await pool.query(`INSERT INTO sessions (token, player_id) SELECT 'g-token', id FROM players WHERE username = 'g_only'`);
  const googleSnap = await ask({ type: 'get_account_snapshot', token: 'g-token', request_id: 'req-2' }, 'account_snapshot_result');
  assert.equal(googleSnap.account.google_linked, true);
  assert.equal(googleSnap.account.has_password, false);
  assert.equal(googleSnap.account.currency, 123);
  assert.equal(googleSnap.account.pfp_id, 'owl.png');

  // Unknown, missing and logged-out tokens are `unauthorized`, distinct from a server failure.
  for (const token of ['nope', '', undefined]) {
    const denied = await ask({ type: 'get_account_snapshot', token, request_id: 'req-3' }, 'account_snapshot_result');
    assert.equal(denied.success, false);
    assert.equal(denied.unauthorized, true);
    assert.equal(denied.request_id, 'req-3');
  }
  await ask({ type: 'logout', token: login.token }, 'logged_out');
  const afterLogout = await ask({ type: 'get_account_snapshot', token: login.token, request_id: 'req-4' }, 'account_snapshot_result');
  assert.equal(afterLogout.unauthorized, true, 'a revoked token is unauthorized');
});
