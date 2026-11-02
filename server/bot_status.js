'use strict';
const { profiles } = require('./bot_matches');
const BOT_STATUS_PATH = '/data/bots/status.json';
const ACTIVITIES = new Set(['queued', 'joining', 'playing', 'idle', 'reconnecting', 'offline']);

// Only authenticated relay paths can bind a socket. Tickets prevent an older
// async lookup from resurrecting a closed socket or replacing a newer identity.
function createBotPresence({ queue, manager = () => null }) {
  const sockets = new Map(), tickets = new WeakMap();
  function begin(ws) {
    const ticket = (tickets.get(ws) || 0) + 1;
    tickets.set(ws, ticket); return ticket;
  }
  function remember(ws, playerId, ticket) {
    if (ws.readyState === 1 && Number.isInteger(ticket) && tickets.get(ws) === ticket) sockets.set(ws, playerId);
  }
  function reject(ws, ticket) { if (tickets.get(ws) === ticket) sockets.delete(ws); }
  function forget(ws) { begin(ws); sockets.delete(ws); }
  function activity(playerId) {
    if (![...sockets].some(([ws, id]) => id === playerId && ws.readyState === 1)) return 'offline';
    const owner = manager();
    const match = owner?.matchOf(playerId);
    if (match && ['waiting', 'active'].includes(match.status)) {
      const seat = Object.values(match.seats).find(s => s.playerId === playerId);
      if (match.hostDown || owner.host?.ready === false) return 'reconnecting';
      if (match.status === 'waiting' && seat?.epoch === 0) return 'joining';
      if (!seat?.conn || seat.disconnectedAt !== null) return 'reconnecting';
      return match.status === 'waiting' ? 'joining' : 'playing';
    }
    if (owner?.creatingPlayers.has(playerId)) return 'joining';
    if ([...queue].some(([ws, entry]) => entry.playerId === playerId && ws.readyState === 1)) return 'queued';
    return 'idle';
  }
  return { begin, remember, reject, forget, activity };
}

function visibleRank(row) {
  const rank = { bracket: row.rank_bracket, inLegend: row.rank_in_legend,
    legendRating: row.rank_legend_rating, lp: row.rank_lp };
  if (!Number.isInteger(rank.bracket) || rank.bracket < 0 || rank.bracket > 20 ||
      typeof rank.inLegend !== 'boolean' || !Number.isSafeInteger(rank.legendRating) || rank.legendRating < 0 ||
      !Number.isInteger(rank.lp) || rank.lp < 0 || rank.lp >= 100) throw new Error('invalid bot rank');
  return rank;
}

function createBotStatus({ pool, activity = () => 'offline', now = Date.now }) {
  let cached, expires = 0, pending;
  return function snapshot() {
    if (cached && now() < expires) return Promise.resolve(cached);
    if (!pending) pending = pool.query({ text: `SELECT b.bot_id,p.id,p.rank_bracket,p.rank_in_legend,p.rank_legend_rating,p.rank_lp
      FROM ranked_bot_accounts b JOIN players p ON p.id=b.player_id WHERE b.bot_id=ANY($1::text[])`,
      values: [profiles.map(p => p.id)], query_timeout: 5000 }).then(({ rows }) => {
      const byId = new Map(rows.map(row => [row.bot_id, row]));
      const bots = profiles.map(profile => {
        const row = byId.get(profile.id), state = row ? activity(row.id) : 'not_started';
        if (row && !ACTIVITIES.has(state)) throw new Error('invalid bot activity');
        return { id: profile.id, name: profile.name, version: profile.version, level: profile.level, style: profile.style,
          activity: state, rank: row ? visibleRank(row) : null };
      });
      cached = { generatedAt: new Date(now()).toISOString(), bots };
      expires = now() + 5000; return cached;
    }).finally(() => { pending = null; });
    return pending;
  };
}
module.exports = { BOT_STATUS_PATH, createBotPresence, createBotStatus };
