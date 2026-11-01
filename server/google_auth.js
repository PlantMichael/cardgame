'use strict';
// Google sign-in for the website.
//
// The browser renders Google's own button and hands the relay the signed ID
// token it receives. The relay verifies it (signature, issuer, audience and
// expiry, through google-auth-library) and ties it to a short-lived, single-use
// challenge it issued to that same connection for that purpose, so a replayed,
// stolen or unsolicited token is refused. The verified `sub` is the only
// identity key: an e-mail address or display name never finds, creates or
// merges a player.
//
// Wire messages (all JSON over the existing relay websocket):
//   google_config            -> google_config_result { available, client_id? }
//   google_challenge         { purpose: 'signin'|'link', token? }
//                            -> google_challenge_result { success, nonce, expires_in_s }
//   google_signin            { credential, nonce }
//                            -> google_signin_result { success, token, ...profile, decks }
//                             | google_signin_result { success, needs_username: true, setup_token }
//   google_register          { setup_token, username }
//                            -> google_register_result { success, token, ...profile, decks }
//   google_link              { token, credential, nonce }
//                            -> google_link_result { success, account }
// Failures carry { success: false, code, message }. `code` is one of
// unavailable, origin, bad_request, rate_limited, bad_challenge, bad_token,
// unauthorized, google_in_use, already_linked, username_taken, invalid_username,
// expired, server_error.
const crypto = require('node:crypto');
const { OAuth2Client } = require('google-auth-library');

const MAX_CREDENTIAL_LENGTH = 8192;
const VERIFY_TIMEOUT_MS = 5000;
const CHALLENGE_TTL_MS = 5 * 60 * 1000;
const SETUP_TTL_MS = 10 * 60 * 1000;
const MAX_OUTSTANDING_CHALLENGES = 5;
const MAX_FAILURES_PER_CONNECTION = 10;
// Google ID tokens live about an hour; refuse anything claiming far more.
const MAX_TOKEN_LIFETIME_S = 2 * 60 * 60;

function randomToken(bytes = 32) {
  return crypto.randomBytes(bytes).toString('hex');
}

/**
 * Wraps google-auth-library. `certsUrl` exists so a test can serve its own
 * signing keys through the library's real key-fetch path; production leaves it
 * unset, so Google's published keys are the only ones ever trusted. The
 * issuer list, audience and key endpoint are never taken from a client.
 */
function createGoogleVerifier({ clientId, certsUrl } = {}) {
  const options = { clientId };
  if (certsUrl) options.endpoints = { oauth2FederatedSignonPemCertsUrl: certsUrl };
  const client = new OAuth2Client(options);
  return {
    async verify(credential) {
      const ticket = await client.verifyIdToken({ idToken: credential, audience: clientId, maxExpiry: MAX_TOKEN_LIFETIME_S });
      const payload = ticket.getPayload();
      if (!payload || typeof payload.sub !== 'string' || payload.sub === '' || payload.sub.length > 255) {
        throw new Error('token has no usable subject');
      }
      return { sub: payload.sub, nonce: typeof payload.nonce === 'string' ? payload.nonce : '' };
    },
  };
}

function parseOrigins(value) {
  return String(value || '').split(',').map((o) => o.trim()).filter(Boolean);
}

/**
 * `deps`: pool, sendTo, makeToken, usernameRe, profileOf, decksOf,
 * accountSnapshotByToken. `config`: clientId, origins, verifier.
 * Returns { handles(type), handle(ws, msg), onClose(ws), available }.
 */
