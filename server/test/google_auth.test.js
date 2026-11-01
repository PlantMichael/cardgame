'use strict';
// Google sign-in: the real google-auth-library verification (signature, issuer,
// audience, expiry) over tokens signed here with a throwaway RSA key and served
// through the library's own key-fetch path, against a real PostgreSQL schema.
// A stubbed verifier returning "valid" would prove nothing about security.
//
// Not covered here (and stated plainly): Google's real consent screen and real
// signing keys. That remains an owner-assisted check once an OAuth client exists.
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const http = require('node:http');
const { once } = require('node:events');
const { Pool } = require('pg');
const { initLegacySchema } = require('../schema_legacy');
const { createGoogleAuth, createGoogleVerifier, MAX_FAILURES_PER_CONNECTION } = require('../google_auth');
const { disposableDatabase } = require('./helpers');

const dbUrl = process.env.DATABASE_URL;
const skip = !dbUrl || !disposableDatabase(dbUrl) ? 'requires a disposable DATABASE_URL' : false;

const CLIENT_ID = 'test-client.apps.googleusercontent.com';
const ORIGIN = 'https://site.example';
const USERNAME_RE = /^[A-Za-z0-9_]{3,20}$/;

const b64 = (value) => Buffer.from(typeof value === 'string' ? value : JSON.stringify(value)).toString('base64url');

function keyPair() {
  return crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
}

function sign(privateKey, kid, claims, header = {}) {
  const head = b64({ alg: 'RS256', typ: 'JWT', kid, ...header });
  const body = b64(claims);
  const signature = crypto.sign('RSA-SHA256', Buffer.from(`${head}.${body}`), privateKey).toString('base64url');
  return `${head}.${body}.${signature}`;
}

async function harness(t) {
  const trusted = keyPair();
  const stranger = keyPair();
  const certs = { 'trusted-kid': trusted.publicKey.export({ type: 'spki', format: 'pem' }) };
  const keyServer = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(certs));
  });
  keyServer.listen(0, '127.0.0.1');
  await once(keyServer, 'listening');

  const admin = new Pool({ connectionString: dbUrl, ssl: false });
  const schema = `google_${process.pid}_${Math.floor(Math.random() * 1e6)}`;
  await admin.query(`CREATE SCHEMA ${schema}`);
  const url = new URL(dbUrl);
  url.searchParams.set('options', `-c search_path=${schema}`);
  const pool = new Pool({ connectionString: url.toString(), ssl: false });
  t.after(async () => {
    await pool.end();
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
    keyServer.closeAllConnections();
    await new Promise((resolve) => keyServer.close(resolve));
  });
  await initLegacySchema(pool);

  const sent = new Map(); // ws -> replies
  const sendTo = (ws, message) => { if (!sent.has(ws)) sent.set(ws, []); sent.get(ws).push(message); };
  const sockets = [];
  const newSocket = (siteOrigin = ORIGIN) => { const ws = { siteOrigin }; sockets.push(ws); return ws; };
  const deps = {
    pool, sendTo, makeToken: () => crypto.randomBytes(16).toString('hex'), usernameRe: USERNAME_RE,
    profileOf: (r) => ({ username: r.username, pfp_id: r.pfp_id, rank_bracket: r.rank_bracket }),
    decksOf: async () => [],
    accountSnapshotByToken: async (token) => {
      const r = await pool.query(`SELECT p.id, p.username, (p.google_sub IS NOT NULL) AS google_linked
        FROM sessions s JOIN players p ON p.id = s.player_id WHERE s.token = $1`, [token]);
      return r.rows[0] ? { player_id: r.rows[0].id, username: r.rows[0].username, google_linked: r.rows[0].google_linked } : null;
    },
  };
  const verifier = createGoogleVerifier({ clientId: CLIENT_ID, certsUrl: `http://127.0.0.1:${keyServer.address().port}/certs` });
  const google = createGoogleAuth(deps, { clientId: CLIENT_ID, origins: [ORIGIN], verifier });

  const call = async (ws, message) => {
    const before = (sent.get(ws) || []).length;
    await google.handle(ws, message);
    return (sent.get(ws) || []).slice(before).pop();
  };
  const claims = (overrides = {}) => {
    const now = Math.floor(Date.now() / 1000);
    return { iss: 'https://accounts.google.com', aud: CLIENT_ID, sub: 'sub-1', iat: now - 5, exp: now + 3600, ...overrides };
  };
  const nonceFor = async (ws, purpose, token) => (await call(ws, { type: 'google_challenge', purpose, token })).nonce;
  return { pool, google, call, newSocket, claims, nonceFor, trusted, stranger,
    token: (c, extra = {}, key = trusted.privateKey, kid = 'trusted-kid') => sign(key, kid, c, extra),
    count: async (sql, args = []) => (await pool.query(sql, args)).rows[0].n };
}

