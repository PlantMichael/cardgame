import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildSite, projectRoot } from '../build.mjs';
import { renderPages } from '../pages.mjs';
import { previewServer } from '../preview.mjs';

test('built public pages, canonical keywords and unchanged Godot runtime work over HTTP', async t => {
  const scratch = mkdtempSync(path.join(os.tmpdir(), 'cardgame-website-'));
  const hash = file => createHash('sha256').update(readFileSync(file)).digest('hex');
  const runtime = ['index.html', 'index.js', 'index.pck', 'index.wasm'];
  const before = runtime.map(name => hash(path.join(projectRoot, 'build', name)));
  const destination = buildSite(scratch);
  const server = previewServer(destination);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    assert.equal(path.dirname(path.resolve(scratch)), path.resolve(os.tmpdir()));
    rmSync(scratch, { recursive: true });
  });
  const origin = `http://127.0.0.1:${server.address().port}`;
  const pages = [];
  for (const route of ['/', '/rulebook/', '/glossary/']) {
    const response = await fetch(origin + route);
    assert.equal(response.status, 200, route);
    assert.match(response.headers.get('content-type'), /text\/html/);
    pages.push(await response.text());
  }
  const keywords = JSON.parse(readFileSync(path.join(projectRoot, 'data/keywords.json'), 'utf8'));
  const definitionText = pages[2].replaceAll('&#39;', "'").replaceAll('&amp;', '&');
  for (const [name, description] of Object.entries(keywords)) {
    assert.ok(pages[2].includes(`>${name}</h2>`), `visible definition: ${name}`);
    assert.ok(definitionText.includes(description.replace("Add's", 'Adds')), `definition text: ${name}`);
  }
  // Resolve actual links/images/scripts from every rendered page, including fragment targets.
  for (const html of pages) {
    for (const [, target] of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
      const url = new URL(target, origin + ['/','/rulebook/','/glossary/'][pages.indexOf(html)]);
      const response = await fetch(url, { method: 'HEAD' });
      assert.equal(response.status, 200, target);
      if (url.hash) {
        const body = await (await fetch(url)).text();
        assert.ok(body.includes(`id="${url.hash.slice(1)}"`), `fragment: ${target}`);
      }
    }
  }
  const redirect = await fetch(origin + '/play', { redirect: 'manual' });
  assert.equal(redirect.status, 308); assert.equal(redirect.headers.get('location'), '/play/');
  const play = await fetch(origin + '/play/');
  assert.equal(await play.text(), readFileSync(path.join(projectRoot, 'build/index.html'), 'utf8'));
  for (let i = 0; i < runtime.length; i++) {
    const name = runtime[i];
    assert.equal(hash(path.join(destination, 'play', name)), before[i], `copied runtime: ${name}`);
    assert.equal(hash(path.join(projectRoot, 'build', name)), before[i], `source unchanged: ${name}`);
    const response = await fetch(origin + '/play/' + name, { method: 'HEAD' });
    assert.equal(response.status, 200); assert.equal(response.headers.get('cache-control'), 'no-cache');
    if (name.endsWith('.wasm')) assert.equal(response.headers.get('content-type'), 'application/wasm');
  }
  assert.equal((await fetch(origin + '/index.wasm', { method: 'HEAD' })).status, 200, 'original runtime URLs survive');
  assert.equal((await fetch(origin + '/not-a-page/')).status, 404);
  assert.equal((await fetch(origin + '/%2ehidden')).status, 404);
  assert.equal((await fetch(origin + '/', { method: 'POST' })).status, 405);
});

test('untrusted keyword content is escaped in the generated public HTML', () => {
  const featured = ['GREEN','CRIMSON','TEAL'].map(color => ({ color, card_name: 'Example', cost: 1, attack: 1, health: 1,
    card_type: 'CREATURE', description: 'Example', image: '/example.png' }));
  const pages = renderPages({ featured, keywords: { '<img src=x onerror="alert(1)">': 'A & B <script>alert(2)</script>' } });
  const html = pages['glossary/index.html'];
  assert.ok(!html.includes('<script>alert(2)</script>'));
  assert.ok(!html.includes('<img src=x'));
  assert.ok(html.includes('A &amp; B &lt;script&gt;alert(2)&lt;/script&gt;'));
});
