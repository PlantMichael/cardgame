import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createCatalogServer } from '../src/server.mjs';
import { STATS_PATH } from '../src/card-winrates.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../public');
const published = JSON.parse(readFileSync(path.join(root, 'data/cards.json'))).cards.filter(c => c.collectible && !c.isToken);

test('catalog projects only published counts and isolates bounded upstream failures', async t => {
  let mode = 'ok';
  const upstream = http.createServer((req, res) => {
    if (mode === 'timeout') return;
    if (mode === 'status') { res.writeHead(503); res.end('private DB error'); return; }
    if (mode === 'redirect') { res.writeHead(302, { Location: '/private' }); res.end(); return; }
    if (mode === 'large') { res.end(' '.repeat(1024 * 1024 + 1)); return; }
    const cards = published.map(c => ({ id: c.id, matches: 1, wins: 1, losses: 0, winRate: 999, player_id: 5 }));
    cards.push({ id: 'gen_str_005', matches: 1, wins: 1, losses: 0 });
    if (mode === 'malformed') cards[0].wins = 2;
    if (mode === 'incomplete') cards.pop(), cards.pop();
    res.end(JSON.stringify({
      generatedAt: new Date().toISOString(), cards, player_deck: ['private'],
      methodology: { secret: true, ...(mode === 'missingSeats' ? {} : { aiSeats: mode === 'oldSeats' ? 'human_only' : 'both' }) } }));
  });
  await new Promise(r => upstream.listen(0, '127.0.0.1', r));
  const server = createCatalogServer(root, { statsOrigin: `http://127.0.0.1:${upstream.address().port}`, statsTimeoutMs: 100 });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  t.after(async () => {
    upstream.closeAllConnections(); server.closeAllConnections();
    await Promise.all([new Promise(r => upstream.close(r)), new Promise(r => server.close(r))]);
  });
  const origin = `http://127.0.0.1:${server.address().port}`;
  const ok = await fetch(origin + STATS_PATH);
  assert.equal(ok.status, 200);
  const text = await ok.text();
  const data = JSON.parse(text);
  assert.equal(data.cards.length, published.length);
  assert.equal(data.cards[0].winRate, 1, 'rate is recomputed from validated counts');
  assert.equal(data.methodology.aiSeats, 'both');
  assert.ok(!('schemaVersion' in data) && !('catalogVersion' in data), 'stats carry no version fields');
  for (const privateField of ['player_id', 'player_deck', 'gen_str_005', 'secret']) assert.ok(!text.includes(privateField));
  for (mode of ['status', 'redirect', 'large', 'malformed', 'incomplete', 'timeout', 'oldSeats', 'missingSeats']) {
    const response = await fetch(origin + STATS_PATH);
    assert.equal(response.status, 503, mode);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await response.json(), { error: 'card win rates unavailable' });
  }
  mode = 'ok';
  assert.equal((await fetch(origin + STATS_PATH)).status, 200);
  assert.equal((await fetch(origin + '/healthz')).status, 200);
});
