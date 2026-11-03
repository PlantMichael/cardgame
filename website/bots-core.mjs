import { TIERS, SUB_RANKS, LEGEND_TIERS, LP, divisionName } from './ranked-data.mjs';
export const BOT_NAMES = { io: 'Io', callisto: 'Callisto', europa: 'Europa', ganymede: 'Ganymede', amalthea: 'Amalthea' };
export const ACTIVITIES = { queued: 'Queued for ranked', joining: 'Joining a match', playing: 'Playing ranked',
  playing_ai: 'Playing ranked AI', idle: 'Between matches', reconnecting: 'Reconnecting', offline: 'Offline', not_started: 'Not started' };
export function validStatus(data) {
  if (typeof data?.generatedAt !== 'string' || !Number.isFinite(Date.parse(data.generatedAt)) ||
      !Array.isArray(data.bots) || data.bots.length !== Object.keys(BOT_NAMES).length) return false;
  const seen = new Set();
  return data.bots.every(b => {
    if (!Object.hasOwn(BOT_NAMES, b?.id) || seen.has(b.id) || b.name !== BOT_NAMES[b.id] ||
        !Object.hasOwn(ACTIVITIES, b.activity) || typeof b.version !== 'string' || !/^[A-Za-z0-9._-]{1,32}$/.test(b.version) ||
        !Number.isInteger(b.level) || b.level < 1 || b.level > 10 || !['tempo','combo','aggro','budget','random',''].includes(b.style)) return false;
    seen.add(b.id);
    if (b.activity === 'not_started') return b.rank === null;
    const r = b.rank;
    return r && Number.isInteger(r.bracket) && r.bracket >= 0 && r.bracket < TIERS.length * SUB_RANKS.length &&
      typeof r.inLegend === 'boolean' && Number.isSafeInteger(r.legendRating) && r.legendRating >= 0 &&
      Number.isInteger(r.lp) && r.lp >= 0 && r.lp < LP.perDivision;
  });
}
export function rankDisplay(rank) {
  if (!rank) return { name: 'Not ranked yet', progress: '', icon: null };
  if (rank.inLegend) {
    const tier = LEGEND_TIERS.find(t => rank.legendRating >= t.from && (t.to === null || rank.legendRating <= t.to));
    return { name: tier.name, progress: `${rank.legendRating.toLocaleString()} Legend points`, icon: tier.icon };
  }
  return { name: divisionName(rank.bracket), progress: `${rank.lp} / ${LP.perDivision} LP`,
    icon: TIERS[Math.floor(rank.bracket / SUB_RANKS.length)].icon };
}
