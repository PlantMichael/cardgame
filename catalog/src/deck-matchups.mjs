// The catalog projects a bounded aggregate; it never reads match/player data.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { DEFAULT_ORIGIN } from './card-winrates.mjs';

export const DECK_STATS_PATH = '/data/stats/deck-matchups.json';
const MAX_BYTES = 4 * 1024 * 1024;
const version = v => v === 'unknown' || (Number.isInteger(v) && v > 0 && v <= 1000000);
const count = v => Number.isSafeInteger(v) && v >= 0;
const fail = () => { throw new Error('invalid deck aggregate'); };

// Reject invalid queries locally, even when the upstream is unavailable.
export function deckQuery(search) {
  const params = new URLSearchParams(search);
  const allowed = ['mode', 'days', 'rulesVersion', 'aiVersion', 'aiLevel'];
  for (const [key, value] of params) {
    if (!allowed.includes(key) || params.getAll(key).length !== 1) fail();
    if (key === 'mode') { if (!['ranked_ai', 'authoritative_pvp'].includes(value)) fail(); }
    else if (['rulesVersion', 'aiVersion'].includes(key) && ['latest', 'unknown'].includes(value)) continue;
    else if (!/^[1-9]\d*$/.test(value) || Number(value) > (key === 'days' ? 365 : key === 'aiLevel' ? 10 : 1000000)) fail();
  }
  if (params.get('mode') === 'authoritative_pvp' && (params.has('aiVersion') || params.has('aiLevel'))) fail();
  return params;
}

function result(row) {
  if (!row || !count(row.matches) || !count(row.wins) || !count(row.losses) || row.wins + row.losses !== row.matches) fail();
  return { matches: row.matches, wins: row.wins, losses: row.losses, winRate: row.matches ? row.wins / row.matches : null };
}

function statistics(row) {
  const base = result(row);
  if (!base.matches || !count(row.testers) || !row.testers || row.testers > 2 * base.matches ||
      !count(row.turnSamples) || row.turnSamples > base.matches ||
      (row.turnSamples ? !Number.isFinite(row.averageTurns) || row.averageTurns <= 0 || row.averageTurns > 1000000 : row.averageTurns !== null)) fail();
  const first = result(row.first), second = result(row.second), unknownFirst = result(row.unknownFirst);
  if (first.matches + second.matches + unknownFirst.matches !== base.matches || first.wins + second.wins + unknownFirst.wins !== base.wins) fail();
  const z2 = 1.96 ** 2, n = base.matches, p = base.winRate;
  const centre = (p + z2 / (2 * n)) / (1 + z2 / n);
  const margin = 1.96 * Math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / (1 + z2 / n);
  return { ...base, winRateInterval: { lower: Math.max(0, centre - margin), upper: Math.min(1, centre + margin) },
    testers: row.testers, averageTurns: row.averageTurns, turnSamples: row.turnSamples, first, second, unknownFirst };
}

function composition(row, catalog) {
  if (!Array.isArray(row.cards) || !row.cards.length || row.cards.length > 40) fail();
  const pairs = [], factions = new Set();
  let total = 0, previous = '';
  for (const c of row.cards) {
    const card = catalog.get(c?.id);
    if (!card || typeof c.id !== 'string' || c.id <= previous || !Number.isInteger(c.copies) || c.copies < 1 || c.copies > (card.rarity === 'LEGENDARY' ? 1 : 2)) fail();
    previous = c.id; total += c.copies;
    pairs.push([c.id, c.copies]);
    if (card.color !== 'GENERIC') factions.add(card.color);
  }
  if (total > 40) fail();
  const id = createHash('sha256').update(JSON.stringify(pairs)).digest('hex');
  if (row.id !== id) fail();
  return { id, cards: pairs.map(([id, copies]) => ({ id, copies })), factions: factions.size ? [...factions].sort() : ['GENERIC'] };
}

