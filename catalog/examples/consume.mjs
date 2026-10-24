// Consumer example: fetch latest -> resolve the catalog URL -> index by ID -> filter locally.
// No SDK, no Godot, no API key.
//
//   node examples/consume.mjs [origin]            (default: http://localhost:8080)
//   node examples/consume.mjs https://<your-catalog-domain>

const origin = (process.argv[2] ?? 'http://localhost:8080').replace(/\/$/, '');

async function getJson(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`GET ${url} failed: HTTP ${res.status}`);
  return res.json();
}

try {
  // The manifest's URLs are root-relative: resolve them against the origin.
  const latest = await getJson(`${origin}/data/v1/latest.json`);
  const catalog = await getJson(new URL(latest.cardsUrl, origin));
  const keywords = await getJson(new URL(latest.keywordsUrl, origin));

  const byId = new Map(catalog.cards.map((c) => [c.id, c]));
  console.log(`catalog ${catalog.catalogVersion} (game ${catalog.gameVersion}): ${byId.size} cards, ${keywords.keywords.length} keywords`);

  // Filtering is done locally - the server has no query API.
  const cheapGuardians = catalog.cards.filter(
    (c) => c.collectible && c.type === 'CREATURE' && c.manaCost <= 3 && c.abilities.includes('guardian'),
  );
  for (const c of cheapGuardians) console.log(`${c.id}  ${c.name}  (${c.color}, ${c.manaCost} mana, ${c.attack}/${c.health})`);
} catch (e) {
  const why = e.cause?.code ? ` (${e.cause.code})` : '';
  console.error(`${e.message}${why} - is the catalog server running at ${origin}?`);
  process.exit(1);
}
