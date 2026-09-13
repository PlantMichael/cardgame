const WebSocket = require('ws');
const crypto = require('crypto');
const { Pool } = require('pg');
const fs = require('fs');
const path = require('path');
const PORT = process.env.PORT || 8080;

// Railway injects DATABASE_URL automatically once a Postgres plugin is
// attached to this project — nothing to paste manually here. Local/internal
// Postgres instances don't speak SSL; a public Railway connection does.
const NO_SSL_HOSTS = ['railway.internal', 'localhost', '127.0.0.1'];
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DATABASE_URL && !NO_SSL_HOSTS.some(h => process.env.DATABASE_URL.includes(h))
    ? { rejectUnauthorized: false }
    : false,
  // Idle pooled connections can die silently on Railway's internal network.
  // Without these, a reused dead connection just hangs forever instead of
  // erroring — keepAlive cuts down on that happening, idleTimeoutMillis
  // recycles connections before they go stale, and query_timeout guarantees
  // a query fails loudly (so callers get a response) instead of hanging.
  keepAlive: true,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 10000,
  query_timeout: 10000,
});

async function initDb() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS players (
      id SERIAL PRIMARY KEY,
      username TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      salt TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      wins INTEGER NOT NULL DEFAULT 0,
      losses INTEGER NOT NULL DEFAULT 0,
      rating INTEGER NOT NULL DEFAULT 1000
    )
  `);
  // The players table above already exists on deployed databases, so new
  // columns must be added with ALTER TABLE — CREATE TABLE IF NOT EXISTS only
  // affects table creation, it won't retrofit columns onto an existing table.
  await pool.query(`
    ALTER TABLE players ADD COLUMN IF NOT EXISTS rank_bracket INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS rank_in_legend BOOLEAN NOT NULL DEFAULT false;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS rank_legend_rating INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS rank_lp INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS ranked_win_streak INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players DROP COLUMN IF EXISTS rank_floor;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS ranked_wins INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS ranked_losses INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS currency INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS dust INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS last_daily_reward_at DATE;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS pfp_id TEXT NOT NULL DEFAULT '';
  `);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS sessions (
      token TEXT PRIMARY KEY,
      player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);
  // Custom decks, tied to the account instead of the browser (see save_deck/
  // delete_deck below) — one row per deck, keyed by (player_id, name) so
  // saving under an existing name overwrites it, mirroring the old
  // per-browser storage's filename-keyed behavior.
  await pool.query(`
    CREATE TABLE IF NOT EXISTS decks (
      id SERIAL PRIMARY KEY,
      player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      faction_idx INTEGER NOT NULL DEFAULT 0,
      card_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      UNIQUE (player_id, name)
    )
  `);
  // Card ownership (currency/shop/pack-unboxing feature) - one row per
  // (player, card) the player has ever obtained. No ownership concept
  // existed before this table; the deck builder previously treated every
  // card as available to everyone.
  await pool.query(`
    CREATE TABLE IF NOT EXISTS owned_cards (
      player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      card_id TEXT NOT NULL,
      quantity INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (player_id, card_id)
    )
  `);
}

async function decksOf(playerId) {
  const result = await pool.query(
    'SELECT name, faction_idx, card_ids FROM decks WHERE player_id = $1 ORDER BY id',
    [playerId]
  );
  return result.rows.map(r => ({ name: r.name, faction_idx: r.faction_idx, card_ids: r.card_ids }));
}

async function ownedCardsOf(playerId) {
  const result = await pool.query(
    'SELECT card_id, quantity FROM owned_cards WHERE player_id = $1 ORDER BY card_id',
    [playerId]
  );
  return result.rows.map(r => ({ card_id: r.card_id, quantity: r.quantity }));
}

// --- Card data & shop packs (currency/shop/pack-unboxing feature) ---------
//
// The server needs to know each card's rarity (and exclude tokens) to roll
// packs and price crafting, but card content is authored once, in the Godot
// project's data/cards/*.json - reading those same files here (rather than
// re-typing card data into a second JS schema) keeps that single source of
// truth intact, per specs/001-currency-pack-shop/research.md decision 2.
const DATA_DIR = path.join(__dirname, '..', 'data');
const CARD_FILES = ['green', 'crimson', 'black', 'orange', 'teal', 'generic'];

// card_id -> { rarity }, non-token cards only (tokens aren't pack-eligible).
const CARD_RARITY = new Map();
for (const name of CARD_FILES) {
  const cards = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'cards', `${name}.json`), 'utf8'));
  for (const card of cards) {
    if (card.is_token) continue;
    CARD_RARITY.set(card.id, card.rarity);
  }
}

// pack_id -> pack definition (see data/shop_packs.json / data-model.md).
const SHOP_PACKS = new Map();
for (const pack of JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'shop_packs.json'), 'utf8'))) {
  SHOP_PACKS.set(pack.pack_id, pack);
}

// Mirrors DeckManager.max_copies_for() in scripts/game/deck_manager.gd -
// keep these in sync if that ever changes.
const MAX_CARD_COPIES = 2;
function maxCopiesFor(rarity) {
  return rarity === 'LEGENDARY' ? 1 : MAX_CARD_COPIES;
}

// Crafting costs (dust), scaled by rarity - roughly 2x each pack's
// dust_value for that rarity, a standard CCG "crafting costs more than
// disenchanting" ratio. Tuning detail, not a spec requirement.
const CRAFT_COST_BY_RARITY = { COMMON: 40, RARE: 100, EPIC: 400, LEGENDARY: 1600 };

function weightedPick(candidates, weights, rng) {
  const total = weights.reduce((a, b) => a + b, 0);
  const roll = rng() * total;
  let cumulative = 0;
  for (let i = 0; i < candidates.length; i++) {
    cumulative += weights[i];
    if (roll <= cumulative) return candidates[i];
  }
  return candidates[candidates.length - 1];
}

// Mirrors PackOpener.roll_pack in scripts/game/pack_opener.gd (see
// research.md decision 3: the roll itself is duplicated - not the card
// data - because this server call is the authoritative one for real
// purchases, while the client-side copy exists for the headless
// `--shop-test` dev hook).
function rollPack(packDef, ownedCardsMap, rng = Math.random) {
  const poolByRarity = {};
  for (const [cardId, rarity] of CARD_RARITY.entries()) {
    (poolByRarity[rarity] ||= []).push(cardId);
  }
  function rollOne(allowedRarities) {
    const candidates = [];
    const weights = [];
    for (const [rarity, weight] of Object.entries(packDef.rarity_weights)) {
      if (allowedRarities && !allowedRarities.includes(rarity)) continue;
      const bucket = poolByRarity[rarity];
      if (!bucket || bucket.length === 0) continue;
      candidates.push(rarity);
      weights.push(weight);
    }
    if (candidates.length === 0) return null;
    const rarity = weightedPick(candidates, weights, rng);
    const bucket = poolByRarity[rarity];
    const cardId = bucket[Math.floor(rng() * bucket.length)];
    return { card_id: cardId, rarity };
  }

  const picks = [];
  for (let i = 0; i < packDef.card_count; i++) {
    const pick = rollOne(null);
    if (pick) picks.push(pick);
  }
  if (packDef.guaranteed_rare_or_better && picks.length > 0 && !picks.some(p => p.rarity !== 'COMMON')) {
    const better = rollOne(['RARE', 'EPIC', 'LEGENDARY']);
    if (better) picks[0] = better;
  }

  const workingOwned = new Map(ownedCardsMap);
  let dustAwarded = 0;
  const cardsOut = picks.map(({ card_id, rarity }) => {
    const maxCopies = maxCopiesFor(rarity);
    const owned = workingOwned.get(card_id) || 0;
    const wasNew = owned < maxCopies;
    if (wasNew) workingOwned.set(card_id, owned + 1);
    else dustAwarded += packDef.dust_value[rarity] || 0;
    return { card_id, was_new: wasNew, rarity };
  });
  return { cards: cardsOut, dust_awarded: dustAwarded };
}

// --- Ranked ladder (mirrors scripts/game/ranked_progress.gd's display math;
// keep BRACKET_COUNT/LP constants in sync with that file) ------------------

const RANK_BRACKET_COUNT = 21; // 7 named tiers x 3 sub-ranks (Orbital III .. Cosmic I)
const RANK_LEGEND_RATING_STEP = 25;
const LEGEND_TIER_SPAN = 500; // rating span of the Superluminal (lowest legend) band

// LP economy for the bracketed ladder (Orbital III .. Cosmic I). A win/loss
// never demotes a bracket here — a loss just floors LP at 0 — so there's no
// tier-floor protection to track any more (that only mattered when losses
// could drop you back a bracket).
const RANK_LP_PER_BRACKET = 100;
const RANK_LP_WIN_BASE = 34;
const RANK_LP_WIN_STREAK = 45; // 3rd win-in-a-row and every win after, until a loss
const RANK_LP_WIN_STREAK_THRESHOLD = 3;
const RANK_LP_LOSS = 20;

// Pure function: given the player's current rank row and whether they just
// won, returns the next rank state. Kept server-side and authoritative (the
// client only ever sends a boolean `won`) so the persisted ladder position
// can't just be dictated by the client.
//
// Legend (Superluminal/Celestial/Universal) keeps its own separate
// continuous-rating system, unaffected by the LP economy above, *except*:
// a loss that would push legend rating below 0 while still in the lowest
// band (Superluminal) demotes the player out of Legend entirely, back to
// Cosmic I — landing LP carries the negative overflow the same way bracket
// promotion/demotion does, floored at 0.
function nextRankState(player, won) {
  let bracket = player.rank_bracket;
  let inLegend = player.rank_in_legend;
  let legendRating = player.rank_legend_rating;
  let lp = player.rank_lp;
  let winStreak = player.ranked_win_streak;
  let rankedWins = player.ranked_wins;
  let rankedLosses = player.ranked_losses;
  if (won) {
    rankedWins += 1;
    winStreak += 1;
    if (inLegend) {
      legendRating += RANK_LEGEND_RATING_STEP;
    } else {
      const gain = winStreak >= RANK_LP_WIN_STREAK_THRESHOLD ? RANK_LP_WIN_STREAK : RANK_LP_WIN_BASE;
      lp += gain;
      if (lp >= RANK_LP_PER_BRACKET) {
        const overflow = lp - RANK_LP_PER_BRACKET;
        if (bracket >= RANK_BRACKET_COUNT - 1) {
          inLegend = true;
          legendRating = overflow;
          lp = 0;
        } else {
          bracket += 1;
          lp = overflow;
        }
      }
    }
  } else {
    rankedLosses += 1;
    winStreak = 0;
    if (inLegend) {
      const next = legendRating - RANK_LEGEND_RATING_STEP;
      if (next < 0 && legendRating < LEGEND_TIER_SPAN) {
        // Demoted out of Legend back to Cosmic I, carrying the overflow.
        inLegend = false;
        bracket = RANK_BRACKET_COUNT - 1;
        lp = Math.max(0, RANK_LP_PER_BRACKET + next);
      } else {
        legendRating = Math.max(0, next);
      }
    } else {
      lp = Math.max(0, lp - RANK_LP_LOSS);
    }
  }
  return {
    rank_bracket: bracket, rank_in_legend: inLegend, rank_legend_rating: legendRating,
    rank_lp: lp, ranked_win_streak: winStreak,
    ranked_wins: rankedWins, ranked_losses: rankedLosses,
  };
}

// --- Matchmaking Elo (`players.rating`) ------------------------------------
//
// This is intentionally separate from the bracket/Legend ladder above: the
// ladder (rank_bracket/rank_in_legend/rank_legend_rating) is the single
// progression every player sees on the Ranked menu regardless of whether
// they played a bot or a human, while `rating` is an invisible Elo used only
// to pair players of similar skill in matchmaking (see the ranked queue
// below). Bot matches never touch it — there's no opponent account to rate
// against.
const ELO_K = 32;

function nextElo(rating, opponentRating, won) {
  const expected = 1 / (1 + Math.pow(10, (opponentRating - rating) / 400));
  return Math.max(100, Math.round(rating + ELO_K * ((won ? 1 : 0) - expected)));
}

// --- Auth helpers ---------------------------------------------------------

const USERNAME_RE = /^[A-Za-z0-9_]{3,20}$/;

function validateCredentials(username, password) {
  if (typeof username !== 'string' || !USERNAME_RE.test(username)) {
    return 'Username must be 3-20 letters, numbers, or underscores.';
  }
  if (typeof password !== 'string' || password.length < 6 || password.length > 128) {
    return 'Password must be at least 6 characters.';
  }
  return null;
}

function makeSalt() {
  return crypto.randomBytes(16).toString('hex');
}

function makeToken() {
  return crypto.randomBytes(32).toString('hex');
}

function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 64).toString('hex');
}

function verifyPassword(password, salt, expectedHash) {
  const hash = Buffer.from(hashPassword(password, salt), 'hex');
  const expected = Buffer.from(expectedHash, 'hex');
  return hash.length === expected.length && crypto.timingSafeEqual(hash, expected);
}

function profileOf(row) {
  return {
    username: row.username, wins: row.wins, losses: row.losses, rating: row.rating,
    rank_bracket: row.rank_bracket, rank_in_legend: row.rank_in_legend,
    rank_legend_rating: row.rank_legend_rating, rank_lp: row.rank_lp,
    ranked_win_streak: row.ranked_win_streak,
    ranked_wins: row.ranked_wins, ranked_losses: row.ranked_losses,
    pfp_id: row.pfp_id,
  };
}

// Client sends the chosen pfp's filename (see main.gd's PFP_DIR scan) as the
// id - constrained to a plain filename shape so it can never be used to
// escape res://assets/pfps/ when the client later builds a load() path from
// it (see _pfp_path in main.gd). Not a filesystem-traversal risk either way
// (res:// paths never leave the exported game's own bundle), but rejecting
// anything else here keeps the stored value meaningful.
const PFP_ID_RE = /^[a-zA-Z0-9_.-]{1,80}$/;

// --- Lobby state (unchanged, in-memory) -----------------------------------

// lobby_id -> { id, name, host_ws, guest_ws, host_name, guest_name, status }
const lobbies = new Map();
// ws -> { lobby_id, role }
const clients = new Map();

function sendTo(ws, obj) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(obj));
  }
}

function lobbyList() {
  return Array.from(lobbies.values())
    .filter(l => l.status === 'waiting')
    .map(l => ({ id: l.id, name: l.name, host_name: l.host_name }));
}

// --- Ranked matchmaking queue -----------------------------------------------
//
// The client owns the ~10s search window and gives up client-side (sending
// cancel_ranked_queue and falling back to an AI opponent) rather than the
// server pushing a timeout — this queue only ever needs to pair people while
// they're waiting, never to reject them.
//
// ws -> { id, username, rating, queuedAt }
const rankedQueue = new Map();

const RANKED_BAND_START = 100; // initial +/- rating window
const RANKED_BAND_GROWTH_PER_SEC = 60; // widens the longer both sides wait
const RANKED_SWEEP_MS = 500;

function ratingBandAt(queuedAt, now) {
  const waitedSec = (now - queuedAt) / 1000;
  return RANKED_BAND_START + waitedSec * RANKED_BAND_GROWTH_PER_SEC;
}

// Pairs up queued players within each other's widening rating band, oldest
// entries first so a long-waiting player matches as soon as anyone in range
// shows up. Runs on a timer rather than only on enqueue so two players who
// joined moments apart (and whose bands only now overlap) still get paired
// without either of them sending another message.
function sweepRankedQueue() {
  if (rankedQueue.size < 2) return;
  const now = Date.now();
  const waiting = Array.from(rankedQueue.entries()).sort((a, b) => a[1].queuedAt - b[1].queuedAt);
  const matched = new Set();
  for (let i = 0; i < waiting.length; i++) {
    const [wsA, a] = waiting[i];
    if (matched.has(wsA)) continue;
    const bandA = ratingBandAt(a.queuedAt, now);
    for (let j = i + 1; j < waiting.length; j++) {
      const [wsB, b] = waiting[j];
      if (matched.has(wsB)) continue;
      const bandB = ratingBandAt(b.queuedAt, now);
      const diff = Math.abs(a.rating - b.rating);
      if (diff <= bandA && diff <= bandB) {
        matched.add(wsA);
        matched.add(wsB);
        rankedQueue.delete(wsA);
        rankedQueue.delete(wsB);
        startRankedMatch(wsA, a, wsB, b);
        break;
      }
    }
  }
}

function startRankedMatch(wsHost, host, wsGuest, guest) {
  const id = 'rk_' + Math.random().toString(36).slice(2, 10);
  const lobby = {
    id, name: 'Ranked', host_ws: wsHost, guest_ws: wsGuest,
    host_name: host.username, guest_name: guest.username, status: 'full',
  };
  lobbies.set(id, lobby);
  clients.set(wsHost, { lobby_id: id, role: 'host' });
  clients.set(wsGuest, { lobby_id: id, role: 'guest' });
  sendTo(wsHost, {
    type: 'ranked_match_found', lobby_id: id, role: 'host',
    opponent_name: guest.username, opponent_rating: guest.rating,
  });
  sendTo(wsGuest, {
    type: 'ranked_match_found', lobby_id: id, role: 'guest',
    opponent_name: host.username, opponent_rating: host.rating,
  });
}

// --- Campaign matchmaking queue ---------------------------------------------
//
// Same client-owns-the-timeout shape as the ranked queue above (client gives
// up and falls back to an AI opponent for the whole run if nobody's found in
// time), but pairing only needs to check that both sides picked the same
// campaign size - no rating/skill band involved, so no sweep-with-widening-
// band logic is needed, just a straight match on first-come-first-served.
//
// ws -> { username, size, queuedAt }
const campaignQueue = new Map();
const CAMPAIGN_SWEEP_MS = 500;

function sweepCampaignQueue() {
  if (campaignQueue.size < 2) return;
  const waiting = Array.from(campaignQueue.entries()).sort((a, b) => a[1].queuedAt - b[1].queuedAt);
  const matched = new Set();
  for (let i = 0; i < waiting.length; i++) {
    const [wsA, a] = waiting[i];
    if (matched.has(wsA)) continue;
    for (let j = i + 1; j < waiting.length; j++) {
      const [wsB, b] = waiting[j];
      if (matched.has(wsB) || b.size !== a.size) continue;
      matched.add(wsA);
      matched.add(wsB);
      campaignQueue.delete(wsA);
      campaignQueue.delete(wsB);
      startCampaignMatch(wsA, a, wsB, b);
      break;
    }
  }
}

function startCampaignMatch(wsHost, host, wsGuest, guest) {
  const id = 'cp_' + Math.random().toString(36).slice(2, 10);
  const lobby = {
    id, name: 'Campaign', host_ws: wsHost, guest_ws: wsGuest,
    host_name: host.username, guest_name: guest.username, status: 'full',
  };
  lobbies.set(id, lobby);
  clients.set(wsHost, { lobby_id: id, role: 'host' });
  clients.set(wsGuest, { lobby_id: id, role: 'guest' });
  sendTo(wsHost, {
    type: 'campaign_match_found', lobby_id: id, role: 'host',
    opponent_name: guest.username, size: host.size,
  });
  sendTo(wsGuest, {
    type: 'campaign_match_found', lobby_id: id, role: 'guest',
    opponent_name: host.username, size: guest.size,
  });
}

async function main() {
  await initDb();

  const wss = new WebSocket.Server({ port: PORT });

  wss.on('connection', (ws) => {
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });

    ws.on('message', async (raw) => {
      let msg;
      try { msg = JSON.parse(raw); } catch { return; }

      switch (msg.type) {
        case 'register': {
          const username = msg.username;
          const password = msg.password;
          const validationError = validateCredentials(username, password);
          if (validationError) {
            sendTo(ws, { type: 'register_result', success: false, message: validationError });
            return;
          }
          try {
            const existing = await pool.query('SELECT id FROM players WHERE username = $1', [username]);
            if (existing.rows.length > 0) {
              sendTo(ws, { type: 'register_result', success: false, message: 'That username is taken.' });
              return;
            }
            const salt = makeSalt();
            const hash = hashPassword(password, salt);
            const inserted = await pool.query(
              `INSERT INTO players (username, password_hash, salt) VALUES ($1, $2, $3)
               RETURNING id, username, wins, losses, rating,
                         rank_bracket, rank_in_legend, rank_legend_rating, rank_lp, ranked_win_streak,
                         ranked_wins, ranked_losses`,
              [username, hash, salt]
            );
            const player = inserted.rows[0];
            const token = makeToken();
            await pool.query(
              'INSERT INTO sessions (token, player_id) VALUES ($1, $2)',
              [token, player.id]
            );
            sendTo(ws, { type: 'register_result', success: true, token, ...profileOf(player), decks: [] });
          } catch (err) {
            console.error('register error', err);
            sendTo(ws, { type: 'register_result', success: false, message: 'Server error, try again.' });
          }
          break;
        }

        case 'login': {
          const username = msg.username;
          const password = msg.password;
          try {
            const result = await pool.query('SELECT * FROM players WHERE username = $1', [username]);
            const player = result.rows[0];
            if (!player || !verifyPassword(password || '', player.salt, player.password_hash)) {
              sendTo(ws, { type: 'login_result', success: false, message: 'Invalid username or password.' });
              return;
            }
            const token = makeToken();
            await pool.query('INSERT INTO sessions (token, player_id) VALUES ($1, $2)', [token, player.id]);
            const decks = await decksOf(player.id);
            sendTo(ws, { type: 'login_result', success: true, token, ...profileOf(player), decks });
          } catch (err) {
            console.error('login error', err);
            sendTo(ws, { type: 'login_result', success: false, message: 'Server error, try again.' });
          }
          break;
        }

        case 'resume_session': {
          const token = msg.token;
          try {
            const result = await pool.query(
              `SELECT p.id, p.username, p.wins, p.losses, p.rating,
                      p.rank_bracket, p.rank_in_legend, p.rank_legend_rating, p.rank_lp, p.ranked_win_streak,
                      p.ranked_wins, p.ranked_losses
               FROM sessions s JOIN players p ON p.id = s.player_id WHERE s.token = $1`,
              [token]
            );
            const player = result.rows[0];
            if (!player) {
              sendTo(ws, { type: 'login_result', success: false, message: 'Session expired.' });
              return;
            }
            const decks = await decksOf(player.id);
            sendTo(ws, { type: 'login_result', success: true, token, ...profileOf(player), decks });
          } catch (err) {
            console.error('resume_session error', err);
            sendTo(ws, { type: 'login_result', success: false, message: 'Server error, try again.' });
          }
          break;
        }

        case 'save_deck': {
          const token = msg.token;
          const name = typeof msg.name === 'string' ? msg.name.trim() : '';
          const factionIdx = Number.isInteger(msg.faction_idx) ? msg.faction_idx : 0;
          const cardIds = Array.isArray(msg.card_ids) ? msg.card_ids.map(String) : [];
          if (!name || name.length > 40) {
            sendTo(ws, { type: 'save_deck_result', success: false, message: 'Invalid deck name.' });
            return;
          }
          try {
            const session = await pool.query('SELECT player_id FROM sessions WHERE token = $1', [token]);
            const row = session.rows[0];
            if (!row) {
              sendTo(ws, { type: 'save_deck_result', success: false, message: 'Session expired.' });
              return;
            }
            await pool.query(
              `INSERT INTO decks (player_id, name, faction_idx, card_ids) VALUES ($1, $2, $3, $4)
               ON CONFLICT (player_id, name) DO UPDATE SET faction_idx = $3, card_ids = $4`,
              [row.player_id, name, factionIdx, JSON.stringify(cardIds)]
            );
            sendTo(ws, { type: 'save_deck_result', success: true, name });
          } catch (err) {
            console.error('save_deck error', err);
            sendTo(ws, { type: 'save_deck_result', success: false, message: 'Server error, try again.' });
          }
          break;
        }

        case 'delete_deck': {
          const token = msg.token;
          const name = typeof msg.name === 'string' ? msg.name.trim() : '';
          try {
            const session = await pool.query('SELECT player_id FROM sessions WHERE token = $1', [token]);
            const row = session.rows[0];
            if (!row) {
              sendTo(ws, { type: 'delete_deck_result', success: false, message: 'Session expired.' });
              return;
            }
            await pool.query('DELETE FROM decks WHERE player_id = $1 AND name = $2', [row.player_id, name]);
            sendTo(ws, { type: 'delete_deck_result', success: true, name });
          } catch (err) {
            console.error('delete_deck error', err);
            sendTo(ws, { type: 'delete_deck_result', success: false, message: 'Server error, try again.' });
          }
          break;
        }

        case 'set_pfp': {
          const token = msg.token;
          const pfpId = typeof msg.pfp_id === 'string' ? msg.pfp_id : '';
          if (pfpId !== '' && !PFP_ID_RE.test(pfpId)) {
            sendTo(ws, { type: 'set_pfp_result', success: false, message: 'Invalid profile picture.' });
            return;
          }
          try {
            const session = await pool.query('SELECT player_id FROM sessions WHERE token = $1', [token]);
            const row = session.rows[0];
            if (!row) {
              sendTo(ws, { type: 'set_pfp_result', success: false, message: 'Session expired.' });
              return;
            }
            await pool.query('UPDATE players SET pfp_id = $1 WHERE id = $2', [pfpId, row.player_id]);
            sendTo(ws, { type: 'set_pfp_result', success: true, pfp_id: pfpId });
          } catch (err) {
            console.error('set_pfp error', err);
            sendTo(ws, { type: 'set_pfp_result', success: false, message: 'Server error, try again.' });
          }
          break;
        }

        case 'get_economy_state': {
          try {
            const session = await pool.query('SELECT player_id FROM sessions WHERE token = $1', [msg.token]);
            const row = session.rows[0];
            if (!row) {
              sendTo(ws, { type: 'economy_state_result', success: false, message: 'Session expired.' });
              return;
            }
            const player = await pool.query('SELECT currency, dust FROM players WHERE id = $1', [row.player_id]);
            const owned = await ownedCardsOf(row.player_id);
            sendTo(ws, {
              type: 'economy_state_result', success: true,
              currency: player.rows[0].currency, dust: player.rows[0].dust, owned_cards: owned,
            });
          } catch (err) {
            console.error('get_economy_state error', err);
            sendTo(ws, { type: 'economy_state_result', success: false, message: 'Server error, try again.' });
          }
          break;
        }

        case 'purchase_pack': {
          const packDef = SHOP_PACKS.get(msg.pack_id);
          if (!packDef) {
            sendTo(ws, { type: 'purchase_pack_result', success: false, message: 'Unknown pack.' });
            return;
          }
          const client = await pool.connect();
          try {
            await client.query('BEGIN');
            const session = await client.query('SELECT player_id FROM sessions WHERE token = $1', [msg.token]);
            const sessionRow = session.rows[0];
            if (!sessionRow) {
              await client.query('ROLLBACK');
              sendTo(ws, { type: 'purchase_pack_result', success: false, message: 'Session expired.' });
              return;
            }
            const playerId = sessionRow.player_id;
            // FOR UPDATE: locks this player's row for the rest of the
            // transaction so two purchases in flight at once can't both read
            // the same starting currency and both succeed past the check
            // below (FR-006 - a purchase must never partially or doubly
            // deduct).
            const playerResult = await client.query('SELECT currency, dust FROM players WHERE id = $1 FOR UPDATE', [playerId]);
            const player = playerResult.rows[0];
            if (player.currency < packDef.price) {
              await client.query('ROLLBACK');
              sendTo(ws, { type: 'purchase_pack_result', success: false, message: 'Not enough currency for this pack.' });
              return;
            }
            const ownedResult = await client.query('SELECT card_id, quantity FROM owned_cards WHERE player_id = $1', [playerId]);
            const ownedMap = new Map(ownedResult.rows.map(r => [r.card_id, r.quantity]));
            const rolled = rollPack(packDef, ownedMap);
            const newCurrency = player.currency - packDef.price;
            const newDust = player.dust + rolled.dust_awarded;
            for (const card of rolled.cards) {
              if (card.was_new) {
                await client.query(
                  `INSERT INTO owned_cards (player_id, card_id, quantity) VALUES ($1, $2, 1)
                   ON CONFLICT (player_id, card_id) DO UPDATE SET quantity = owned_cards.quantity + 1`,
                  [playerId, card.card_id]
                );
              }
            }
            await client.query('UPDATE players SET currency = $1, dust = $2 WHERE id = $3', [newCurrency, newDust, playerId]);
            await client.query('COMMIT');
            sendTo(ws, {
              type: 'purchase_pack_result', success: true, currency: newCurrency, dust: newDust,
              result: { pack_id: msg.pack_id, cards: rolled.cards, dust_awarded: rolled.dust_awarded },
            });
          } catch (err) {
            await client.query('ROLLBACK');
            console.error('purchase_pack error', err);
            sendTo(ws, { type: 'purchase_pack_result', success: false, message: 'Server error, try again.' });
          } finally {
            client.release();
          }
          break;
        }

        case 'craft_card': {
          const rarity = CARD_RARITY.get(msg.card_id);
          if (!rarity) {
            sendTo(ws, { type: 'craft_card_result', success: false, message: 'Unknown card.' });
            return;
          }
          const cost = CRAFT_COST_BY_RARITY[rarity] || 0;
          try {
            const session = await pool.query('SELECT player_id FROM sessions WHERE token = $1', [msg.token]);
            const row = session.rows[0];
            if (!row) {
              sendTo(ws, { type: 'craft_card_result', success: false, message: 'Session expired.' });
              return;
            }
            const playerResult = await pool.query('SELECT dust FROM players WHERE id = $1', [row.player_id]);
            const dust = playerResult.rows[0].dust;
            if (dust < cost) {
              sendTo(ws, { type: 'craft_card_result', success: false, message: 'Not enough dust to craft this card.', dust_needed: cost - dust });
              return;
            }
            const newDust = dust - cost;
            await pool.query('UPDATE players SET dust = $1 WHERE id = $2', [newDust, row.player_id]);
            await pool.query(
              `INSERT INTO owned_cards (player_id, card_id, quantity) VALUES ($1, $2, 1)
               ON CONFLICT (player_id, card_id) DO UPDATE SET quantity = owned_cards.quantity + 1`,
              [row.player_id, msg.card_id]
            );
            sendTo(ws, { type: 'craft_card_result', success: true, dust: newDust, card_id: msg.card_id });
          } catch (err) {
            console.error('craft_card error', err);
            sendTo(ws, { type: 'craft_card_result', success: false, message: 'Server error, try again.' });
          }
          break;
        }

        case 'claim_earn_reward': {
          // Server decides eligibility and amount - the client only signals
          // that a condition (e.g. first match of the day) just happened,
          // per contracts/shop-protocol.md.
          const EARN_AMOUNTS = { daily_first_win: 50, ranked_milestone: 75, campaign_milestone: 100 };
          const amount = EARN_AMOUNTS[msg.reason];
          if (!amount) {
            sendTo(ws, { type: 'claim_earn_reward_result', success: false, message: 'Unknown reward reason.' });
            return;
          }
          try {
            const session = await pool.query('SELECT player_id FROM sessions WHERE token = $1', [msg.token]);
            const row = session.rows[0];
            if (!row) {
              sendTo(ws, { type: 'claim_earn_reward_result', success: false, message: 'Session expired.' });
              return;
            }
            if (msg.reason === 'daily_first_win') {
              // Glimmer (dust) is the wins/dailies currency - see Cyllats
              // below for the milestone-reward, premium-currency case.
              const player = await pool.query('SELECT currency, dust, last_daily_reward_at FROM players WHERE id = $1', [row.player_id]);
              const today = new Date().toISOString().slice(0, 10);
              const lastReward = player.rows[0].last_daily_reward_at
                ? new Date(player.rows[0].last_daily_reward_at).toISOString().slice(0, 10) : null;
              if (lastReward === today) {
                sendTo(ws, { type: 'claim_earn_reward_result', success: false, message: 'Daily reward already claimed today.', reason: msg.reason });
                return;
              }
              const newDust = player.rows[0].dust + amount;
              await pool.query('UPDATE players SET dust = $1, last_daily_reward_at = $2 WHERE id = $3', [newDust, today, row.player_id]);
              sendTo(ws, {
                type: 'claim_earn_reward_result', success: true,
                currency: player.rows[0].currency, dust: newDust, amount_awarded: amount, reason: msg.reason,
              });
            } else {
              // ranked_milestone / campaign_milestone still grant Cyllats.
              const player = await pool.query('SELECT currency, dust FROM players WHERE id = $1', [row.player_id]);
              const newCurrency = player.rows[0].currency + amount;
              await pool.query('UPDATE players SET currency = $1 WHERE id = $2', [newCurrency, row.player_id]);
              sendTo(ws, {
                type: 'claim_earn_reward_result', success: true,
                currency: newCurrency, dust: player.rows[0].dust, amount_awarded: amount, reason: msg.reason,
              });
            }
          } catch (err) {
            console.error('claim_earn_reward error', err);
            sendTo(ws, { type: 'claim_earn_reward_result', success: false, message: 'Server error, try again.' });
          }
          break;
        }

        case 'report_ranked_result': {
          const token = msg.token;
          const won = !!msg.won;
          // Present and non-negative only for a matchmade PvP result — the
          // opponent's rating at the time the match was found (see
          // ranked_match_found), used to move this player's own Elo. Absent
          // for AI ranked matches, which don't touch rating at all.
          const opponentRating = Number.isFinite(msg.opponent_rating) && msg.opponent_rating >= 0
            ? msg.opponent_rating : null;
          try {
            const result = await pool.query(
              `SELECT p.id, p.rating, p.rank_bracket, p.rank_in_legend, p.rank_legend_rating, p.rank_lp,
                      p.ranked_win_streak, p.ranked_wins, p.ranked_losses
               FROM sessions s JOIN players p ON p.id = s.player_id WHERE s.token = $1`,
              [token]
            );
            const player = result.rows[0];
            if (!player) {
              sendTo(ws, { type: 'ranked_result_ack', success: false, message: 'Session expired.' });
              return;
            }
            const next = nextRankState(player, won);
            next.rating = opponentRating !== null ? nextElo(player.rating, opponentRating, won) : player.rating;
            await pool.query(
              `UPDATE players
               SET rank_bracket = $1, rank_in_legend = $2, rank_legend_rating = $3, rank_lp = $4,
                   ranked_win_streak = $5, ranked_wins = $6, ranked_losses = $7, rating = $8
               WHERE id = $9`,
              [next.rank_bracket, next.rank_in_legend, next.rank_legend_rating, next.rank_lp,
               next.ranked_win_streak, next.ranked_wins, next.ranked_losses, next.rating, player.id]
            );
            sendTo(ws, { type: 'ranked_result_ack', success: true, ...next });
          } catch (err) {
            console.error('report_ranked_result error', err);
            sendTo(ws, { type: 'ranked_result_ack', success: false, message: 'Server error, try again.' });
          }
          break;
        }

        case 'logout': {
          try {
            await pool.query('DELETE FROM sessions WHERE token = $1', [msg.token]);
          } catch (err) {
            console.error('logout error', err);
          }
          sendTo(ws, { type: 'logged_out' });
          break;
        }

        case 'queue_ranked': {
          try {
            const result = await pool.query(
              `SELECT p.username, p.rating
               FROM sessions s JOIN players p ON p.id = s.player_id WHERE s.token = $1`,
              [msg.token]
            );
            const player = result.rows[0];
            if (!player) {
              sendTo(ws, { type: 'error', message: 'Session expired.' });
              return;
            }
            rankedQueue.set(ws, { username: player.username, rating: player.rating, queuedAt: Date.now() });
            sweepRankedQueue();
          } catch (err) {
            console.error('queue_ranked error', err);
          }
          break;
        }

        case 'cancel_ranked_queue': {
          rankedQueue.delete(ws);
          break;
        }

        case 'queue_campaign': {
          try {
            const result = await pool.query(
              `SELECT p.username
               FROM sessions s JOIN players p ON p.id = s.player_id WHERE s.token = $1`,
              [msg.token]
            );
            const player = result.rows[0];
            if (!player) {
              sendTo(ws, { type: 'error', message: 'Session expired.' });
              return;
            }
            campaignQueue.set(ws, { username: player.username, size: msg.size, queuedAt: Date.now() });
            sweepCampaignQueue();
          } catch (err) {
            console.error('queue_campaign error', err);
          }
          break;
        }

        case 'cancel_campaign_queue': {
          campaignQueue.delete(ws);
          break;
        }

        case 'create_lobby': {
          const id = Math.random().toString(36).slice(2, 8).toUpperCase();
          const lobby = {
            id,
            name: msg.name || (msg.host_name + "'s Lobby"),
            host_ws: ws,
            guest_ws: null,
            host_name: msg.host_name || 'Host',
            guest_name: '',
            status: 'waiting',
          };
          lobbies.set(id, lobby);
          clients.set(ws, { lobby_id: id, role: 'host' });
          sendTo(ws, { type: 'lobby_created', lobby_id: id });
          break;
        }

        case 'list_lobbies': {
          sendTo(ws, { type: 'lobby_list', lobbies: lobbyList() });
          break;
        }

        case 'join_lobby': {
          const lobby = lobbies.get(msg.lobby_id);
          if (!lobby || lobby.status !== 'waiting') {
            sendTo(ws, { type: 'error', message: 'Lobby not found or already full.' });
            return;
          }
          lobby.guest_ws = ws;
          lobby.guest_name = msg.guest_name || 'Guest';
          lobby.status = 'full';
          clients.set(ws, { lobby_id: lobby.id, role: 'guest' });
          sendTo(ws, { type: 'joined_lobby', lobby_id: lobby.id, host_name: lobby.host_name });
          sendTo(lobby.host_ws, { type: 'player_joined', guest_name: lobby.guest_name });
          break;
        }

        case 'relay': {
          const info = clients.get(ws);
          if (!info) return;
          const lobby = lobbies.get(info.lobby_id);
          if (!lobby) return;
          const target_ws = info.role === 'host' ? lobby.guest_ws : lobby.host_ws;
          sendTo(target_ws, { type: 'relay', payload: msg.payload, from_role: info.role });
          break;
        }

        case 'leave_lobby': {
          _handleDisconnect(ws);
          break;
        }
      }
    });

    ws.on('close', () => _handleDisconnect(ws));
  });

  // Ping every 30s to keep connections alive through Railway's proxy.
  // Terminates any client that didn't respond to the last ping (dead connection).
  setInterval(() => {
    wss.clients.forEach((ws) => {
      if (ws.isAlive === false) { ws.terminate(); return; }
      ws.isAlive = false;
      ws.ping();
    });
  }, 30000);

  setInterval(sweepRankedQueue, RANKED_SWEEP_MS);
  setInterval(sweepCampaignQueue, CAMPAIGN_SWEEP_MS);

  console.log('Relay server listening on port', PORT);
}

function _handleDisconnect(ws) {
  rankedQueue.delete(ws);
  campaignQueue.delete(ws);
  const info = clients.get(ws);
  if (!info) return;
  const lobby = lobbies.get(info.lobby_id);
  if (lobby) {
    const other_ws = info.role === 'host' ? lobby.guest_ws : lobby.host_ws;
    sendTo(other_ws, { type: 'opponent_left' });
    lobbies.delete(lobby.id);
  }
  clients.delete(ws);
}

main().catch((err) => {
  console.error('Failed to start relay server', err);
  process.exit(1);
});
