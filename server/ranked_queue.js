'use strict';
// The existing ranked Elo band: deliberately uncapped for every participant.
function ratingBandAt(queuedAt, now) { return 100 + (now - queuedAt) / 1000 * 60; }
function matchQueuedPlayers(queue, startMatch, now = Date.now()) {
  const waiting = [...queue].sort((a, b) => a[1].queuedAt - b[1].queuedAt), matched = new Set();
  for (let i = 0; i < waiting.length; i++) {
    const [wsA, a] = waiting[i];
    if (matched.has(wsA)) continue;
    for (let j = i + 1; j < waiting.length; j++) {
      const [wsB, b] = waiting[j];
      if (matched.has(wsB)) continue;
      const diff = Math.abs(a.rating - b.rating);
      if (diff <= ratingBandAt(a.queuedAt, now) && diff <= ratingBandAt(b.queuedAt, now)) {
        matched.add(wsA); matched.add(wsB); queue.delete(wsA); queue.delete(wsB);
        startMatch(wsA, a, wsB, b); break;
      }
    }
  }
}
module.exports = { ratingBandAt, matchQueuedPlayers };