export function projectDeckMatchups(data, catalog, query) {
  const f = data?.filters, available = data?.availableFilters;
  const mode = query.get('mode') ?? 'ranked_ai';
  if (data?.methodology?.metric !== 'exact_starting_deck_matchup' || data.methodology.rolesSeparated !== true ||
      data.methodology.unit !== 'seat_game' || data.methodology.source !== (mode === 'ranked_ai' ? 'client_reported' : 'server_verified') ||
      typeof data.generatedAt !== 'string' || !Number.isFinite(Date.parse(data.generatedAt)) ||
      !count(data.games) || data.games > 50000 || !Array.isArray(data.decks) || !Array.isArray(data.matchups) ||
      data.decks.length > 100000 || data.matchups.length > 100000 || !f || f.mode !== mode ||
      f.days !== Number(query.get('days') ?? 30) || !version(f.rulesVersion)) fail();
  for (const key of ['rulesVersion', 'aiVersion']) {
    const requested = query.get(key);
    if (requested && requested !== 'latest' && String(f[key]) !== requested) fail();
  }
  if (mode === 'ranked_ai' ? !version(f.aiVersion) || f.aiLevel !== Number(query.get('aiLevel') ?? 10) : f.aiVersion !== null || f.aiLevel !== null) fail();
  for (const key of ['rulesVersions', 'aiVersions', 'aiLevels']) {
    const values = available?.[key];
    if (!Array.isArray(values) || values.length > 50001 || new Set(values).size !== values.length ||
        values.some(v => key === 'aiLevels' ? !Number.isInteger(v) || v < 1 || v > 10 : !version(v))) fail();
    if (mode === 'authoritative_pvp' && key !== 'rulesVersions' && values.length) fail();
  }
  const byKey = new Map();
  const decks = data.decks.map(row => {
    if (!['human', 'ai'].includes(row.role) || (mode === 'authoritative_pvp' && row.role !== 'human')) fail();
    const deck = { ...composition(row, catalog), role: row.role, ...statistics(row) };
    const key = `${deck.id}/${deck.role}`;
    if (byKey.has(key)) fail();
    byKey.set(key, { ...deck, pairMatches: 0, pairWins: 0 });
    return deck;
  });
  const pairs = new Map();
  const matchups = data.matchups.map(row => {
    const own = byKey.get(`${row.deckId}/${row.role}`), enemy = byKey.get(`${row.opponentDeckId}/${row.opponentRole}`);
    if (!own || !enemy || (mode === 'ranked_ai' && row.role === row.opponentRole)) fail();
    const key = `${row.deckId}/${row.role}/${row.opponentDeckId}/${row.opponentRole}`;
    if (pairs.has(key)) fail();
    const stats = statistics(row);
    pairs.set(key, { ...row, ...stats });
    own.pairMatches += stats.matches; own.pairWins += stats.wins;
    return { deckId: row.deckId, opponentDeckId: row.opponentDeckId, role: row.role, opponentRole: row.opponentRole, ...stats };
  });
  if ([...byKey.values()].some(d => d.matches !== d.pairMatches || d.wins !== d.pairWins) ||
      decks.reduce((n, d) => n + d.matches, 0) !== 2 * data.games || decks.reduce((n, d) => n + d.wins, 0) !== data.games) fail();
  for (const row of matchups) {
    const reverse = pairs.get(`${row.opponentDeckId}/${row.opponentRole}/${row.deckId}/${row.role}`);
    if (!reverse || row.matches !== reverse.matches || row.wins !== reverse.losses ||
        row.first.matches !== reverse.second.matches || row.first.wins !== reverse.second.losses ||
        row.unknownFirst.matches !== reverse.unknownFirst.matches || row.unknownFirst.wins !== reverse.unknownFirst.losses) fail();
  }
  return { generatedAt: data.generatedAt,
    filters: { mode, days: f.days, rulesVersion: f.rulesVersion, aiVersion: f.aiVersion, aiLevel: f.aiLevel },
    availableFilters: { rulesVersions: available.rulesVersions, aiVersions: available.aiVersions, aiLevels: available.aiLevels },
    methodology: { metric: 'exact_starting_deck_matchup', unit: 'seat_game', rolesSeparated: true,
      source: mode === 'ranked_ai' ? 'client_reported' : 'server_verified', minSample: 1, preliminary: true,
      interval: 'Wilson 95%; repeated testers are not independent samples',
      testers: 'Distinct human participants involved, including opponents; never AI accounts',
      privacy: 'Public exact deck lists and small-sample aggregates can permit inference. No identities or individual match histories.' },
    games: data.games, decks, matchups };
}

export async function deckMatchups(root, search, { statsOrigin = DEFAULT_ORIGIN, statsTimeoutMs = 5000 } = {}) {
  const query = deckQuery(search);
  const origin = new URL(statsOrigin);
  if (!['http:', 'https:'].includes(origin.protocol) || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash) fail();
  const cards = JSON.parse(readFileSync(path.join(root, 'data/cards.json'), 'utf8')).cards;
  if (!Array.isArray(cards)) fail();
  const catalog = new Map(cards.filter(c => c.collectible === true && c.isToken === false).map(c => [c.id, c]));
  const url = new URL(DECK_STATS_PATH, origin); url.search = query.toString();
  const response = await fetch(url, { redirect: 'error', signal: AbortSignal.timeout(statsTimeoutMs) });
  if (!response.ok || !response.body) { await response.body?.cancel(); throw new Error('unavailable'); }
  const chunks = []; let bytes = 0;
  for await (const chunk of response.body) {
    bytes += chunk.length;
    if (bytes > MAX_BYTES) throw new Error('too large');
    chunks.push(chunk);
  }
  return projectDeckMatchups(JSON.parse(Buffer.concat(chunks).toString('utf8')), catalog, query);
}
