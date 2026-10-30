// Read-only server for prepared card definitions and public win-rate aggregates.
//
// Serves prepared files plus a bounded aggregate fetch from the relay. No
// database credentials. Binds to $PORT (Railway
// injects it) on 0.0.0.0.

import { createHash } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { cardWinrates, STATS_PATH } from './card-winrates.mjs';
import { deckMatchups, deckQuery, DECK_STATS_PATH } from './deck-matchups.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const REVALIDATE = 'no-cache';

function etagOf(body) {
  return `"${createHash('sha256').update(body).digest('hex').slice(0, 32)}"`;
}

/** True when an If-None-Match header matches `etag` (list, `*`, weak forms). */
function matches(header, etag) {
  if (!header) return false;
  if (header.trim() === '*') return true;
  return header.split(',').some((t) => t.trim().replace(/^W\//, '') === etag);
}

/**
 * Maps a request path to a file inside `root`, or null. Rejects traversal,
 * encoded separators, NULs, dotfiles/dot-directories and anything that is not
 * a .json file.
 */
export function resolvePublicFile(root, rawPath) {
  let decoded;
  try {
    decoded = decodeURIComponent(rawPath.split('?')[0]);
  } catch {
    return null;
  }
  if (decoded.includes('\0') || decoded.includes('\\')) return null;
  const parts = decoded.split('/').filter((p) => p !== '');
  if (parts.length === 0) return null;
  if (parts.some((p) => p === '.' || p === '..' || p.startsWith('.'))) return null;
  if (!parts[parts.length - 1].endsWith('.json')) return null;
  const file = path.join(root, ...parts);
  const rel = path.relative(root, file);
  if (rel === '' || rel.startsWith('..') || path.isAbsolute(rel)) return null;
  return file;
}

function readIfFile(file) {
  try {
    if (!statSync(file).isFile()) return null;
    return readFileSync(file);
  } catch {
    return null;
  }
}

/** The prepared catalog is present: cards.json and keywords.json both exist and parse. */
export function healthStatus(root) {
  for (const name of ['cards.json', 'keywords.json']) {
    const body = readIfFile(path.join(root, 'data', name));
    if (!body) return { ok: false, reason: `${name} missing` };
    try {
      JSON.parse(body.toString('utf8'));
    } catch {
      return { ok: false, reason: `${name} unreadable` };
    }
  }
  return { ok: true };
}

export function createCatalogServer(root, options = {}) {
  const base = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Expose-Headers': 'ETag',
    'X-Content-Type-Options': 'nosniff',
  };

  return http.createServer(async (req, res) => {
    const send = (status, headers, body) => {
      res.writeHead(status, { ...base, ...headers });
      res.end(req.method === 'HEAD' ? undefined : body);
    };
    const json = (status, value, extra = {}) => {
      const body = `${JSON.stringify(value)}\n`;
      send(status, {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': Buffer.byteLength(body),
        'Cache-Control': 'no-store',
        ...extra,
      }, body);
    };

    if (req.method === 'OPTIONS') {
      send(204, {
        'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
        'Access-Control-Allow-Headers': 'If-None-Match',
        'Access-Control-Max-Age': '86400',
      });
      return;
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      json(405, { error: 'method not allowed' }, { Allow: 'GET, HEAD, OPTIONS' });
      return;
    }

    const pathname = (req.url ?? '/').split('?')[0];
    if (pathname === DECK_STATS_PATH) {
      const search = (req.url ?? '').split('?').slice(1).join('?');
      try { deckQuery(search); }
      catch { json(400, { error: 'invalid stats query' }); return; }
      try { json(200, await deckMatchups(root, search, options), { 'Cache-Control': REVALIDATE }); }
      catch { json(503, { error: 'deck matchup statistics unavailable' }); }
      return;
    }
    if (pathname === STATS_PATH) {
      try { json(200, await cardWinrates(root, resolvePublicFile, options), { 'Cache-Control': REVALIDATE }); }
      catch { json(503, { error: 'card win rates unavailable' }); }
      return;
    }
    if (pathname === '/healthz') {
      const h = healthStatus(root);
      json(h.ok ? 200 : 503, h.ok ? { status: 'ok' } : { status: 'unavailable', reason: h.reason });
      return;
    }

    const file = resolvePublicFile(root, req.url ?? '/');
    const body = file ? readIfFile(file) : null;
    if (!body) {
      json(404, { error: 'not found' });
      return;
    }
    const etag = etagOf(body);
    // Nothing is versioned, so every file is revalidated (ETag -> 304).
    const headers = { ETag: etag, 'Cache-Control': REVALIDATE };
    if (matches(req.headers['if-none-match'], etag)) {
      send(304, headers);
      return;
    }
    send(200, {
      ...headers,
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': body.length,
    }, body);
  });
}

export function main() {
  const root = path.resolve(process.env.CATALOG_PUBLIC_DIR ?? path.join(here, '..', 'public'));
  const port = Number(process.env.PORT ?? 8080);
  const server = createCatalogServer(root, { statsOrigin: process.env.CARD_WINRATES_ORIGIN });
  server.listen(port, '0.0.0.0', () => {
    const h = healthStatus(root);
    console.log(`catalog server on :${port}, serving ${root} (${h.ok ? 'ready' : `NOT READY: ${h.reason}`})`);
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
