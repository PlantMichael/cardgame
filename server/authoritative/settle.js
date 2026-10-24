'use strict';
// Settles a finished server-run ranked match: ladder rank, streak and matchmaking
// Elo, exactly once per player, from the SERVER's own result. Nothing a client
// reports is read here. The math is the existing ladder (ladder.js).
//
// Idempotency is the same device the legacy path uses: a row in
// ranked_settlements keyed (match_id, player_id) is inserted ON CONFLICT DO
// NOTHING, and a conflict means "already settled" - the stored outcome is
// replayed instead of awarding twice.
const { nextRankState, nextElo } = require('../ladder');

// A result settles the ladder only when somebody won by a path that counts.
// Draws, abandons, voids and server faults move nothing (FR-017).
const SETTLING_REASONS = new Set(['completed', 'conceded', 'forfeit_disconnect', 'forfeit_timeout']);

function shouldSettle(winner, endReason) {
  return (winner === 'a' || winner === 'b') && SETTLING_REASONS.has(endReason);
}

/** Pure: the next ladder row for one player given the server's result. */
function computeOutcome(playerRow, won, opponentRating) {
  const next = nextRankState(playerRow, won);
  next.rating = opponentRating !== null && opponentRating !== undefined
    ? nextElo(playerRow.rating, opponentRating, won)
    : playerRow.rating;
  return next;
}

/** Postgres repository for settlement; replaced by an in-memory one in tests. */
class PgSettleRepo {
  constructor(pool) { this.pool = pool; }
  async begin() {
    this.client = await this.pool.connect();
    await this.client.query('BEGIN');
  }
  async commit() { await this.client.query('COMMIT'); this.client.release(); this.client = null; }
  async rollback() {
    if (!this.client) return;
    try { await this.client.query('ROLLBACK'); } finally { this.client.release(); this.client = null; }
  }
  async loadPlayer(id) {
    const { rows } = await this.client.query(
      `SELECT id, username, rating, rank_bracket, rank_in_legend, rank_legend_rating, rank_lp,
              ranked_win_streak, ranked_wins, ranked_losses
       FROM players WHERE id = $1 FOR UPDATE`, [id]);
    return rows[0] || null;
  }
  async claim(matchId, playerId, won, outcome) {
    const { rows } = await this.client.query(
      `INSERT INTO ranked_settlements (match_id, player_id, won, outcome)
       VALUES ($1, $2, $3, $4) ON CONFLICT (match_id, player_id) DO NOTHING RETURNING match_id`,
      [matchId, playerId, won, JSON.stringify(outcome)]);
    return rows.length > 0;
  }
  async storedOutcome(matchId, playerId) {
    const { rows } = await this.client.query(
      'SELECT outcome FROM ranked_settlements WHERE match_id = $1 AND player_id = $2', [matchId, playerId]);
    return rows[0] ? rows[0].outcome : null;
  }
  async apply(playerId, next) {
    await this.client.query(
      `UPDATE players
       SET rank_bracket = $1, rank_in_legend = $2, rank_legend_rating = $3, rank_lp = $4,
           ranked_win_streak = $5, ranked_wins = $6, ranked_losses = $7, rating = $8
       WHERE id = $9`,
      [next.rank_bracket, next.rank_in_legend, next.rank_legend_rating, next.rank_lp,
        next.ranked_win_streak, next.ranked_wins, next.ranked_losses, next.rating, playerId]);
  }
}

/**
 * @param repo       a PgSettleRepo (or test double)
 * @param match      { matchId, seats: { a: playerId, b: playerId }, winner: 'a'|'b'|null, endReason }
 * @returns          { [playerId]: outcome } - empty when nothing settles
 */
async function settleRankedMatch(repo, match) {
  if (!shouldSettle(match.winner, match.endReason)) return {};
  await repo.begin();
  try {
    const rows = { a: await repo.loadPlayer(match.seats.a), b: await repo.loadPlayer(match.seats.b) };
    if (!rows.a || !rows.b) { await repo.rollback(); return {}; }
    const out = {};
    for (const letter of ['a', 'b']) {
      const row = rows[letter];
      const opp = rows[letter === 'a' ? 'b' : 'a'];
      const won = match.winner === letter;
      const next = computeOutcome(row, won, opp.rating);
      const claimed = await repo.claim(match.matchId, row.id, won, next);
      if (!claimed) {
        // Settled before (a retry after a crash): replay what was awarded.
        out[row.id] = { success: true, replayed: true, ...(await repo.storedOutcome(match.matchId, row.id)) };
        continue;
      }
      await repo.apply(row.id, next);
      out[row.id] = { success: true, ...next };
    }
    await repo.commit();
    return out;
  } catch (e) {
    await repo.rollback();
    throw e;
  }
}

/** The callback MatchManager takes: derives the settlement from the finished session. */
function makeSettler(pool, RepoClass = PgSettleRepo) {
  return (sess, result) => settleRankedMatch(new RepoClass(pool), {
    matchId: sess.id,
    seats: { a: sess.seats.a.playerId, b: sess.seats.b.playerId },
    winner: result.winner,
    endReason: result.endReason,
  });
}

module.exports = { settleRankedMatch, computeOutcome, shouldSettle, makeSettler, PgSettleRepo, SETTLING_REASONS };
