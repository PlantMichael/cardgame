import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  buildCandidate, loadReleaseInput, writeCatalog,
} from '../src/export.mjs';
import {
  CREATURE, DRAFT, releaseInput, tempDir, writeInput, writeSource,
} from './fixtures.mjs';

const exporter = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'src', 'export.mjs');

function setup(sourceOverrides, input = releaseInput()) {
  const root = tempDir();
  const source = path.join(root, 'data');
  writeSource(source, sourceOverrides);
  const inputFile = path.join(root, 'release-input.json');
  writeInput(inputFile, input);
  return { root, source, inputFile, out: path.join(root, 'public') };
}

function runCli(s, extra = []) {
  return spawnSync(process.execPath, [exporter, '--source', s.source, '--input', s.inputFile, '--out', s.out, ...extra], { encoding: 'utf8' });
}

function snapshot(dir) {
  const out = {};
  const walk = (d) => {
    for (const name of readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, name.name);
      if (name.isDirectory()) walk(p);
      else out[path.relative(dir, p)] = readFileSync(p, 'utf8');
    }
  };
  if (existsSync(dir)) walk(dir);
  return out;
}

test('projection: public fields only, correct nulls, every card type', () => {
  const s = setup();
  const c = buildCandidate(s.source, loadReleaseInput(s.inputFile));
  const cards = JSON.parse(c.cards).cards;
  assert.deepEqual(cards.map((x) => x.id), ['f_001', 'f_001t', 'f_loc_001', 'f_str_001']);
  const [creature, form, location, stratagem] = cards;

  assert.deepEqual(Object.keys(creature), [
    'id', 'name', 'color', 'type', 'rarity', 'manaCost', 'attack', 'health', 'tribe', 'description',
    'abilities', 'collectible', 'isToken', 'isTransformForm', 'transformInto', 'transformChoices',
  ]);
  assert.equal(creature.name, 'Fixture Guard');
  assert.equal(creature.manaCost, 2);
  assert.equal(creature.attack, 1);
  assert.equal(creature.health, 4);
  assert.equal(creature.tribe, null);
  assert.equal(creature.transformInto, 'f_001t');
  assert.deepEqual(creature.abilities, ['guardian', 'shielded_1']);

  assert.equal(form.collectible, false);
  assert.equal(form.isToken, true);
  assert.equal(form.isTransformForm, true);
  assert.equal(form.tribe, 'wolf');

  assert.equal(location.type, 'LOCATION');
  assert.equal(location.attack, null, 'a Location has no attack');
  assert.equal(location.health, 8, 'a Location keeps its health');

  assert.equal(stratagem.attack, null, 'a spell is not a 0-attack creature');
  assert.equal(stratagem.health, null);
  assert.equal(stratagem.description, 'Deal 3 damage.', '{n} resolves to the printed value');

  const text = c.cards + c.keywords;
  for (const leaked of ['res://', 'assets/', 'internal_effect', 'effect_value', 'in_starter', 'uid', 'rummage', 'f_draft', 'Unreleased']) {
    assert.ok(!text.includes(leaked), `must not leak ${leaked}`);
  }
});

test('keywords: base keyword resolution for parameterised abilities and aliases', () => {
  const s = setup();
  const kw = JSON.parse(buildCandidate(s.source, loadReleaseInput(s.inputFile)).keywords);
  assert.equal(kw.abilityKeywords.shielded_1, 'shielded');
  assert.equal(kw.abilityKeywords.guardian, 'guardian');
  assert.deepEqual(kw.keywords.map((k) => k.id), ['ethereal', 'guardian', 'rush', 'shielded']);
});

test('same inputs produce identical bytes; re-export is a no-op', () => {
  const s = setup();
  const first = buildCandidate(s.source, loadReleaseInput(s.inputFile));
  const second = buildCandidate(s.source, loadReleaseInput(s.inputFile));
  assert.equal(first.cards, second.cards);
  assert.equal(first.keywords, second.keywords);
  assert.equal(writeCatalog(s.out, first).status, 'written');
  const before = snapshot(s.out);
  assert.equal(writeCatalog(s.out, second).status, 'unchanged');
  assert.deepEqual(snapshot(s.out), before);
  assert.deepEqual(Object.keys(before).sort(), [path.join('data', 'cards.json'), path.join('data', 'keywords.json')]);
});

