const WebSocket = require('ws');
const crypto = require('crypto');
const { Pool } = require('pg');
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
  `);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS sessions (
      token TEXT PRIMARY KEY,
      player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);
}

// --- Ranked ladder (mirrors scripts/game/ranked_progress.gd's display math;
// keep BRACKET_COUNT/LP constants in sync with that file) ------------------

const RANK_BRACKET_COUNT = 21; // 7 named tiers x 3 sub-ranks (Orbital III .. Cosmic I)
const RANK_LEGEND_RATING_STEP = 25;
const LEGEND_TIER_SPAN = 1000; // rating span of the Superluminal (lowest legend) band

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
  };
}

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
               RETURNING username, wins, losses, rating,
                         rank_bracket, rank_in_legend, rank_legend_rating, rank_lp, ranked_win_streak,
                         ranked_wins, ranked_losses`,
              [username, hash, salt]
            );
            const player = inserted.rows[0];
            const token = makeToken();
            await pool.query(
              'INSERT INTO sessions (token, player_id) VALUES ($1, (SELECT id FROM players WHERE username = $2))',
              [token, username]
            );
            sendTo(ws, { type: 'register_result', success: true, token, ...profileOf(player) });
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
            sendTo(ws, { type: 'login_result', success: true, token, ...profileOf(player) });
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
              `SELECT p.username, p.wins, p.losses, p.rating,
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
            sendTo(ws, { type: 'login_result', success: true, token, ...profileOf(player) });
          } catch (err) {
            console.error('resume_session error', err);
            sendTo(ws, { type: 'login_result', success: false, message: 'Server error, try again.' });
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

  console.log('Relay server listening on port', PORT);
}

function _handleDisconnect(ws) {
  rankedQueue.delete(ws);
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
