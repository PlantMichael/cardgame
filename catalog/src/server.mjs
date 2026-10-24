// Static, read-only server for the prepared public catalog.
//
// Serves ONLY files under the public directory (default ../public). No
// database, no WebSocket relay, no credentials. Binds to $PORT (Railway
// injects it) on 0.0.0.0.

import { createHash } from 'node:crypto';
import { existsSync, readFileSync, statSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const IMMUTABLE = 'public, max-age=31536000, immutable';
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

/** The prepared catalog is present: latest.json exists and the files it links to do too. */
export function healthStatus(root) {
  const latest = readIfFile(path.join(root, 'data', 'v1', 'latest.json'));
  if (!latest) return { ok: false, reason: 'latest.json missing' };
  let pointer;
  try {
    pointer = JSON.parse(latest.toString('utf8'));
  } catch {
    return { ok: false, reason: 'latest.json unreadable' };
  }
  for (const key of ['cardsUrl', 'keywordsUrl']) {
    const file = typeof pointer[key] === 'string' ? resolvePublicFile(root, pointer[key]) : null;
    if (!file || !existsSync(file)) return { ok: false, reason: `${key} does not resolve to a prepared file` };
  }
  return { ok: true, catalogVersion: pointer.catalogVersion };
}

export function createCatalogServer(root) {
  const base = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Expose-Headers': 'ETag',
    'X-Content-Type-Options': 'nosniff',
  };

  return http.createServer((req, res) => {
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
    if (pathname === '/healthz') {
      const h = healthStatus(root);
      json(h.ok ? 200 : 503, h.ok ? { status: 'ok', catalogVersion: h.catalogVersion } : { status: 'unavailable', reason: h.reason });
      return;
    }

    const file = resolvePublicFile(root, req.url ?? '/');
    const body = file ? readIfFile(file) : null;
    if (!body) {
      json(404, { error: 'not found' });
      return;
    }
    const etag = etagOf(body);
    // Only files under releases/ are write-once; everything else (latest.json)
    // must be revalidated so a new release is seen promptly.
    const isRelease = path.relative(root, file).split(path.sep).includes('releases');
    const headers = {
      ETag: etag,
      'Cache-Control': isRelease ? IMMUTABLE : REVALIDATE,
    };
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
  const server = createCatalogServer(root);
  server.listen(port, '0.0.0.0', () => {
    const h = healthStatus(root);
    console.log(`catalog server on :${port}, serving ${root} (${h.ok ? `latest ${h.catalogVersion}` : `NOT READY: ${h.reason}`})`);
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
