'use strict';
// Settlement (SC-005): the ladder moves once, by the existing ladder rules, from
// the server's own result. Runs against an in-memory repository - no database.
const test = require('node:test');
const assert = require('node:assert/strict');
const { settleRankedMatch, computeOutcome, shouldSettle } = require('../authoritative/settle');
const { nextRankState, nextElo } = require('../ladder');

function player(id, over = {}) {
  return {
    id, username: `p${id}`, rating: 1000, rank_bracket: 0, rank_in_legend: false, rank_legend_rating: 0,
    rank_lp: 0, ranked_win_streak: 0, ranked_wins: 0, ranked_losses: 0, ...over,
  };
}

class MemRepo {
  constructor(players, settlements = new Map()) {
    this.players = players;
    this.settlements = settlements;
    this.began = 0; this.committed = 0; this.rolledBack = 0;
  }
  async begin() { this.began += 1; this.snapshot = JSON.stringify([...this.players]); }
  async commit() { this.committed += 1; }
  async rollback() { this.rolledBack += 1; this.players = new Map(JSON.parse(this.snapshot)); }
  async loadPlayer(id) { return this.players.get(id) ? { ...this.players.get(id) } : null; }
  async claim(matchId, playerId, won, outcome) {
    const key = `${matchId}:${playerId}`;
    if (this.settlements.has(key)) return false;
    this.settlements.set(key, outcome);
    return true;
  }
  async storedOutcome(matchId, playerId) { return this.settlements.get(`${matchId}:${playerId}`); }
  async apply(playerId, next) { this.players.set(playerId, { ...this.players.get(playerId), ...next }); }
}

const match = (over = {}) => ({ matchId: 'rk_1', seats: { a: 1, b: 2 }, winner: 'a', endReason: 'completed', ...over });

test('a win and a loss settle once, using the existing ladder and Elo math', async () => {
  const repo = new MemRepo(new Map([[1, player(1)], [2, player(2, { rating: 1100, rank_lp: 50 })]]));
  const out = await settleRankedMatch(repo, match());
  const w = nextRankState(player(1), true);
  const l = nextRankState(player(2, { rating: 1100, rank_lp: 50 }), false);
  assert.equal(out[1].rank_lp, w.rank_lp);
  assert.equal(out[1].ranked_wins, 1);
  assert.equal(out[2].rank_lp, l.rank_lp);
  assert.equal(out[2].ranked_losses, 1);
  assert.equal(out[1].rating, nextElo(1000, 1100, true));
  assert.equal(out[2].rating, nextElo(1100, 1000, false));
  assert.equal(repo.players.get(1).ranked_wins, 1, 'the player rows were updated');
  assert.equal(repo.committed, 1);
});

test('settling the same match again replays the stored outcome and awards nothing', async () => {
  const repo = new MemRepo(new Map([[1, player(1)], [2, player(2)]]));
  const first = await settleRankedMatch(repo, match());
  const second = await settleRankedMatch(repo, match());
  assert.equal(second[1].replayed, true);
  assert.equal(second[1].rank_lp, first[1].rank_lp);
  assert.equal(repo.players.get(1).ranked_wins, 1, 'one win, not two');
  assert.equal(repo.players.get(2).ranked_losses, 1);
});

test('draws, abandoned, voided and fault endings change nothing', async () => {
  for (const [winner, endReason] of [[null, 'completed'], ['a', 'abandoned'], ['a', 'voided_fault'], [null, 'abandoned'], ['a', 'unknown']]) {
    const repo = new MemRepo(new Map([[1, player(1)], [2, player(2)]]));
    assert.deepEqual(await settleRankedMatch(repo, match({ winner, endReason })), {}, `${winner}/${endReason}`);
    assert.equal(repo.began, 0, 'not even a transaction was opened');
    assert.equal(repo.settlements.size, 0);
  }
});

test('forfeits and concessions settle as ordinary wins and losses', async () => {
  for (const endReason of ['conceded', 'forfeit_disconnect', 'forfeit_timeout']) {
    const repo = new MemRepo(new Map([[1, player(1)], [2, player(2)]]));
    const out = await settleRankedMatch(repo, match({ winner: 'b', endReason }));
    assert.equal(out[2].ranked_wins, 1, endReason);
    assert.equal(out[1].ranked_losses, 1, endReason);
  }
});

test('a failure rolls the whole settlement back', async () => {
  const repo = new MemRepo(new Map([[1, player(1)], [2, player(2)]]));
  repo.apply = async () => { throw new Error('disk full'); };
  await assert.rejects(settleRankedMatch(repo, match()), /disk full/);
  assert.equal(repo.rolledBack, 1);
  assert.equal(repo.players.get(1).ranked_wins, 0);
});

test('a missing player settles nothing', async () => {
  const repo = new MemRepo(new Map([[1, player(1)]]));
  assert.deepEqual(await settleRankedMatch(repo, match()), {});
  assert.equal(repo.rolledBack, 1);
});

test('shouldSettle and computeOutcome are pure', () => {
  assert.equal(shouldSettle('a', 'completed'), true);
  assert.equal(shouldSettle(null, 'completed'), false);
  assert.equal(computeOutcome(player(1), true, null).rating, 1000, 'no opponent rating -> Elo unchanged');
});
