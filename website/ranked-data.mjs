// The ranked ladder as the game and server define it. A test (ranked.test.mjs)
// compares every number here with scripts/game/ranked_progress.gd and
// server/ladder.js, so this page cannot drift from the real rules.

export const TIERS = [
  { name: 'Orbital', icon: '01-orbital', color: '#8c857a' },
  { name: 'Lunar', icon: '02-lunar', color: '#8c9fad' },
  { name: 'Planetary', icon: '03-planetary', color: '#599e59' },
  { name: 'Solar', icon: '04-solar', color: '#d9a633' },
  { name: 'Nebular', icon: '05-nebular', color: '#8c59bf' },
  { name: 'Galactic', icon: '06-galactic', color: '#408cd9' },
  { name: 'Cosmic', icon: '07-cosmic', color: '#d94040' },
];
export const SUB_RANKS = ['III', 'II', 'I']; // III lowest, I highest within a tier
export const LEGEND_TIERS = [
  { name: 'Superluminal', icon: '08-superluminal', color: '#d9d9f2', from: 0, to: 499 },
  { name: 'Celestial', icon: '09-celestial', color: '#ffd600', from: 500, to: 999 },
  { name: 'Universal', icon: '10-universal', color: '#f259d9', from: 1000, to: null },
];
export const LP = { perDivision: 100, win: 34, winStreak: 45, winStreakFrom: 3, loss: 20 };
export const LEGEND_STEP = 25;
export const DIVISION_COUNT = TIERS.length * SUB_RANKS.length;
export const MATCH_SEARCH_SECONDS = 10;
export const REWARDS = { rankUpCyllats: 75, dailyFirstWinGlimmer: 50 };

/** "Orbital III" ... "Cosmic I" for division index 0..20. */
export function divisionName(index) {
  return `${TIERS[Math.floor(index / SUB_RANKS.length)].name} ${SUB_RANKS[index % SUB_RANKS.length]}`;
}

/** The example climb shown on the page, computed from the same constants. */
export function exampleClimb(wins = 3) {
  let lp = 0; let streak = 0; const steps = [];
  for (let i = 0; i < wins; i++) {
    streak += 1;
    const gain = streak >= LP.winStreakFrom ? LP.winStreak : LP.win;
    lp += gain;
    steps.push({ win: i + 1, gain, total: lp });
  }
  return { steps, promoted: lp >= LP.perDivision, carried: Math.max(0, lp - LP.perDivision) };
}
