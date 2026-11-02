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
    const url = demo ? (route.cohort.mode === 'all' ? '/media/stats-demo-combined.json' : '/media/stats-demo.json') : S.apiUrl(CATALOG, route.cohort);
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
  catalog = {status:'loading',cards:new Map(),list:[]};
  render();
  try {
    const response = await fetch(route.demo ? '/media/stats-demo-cards.json' : `${CATALOG}/data/cards.json`);
    if (!response.ok) throw new Error(String(response.status));
    const body = await response.json();
    if (!Array.isArray(body.cards)) throw new Error('shape');
    catalog = { status: 'ok', cards: S.cardsById(body), list: body.cards };
  } catch { catalog = { status: 'failed', cards: new Map(), list: [] }; }
  render();
}

// ---- small pieces -------------------------------------------------------------------------
const cardName = (id) => catalog.cards.get(id)?.name || id;
const when = (iso) => new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
const roleWord = (role) => (role === 'combined' ? 'Combined' : role === 'ai' ? 'AI' : 'Player');
const small = (n) => n < 10;
const deckName = (deck) => S.deckLabel(deck, load.index?.labels);
const sampleNote = (row) => `Only ${row.matches} game${row.matches === 1 ? '' : 's'} recorded—results may change.`;

function sampleCell(row) {
  return h('td', { class: 'num' }, String(row.matches));
}
function moreNumbers(row) {
  return h('dl', { class: 'stat-grid' },
    statBlock('Wins / losses', S.record(row)),
    statBlock('Win-rate range', S.interval(row.winRateInterval), '95% statistical estimate; small samples give wide ranges'),
    statBlock('Players recorded', String(row.testers)),
    statBlock('Average turns', S.turns(row)));
}
function featuredCards(deck) {
  return [...deck.cards].sort((a, b) => (catalog.cards.get(b.id)?.manaCost ?? -1) - (catalog.cards.get(a.id)?.manaCost ?? -1) || a.id.localeCompare(b.id))
    .slice(0, 2).map(({ id }) => cardName(id)).join(' · ');
}
function curveBars(deck) {
  const buckets = S.manaCurve(deck, catalog.cards);
  const max = Math.max(1, ...buckets);
  return h('span', { class: 'curve', role: 'img', ariaLabel: `Mana curve, cost 0 to 7+: ${buckets.join(', ')} cards` },
    buckets.map((n, i) => h('i', { style: `height:${Math.round((n / max) * 100)}%`, title: `${i === 7 ? '7+' : i}: ${n}` })));
}
function deckLink(deck, text) {
  return link({ view: 'deck', deck: deck.id, role: deck.role, opp: '', oppRole: route.cohort.mode === 'all' ? 'combined' : 'ai' }, text || deckName(deck), { class: 'deck-link' });
}

// ---- cohort bar -------------------------------------------------------------------------------
function option(value, label, selected) { return h('option', { value: String(value), selected: String(selected) === String(value) }, label); }

function cohortBar() {
  const c = route.cohort;
  const rules = [...new Set(['latest','unknown',...(load.snapshot?.availableFilters.rulesVersions || []).map(String)])];
  const days = h('input',{name:'days',type:'number',min:'1',max:'365',step:'1',value:c.days,required:true});
  const version = h('select',{name:'rulesVersion'},rules.map(v=>option(v,v==='latest'?'Latest':v==='unknown'?'Unknown':'Version '+v,c.rulesVersion)));
  return h('details',{class:'stats-disclosure'},h('summary',{},'Date range and game version'),
    h('form',{class:'cohort-bar',ariaLabel:'Results filters',onsubmit:e=>{
      e.preventDefault(); go({cohort:S.cohortFromParams(new URLSearchParams({...c,days:days.value,rulesVersion:version.value})),opp:''});
    }},h('label',{class:'cohort-field'},h('span',{},'Days to include'),days),
    h('label',{class:'cohort-field'},h('span',{},'Game version'),version),
    h('button',{type:'submit',class:'button small'},h('span',{},'Apply')),
    c.mode !== 'all' ? link({cohort:S.DEFAULT_COHORT,deck:'',opp:'',role:'combined',who:'combined'},'Use combined results',{class:'text-link'}) : null));
}

