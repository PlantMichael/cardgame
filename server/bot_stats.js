'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { deckOf } = require('./deck_matchups');
const { normalizeBotMatch, normalizeBotParticipant } = require('./bot_matches');
const { SETTLING_REASONS } = require('./authoritative/settle');
const BOT_STATS_PATH = '/data/stats/bot-matchups.json';
const MAX_BYTES = 16 * 1024 * 1024;

function botQuery(search) {
  const p = new URLSearchParams(search);
  for (const key of p.keys()) if (!['days', 'mode'].includes(key) || p.getAll(key).length !== 1) throw new Error('invalid query');
  const value = p.get('days') ?? '30';
  if (!/^[1-9]\d*$/.test(value) || Number(value) > 365) throw new Error('invalid days');
  const mode = p.get('mode') ?? 'simulation';
  if (!['simulation', 'ranked'].includes(mode)) throw new Error('invalid mode');
  return { days: Number(value), mode };
}
const identity = (p, r) => `${p.id}@${p.version}/L${p.level}/R${r.rulesVersion}/E${r.engineVersion}`;
const bucket = () => ({ matches: 0, wins: 0, losses: 0, draws: 0, totalTurns: 0, first: { matches: 0, wins: 0 }, second: { matches: 0, wins: 0 } });
function add(v, outcome, turns, first) {
  v.matches++; v[outcome]++; v.totalTurns += turns;
  v[first ? 'first' : 'second'].matches++;
  v[first ? 'first' : 'second'].wins += Number(outcome === 'wins');
}
function finish(v) {
  const { totalTurns, ...stats } = v;
  return { ...stats, winRate: v.wins + v.losses ? v.wins / (v.wins + v.losses) : null, averageTurns: totalTurns / v.matches };
}

