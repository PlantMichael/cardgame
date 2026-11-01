// Stats tab: exact-deck results for the playtest. Renders with textContent only
// (card and deck data are never parsed as HTML). Logic lives in stats-core.mjs.
import * as S from '/stats-core.mjs';

const app = document.querySelector('[data-stats-app]');
const meta = (name) => document.querySelector(`meta[name="${name}"]`)?.content || '';
const CATALOG = meta('cg-catalog').replace(/\/$/, '');
const SNAPSHOT_TTL_MS = 60000; // the relay caches for 60s; never refetch faster

const h = (tag, props = {}, ...kids) => {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (v === undefined || v === null || v === false) continue;
    if (k === 'class') node.className = v;
    else if (/^aria[A-Z]/.test(k)) node.setAttribute(`aria-${k.slice(4).toLowerCase()}`, v);
    else if (k === 'data') Object.assign(node.dataset, v);
    else if (k.startsWith('on')) node.addEventListener(k.slice(2).toLowerCase(), v);
    else node[k] = v;
  }
  for (const kid of kids.flat()) if (kid !== null && kid !== undefined && kid !== false) node.append(kid);
  return node;
};

// ---- state ----------------------------------------------------------------------
let route = S.routeFromSearch(location.search);
let load = { status: 'loading', snapshot: null, index: null, code: 0 };
let catalog = { status: 'loading', cards: new Map(), list: [] };
let inclusion = { status: 'idle', rates: new Map() };
let seq = 0; // every cohort request gets a number; only the newest may update the page
let inflight = null;
const cache = new Map(); // query string -> { at, snapshot }

const here = (r = route) => `/stats/${S.searchFromRoute(r)}`;
const needsFetch = () => S.serverQuery(route.cohort).toString() !== load.key || route.demo !== load.demo;
function go(patch, { replace = false } = {}) {
  route = { ...route, ...patch };
  history[replace ? 'replaceState' : 'pushState'](null, '', here());
  if (needsFetch()) fetchCohort(); else render();
  if (!replace) window.scrollTo({ top: 0 });
}
const link = (patch, text, props = {}) => h('a', { href: here({ ...route, ...patch }), data: { statsLink: '1' }, ...props }, text);