function resolvedLine() {
  if (!load.snapshot) return null;
  const f = load.snapshot.filters;
  const parts = [`${S.MODES[f.mode] || f.mode}`, `last ${f.days} day${Number(f.days) === 1 ? '' : 's'}`, `rules ${f.rulesVersion === 'unknown' || f.rulesVersion === null ? 'unknown' : `v${f.rulesVersion}`}`];
  if (f.mode === 'ranked_ai') parts.push(`AI policy ${f.aiVersion === 'unknown' || f.aiVersion === null ? 'unknown' : `v${f.aiVersion}`}`, `difficulty ${f.aiLevel}`);
  const m = load.snapshot.methodology;
  const seatGames = load.snapshot.decks.reduce((n, d) => n + d.matches, 0);
  return h('div', { class: 'results-context' },
    h('p', { class: 'resolved' }, `${S.MODES[f.mode] || f.mode} · Last ${f.days} days · ${load.snapshot.games} game${load.snapshot.games === 1 ? '' : 's'} recorded`),
    h('details', { class: 'stats-disclosure' }, h('summary', {}, 'About these results'),
      h('p', { class: 'foot' }, parts.join(' · ')),
      h('p', { class: 'foot' }, m.source === 'mixed' ? 'Combined playtest results include human games and automated ranked bots. Local AI results are client-reported; ranked player and bot games are verified by the game server.' : m.source === 'server_verified' ? 'Results verified by the game server.' : 'These results are reported by the game client, rather than verified by the server.'),
      h('p', { class: 'foot' }, `${seatGames} deck appearances: each game contributes one result to each deck that played. Repeated human or bot games can dominate the sample. These numbers are a playtest guide, not proof that a deck is balanced.`),
      h('p', { class: 'foot' }, `Updated ${when(load.snapshot.generatedAt)}. Deck names describe factions, with numbers to separate different card lists in these results. Saved player deck names are not published.`)));
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
  if (load.status === 'empty') return h('div', { class: 'state', role: 'status' }, h('p', {}, 'No games recorded for these filters. Try a longer date range.'));
  return null;
}

