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
  await pool.query(`
    CREATE TABLE IF NOT EXISTS sessions (
      token TEXT PRIMARY KEY,
      player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);
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
  return { username: row.username, wins: row.wins, losses: row.losses, rating: row.rating };
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
              'INSERT INTO players (username, password_hash, salt) VALUES ($1, $2, $3) RETURNING username, wins, losses, rating',
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
              `SELECT p.username, p.wins, p.losses, p.rating FROM sessions s
               JOIN players p ON p.id = s.player_id WHERE s.token = $1`,
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

        case 'logout': {
          try {
            await pool.query('DELETE FROM sessions WHERE token = $1', [msg.token]);
          } catch (err) {
            console.error('logout error', err);
          }
          sendTo(ws, { type: 'logged_out' });
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

  console.log('Relay server listening on port', PORT);
}

function _handleDisconnect(ws) {
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
