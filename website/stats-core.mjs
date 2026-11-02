// Pure logic for the Stats tab: cohort/URL handling, number formatting, and the
// joins over a deck-matchups snapshot. No DOM and no network, so the same file
// runs in the browser (stats.js) and under node --test.
//
// Contract: catalog/stats-website-spec.md on the API branch (e3c9c9e). Rates and
// interval bounds are fractions. A deck is identified by id AND role.

export const MODES = { all: 'Combined results', ranked_ai: 'Against AI', authoritative_pvp: 'Against players' };
export const SERVER_PARAMS = ['mode', 'days', 'rulesVersion', 'aiVersion', 'aiLevel'];
export const DEFAULT_COHORT = { mode: 'all', days: '30', rulesVersion: 'latest' };
export const FACTION_NAMES = { GREEN: 'Sapiens', CRIMSON: 'Moonlight Coven', BLACK: 'Junklings', ORANGE: 'Gundari', TEAL: 'Mokotai', GENERIC: 'Generic' };

const VERSION = /^(latest|unknown|[1-9][0-9]{0,5}|1000000)$/;

// ---- cohort <-> URL ---------------------------------------------------------

/** A usable cohort from any URLSearchParams-like input; invalid values fall back to defaults. */
export function cohortFromParams(params) {
  const get = (k) => params.get(k);
  const mode = get('mode') in MODES ? get('mode') : DEFAULT_COHORT.mode;
  const daysRaw = get('days');
  const days = /^[1-9][0-9]{0,2}$/.test(daysRaw || '') && Number(daysRaw) <= 365 ? daysRaw : DEFAULT_COHORT.days;
  const rulesVersion = VERSION.test(get('rulesVersion') || '') ? get('rulesVersion') : DEFAULT_COHORT.rulesVersion;
  const cohort = { mode, days, rulesVersion };
  if (mode === 'ranked_ai') {
    cohort.aiVersion = VERSION.test(get('aiVersion') || '') ? get('aiVersion') : 'latest';
    const level = get('aiLevel');
    cohort.aiLevel = /^([1-9]|10)$/.test(level || '') ? level : '10';
  }
  return cohort;
}

/** The ONLY query keys the server accepts; AI keys are removed for PvP. */
export function serverQuery(cohort) {
  const q = new URLSearchParams();
  q.set('mode', cohort.mode);
  q.set('days', String(cohort.days));
  q.set('rulesVersion', String(cohort.rulesVersion));
  if (cohort.mode === 'ranked_ai') {
    q.set('aiVersion', String(cohort.aiVersion));
    q.set('aiLevel', String(cohort.aiLevel));
  }
  return q;
}

export function apiUrl(origin, cohort) {
  const url = new URL('/data/stats/deck-matchups.json', origin);
  url.search = serverQuery(cohort).toString();
  return url.toString();
}

/** Everything the page remembers in its address: the cohort plus view state. */
export const VIEW_KEYS = ['view', 'deck', 'role', 'opp', 'oppRole', 'faction', 'q', 'x', 'min', 'sort', 'dir', 'who', 'rows', 'cols', 'demo'];

export function routeFromSearch(search) {
  const params = new URLSearchParams(search);
  const view = ['explorer', 'deck', 'matrix', 'cards'].includes(params.get('view')) ? params.get('view') : 'explorer';
  const cohort = cohortFromParams(params);
  const role = (r, fallback) => (['human', 'ai', 'combined'].includes(r) ? r : fallback);
  const ownRole = cohort.mode === 'all' ? 'combined' : 'human';
  const enemyRole = cohort.mode === 'all' ? 'combined' : cohort.mode === 'ranked_ai' ? 'ai' : 'human';
  const min = /^[0-9]{1,6}$/.test(params.get('min') || '') ? Number(params.get('min')) : 1;
  return {
    cohort, view,
    deck: params.get('deck') || '', role: role(params.get('role'), ownRole),
    opp: params.get('opp') || '', oppRole: role(params.get('oppRole'), enemyRole),
    faction: (params.get('faction') || '').toUpperCase(), q: params.get('q') || '', x: params.get('x') || '',
    min: Math.max(1, min), sort: params.get('sort') || (view === 'cards' ? 'timesPlayed' : 'matches'), dir: params.get('dir') === 'asc' ? 'asc' : 'desc',
    who: cohort.mode === 'all' ? 'combined' : params.get('who') === 'ai' ? 'ai' : 'human',
    rows: clampInt(params.get('rows'), 3, 25, 8), cols: clampInt(params.get('cols'), 3, 25, 8),
    demo: params.get('demo') === '1',
  };
}

