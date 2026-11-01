import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createCatalogServer } from '../src/server.mjs';
import { DECK_STATS_PATH } from '../src/deck-matchups.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../public');
const identity = id => createHash('sha256').update(JSON.stringify([[id, 1]])).digest('hex');
const A = identity('g_001'), B = identity('cr_002');
function split(matches, wins) { return { matches, wins, losses: matches - wins }; }
function stats(won, first) {
  return { matches: 1, wins: Number(won), losses: Number(!won), winRate: 999,
    testers: 1, averageTurns: 8, turnSamples: 1, winRateInterval: { lower: 999, upper: 999 },
    first: split(Number(first), first && won ? 1 : 0),
    second: split(Number(!first), !first && won ? 1 : 0), unknownFirst: split(0, 0), player_id: 42 };
}
function fixture() {
  return { generatedAt: new Date().toISOString(),
    filters: { mode: 'ranked_ai', days: 30, rulesVersion: 3, aiVersion: 1, aiLevel: 10, private: 'secret' },
    availableFilters: { rulesVersions: [3], aiVersions: [1, 'unknown'], aiLevels: [10], player_ids: [42] },
    methodology: { metric: 'exact_starting_deck_matchup', rolesSeparated: true, unit: 'seat_game', source: 'client_reported', secret: true },
    games: 1, match_id: 'private_match',
    decks: [{ id: A, cards: [{ id: 'g_001', copies: 1, secret: true }], role: 'human', ...stats(true, true) },
      { id: B, cards: [{ id: 'cr_002', copies: 1 }], role: 'ai', ...stats(false, false) }],
    matchups: [{ deckId: A, opponentDeckId: B, role: 'human', opponentRole: 'ai', ...stats(true, true) },
      { deckId: B, opponentDeckId: A, role: 'ai', opponentRole: 'human', ...stats(false, false) }] };
}

test('deck proxy projects the public contract and rejects malformed or unavailable upstream data', async t => {
  let mode = 'ok', requestUrl;
  const upstream = http.createServer((req, res) => {
    requestUrl = req.url;
    if (mode === 'timeout') return;
    if (mode === 'status') { res.writeHead(503).end('private DB diagnostic'); return; }
    if (mode === 'redirect') { res.writeHead(302, { Location: '/private' }).end(); return; }
    if (mode === 'large') { res.end(' '.repeat(4 * 1024 * 1024 + 1)); return; }
    const data = fixture();
    if (mode === 'counts') data.decks[0].wins = 2;
    if (mode === 'card') data.decks[0].cards[0].id = 'unpublished_card';
    if (mode === 'identity') data.decks[0].id = 'wrong_hash';
    if (mode === 'reference') data.matchups[0].opponentDeckId = 'missing';
    if (mode === 'roles') data.matchups[0].opponentRole = 'human';
    if (mode === 'source') data.methodology.source = 'server_verified';
    if (mode === 'filters') data.filters.aiVersion = 2;
    if (mode === 'split') data.decks[0].first.wins = 0;
    if (mode === 'duplicate') data.decks.push(data.decks[0]);
    if (mode === 'reverse') {
      data.matchups[0].first = split(0, 0); data.matchups[0].second = split(1, 1);
    }
    res.end(JSON.stringify(data));
  });
  await new Promise(r => upstream.listen(0, '127.0.0.1', r));
  const proxy = createCatalogServer(root, { statsOrigin: `http://127.0.0.1:${upstream.address().port}`, statsTimeoutMs: 100 });
  await new Promise(r => proxy.listen(0, '127.0.0.1', r));
  t.after(async () => {
    for (const server of [upstream, proxy]) { server.closeAllConnections(); await new Promise(r => server.close(r)); }
  });
  const url = `http://127.0.0.1:${proxy.address().port}${DECK_STATS_PATH}?rulesVersion=3&aiVersion=1`;
  const response = await fetch(url); assert.equal(response.status, 200);
  const text = await response.text(), data = JSON.parse(text);
  assert.equal(requestUrl, DECK_STATS_PATH + '?rulesVersion=3&aiVersion=1');
  assert.equal(data.decks[0].winRate, 1, 'rates derive from validated counts');
  assert.ok(data.decks[0].winRateInterval.lower > 0 && data.decks[0].winRateInterval.lower < 1);
  assert.deepEqual(data.decks[0].factions, ['GREEN'], 'factions derive from published card data');
  for (const privateText of ['secret', 'private_match', 'match_id', 'player_id', 'player_ids', 'private DB']) assert.ok(!text.includes(privateText), privateText);
  for (mode of ['counts', 'card', 'identity', 'reference', 'roles', 'source', 'filters', 'split', 'duplicate', 'reverse', 'large', 'status', 'redirect', 'timeout']) {
    const failed = await fetch(url);
    assert.equal(failed.status, 503, mode);
    assert.equal(failed.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await failed.json(), { error: 'deck matchup statistics unavailable' });
  }
  assert.equal((await fetch(url + '&token=private')).status, 400, 'invalid query is rejected before upstream failure');
  mode = 'ok';
  assert.equal((await fetch(url)).status, 200, 'errors are not cached');
  assert.equal((await fetch(`http://127.0.0.1:${proxy.address().port}/data/cards.json`)).status, 200);
});
