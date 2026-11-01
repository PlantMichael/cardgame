// Stats tab logic against a SYNTHETIC, schema-valid snapshot (website/tools/stats-fixture.mjs).
// The numbers are invented; only the schema and the arithmetic rules are real.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildFixtureSnapshot, deckId } from '../tools/stats-fixture.mjs';
import * as S from '../stats-core.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const catalog = JSON.parse(readFileSync(path.join(root, 'catalog/public/data/cards.json'), 'utf8'));
const cards = S.cardsById(catalog);
const snapshot = buildFixtureSnapshot(catalog);
const index = S.indexSnapshot(snapshot);
const K = snapshot._keys;

test('the synthetic fixture obeys the documented invariants', () => {
  assert.ok(S.validateSnapshot(snapshot));
  // matches sum to twice the physical games; wins sum to games
  assert.equal(snapshot.decks.reduce((n, d) => n + d.matches, 0), snapshot.games * 2);
  assert.equal(snapshot.decks.reduce((n, d) => n + d.wins, 0), snapshot.games);
  for (const d of snapshot.decks) {
    for (const split of [d.first, d.second, d.unknownFirst]) assert.equal(split.wins + split.losses, split.matches);
    assert.equal(d.first.matches + d.second.matches + d.unknownFirst.matches, d.matches);
  }
});

test('percentages are fractions: 2 of 3 is 66.7%, not 0.7% or 200%', () => {
  assert.equal(S.pct(2 / 3), '66.7%');
  assert.equal(S.pct(0), '0.0%');
  assert.equal(S.pct(1), '100.0%');
  assert.equal(S.pct(null), '—');
  assert.equal(S.pct(undefined), '—');
  assert.equal(S.interval({ lower: 0.208, upper: 0.939 }), '20.8%–93.9%');
  assert.equal(S.interval(null), '—');
  assert.equal(S.record({ wins: 2, losses: 1 }), '2–1');
});

test('null turns render as a dash and are never zero', () => {
  assert.equal(S.turns({ averageTurns: null }), '—');
  assert.equal(S.turns({ averageTurns: 9.25 }), '9.3');
  const noTurns = snapshot.matchups.find((m) => m.turnSamples === 0);
  assert.ok(noTurns && noTurns.averageTurns === null, 'the fixture has a null-turns row');
  assert.equal(S.turns(noTurns), '—');
});

test('the same composition stays separate in the human and AI roles', () => {
  assert.equal(K.H1, K.A1);
  const human = S.findDeck(index, K.H1, 'human');
  const ai = S.findDeck(index, K.A1, 'ai');
  assert.ok(human && ai && human !== ai);
  assert.notDeepEqual([human.wins, human.losses], [ai.wins, ai.losses]);
  assert.equal(S.findDeck(index, K.H1, 'ai').role, 'ai', 'looked up by id AND role');
  assert.equal(S.findDeck(index, K.H2, 'ai'), null, 'a human-only composition has no AI record');
});

test('deck identity ignores order and is sensitive to a copy count', () => {
  const a = deckId(['g_002', 'g_001', 'g_001']);
  assert.equal(a, deckId(['g_001', 'g_002', 'g_001']));
  assert.notEqual(a, deckId(['g_001', 'g_002']));
  assert.match(a, /^[0-9a-f]{64}$/);
});

test('matchups include the reverse perspective and are never double counted', () => {
  const h1 = S.findDeck(index, K.H1, 'human');
  const rows = S.opponentsOf(snapshot, index, h1);
  assert.equal(rows.length, 3);
  assert.deepEqual([h1.wins, h1.losses], [rows.reduce((n, r) => n + r.matchup.wins, 0), rows.reduce((n, r) => n + r.matchup.losses, 0)],
    'a deck record is the sum of its OWN opponent rows only');
  const a1 = S.findDeck(index, K.A1, 'ai');
  const forward = index.matchByKey.get(`${K.H1}/human>${K.A1}/ai`);
  const reverse = index.matchByKey.get(`${K.A1}/ai>${K.H1}/human`);
  assert.equal(forward.wins, reverse.losses);
  assert.equal(forward.losses, reverse.wins);
  assert.ok(a1.matches > 0);
  // distinct testers are not additive across opponents
  assert.ok(h1.testers <= rows.reduce((n, r) => n + r.matchup.testers, 0));
});

