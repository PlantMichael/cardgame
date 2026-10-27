// Bounded aggregate-only fetch: the catalog never owns database credentials.
import { readFileSync } from 'node:fs';
import path from 'node:path';

export const STATS_PATH = '/data/v1/stats/card-winrates.json';
export const DEFAULT_ORIGIN = 'https://cardgame-relay-production.up.railway.app';
const MAX_BYTES = 1024 * 1024;

export async function cardWinrates(root, resolvePublicFile, { statsOrigin = DEFAULT_ORIGIN, statsTimeoutMs = 5000 } = {}) {
  const origin = new URL(statsOrigin);
  if (!['http:', 'https:'].includes(origin.protocol) || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash) throw new Error('invalid origin');
  const latest = JSON.parse(readFileSync(path.join(root, 'data/v1/latest.json'), 'utf8'));
  const file = typeof latest.cardsUrl === 'string' ? resolvePublicFile(root, latest.cardsUrl) : null;
  if (!file) throw new Error('invalid catalog');
  const release = JSON.parse(readFileSync(file, 'utf8'));
  if (!Array.isArray(release.cards) || release.catalogVersion !== latest.catalogVersion) throw new Error('invalid catalog');
  const response = await fetch(new URL(STATS_PATH, origin), { redirect: 'error', signal: AbortSignal.timeout(statsTimeoutMs) });
  if (!response.ok || !response.body) { await response.body?.cancel(); throw new Error('unavailable'); }
  const chunks = [];
  let bytes = 0;
  for await (const chunk of response.body) {
    bytes += chunk.length;
    if (bytes > MAX_BYTES) throw new Error('too large');
    chunks.push(chunk);
  }
  const data = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (data.schemaVersion !== 1 || data.catalogVersion !== latest.catalogVersion ||
      typeof data.generatedAt !== 'string' || !Number.isFinite(Date.parse(data.generatedAt)) ||
      !Array.isArray(data.cards) || data.cards.length > 10000) throw new Error('invalid aggregate');
  const counts = new Map();
  for (const row of data.cards) {
    if (typeof row?.id !== 'string' || row.id.length > 128 || counts.has(row.id) ||
        !Number.isSafeInteger(row.matches) || !Number.isSafeInteger(row.wins) || !Number.isSafeInteger(row.losses) ||
        row.matches < 0 || row.wins < 0 || row.losses < 0 || row.wins + row.losses !== row.matches) throw new Error('invalid counts');
    counts.set(row.id, row);
  }
  return { schemaVersion: 1, catalogVersion: latest.catalogVersion, generatedAt: data.generatedAt,
    methodology: { metric: 'starting_deck_inclusion', modes: ['ranked_ai', 'authoritative_pvp'],
      aiSeats: 'human_only', copies: 'once_per_player_game', rulesVersions: 'combined',
      minSample: 1, preliminary: true,
      privacy: 'No raw identities or deck lists. Small sample changes may reveal deck inclusion or outcomes.' },
    cards: release.cards.filter(c => c.collectible === true && c.isToken === false).map(c => {
      const row = counts.get(c.id);
      if (!row) throw new Error('incomplete aggregate');
      const { matches, wins, losses } = row;
      return { id: c.id, matches, wins, losses, winRate: matches ? wins / matches : null };
    }) };
}
