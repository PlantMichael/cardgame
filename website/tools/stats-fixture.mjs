// SYNTHETIC deck-matchups snapshot in the documented schema, for tests and for
// the "?demo=1" preview. The compositions use real printed card ids so the page
// can show real card text; the RESULTS are invented. Never present this as
// recorded play: the page labels demo mode on screen.
import { createHash } from 'node:crypto';

export function deckId(cards) {
  const counts = new Map();
  for (const id of cards) counts.set(id, (counts.get(id) || 0) + 1);
  const pairs = [...counts.entries()].sort(([a], [b]) => (a < b ? -1 : 1));
  return createHash('sha256').update(JSON.stringify(pairs)).digest('hex');
}

function wilson(wins, n) {
  if (!n) return { lower: 0, upper: 1 };
  const z = 1.96; const p = wins / n;
  const denom = 1 + (z * z) / n;
  const centre = (p + (z * z) / (2 * n)) / denom;
  const margin = (z * Math.sqrt((p * (1 - p)) / n + (z * z) / (4 * n * n))) / denom;
  return { lower: Math.max(0, centre - margin), upper: Math.min(1, centre + margin) };
}

const split = (matches, wins) => ({ matches, wins, losses: matches - wins, winRate: matches ? wins / matches : null });

function stats({ wins, losses, testers, turnTotal = 0, turnSamples = 0, first, second, unknown }) {
  const matches = wins + losses;
  return {
    matches, wins, losses, winRate: matches ? wins / matches : null, winRateInterval: wilson(wins, matches),
    testers, averageTurns: turnSamples ? turnTotal / turnSamples : null, turnSamples,
    first: split(first[0], first[1]), second: split(second[0], second[1]), unknownFirst: split(unknown[0], unknown[1]),
  };
}

/** Pick `count` cards by cycling a pool, at most `max` copies each (legendary: 1). */
function build(cards, pool, count) {
  const out = [];
  const copies = new Map();
  for (let i = 0; out.length < count && i < pool.length * 3; i++) {
    const card = pool[i % pool.length];
    const limit = card.rarity === 'LEGENDARY' ? 1 : 2;
    if ((copies.get(card.id) || 0) >= limit) continue;
    copies.set(card.id, (copies.get(card.id) || 0) + 1);
    out.push(card.id);
  }
  return out;
}

