'use strict';
const { createHash } = require('node:crypto');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { MAX_DECK_SIZE, maxCopiesFor } = require('./authoritative/decks');
const { SETTLING_REASONS } = require('./authoritative/settle');

const DECK_STATS_PATH = '/data/stats/deck-matchups.json';
const MAX_MATCHES = 50000;
const MAX_BYTES = 4 * 1024 * 1024;
const VERSION = value => value === 'unknown' || (Number.isInteger(value) && value > 0 && value <= 1000000);

function parseQuery(search) {
  const params = new URLSearchParams(search);
  const allowed = new Set(['mode', 'days', 'rulesVersion', 'aiVersion', 'aiLevel']);
  for (const key of params.keys()) {
    if (!allowed.has(key) || params.getAll(key).length !== 1) throw new Error('invalid query');
  }
  const mode = params.get('mode') ?? 'ranked_ai';
  if (!['ranked_ai', 'authoritative_pvp'].includes(mode)) throw new Error('invalid mode');
  function integer(key, fallback, max) {
    const raw = params.get(key) ?? String(fallback);
    if (!/^[1-9]\d*$/.test(raw) || Number(raw) > max) throw new Error('invalid integer');
    return Number(raw);
  }
  function version(key) {
    const raw = params.get(key) ?? 'latest';
    return ['unknown', 'latest'].includes(raw) ? raw : integer(key, 1, 1000000);
  }
  if (mode === 'authoritative_pvp' && (params.has('aiVersion') || params.has('aiLevel'))) throw new Error('irrelevant filter');
  return { mode, days: integer('days', 30, 365), rulesVersion: version('rulesVersion'),
    aiVersion: mode === 'ranked_ai' ? version('aiVersion') : null,
    aiLevel: mode === 'ranked_ai' ? integer('aiLevel', 10, 10) : null };
}

function deckOf(ids, catalog) {
  if (!Array.isArray(ids) || ids.length < 1 || ids.length > MAX_DECK_SIZE) return null;
  const copies = new Map();
  for (const id of ids) {
    const card = catalog.get(id);
    if (typeof id !== 'string' || !card) return null;
    copies.set(id, (copies.get(id) ?? 0) + 1);
    if (copies.get(id) > maxCopiesFor(card)) return null;
  }
  const pairs = [...copies].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
  const factions = [...new Set(ids.map(id => catalog.get(id).color).filter(c => c !== 'GENERIC'))].sort();
  return { id: createHash('sha256').update(JSON.stringify(pairs)).digest('hex'),
    cards: pairs.map(([id, copies]) => ({ id, copies })), factions: factions.length ? factions : ['GENERIC'] };
}

function versions(rows, key) {
  return [...new Set(rows.map(r => r[key]))].sort((a, b) => a === 'unknown' ? 1 : b === 'unknown' ? -1 : a - b);
}
function latest(values) {
  const known = values.filter(v => v !== 'unknown');
  return known.length ? Math.max(...known) : 'unknown';
}

function resolveCohort(rows, query) {
  const aiLevels = [...new Set(rows.map(r => r.aiLevel).filter(Number.isInteger))].sort((a, b) => a - b);
  let candidates = rows.filter(r => query.aiLevel === null || r.aiLevel === query.aiLevel);
  const ruleChoices = versions(candidates.filter(r => query.aiVersion === null || query.aiVersion === 'latest' || r.aiVersion === query.aiVersion), 'rulesVersion');
  if (query.rulesVersion !== 'latest') candidates = candidates.filter(r => r.rulesVersion === query.rulesVersion);
  if (query.aiVersion !== null && query.aiVersion !== 'latest') candidates = candidates.filter(r => r.aiVersion === query.aiVersion);
  const rulesVersion = query.rulesVersion === 'latest' ? latest(versions(candidates, 'rulesVersion')) : query.rulesVersion;
  const aiChoices = query.aiVersion === null ? [] : versions(rows.filter(r => r.aiLevel === query.aiLevel && r.rulesVersion === rulesVersion), 'aiVersion');
  candidates = candidates.filter(r => r.rulesVersion === rulesVersion);
  const aiVersion = query.aiVersion === 'latest' ? latest(versions(candidates, 'aiVersion')) : query.aiVersion;
  if (aiVersion !== null) candidates = candidates.filter(r => r.aiVersion === aiVersion);
  return { rows: candidates, filters: { ...query, rulesVersion, aiVersion },
    availableFilters: { rulesVersions: ruleChoices, aiVersions: aiChoices, aiLevels } };
}

