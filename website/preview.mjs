import http from 'node:http';
import { createReadStream, statSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { outputRoot } from './build.mjs';

const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.ttf': 'font/ttf', '.wasm': 'application/wasm', '.pck': 'application/octet-stream' };

// Same directory-index URLs as the static Vercel output, without a framework/dev dependency.
export function previewServer(root = outputRoot) {
  const absoluteRoot = path.resolve(root);
  return http.createServer((req, res) => {
    if (!['GET', 'HEAD'].includes(req.method)) { res.writeHead(405, { Allow: 'GET, HEAD' }).end(); return; }
    let pathname;
    try { pathname = decodeURIComponent((req.url ?? '/').split('?')[0]); }
    catch { res.writeHead(400).end('Invalid path'); return; }
    if (pathname.includes('\\') || pathname.includes('\0') || pathname.split('/').some(p => p.startsWith('.'))) {
      res.writeHead(404).end('Not found'); return;
    }
    let file = path.resolve(absoluteRoot, `.${pathname}`);
    if (file !== absoluteRoot && !file.startsWith(absoluteRoot + path.sep)) { res.writeHead(404).end('Not found'); return; }
    let stat;
    try {
      stat = statSync(file);
      if (stat.isDirectory()) {
        if (!pathname.endsWith('/')) { res.writeHead(308, { Location: pathname + '/' }).end(); return; }
        file = path.join(file, 'index.html'); stat = statSync(file);
      }
      if (!stat.isFile()) throw new Error('Not a file');
    } catch { res.writeHead(404).end('Not found'); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(file)] ?? 'application/octet-stream',
      'Content-Length': stat.size, 'Cache-Control': 'no-cache', 'X-Content-Type-Options': 'nosniff' });
    if (req.method === 'HEAD') { res.end(); return; }
    const stream = createReadStream(file);
    stream.on('error', () => res.destroy());
    res.on('close', () => stream.destroy());
    stream.pipe(res);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const server = previewServer();
  server.listen(Number(process.env.PORT ?? 8943), '127.0.0.1', () => console.log(`cardgame preview: http://127.0.0.1:${server.address().port}`));
}
