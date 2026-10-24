// Shared test fixtures: a tiny source tree and release input in a temp dir.
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

export function tempDir(prefix = 'catalog-test-') {
  return mkdtempSync(path.join(tmpdir(), prefix));
}

export const CREATURE = {
  id: 'f_001', card_name: 'Fixture Guard', cost: 2, color: 'GREEN', card_type: 'CREATURE', rarity: 'COMMON',
  tribe: '', description: 'Guardian.', attack: 1, health: 4, abilities: ['guardian', 'shielded_1'],
  art: 'res://assets/green/secret.png', effect: 'internal_effect', effect_value: 9, in_starter: true,
  transform_into: 'f_001t',
};
export const TOKEN = {
  id: 'f_001t', card_name: 'Fixture Form', cost: 2, color: 'GREEN', card_type: 'CREATURE', rarity: 'COMMON',
  tribe: 'wolf', description: 'Rush.', attack: 5, health: 4, abilities: ['rush'], is_token: true,
};
export const STRATAGEM = {
  id: 'f_str_001', card_name: 'Fixture Bolt', cost: 3, color: 'GENERIC', card_type: 'STRATAGEM', rarity: 'RARE',
  tribe: '', description: 'Deal {n} damage.', attack: 0, health: 0, abilities: [], effect: 'deal_damage', effect_value: 3,
};
export const LOCATION = {
  id: 'f_loc_001', card_name: 'Fixture Hall', cost: 3, color: 'CRIMSON', card_type: 'LOCATION', rarity: 'EPIC',
  tribe: '', description: 'A place.', attack: 0, health: 8, abilities: [],
};
export const DRAFT = {
  id: 'f_draft', card_name: 'Unreleased Draft', cost: 1, color: 'TEAL', card_type: 'CREATURE', rarity: 'COMMON',
  tribe: '', description: 'Not public.', attack: 1, health: 1, abilities: [],
};

export function writeSource(dir, overrides = {}) {
  const files = {
    green: [CREATURE, TOKEN],
    crimson: [LOCATION],
    black: [],
    orange: [],
    teal: [DRAFT],
    generic: [STRATAGEM],
    ...overrides,
  };
  mkdirSync(path.join(dir, 'cards'), { recursive: true });
  for (const [name, list] of Object.entries(files)) {
    const text = typeof list === 'string' ? list : JSON.stringify(list, null, 2);
    writeFileSync(path.join(dir, 'cards', `${name}.json`), text);
  }
  writeFileSync(path.join(dir, 'keywords.json'), JSON.stringify({
    Guardian: 'Must be targeted first.', Shielded: 'Reduces damage by X.', Rush: 'Attacks at once.', Ethereal: 'Immune to combat damage.',
  }));
  writeFileSync(path.join(dir, 'keyword_abilities.json'), JSON.stringify({ Ethereal: ['combat_immune'] }));
}

export function releaseInput(overrides = {}) {
  return {
    catalogVersion: '1.0.0',
    gameVersion: '9.9.9',
    cards: [
      { id: 'f_001', collectible: true },
      { id: 'f_001t', collectible: false },
      { id: 'f_str_001', collectible: true },
      { id: 'f_loc_001', collectible: true },
    ],
    ...overrides,
  };
}

export function writeInput(file, input) {
  writeFileSync(file, JSON.stringify(input, null, 2));
}