// ---- explorer ------------------------------------------------------------------------------------
function explorer() {
  const snap = load.snapshot;
  const rows = S.sortDecks(S.filterDecks(snap, catalog.cards, route, load.index.labels), route.sort, route.dir);
  const factions = ['GREEN', 'CRIMSON', 'BLACK', 'ORANGE', 'TEAL'];
  const patch = (p) => go(p, { replace: true });
  const advancedActive = (route.cohort.mode !== 'all' && route.who !== 'human') || route.x || route.min > 1 || !['matches', 'winRate'].includes(route.sort);
  const filters = h('div', { class: 'filter-row simple-filters' },
    h('label', { class: 'cohort-field' }, h('span', {}, 'Faction'), h('select', { onchange: (e) => patch({ faction: e.target.value }) },
      option('', 'Any faction', route.faction), factions.map((f) => option(f, S.FACTION_NAMES[f], route.faction)))),
    h('form', { class: 'deck-search', onsubmit: (e) => { e.preventDefault(); patch({ q: e.currentTarget.elements.q.value }); } },
      h('label', { class: 'cohort-field' }, h('span', {}, 'Find a deck'), h('input', { name: 'q', type: 'search', value: route.q, placeholder: 'Deck or card name' })),
      h('button', { type: 'submit', class: 'button small' }, h('span', {}, 'Search'))));
  const moreFilters = h('details', { class: 'stats-disclosure', open: !!advancedActive },
    h('summary', {}, 'More filters' + (advancedActive ? ' (active)' : '')),
    h('div', { class: 'filter-row' },
      route.cohort.mode !== 'all' ? h('label', { class: 'cohort-field' }, h('span', {}, 'Decks played by'), h('select', { onchange: (e) => patch({ who: e.target.value }) },
        option('human', 'Players', route.who), option('ai', 'AI', route.who))) : null,
      h('label', { class: 'cohort-field' }, h('span', {}, 'Without this card'), h('input', { type: 'search', value: route.x, placeholder: 'Card name', onchange: (e) => patch({ x: e.target.value }) })),
      h('label', { class: 'cohort-field' }, h('span', {}, 'At least this many games'), h('input', { type: 'number', min: '1', value: String(route.min), onchange: (e) => patch({ min: Math.max(1, Number(e.target.value) || 1) }) })),
      h('label', { class: 'cohort-field' }, h('span', {}, 'Sort by'), h('select', { onchange: (e) => patch({ sort: e.target.value, dir: 'desc' }) },
        [['matches', 'Most played'], ['winRate', 'Win rate'], ['testers', 'Players recorded'], ['lower', 'Win-rate range'], ['turns', 'Average turns']].map(([v, label]) => option(v, label, route.sort))))));
  const th = (key, label, tip) => {
    const active = route.sort === key;
    const next = active && route.dir === 'desc' ? 'asc' : 'desc';
    return h('th', { scope: 'col', ariaSort: active ? (route.dir === 'asc' ? 'ascending' : 'descending') : 'none' },
      h('button', { type: 'button', class: 'sort', title: tip, onclick: () => patch({ sort: key, dir: next }) }, label, active ? (route.dir === 'asc' ? ' ▲' : ' ▼') : ''));
  };
  const table = h('div', { class: 'table-wrap' }, h('table', { class: 'stats-table deck-explorer' },
    h('caption', { class: 'sr-only' }, 'Deck results'),
    h('thead', {}, h('tr', {}, h('th', { scope: 'col' }, 'Deck'), th('winRate', 'Win rate'), th('matches', 'Games played'))),
    h('tbody', {}, rows.map((d) => h('tr', {},
      h('th', { scope: 'row' }, deckLink(d), h('small', { class: 'deck-preview' }, featuredCards(d)),
        small(d.matches) ? h('small', { class: 'sample-note' }, sampleNote(d)) : null),
      h('td', { class: 'num strong' }, S.pct(d.winRate)), sampleCell(d))))));
  return h('section', {},
    filters, moreFilters,
    rows.length ? table : h('p', { class: 'state', role: 'status' }, 'No decks match. Try another faction or clear your search and extra filters.'),
    h('p', { class: 'foot', role: 'status' }, rows.length + ' ' + (route.who === 'combined' ? '' : route.who === 'human' ? 'player ' : 'AI ') + 'deck' + (rows.length === 1 ? '' : 's') + ' shown.'));
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
    h('thead', {}, h('tr', {}, h('th', { scope: 'col' }, 'Turn order'), h('th', { scope: 'col' }, 'Win rate'), h('th', { scope: 'col' }, 'Record'), h('th', { scope: 'col' }, 'Games played'))),
    h('tbody', {}, row('Going first', deck.first), row('Going second', deck.second), row('Unknown', deck.unknownFirst))));
}
function statBlock(label, value, note) {
  return h('div', { class: 'stat' }, h('dt', {}, label), h('dd', {}, value, note ? h('small', {}, note) : null));
}
function deckDetail() {
  const deck = S.findDeck(load.index, route.deck, route.role);
  const back = link({ view: 'explorer', deck: '', opp: '' }, '← All decks', { class: 'text-link' });
  if (!deck) {
    return h('section', {}, back, h('h2', {}, 'No results for this deck'),
      h('p', { class: 'state' }, 'This deck has no results for the selected date range and game version. Try changing the filters.'));
  }
  const opponents = S.opponentsOf(load.snapshot, load.index, deck).sort((a, b) => b.matchup.matches - a.matchup.matches);
  const selected = route.opp ? S.findDeck(load.index, route.opp, route.oppRole) : null;
  const oppRow = selected && opponents.find((o) => o.matchup.opponentDeckId === selected.id && o.matchup.opponentRole === selected.role);
  const table = h('div', { class: 'table-wrap' }, h('table', { class: 'stats-table' },
    h('caption', {}, 'Results against each opposing deck'),
    h('thead', {}, h('tr', {}, h('th', { scope: 'col' }, 'Opponent'), h('th', { scope: 'col' }, 'Win rate'), h('th', { scope: 'col' }, 'Games played'))),
    h('tbody', {}, opponents.map(({ matchup, opponent }) => {
      const on = selected && opponent && opponent.id === selected.id && opponent.role === selected.role;
      return h('tr', { class: on ? 'selected' : '' },
        h('th', { scope: 'row' }, opponent ? link({ opp: opponent.id, oppRole: opponent.role }, `${route.cohort.mode === 'all' ? '' : roleWord(opponent.role)+' · '}${deckName(opponent)}`, { ariaCurrent: on ? 'true' : undefined, class: 'deck-link' }) : `${roleWord(matchup.opponentRole)} deck`,
          small(matchup.matches) ? h('small', { class: 'sample-note' }, sampleNote(matchup)) : null),
        h('td', { class: 'num strong' }, S.pct(matchup.winRate)), sampleCell(matchup));
    }))));
  const side = h('aside', { class: 'opp-panel', ariaLabel: 'Selected opponent' },
    selected ? [h('h3', {}, 'Opponent cards'), h('p', { class: 'opp-title' }, `${route.cohort.mode === 'all' ? '' : roleWord(selected.role)+' · '}${deckName(selected)}`),
      oppRow ? h('p', {}, `${deck.role === 'ai' ? 'This deck' : 'Your selected deck'} wins ${S.pct(oppRow.matchup.winRate)} (${S.record(oppRow.matchup)}) against it.`) : null,
      oppRow ? h('details', { class: 'stats-disclosure' }, h('summary', {}, 'More matchup details'), moreNumbers(oppRow.matchup)) : null,
      compositionList(selected), h('div', { class: 'actions' }, link({ view: 'deck', deck: selected.id, role: selected.role, opp: '' }, 'Open this deck', { class: 'text-link' }), link({ opp: '' }, 'Clear', { class: 'text-link' }))]
      : null);
  return h('section', {}, back,
    h('h2', {}, deckName(deck)),
    h('p', { class: 'lede' }, `${S.cardCount(deck)} cards · Played by ${deck.role === 'combined' ? 'players and AI in the combined results' : deck.role === 'ai' ? 'AI' : 'players'}`),
    h('dl', { class: 'stat-grid' },
      statBlock('Win rate', S.pct(deck.winRate), `${deck.wins} wins · ${deck.losses} losses`),
      statBlock('Games played', String(deck.matches))),
    small(deck.matches) ? h('p', { class: 'sample-note' }, sampleNote(deck)) : null,
    h('div', { class: 'deck-columns' },
      h('div', { class: 'deck-main' }, h('h3', {}, 'How it does against other decks'),
        h('p', { class: 'foot' }, 'Win rates below are for this deck. Choose an opponent to see its cards.'),
        opponents.length ? table : h('p', { class: 'state' }, 'No opponent results recorded yet.'),
        selected ? side : null,
        h('details', { class: 'stats-disclosure' }, h('summary', {}, 'More deck statistics'), moreNumbers(deck), splitTable(deck),
          deck.role === 'human' ? h('p', { class: 'foot' }, `This list accounts for ${S.pct(S.shareOfHumanSeatGames(load.index, deck))} of player deck appearances in these results.`) : null,
          h('p', { class: 'foot deck-id' }, `Deck ID: ${deck.id}`),
          h('p', { class: 'foot' }, 'Each list is counted separately. Cards created or transformed during a game do not change its starting deck.'))),
      h('div', { class: 'deck-lists' }, ...(() => {
        const own = h('div', { class: 'list-block' }, h('h3', {}, 'Cards in this deck'), compositionList(deck),
          h('details', { class: 'stats-disclosure' }, h('summary', {}, 'Mana costs'), h('div', { class: 'curve large' }, curveBars(deck), h('small', {}, 'Cards by mana cost; 7 and higher grouped together'))));
        return [own];
      })())));
}