export function buildFixtureSnapshot(catalog, { generatedAt = '2026-11-02T12:00:00.000Z' } = {}) {
  const real = catalog.cards.filter((c) => c.collectible && !c.isToken);
  const of = (color) => real.filter((c) => c.color === color).sort((a, b) => a.manaCost - b.manaCost || a.id.localeCompare(b.id));
  const generic = of('GENERIC');
  const lists = {
    sapiens: build(real, [...of('GREEN'), ...generic], 40),
    coven: build(real, [...of('CRIMSON'), ...generic], 40),
    mokotai: build(real, [...of('TEAL'), ...generic], 30),
    junk: build(real, [...of('BLACK').reverse(), ...generic], 40),
  };
  const specs = {
    H1: { role: 'human', cards: lists.sapiens }, H2: { role: 'human', cards: lists.coven },
    H3: { role: 'human', cards: lists.mokotai },
    A1: { role: 'ai', cards: lists.sapiens }, // same composition as H1, kept separate by role
    A2: { role: 'ai', cards: lists.junk }, A3: { role: 'ai', cards: lists.mokotai },
  };
  const toDeck = (key) => {
    const { role, cards } = specs[key];
    const counts = new Map();
    for (const id of cards) counts.set(id, (counts.get(id) || 0) + 1);
    const sorted = [...counts.entries()].sort(([a], [b]) => (a < b ? -1 : 1));
    const colours = [...new Set(sorted.map(([id]) => real.find((c) => c.id === id)?.color).filter((c) => c && c !== 'GENERIC'))].sort();
    return { key, id: deckId(cards), role, cards: sorted.map(([id, copies]) => ({ id, copies })), factions: colours.length ? colours : ['GENERIC'] };
  };
  const decks = Object.fromEntries(Object.keys(specs).map((k) => [k, toDeck(k)]));

  // human deck vs ai deck: [wins, losses, testers, turnTotal, turnSamples, first[m,w], second[m,w], unknown[m,w]]
  const pairs = {
    'H1>A1': [7, 5, 3, 9 * 10 + 2 * 11, 12, [6, 4], [5, 3], [1, 0]],
    'H1>A2': [9, 3, 3, 8 * 12, 12, [6, 5], [6, 4], [0, 0]],
    'H1>A3': [4, 4, 2, 0, 0, [0, 0], [0, 0], [8, 4]], // all turn counts and first-player facts missing
    'H2>A1': [3, 6, 2, 9 * 11, 9, [5, 2], [4, 1], [0, 0]],
    'H2>A2': [5, 2, 2, 7 * 10, 7, [3, 3], [4, 2], [0, 0]],
    'H3>A1': [0, 2, 1, 2 * 14, 2, [1, 0], [1, 0], [0, 0]], // a real 0-2 record
    'H3>A2': [1, 0, 1, 9, 1, [1, 1], [0, 0], [0, 0]], // a single game, 100%
    'H3>A3': [2, 1, 1, 3 * 13, 3, [2, 1], [1, 1], [0, 0]],
  };
  const total = { H1: [0, 0], H2: [0, 0], H3: [0, 0], A1: [0, 0], A2: [0, 0], A3: [0, 0] };
  const agg = {};
  const matchups = [];
  const addAgg = (key, row) => {
    const a = agg[key] || (agg[key] = { wins: 0, losses: 0, tt: 0, ts: 0, f: [0, 0], s: [0, 0], u: [0, 0], people: new Set() });
    a.wins += row.wins; a.losses += row.losses; a.tt += row.turnTotal; a.ts += row.turnSamples;
    a.f[0] += row.first[0]; a.f[1] += row.first[1]; a.s[0] += row.second[0]; a.s[1] += row.second[1];
    a.u[0] += row.unknown[0]; a.u[1] += row.unknown[1];
    for (let i = 0; i < row.testers; i++) a.people.add(`${row.pair}-${i}`);
  };
  for (const [pair, [wins, losses, testers, turnTotal, turnSamples, first, second, unknown]] of Object.entries(pairs)) {
    const [h, a] = pair.split('>');
    const base = { wins, losses, testers, turnTotal, turnSamples, first, second, unknown, pair };
    matchups.push({ deckId: decks[h].id, role: 'human', opponentDeckId: decks[a].id, opponentRole: 'ai', ...stats(base) });
    // The AI side sees the reverse result; the splits are from the same seat-games.
    const rev = { ...base, wins: losses, losses: wins,
      // Who went first flips with the perspective: the AI went first exactly when the human went second.
      first: [second[0], second[0] - second[1]], second: [first[0], first[0] - first[1]], unknown: [unknown[0], unknown[0] - unknown[1]] };
    matchups.push({ deckId: decks[a].id, role: 'ai', opponentDeckId: decks[h].id, opponentRole: 'human', ...stats(rev) });
    addAgg(h, base); addAgg(a, rev);
    total[h][0] += wins; total[h][1] += losses; total[a][0] += losses; total[a][1] += wins;
  }
  const deckRows = Object.values(decks).map((d) => {
    const a = agg[d.key];
    return { id: d.id, cards: d.cards, factions: d.factions, role: d.role,
      ...stats({ wins: a.wins, losses: a.losses, testers: a.people.size, turnTotal: a.tt, turnSamples: a.ts, first: a.f, second: a.s, unknown: a.u }) };
  });
  const games = deckRows.filter((d) => d.role === 'human').reduce((n, d) => n + d.matches, 0);
  return {
    generatedAt,
    filters: { mode: 'ranked_ai', days: 30, rulesVersion: 2, aiVersion: 1, aiLevel: 10 },
    availableFilters: { rulesVersions: [2, 1], aiVersions: [1, 'unknown'], aiLevels: [1, 5, 10] },
    methodology: { metric: 'exact_starting_deck_matchup', unit: 'seat_game', rolesSeparated: true, minSample: 1, preliminary: true, source: 'client_reported' },
    games, decks: deckRows, matchups, _keys: Object.fromEntries(Object.entries(decks).map(([k, d]) => [k, d.id])),
  };
}