const playerCount = (h) => h.count('SELECT count(*)::int AS n FROM players');

test('Google sign-in is unavailable until configured, and from the wrong origin', { skip }, async (t) => {
  const h = await harness(t);
  const unconfigured = createGoogleAuth({ pool: h.pool, sendTo: () => {}, makeToken: () => 'x', usernameRe: USERNAME_RE }, { clientId: '', origins: [], verifier: null });
  assert.equal(unconfigured.available, false);
  const replies = [];
  const bare = createGoogleAuth({ pool: h.pool, sendTo: (_ws, m) => replies.push(m), makeToken: () => 'x', usernameRe: USERNAME_RE }, { clientId: CLIENT_ID, origins: [], verifier: null });
  await bare.handle({ siteOrigin: ORIGIN }, { type: 'google_challenge', purpose: 'signin' });
  assert.equal(replies.at(-1).code, 'unavailable', 'a client ID with no allowed origin stays off');

  const nativeLike = h.newSocket('');
  assert.equal((await h.call(nativeLike, { type: 'google_config' })).available, false);
  assert.equal((await h.call(nativeLike, { type: 'google_challenge', purpose: 'signin' })).code, 'origin');
  const other = h.newSocket('https://evil.example');
  assert.equal((await h.call(other, { type: 'google_signin', credential: 'x', nonce: 'y' })).code, 'origin');
  const ok = h.newSocket();
  const config = await h.call(ok, { type: 'google_config' });
  assert.deepEqual(config, { type: 'google_config_result', available: true, client_id: CLIENT_ID });
});

test('a new Google identity picks a username; a returning one signs in; no password exists', { skip }, async (t) => {
  const h = await harness(t);
  const ws = h.newSocket();
  const nonce = await h.nonceFor(ws, 'signin');
  const first = await h.call(ws, { type: 'google_signin', nonce, credential: h.token(h.claims({ nonce, email: 'someone@example.com', name: 'Real Name' })) });
  assert.equal(first.success, true);
  assert.equal(first.needs_username, true);
  assert.equal(await playerCount(h), 0, 'nothing is created before a username is chosen');

  assert.equal((await h.call(ws, { type: 'google_register', setup_token: first.setup_token, username: 'a!' })).code, 'invalid_username');
  await h.pool.query(`INSERT INTO players (username, password_hash, salt) VALUES ('taken_name', 'h', 's')`);
  assert.equal((await h.call(ws, { type: 'google_register', setup_token: first.setup_token, username: 'taken_name' })).code, 'username_taken');
  assert.equal(await playerCount(h), 1, 'a refused username creates nothing');

  const made = await h.call(ws, { type: 'google_register', setup_token: first.setup_token, username: 'google_hero' });
  assert.equal(made.success, true);
  assert.equal(made.username, 'google_hero');
  const row = (await h.pool.query(`SELECT * FROM players WHERE username = 'google_hero'`)).rows[0];
  assert.equal(row.google_sub, 'sub-1');
  assert.equal(row.password_hash, null, 'no made-up password');
  assert.equal(row.salt, null);
  assert.ok(!JSON.stringify(row).includes('someone@example.com') && !JSON.stringify(row).includes('Real Name'), 'no Google profile data is stored');
  assert.equal((await h.pool.query('SELECT count(*)::int AS n FROM sessions WHERE token = $1', [made.token])).rows[0].n, 1);
  assert.equal((await h.call(ws, { type: 'google_register', setup_token: first.setup_token, username: 'again_name' })).code, 'expired', 'a setup token is single use');

  const again = h.newSocket();
  const nonce2 = await h.nonceFor(again, 'signin');
  const back = await h.call(again, { type: 'google_signin', nonce: nonce2, credential: h.token(h.claims({ nonce: nonce2 })) });
  assert.equal(back.success, true);
  assert.equal(back.username, 'google_hero');
  assert.notEqual(back.token, made.token);
  assert.equal(await playerCount(h), 2, 'a returning identity creates no player');
});