// ---- matrix ------------------------------------------------------------------------------------------
function matrixView() {
  const snap = load.snapshot;
  const ownRole = snap.filters.mode === 'all' ? 'combined' : 'human';
  const choices = S.sortDecks(snap.decks.filter(d=>d.role===ownRole),'matches','desc');
  const deck = route.deck ? choices.find(d=>d.id===route.deck && d.role===route.role) : choices[0];
  const opponents = deck ? S.opponentsOf(snap,load.index,deck).sort((a,b)=>b.matchup.matches-a.matchup.matches) : [];
  const selected = route.opp ? S.findDeck(load.index,route.opp,route.oppRole) : null;
  const picked = selected && opponents.find(o=>o.matchup.opponentDeckId===selected.id && o.matchup.opponentRole===selected.role);
  const opponentName = d => (snap.filters.mode==='all'?'':roleWord(d.role)+' · ')+deckName(d);
  const table = h('div',{class:'table-wrap'},h('table',{class:'stats-table deck-explorer'},
    h('caption',{class:'sr-only'},'Results against each opponent'),
    h('thead',{},h('tr',{},...['Opponent','Win rate','Games played'].map(t=>h('th',{scope:'col'},t)))),
    h('tbody',{},opponents.map(({matchup,opponent})=>h('tr',{class:selected?.id===opponent?.id && selected?.role===opponent?.role?'selected':''},
      h('th',{scope:'row'},opponent ? link({deck:deck.id,role:deck.role,opp:opponent.id,oppRole:opponent.role},opponentName(opponent),{class:'deck-link'}) : 'Unknown deck',
        small(matchup.matches)?h('small',{class:'sample-note'},sampleNote(matchup)):null),
      h('td',{class:'num strong'},S.pct(matchup.winRate)),sampleCell(matchup))))));
  const detail = deck && selected ? h('div',{class:'matrix-detail',role:'region',ariaLabel:'Selected matchup'},
    h('h3',{},deckName(deck)+' vs '+opponentName(selected)),
    picked ? h('p',{},deckName(deck)+' wins '+S.pct(picked.matchup.winRate)+' of '+picked.matchup.matches+' games against this deck.')
      : h('p',{class:'state'},'No games recorded for this pairing.'),
    picked ? h('details',{class:'stats-disclosure'},h('summary',{},'More matchup details'),moreNumbers(picked.matchup)) : null,
    h('details',{class:'stats-disclosure'},h('summary',{},'Cards in these decks'),
      h('div',{class:'deck-columns'},h('div',{},h('h3',{},deckName(deck)),compositionList(deck)),h('div',{},h('h3',{},opponentName(selected)),compositionList(selected))))) : null;
  const {rowDecks,colDecks} = S.matrixAxes(snap,snap.filters.mode,route.rows,route.cols);
  const grid = S.buildMatrix(snap,rowDecks,colDecks);
  const gridSize = (key,value)=>h('select',{onchange:e=>go({[key]:Number(e.target.value)},{replace:true})},[3,5,8,10,15,25].map(n=>option(n,String(n),value)));
  const comparison = h('details',{class:'stats-disclosure'},h('summary',{},'Compare all decks'),
    h('p',{class:'foot'},'Read each result from the deck on the left. No games means this pairing has not been recorded.'),
    h('div',{class:'filter-row'},h('label',{class:'cohort-field'},h('span',{},'Deck rows'),gridSize('rows',route.rows)),
      h('label',{class:'cohort-field'},h('span',{},'Opponent columns'),gridSize('cols',route.cols))),
    h('div',{class:'table-wrap'},h('table',{class:'matrix'},h('caption',{class:'sr-only'},'Deck comparison grid'),
      h('thead',{},h('tr',{},h('td',{}),colDecks.map(d=>h('th',{scope:'col'},opponentName(d))))),
      h('tbody',{},rowDecks.map((d,r)=>h('tr',{},h('th',{scope:'row'},deckName(d)),colDecks.map((enemy,c)=>{
        const match=grid[r][c]; const on=deck?.id===d.id && selected?.id===enemy.id && selected?.role===enemy.role;
        return h('td',{},h('button',{type:'button',class:'cell heat-'+S.heat(match?.winRate)+(match?'':' none')+(on?' on':''),ariaPressed:String(on),
          ariaLabel:deckName(d)+' against '+opponentName(enemy)+': '+(match?S.pct(match.winRate)+', '+match.matches+' games':'no games recorded'),
          onclick:()=>go({deck:d.id,role:d.role,opp:enemy.id,oppRole:enemy.role},{replace:true})},
          h('b',{},match?S.pct(match.winRate):'No games'),match?h('small',{},match.matches+' games'):null));
      })))))));
  return h('section',{},h('h2',{class:'sr-only'},'Deck matchups'),
    h('div',{class:'filter-row'},h('label',{class:'cohort-field matchup-picker'},h('span',{},'Your deck'),
      h('select',{onchange:e=>go({deck:e.target.value,role:ownRole,opp:''})},option('','Choose a deck',deck?.id||''),choices.map(d=>option(d.id,deckName(d),deck?.id))))),
    deck ? (opponents.length?table:h('p',{class:'state'},'No opponent results for this deck yet.')) : h('p',{class:'state'},'Choose a deck with results for these filters.'),
    detail,comparison);
}

