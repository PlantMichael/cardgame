'use strict';
// Optional observational telemetry: malformed counts never invalidate a result.
const MAX_PLAYS = 1000000;
function normalizeCardPlays(input, cardIds) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const entries = Object.entries(input);
  if (entries.length > 10000) return null;
  const counts = {};
  let total = 0;
  for (const [id, count] of entries) {
    if (id.length > 128 || !Number.isSafeInteger(count) || count < 0 || count > MAX_PLAYS) return null;
    total += count;
    if (total > MAX_PLAYS) return null;
    if (cardIds.has(id)) counts[id] = count;
  }
  return counts;
}
module.exports = { MAX_PLAYS, normalizeCardPlays };