test('forged, expired, wrong-audience, wrong-issuer, replayed and misdirected proofs are refused', { skip }, async (t) => {
  const h = await harness(t);
  const attempt = async (build, { purpose = 'signin', ws = h.newSocket(), nonceOverride } = {}) => {
    const nonce = await h.nonceFor(ws, purpose);
    const credential = build(nonce);
    return h.call(ws, { type: 'google_signin', credential, nonce: nonceOverride === undefined ? nonce : nonceOverride });
  };
  const now = Math.floor(Date.now() / 1000);
  const cases = {
    'wrong audience': (n) => h.token(h.claims({ nonce: n, aud: 'someone-else' })),
    'wrong issuer': (n) => h.token(h.claims({ nonce: n, iss: 'https://evil.example' })),
    'expired': (n) => h.token(h.claims({ nonce: n, iat: now - 7200, exp: now - 3600 })),
    'lifetime far too long': (n) => h.token(h.claims({ nonce: n, exp: now + 86400 * 30 })),
    'signed by an unknown key': (n) => h.token(h.claims({ nonce: n }), {}, h.stranger.privateKey),
    'unknown key id': (n) => h.token(h.claims({ nonce: n }), {}, h.trusted.privateKey, 'missing-kid'),
    'wrong nonce in the token': (n) => h.token(h.claims({ nonce: `${n}x` })),
    'no nonce in the token': () => h.token(h.claims()),
    'no subject': (n) => h.token(h.claims({ nonce: n, sub: '' })),
    'not a token': () => 'not.a.jwt',
  };
  for (const [name, build] of Object.entries(cases)) {
    const reply = await attempt(build);
    assert.equal(reply.success, false, name);
    assert.equal(reply.code, 'bad_token', name);
  }
  // alg=none and a tampered payload must also fail the signature check.
  const forged = await attempt((n) => `${b64({ alg: 'none', kid: 'trusted-kid' })}.${b64(h.claims({ nonce: n }))}.`);
  assert.equal(forged.success, false);
  const tampered = await attempt((n) => {
    const [head, , sig] = h.token(h.claims({ nonce: n })).split('.');
    return `${head}.${b64(h.claims({ nonce: n, sub: 'someone-else' }))}.${sig}`;
  });
  assert.equal(tampered.success, false);

  // Unsolicited: no challenge was ever issued. Replayed: a nonce works once.
  const ws = h.newSocket();
  assert.equal((await h.call(ws, { type: 'google_signin', nonce: 'made-up', credential: h.token(h.claims({ nonce: 'made-up' })) })).code, 'bad_challenge');
  const nonce = await h.nonceFor(ws, 'signin');
  const credential = h.token(h.claims({ nonce }));
  assert.equal((await h.call(ws, { type: 'google_signin', nonce, credential })).success, true);
  assert.equal((await h.call(ws, { type: 'google_signin', nonce, credential })).code, 'bad_challenge', 'a replay is refused');

  // A challenge belongs to the connection that asked for it, and to its purpose.
  const owner = h.newSocket();
  const thief = h.newSocket();
  const ownersNonce = await h.nonceFor(owner, 'signin');
  assert.equal((await h.call(thief, { type: 'google_signin', nonce: ownersNonce, credential: h.token(h.claims({ nonce: ownersNonce })) })).code, 'bad_challenge');
  const linkSocket = h.newSocket();
  await h.pool.query(`INSERT INTO players (username, password_hash, salt) VALUES ('linker', 'h', 's')`);
  await h.pool.query(`INSERT INTO sessions (token, player_id) SELECT 'link-token', id FROM players WHERE username = 'linker'`);
  const linkNonce = await h.nonceFor(linkSocket, 'link', 'link-token');
  const wrongPurpose = await h.call(linkSocket, { type: 'google_signin', nonce: linkNonce, credential: h.token(h.claims({ nonce: linkNonce, sub: 'sub-wp' })) });
  assert.equal(wrongPurpose.code, 'bad_challenge', 'a link challenge cannot sign in');

  assert.equal((await h.call(h.newSocket(), { type: 'google_signin', nonce: 'n', credential: 'x'.repeat(9000) })).code, 'bad_request');
  assert.equal(await h.count(`SELECT count(*)::int AS n FROM players WHERE google_sub IS NOT NULL`), 0, 'no refused proof created or linked anything');
});