// ---- cards (supporting context) ------------------------------------------------------------------------
function cardsView() {
  const snap = load.snapshot;
  const q = route.q.trim().toLowerCase();
  const ids = catalog.list.filter(c=>c.collectible && !c.isToken).map(c=>c.id);
  const sort = S.CARD_SORT_KEYS.includes(route.sort)?route.sort:'timesPlayed';
  const rows = S.sortCardMetrics(S.cardMetrics(snap,ids).map(row=>({...row,name:cardName(row.id)})),sort,route.dir)
    .filter(row=>catalog.cards.has(row.id) && (!route.faction||catalog.cards.get(row.id).color===route.faction) && (!q||row.name.toLowerCase().includes(q)));
  const coverage = snap.playStats || {totalSeats:snap.games*2,trackedSeats:0,completeSeats:0};
  const heading = (key,label,help)=>h('th',{scope:'col',ariaSort:sort===key?(route.dir==='asc'?'ascending':'descending'):'none'},
    h('button',{type:'button',class:'sort',title:help,onclick:()=>go({sort:key,dir:sort===key&&route.dir==='desc'?'asc':'desc'},{replace:true})},label,sort===key?(route.dir==='asc'?' ▲':' ▼'):''));
  return h('section',{},h('h2',{class:'sr-only'},'Card statistics'),
    h('div',{class:'filter-row simple-filters'},
      h('label',{class:'cohort-field'},h('span',{},'Faction'),h('select',{onchange:e=>go({faction:e.target.value},{replace:true})},option('','Any faction',route.faction),
        ['GREEN','CRIMSON','BLACK','ORANGE','TEAL','GENERIC'].map(f=>option(f,S.FACTION_NAMES[f],route.faction)))),
      h('form',{class:'deck-search',onsubmit:e=>{e.preventDefault();go({q:e.currentTarget.elements.q.value},{replace:true});}},
        h('label',{class:'cohort-field'},h('span',{},'Find a card'),h('input',{name:'q',type:'search',value:route.q,placeholder:'Card name'})),
        h('button',{type:'submit',class:'button small'},h('span',{},'Search')))),
    h('p',{class:'foot'},coverage.trackedSeats===0?'No card-play history is recorded for these games. The deck statistics are still available.'
      : coverage.completeSeats<coverage.totalSeats?'Times played is partially recorded for older games. Counts below show recorded plays only.':'Play counts are fully recorded for these results.'),
    h('details',{class:'stats-disclosure'},h('summary',{},'About card statistics'),
      h('p',{class:'foot'},'In % of decks: the share of recorded deck appearances that started with the card. Each game contributes one appearance for each deck.'),
      h('p',{class:'foot'},'Average copies: copies in decks containing this card, weighted by games played. Deck win rate: wins by those decks, not the card’s individual contribution.'),
      h('p',{class:'foot'},'Times played: actual card plays, including replays and generated copies. Drawing, summoning or transforming a card does not add a play.'),
      h('p',{class:'foot'},coverage.completeSeats+' of '+coverage.totalSeats+' deck results have complete play tracking; '+(coverage.trackedSeats-coverage.completeSeats)+' have partial tracking. Missing history is not counted as zero.')),
    catalog.status==='failed'?h('div',{class:'state error'},h('p',{},'Could not load card names.'),h('button',{type:'button',class:'button small',onclick:fetchCatalog},'Retry'))
      :catalog.status==='loading'?h('p',{class:'state',role:'status'},'Loading card names…')
      :!rows.length?h('p',{class:'state',role:'status'},'No cards match. Clear your search or choose another faction.')
      :h('div',{class:'table-wrap'},h('table',{class:'stats-table card-statistics'},h('caption',{class:'sr-only'},'Card statistics'),
        h('thead',{},h('tr',{},heading('name','Card','Sort by card name'),heading('inDecks','In % of decks','Share of deck appearances containing this card'),
          heading('averageCopies','Avg. copies','Average copies among decks containing the card'),heading('deckWinRate','Deck win rate','Win rate of decks containing the card'),heading('timesPlayed','Times played','Actual recorded plays; older history can be incomplete'))),
        h('tbody',{},rows.map(row=>{const card=catalog.cards.get(row.id);return h('tr',{},
          h('th',{scope:'row'},h('details',{class:'card-row-details'},h('summary',{},card.name),
            h('p',{class:'foot'},card.manaCost+' mana · '+card.type.toLowerCase()+' · '+(S.FACTION_NAMES[card.color]||card.color)),
            h('p',{class:'rules'},card.description),h('p',{class:'foot'},row.appearances+' deck appearances containing this card.')),
            row.appearances>0&&small(row.appearances)?h('small',{class:'sample-note'},'Only '+row.appearances+' deck results.'):null),
          h('td',{class:'num'},S.pct(row.inDecks)),h('td',{class:'num'},row.averageCopies===null?'—':row.averageCopies.toFixed(1).replace(/\.0$/,'')),
          h('td',{class:'num strong'},S.pct(row.deckWinRate)),h('td',{class:'num',title:coverage.completeSeats<coverage.totalSeats?'At least this many plays were recorded; older history can be incomplete.':'Actual recorded plays'},row.timesPlayed===null?'—':(coverage.completeSeats<coverage.totalSeats?'≥ ':'')+row.timesPlayed.toLocaleString()));})))));
}