function clampInt(raw, lo, hi, fallback) {
  return /^[0-9]{1,3}$/.test(raw || '') ? Math.min(hi, Math.max(lo, Number(raw))) : fallback;
}

/** Search string for a route; defaults are omitted so shared links stay short and stable. */
export function searchFromRoute(route) {
  const q = serverQuery(route.cohort);
  const ownRole = route.cohort.mode === 'all' ? 'combined' : 'human';
  const enemyRole = route.cohort.mode === 'all' ? 'combined' : route.cohort.mode === 'ranked_ai' ? 'ai' : 'human';
  const set = (k, v, def) => { if (v !== undefined && v !== '' && v !== def) q.set(k, String(v)); };
  set('view', route.view, 'explorer');
  if (route.view === 'deck' || route.view === 'matrix') {
    set('deck', route.deck); set('role', route.role, ownRole);
    set('opp', route.opp); if (route.opp) set('oppRole', route.oppRole, enemyRole);
  }
  if (route.view === 'explorer') {
    set('who', route.who, ownRole); set('faction', route.faction); set('q', route.q); set('x', route.x);
    set('min', route.min, 1); set('sort', route.sort, 'matches'); set('dir', route.dir, 'desc');
  }
  if (route.view === 'cards') { set('faction', route.faction); set('q', route.q); set('sort', route.sort, 'timesPlayed'); set('dir', route.dir, 'desc'); }
  if (route.view === 'matrix') { set('rows', route.rows, 8); set('cols', route.cols, 8); }
  if (route.demo) q.set('demo', '1');
  return `?${q.toString()}`;
}

// ---- numbers ------------------------------------------------------------------

/** 2 wins of 3 is 66.7%: rates are fractions, never already percentages. */
export function pct(fraction, digits = 1) {
  return typeof fraction === 'number' && Number.isFinite(fraction) ? `${(fraction * 100).toFixed(digits)}%` : '—';
}
export function interval(range) {
  return range && Number.isFinite(range.lower) && Number.isFinite(range.upper) ? `${pct(range.lower)}–${pct(range.upper)}` : '—';
}
export const record = (row) => `${row.wins}–${row.losses}`;
export const turns = (row) => (typeof row.averageTurns === 'number' ? row.averageTurns.toFixed(1) : '—');
export const shortId = (id) => String(id).slice(0, 8);

export function factionLabel(deck) {
  const names = (deck.factions || []).map((f) => FACTION_NAMES[f] || f);
  return names.length ? names.join(' / ') : 'Unknown';
}
/** Public results omit saved deck names. Number distinct lists within a faction,
 * using the same label for the same list in either role. IDs still own links. */
export function deckLabels(decks) {
  const groups = new Map();
  for (const deck of decks) {
    const faction = factionLabel(deck);
    if (!groups.has(faction)) groups.set(faction, new Set());
    groups.get(faction).add(deck.id);
  }
  const labels = new Map();
  for (const [faction, ids] of groups) {
    const variants = [...ids].sort();
    variants.forEach((id, i) => labels.set(id, `${faction} deck${variants.length > 1 ? ` ${i + 1}` : ''}`));
  }
  return labels;
}
export function deckLabel(deck, labels) {
  return labels?.get(deck.id) || `${factionLabel(deck)} deck`;
}
export const deckKey = (id, role) => `${id}/${role}`;
export const cardCount = (deck) => deck.cards.reduce((n, c) => n + c.copies, 0);

// ---- validation -----------------------------------------------------------------

const isCount = (n) => Number.isSafeInteger(n) && n >= 0;
function validRow(r) {
  return r && isCount(r.matches) && isCount(r.wins) && isCount(r.losses) && r.wins + r.losses === r.matches;
}

