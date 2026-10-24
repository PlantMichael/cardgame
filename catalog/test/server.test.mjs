import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { after, before, test } from 'node:test';

import { buildCandidate, loadReleaseInput, setLatest, writeRelease } from '../src/export.mjs';
import { createCatalogServer } from '../src/server.mjs';
import {
  releaseInput, tempDir, writeInput, writeSource,
} from './fixtures.mjs';

const root = tempDir();
const source = path.join(root, 'data');
const inputFile = path.join(root, 'release-input.json');
const pub = path.join(root, 'public');
let server;
let port;

function release(version) {
  writeInput(inputFile, releaseInput({ catalogVersion: version }));
  writeRelease(pub, buildCandidate(source, loadReleaseInput(inputFile)));
}

/** Raw request so that '..' and encoded paths reach the server un-normalised. */
function raw(method, urlPath, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path: urlPath, headers }, (res) => {
      const chunks = [];
      res.on('data', (d) => chunks.push(d));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    req.end();
  });
}

before(async () => {
  writeSource(source);
  release('1.0.0');
  // Something private beside the public tree that must never be reachable.
  writeFileSync(path.join(root, 'secret.json'), '{"secret":true}');
  writeFileSync(path.join(pub, 'data', 'v1', 'notes.txt'), 'not json');
  server = createCatalogServer(pub);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  port = server.address().port;
});
after(() => server.close());

test('latest -> linked files are served as JSON with the expected shape', async () => {
  const latest = await raw('GET', '/data/v1/latest.json');
  assert.equal(latest.status, 200);
  assert.equal(latest.headers['content-type'], 'application/json; charset=utf-8');
  const pointer = JSON.parse(latest.body);
  for (const url of [pointer.cardsUrl, pointer.keywordsUrl]) {
    const r = await raw('GET', url);
    assert.equal(r.status, 200, url);
    assert.equal(JSON.parse(r.body).catalogVersion, '1.0.0');
  }
  const cards = JSON.parse((await raw('GET', pointer.cardsUrl)).body).cards;
  assert.equal(cards.length, 4);
});

test('no database prerequisite: no DATABASE_URL is set or needed', async () => {
  assert.equal(process.env.DATABASE_URL, undefined);
  assert.equal((await raw('GET', '/healthz')).status, 200);
});

test('unknown paths are a real 404 JSON, not a fallback page', async () => {
  for (const p of ['/', '/index.html', '/data/v1/nope.json', '/data/v1/releases/9.9.9/cards.json', '/data/v1/', '/data', '/favicon.ico']) {
    const r = await raw('GET', p);
    assert.equal(r.status, 404, p);
    assert.match(r.headers['content-type'], /application\/json/);
    assert.ok(!r.body.includes('<html'), p);
  }
});

test('no traversal, no directory listing, no non-JSON, no dotfiles, no source tree', async () => {
  for (const p of [
    '/data/v1/../../../secret.json', '/../secret.json', '/data/v1/%2e%2e/%2e%2e/%2e%2e/secret.json',
    '/data%2fv1%2f..%2f..%2f..%2fsecret.json', '/data/v1/..%5c..%5csecret.json', '/data/v1/latest.json%00.png',
    '/data/v1/notes.txt', '/.tmp/x.json', '/data/v1/releases/', '/data/v1/releases',
  ]) {
    const r = await raw('GET', p);
    assert.equal(r.status, 404, p);
    assert.ok(!r.body.includes('secret'), p);
  }
});

test('CORS: anonymous, any origin, ETag exposed, preflight answered, never credentialed', async () => {
  const r = await raw('GET', '/data/v1/latest.json', { Origin: 'http://localhost:5173' });
  assert.equal(r.headers['access-control-allow-origin'], '*');
  assert.match(r.headers['access-control-expose-headers'], /ETag/i);
  assert.equal(r.headers['access-control-allow-credentials'], undefined);
  const pre = await raw('OPTIONS', '/data/v1/latest.json', {
    Origin: 'http://localhost:5173', 'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'if-none-match',
  });
  assert.equal(pre.status, 204);
  assert.match(pre.headers['access-control-allow-headers'], /If-None-Match/i);
  assert.match(pre.headers['access-control-allow-methods'], /GET/);
  // A 404 is still readable cross-origin.
  assert.equal((await raw('GET', '/nope.json')).headers['access-control-allow-origin'], '*');
});

