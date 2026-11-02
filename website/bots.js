import { BOT_NAMES, ACTIVITIES, validStatus, rankDisplay } from '/bots-core.mjs';
const app = document.querySelector('[data-bots-app]');
const grid = app?.querySelector('[data-bot-grid]');
const message = app?.querySelector('[data-bot-message]');
const updated = app?.querySelector('[data-bot-updated]');
const refresh = app?.querySelector('[data-bot-refresh]');
const origin = document.querySelector('meta[name="cg-catalog"]')?.content;
let sequence = 0, controller, timer, snapshot;
const el = (tag, className, text) => {
  const node = document.createElement(tag); node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};
function render(state) {
  const cards = Object.entries(BOT_NAMES).map(([id, name]) => {
    const bot = state === 'ok' ? snapshot.bots.find(b => b.id === id) : null;
    const card = el('article', 'bot-card');
    const head = el('div', 'bot-card-head');
    head.append(el('h2', '', name), el('span', 'bot-version', bot ? `v${bot.version}` : ''));
    card.append(head, el('p', 'bot-personality', bot ? `Level ${bot.level} · ${bot.style}` : 'Ranked bot'));
    card.append(el('p', `bot-activity ${bot?.activity || ''}`, bot ? ACTIVITIES[bot.activity]
      : state === 'loading' ? 'Checking activity…' : 'Status unavailable'));
    const rank = bot ? rankDisplay(bot.rank) : { name: '—', progress: state === 'loading' ? 'Loading rank…' : 'Rank unavailable', icon: null };
    const row = el('div', 'bot-rank');
    const icon = el('div', 'bot-rank-icon');
    if (rank.icon) {
      const img = document.createElement('img'); img.src = `/media/ranks/${rank.icon}.png`;
      img.alt = ''; img.width = 64; img.height = 64; icon.append(img);
    }
    const words = el('div', 'bot-rank-copy');
    words.append(el('p', 'bot-rank-name', rank.name), el('p', 'bot-rank-progress', rank.progress));
    row.append(icon, words); card.append(row); return card;
  });
  grid.replaceChildren(...cards);
  message.textContent = state === 'error' ? 'Could not check the bots. Try again; unavailable does not mean offline.' : '';
  refresh.textContent = state === 'error' ? 'Retry' : 'Refresh now';
  updated.textContent = snapshot ? `${state === 'error' ? 'Last successful check' : 'Checked'} ${new Date(snapshot.generatedAt).toLocaleTimeString()}` : 'Waiting for the first check';
}
async function load() {
  clearTimeout(timer); controller?.abort();
  const current = ++sequence;
  const ownController = new AbortController();
  controller = ownController;
  const deadline = setTimeout(() => ownController.abort(new Error('Bot status request timed out')), 8000);
  refresh.disabled = true; grid.setAttribute('aria-busy', 'true');
  if (!snapshot) render('loading');
  try {
    const response = await fetch(new URL('/data/bots/status.json', origin), { signal: controller.signal, cache: 'no-store' });
    if (!response.ok) throw new Error('unavailable');
    const data = await response.json();
    if (current !== sequence) return;
    if (!validStatus(data)) throw new Error('invalid status');
    snapshot = data; render('ok');
  } catch (error) {
    if (current === sequence && error.name !== 'AbortError') render('error');
  } finally {
    clearTimeout(deadline);
    if (current === sequence) {
      refresh.disabled = false; grid.setAttribute('aria-busy', 'false'); controller = null;
      if (!document.hidden) timer = setTimeout(load, 10000);
    }
  }
}
if (app) {
  refresh.addEventListener('click', load);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { sequence++; clearTimeout(timer); controller?.abort(); controller = null; refresh.disabled = false; }
    else load();
  });
  window.addEventListener('pagehide', () => { sequence++; clearTimeout(timer); controller?.abort(); });
  window.addEventListener('pageshow', event => { if (event.persisted && !document.hidden) load(); });
  render('loading');
  if (!document.hidden) load();
}
