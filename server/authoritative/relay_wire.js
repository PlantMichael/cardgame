'use strict';
// Glue between relay.js and the server-run match machinery, kept out of relay.js
// so the relay's edit stays small and this part can be tested with fakes.
//
// Off unless RANKED_AUTHORITATIVE=1: with the flag unset relay.js behaves exactly
// as before (peer-hosted ranked matches).
const { HostProcess } = require('./host_process');
const { MatchManager } = require('./match_manager');
const { PgStore, initSchema } = require('./schema');
const { makeSettler } = require('./settle');
const { loadCards } = require('./decks');
const { MAX_FRAME_BYTES, FRAMES_PER_SECOND, RateLimiter } = require('./protocol');

// How long a verified session token stays usable for the socket that presented
// it. Short enough that a revoked token stops working almost at once, long
// enough that a normal match is not one database query per frame.
const SESSION_CACHE_MS = 10000;

/** Tunables from the environment; anything unset keeps the manager's default (FR-023). */
function configFromEnv(env = process.env) {
  const map = {
    RANKED_MAX_LIVE_MATCHES: 'maxLiveMatches',
    RANKED_TURN_SECONDS: 'turnSeconds',
    RANKED_MULLIGAN_SECONDS: 'mulliganSeconds',
    RANKED_GRACE_SECONDS: 'graceSeconds',
  };
  const out = {};
  for (const [key, name] of Object.entries(map)) {
    const n = Number(env[key]);
    if (env[key] !== undefined && Number.isFinite(n) && n > 0) out[name] = n;
  }
  return out;
}

const MATCH_TYPES = new Set(['match_join', 'match_command', 'match_mulligan', 'match_concede', 'match_ping']);

function isEnabled(env = process.env) {
  return env.RANKED_AUTHORITATIVE === '1' || env.RANKED_AUTHORITATIVE === 'true';
}

class Authoritative {
  /**
   * @param deps.pool      pg pool
   * @param deps.manager   optional prebuilt MatchManager (tests)
   * @param deps.log       logger
   */
  constructor({ pool, manager = null, host = null, log = console }) {
    this.pool = pool;
    this.log = log;
    this.conns = new WeakMap(); // ws -> connection adapter given to the manager
    this.budget = new WeakMap(); // ws -> frame budget (before any seat is known)
    this.session = new WeakMap(); // ws -> { token, playerId, until } verified recently
    this.host = host;
    this.manager = manager;
    this.timer = null;
  }

  /** Creates the tables, the host process and the manager, and starts ticking. */
  async start() {
    await initSchema(this.pool);
    if (!this.manager) {
      this.host = this.host || new HostProcess({ log: this.log });
      this.manager = new MatchManager({
        store: new PgStore(this.pool),
        host: this.host,
        cards: loadCards(),
        settle: makeSettler(this.pool),
        config: configFromEnv(),
        log: this.log,
      });
      await this.host.start(); // 'ready' triggers manager.resume() for matches in flight
    }
    this.timer = setInterval(() => {
      this.manager.tick().catch((e) => this.log.error('match tick failed', e.message));
    }, 1000);
    if (this.timer.unref) this.timer.unref();
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    if (this.host && this.host.stop) this.host.stop();
  }

  get rulesVersion() { return this.host ? this.host.rulesVersion : null; }

  /** Whether a lobby/match id belongs to a server-run match (its result is never client-reported). */
  owns(matchId) { return this.manager.sessions.has(matchId); }

  /** The manager only needs send(obj) and close(); one adapter per socket. */
  connFor(ws, sendTo) {
    let c = this.conns.get(ws);
    if (!c) {
      c = { send: (obj) => sendTo(ws, obj), close: () => { try { ws.close(); } catch { /* already closed */ } } };
      this.conns.set(ws, c);
    }
    return c;
  }

  isMatchMessage(type) { return MATCH_TYPES.has(type); }

  /**
   * One token-bucket per socket, spent before the session lookup, so an
   * unauthenticated flood of match frames cannot turn into one database query
   * (and one audit row) per frame.
   */
  allowFrame(ws) {
    let b = this.budget.get(ws);
    if (!b) { b = new RateLimiter(FRAMES_PER_SECOND); this.budget.set(ws, b); }
    return b.take();
  }

  /** The player this socket's token belongs to, from a short-lived cache. */
  cachedPlayer(ws, token) {
    const c = this.session.get(ws);
    if (c && c.token === token && c.until > Date.now()) return c.playerId;
    return null;
  }

  rememberPlayer(ws, token, playerId) {
    this.session.set(ws, { token, playerId, until: Date.now() + SESSION_CACHE_MS });
  }

  /** Rejects oversized frames before anything parses them further. */
  frameTooLarge(rawFrame) {
    return rawFrame && (rawFrame.length || 0) > MAX_FRAME_BYTES;
  }

  /**
   * Starts a server-run match for two queued players. Returns { ok, error? }.
   * Deck, seed and first seat are decided inside createMatch - never by a client.
   */
  async pair(matchId, a, b) {
    return this.manager.createMatch({
      matchId,
      a: { playerId: a.playerId, deckName: a.deckName },
      b: { playerId: b.playerId, deckName: b.deckName },
    });
  }

  onClose(ws) {
    const c = this.conns.get(ws);
    if (c) this.manager.onClose(c);
  }

  /** Dispatch one authenticated match message. */
  async route(playerId, msg, ws, sendTo) {
    return this.manager.handleMessage(playerId, msg, this.connFor(ws, sendTo));
  }
}

module.exports = { Authoritative, isEnabled, configFromEnv, MATCH_TYPES, SESSION_CACHE_MS };
