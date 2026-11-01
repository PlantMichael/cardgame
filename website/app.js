const searchForm = document.querySelector('[data-glossary-search]');
if (searchForm) {
  const input = document.querySelector('#keyword-search');
  const entries = [...document.querySelectorAll('[data-keyword]')];
  const count = document.querySelector('#result-count');
  const empty = document.querySelector('#no-results');
  const clear = document.querySelector('#clear-search');
  function filter() {
    const query = input.value.trim().toLocaleLowerCase();
    let matches = 0;
    for (const entry of entries) {
      entry.hidden = !entry.textContent.toLocaleLowerCase().includes(query);
      if (!entry.hidden) matches++;
    }
    count.textContent = `${matches} of ${entries.length} keywords`;
    empty.hidden = matches !== 0;
    clear.disabled = !input.value;
  }
  function reset() { input.value = ''; filter(); input.focus(); }
  input.addEventListener('input', filter);
  searchForm.addEventListener('submit', event => { event.preventDefault(); filter(); });
  clear.addEventListener('click', reset);
  document.querySelector('#reset-search').addEventListener('click', reset);
  // A direct definition link should remain readable after filtering.
  window.addEventListener('hashchange', () => {
    let target;
    try { target = document.getElementById(decodeURIComponent(location.hash.slice(1))); }
    catch { return; }
    if (target?.hidden) {
      input.value = ''; filter();
      target.scrollIntoView();
    }
  });
  searchForm.hidden = false;
  filter();
}

// Ranked page: mark the signed-in player's current rung.
const ladder = document.querySelector('[data-ladder]');
if (ladder) {
  const you = document.querySelector('[data-ladder-you]');
  const mark = (account) => {
    ladder.querySelectorAll('.here').forEach((n) => { n.classList.remove('here'); n.removeAttribute('aria-current'); });
    if (!account) { you.hidden = true; return; }
    const target = account.rank_in_legend
      ? ladder.querySelector(`[data-legend="${Math.min(Math.floor(account.rank_legend_rating / 500), 2)}"]`)
      : ladder.querySelector(`[data-division="${account.rank_bracket}"]`);
    if (!target) return;
    target.classList.add('here');
    target.setAttribute('aria-current', 'true');
    you.textContent = account.rank_in_legend ? `You are in Legend (rating ${account.rank_legend_rating}).` : `You are here, with ${account.rank_lp} / 100 LP.`;
    you.hidden = false;
  };
  window.addEventListener('cardgame:account', (e) => mark(e.detail));
  mark(window.cardgameSite?.account?.() || null);
}