function createGoogleAuth(deps, config) {
  const { pool, sendTo, makeToken, usernameRe, profileOf, decksOf, accountSnapshotByToken } = deps;
  const origins = new Set(config.origins || []);
  const available = Boolean(config.clientId && config.verifier && origins.size > 0);
  // ws -> { challenges: Map(nonce -> { purpose, playerId, expires }), failures }
  const connections = new WeakMap();
  // setup_token -> { ws, sub, expires }; bounded by sweeping and a hard cap.
  const setups = new Map();
  const TYPES = new Set(['google_config', 'google_challenge', 'google_signin', 'google_register', 'google_link']);

  function stateOf(ws) {
    let s = connections.get(ws);
    if (!s) { s = { challenges: new Map(), failures: 0 }; connections.set(ws, s); }
    return s;
  }

  function sweep(now = Date.now()) {
    for (const [token, setup] of setups) if (setup.expires <= now) setups.delete(token);
  }

  function fail(ws, type, code, message) {
    sendTo(ws, { type, success: false, code, message });
  }

  function countFailure(ws) { stateOf(ws).failures += 1; }

  // The challenge a credential answers: issued here, to this connection, for
  // this purpose, unexpired, and consumed by the attempt whatever its outcome.
  function takeChallenge(ws, nonce, purpose) {
    const state = stateOf(ws);
    const challenge = typeof nonce === 'string' ? state.challenges.get(nonce) : undefined;
    if (!challenge) return null;
    state.challenges.delete(nonce);
    if (challenge.expires <= Date.now() || challenge.purpose !== purpose) return null;
    return challenge;
  }

  async function verifyCredential(credential, nonce) {
    let timer;
    try {
      const claims = await Promise.race([
        config.verifier.verify(credential),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('verification timed out')), VERIFY_TIMEOUT_MS); }),
      ]);
      // Constant-time comparison of the nonce Google signed with the one we issued.
      const a = Buffer.from(claims.nonce);
      const b = Buffer.from(nonce);
      if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
      return claims.sub;
    } catch {
      // Never log the credential or the library's message (it can echo the token).
      return null;
    } finally {
      clearTimeout(timer);
    }
  }

  // Common gate: configured, an allowed browser origin, not hammering.
  function admit(ws, replyType) {
    if (!available) { fail(ws, replyType, 'unavailable', 'Google sign-in is not available.'); return false; }
    if (!origins.has(ws.siteOrigin || '')) { fail(ws, replyType, 'origin', 'Google sign-in is only available from the website.'); return false; }
    if (stateOf(ws).failures >= MAX_FAILURES_PER_CONNECTION) { fail(ws, replyType, 'rate_limited', 'Too many attempts. Reload the page and try again.'); return false; }
    return true;
  }

  async function sessionFor(playerId) {
    const token = makeToken();
    await pool.query('INSERT INTO sessions (token, player_id) VALUES ($1, $2)', [token, playerId]);
    return token;
  }

  async function handleChallenge(ws, msg) {
    const reply = 'google_challenge_result';
    if (!admit(ws, reply)) return;
    const purpose = msg.purpose;
    if (purpose !== 'signin' && purpose !== 'link') { fail(ws, reply, 'bad_request', 'Unknown purpose.'); return; }
    let playerId = null;
    if (purpose === 'link') {
      const found = typeof msg.token === 'string' && msg.token.length <= 128
        ? await pool.query('SELECT player_id FROM sessions WHERE token = $1', [msg.token]) : { rows: [] };
      if (!found.rows[0]) { fail(ws, reply, 'unauthorized', 'Session expired.'); return; }
      playerId = found.rows[0].player_id;
    }
    const state = stateOf(ws);
    const now = Date.now();
    for (const [nonce, challenge] of state.challenges) if (challenge.expires <= now) state.challenges.delete(nonce);
    if (state.challenges.size >= MAX_OUTSTANDING_CHALLENGES) {
      // Oldest first: a page that keeps reloading its button must not lock itself out.
      state.challenges.delete(state.challenges.keys().next().value);
    }
    const nonce = randomToken(16);
    state.challenges.set(nonce, { purpose, playerId, expires: now + CHALLENGE_TTL_MS });
    sendTo(ws, { type: reply, success: true, nonce, expires_in_s: Math.floor(CHALLENGE_TTL_MS / 1000) });
  }

  async function handleSignin(ws, msg) {
    const reply = 'google_signin_result';
    if (!admit(ws, reply)) return;
    if (typeof msg.credential !== 'string' || msg.credential.length === 0 || msg.credential.length > MAX_CREDENTIAL_LENGTH) {
      countFailure(ws); fail(ws, reply, 'bad_request', 'Invalid Google credential.'); return;
    }
    const challenge = takeChallenge(ws, msg.nonce, 'signin');
    if (!challenge) { countFailure(ws); fail(ws, reply, 'bad_challenge', 'Sign-in expired. Try again.'); return; }
    const sub = await verifyCredential(msg.credential, msg.nonce);
    if (!sub) { countFailure(ws); fail(ws, reply, 'bad_token', 'Google could not verify that sign-in.'); return; }
    const found = await pool.query('SELECT * FROM players WHERE google_sub = $1', [sub]);
    const player = found.rows[0];
    if (player) {
      const token = await sessionFor(player.id);
      sendTo(ws, { type: reply, success: true, token, ...profileOf(player), decks: await decksOf(player.id) });
      return;
    }
    // A Google identity nobody has used yet: the player picks a game username
    // before anything is created. Nothing from the Google profile is kept.
    sweep();
    if (setups.size >= 1000) { fail(ws, reply, 'rate_limited', 'Try again shortly.'); return; }
    const setupToken = randomToken(24);
    setups.set(setupToken, { ws, sub, expires: Date.now() + SETUP_TTL_MS });
    sendTo(ws, { type: reply, success: true, needs_username: true, setup_token: setupToken });
  }

  async function handleRegister(ws, msg) {
    const reply = 'google_register_result';
    if (!admit(ws, reply)) return;
    sweep();
    const setup = typeof msg.setup_token === 'string' ? setups.get(msg.setup_token) : undefined;
    if (!setup || setup.ws !== ws || setup.expires <= Date.now()) {
      countFailure(ws); fail(ws, reply, 'expired', 'That sign-in has expired. Sign in with Google again.'); return;
    }
    if (typeof msg.username !== 'string' || !usernameRe.test(msg.username)) {
      fail(ws, reply, 'invalid_username', 'Username must be 3-20 letters, numbers, or underscores.'); return;
    }
    let player;
    try {
      // One statement: either the player exists with its Google identity, or nothing does.
      const inserted = await pool.query(
        `INSERT INTO players (username, google_sub, google_linked_at) VALUES ($1, $2, now())
         RETURNING id, username, wins, losses, rating, rank_bracket, rank_in_legend, rank_legend_rating,
                   rank_lp, ranked_win_streak, ranked_wins, ranked_losses, pfp_id`,
        [msg.username, setup.sub]
      );
      player = inserted.rows[0];
    } catch (err) {
      if (err && err.code === '23505') {
        if (String(err.constraint).includes('google_sub')) {
          // Someone completed this Google identity first (a second tab): the setup is spent.
          setups.delete(msg.setup_token);
          fail(ws, reply, 'google_in_use', 'That Google account is already registered. Sign in with Google again.'); return;
        }
        fail(ws, reply, 'username_taken', 'That username is taken.'); return;
      }
      throw err;
    }
    setups.delete(msg.setup_token);
    const token = await sessionFor(player.id);
    sendTo(ws, { type: reply, success: true, token, ...profileOf(player), decks: [] });
  }

  async function handleLink(ws, msg) {
    const reply = 'google_link_result';
    if (!admit(ws, reply)) return;
    if (typeof msg.credential !== 'string' || msg.credential.length === 0 || msg.credential.length > MAX_CREDENTIAL_LENGTH
        || typeof msg.token !== 'string' || msg.token.length > 128) {
      countFailure(ws); fail(ws, reply, 'bad_request', 'Invalid Google credential.'); return;
    }
    const challenge = takeChallenge(ws, msg.nonce, 'link');
    if (!challenge) { countFailure(ws); fail(ws, reply, 'bad_challenge', 'Linking expired. Try again.'); return; }
    // The session must still be the one that asked for the challenge.
    const session = await pool.query('SELECT player_id FROM sessions WHERE token = $1', [msg.token]);
    if (!session.rows[0] || session.rows[0].player_id !== challenge.playerId) {
      countFailure(ws); fail(ws, reply, 'unauthorized', 'Session expired.'); return;
    }
    const sub = await verifyCredential(msg.credential, msg.nonce);
    if (!sub) { countFailure(ws); fail(ws, reply, 'bad_token', 'Google could not verify that sign-in.'); return; }
    try {
      const updated = await pool.query(
        'UPDATE players SET google_sub = $1, google_linked_at = now() WHERE id = $2 AND google_sub IS NULL',
        [sub, challenge.playerId]
      );
      if (updated.rowCount === 0) {
        // Either already linked to this very Google account (harmless) or to a different one (refused).
        const current = await pool.query('SELECT google_sub FROM players WHERE id = $1', [challenge.playerId]);
        if (current.rows[0] && current.rows[0].google_sub === sub) {
          sendTo(ws, { type: reply, success: true, account: await accountSnapshotByToken(msg.token) });
          return;
        }
        fail(ws, reply, 'already_linked', 'This account is already linked to a different Google account.'); return;
      }
    } catch (err) {
      if (err && err.code === '23505') {
        // The identity belongs to another player: neither account changes.
        fail(ws, reply, 'google_in_use', 'That Google account is already linked to another player.'); return;
      }
      throw err;
    }
    sendTo(ws, { type: reply, success: true, account: await accountSnapshotByToken(msg.token) });
  }

  const handlers = {
    google_challenge: handleChallenge,
    google_signin: handleSignin,
    google_register: handleRegister,
    google_link: handleLink,
  };

  return {
    available,
    handles: (type) => TYPES.has(type),
    async handle(ws, msg) {
      if (msg.type === 'google_config') {
        sendTo(ws, { type: 'google_config_result', available: available && origins.has(ws.siteOrigin || ''),
          ...(available && origins.has(ws.siteOrigin || '') ? { client_id: config.clientId } : {}) });
        return;
      }
      try {
        await handlers[msg.type](ws, msg);
      } catch (err) {
        console.error('google auth error', msg.type, err && err.code ? err.code : 'unexpected');
        fail(ws, `${msg.type}_result`, 'server_error', 'Server error, try again.');
      }
    },
    onClose(ws) {
      connections.delete(ws);
      for (const [token, setup] of setups) if (setup.ws === ws) setups.delete(token);
    },
  };
}

function createGoogleAuthFromEnv(deps, env = process.env) {
  const clientId = (env.GOOGLE_CLIENT_ID || '').trim();
  const origins = parseOrigins(env.SITE_ORIGINS);
  const verifier = clientId ? createGoogleVerifier({ clientId, certsUrl: undefined }) : null;
  if (!clientId) console.log('Google sign-in disabled: GOOGLE_CLIENT_ID is not set.');
  else if (origins.length === 0) console.log('Google sign-in disabled: SITE_ORIGINS is empty.');
  return createGoogleAuth(deps, { clientId, origins, verifier });
}

module.exports = { createGoogleAuth, createGoogleAuthFromEnv, createGoogleVerifier, parseOrigins,
  CHALLENGE_TTL_MS, MAX_CREDENTIAL_LENGTH, MAX_FAILURES_PER_CONNECTION };