test('a real 0% record is different from a missing matchup', () => {
  const real = index.matchByKey.get(`${K.H3}/human>${K.A1}/ai`);
  assert.deepEqual([real.wins, real.losses, real.winRate], [0, 2, 0]);
  assert.equal(S.pct(real.winRate), '0.0%');
  const { rowDecks, colDecks } = S.matrixAxes(snapshot, 'ranked_ai', 10, 10);
  const grid = S.buildMatrix(snapshot, rowDecks, colDecks);
  const r = rowDecks.findIndex((d) => d.id === K.H3);
  const c = colDecks.findIndex((d) => d.id === K.A1);
  assert.equal(grid[r][c].wins, 0, 'a 0-win cell exists');
  const missingRow = rowDecks.findIndex((d) => d.id === K.H2);
  const missingCol = colDecks.findIndex((d) => d.id === K.A3);
  assert.equal(grid[missingRow][missingCol], null, 'no recorded games is null, not 0% or 50%');
  assert.equal(S.heat(null), -1);
  assert.equal(S.heat(0), 0);
});

test('matrix axes: AI mode is human rows against AI columns; PvP is human on both', () => {
  const ai = S.matrixAxes(snapshot, 'ranked_ai', 10, 10);
  assert.ok(ai.rowDecks.every((d) => d.role === 'human') && ai.colDecks.every((d) => d.role === 'ai'));
  const pvp = S.matrixAxes(snapshot, 'authoritative_pvp', 10, 10);
  assert.ok(pvp.colDecks.every((d) => d.role === 'human'));
  assert.deepEqual(ai.rowDecks.map((d) => d.matches), [...ai.rowDecks.map((d) => d.matches)].sort((a, b) => b - a), 'most played first');
  assert.equal(S.matrixAxes(snapshot, 'ranked_ai', 2, 1).rowDecks.length, 2);
});

test('share is of ALL human seat-games before any local filter', () => {
  const human = snapshot.decks.filter((d) => d.role === 'human');
  const denominator = human.reduce((n, d) => n + d.matches, 0);
  assert.equal(index.humanSeatGames, denominator);
  const h1 = S.findDeck(index, K.H1, 'human');
  assert.equal(S.shareOfHumanSeatGames(index, h1), h1.matches / denominator);
  assert.equal(S.shareOfHumanSeatGames(index, S.findDeck(index, K.A1, 'ai')), null, 'AI decks have no human share');
});

test('local filters: role, faction, card search, exclusion, minimum sample, stable sort', () => {
  const route = (over) => ({ ...S.routeFromSearch(''), ...over });
  assert.equal(S.filterDecks(snapshot, cards, route({})).length, 3, 'human decks by default');
  assert.equal(S.filterDecks(snapshot, cards, route({ who: 'ai' })).length, 3);
  assert.equal(S.filterDecks(snapshot, cards, route({ faction: 'GREEN' })).length, 1);
  assert.equal(S.filterDecks(snapshot, cards, route({ min: 12 })).every((d) => d.matches >= 12), true);
  const anyCard = cards.get(snapshot.decks[0].cards[0].id).name;
  assert.ok(S.filterDecks(snapshot, cards, route({ q: anyCard.toUpperCase() })).length >= 1, 'case-insensitive card name search');
  assert.equal(S.filterDecks(snapshot, cards, route({ x: anyCard })).some((d) => d.cards.some((c) => cards.get(c.id).name === anyCard)), false);
  const sorted = S.sortDecks(snapshot.decks.filter((d) => d.role === 'human'), 'winRate', 'desc');
  assert.deepEqual(sorted.map((d) => d.winRate), [...sorted.map((d) => d.winRate)].sort((a, b) => b - a));
  assert.deepEqual(S.sortDecks(snapshot.decks, 'bogus', 'desc').map((d) => d.matches), S.sortDecks(snapshot.decks, 'matches', 'desc').map((d) => d.matches));
});

test('a single-game 100% deck keeps its sample and is not hidden by default', () => {
  const lone = snapshot.matchups.find((m) => m.matches === 1 && m.winRate === 1);
  assert.ok(lone);
  assert.equal(S.pct(lone.winRate), '100.0%');
  assert.equal(lone.matches, 1);
  assert.equal(S.routeFromSearch('').min, 1, 'minimum sample starts at 1');
});

test('mana curve comes from the composition and totals the card count', () => {
  for (const d of snapshot.decks) {
    const curve = S.manaCurve(d, cards);
    assert.equal(curve.reduce((a, b) => a + b, 0), S.cardCount(d));
  }
});

