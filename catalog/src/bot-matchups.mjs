import { readFileSync } from 'node:fs';
import path from 'node:path';
import { DEFAULT_ORIGIN } from './card-winrates.mjs';
import { composition } from './deck-matchups.mjs';

export const BOT_STATS_PATH = '/data/stats/bot-matchups.json';
const MAX_BYTES = 4 * 1024 * 1024;
const fail = () => { throw new Error('invalid bot aggregate'); };
const count = n => Number.isSafeInteger(n) && n >= 0;
const positive = n => Number.isInteger(n) && n > 0 && n <= 1000000;
export function botQuery(search) {
  const p = new URLSearchParams(search);
  for (const key of p.keys()) if (!['days', 'mode'].includes(key) || p.getAll(key).length !== 1) fail();
  const value = p.get('days') ?? '30';
  if (!/^[1-9]\d*$/.test(value) || Number(value) > 365) fail();
  const mode = p.get('mode') ?? 'simulation';
  if (!['simulation', 'ranked'].includes(mode)) fail();
  return { days: Number(value), mode };
}
function statistics(row) {
  if (!row || !count(row.matches) || row.matches === 0 || !count(row.wins) || !count(row.losses) || !count(row.draws) ||
      row.wins + row.losses + row.draws !== row.matches || !Number.isFinite(row.averageTurns) || row.averageTurns <= 0 || row.averageTurns > 1000000) fail();
  const split = s => {
    if (!s || !count(s.matches) || !count(s.wins) || s.wins > s.matches) fail();
    return { matches: s.matches, wins: s.wins };
  };
  const first = split(row.first), second = split(row.second);
  if (first.matches + second.matches !== row.matches || first.wins + second.wins !== row.wins) fail();
  return { matches: row.matches, wins: row.wins, losses: row.losses, draws: row.draws,
    winRate: row.wins + row.losses ? row.wins / (row.wins + row.losses) : null, averageTurns: row.averageTurns, first, second };
}
const names = { io: 'Io', callisto: 'Callisto', europa: 'Europa', ganymede: 'Ganymede', standard: 'Standard AI', human: 'Human players' };