function bucket() {
  return { matches: 0, wins: 0, people: new Set(), turns: 0, turnSamples: 0,
    first: { matches: 0, wins: 0 }, second: { matches: 0, wins: 0 }, unknownFirst: { matches: 0, wins: 0 } };
}
function add(target, won, people, turns, first) {
  target.matches++; target.wins += Number(won);
  for (const person of people) target.people.add(person);
  if (Number.isInteger(turns) && turns > 0 && turns <= 1000000) { target.turns += turns; target.turnSamples++; }
  const split = target[first === null ? 'unknownFirst' : first ? 'first' : 'second'];
  split.matches++; split.wins += Number(won);
}
function record({ matches, wins }) {
  return { matches, wins, losses: matches - wins, winRate: matches ? wins / matches : null };
}
function finish(value) {
  const base = record(value);
  const n = value.matches, p = base.winRate, z = 1.96, z2 = z * z;
  const centre = (p + z2 / (2 * n)) / (1 + z2 / n);
  const margin = z * Math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / (1 + z2 / n);
  return { ...base, winRateInterval: { lower: Math.max(0, centre - margin), upper: Math.min(1, centre + margin) },
    testers: value.people.size, averageTurns: value.turnSamples ? value.turns / value.turnSamples : null,
    turnSamples: value.turnSamples, first: record(value.first), second: record(value.second), unknownFirst: record(value.unknownFirst) };
}

function aggregate(rows, filters, availableFilters, now) {
  const decks = new Map(), matchups = new Map();
  for (const row of rows) {
    for (const side of [0, 1]) {
      const deck = row.decks[side], opponent = row.decks[1 - side];
      const role = filters.mode === 'ranked_ai' && side === 1 ? 'ai' : 'human';
      const opponentRole = filters.mode === 'ranked_ai' && side === 0 ? 'ai' : 'human';
      const key = `${deck.id}/${role}`, pair = `${key}/${opponent.id}/${opponentRole}`;
      if (!decks.has(key)) decks.set(key, { deck, role, value: bucket() });
      if (!matchups.has(pair)) matchups.set(pair, { deckId: deck.id, opponentDeckId: opponent.id, role, opponentRole, value: bucket() });
      const won = side === 0 ? row.won : !row.won;
      const first = row.first === null ? null : row.first === side;
      add(decks.get(key).value, won, row.people, row.turns, first);
      add(matchups.get(pair).value, won, row.people, row.turns, first);
    }
  }
  return { generatedAt: new Date(now).toISOString(), filters, availableFilters,
    methodology: { metric: 'exact_starting_deck_matchup', unit: 'seat_game', rolesSeparated: true,
      source: filters.mode === 'ranked_ai' ? 'client_reported' : 'server_verified',
      minSample: 1, preliminary: true, interval: 'Wilson 95%; repeated testers are not independent samples',
      testers: 'Distinct human participants involved, including opponents; never AI accounts',
      privacy: 'Public exact deck lists and small-sample aggregates can permit inference. No identities or individual match histories.' },
    games: rows.length,
    decks: [...decks].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([, row]) => ({ ...row.deck, role: row.role, ...finish(row.value) })),
    matchups: [...matchups].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([, { value, ...row }]) => ({ ...row, ...finish(value) })) };
}