test('only the five allowed server parameters are ever sent; PvP drops the AI ones', () => {
  const ai = S.serverQuery({ mode: 'ranked_ai', days: '30', rulesVersion: 'latest', aiVersion: 'latest', aiLevel: '10' });
  assert.deepEqual([...ai.keys()].sort(), ['aiLevel', 'aiVersion', 'days', 'mode', 'rulesVersion']);
  const pvp = S.serverQuery({ mode: 'authoritative_pvp', days: '7', rulesVersion: '3', aiVersion: 'latest', aiLevel: '10' });
  assert.deepEqual([...pvp.keys()].sort(), ['days', 'mode', 'rulesVersion']);
  assert.equal(S.apiUrl('https://catalog.example', { mode: 'authoritative_pvp', days: '7', rulesVersion: 'latest' }),
    'https://catalog.example/data/stats/deck-matchups.json?mode=authoritative_pvp&days=7&rulesVersion=latest');
  // UI-only keys (view, deck, search) never reach the server query
  const route = S.routeFromSearch('?mode=ranked_ai&view=deck&deck=abc&q=foo&min=3');
  assert.ok(![...S.serverQuery(route.cohort).keys()].some((k) => ['view', 'deck', 'q', 'min'].includes(k)));
});

test('cohort parsing is strict and round-trips through the URL', () => {
  const bad = S.cohortFromParams(new URLSearchParams('mode=nope&days=0&rulesVersion=-1&aiVersion=1.5&aiLevel=11'));
  assert.deepEqual(bad, S.DEFAULT_COHORT);
  assert.equal(S.cohortFromParams(new URLSearchParams('days=365')).days, '365');
  assert.equal(S.cohortFromParams(new URLSearchParams('days=366')).days, '30');
  assert.equal(S.cohortFromParams(new URLSearchParams('mode=authoritative_pvp&aiLevel=3')).aiLevel, undefined, 'PvP carries no AI parameters');
  for (const search of ['?mode=ranked_ai&days=7&rulesVersion=3&aiVersion=unknown&aiLevel=4',
    '?mode=authoritative_pvp&days=90&rulesVersion=latest&view=matrix&rows=5&cols=6',
    `?mode=ranked_ai&days=30&rulesVersion=latest&aiVersion=latest&aiLevel=10&view=deck&deck=${K.H1}&role=human&opp=${K.A2}&oppRole=ai`]) {
    const route = S.routeFromSearch(search);
    assert.deepEqual(S.routeFromSearch(S.searchFromRoute(route)), route, search);
  }
  // switching to PvP removes the AI parameters from the address
  const pvp = S.routeFromSearch('?mode=ranked_ai&aiVersion=2&aiLevel=4');
  pvp.cohort = S.cohortFromParams(new URLSearchParams('mode=authoritative_pvp&days=30&rulesVersion=latest'));
  assert.ok(!S.searchFromRoute(pvp).includes('ai'));
});

test('deck links keep both id and role plus the cohort', () => {
  const route = { ...S.routeFromSearch('?days=14&aiLevel=5'), view: 'deck', deck: K.H1, role: 'ai' };
  const search = S.searchFromRoute(route);
  const back = S.routeFromSearch(search);
  assert.equal(back.deck, K.H1);
  assert.equal(back.role, 'ai');
  assert.equal(back.cohort.days, '14');
  assert.equal(back.cohort.aiLevel, '5');
});

test('a matrix selection survives in the address', () => {
  const route = { ...S.routeFromSearch('?view=matrix'), deck: K.H1, role: 'human', opp: K.A2, oppRole: 'ai' };
  const back = S.routeFromSearch(S.searchFromRoute(route));
  assert.deepEqual([back.view, back.deck, back.opp, back.oppRole], ['matrix', K.H1, K.A2, 'ai']);
});

test('malformed or incoherent snapshots are rejected instead of rendered', () => {
  assert.equal(S.validateSnapshot(null), false);
  assert.equal(S.validateSnapshot({}), false);
  const bad = structuredClone(snapshot);
  bad.decks[0].wins += 1;
  assert.equal(S.validateSnapshot(bad), false, 'wins + losses must equal matches');
  const noRole = structuredClone(snapshot);
  delete noRole.decks[0].role;
  assert.equal(S.validateSnapshot(noRole), false);
  const empty = { ...structuredClone(snapshot), games: 0, decks: [], matchups: [] };
  assert.equal(S.validateSnapshot(empty), true, 'an empty cohort is a valid, successful snapshot');
});