/** Reject anything that is not a snapshot of the documented shape, instead of rendering guesses. */
export function validateSnapshot(s) {
  if (!s || typeof s !== 'object' || !s.filters || !s.availableFilters || !s.methodology) return false;
  if (!isCount(s.games) || !Array.isArray(s.decks) || !Array.isArray(s.matchups)) return false;
  if (typeof s.generatedAt !== 'string' || Number.isNaN(Date.parse(s.generatedAt))) return false;
  const roles = s.filters.mode === 'all' ? ['combined'] : s.filters.mode === 'authoritative_pvp' ? ['human'] : ['human','ai'];
  const compositionOk = xs => Array.isArray(xs) && xs.length > 0 && xs.length <= 40
    && xs.every(c=>typeof c?.id==='string' && Number.isInteger(c.copies) && c.copies>=1 && c.copies<=2)
    && new Set(xs.map(c=>c.id)).size===xs.length && xs.reduce((n,c)=>n+c.copies,0)<=40;
  const deckOk = (d) => d && typeof d.id === 'string' && roles.includes(d.role) && compositionOk(d.cards) && validRow(d);
  const matchOk = (m) => m && typeof m.deckId === 'string' && typeof m.opponentDeckId === 'string'
    && roles.includes(m.role) && roles.includes(m.opponentRole) && validRow(m);
  if (s.playStats !== undefined) {
    const p = s.playStats;
    if (!p || p.totalSeats !== s.games*2 || !isCount(p.trackedSeats) || !isCount(p.completeSeats)
        || p.completeSeats > p.trackedSeats || p.trackedSeats > p.totalSeats || !Array.isArray(p.cards)) return false;
    const ids = new Set(); let plays = 0;
    for (const c of p.cards) {
      if (typeof c?.id !== 'string' || ids.has(c.id) || !isCount(c.plays)) return false;
      ids.add(c.id); plays += c.plays;
    }
    if (plays > p.trackedSeats*1000000 || (!p.trackedSeats && p.cards.length)) return false;
  }
  return s.decks.every(deckOk) && s.matchups.every(matchOk);
}

// ---- joins ----------------------------------------------------------------------

export function indexSnapshot(snapshot) {
  const byKey = new Map(snapshot.decks.map((d) => [deckKey(d.id, d.role), d]));
  const matchByKey = new Map(snapshot.matchups.map((m) => [`${deckKey(m.deckId, m.role)}>${deckKey(m.opponentDeckId, m.opponentRole)}`, m]));
  // Share of recorded human seat-games: the denominator is every human deck row, before any local filtering.
  const humanSeatGames = snapshot.decks.filter((d) => d.role === 'human').reduce((n, d) => n + d.matches, 0);
  return { byKey, matchByKey, humanSeatGames, labels: deckLabels(snapshot.decks) };
}

export function findDeck(index, id, role) {
  return index.byKey.get(deckKey(id, role)) || null;
}

/** Opponent rows for one deck, joined to the opponent's own deck record (may be null if absent). */
export function opponentsOf(snapshot, index, deck) {
  return snapshot.matchups
    .filter((m) => m.deckId === deck.id && m.role === deck.role)
    .map((m) => ({ matchup: m, opponent: index.byKey.get(deckKey(m.opponentDeckId, m.opponentRole)) || null }));
}

export function shareOfHumanSeatGames(index, deck) {
  return deck.role === 'human' && index.humanSeatGames > 0 ? deck.matches / index.humanSeatGames : null;
}

/** Cards by id from the printed catalog. */
export function cardsById(catalog) {
  return new Map((catalog.cards || []).map((c) => [c.id, c]));
}

/** Mana curve from the full composition: copies per cost, costs 7+ pooled. */
export function manaCurve(deck, cards) {
  const buckets = Array(8).fill(0);
  for (const { id, copies } of deck.cards) {
    const cost = cards.get(id)?.manaCost;
    if (typeof cost === 'number') buckets[Math.min(Math.max(cost, 0), 7)] += copies;
  }
  return buckets;
}

// ---- explorer filtering and sorting ---------------------------------------------------

const names = (deck, cards) => deck.cards.map((c) => (cards.get(c.id)?.name || c.id).toLowerCase());

