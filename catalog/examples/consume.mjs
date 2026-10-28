// Consumer example: fetch cards and keywords -> index by ID -> filter locally.
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
  const catalog = await getJson(`${origin}/data/cards.json`);
  const keywords = await getJson(`${origin}/data/keywords.json`);

  const byId = new Map(catalog.cards.map((c) => [c.id, c]));
  console.log(`${byId.size} cards, ${keywords.keywords.length} keywords`);

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
