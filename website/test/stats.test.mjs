// Stats tab logic against a SYNTHETIC, schema-valid snapshot (website/tools/stats-fixture.mjs).
// The numbers are invented; only the schema and the arithmetic rules are real.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildFixtureSnapshot, buildCombinedFixtureSnapshot, deckId } from '../tools/stats-fixture.mjs';
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
  const route = (over) => ({ ...S.routeFromSearch('?mode=ranked_ai'), ...over });
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

test('archetype labels use compositions, share names without merging lists and can be searched', () => {
  const deck = snapshot.decks.find((d) => d.role === 'human');
  const variant = { ...deck, id: 'different-list' };
  const decks = [...snapshot.decks, variant];
  const labeledIndex = S.indexSnapshot({ ...snapshot, decks }, cards);
  const labels = labeledIndex.labels;
  const name = S.deckLabel(deck, labels);
  assert.equal(name, `${S.factionLabel(deck)} ${S.deckArchetype(deck, cards)}`);
  assert.equal(name, S.deckLabel(variant, labels));
  assert.equal(S.findDeck(labeledIndex, variant.id, variant.role), variant, 'same label preserves distinct exact lists');
  assert.equal(S.deckLabel({ ...deck, role: 'ai' }, labels), name);
  assert.equal(S.deckLabel(deck, S.deckLabels([...decks].reverse(), cards)), name, 'input order does not change the label');
  assert.ok(!name.includes(S.shortId(deck.id)));
  const route = { ...S.routeFromSearch('?mode=ranked_ai'), q: name.toUpperCase() };
  assert.deepEqual(S.filterDecks({ ...snapshot, decks }, cards, route).map((d) => d.id).sort(), [deck.id, variant.id].sort());
  assert.ok(S.filterDecks(snapshot, cards, { ...route, q: S.factionLabel(deck) }).some((d) => d.id === deck.id));
});

test('estimated archetypes distinguish real printed card packages and do not guess with missing data', () => {
  const deck = (ids, faction = 'BLACK') => ({ id: ids.join(','), factions: [faction], cards: ids.map(id => ({id,copies:1})) });
  const aggressive = deck(['o_001','o_002','o_019','o_021','o_022','o_025'], 'ORANGE');
  assert.equal(S.deckLabel(aggressive, S.deckLabels([aggressive], cards)), 'Gundari Aggro');
  const tempo = deck(['b_007','b_018','b_019','b_001','b_012','b_003']);
  assert.equal(S.deckLabel(tempo, S.deckLabels([tempo], cards)), 'Junklings Tempo');
  assert.equal(S.deckArchetype(deck(['o_003','o_004','o_013','o_014','o_015','o_016'], 'ORANGE'), cards), 'Combo');
  assert.equal(S.deckArchetype(deck(['b_002','b_006','b_010','b_013','b_str_003']), cards), 'Control');
  assert.equal(S.deckArchetype(deck(['b_003','b_005','b_012','b_024']), cards), 'Midrange');
  assert.equal(S.deckArchetype(deck(['b_017']), cards), 'Midrange', 'a payoff alone does not establish a combo package');
  assert.equal(S.deckArchetype(aggressive, new Map()), 'Unclassified');
  const incomplete = new Map(cards); incomplete.delete('o_001');
  assert.equal(S.deckArchetype(aggressive, incomplete), 'Unclassified');
  assert.equal(S.deckArchetype({...tempo,cards:[...tempo.cards].reverse()}, cards), 'Tempo');
  // Copies, rather than distinct card IDs, determine the mana curve.
  const weighted = deck(['o_001','o_002','o_019','o_021','o_022','o_025','o_010','o_011'], 'ORANGE');
  assert.equal(S.deckArchetype(weighted, cards), 'Aggro');
  weighted.cards.find(c=>c.id==='o_010').copies=2;
  weighted.cards.find(c=>c.id==='o_011').copies=2;
  assert.equal(S.deckArchetype(weighted, cards), 'Tempo');
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
  const route = { ...S.routeFromSearch('?mode=ranked_ai&days=14&aiLevel=5'), view: 'deck', deck: K.H1, role: 'ai' };
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
  const badCopies=structuredClone(snapshot);badCopies.decks[0].cards[0].copies=-1;
  assert.equal(S.validateSnapshot(badCopies),false,'weighted card metrics require valid copy counts');
  const empty = { ...structuredClone(snapshot), games: 0, decks: [], matchups: [] };
  assert.equal(S.validateSnapshot(empty), true, 'an empty cohort is a valid, successful snapshot');
});


