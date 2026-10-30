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
