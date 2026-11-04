import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createCatalogServer } from '../src/server.mjs';

test('bot proxy bounds upstream failures, projects privacy and recovers without stale success', async t => {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../public');
  let mode = 'ok', requested;
  const upstream = http.createServer((req, res) => {
    requested = req.url;
    if (mode === 'timeout') return;
    if (mode === 'status') { res.writeHead(503).end('private database diagnostic'); return; }
    if (mode === 'redirect') { res.writeHead(302, { Location: '/private' }).end(); return; }
    if (mode === 'json') { res.end('{'); return; }
    const data = { generatedAt: new Date().toISOString(), days: 30, games: 0, bots: [], decks: [], matchups: [],
      methodology: { source: 'bot_simulation', metric: 'exact_starting_deck_matchup', unit: 'seat_game', draws: 'excluded_from_win_rate', humanStats: 'excluded' },
      player_ids: ['private'], match_id: 'private' };
    if (mode === 'source') data.methodology.source = 'server_verified';
    if (mode === 'counts') data.games = 1;
    if (mode === 'days') data.days = 7;
    if (mode === 'ranked') { data.mode = 'ranked'; data.methodology.source = 'server_verified'; }
    const body = JSON.stringify(data);
    const bytes = mode === 'large' ? 16 * 1024 * 1024 + 1 : mode === 'expanded' ? 5 * 1024 * 1024 : 0;
    res.end(body + ' '.repeat(Math.max(0, bytes - Buffer.byteLength(body))));
  });
  await new Promise(r => upstream.listen(0, '127.0.0.1', r));
  const proxy = createCatalogServer(root, { statsOrigin: `http://127.0.0.1:${upstream.address().port}`, statsTimeoutMs: 1000 });
  await new Promise(r => proxy.listen(0, '127.0.0.1', r));
  t.after(async () => {
    for (const server of [proxy, upstream]) { server.closeAllConnections(); await new Promise(r => server.close(r)); }
  });
  const url = `http://127.0.0.1:${proxy.address().port}/data/stats/bot-matchups.json`;
  const first = await fetch(url); assert.equal(first.status, 200);
  const text = await first.text(); assert.ok(!text.includes('private')); assert.equal(JSON.parse(text).games, 0);
  assert.equal(requested, '/data/stats/bot-matchups.json?days=30');
  mode = 'expanded';
  assert.equal((await fetch(url)).status, 200, 'valid bot responses above the old 4 MiB ceiling are accepted');
  for (mode of ['timeout', 'status', 'redirect', 'large', 'json', 'source', 'counts', 'days']) {
    const response = await fetch(url);
    assert.equal(response.status, 503, mode);
    assert.deepEqual(await response.json(), { error: 'bot statistics unavailable' });
    assert.equal(response.headers.get('cache-control'), 'no-store');
  }
  mode = 'ok'; assert.equal((await fetch(url)).status, 200);
  assert.equal((await fetch(url + '?mode=ranked')).status, 503, 'simulation cannot masquerade as ranked data');
  mode = 'ranked';
  const ranked = await fetch(url + '?mode=ranked'); assert.equal(ranked.status, 200);
  assert.equal((await ranked.json()).mode, 'ranked');
  assert.equal(requested, '/data/stats/bot-matchups.json?days=30&mode=ranked');
  assert.equal((await fetch(url)).status, 503, 'ranked data cannot masquerade as simulations');
});