async function loadRows(pool, publicRoot, query, now) {
  const release = JSON.parse(readFileSync(path.join(publicRoot, 'data/cards.json'), 'utf8'));
  if (!Array.isArray(release.cards)) throw new Error('invalid catalog');
  const catalog = new Map(release.cards.filter(c => c.collectible === true && c.isToken === false).map(c => [c.id, c]));
  if (!catalog.size) throw new Error('invalid catalog');
  const since = new Date(now - query.days * 86400000).toISOString();
  let raw;
  if (query.mode === 'ranked_ai') {
    raw = (await pool.query({ text: `SELECT player_id, won, ai_match FROM ranked_settlements
      WHERE settled_at >= $1 AND settled_at <= $2 AND ai_match->>'mode' = 'ranked_ai'
      AND ai_match->>'source' = 'client_reported' LIMIT $3`,
      values: [since, new Date(now).toISOString(), MAX_MATCHES + 1], query_timeout: 5000 })).rows;
  } else {
    const available = await pool.query("SELECT to_regclass('ranked_matches') IS NOT NULL AS available");
    if (!available.rows[0].available) return [];
    raw = (await pool.query({ text: `SELECT m.deck_a, m.deck_b, m.rules_version, m.first_seat, m.facts,
      m.seat_a_player_id, m.seat_b_player_id, m.winner_seat, sa.won AS a_won, sb.won AS b_won
      FROM ranked_matches m
      JOIN ranked_settlements sa ON sa.match_id = m.match_id AND sa.player_id = m.seat_a_player_id AND sa.ai_match IS NULL
      JOIN ranked_settlements sb ON sb.match_id = m.match_id AND sb.player_id = m.seat_b_player_id AND sb.ai_match IS NULL
      WHERE m.ended_at >= $1 AND m.ended_at <= $2 AND m.mode = 'authoritative' AND m.status = 'finished'
      AND m.winner_seat IN ('a','b') AND m.end_reason = ANY($3::text[]) LIMIT $4`,
      values: [since, new Date(now).toISOString(), [...SETTLING_REASONS], MAX_MATCHES + 1], query_timeout: 5000 })).rows;
  }
  if (raw.length > MAX_MATCHES) throw new Error('too many matches');
  const rows = [];
  for (const row of raw) {
    const ai = query.mode === 'ranked_ai' ? row.ai_match : null;
    const a = deckOf(ai ? ai.player_deck : row.deck_a, catalog), b = deckOf(ai ? ai.opponent_deck : row.deck_b, catalog);
    if (!a || !b) continue;
    const rulesVersion = (ai ? ai.rules_version : row.rules_version) ?? 'unknown';
    const aiVersion = ai ? (ai.ai_version ?? 'unknown') : null;
    if (!VERSION(rulesVersion) || (ai && (!VERSION(aiVersion) || !Number.isInteger(ai.ai_level) || ai.ai_level < 1 || ai.ai_level > 10))) continue;
    if (ai && ai.first_player !== undefined && !['player', 'opponent'].includes(ai.first_player)) continue;
    if (!ai && (row.a_won !== (row.winner_seat === 'a') || row.b_won !== (row.winner_seat === 'b'))) continue;
    rows.push({ decks: [a, b], rulesVersion, aiVersion, aiLevel: ai ? ai.ai_level : null,
      won: ai ? row.won : row.a_won, people: ai ? [row.player_id] : [row.seat_a_player_id, row.seat_b_player_id],
      first: ai ? (ai.first_player === undefined ? null : ai.first_player === 'player' ? 0 : 1) : row.first_seat === 'a' ? 0 : row.first_seat === 'b' ? 1 : null,
      turns: ai ? ai.turns : row.facts?.turns });
  }
  return rows;
}

function createDeckMatchups({ pool, publicRoot, now = Date.now }) {
  const cache = new Map();
  return function snapshot(query) {
    const key = JSON.stringify(query), time = now(), current = cache.get(key);
    if (current && (current.pending || time < current.expires)) return current.promise;
    cache.delete(key);
    if (cache.size >= 64) {
      const victim = [...cache].find(([, entry]) => !entry.pending);
      if (!victim) return Promise.reject(new Error('busy'));
      cache.delete(victim[0]);
    }
    const entry = { pending: true, expires: 0 };
    entry.promise = loadRows(pool, publicRoot, query, time).then(rows => {
      const cohort = resolveCohort(rows, query);
      const result = aggregate(cohort.rows, cohort.filters, cohort.availableFilters, time);
      if (Buffer.byteLength(JSON.stringify(result)) > MAX_BYTES) throw new Error('too large');
      entry.pending = false; entry.expires = now() + 60000;
      return result;
    }).catch(error => { cache.delete(key); throw error; });
    cache.set(key, entry);
    return entry.promise;
  };
}

module.exports = { DECK_STATS_PATH, MAX_BYTES, parseQuery, createDeckMatchups };
