'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { loadCards, validateDeck } = require('./authoritative/decks');

const ROOT = path.resolve(__dirname, '..');
const profiles = JSON.parse(fs.readFileSync(path.join(ROOT, 'data/bot_profiles.json'), 'utf8'));
const cards = loadCards();
const published = new Set(JSON.parse(fs.readFileSync(path.join(ROOT, 'catalog/public/data/cards.json'), 'utf8'))
  .cards.filter(c => c.collectible === true && c.isToken === false).map(c => c.id));
const positive = n => Number.isInteger(n) && n > 0 && n <= 1000000;

async function initBotSchema(pool) {
  await pool.query(`CREATE TABLE IF NOT EXISTS bot_matches (
    match_id UUID PRIMARY KEY, result JSONB NOT NULL,
    ended_at TIMESTAMPTZ NOT NULL DEFAULT now()
  )`);
  await pool.query('CREATE INDEX IF NOT EXISTS bot_matches_ended_at ON bot_matches (ended_at)');
}

function participant(p, engineVersion, historical) {
  if (!p || typeof p !== 'object') throw new Error('invalid participant');
  const known = profiles.find(profile => profile.id === p.id);
  if (!known && p.id !== 'standard') throw new Error('invalid bot id');
  if (p.name !== (known?.name ?? 'Standard AI') || !Number.isInteger(p.level) || p.level < 1 || p.level > 10 ||
      typeof p.version !== 'string' || !/^\d{1,6}(?:\.\d{1,6})?$/.test(p.version) ||
      !['tempo', 'combo', 'aggro', 'budget', 'random', ''].includes(p.style)) throw new Error('invalid bot metadata');
  if (!historical && known && ['version', 'level', 'style'].some(key => p[key] !== known[key])) throw new Error('wrong release');
  if (p.id === 'standard' && (p.version !== String(engineVersion) || p.level !== 10 || p.style !== '')) throw new Error('invalid baseline');
  return { id: p.id, name: p.name, version: p.version, level: p.level, style: p.style };
}

function normalizeBotMatch(input, { historical = false } = {}) {
  if (!input || !positive(input.rulesVersion) || !positive(input.engineVersion) || !positive(input.turns) ||
      !Number.isInteger(input.seed) || input.seed < 0 || input.seed > 2147483647 ||
      !['a', 'b'].includes(input.first) || !['a', 'b', 'draw'].includes(input.winner)) throw new Error('invalid finished match');
  const a = participant(input.a, input.engineVersion, historical), b = participant(input.b, input.engineVersion, historical);
  if (a.id === 'standard' && b.id === 'standard') throw new Error('no named bot');
  for (const [deck, faction] of [[input.deckA, input.factionA], [input.deckB, input.factionB]]) {
    if (!validateDeck(deck, faction, cards).ok || deck.length !== 40 || deck.some(id => !published.has(id))) throw new Error('invalid public deck');
  }
  return { a, b, deckA: input.deckA.slice(), deckB: input.deckB.slice(), factionA: input.factionA, factionB: input.factionB,
    first: input.first, winner: input.winner, seed: input.seed, turns: input.turns,
    rulesVersion: input.rulesVersion, engineVersion: input.engineVersion };
}

async function saveBotMatch(pool, id, input, { historical = false } = {}) {
  if (typeof id !== 'string' || !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(id)) throw new Error('invalid match id');
  const result = normalizeBotMatch(input, { historical });
  const saved = await pool.query(`INSERT INTO bot_matches (match_id,result) VALUES ($1,$2)
    ON CONFLICT (match_id) DO UPDATE SET result = bot_matches.result
    WHERE bot_matches.result = EXCLUDED.result RETURNING match_id`, [id, result]);
  if (saved.rowCount !== 1) throw new Error('match id already contains a different result');
}

module.exports = { profiles, initBotSchema, normalizeBotMatch, saveBotMatch, normalizeBotParticipant: participant };