// ---- page ---------------------------------------------------------------------------------------------------
function tabs() {
  const items = [['explorer', 'Decks'], ['matrix', 'Matchups'], ['cards', 'Cards']];
  const current = route.view === 'deck' ? 'explorer' : route.view;
  return h('nav', { class: 'stats-tabs', ariaLabel: 'Statistics views' }, items.map(([view, label]) =>
    link({ view, deck: '', opp: '', q:'', sort:view==='cards'?'timesPlayed':'matches', dir:'desc' }, label, { ariaCurrent: current === view ? 'page' : undefined })),
    h('a', { href: '/stats/bots/' }, 'Check on the bots'));
}

function render() {
  if (!app) return;
  const body = [];
  if (route.demo) body.push(h('p', { class: 'demo-banner', role: 'note' }, 'DEMO DATA: synthetic results for previewing the layout. These are not recorded games.', ' ', link({ demo: false }, 'Leave demo', { class: 'text-link' })));
  const heading = route.view === 'cards' ? 'Card statistics' : route.view === 'matrix' ? 'Deck matchups' : 'Deck results';
  const intro = route.view === 'cards' ? 'See card popularity, deck win rates and recorded plays.' : route.view === 'matrix' ? 'Pick a deck to see which opponents it beats.' : 'See which decks are winning. Pick one to see its cards and what it beats.';
  body.push(h('header', { class: 'stats-head' }, h('p', { class: 'eyebrow' }, 'Playtest statistics'), h('h1', {}, heading),
    h('p', { class: 'lede' }, intro)));
  body.push(tabs());
  body.push(h('div', { class: 'stats-toolbar' }, resolvedLine(), cohortBar()));
  const status = statusPanel();
  if (status) body.push(status);
  else if (route.view === 'cards') body.push(cardsView());
  else if (load.snapshot && load.status === 'ok') body.push(route.view === 'deck' ? deckDetail() : route.view === 'matrix' ? matrixView() : explorer());
  app.replaceChildren(...body.filter(Boolean));
  document.title = heading+' — cardgame stats';
}

render();
fetchCatalog();
fetchCohort();
