'use strict';
// Server-side deck loading and validation for server-run matches.
//
// A client NEVER supplies a deck: it names one of its own saved decks, the
// relay reads the card list from the database and checks it here against the
// same card files the game ships (data/cards/*.json). The limits mirror
// DeckManager in scripts/game/deck_manager.gd; a test fails if they drift.
const fs = require('fs');
const path = require('path');

const DATA_DIR = path.join(__dirname, '..', '..', 'data');
const CARD_FILES = ['green', 'crimson', 'black', 'orange', 'teal', 'generic'];
// Mirrors DeckManager.FACTION order (faction_idx 0..4) -> card colour.
const FACTION_COLORS = ['GREEN', 'CRIMSON', 'BLACK', 'ORANGE', 'TEAL'];

// Mirrors DeckManager.MAX_DECK_SIZE / MAX_COPIES / max_copies_for().
const MAX_DECK_SIZE = 40;
const MAX_COPIES = 2;
const MIN_DECK_SIZE = 1;

function loadCards(dataDir = DATA_DIR) {
  const cards = new Map();
  for (const name of CARD_FILES) {
    const list = JSON.parse(fs.readFileSync(path.join(dataDir, 'cards', `${name}.json`), 'utf8'));
    for (const c of list) cards.set(c.id, c);
  }
  return cards;
}

/** The shipped starter decks, by name: a player may queue with one without ever saving it. */
function loadStarters(dataDir = DATA_DIR) {
  const out = new Map();
  for (const d of JSON.parse(fs.readFileSync(path.join(dataDir, 'starters.json'), 'utf8'))) {
    out.set(d.name, { faction_idx: d.faction_idx, card_ids: d.card_ids });
  }
  return out;
}

function maxCopiesFor(card) {
  return card.rarity === 'LEGENDARY' ? 1 : MAX_COPIES;
}

/**
 * Returns { ok: true, cardIds } or { ok: false, error }. `error` is for the
 * audit log and tests, never sent to a client verbatim.
 */
function validateDeck(cardIds, factionIdx, cards) {
  if (!Array.isArray(cardIds)) return { ok: false, error: 'deck_not_a_list' };
  if (cardIds.length < MIN_DECK_SIZE || cardIds.length > MAX_DECK_SIZE) return { ok: false, error: 'deck_size' };
  if (!Number.isInteger(factionIdx) || factionIdx < 0 || factionIdx >= FACTION_COLORS.length) {
    return { ok: false, error: 'deck_faction' };
  }
  const faction = FACTION_COLORS[factionIdx];
  const counts = new Map();
  for (const id of cardIds) {
    if (typeof id !== 'string') return { ok: false, error: 'deck_bad_id' };
    const card = cards.get(id);
    if (!card) return { ok: false, error: 'deck_unknown_card' };
    if (card.is_token) return { ok: false, error: 'deck_token' };
    if (card.color !== faction && card.color !== 'GENERIC') return { ok: false, error: 'deck_wrong_faction' };
    const n = (counts.get(id) || 0) + 1;
    if (n > maxCopiesFor(card)) return { ok: false, error: 'deck_too_many_copies' };
    counts.set(id, n);
  }
  return { ok: true, cardIds: cardIds.slice() };
}

module.exports = { loadCards, loadStarters, validateDeck, maxCopiesFor, MAX_DECK_SIZE, MAX_COPIES, MIN_DECK_SIZE, FACTION_COLORS };
