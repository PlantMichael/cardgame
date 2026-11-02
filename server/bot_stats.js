'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { deckOf } = require('./deck_matchups');
const { normalizeBotMatch } = require('./bot_matches');
const BOT_STATS_PATH = '/data/stats/bot-matchups.json';
const MAX_BYTES = 4 * 1024 * 1024;

function botQuery(search) {
  const p = new URLSearchParams(search);
  for (const key of p.keys()) if (key !== 'days' || p.getAll(key).length !== 1) throw new Error('invalid query');
  const value = p.get('days') ?? '30';
  if (!/^[1-9]\d*$/.test(value) || Number(value) > 365) throw new Error('invalid days');
  return Number(value);
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

async function load(pool, publicRoot, days, now) {
  const release = JSON.parse(fs.readFileSync(path.join(publicRoot, 'data/cards.json'), 'utf8'));
  const catalog = new Map(release.cards.filter(c => c.collectible === true && c.isToken === false).map(c => [c.id, c]));
  const available = await pool.query("SELECT to_regclass('bot_matches') IS NOT NULL AS available");
  const raw = available.rows[0].available ? (await pool.query({ text: `SELECT result FROM bot_matches
    WHERE ended_at >= $1 AND ended_at <= $2 LIMIT 50001`, values: [new Date(now - days * 86400000), new Date(now)], query_timeout: 5000 })).rows : [];
  if (raw.length > 50000) throw new Error('too many matches');
  const bots = new Map(), decks = new Map(), matchups = new Map();
  let games = 0;
  for (const row of raw) {
    const r = normalizeBotMatch(row.result, { historical: true });
    const compositions = [deckOf(r.deckA, catalog), deckOf(r.deckB, catalog)];
    if (compositions.some(c => !c)) throw new Error('unpublished result');
    games++;
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
  const result = { generatedAt: new Date(now).toISOString(), days, games,
    methodology: { source: 'bot_simulation', metric: 'exact_starting_deck_matchup', unit: 'seat_game', draws: 'excluded_from_win_rate', humanStats: 'excluded' },
    bots: project(bots), decks: project(decks), matchups: project(matchups) };
  if (Buffer.byteLength(JSON.stringify(result)) > MAX_BYTES) throw new Error('too large');
  return result;
}

function createBotStats({ pool, publicRoot, now = Date.now }) {
  const cache = new Map();
  return days => {
    const time = now(), current = cache.get(days);
    if (current && (current.pending || time < current.expires)) return current.promise;
    cache.delete(days);
    if (cache.size >= 32) {
      const victim = [...cache].find(([, e]) => !e.pending);
      if (!victim) return Promise.reject(new Error('busy'));
      cache.delete(victim[0]);
    }
    const entry = { pending: true, expires: 0 };
    entry.promise = load(pool, publicRoot, days, time).then(r => {
      entry.pending = false; entry.expires = now() + 60000; return r;
    }).catch(e => { cache.delete(days); throw e; });
    cache.set(days, entry);
    return entry.promise;
  };
}
module.exports = { BOT_STATS_PATH, MAX_BYTES, botQuery, createBotStats };
