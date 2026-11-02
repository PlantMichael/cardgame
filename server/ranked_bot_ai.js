'use strict';
const { PgSettleRepo, computeOutcome } = require('./authoritative/settle');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { deckOf } = require('./deck_matchups');
const published = new Map(JSON.parse(readFileSync(path.join(__dirname, '../catalog/public/data/cards.json'), 'utf8'))
  .cards.filter(c => c.collectible && !c.isToken).map(c => [c.id, c]));
function validBotAIDecks(summary) {
  return [summary.player_deck, summary.opponent_deck].every(ids =>
    ids.length === 40 && deckOf(ids, published)?.factions.length === 1);
}

// Same named-tier mapping as RankedProgress.get_ai_level; sub-ranks share it.
function rankedAILevel(bracket, inLegend) {
  return inLegend ? 10 : 3 + Math.floor(Math.max(0, Math.min(20, bracket)) / 3);
}
async function nextBotAI(pool, playerId) {
  const { rows } = await pool.query(`SELECT ai_match IS NULL AS next_ai FROM ranked_settlements
    WHERE player_id=$1 ORDER BY settled_at DESC,match_id DESC LIMIT 1`, [playerId]);
  return rows[0]?.next_ai ?? true;
}
async function settleBotAI(pool, playerId, matchId, won, aiMatch) {
  const repo = new PgSettleRepo(pool);
  await repo.begin();
  try {
    const player = await repo.loadPlayer(playerId);
    if (!player) throw new Error('missing bot account');
    const next = computeOutcome(player, won, null);
    if (!await repo.claim(matchId, playerId, won, next, aiMatch)) {
      const stored = await repo.storedOutcome(matchId, playerId);
      await repo.commit(); return { success: true, replayed: true, ...stored };
    }
    await repo.apply(playerId, next); await repo.commit();
    return { success: true, ...next };
  } catch (error) { await repo.rollback(); throw error; }
}
module.exports = { rankedAILevel, nextBotAI, settleBotAI, validBotAIDecks };
