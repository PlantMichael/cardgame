import { DEFAULT_ORIGIN } from './card-winrates.mjs';
export const BOT_STATUS_PATH = '/data/bots/status.json';
const NAMES = { io: 'Io', callisto: 'Callisto', europa: 'Europa', ganymede: 'Ganymede' };
const STATES = ['queued', 'joining', 'playing', 'playing_ai', 'idle', 'reconnecting', 'offline', 'not_started'];
const count = n => Number.isSafeInteger(n) && n >= 0;
const fail = () => { throw new Error('invalid bot status'); };

export function projectBotStatus(data) {
  if (typeof data?.generatedAt !== 'string' || !Number.isFinite(Date.parse(data.generatedAt)) ||
      !Array.isArray(data.bots) || data.bots.length !== 4) fail();
  const seen = new Set();
  const bots = data.bots.map(row => {
    if (!Object.hasOwn(NAMES, row?.id) || seen.has(row.id) || row.name !== NAMES[row.id] ||
        typeof row.version !== 'string' || !/^[A-Za-z0-9._-]{1,32}$/.test(row.version) ||
        !Number.isInteger(row.level) || row.level < 1 || row.level > 10 ||
        !['tempo', 'combo', 'aggro', 'random'].includes(row.style) || !STATES.includes(row.activity)) fail();
    seen.add(row.id);
    let rank = null;
    if (row.activity === 'not_started') { if (row.rank !== null) fail(); }
    else {
      const r = row.rank;
      if (!r || !Number.isInteger(r.bracket) || r.bracket < 0 || r.bracket > 20 ||
          typeof r.inLegend !== 'boolean' || !count(r.legendRating) || !Number.isInteger(r.lp) || r.lp < 0 || r.lp >= 100) fail();
      rank = { bracket: r.bracket, inLegend: r.inLegend, legendRating: r.legendRating, lp: r.lp };
    }
    return { id: row.id, name: NAMES[row.id], version: row.version, level: row.level, style: row.style, activity: row.activity, rank };
  });
  return { generatedAt: data.generatedAt, bots: Object.keys(NAMES).map(id => bots.find(b => b.id === id)) };
}

export async function botStatus({ statsOrigin = DEFAULT_ORIGIN, statsTimeoutMs = 5000 } = {}) {
  const origin = new URL(statsOrigin);
  if (!['http:', 'https:'].includes(origin.protocol) || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash) fail();
  const response = await fetch(new URL(BOT_STATUS_PATH, origin), { redirect: 'error', signal: AbortSignal.timeout(statsTimeoutMs) });
  if (!response.ok || !response.body) { await response.body?.cancel(); throw new Error('unavailable'); }
  const chunks = []; let bytes = 0;
  for await (const chunk of response.body) {
    bytes += chunk.length;
    if (bytes > 32768) throw new Error('too large');
    chunks.push(chunk);
  }
  return projectBotStatus(JSON.parse(Buffer.concat(chunks).toString('utf8')));
}
