// Public card catalog exporter.
//
// Reads the six faction card files the game itself loads (see
// scripts/cards/card_database.gd), the keyword tooltips, and a release-input
// manifest that EXPLICITLY selects which cards are public. Writes immutable,
// versioned JSON under <outDir>/data/v1/ plus a small `latest.json` pointer.
//
// Node built-ins only. Deliberately does not touch server/relay.js, Postgres
// or the Godot export directory.
//
//   node src/export.mjs                          export the release named in release-input.json
//   node src/export.mjs --set-latest <version>   point latest.json at an existing release (rollback)

import { createHash } from 'node:crypto';
import {
  existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const SCHEMA_VERSION = 1;
// The same six files, in the same order, as CardDatabase._load_cards().
// red.json and data/cards/backup/ exist on disk but are NOT game content.
export const FACTION_FILES = ['green', 'crimson', 'black', 'orange', 'teal', 'generic'];

const COLORS = ['GREEN', 'CRIMSON', 'BLACK', 'ORANGE', 'TEAL', 'GENERIC'];
const TYPES = ['CREATURE', 'STRATAGEM', 'LOCATION'];
const RARITIES = ['COMMON', 'RARE', 'EPIC', 'LEGENDARY'];
const VERSION_LABEL = /^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$/;

const here = path.dirname(fileURLToPath(import.meta.url));
export const CATALOG_ROOT = path.resolve(here, '..');
export const REPO_ROOT = path.resolve(CATALOG_ROOT, '..');

export class ExportError extends Error {}

/** A label is used to build filesystem paths, so it must not be able to leave its directory. */
export function assertVersionLabel(label, what = 'version') {
  if (typeof label !== 'string' || !VERSION_LABEL.test(label) || label.includes('..')) {
    throw new ExportError(`${what} ${JSON.stringify(label)} is not a safe label (letters, digits, '.', '_', '-'; max 64)`);
  }
}

function readJson(file, what) {
  let text;
  try {
    text = readFileSync(file, 'utf8');
  } catch (e) {
    throw new ExportError(`${what}: cannot read ${file}: ${e.message}`);
  }
  try {
    return JSON.parse(text);
  } catch (e) {
    throw new ExportError(`${what}: ${file} is not valid JSON: ${e.message}`);
  }
}

/** Stable JSON text: fixed key order comes from construction, 2-space indent, trailing newline. */
export function serialize(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

// --- Loading ---------------------------------------------------------------

export function loadSources(sourceDir) {
  const cards = new Map();
  for (const name of FACTION_FILES) {
    const file = path.join(sourceDir, 'cards', `${name}.json`);
    const list = readJson(file, `faction file ${name}`);
    if (!Array.isArray(list)) throw new ExportError(`${file}: expected a JSON array`);
    list.forEach((raw, i) => {
      const where = `${name}.json[${i}]${raw && raw.id ? ` (${raw.id})` : ''}`;
      if (raw === null || typeof raw !== 'object') throw new ExportError(`${where}: not an object`);
      if (typeof raw.id !== 'string' || raw.id === '') throw new ExportError(`${where}: missing id`);
      if (cards.has(raw.id)) {
        throw new ExportError(`duplicate card id ${raw.id} (in ${name}.json and ${cards.get(raw.id).file})`);
      }
      cards.set(raw.id, { raw, file: `${name}.json` });
    });
  }
  const keywords = readJson(path.join(sourceDir, 'keywords.json'), 'keywords');
  const aliasesFile = path.join(sourceDir, 'keyword_abilities.json');
  const aliases = existsSync(aliasesFile) ? readJson(aliasesFile, 'keyword aliases') : {};
  return { cards, keywords, aliases };
}

export function loadReleaseInput(file) {
  const input = readJson(file, 'release input');
  assertVersionLabel(input.catalogVersion, 'catalogVersion');
  if (typeof input.gameVersion !== 'string' || input.gameVersion === '') {
    throw new ExportError('release input: gameVersion must be a non-empty string');
  }
  if (!Array.isArray(input.cards) || input.cards.length === 0) {
    throw new ExportError('release input: cards must be a non-empty array of { id, collectible }');
  }
  const seen = new Set();
  for (const entry of input.cards) {
    if (!entry || typeof entry.id !== 'string' || typeof entry.collectible !== 'boolean') {
      throw new ExportError(`release input: bad entry ${JSON.stringify(entry)} (need { "id": string, "collectible": boolean })`);
    }
    if (seen.has(entry.id)) throw new ExportError(`release input: ${entry.id} is listed twice`);
    seen.add(entry.id);
  }
  return input;
}

// --- Projection ------------------------------------------------------------

function requireField(where, raw, key, ok) {
  if (!ok(raw[key])) throw new ExportError(`${where}: invalid or missing "${key}" (${JSON.stringify(raw[key])})`);
}

/** The allowlisted public shape of one card. Nothing else from the source leaks through. */
export function projectCard(raw, entry, file, transformedInto) {
  const where = `${file} card ${raw.id}`;
  requireField(where, raw, 'card_name', (v) => typeof v === 'string' && v !== '');
  requireField(where, raw, 'cost', Number.isInteger);
  requireField(where, raw, 'color', (v) => COLORS.includes(v));
  requireField(where, raw, 'card_type', (v) => TYPES.includes(v));
  requireField(where, raw, 'rarity', (v) => RARITIES.includes(v));
  requireField(where, raw, 'description', (v) => typeof v === 'string');
  const abilities = raw.abilities ?? [];
  if (!Array.isArray(abilities) || abilities.some((a) => typeof a !== 'string')) {
    throw new ExportError(`${where}: "abilities" must be an array of strings`);
  }
  const type = raw.card_type;
  const hasAttack = type === 'CREATURE';
  const hasHealth = type === 'CREATURE' || type === 'LOCATION';
  if (hasAttack) requireField(where, raw, 'attack', Number.isInteger);
  if (hasHealth) requireField(where, raw, 'health', Number.isInteger);

  // "{n}" is substituted at runtime with effect_value + rummage_count; the
  // printed (as-drawn, no rummage history) value is what a catalog states.
  const description = raw.description.replaceAll('{n}', String(raw.effect_value ?? 0));
  const transformInto = raw.transform_into ? raw.transform_into : null;
  const transformChoices = Array.isArray(raw.transform_choices) ? [...raw.transform_choices] : [];

  return {
    id: raw.id,
    name: raw.card_name,
    color: raw.color,
    type,
    rarity: raw.rarity,
    manaCost: raw.cost,
    // Not applicable -> null, never a stratagem presented as a 0-attack creature.
    attack: hasAttack ? raw.attack : null,
    health: hasHealth ? raw.health : null,
    tribe: raw.tribe ? raw.tribe : null,
    description,
    abilities: [...abilities],
    collectible: entry.collectible,
    isToken: raw.is_token === true,
    isTransformForm: transformedInto.has(raw.id),
    transformInto,
    transformChoices,
  };
}

/** Strips trailing numeric parameters: shielded_1 -> shielded, pilot_2_2 -> pilot. */
export function abilityBase(ability) {
  return ability.replace(/(_\d+)+$/, '');
}

export function keywordId(name) {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
}

export function buildKeywords(keywordMap, aliases, publishedAbilities) {
  const byId = new Map();
  for (const [name, description] of Object.entries(keywordMap)) {
    if (typeof description !== 'string') throw new ExportError(`keywords.json: "${name}" must map to text`);
    byId.set(keywordId(name), { id: keywordId(name), name, description });
  }
  const aliasToKeyword = new Map();
  for (const [name, abilityKeys] of Object.entries(aliases)) {
    if (!byId.has(keywordId(name))) throw new ExportError(`keyword_abilities.json: "${name}" is not in keywords.json`);
    for (const key of abilityKeys) aliasToKeyword.set(key, keywordId(name));
  }
  const abilityKeywords = {};
  for (const ability of [...publishedAbilities].sort()) {
    const base = abilityBase(ability);
    abilityKeywords[ability] = aliasToKeyword.get(base) ?? (byId.has(base) ? base : null);
  }
  return {
    keywords: [...byId.values()].sort((a, b) => (a.id < b.id ? -1 : 1)),
    abilityKeywords,
  };
}

// --- Whole-candidate build (pure; touches no output) -------------------------

export function buildCandidate(sourceDir, releaseInput) {
  const { cards: source, keywords, aliases } = loadSources(sourceDir);
  const selected = new Map(releaseInput.cards.map((e) => [e.id, e]));
  for (const id of selected.keys()) {
    if (!source.has(id)) throw new ExportError(`release input names unknown card id ${id}`);
  }
  // Who is a transformation target, among the published set only.
  const transformedInto = new Set();
  for (const id of selected.keys()) {
    const raw = source.get(id).raw;
    if (raw.transform_into) transformedInto.add(raw.transform_into);
    for (const c of raw.transform_choices ?? []) transformedInto.add(c);
  }
  const projected = [];
  for (const [id, entry] of selected) {
    const { raw, file } = source.get(id);
    projected.push(projectCard(raw, entry, file, transformedInto));
  }
  projected.sort((a, b) => (a.id < b.id ? -1 : 1));
  // A published reference must resolve inside the published set; never pull
  // in an unreleased definition just to repair a dangling link.
  const ids = new Set(projected.map((c) => c.id));
  for (const c of projected) {
    for (const ref of [c.transformInto, ...c.transformChoices]) {
      if (ref && !ids.has(ref)) {
        throw new ExportError(`published card ${c.id} references ${ref}, which is not in the release selection`);
      }
    }
  }
  const publishedAbilities = new Set(projected.flatMap((c) => c.abilities));
  const kw = buildKeywords(keywords, aliases, publishedAbilities);
  const meta = {
    schemaVersion: SCHEMA_VERSION,
    catalogVersion: releaseInput.catalogVersion,
    gameVersion: releaseInput.gameVersion,
  };
  return {
    meta,
    cards: serialize({ ...meta, cards: projected }),
    keywords: serialize({ ...meta, ...kw }),
    cardCount: projected.length,
    abilitiesWithoutKeyword: Object.entries(kw.abilityKeywords).filter(([, v]) => v === null).map(([k]) => k),
  };
}

// --- Writing ----------------------------------------------------------------

function sha(buf) {
  return createHash('sha256').update(buf).digest('hex');
}

function atomicWrite(file, content, tmpDir) {
  mkdirSync(tmpDir, { recursive: true });
  const tmp = path.join(tmpDir, `${path.basename(file)}.${process.pid}.tmp`);
  writeFileSync(tmp, content);
  mkdirSync(path.dirname(file), { recursive: true });
  renameSync(tmp, file);
}

export function releaseDir(outDir, version) {
  assertVersionLabel(version);
  return path.join(outDir, 'data', 'v1', 'releases', version);
}

export function latestPointer(meta) {
  return serialize({
    schemaVersion: meta.schemaVersion,
    catalogVersion: meta.catalogVersion,
    gameVersion: meta.gameVersion,
    cardsUrl: `/data/v1/releases/${meta.catalogVersion}/cards.json`,
    keywordsUrl: `/data/v1/releases/${meta.catalogVersion}/keywords.json`,
  });
}

/**
 * Validates the whole candidate FIRST, then writes. Returns a description of
 * what happened. A published version is write-once: byte-identical is a no-op,
 * different content under the same label fails.
 */
export function writeRelease(outDir, candidate, { updateLatest = true } = {}) {
  const version = candidate.meta.catalogVersion;
  const dir = releaseDir(outDir, version);
  const cardsFile = path.join(dir, 'cards.json');
  const keywordsFile = path.join(dir, 'keywords.json');
  const tmpDir = path.join(outDir, '.tmp');

  let status = 'created';
  if (existsSync(cardsFile) || existsSync(keywordsFile)) {
    const same = existsSync(cardsFile) && existsSync(keywordsFile)
      && sha(readFileSync(cardsFile)) === sha(candidate.cards)
      && sha(readFileSync(keywordsFile)) === sha(candidate.keywords);
    if (!same) {
      throw new ExportError(
        `release ${version} already exists with different content; published versions are immutable - choose a new catalogVersion`,
      );
    }
    status = 'unchanged';
  } else {
    // Complete files land before anything points at them.
    atomicWrite(cardsFile, candidate.cards, tmpDir);
    atomicWrite(keywordsFile, candidate.keywords, tmpDir);
  }
  if (updateLatest) {
    atomicWrite(path.join(outDir, 'data', 'v1', 'latest.json'), latestPointer(candidate.meta), tmpDir);
  }
  rmSync(tmpDir, { recursive: true, force: true });
  return { status, version, latest: updateLatest };
}

/** Rollback / roll-forward: repoint latest.json at a release that already exists. */
export function setLatest(outDir, version) {
  const cardsFile = path.join(releaseDir(outDir, version), 'cards.json');
  if (!existsSync(cardsFile) || !existsSync(path.join(path.dirname(cardsFile), 'keywords.json'))) {
    throw new ExportError(`release ${version} does not exist in ${outDir}`);
  }
  const env = readJson(cardsFile, `release ${version}`);
  atomicWrite(path.join(outDir, 'data', 'v1', 'latest.json'), latestPointer(env), path.join(outDir, '.tmp'));
  rmSync(path.join(outDir, '.tmp'), { recursive: true, force: true });
  return { version };
}

// --- CLI -------------------------------------------------------------------

function parseArgs(argv) {
  const opts = {
    sourceDir: path.join(REPO_ROOT, 'data'),
    input: path.join(CATALOG_ROOT, 'release-input.json'),
    outDir: path.join(CATALOG_ROOT, 'public'),
    setLatest: null,
    updateLatest: true,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--source') opts.sourceDir = path.resolve(argv[++i]);
    else if (a === '--input') opts.input = path.resolve(argv[++i]);
    else if (a === '--out') opts.outDir = path.resolve(argv[++i]);
    else if (a === '--set-latest') opts.setLatest = argv[++i];
    else if (a === '--no-latest') opts.updateLatest = false;
    else throw new ExportError(`unknown argument ${a}`);
  }
  return opts;
}

export function main(argv) {
  const opts = parseArgs(argv);
  if (opts.setLatest) {
    setLatest(opts.outDir, opts.setLatest);
    console.log(`latest.json now points at release ${opts.setLatest}`);
    return;
  }
  const candidate = buildCandidate(opts.sourceDir, loadReleaseInput(opts.input));
  const result = writeRelease(opts.outDir, candidate, { updateLatest: opts.updateLatest });
  console.log(`release ${result.version}: ${result.status}, ${candidate.cardCount} cards${result.latest ? ', latest updated' : ''}`);
  if (candidate.abilitiesWithoutKeyword.length > 0) {
    console.log(`note: ${candidate.abilitiesWithoutKeyword.length} ability keys have no keyword entry (null in abilityKeywords): ${candidate.abilitiesWithoutKeyword.join(', ')}`);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    if (e instanceof ExportError) {
      console.error(`export failed: ${e.message}`);
      process.exit(1);
    }
    throw e;
  }
}
