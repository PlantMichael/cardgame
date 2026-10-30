'use strict';
// Completed local AI summaries are useful for testing, but never verified PvP.
// Reuse deck-size bounds; cardIds is the relay's map of shipped non-token cards.
const { MIN_DECK_SIZE, MAX_DECK_SIZE } = require('./authoritative/decks');

// Project only bounded, known fields. Labels and account identity are server-owned.
function normalizeAIRecord(input, matchId, cardIds) {
  if (!/^ai_\d+_\d+$/.test(matchId) || matchId.length > 96) return null;
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const integer = (value, min, max) => Number.isInteger(value) && value >= min && value <= max;
  if (!integer(input.ai_level, 1, 10) || !integer(input.turns, 1, 1000000)
      || !integer(input.rules_version, 1, 1000000)) return null;
  for (const deck of [input.player_deck, input.opponent_deck]) {
    if (!Array.isArray(deck) || deck.length < MIN_DECK_SIZE || deck.length > MAX_DECK_SIZE) return null;
    if (deck.some((id) => typeof id !== 'string' || !cardIds.has(id))) return null;
  }
  if (input.ai_version !== undefined && !integer(input.ai_version, 1, 1000000)) return null;
  if (input.first_player !== undefined && !['player', 'opponent'].includes(input.first_player)) return null;
  return {
    mode: 'ranked_ai', source: 'client_reported',
    player_deck: input.player_deck.slice(), opponent_deck: input.opponent_deck.slice(),
    ai_level: input.ai_level, turns: input.turns, rules_version: input.rules_version,
    ...(input.ai_version === undefined ? {} : { ai_version: input.ai_version }),
    ...(input.first_player === undefined ? {} : { first_player: input.first_player }),
  };
}

module.exports = { normalizeAIRecord };