export function projectBotStats(data, catalog, days, mode = 'simulation') {
  if ((data?.mode ?? 'simulation') !== mode || data?.methodology?.source !== (mode === 'ranked' ? 'server_verified' : 'bot_simulation') || data.methodology.metric !== 'exact_starting_deck_matchup' ||
      data.methodology.unit !== 'seat_game' || data.methodology.draws !== 'excluded_from_win_rate' || data.methodology.humanStats !== 'excluded' ||
      data.days !== days || typeof data.generatedAt !== 'string' || !Number.isFinite(Date.parse(data.generatedAt)) ||
      !count(data.games) || data.games > 50000) fail();
  for (const key of ['bots', 'decks', 'matchups']) if (!Array.isArray(data[key]) || data[key].length > 100000) fail();
  const botMap = new Map(), deckMap = new Map(), pairMap = new Map();
  const bots = data.bots.map(row => {
    const human = row.id === 'human';
    if (!Object.hasOwn(names, row.id) || row.name !== names[row.id] ||
        (human ? mode !== 'ranked' || row.version !== 'unversioned' || row.level !== null || row.style !== 'human'
          : typeof row.version !== 'string' || !/^\d{1,6}(?:\.\d{1,6})?$/.test(row.version) || !Number.isInteger(row.level) || row.level < 1 || row.level > 10 || !['tempo', 'combo', 'aggro', 'random', ''].includes(row.style)) ||
        !positive(row.rulesVersion) || !positive(row.engineVersion)) fail();
    const key = `${row.id}@${row.version}/L${row.level}/R${row.rulesVersion}/E${row.engineVersion}`;
    if (row.key !== key || botMap.has(key)) fail();
    if (row.id === 'standard' && (row.version !== String(row.engineVersion) || row.level !== 10 || row.style !== '')) fail();
    if (mode === 'ranked' && row.id === 'standard') fail();
    const result = { key, id: row.id, name: row.name, version: row.version, level: row.level, style: row.style,
      rulesVersion: row.rulesVersion, engineVersion: row.engineVersion, ...statistics(row) };
    botMap.set(key, { ...result, deckMatches: 0, deckWins: 0, deckDraws: 0 });
    return result;
  });
  const decks = data.decks.map(row => {
    const bot = botMap.get(row.botKey);
    if (!bot) fail();
    const deck = composition(row, catalog), key = `${row.botKey}/${deck.id}`;
    const size = deck.cards.reduce((n, c) => n + c.copies, 0);
    if (row.key !== key || deckMap.has(key) || deck.factions.length !== 1 || (bot.id === 'human' ? size < 1 || size > 40 : size !== 40)) fail();
    const result = { ...deck, key, botKey: row.botKey, ...statistics(row) };
    deckMap.set(key, { ...result, pairMatches: 0, pairWins: 0, pairDraws: 0 });
    bot.deckMatches += result.matches; bot.deckWins += result.wins; bot.deckDraws += result.draws;
    return result;
  });
  const matchups = data.matchups.map(row => {
    const own = deckMap.get(row.deckKey), enemy = deckMap.get(row.opponentDeckKey);
    if (!own || !enemy) fail();
    const a = botMap.get(own.botKey), b = botMap.get(enemy.botKey);
    if (a.rulesVersion !== b.rulesVersion || a.engineVersion !== b.engineVersion || a.id === 'standard' && b.id === 'standard' || a.id === 'human' && b.id === 'human') fail();
    const key = `${row.deckKey}|${row.opponentDeckKey}`;
    if (pairMap.has(key)) fail();
    const result = { deckKey: row.deckKey, opponentDeckKey: row.opponentDeckKey, ...statistics(row) };
    pairMap.set(key, result);
    own.pairMatches += result.matches; own.pairWins += result.wins; own.pairDraws += result.draws;
    return result;
  });
  for (const [key, row] of pairMap) {
    const reverse = pairMap.get(`${row.opponentDeckKey}|${row.deckKey}`);
    if (!reverse || row.matches !== reverse.matches || row.wins !== reverse.losses || row.draws !== reverse.draws ||
        row.first.matches !== reverse.second.matches || row.second.matches !== reverse.first.matches) fail();
  }
  if ([...botMap.values()].some(r => r.matches !== r.deckMatches || r.wins !== r.deckWins || r.draws !== r.deckDraws) ||
      [...deckMap.values()].some(r => r.matches !== r.pairMatches || r.wins !== r.pairWins || r.draws !== r.pairDraws) ||
      bots.reduce((n, r) => n + r.matches, 0) !== 2 * data.games ||
      bots.reduce((n, r) => n + r.wins + r.draws / 2, 0) !== data.games) fail();
  return { generatedAt: data.generatedAt, days, mode, games: data.games,
    methodology: { source: mode === 'ranked' ? 'server_verified' : 'bot_simulation', metric: 'exact_starting_deck_matchup', unit: 'seat_game', draws: 'excluded_from_win_rate', humanStats: 'excluded' },
    bots, decks, matchups };
}

export async function botMatchups(root, search, { statsOrigin = DEFAULT_ORIGIN, statsTimeoutMs = 5000 } = {}) {
  const { days, mode } = botQuery(search), origin = new URL(statsOrigin);
  if (!['http:', 'https:'].includes(origin.protocol) || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash) fail();
  const release = JSON.parse(readFileSync(path.join(root, 'data/cards.json'), 'utf8'));
  const catalog = new Map(release.cards.filter(c => c.collectible === true && c.isToken === false).map(c => [c.id, c]));
  const url = new URL(BOT_STATS_PATH, origin); url.searchParams.set('days', days);
  if (mode !== 'simulation') url.searchParams.set('mode', mode);
  const response = await fetch(url, { redirect: 'error', signal: AbortSignal.timeout(statsTimeoutMs) });
  if (!response.ok || !response.body) { await response.body?.cancel(); throw new Error('unavailable'); }
  const chunks = []; let bytes = 0;
  for await (const chunk of response.body) {
    bytes += chunk.length;
    if (bytes > MAX_BYTES) { await response.body.cancel().catch(() => {}); throw new Error('too large'); }
    chunks.push(chunk);
  }
  return projectBotStats(JSON.parse(Buffer.concat(chunks).toString('utf8')), catalog, days, mode);
}
