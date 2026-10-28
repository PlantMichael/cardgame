import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { after, before, test } from 'node:test';

import { buildCandidate, loadReleaseInput, writeCatalog } from '../src/export.mjs';
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

function publish() {
  writeInput(inputFile, releaseInput());
  writeCatalog(pub, buildCandidate(source, loadReleaseInput(inputFile)));
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
  publish();
  // Something private beside the public tree that must never be reachable.
  writeFileSync(path.join(root, 'secret.json'), '{"secret":true}');
  writeFileSync(path.join(pub, 'data', 'notes.txt'), 'not json');
  server = createCatalogServer(pub);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  port = server.address().port;
});
after(() => server.close());

test('cards and keywords are served as JSON with the expected shape', async () => {
  for (const url of ['/data/cards.json', '/data/keywords.json']) {
    const r = await raw('GET', url);
    assert.equal(r.status, 200, url);
    assert.equal(r.headers['content-type'], 'application/json; charset=utf-8');
    const body = JSON.parse(r.body);
    assert.ok(!('catalogVersion' in body) && !('schemaVersion' in body), `${url} carries no version`);
  }
  assert.equal(JSON.parse((await raw('GET', '/data/cards.json')).body).cards.length, 4);
  for (const old of ['/data/v1/latest.json', '/data/v1/releases/1.0.0/cards.json']) assert.equal((await raw('GET', old)).status, 404, old);
});

test('no database prerequisite: no DATABASE_URL is set or needed', async () => {
  assert.equal(process.env.DATABASE_URL, undefined);
  assert.equal((await raw('GET', '/healthz')).status, 200);
});

test('unknown paths are a real 404 JSON, not a fallback page', async () => {
  for (const p of ['/', '/index.html', '/data/nope.json', '/data/', '/data', '/favicon.ico']) {
    const r = await raw('GET', p);
    assert.equal(r.status, 404, p);
    assert.match(r.headers['content-type'], /application\/json/);
    assert.ok(!r.body.includes('<html'), p);
  }
});

test('no traversal, no directory listing, no non-JSON, no dotfiles, no source tree', async () => {
  for (const p of [
    '/data/../../secret.json', '/../secret.json', '/data/%2e%2e/%2e%2e/secret.json',
    '/data%2f..%2f..%2fsecret.json', '/data/..%5c..%5csecret.json', '/data/cards.json%00.png',
    '/data/notes.txt', '/.tmp/x.json',
  ]) {
    const r = await raw('GET', p);
    assert.equal(r.status, 404, p);
    assert.ok(!r.body.includes('secret'), p);
  }
});

test('CORS: anonymous, any origin, ETag exposed, preflight answered, never credentialed', async () => {
  const r = await raw('GET', '/data/cards.json', { Origin: 'http://localhost:5173' });
  assert.equal(r.headers['access-control-allow-origin'], '*');
  assert.match(r.headers['access-control-expose-headers'], /ETag/i);
  assert.equal(r.headers['access-control-allow-credentials'], undefined);
  const pre = await raw('OPTIONS', '/data/cards.json', {
    Origin: 'http://localhost:5173', 'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'if-none-match',
  });
  assert.equal(pre.status, 204);
  assert.match(pre.headers['access-control-allow-headers'], /If-None-Match/i);
  assert.match(pre.headers['access-control-allow-methods'], /GET/);
  // A 404 is still readable cross-origin.
  assert.equal((await raw('GET', '/nope.json')).headers['access-control-allow-origin'], '*');
});

test('other methods are refused; HEAD matches GET without a body', async () => {
  assert.equal((await raw('POST', '/data/cards.json')).status, 405);
  assert.equal((await raw('DELETE', '/data/cards.json')).status, 405);
  const get = await raw('GET', '/data/cards.json');
  const head = await raw('HEAD', '/data/cards.json');
  assert.equal(head.status, 200);
  assert.equal(head.body, '');
  assert.equal(head.headers.etag, get.headers.etag);
});

test('cache policy: everything revalidates, ETag gives 304', async () => {
  for (const p of ['/data/cards.json', '/data/keywords.json']) {
    const res = await raw('GET', p);
    assert.equal(res.headers['cache-control'], 'no-cache', p);
    assert.match(res.headers.etag, /^"[0-9a-f]{32}"$/);
    assert.match(res.headers['content-type'], /charset=utf-8/);
    const tag = res.headers.etag;
    const same = await raw('GET', p, { 'If-None-Match': tag });
    assert.equal(same.status, 304, p);
    assert.equal(same.body, '');
    assert.equal((await raw('GET', p, { 'If-None-Match': `W/${tag}` })).status, 304, 'weak form matches');
    assert.equal((await raw('GET', p, { 'If-None-Match': `"other", ${tag}` })).status, 304, 'list form matches');
    assert.equal((await raw('GET', p, { 'If-None-Match': '"stale"' })).status, 200, 'a stale tag gets the body');
  }
});

test('an update replaces the data: the old ETag no longer matches', async () => {
  const oldTag = (await raw('GET', '/data/cards.json')).headers.etag;
  writeSource(source, { teal: [] });
  writeInput(inputFile, releaseInput({ cards: [{ id: 'f_001', collectible: true }, { id: 'f_001t', collectible: false }] }));
  writeCatalog(pub, buildCandidate(source, loadReleaseInput(inputFile)));
  const res = await raw('GET', '/data/cards.json', { 'If-None-Match': oldTag });
  assert.equal(res.status, 200);
  assert.equal(JSON.parse(res.body).cards.length, 2);
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

  // cards.json present but keywords.json missing.
  mkdirSync(path.join(empty, 'data'), { recursive: true });
  writeFileSync(path.join(empty, 'data', 'cards.json'), '{"cards":[]}');
  const res2 = await new Promise((resolve) => {
    http.get({ host: '127.0.0.1', port: p2, path: '/healthz' }, (r) => {
      r.resume();
      r.on('end', () => resolve(r.statusCode));
    });
  });
  assert.equal(res2, 503, 'a half-prepared catalog is unhealthy');
  s2.close();
});