test('combined defaults and pooled fixture keep exact identities, mirrors and missing pairs', () => {
  const mixed = buildCombinedFixtureSnapshot(catalog);
  assert.ok(S.validateSnapshot(mixed));
  assert.equal(S.routeFromSearch('').cohort.mode,'all');
  assert.equal(S.routeFromSearch('').who,'combined');
  assert.deepEqual([...S.serverQuery(S.DEFAULT_COHORT).keys()].sort(),['days','mode','rulesVersion']);
  assert.equal(S.filterDecks(mixed,cards,S.routeFromSearch('')).length,3);
  assert.equal(mixed.decks.reduce((n,d)=>n+d.matches,0),mixed.games*2);
  assert.equal(mixed.decks.reduce((n,d)=>n+d.wins,0),mixed.games);
  const axes=S.matrixAxes(mixed,'all',8,8),grid=S.buildMatrix(mixed,axes.rowDecks,axes.colDecks);
  const row=id=>axes.rowDecks.findIndex(d=>d.id===id),col=id=>axes.colDecks.findIndex(d=>d.id===id);
  assert.equal(grid[row(mixed._keys.A)][col(mixed._keys.C)].winRate,0);
  assert.equal(grid[row(mixed._keys.B)][col(mixed._keys.C)],null);
  assert.deepEqual([grid[row(mixed._keys.A)][col(mixed._keys.A)].matches,grid[row(mixed._keys.A)][col(mixed._keys.A)].wins],[2,1]);
});

test('card metrics weight copies and win rate by appearances and distinguish missing play history',()=>{
  const mixed={decks:[{matches:3,wins:2,cards:[{id:'g_001',copies:2}]},{matches:1,wins:0,cards:[{id:'g_001',copies:1},{id:'cr_002',copies:1}]}],
    playStats:{totalSeats:4,trackedSeats:2,completeSeats:1,cards:[{id:'g_001',plays:7},{id:'g_003',plays:4}]}};
  const get=s=>new Map(S.cardMetrics(s,['g_001','cr_002','g_003','cr_003']).map(r=>[r.id,r]));
  const metrics=get(mixed);
  assert.deepEqual(metrics.get('g_001'),{id:'g_001',appearances:4,inDecks:1,averageCopies:1.75,deckWinRate:0.5,timesPlayed:7});
  assert.equal(metrics.get('cr_002').inDecks,0.25);
  assert.equal(metrics.get('cr_002').deckWinRate,0);
  assert.deepEqual(metrics.get('g_003'),{id:'g_003',appearances:0,inDecks:0,averageCopies:null,deckWinRate:null,timesPlayed:4},'a generated card can be played without starting in a deck');
  assert.equal(get({...mixed,playStats:undefined}).get('g_001').timesPlayed,null);
  assert.equal(get({...mixed,playStats:{totalSeats:4,trackedSeats:4,completeSeats:4,cards:[]}}).get('g_001').timesPlayed,0,'fully recorded zero stays different from missing history');
  assert.equal(S.sortCardMetrics([...metrics.values()],'deckWinRate','asc')[0].id,'cr_002');
  assert.equal(S.sortCardMetrics([...metrics.values()],'deckWinRate','desc')[0].id,'g_001');
  assert.equal(S.sortCardMetrics([...metrics.values()],'timesPlayed','desc')[0].id,'g_001');
});

test('card filters and sorting survive shared URLs; legacy AI/PvP cohorts remain selectable by URL',()=>{
  const route=S.routeFromSearch('?view=cards&mode=all&q=Slime&faction=BLACK&sort=deckWinRate&dir=asc');
  assert.deepEqual(S.routeFromSearch(S.searchFromRoute(route)),route);
  const legacy=S.routeFromSearch('?mode=ranked_ai&aiVersion=1&aiLevel=4&view=cards');
  assert.equal(legacy.cohort.aiLevel,'4');
  assert.deepEqual(S.routeFromSearch(S.searchFromRoute(legacy)),legacy);
  assert.equal(S.routeFromSearch('?mode=authoritative_pvp').cohort.mode,'authoritative_pvp');
  const bad=buildCombinedFixtureSnapshot(catalog);bad.playStats.completeSeats=bad.playStats.totalSeats+1;
  assert.equal(S.validateSnapshot(bad),false);
});
