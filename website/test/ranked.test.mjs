// The Ranked page's numbers must match the real rules: the game's display math
// (scripts/game/ranked_progress.gd) and the server's settlement math (server/ladder.js).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import * as R from '../ranked-data.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const gd = readFileSync(path.join(root, 'scripts/game/ranked_progress.gd'), 'utf8');
const ladderSource = readFileSync(path.join(root, 'server/ladder.js'), 'utf8');
const { nextRankState } = createRequire(import.meta.url)(path.join(root, 'server/ladder.js'));

const gdList = (name) => [...gd.match(new RegExp(`const ${name} := \\[([^\\]]*)\\]`))[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
const gdInt = (name) => Number(gd.match(new RegExp(`const ${name} := (\\d+)`))[1]);
const jsInt = (name) => Number(ladderSource.match(new RegExp(`const ${name} = (\\d+)`))[1]);

test('tier names, divisions and Legend bands match the game', () => {
  assert.deepEqual(R.TIERS.map((t) => t.name), gdList('TIER_NAMES'));
  assert.deepEqual(R.SUB_RANKS, gdList('SUB_RANKS'));
  assert.deepEqual(R.LEGEND_TIERS.map((t) => t.name), gdList('LEGEND_TIER_NAMES'));
  assert.equal(R.DIVISION_COUNT, gdInt('BRACKET_COUNT'));
  assert.equal(R.LEGEND_TIERS[1].from, gdInt('LEGEND_TIER_SPAN'));
  assert.equal(R.LEGEND_TIERS[2].from, gdInt('LEGEND_TIER_SPAN') * 2);
});

test('rank icons are the ones the game uses, in the same order', () => {
  const icons = [...gd.matchAll(/Ranks\/(\d\d-[a-z]+)\.png/g)].map((m) => m[1]);
  assert.deepEqual([...R.TIERS, ...R.LEGEND_TIERS].map((t) => t.icon), icons);
});

test('ladder-point numbers match both the game and the server', () => {
  assert.equal(R.LP.perDivision, gdInt('LP_PER_BRACKET'));
  assert.equal(R.LP.win, gdInt('LP_WIN_BASE'));
  assert.equal(R.LP.winStreak, gdInt('LP_WIN_STREAK'));
  assert.equal(R.LP.winStreakFrom, gdInt('LP_WIN_STREAK_THRESHOLD'));
  assert.equal(R.LP.loss, gdInt('LP_LOSS'));
  assert.equal(R.LP.perDivision, jsInt('RANK_LP_PER_BRACKET'));
  assert.equal(R.LP.win, jsInt('RANK_LP_WIN_BASE'));
  assert.equal(R.LP.winStreak, jsInt('RANK_LP_WIN_STREAK'));
  assert.equal(R.LP.winStreakFrom, jsInt('RANK_LP_WIN_STREAK_THRESHOLD'));
  assert.equal(R.LP.loss, jsInt('RANK_LP_LOSS'));
  assert.equal(R.LEGEND_STEP, jsInt('RANK_LEGEND_RATING_STEP'));
  assert.equal(R.DIVISION_COUNT, jsInt('RANK_BRACKET_COUNT'));
});

test('the worked example is what the server really does', () => {
  const climb = R.exampleClimb(3);
  let player = { rank_bracket: 0, rank_in_legend: false, rank_legend_rating: 0, rank_lp: 0, ranked_win_streak: 0, ranked_wins: 0, ranked_losses: 0 };
  for (let i = 0; i < 3; i++) player = nextRankState(player, true);
  assert.equal(player.rank_bracket, climb.promoted ? 1 : 0);
  assert.equal(player.rank_lp, climb.carried);
  assert.deepEqual(climb.steps.map((s) => s.gain), [34, 34, 45]);
});

test('division names run from Orbital III to Cosmic I', () => {
  assert.equal(R.divisionName(0), 'Orbital III');
  assert.equal(R.divisionName(2), 'Orbital I');
  assert.equal(R.divisionName(R.DIVISION_COUNT - 1), 'Cosmic I');
});

test('a loss never drops a division and Legend steps by 25, as the page says', () => {
  const base = { rank_bracket: 5, rank_in_legend: false, rank_legend_rating: 0, rank_lp: 10, ranked_win_streak: 0, ranked_wins: 0, ranked_losses: 0 };
  const lost = nextRankState(base, false);
  assert.equal(lost.rank_bracket, 5);
  assert.equal(lost.rank_lp, 0);
  const legend = { ...base, rank_in_legend: true, rank_legend_rating: 600 };
  assert.equal(nextRankState(legend, true).rank_legend_rating, 625);
  assert.equal(nextRankState(legend, false).rank_legend_rating, 575);
  const edge = nextRankState({ ...base, rank_bracket: 20, rank_lp: 90 }, true);
  assert.equal(edge.rank_in_legend, true, 'a win from Cosmic I at the top of the bar enters Legend');
});
