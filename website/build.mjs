import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { renderPages } from './pages.mjs';

export const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const outputRoot = path.join(projectRoot, 'website-dist');
export const featuredIds = ['g_002', 'cr_002', 't_010'];

// Compose the website around the existing export. Never modify or regenerate it.
export function buildSite(destination = outputRoot) {
  const allCards = ['green', 'crimson', 'black', 'orange', 'teal', 'generic']
    .flatMap(f => JSON.parse(readFileSync(path.join(projectRoot, `data/cards/${f}.json`), 'utf8')));
  const featured = featuredIds.map(id => {
    const card = allCards.find(c => c.id === id);
    if (!card || !card.art?.startsWith('res://assets/')) throw new Error(`Missing featured card: ${id}`);
    const source = path.join(projectRoot, card.art.slice(6));
    if (!existsSync(source)) throw new Error(`Missing featured artwork: ${id}`);
    return { ...card, source, image: `/media/${id}${path.extname(source)}` };
  });
  const keywords = JSON.parse(readFileSync(path.join(projectRoot, 'data/keywords.json'), 'utf8'));
  const pages = renderPages({ featured, keywords });
  const gameRoot = path.join(projectRoot, 'build');
  for (const name of ['index.html', 'index.js', 'index.wasm', 'index.pck']) {
    if (!existsSync(path.join(gameRoot, name))) throw new Error(`Export the Web game first: missing build/${name}`);
  }
  mkdirSync(path.join(destination, 'media'), { recursive: true });
  mkdirSync(path.join(destination, 'play'), { recursive: true });
  for (const [name, html] of Object.entries(pages)) {
    mkdirSync(path.dirname(path.join(destination, name)), { recursive: true });
    writeFileSync(path.join(destination, name), html);
  }
  for (const name of ['style.css', 'app.js', 'mark.svg']) cpSync(path.join(projectRoot, 'website', name), path.join(destination, name));
  for (const card of featured) cpSync(card.source, path.join(destination, card.image.slice(1)));
  cpSync(path.join(projectRoot, 'assets/wallapepr.png'), path.join(destination, 'media/world.png'));
  for (const name of readdirSync(gameRoot)) {
    if (!/^index\.[\w.-]+$/.test(name) || name.endsWith('.import')) continue;
    cpSync(path.join(gameRoot, name), path.join(destination, 'play', name));
    // Existing cached bootstrap pages can still fetch the original runtime URLs.
    if (name !== 'index.html') cpSync(path.join(gameRoot, name), path.join(destination, name));
  }
  return destination;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  console.log(`Built cardgame website: ${buildSite()}`);
}