test('repeated failures are cut off', { skip }, async (t) => {
  const h = await harness(t);
  const ws = h.newSocket();
  let last;
  for (let i = 0; i < MAX_FAILURES_PER_CONNECTION + 2; i++) {
    last = await h.call(ws, { type: 'google_signin', nonce: 'nope', credential: 'junk' });
  }
  assert.equal(last.code, 'rate_limited');
  const fresh = h.newSocket();
  assert.equal((await h.call(fresh, { type: 'google_challenge', purpose: 'signin' })).success, true, 'another connection is unaffected');
});

test('linking: explicit, authenticated, one identity per player, nothing changes on conflict', { skip }, async (t) => {
  const h = await harness(t);
  await h.pool.query(`INSERT INTO players (username, password_hash, salt, currency, dust, rank_bracket) VALUES
    ('alice', 'ha', 'sa', 500, 600, 4), ('bob', 'hb', 'sb', 1, 2, 0)`);
  await h.pool.query(`INSERT INTO sessions (token, player_id) SELECT 'alice-token', id FROM players WHERE username = 'alice'`);
  await h.pool.query(`INSERT INTO sessions (token, player_id) SELECT 'bob-token', id FROM players WHERE username = 'bob'`);
  const before = (await h.pool.query('SELECT * FROM players ORDER BY id')).rows;

  const ws = h.newSocket();
  // No session, or a challenge for someone else's session, cannot link.
  assert.equal((await h.call(ws, { type: 'google_challenge', purpose: 'link', token: 'nope' })).code, 'unauthorized');
  const nonce = await h.nonceFor(ws, 'link', 'alice-token');
  const asBob = await h.call(ws, { type: 'google_link', token: 'bob-token', nonce, credential: h.token(h.claims({ nonce, sub: 'sub-alice' })) });
  assert.equal(asBob.code, 'unauthorized', "a challenge issued for alice's session cannot link bob");

  const nonce2 = await h.nonceFor(ws, 'link', 'alice-token');
  const linked = await h.call(ws, { type: 'google_link', token: 'alice-token', nonce: nonce2, credential: h.token(h.claims({ nonce: nonce2, sub: 'sub-alice' })) });
  assert.equal(linked.success, true);
  assert.equal(linked.account.google_linked, true);
  const after = (await h.pool.query('SELECT * FROM players ORDER BY id')).rows;
  for (const key of Object.keys(before[0])) {
    if (key === 'google_sub' || key === 'google_linked_at') continue;
    assert.deepEqual(after[0][key], before[0][key], `alice ${key} preserved`);
  }
  assert.equal(after[0].google_sub, 'sub-alice');
  assert.deepEqual(after[1], before[1], 'bob untouched');

  // Bob tries to claim alice's Google identity: refused, nobody changes.
  const wsBob = h.newSocket();
  const bobNonce = await h.nonceFor(wsBob, 'link', 'bob-token');
  const stolen = await h.call(wsBob, { type: 'google_link', token: 'bob-token', nonce: bobNonce, credential: h.token(h.claims({ nonce: bobNonce, sub: 'sub-alice' })) });
  assert.equal(stolen.code, 'google_in_use');
  // Alice cannot swap to a second Google identity (no unlinking in scope).
  const second = await h.nonceFor(ws, 'link', 'alice-token');
  assert.equal((await h.call(ws, { type: 'google_link', token: 'alice-token', nonce: second, credential: h.token(h.claims({ nonce: second, sub: 'sub-other' })) })).code, 'already_linked');
  // Linking the same identity again is harmless.
  const third = await h.nonceFor(ws, 'link', 'alice-token');
  assert.equal((await h.call(ws, { type: 'google_link', token: 'alice-token', nonce: third, credential: h.token(h.claims({ nonce: third, sub: 'sub-alice' })) })).success, true);
  const final = (await h.pool.query('SELECT username, google_sub FROM players ORDER BY id')).rows;
  assert.deepEqual(final, [{ username: 'alice', google_sub: 'sub-alice' }, { username: 'bob', google_sub: null }]);

  // The linked identity now signs into the same player: same decks, balances, rank.
  const wsIn = h.newSocket();
  const inNonce = await h.nonceFor(wsIn, 'signin');
  const signedIn = await h.call(wsIn, { type: 'google_signin', nonce: inNonce, credential: h.token(h.claims({ nonce: inNonce, sub: 'sub-alice' })) });
  assert.equal(signedIn.username, 'alice');
  assert.equal(signedIn.rank_bracket, 4);
});