export function filterDecks(snapshot, cards, route, labels = deckLabels(snapshot.decks)) {
  const q = route.q.trim().toLowerCase();
  const x = route.x.trim().toLowerCase();
  return snapshot.decks.filter((d) => {
    if (d.role !== route.who) return false;
    if (d.matches < route.min) return false;
    if (route.faction && !(d.factions || []).includes(route.faction)) return false;
    const n = names(d, cards);
    if (q && ![deckLabel(d, labels).toLowerCase(), ...n].some((name) => name.includes(q))) return false;
    if (x && n.some((name) => name.includes(x))) return false;
    return true;
  });
}

const SORTERS = {
  matches: (d) => d.matches,
  winRate: (d) => d.winRate,
  testers: (d) => d.testers,
  turns: (d) => (typeof d.averageTurns === 'number' ? d.averageTurns : -1),
  lower: (d) => d.winRateInterval?.lower ?? -1,
};
export const SORT_KEYS = Object.keys(SORTERS);

export function sortDecks(decks, sort, dir) {
  const pick = SORTERS[sort] || SORTERS.matches;
  const sign = dir === 'asc' ? 1 : -1;
  // Ties fall back to sample size, then id, so the order is stable between renders.
  return [...decks].sort((a, b) => sign * (pick(a) - pick(b)) || b.matches - a.matches || a.id.localeCompare(b.id));
}

// ---- matrix -------------------------------------------------------------------------------

/**
 * Rows are the row deck's outcome against each column deck. A pair with no
 * recorded matchup is `null` ("No games"), never 0% or 50%.
 */
export function buildMatrix(snapshot, rowDecks, colDecks) {
  const index = indexSnapshot(snapshot);
  return rowDecks.map((row) => colDecks.map((col) => index.matchByKey.get(`${deckKey(row.id, row.role)}>${deckKey(col.id, col.role)}`) || null));
}

/** The decks a matrix starts from: most played first. AI mode is human rows vs AI columns; PvP is human vs human. */
export function matrixAxes(snapshot, mode, rows, cols) {
  const byPlays = (list) => [...list].sort((a, b) => b.matches - a.matches || a.id.localeCompare(b.id));
  const human = byPlays(snapshot.decks.filter((d) => d.role === (mode === 'all' ? 'combined' : 'human')));
  const ai = byPlays(snapshot.decks.filter((d) => d.role === 'ai'));
  return { rowDecks: human.slice(0, rows), colDecks: (mode === 'ranked_ai' ? ai : human).slice(0, cols) };
}

/** Heat bucket 0-5 for colour; the number is always printed beside it. */
export function heat(rate) {
  if (typeof rate !== 'number') return -1;
  return Math.min(5, Math.floor(rate * 6));
}

// Metrics use deck appearances (one per seat-game), never unweighted list averages.
export function cardMetrics(snapshot, cardIds = []) {
  const rows = new Map();
  const get = id => {
    if (!rows.has(id)) rows.set(id, { id, appearances: 0, copies: 0, wins: 0, plays: 0 });
    return rows.get(id);
  };
  for (const id of cardIds) get(id);
  const total = snapshot.decks.reduce((n,d) => n+d.matches,0);
  for (const deck of snapshot.decks) for (const {id,copies} of deck.cards) {
    const row = get(id);
    row.appearances += deck.matches; row.copies += deck.matches*copies; row.wins += deck.wins;
  }
  for (const {id,plays} of snapshot.playStats?.cards || []) get(id).plays = plays;
  return [...rows.values()].map(row => ({ id: row.id, appearances: row.appearances,
    inDecks: total ? row.appearances/total : null,
    averageCopies: row.appearances ? row.copies/row.appearances : null,
    deckWinRate: row.appearances ? row.wins/row.appearances : null,
    timesPlayed: snapshot.playStats?.trackedSeats ? row.plays : null }));
}
export const CARD_SORT_KEYS = ['name','inDecks','averageCopies','deckWinRate','timesPlayed'];
export function sortCardMetrics(rows, key, dir) {
  const field = CARD_SORT_KEYS.includes(key) ? key : 'timesPlayed';
  const sign = dir === 'asc' ? 1 : -1;
  return [...rows].sort((a,b) => {
    const av=a[field], bv=b[field];
    if (av == null && bv != null) return 1;
    if (bv == null && av != null) return -1;
    const value = field === 'name' ? String(av).localeCompare(String(bv)) : (av ?? 0)-(bv ?? 0);
    return sign*value || b.appearances-a.appearances || a.id.localeCompare(b.id);
  });
}
