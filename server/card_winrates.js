'use strict';
// Public starting-deck aggregates share the relay's existing database pool.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const WebSocket = require('ws');
const { SETTLING_REASONS } = require('./authoritative/settle');
const { DECK_STATS_PATH, parseQuery, createDeckMatchups } = require('./deck_matchups');

const STATS_PATH = '/data/stats/card-winrates.json';
const PUBLIC_ROOT = path.join(__dirname, '..', 'catalog', 'public');
const METHODOLOGY = {
  metric: 'starting_deck_inclusion', modes: ['ranked_ai', 'authoritative_pvp'],
  aiSeats: 'both', copies: 'once_per_player_game', rulesVersions: 'combined',
  minSample: 1, preliminary: true,
  privacy: 'No raw identities or deck lists. Small sample changes may reveal deck inclusion or outcomes.',
};

// Publication, rather than private card ingestion, owns this allowlist.
function publishedCards(root) {
  const release = JSON.parse(fs.readFileSync(path.join(root, 'data/cards.json'), 'utf8'));
  if (!Array.isArray(release.cards)) throw new Error('invalid catalog');
  const ids = release.cards.filter(c => c.collectible === true && c.isToken === false).map(c => c.id);
  if (!ids.length || ids.some(id => typeof id !== 'string') || new Set(ids).size !== ids.length) throw new Error('invalid catalog');
  return { ids };
}

async function aggregate(pool, root, now) {
  const { ids } = publishedCards(root);
  const { rows: availability } = await pool.query("SELECT to_regclass('ranked_matches') IS NOT NULL AS available");
  const pvp = availability[0].available ? `UNION ALL
    SELECT s.match_id, s.player_id, 'player' AS side, s.won,
      CASE WHEN s.player_id = m.seat_a_player_id THEN m.deck_a
           WHEN s.player_id = m.seat_b_player_id THEN m.deck_b END AS deck
    FROM ranked_settlements s JOIN ranked_matches m USING (match_id)
    WHERE s.ai_match IS NULL AND m.mode = 'authoritative' AND m.status = 'finished'
      AND m.winner_seat IN ('a', 'b') AND m.end_reason = ANY($2::text[])` : '';
  const { rows } = await pool.query(`WITH perspectives AS (
    SELECT s.match_id, s.player_id, seat.side, seat.won, seat.deck
    FROM ranked_settlements s
    CROSS JOIN LATERAL (VALUES
      ('player', s.won, s.ai_match->'player_deck'),
      ('opponent', NOT s.won, s.ai_match->'opponent_deck')
    ) AS seat(side, won, deck)
    WHERE s.ai_match->>'mode' = 'ranked_ai' AND s.ai_match->>'source' = 'client_reported'
    ${pvp}
  ), inclusions AS (
    SELECT DISTINCT match_id, player_id, side, won, card_id
    FROM perspectives CROSS JOIN LATERAL jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(deck) = 'array' THEN deck ELSE '[]'::jsonb END) AS cards(card_id)
    WHERE card_id = ANY($1::text[])
  ) SELECT card_id, COUNT(*) AS matches, COUNT(*) FILTER (WHERE won) AS wins
    FROM inclusions GROUP BY card_id`, availability[0].available ? [ids, [...SETTLING_REASONS]] : [ids]);
  const counts = new Map(rows.map(r => [r.card_id, r]));
  return { generatedAt: new Date(now()).toISOString(), methodology: METHODOLOGY,
    cards: ids.map(id => {
      const matches = Number(counts.get(id)?.matches ?? 0);
      const wins = Number(counts.get(id)?.wins ?? 0);
      if (!Number.isSafeInteger(matches) || !Number.isSafeInteger(wins)) throw new Error('count overflow');
      return { id, matches, wins, losses: matches - wins, winRate: matches ? wins / matches : null };
    }) };
}

// HTTP and websocket upgrades use the same listener and existing relay port.
function createRelayServer({ pool, publicRoot = PUBLIC_ROOT, now = Date.now }) {
  const deckMatchups = createDeckMatchups({ pool, publicRoot, now });
  let cached, expires = 0, refreshing;
  function snapshot() {
    if (cached && now() < expires) return Promise.resolve(cached);
    if (!refreshing) refreshing = aggregate(pool, publicRoot, now).then(value => {
      cached = value; expires = now() + 60000; return value;
    }).finally(() => { refreshing = null; });
    return refreshing;
  }
  const server = http.createServer(async (req, res) => {
    const pathname = (req.url ?? '/').split('?')[0];
    if (pathname !== STATS_PATH && pathname !== DECK_STATS_PATH) {
      res.writeHead(426, { 'Content-Length': 16, 'Content-Type': 'text/plain' });
      res.end('Upgrade Required'); return;
    }
    const send = (status, value, extra = {}) => {
      const body = value === null ? '' : `${JSON.stringify(value)}\n`;
      res.writeHead(status, { 'Access-Control-Allow-Origin': '*', 'X-Content-Type-Options': 'nosniff',
        'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
        ...extra, 'Content-Length': Buffer.byteLength(body) });
      res.end(req.method === 'HEAD' ? undefined : body);
    };
    if (req.method === 'OPTIONS') {
      send(204, null, { 'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS' }); return;
    }
    if (!['GET', 'HEAD'].includes(req.method)) {
      send(405, { error: 'method not allowed' }, { Allow: 'GET, HEAD, OPTIONS' }); return;
    }
    if (pathname === DECK_STATS_PATH) {
      let query;
      try { query = parseQuery((req.url ?? '').split('?').slice(1).join('?')); }
      catch { send(400, { error: 'invalid stats query' }); return; }
      try { send(200, await deckMatchups(query), { 'Cache-Control': 'no-cache' }); }
      catch { send(503, { error: 'deck matchup statistics unavailable' }); }
      return;
    }
    try { send(200, await snapshot(), { 'Cache-Control': 'no-cache' }); }
    catch { send(503, { error: 'card win rates unavailable' }); }
  });
  return { server, wss: new WebSocket.Server({ server }) };
}

module.exports = { createRelayServer, STATS_PATH };