test('nothing is versioned: no version fields, and a changed export replaces the files', () => {
  const s = setup();
  writeCatalog(s.out, buildCandidate(s.source, loadReleaseInput(s.inputFile)));
  const cards = JSON.parse(readFileSync(path.join(s.out, 'data', 'cards.json'), 'utf8'));
  const keywords = JSON.parse(readFileSync(path.join(s.out, 'data', 'keywords.json'), 'utf8'));
  for (const file of [cards, keywords]) {
    for (const k of ['schemaVersion', 'catalogVersion', 'gameVersion']) assert.ok(!(k in file), k);
  }
  writeSource(s.source, { green: [{ ...CREATURE, health: 99 }, JSON.parse(readFileSync(path.join(s.source, 'cards', 'green.json'), 'utf8'))[1]] });
  assert.equal(writeCatalog(s.out, buildCandidate(s.source, loadReleaseInput(s.inputFile))).status, 'written');
  const after = JSON.parse(readFileSync(path.join(s.out, 'data', 'cards.json'), 'utf8')).cards.find((c) => c.id === 'f_001');
  assert.equal(after.health, 99);
});

test('release selection: unselected drafts stay out; nothing is auto-published', () => {
  const s = setup();
  const c = buildCandidate(s.source, loadReleaseInput(s.inputFile));
  assert.ok(!JSON.parse(c.cards).cards.some((x) => x.id === DRAFT.id));
});

// --- Failures: nonzero exit, named card/file, previous output untouched ---

function failureCase(name, mutate, expectText) {
  test(`failure: ${name}`, () => {
    const s = setup();
    assert.equal(runCli(s).status, 0, 'baseline export succeeds');
    const before = snapshot(s.out);
    mutate(s);
    const r = runCli(s);
    assert.notEqual(r.status, 0, 'must exit nonzero');
    assert.match(r.stderr, expectText);
    assert.deepEqual(snapshot(s.out), before, 'previous output must be unchanged');
  });
}

failureCase('malformed JSON names the file', (s) => {
  writeSource(s.source, { green: '{ not json' });
}, /green.*not valid JSON/);

failureCase('duplicate id across files names the id', (s) => {
  writeSource(s.source, { generic: [{ ...DRAFT, id: 'f_001' }] });
}, /duplicate card id f_001/);

failureCase('unknown id in the release input', (s) => {
  writeInput(s.inputFile, releaseInput({ cards: [{ id: 'f_001', collectible: true }, { id: 'nope', collectible: true }] }));
}, /unknown card id nope/);

failureCase('dangling transformation reference is not repaired', (s) => {
  writeInput(s.inputFile, releaseInput({ cards: [{ id: 'f_001', collectible: true }] }));
}, /f_001 references f_001t/);

failureCase('invalid required field names the card', (s) => {
  writeSource(s.source, { green: [{ ...CREATURE, rarity: 'MYTHIC' }, JSON.parse('{"id":"f_001t","card_name":"x","cost":1,"color":"GREEN","card_type":"CREATURE","rarity":"COMMON","description":"","attack":1,"health":1}')] });
}, /card f_001: invalid or missing "rarity"/);

test('exporting never edits the source tree', () => {
  const s = setup();
  const before = snapshot(s.source);
  runCli(s);
  assert.deepEqual(snapshot(s.source), before);
  writeFileSync(path.join(s.root, 'marker'), 'x');
});

// The smallest falsifier: the real six files, the real proposed selection.
test('real current game data exports cleanly and every reference resolves', () => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const repo = path.resolve(here, '..', '..');
  const c = buildCandidate(path.join(repo, 'data'), loadReleaseInput(path.join(here, '..', 'release-input.json')));
  const cards = JSON.parse(c.cards).cards;
  assert.ok(cards.length > 100);
  const ids = new Set(cards.map((x) => x.id));
  assert.equal(ids.size, cards.length, 'no duplicate ids');
  for (const x of cards) {
    for (const ref of [x.transformInto, ...x.transformChoices]) if (ref) assert.ok(ids.has(ref), `${x.id} -> ${ref}`);
  }
  assert.ok(cards.some((x) => x.type === 'LOCATION' && x.attack === null && x.health > 0));
  assert.ok(cards.some((x) => x.type === 'STRATAGEM' && x.attack === null));
  assert.ok(cards.some((x) => x.isTransformForm && !x.collectible));
});
