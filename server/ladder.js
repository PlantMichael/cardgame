'use strict';
// The ranked ladder and matchmaking-Elo math, extracted verbatim from relay.js so
// the same functions settle legacy results and server-run matches (spec 003).
// Do not change the math here without changing ranked_progress.gd to match.

// --- Ranked ladder (mirrors scripts/game/ranked_progress.gd's display math;
// keep BRACKET_COUNT/LP constants in sync with that file) ------------------

const RANK_BRACKET_COUNT = 21; // 7 named tiers x 3 sub-ranks (Orbital III .. Cosmic I)
const RANK_LEGEND_RATING_STEP = 25;
const LEGEND_TIER_SPAN = 500; // rating span of the Superluminal (lowest legend) band

// LP economy for the bracketed ladder (Orbital III .. Cosmic I). A win/loss
// never demotes a bracket here — a loss just floors LP at 0 — so there's no
// tier-floor protection to track any more (that only mattered when losses
// could drop you back a bracket).
const RANK_LP_PER_BRACKET = 100;
const RANK_LP_WIN_BASE = 34;
const RANK_LP_WIN_STREAK = 45; // 3rd win-in-a-row and every win after, until a loss
const RANK_LP_WIN_STREAK_THRESHOLD = 3;
const RANK_LP_LOSS = 20;

// Pure function: given the player's current rank row and whether they just
// won, returns the next rank state. Kept server-side and authoritative (the
// client only ever sends a boolean `won`) so the persisted ladder position
// can't just be dictated by the client.
//
// Legend (Superluminal/Celestial/Universal) keeps its own separate
// continuous-rating system, unaffected by the LP economy above, *except*:
// a loss that would push legend rating below 0 while still in the lowest
// band (Superluminal) demotes the player out of Legend entirely, back to
// Cosmic I — landing LP carries the negative overflow the same way bracket
// promotion/demotion does, floored at 0.
function nextRankState(player, won) {
  let bracket = player.rank_bracket;
  let inLegend = player.rank_in_legend;
  let legendRating = player.rank_legend_rating;
  let lp = player.rank_lp;
  let winStreak = player.ranked_win_streak;
  let rankedWins = player.ranked_wins;
  let rankedLosses = player.ranked_losses;
  if (won) {
    rankedWins += 1;
    winStreak += 1;
    if (inLegend) {
      legendRating += RANK_LEGEND_RATING_STEP;
    } else {
      const gain = winStreak >= RANK_LP_WIN_STREAK_THRESHOLD ? RANK_LP_WIN_STREAK : RANK_LP_WIN_BASE;
      lp += gain;
      if (lp >= RANK_LP_PER_BRACKET) {
        const overflow = lp - RANK_LP_PER_BRACKET;
        if (bracket >= RANK_BRACKET_COUNT - 1) {
          inLegend = true;
          legendRating = overflow;
          lp = 0;
        } else {
          bracket += 1;
          lp = overflow;
        }
      }
    }
  } else {
    rankedLosses += 1;
    winStreak = 0;
    if (inLegend) {
      const next = legendRating - RANK_LEGEND_RATING_STEP;
      if (next < 0 && legendRating < LEGEND_TIER_SPAN) {
        // Demoted out of Legend back to Cosmic I, carrying the overflow.
        inLegend = false;
        bracket = RANK_BRACKET_COUNT - 1;
        lp = Math.max(0, RANK_LP_PER_BRACKET + next);
      } else {
        legendRating = Math.max(0, next);
      }
    } else {
      lp = Math.max(0, lp - RANK_LP_LOSS);
    }
  }
  return {
    rank_bracket: bracket, rank_in_legend: inLegend, rank_legend_rating: legendRating,
    rank_lp: lp, ranked_win_streak: winStreak,
    ranked_wins: rankedWins, ranked_losses: rankedLosses,
  };
}

// --- Matchmaking Elo (`players.rating`) ------------------------------------
//
// This is intentionally separate from the bracket/Legend ladder above: the
// ladder (rank_bracket/rank_in_legend/rank_legend_rating) is the single
// progression every player sees on the Ranked menu regardless of whether
// they played a bot or a human, while `rating` is an invisible Elo used only
// to pair players of similar skill in matchmaking (see the ranked queue
// below). Bot matches never touch it — there's no opponent account to rate
// against.
const ELO_K = 32;

function nextElo(rating, opponentRating, won) {
  const expected = 1 / (1 + Math.pow(10, (opponentRating - rating) / 400));
  return Math.max(100, Math.round(rating + ELO_K * ((won ? 1 : 0) - expected)));
}

module.exports = { nextRankState, nextElo, RANK_BRACKET_COUNT, LEGEND_TIER_SPAN };