document.addEventListener('click', (e) => {
  const a = e.target.closest?.('a[data-stats-link]');
  if (!a || e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
  e.preventDefault();
  route = S.routeFromSearch(new URL(a.href).search);
  history.pushState(null, '', a.href);
  if (needsFetch()) fetchCohort(); else render();
  window.scrollTo({ top: 0 });
});
window.addEventListener('popstate', () => {
  route = S.routeFromSearch(location.search);
  if (needsFetch()) fetchCohort(); else render();
});

// ---- data ---------------------------------------------------------------------------
async function fetchCohort(force = false) {
  const mySeq = ++seq;
  inflight?.abort();
  const key = S.serverQuery(route.cohort).toString();
  const demo = route.demo;
  const cached = cache.get(`${demo}|${key}`);
  if (!force && cached && Date.now() - cached.at < SNAPSHOT_TTL_MS) {
    setLoaded(mySeq, key, demo, cached.snapshot);
    return;
  }
  load = { status: 'loading', snapshot: null, index: null, code: 0, key, demo };
  render();
  const controller = new AbortController();
  inflight = controller;
  try {
    const url = demo ? '/media/stats-demo.json' : S.apiUrl(CATALOG, route.cohort);
    const response = await fetch(url, { signal: controller.signal, headers: { Accept: 'application/json' } });
    if (mySeq !== seq) return; // a newer selection superseded this one
    if (!response.ok) { fail(mySeq, key, demo, response.status); return; }
    const body = await response.json();
    if (mySeq !== seq) return;
    if (!S.validateSnapshot(body)) { fail(mySeq, key, demo, 'shape'); return; }
    cache.set(`${demo}|${key}`, { at: Date.now(), snapshot: body });
    while (cache.size > 8) cache.delete(cache.keys().next().value);
    setLoaded(mySeq, key, demo, body);
  } catch (error) {
    if (error.name === 'AbortError' || mySeq !== seq) return;
    fail(mySeq, key, demo, 'network');
  }
}
function setLoaded(mySeq, key, demo, snapshot) {
  if (mySeq !== seq) return;
  load = { status: snapshot.games === 0 ? 'empty' : 'ok', snapshot, index: S.indexSnapshot(snapshot), code: 200, key, demo };
  render();
}
function fail(mySeq, key, demo, code) {
  if (mySeq !== seq) return;
  load = { status: code === 400 ? 'bad' : 'unavailable', snapshot: null, index: null, code, key, demo };
  render();
}

async function fetchCatalog() {
  try {
    const response = await fetch(route.demo ? '/media/stats-demo-cards.json' : `${CATALOG}/data/cards.json`);
    if (!response.ok) throw new Error(String(response.status));
    const body = await response.json();
    if (!Array.isArray(body.cards)) throw new Error('shape');
    catalog = { status: 'ok', cards: S.cardsById(body), list: body.cards };
  } catch { catalog = { status: 'failed', cards: new Map(), list: [] }; }
  render();
}

async function fetchInclusion() {
  if (inclusion.status !== 'idle' || route.demo) return;
  inclusion = { status: 'loading', rates: new Map() };
  try {
    const response = await fetch(`${CATALOG}/data/stats/card-winrates.json`);
    if (!response.ok) throw new Error(String(response.status));
    const body = await response.json();
    inclusion = { status: 'ok', rates: new Map((body.cards || []).map((c) => [c.id, c])) };
  } catch { inclusion = { status: 'failed', rates: new Map() }; }
  render();
}

// ---- small pieces -------------------------------------------------------------------------
const cardName = (id) => catalog.cards.get(id)?.name || id;
const when = (iso) => new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
const roleWord = (role) => (role === 'ai' ? 'AI' : 'Human');
const small = (n) => n < 10;

function sampleCell(row) {
  return h('td', { class: 'num' }, String(row.matches), small(row.matches) ? h('span', { class: 'prelim', title: 'Fewer than 10 seat-games: preliminary' }, 'prelim.') : null);
}
function curveBars(deck) {
  const buckets = S.manaCurve(deck, catalog.cards);
  const max = Math.max(1, ...buckets);
  return h('span', { class: 'curve', role: 'img', ariaLabel: `Mana curve, cost 0 to 7+: ${buckets.join(', ')} cards` },
    buckets.map((n, i) => h('i', { style: `height:${Math.round((n / max) * 100)}%`, title: `${i === 7 ? '7+' : i}: ${n}` })));
}
function deckLink(deck, text) {
  return link({ view: 'deck', deck: deck.id, role: deck.role, opp: '', oppRole: 'ai' }, text || S.deckLabel(deck), { class: 'deck-link' });
}

// ---- cohort bar -------------------------------------------------------------------------------
function option(value, label, selected) { return h('option', { value: String(value), selected: String(selected) === String(value) }, label); }

function cohortBar() {
  const c = route.cohort;
  const avail = load.snapshot?.availableFilters;
  const choices = (list, fallback) => [...new Set([...fallback, ...(list || []).map(String)])];
  const rules = choices(avail?.rulesVersions, ['latest', 'unknown']);
  const ai = choices(avail?.aiVersions, ['latest', 'unknown']);
  const levels = avail?.aiLevels?.length ? [...new Set([c.aiLevel, ...avail.aiLevels.map(String)].filter(Boolean))].sort((a, b) => a - b) : ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10'];
  const field = (label, control) => h('label', { class: 'cohort-field' }, h('span', {}, label), control);
  const mode = h('select', { name: 'mode' }, Object.entries(S.MODES).map(([v, l]) => option(v, l, c.mode)));
  const days = h('input', { name: 'days', type: 'number', min: '1', max: '365', step: '1', value: c.days, required: true });
  const rulesSel = h('select', { name: 'rulesVersion' }, rules.map((v) => option(v, v === 'latest' ? 'Latest' : v === 'unknown' ? 'Unknown' : `Version ${v}`, c.rulesVersion)));
  const aiSel = h('select', { name: 'aiVersion' }, ai.map((v) => option(v, v === 'latest' ? 'Latest' : v === 'unknown' ? 'Unknown' : `Policy ${v}`, c.aiVersion)));
  const lvl = h('select', { name: 'aiLevel' }, levels.map((v) => option(v, `Level ${v}`, c.aiLevel)));
  const form = h('form', { class: 'cohort-bar', ariaLabel: 'Data cohort', onsubmit: (e) => {
    e.preventDefault();
    const next = new URLSearchParams({ mode: mode.value, days: days.value, rulesVersion: rulesSel.value });
    if (mode.value === 'ranked_ai') { next.set('aiVersion', aiSel.value); next.set('aiLevel', lvl.value); }
    go({ cohort: S.cohortFromParams(next), opp: '' });
  } },
  field('Mode', mode), field('Days', days), field('Rules version', rulesSel),
  c.mode === 'ranked_ai' ? field('AI policy', aiSel) : null, c.mode === 'ranked_ai' ? field('AI difficulty', lvl) : null,
  h('button', { type: 'submit', class: 'button small' }, h('span', {}, 'Apply')));
  // Changing the mode only swaps which fields apply; applying sends the request.
  mode.addEventListener('change', () => { const next = new URLSearchParams({ mode: mode.value, days: days.value, rulesVersion: rulesSel.value });
    if (mode.value === 'ranked_ai') { next.set('aiVersion', 'latest'); next.set('aiLevel', '10'); }
    go({ cohort: S.cohortFromParams(next), opp: '' }); });
  return form;
}

function resolvedLine() {
  if (!load.snapshot) return null;
  const f = load.snapshot.filters;
  const parts = [`${S.MODES[f.mode] || f.mode}`, `last ${f.days} day${Number(f.days) === 1 ? '' : 's'}`, `rules ${f.rulesVersion === 'unknown' || f.rulesVersion === null ? 'unknown' : `v${f.rulesVersion}`}`];
  if (f.mode === 'ranked_ai') parts.push(`AI policy ${f.aiVersion === 'unknown' || f.aiVersion === null ? 'unknown' : `v${f.aiVersion}`}`, `difficulty ${f.aiLevel}`);
  const m = load.snapshot.methodology;
  const seatGames = load.snapshot.decks.reduce((n, d) => n + d.matches, 0);
  return h('p', { class: 'resolved' },
    h('strong', {}, 'Showing: '), parts.join(' · '), h('br'),
    `${load.snapshot.games} game${load.snapshot.games === 1 ? '' : 's'} (${seatGames} seat-games). `,
    m.source === 'server_verified' ? 'Results verified by the game server. ' : 'Results are reported by the game client and not verified. ',
    `Stats updated ${when(load.snapshot.generatedAt)}. `, h('strong', {}, 'Preliminary: '),
    'repeated playtesters are not independent samples, and intervals are descriptive, not proof of balance.');
}

// ---- states ------------------------------------------------------------------------------------
function statusPanel() {
  if (load.status === 'loading') return h('p', { class: 'state', role: 'status' }, 'Loading results…');
  if (load.status === 'bad') return h('div', { class: 'state error', role: 'alert' }, h('p', {}, 'The server rejected these filters (400). Reset them to continue.'), link({ cohort: S.DEFAULT_COHORT, view: 'explorer', opp: '' }, 'Reset filters', { class: 'button small' }));
  if (load.status === 'unavailable') {
    const why = load.code === 404 ? 'The deck results are not available on this server yet.'
      : load.code === 503 ? 'The statistics service is unavailable or the request was too large (503). This does not mean no games were played.'
      : 'Could not reach the statistics service. This does not mean no games were played.';
    return h('div', { class: 'state error', role: 'alert' }, h('p', {}, why),
      h('div', { class: 'actions' },
        h('button', { type: 'button', class: 'button small', onclick: () => fetchCohort(true) }, h('span', {}, 'Retry')),
        Number(route.cohort.days) > 7 ? h('button', { type: 'button', class: 'button small secondary', onclick: () => go({ cohort: { ...route.cohort, days: '7' } }) }, h('span', {}, 'Try the last 7 days')) : null,
        route.demo ? null : link({ demo: true }, 'Preview the layout with demo data', { class: 'text-link' })));
  }
  if (load.status === 'empty') return h('div', { class: 'state', role: 'status' }, h('p', {}, 'No eligible games in this cohort. Try a longer window, another version, or the other mode.'));
  return null;
}

// ---- explorer ------------------------------------------------------------------------------------
function explorer() {
  const snap = load.snapshot;
  const rows = S.sortDecks(S.filterDecks(snap, catalog.cards, route), route.sort, route.dir);
  const factions = ['GREEN', 'CRIMSON', 'BLACK', 'ORANGE', 'TEAL'];
  const patch = (p) => go(p, { replace: true });
  const filters = h('div', { class: 'filter-row' },
    h('label', { class: 'cohort-field' }, h('span', {}, 'Decks controlled by'), h('select', { onchange: (e) => patch({ who: e.target.value }) },
      option('human', 'Human players', route.who), option('ai', 'AI opponents', route.who))),
    h('label', { class: 'cohort-field' }, h('span', {}, 'Faction'), h('select', { onchange: (e) => patch({ faction: e.target.value }) },
      option('', 'Any faction', route.faction), factions.map((f) => option(f, S.FACTION_NAMES[f], route.faction)))),
    h('label', { class: 'cohort-field' }, h('span', {}, 'Includes card'), h('input', { type: 'search', value: route.q, placeholder: 'Card name', onchange: (e) => patch({ q: e.target.value }) })),
    h('label', { class: 'cohort-field' }, h('span', {}, 'Excludes card'), h('input', { type: 'search', value: route.x, placeholder: 'Card name', onchange: (e) => patch({ x: e.target.value }) })),
    h('label', { class: 'cohort-field' }, h('span', {}, 'Minimum seat-games'), h('input', { type: 'number', min: '1', value: String(route.min), onchange: (e) => patch({ min: Math.max(1, Number(e.target.value) || 1) }) })));
  const th = (key, label, tip) => {
    const active = route.sort === key;
    const next = active && route.dir === 'desc' ? 'asc' : 'desc';
    return h('th', { scope: 'col', ariaSort: active ? (route.dir === 'asc' ? 'ascending' : 'descending') : 'none' },
      h('button', { type: 'button', class: 'sort', title: tip, onclick: () => patch({ sort: key, dir: next }) }, label, active ? (route.dir === 'asc' ? ' ▲' : ' ▼') : ''));
  };
  const table = h('div', { class: 'table-wrap' }, h('table', { class: 'stats-table' },
    h('caption', { class: 'sr-only' }, 'Exact starting decks in this cohort'),
    h('thead', {}, h('tr', {}, h('th', { scope: 'col' }, 'Deck'), th('winRate', 'Win rate'), h('th', { scope: 'col' }, 'Record'), th('matches', 'Seat-games', 'Number of seat-games (each game counts once per player)'),
      th('testers', 'Testers', 'Distinct human testers'), th('lower', 'Interval', 'Wilson 95% interval'), th('turns', 'Avg turns', 'Average recorded game turns'),
      h('th', { scope: 'col' }, 'Curve'), route.who === 'human' ? h('th', { scope: 'col', title: 'Share of recorded human seat-games in this cohort, not population meta share' }, 'Share*') : null)),
    h('tbody', {}, rows.map((d) => h('tr', {},
      h('th', { scope: 'row' }, deckLink(d), h('small', {}, ` ${S.cardCount(d)} cards`)),
      h('td', { class: 'num strong' }, S.pct(d.winRate)), h('td', { class: 'num' }, S.record(d)), sampleCell(d), h('td', { class: 'num' }, String(d.testers)),
      h('td', { class: 'num' }, S.interval(d.winRateInterval)), h('td', { class: 'num' }, S.turns(d)), h('td', {}, curveBars(d)),
      route.who === 'human' ? h('td', { class: 'num' }, S.pct(S.shareOfHumanSeatGames(load.index, d))) : null)))));
  return h('section', {},
    h('h2', {}, 'Deck explorer'),
    h('p', { class: 'lede' }, 'Each row is one exact starting list. Similar lists are separate decks, and a deck’s record combines every opponent it faced in this cohort.'),
    filters,
    rows.length ? table : h('p', { class: 'state' }, snap.decks.length ? 'No decks match these filters. Lower the minimum or clear the card search.' : 'No decks in this cohort.'),
    h('p', { class: 'foot' }, `Showing ${rows.length} of ${snap.decks.filter((d) => d.role === route.who).length} ${route.who === 'human' ? 'human' : 'AI'} decks. Seat-games count each game once for each player. `,
      route.who === 'human' ? '*Share of recorded human seat-games in this cohort; not population meta share. ' : '', 'Win rate alone is not a ranking: read it with the sample and interval.'));
}

// ---- deck detail ------------------------------------------------------------------------------------
function compositionList(deck) {
  return h('ul', { class: 'composition' }, deck.cards.map(({ id, copies }) => {
    const c = catalog.cards.get(id);
    return h('li', {}, h('span', { class: 'copies' }, `${copies}×`), h('span', { class: 'cost', title: 'Mana cost' }, c ? String(c.manaCost) : '?'),
      h('span', { class: 'card-main' }, h('strong', {}, cardName(id)),
        c ? h('small', {}, `${c.type.toLowerCase()}${c.attack !== null ? ` · ${c.attack}/${c.health}` : c.health !== null ? ` · ${c.health} health` : ''} · ${c.rarity.toLowerCase()}`) : null,
        c?.description ? h('span', { class: 'rules' }, c.description) : null));
  }));
}
function splitTable(deck) {
  const row = (label, s) => h('tr', {}, h('th', { scope: 'row' }, label), h('td', { class: 'num' }, s.matches ? S.pct(s.winRate) : 'No games'), h('td', { class: 'num' }, s.matches ? `${s.wins}–${s.losses}` : '—'), h('td', { class: 'num' }, String(s.matches)));
  return h('div', { class: 'table-wrap split' }, h('table', { class: 'stats-table compact' }, h('caption', {}, 'By who went first'),
    h('thead', {}, h('tr', {}, h('th', { scope: 'col' }, 'Turn order'), h('th', { scope: 'col' }, 'Win rate'), h('th', { scope: 'col' }, 'Record'), h('th', { scope: 'col' }, 'Seat-games'))),
    h('tbody', {}, row('Going first', deck.first), row('Going second', deck.second), row('Unknown', deck.unknownFirst))));
}
function statBlock(label, value, note) {
  return h('div', { class: 'stat' }, h('dt', {}, label), h('dd', {}, value, note ? h('small', {}, note) : null));
}
function deckDetail() {
  const deck = S.findDeck(load.index, route.deck, route.role);
  const back = link({ view: 'explorer', deck: '', opp: '' }, '← All decks', { class: 'text-link' });
  if (!deck) {
    return h('section', {}, back, h('h2', {}, 'Deck not found in this cohort'),
      h('p', { class: 'state' }, `No ${roleWord(route.role).toLowerCase()} deck ${route.deck ? S.shortId(route.deck) : ''} has results in this cohort. It may be recorded under another mode, window or version; its numbers are not carried over.`));
  }
  const opponents = S.opponentsOf(load.snapshot, load.index, deck).sort((a, b) => b.matchup.matches - a.matchup.matches);
  const selected = route.opp ? S.findDeck(load.index, route.opp, route.oppRole) : null;
  const oppRow = selected && opponents.find((o) => o.matchup.opponentDeckId === selected.id && o.matchup.opponentRole === selected.role);
  const table = h('div', { class: 'table-wrap' }, h('table', { class: 'stats-table' },
    h('caption', {}, 'Results against each opposing deck'),
    h('thead', {}, h('tr', {}, h('th', { scope: 'col' }, 'Opponent'), h('th', { scope: 'col' }, 'Win rate'), h('th', { scope: 'col' }, 'Record'), h('th', { scope: 'col' }, 'Seat-games'), h('th', { scope: 'col' }, 'Interval'), h('th', { scope: 'col' }, 'Testers'), h('th', { scope: 'col' }, 'Avg turns'))),
    h('tbody', {}, opponents.map(({ matchup, opponent }) => {
      const on = selected && opponent && opponent.id === selected.id && opponent.role === selected.role;
      return h('tr', { class: on ? 'selected' : '' },
        h('th', { scope: 'row' }, opponent ? link({ opp: opponent.id, oppRole: opponent.role }, `${roleWord(opponent.role)} · ${S.deckLabel(opponent)}`, { ariaCurrent: on ? 'true' : undefined, class: 'deck-link' }) : `${roleWord(matchup.opponentRole)} · ${S.shortId(matchup.opponentDeckId)}`),
        h('td', { class: 'num strong' }, S.pct(matchup.winRate)), h('td', { class: 'num' }, S.record(matchup)), sampleCell(matchup),
        h('td', { class: 'num' }, S.interval(matchup.winRateInterval)), h('td', { class: 'num' }, String(matchup.testers)), h('td', { class: 'num' }, S.turns(matchup)));
    }))));
  const side = h('aside', { class: 'opp-panel', ariaLabel: 'Selected opponent' },
    selected ? [h('h3', {}, 'Opponent list'), h('p', { class: 'opp-title' }, `${roleWord(selected.role)} · ${S.deckLabel(selected)}`),
      oppRow ? h('p', {}, `${deck.role === 'ai' ? 'This deck' : 'Your selected deck'} wins ${S.pct(oppRow.matchup.winRate)} (${S.record(oppRow.matchup)}) against it.`) : null,
      compositionList(selected), h('div', { class: 'actions' }, link({ view: 'deck', deck: selected.id, role: selected.role, opp: '' }, `Open this deck`, { class: 'text-link' }), link({ opp: '' }, 'Clear', { class: 'text-link' }))]
      : [h('h3', {}, 'Opponent list'), h('p', { class: 'state' }, 'Select an opponent to see its full list here. Your cohort and this deck stay selected.')]);
  return h('section', {}, back,
    h('h2', {}, `${roleWord(deck.role)} deck · ${S.deckLabel(deck)}`),
    h('p', { class: 'lede' }, `Deck id ${deck.id}. ${S.cardCount(deck)} cards. Only starting cards define the deck; cards created or transformed during play do not.`),
    h('dl', { class: 'stat-grid' },
      statBlock('Win rate', S.pct(deck.winRate), `${S.record(deck)} · ${deck.matches} seat-games${small(deck.matches) ? ' · preliminary' : ''}`),
      statBlock('95% interval', S.interval(deck.winRateInterval), 'Wilson, descriptive'),
      statBlock('Testers', String(deck.testers), 'distinct humans'),
      statBlock('Average turns', S.turns(deck), deck.turnSamples ? `${deck.turnSamples} games recorded` : 'no turn data')),
    h('div', { class: 'deck-columns' },
      h('div', { class: 'deck-main' }, h('h3', {}, 'Opponents'), opponents.length ? table : h('p', { class: 'state' }, 'No opponent rows for this deck in this cohort.'), splitTable(deck)),
      h('div', { class: 'deck-lists' }, ...(() => {
        const own = h('div', { class: 'list-block' }, h('h3', {}, 'Starting list'), h('div', { class: 'curve large' }, curveBars(deck), h('small', {}, 'Mana curve (7+ pooled)')), compositionList(deck));
        return selected ? [side, own] : [own, side];
      })())));
}

// ---- matrix ------------------------------------------------------------------------------------------
function matrixView() {
  const snap = load.snapshot;
  const { rowDecks, colDecks } = S.matrixAxes(snap, snap.filters.mode, route.rows, route.cols);
  const grid = S.buildMatrix(snap, rowDecks, colDecks);
  const chosen = route.opp && route.deck ? { r: rowDecks.findIndex((d) => d.id === route.deck && d.role === route.role), c: colDecks.findIndex((d) => d.id === route.opp && d.role === route.oppRole) } : null;
  const select = (key, value) => h('select', { onchange: (e) => go({ [key]: Number(e.target.value) }, { replace: true }) }, [3, 5, 8, 10, 15, 25].map((n) => option(n, String(n), value)));
  const cell = (r, c) => {
    const m = grid[r][c];
    const label = m ? `${S.pct(m.winRate)} · ${S.record(m)}` : 'No games';
    const on = chosen && chosen.r === r && chosen.c === c;
    return h('td', {}, h('button', { type: 'button', class: `cell heat-${S.heat(m?.winRate)}${on ? ' on' : ''}${m ? '' : ' none'}`, ariaPressed: String(!!on),
      ariaLabel: `${S.deckLabel(rowDecks[r])} against ${roleWord(colDecks[c].role)} ${S.deckLabel(colDecks[c])}: ${m ? `${S.pct(m.winRate)}, ${S.record(m)}, ${m.matches} seat-games` : 'no games recorded'}`,
      onclick: () => go({ deck: rowDecks[r].id, role: rowDecks[r].role, opp: colDecks[c].id, oppRole: colDecks[c].role }, { replace: true }) },
    h('b', {}, m ? S.pct(m.winRate) : 'No games'), m ? h('small', {}, `${S.record(m)} · n=${m.matches}`) : null));
  };
  const detail = chosen && chosen.r >= 0 && chosen.c >= 0 ? (() => {
    const m = grid[chosen.r][chosen.c]; const a = rowDecks[chosen.r]; const b = colDecks[chosen.c];
    return h('div', { class: 'matrix-detail', role: 'region', ariaLabel: 'Selected matchup' }, h('h3', {}, 'Selected matchup'),
      h('p', {}, link({ view: 'deck', deck: a.id, role: a.role, opp: b.id, oppRole: b.role }, S.deckLabel(a)), ` (${roleWord(a.role)}) against `, link({ view: 'deck', deck: b.id, role: b.role, opp: '' }, S.deckLabel(b)), ` (${roleWord(b.role)})`),
      m ? h('p', {}, `${S.pct(m.winRate)} · ${S.record(m)} · ${m.matches} seat-games · interval ${S.interval(m.winRateInterval)} · ${m.testers} testers · avg turns ${S.turns(m)}`) : h('p', { class: 'state' }, 'No games recorded for this pairing in this cohort.'));
  })() : h('p', { class: 'foot' }, 'Select a cell to see its interval, testers and both decks.');
  const listRows = grid.flatMap((row, r) => row.map((m, c) => ({ m, a: rowDecks[r], b: colDecks[c] })));
  return h('section', {},
    h('h2', {}, 'Exact-deck matchups'),
    h('p', { class: 'lede' }, `Each cell is the row deck’s result against the column deck. ${snap.filters.mode === 'ranked_ai' ? 'Rows are human decks; columns are AI decks.' : 'Both axes are human decks.'} These are specific lists, not archetypes, and colour is only a hint: read the number and the sample.`),
    h('div', { class: 'filter-row' }, h('label', { class: 'cohort-field' }, h('span', {}, 'Rows (most played)'), select('rows', route.rows)), h('label', { class: 'cohort-field' }, h('span', {}, 'Columns'), select('cols', route.cols))),
    rowDecks.length && colDecks.length ? h('div', { class: 'table-wrap' }, h('table', { class: 'matrix' }, h('caption', { class: 'sr-only' }, 'Row deck win rate against column deck'),
      h('thead', {}, h('tr', {}, h('td', {}), colDecks.map((d) => h('th', { scope: 'col' }, h('span', { class: 'axis' }, roleWord(d.role)), S.deckLabel(d))))),
      h('tbody', {}, rowDecks.map((d, r) => h('tr', {}, h('th', { scope: 'row' }, link({ view: 'deck', deck: d.id, role: d.role, opp: '' }, S.deckLabel(d), { class: 'deck-link' }), h('small', {}, ` n=${d.matches}`)), colDecks.map((_, c) => cell(r, c))))))) : h('p', { class: 'state' }, 'Not enough decks in this cohort to build a matrix.'),
    detail,
    h('details', { class: 'matrix-list' }, h('summary', {}, 'Show every pairing as a list'),
      h('div', { class: 'table-wrap' }, h('table', { class: 'stats-table compact' }, h('thead', {}, h('tr', {}, h('th', { scope: 'col' }, 'Row deck'), h('th', { scope: 'col' }, 'Column deck'), h('th', { scope: 'col' }, 'Win rate'), h('th', { scope: 'col' }, 'Record'))),
        h('tbody', {}, listRows.map(({ m, a, b }) => h('tr', {}, h('td', {}, S.deckLabel(a)), h('td', {}, `${roleWord(b.role)} · ${S.deckLabel(b)}`), h('td', { class: 'num' }, m ? S.pct(m.winRate) : 'No games'), h('td', { class: 'num' }, m ? `${S.record(m)} (n=${m.matches})` : '—'))))))));
}

// ---- cards (supporting context) ------------------------------------------------------------------------
function cardsView() {
  fetchInclusion();
  const q = route.q.trim().toLowerCase();
  const list = catalog.list.filter((c) => c.collectible && (!route.faction || c.color === route.faction) && (!q || c.name.toLowerCase().includes(q)));
  return h('section', {},
    h('h2', {}, 'Cards'),
    h('p', { class: 'lede' }, 'Printed card definitions. The win rate shown is the starting-deck inclusion win rate: it combines AI and PvP games and every rules version, ignores the cohort bar above, and is not controlled card strength.'),
    h('div', { class: 'filter-row' },
      h('label', { class: 'cohort-field' }, h('span', {}, 'Faction'), h('select', { onchange: (e) => go({ faction: e.target.value }, { replace: true }) }, option('', 'Any faction', route.faction), ['GREEN', 'CRIMSON', 'BLACK', 'ORANGE', 'TEAL', 'GENERIC'].map((f) => option(f, S.FACTION_NAMES[f], route.faction)))),
      h('label', { class: 'cohort-field' }, h('span', {}, 'Search'), h('input', { type: 'search', value: route.q, placeholder: 'Card name', onchange: (e) => go({ q: e.target.value }, { replace: true }) }))),
    catalog.status === 'failed' ? h('p', { class: 'state error' }, 'Could not load the card list.') : null,
    h('div', { class: 'table-wrap' }, h('table', { class: 'stats-table' }, h('thead', {}, h('tr', {}, ['Card', 'Cost', 'Type', 'Faction', 'Text', 'Inclusion win rate'].map((t) => h('th', { scope: 'col' }, t)))),
      h('tbody', {}, list.map((c) => {
        const r = inclusion.rates.get(c.id);
        return h('tr', {}, h('th', { scope: 'row' }, c.name), h('td', { class: 'num' }, String(c.manaCost)), h('td', {}, c.type.toLowerCase()), h('td', {}, S.FACTION_NAMES[c.color] || c.color), h('td', { class: 'rules' }, c.description),
          h('td', { class: 'num' }, r ? (r.matches ? `${S.pct(r.winRate)} (n=${r.matches})` : 'No games') : inclusion.status === 'failed' ? 'Unavailable' : '—'));
      })))));
}

// ---- page ---------------------------------------------------------------------------------------------------
function tabs() {
  const items = [['explorer', 'Decks'], ['matrix', 'Exact-deck matchups'], ['cards', 'Cards']];
  const current = route.view === 'deck' ? 'explorer' : route.view;
  return h('nav', { class: 'stats-tabs', ariaLabel: 'Statistics views' }, items.map(([view, label]) =>
    link({ view, deck: '', opp: '' }, label, { ariaCurrent: current === view ? 'page' : undefined })));
}

function render() {
  if (!app) return;
  const body = [];
  if (route.demo) body.push(h('p', { class: 'demo-banner', role: 'note' }, 'DEMO DATA: synthetic results for previewing the layout. These are not recorded games.', ' ', link({ demo: false }, 'Leave demo', { class: 'text-link' })));
  body.push(h('header', { class: 'stats-head' }, h('p', { class: 'eyebrow' }, 'Playtest statistics'), h('h1', {}, 'Deck results'),
    h('p', { class: 'lede' }, 'Exact starting decks and how they do against each other, from recorded playtest games. Sample sizes are small: read every number with its seat-game count.')));
  body.push(tabs());
  if (route.view !== 'cards') { body.push(cohortBar()); body.push(resolvedLine()); }
  const status = route.view === 'cards' ? null : statusPanel();
  if (status) body.push(status);
  else if (route.view === 'cards') body.push(cardsView());
  else if (load.snapshot && load.status === 'ok') body.push(route.view === 'deck' ? deckDetail() : route.view === 'matrix' ? matrixView() : explorer());
  app.replaceChildren(...body.filter(Boolean));
  document.title = `${route.view === 'cards' ? 'Cards' : 'Deck results'} — cardgame stats`;
}

render();
fetchCatalog();
if (route.view !== 'cards') fetchCohort();