test('concurrent creation and linking cannot produce two players for one identity', { skip }, async (t) => {
  const h = await harness(t);
  // Two tabs complete the same brand-new Google identity at once.
  const tabs = [h.newSocket(), h.newSocket()];
  const setups = [];
  for (const ws of tabs) {
    const nonce = await h.nonceFor(ws, 'signin');
    setups.push((await h.call(ws, { type: 'google_signin', nonce, credential: h.token(h.claims({ nonce, sub: 'race-sub' })) })).setup_token);
  }
  const results = await Promise.all(tabs.map((ws, i) => h.call(ws, { type: 'google_register', setup_token: setups[i], username: `racer_${i}` })));
  assert.equal(results.filter((r) => r.success).length, 1, 'exactly one tab wins');
  assert.equal(results.filter((r) => r.code === 'google_in_use').length, 1);
  assert.equal(await h.count(`SELECT count(*)::int AS n FROM players WHERE google_sub = 'race-sub'`), 1);

  // Two Google identities racing for one username: one gets it, the other is told it is taken.
  const sockets = [h.newSocket(), h.newSocket()];
  const pending = [];
  for (const [i, ws] of sockets.entries()) {
    const nonce = await h.nonceFor(ws, 'signin');
    pending.push((await h.call(ws, { type: 'google_signin', nonce, credential: h.token(h.claims({ nonce, sub: `name-sub-${i}` })) })).setup_token);
  }
  const named = await Promise.all(sockets.map((ws, i) => h.call(ws, { type: 'google_register', setup_token: pending[i], username: 'shared_name' })));
  assert.equal(named.filter((r) => r.success).length, 1);
  assert.equal(named.filter((r) => r.code === 'username_taken').length, 1);
  assert.equal(await h.count(`SELECT count(*)::int AS n FROM players WHERE username = 'shared_name'`), 1);

  // Two players race to link the same identity.
  await h.pool.query(`INSERT INTO players (username, password_hash, salt) VALUES ('p1', 'h', 's'), ('p2', 'h', 's')`);
  await h.pool.query(`INSERT INTO sessions (token, player_id) SELECT 't-' || username, id FROM players WHERE username IN ('p1', 'p2')`);
  const linkers = [['p1', h.newSocket()], ['p2', h.newSocket()]];
  const prepared = [];
  for (const [name, ws] of linkers) {
    const nonce = await h.nonceFor(ws, 'link', `t-${name}`);
    prepared.push({ ws, message: { type: 'google_link', token: `t-${name}`, nonce, credential: h.token(h.claims({ nonce, sub: 'link-race' })) } });
  }
  const linkResults = await Promise.all(prepared.map(({ ws, message }) => h.call(ws, message)));
  assert.equal(linkResults.filter((r) => r.success).length, 1);
  assert.equal(linkResults.filter((r) => r.code === 'google_in_use').length, 1);
  assert.equal(await h.count(`SELECT count(*)::int AS n FROM players WHERE google_sub = 'link-race'`), 1);
});