test('other methods are refused; HEAD matches GET without a body', async () => {
  assert.equal((await raw('POST', '/data/v1/latest.json')).status, 405);
  assert.equal((await raw('DELETE', '/data/v1/latest.json')).status, 405);
  const get = await raw('GET', '/data/v1/latest.json');
  const head = await raw('HEAD', '/data/v1/latest.json');
  assert.equal(head.status, 200);
  assert.equal(head.body, '');
  assert.equal(head.headers.etag, get.headers.etag);
});

test('cache policy: latest revalidates, release files are immutable, ETag gives 304', async () => {
  const latest = await raw('GET', '/data/v1/latest.json');
  assert.equal(latest.headers['cache-control'], 'no-cache');
  assert.match(latest.headers.etag, /^"[0-9a-f]{32}"$/);

  const url = '/data/v1/releases/1.0.0/cards.json';
  const cards = await raw('GET', url);
  assert.equal(cards.headers['cache-control'], 'public, max-age=31536000, immutable');
  assert.match(cards.headers['content-type'], /charset=utf-8/);

  for (const [p, tag] of [[url, cards.headers.etag], ['/data/v1/latest.json', latest.headers.etag]]) {
    const same = await raw('GET', p, { 'If-None-Match': tag });
    assert.equal(same.status, 304, p);
    assert.equal(same.body, '');
    assert.equal((await raw('GET', p, { 'If-None-Match': `W/${tag}` })).status, 304, 'weak form matches');
    assert.equal((await raw('GET', p, { 'If-None-Match': `"other", ${tag}` })).status, 304, 'list form matches');
    assert.equal((await raw('GET', p, { 'If-None-Match': '"stale"' })).status, 200, 'a stale tag gets the body');
  }
});

test('history survives an update: latest selects the new release, the old one is unchanged', async () => {
  const oldBody = (await raw('GET', '/data/v1/releases/1.0.0/cards.json')).body;
  const oldTag = (await raw('GET', '/data/v1/latest.json')).headers.etag;

  release('1.1.0');
  const latest = JSON.parse((await raw('GET', '/data/v1/latest.json')).body);
  assert.equal(latest.catalogVersion, '1.1.0');
  assert.equal(JSON.parse((await raw('GET', latest.cardsUrl)).body).catalogVersion, '1.1.0');
  assert.equal((await raw('GET', '/data/v1/releases/1.0.0/cards.json')).body, oldBody, 'old release retrievable and identical');
  // A client holding the old latest ETag now gets the new pointer, not a 304.
  assert.equal((await raw('GET', '/data/v1/latest.json', { 'If-None-Match': oldTag })).status, 200);

  setLatest(pub, '1.0.0');
  assert.equal(JSON.parse((await raw('GET', '/data/v1/latest.json')).body).catalogVersion, '1.0.0');
  assert.equal((await raw('GET', '/data/v1/releases/1.1.0/cards.json')).status, 200, 'rollback keeps the newer release available');
});

test('health fails when the prepared catalog is incomplete', async () => {
  const empty = tempDir();
  const s2 = createCatalogServer(empty);
  await new Promise((r) => s2.listen(0, '127.0.0.1', r));
  const p2 = s2.address().port;
  const res = await new Promise((resolve) => {
    http.get({ host: '127.0.0.1', port: p2, path: '/healthz' }, (r) => {
      let body = '';
      r.on('data', (d) => { body += d; });
      r.on('end', () => resolve({ status: r.statusCode, body }));
    });
  });
  assert.equal(res.status, 503, 'a bound port alone is not healthy');

  // latest.json present but pointing at a file that is missing.
  mkdirSync(path.join(empty, 'data', 'v1'), { recursive: true });
  writeFileSync(path.join(empty, 'data', 'v1', 'latest.json'), JSON.stringify({
    catalogVersion: 'x', cardsUrl: '/data/v1/releases/x/cards.json', keywordsUrl: '/data/v1/releases/x/keywords.json',
  }));
  const res2 = await new Promise((resolve) => {
    http.get({ host: '127.0.0.1', port: p2, path: '/healthz' }, (r) => {
      r.resume();
      r.on('end', () => resolve(r.statusCode));
    });
  });
  assert.equal(res2, 503, 'a dangling pointer is unhealthy');
  s2.close();
});