async function load(pool, publicRoot, { days, mode }, now) {
  const release = JSON.parse(fs.readFileSync(path.join(publicRoot, 'data/cards.json'), 'utf8'));
  const catalog = new Map(release.cards.filter(c => c.collectible === true && c.isToken === false).map(c => [c.id, c]));
  const table = mode === 'ranked' ? 'ranked_matches' : 'bot_matches';
  const available = await pool.query('SELECT to_regclass($1) IS NOT NULL AS available', [table]);
  const since = new Date(now - days * 86400000), until = new Date(now);
  let raw = [];
  if (available.rows[0].available) {
    raw = mode === 'simulation' ? (await pool.query({ text: `SELECT result FROM bot_matches
      WHERE ended_at >= $1 AND ended_at <= $2 LIMIT 50001`, values: [since, until], query_timeout: 5000 })).rows
      : (await pool.query({ text: `SELECT m.deck_a,m.deck_b,m.bot_a,m.bot_b,m.engine_version,m.rules_version,m.winner_seat,m.first_seat,m.facts
        FROM ranked_matches m
        JOIN ranked_settlements sa ON sa.match_id=m.match_id AND sa.player_id=m.seat_a_player_id AND sa.ai_match IS NULL
        JOIN ranked_settlements sb ON sb.match_id=m.match_id AND sb.player_id=m.seat_b_player_id AND sb.ai_match IS NULL
        WHERE m.mode='ranked_bots' AND m.status='finished' AND m.ended_at >= $1 AND m.ended_at <= $2
        AND m.winner_seat IN ('a','b') AND m.end_reason=ANY($3::text[])
        AND sa.won=(m.winner_seat='a') AND sb.won=(m.winner_seat='b')
        AND (m.bot_a IS NOT NULL OR m.bot_b IS NOT NULL) LIMIT 50001`,
      values: [since, until, [...SETTLING_REASONS]], query_timeout: 5000 })).rows;
  }
  if (mode === 'ranked') {
    const local = (await pool.query({ text: `SELECT won,ai_match FROM ranked_settlements
      WHERE settled_at >= $1 AND settled_at <= $2 AND ai_match->>'mode'='ranked_ai'
      AND ai_match->>'source'='client_reported' AND ai_match->'bot_profile' IS NOT NULL LIMIT 50001`,
      values: [since, until], query_timeout: 5000 })).rows;
    raw.push(...local);
  }
  if (raw.length > 50000) throw new Error('too many matches');
  const bots = new Map(), decks = new Map(), matchups = new Map();
  let games = 0, localGames = 0;
  for (const row of raw) {
    let r;
    if (mode === 'simulation') r = normalizeBotMatch(row.result, { historical: true });
    else if (row.ai_match) {
      const ai = row.ai_match;
      if (!Number.isInteger(ai.ai_version) || ai.ai_version < 1 || ai.ai_version > 1000000 ||
          !Number.isInteger(ai.ai_level) || ai.ai_level < 3 || ai.ai_level > 10 ||
          !Number.isInteger(ai.rules_version) || ai.rules_version < 1 || ai.rules_version > 1000000 ||
          !Number.isInteger(ai.turns) || ai.turns < 1 || ai.turns > 1000000 || !['player','opponent'].includes(ai.first_player)) continue;
      r = { a: normalizeBotParticipant(ai.bot_profile, ai.ai_version, true),
        b: { id: 'standard', name: 'Standard AI', version: String(ai.ai_version), level: ai.ai_level, style: '' },
        deckA: ai.player_deck, deckB: ai.opponent_deck, winner: row.won ? 'a' : 'b',
        first: ai.first_player === 'player' ? 'a' : 'b', turns: ai.turns,
        rulesVersion: ai.rules_version, engineVersion: ai.ai_version };
      if (r.a.id === 'standard') throw new Error('invalid named bot');
    } else {
      if (!Number.isInteger(row.rules_version) || row.rules_version < 1 || row.rules_version > 1000000 ||
          !Number.isInteger(row.engine_version) || row.engine_version < 1 || row.engine_version > 1000000 ||
          !Number.isInteger(row.facts?.turns) || row.facts.turns < 1 || row.facts.turns > 1000000 || !['a', 'b'].includes(row.first_seat)) continue;
      const participant = p => p ? normalizeBotParticipant(p, row.engine_version, true)
        : { id: 'human', name: 'Human players', version: 'unversioned', level: null, style: 'human' };
      r = { a: participant(row.bot_a), b: participant(row.bot_b), deckA: row.deck_a, deckB: row.deck_b,
        winner: row.winner_seat, first: row.first_seat, turns: row.facts.turns,
        rulesVersion: row.rules_version, engineVersion: row.engine_version };
      if ([r.a, r.b].some(p => p.id === 'standard')) throw new Error('invalid ranked identity');
    }
    const compositions = [deckOf(r.deckA, catalog), deckOf(r.deckB, catalog)];
    if (compositions.some(c => !c)) {
      if (mode === 'ranked') continue; // An ordinary human may use unpublished cards; never expose a partial deck.
      throw new Error('unpublished result');
    }
    games++;
    if (row.ai_match) localGames++;
    const participants = [r.a, r.b].map(p => ({ ...p, key: identity(p, r), rulesVersion: r.rulesVersion, engineVersion: r.engineVersion }));
    for (const side of [0, 1]) {
      const bot = participants[side], enemy = participants[1 - side];
      const composition = compositions[side];
      const key = `${bot.key}/${composition.id}`, opponentKey = `${enemy.key}/${compositions[1 - side].id}`;
      const pair = `${key}|${opponentKey}`;
      if (!bots.has(bot.key)) bots.set(bot.key, { ...bot, value: bucket() });
      if (!decks.has(key)) decks.set(key, { ...composition, key, botKey: bot.key, value: bucket() });
      if (!matchups.has(pair)) matchups.set(pair, { deckKey: key, opponentDeckKey: opponentKey, value: bucket() });
      const seat = side === 0 ? 'a' : 'b';
      const outcome = r.winner === 'draw' ? 'draws' : r.winner === seat ? 'wins' : 'losses';
      for (const v of [bots.get(bot.key), decks.get(key), matchups.get(pair)]) add(v.value, outcome, r.turns, r.first === seat);
    }
  }
  const project = map => [...map].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([, { value, ...row }]) => ({ ...row, ...finish(value) }));
  const result = { generatedAt: new Date(now).toISOString(), days, mode, games,
    methodology: { source: mode === 'ranked' ? localGames ? 'mixed' : 'server_verified' : 'bot_simulation', metric: 'exact_starting_deck_matchup', unit: 'seat_game', draws: 'excluded_from_win_rate', humanStats: 'excluded' },
    bots: project(bots), decks: project(decks), matchups: project(matchups) };
  if (Buffer.byteLength(JSON.stringify(result)) > MAX_BYTES) throw new Error('too large');
  return result;
}

function createBotStats({ pool, publicRoot, now = Date.now }) {
  const cache = new Map();
  return query => {
    const key = JSON.stringify(query), time = now(), current = cache.get(key);
    if (current && (current.pending || time < current.expires)) return current.promise;
    cache.delete(key);
    if (cache.size >= 32) {
      const victim = [...cache].find(([, e]) => !e.pending);
      if (!victim) return Promise.reject(new Error('busy'));
      cache.delete(victim[0]);
    }
    const entry = { pending: true, expires: 0 };
    entry.promise = load(pool, publicRoot, query, time).then(r => {
      entry.pending = false; entry.expires = now() + 60000; return r;
    }).catch(e => { cache.delete(key); throw e; });
    cache.set(key, entry);
    return entry.promise;
  };
}
module.exports = { BOT_STATS_PATH, MAX_BYTES, botQuery, createBotStats };
