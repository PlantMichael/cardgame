export const escapeHtml = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const slug = value => value.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const arrow = '<span aria-hidden="true">↗</span>';
const button = (label, href, secondary = false) => `<a class="button${secondary ? ' secondary' : ''}" href="${href}">${label} ${arrow}</a>`;

function shell(title, active, content, description) {
  const nav = [['Home', '/'], ['Rulebook', '/rulebook/'], ['Glossary', '/glossary/']];
  const playing = active === 'Play';
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${title === 'Home' ? 'cardgame — Pick a faction. Make your move.' : `${title} — cardgame`}</title>
  <meta name="description" content="${escapeHtml(description)}"><meta name="theme-color" content="#101914">
  <link rel="icon" href="/media/logo.png" type="image/png"><link rel="stylesheet" href="/style.css"><script src="/app.js" defer></script></head>
  <body${playing ? ' class="play-page"' : ''}><a class="skip-link" href="#main">Skip to content</a><header class="site-header"><div class="wrap header-inner">
  <a class="brand" href="/" aria-label="cardgame home"><img src="/media/logo.png" width="42" height="42" alt="">cardgame<span class="brand-period">.</span></a>
  <nav aria-label="Main navigation">${nav.map(([label, href]) => `<a href="${href}" ${active === label ? 'aria-current="page"' : ''}${playing && label !== 'Home' ? ' target="_blank" rel="noopener" aria-label="' + label + ' (opens in a new tab)"' : ''}>${label}</a>`).join('')}</nav>
  <a class="nav-play" href="${playing ? '#game' : '/play/'}"${playing ? ' aria-current="page"' : ''}>${playing ? 'Playing' : 'Play now'} <span aria-hidden="true">↗</span></a></div></header>
  <main id="main">${content}</main>
  ${playing ? '' : `<footer class="site-footer wrap"><a class="brand small" href="/">cardgame<span class="brand-period">.</span></a><p>Five factions. One battlefield.</p>
  <nav aria-label="Footer navigation"><a href="/rulebook/">Learn to play</a><a href="/glossary/">Keywords</a><a href="/play/">Enter the game ↗</a></nav><span class="footer-note">An evolving playtest. Cards and rules may change.</span></footer>`}</body></html>`;
}

function cardMarkup(card, extra = '') {
  return `<article class="game-card ${card.color.toLowerCase()} ${extra}" aria-label="${escapeHtml(card.card_name)} card">
  <img class="card-frame" src="/media/card-${card.color.toLowerCase()}.png" alt="">
  <img class="card-art" src="${card.image}" width="1232" height="928" alt="">
  <div class="mana" aria-label="Mana cost ${card.cost}"><img src="/media/${card.color.toLowerCase()}mana.png" alt=""><span>${card.cost}</span></div>
  <div class="card-name">${escapeHtml(card.card_name)}</div>
  <img class="card-rarity" src="/media/common-grey.png" alt="Common">
  <div class="card-symbols"><img src="/media/tribe-creature.png" alt="Creature">${card.tribe === 'yeti' ? '<img src="/media/tribe-yeti.png" alt="Yeti">' : ''}</div>
  ${card.abilities?.includes('reinforce') ? '<img class="card-reinforce" src="/media/tribe-reinforce.png" alt="Reinforce">' : ''}
  <p class="card-text">${escapeHtml(card.description)}</p><div class="card-stats"><span aria-label="Attack ${card.attack}">${card.attack}</span><span aria-label="Health ${card.health}">${card.health}</span></div></article>`;
}

const factions = [
  ['01', 'Sapiens', 'green', 'Hold the line.', 'Soldiers, Reinforce, and a force that comes back for another fight.', 'Reinforce', 'reinforce'],
  ['02', 'Moonlight Coven', 'crimson', 'Become something else.', 'A coven of creatures that grow, change form, and reward transformation.', 'Ambush', 'ambush'],
  ['03', 'Junklings', 'black', 'Nothing goes to waste.', 'Make use of the graveyard and turn yesterday’s scraps into your next move.', 'Rummage', 'rummage'],
  ['04', 'Gundari', 'orange', 'Get in the machine.', 'Bring Pilots and Mechs together to build a bigger threat on the battlefield.', 'Pilot', 'pilot'],
  ['05', 'Mokotai', 'teal', 'Meet them head-on.', 'Yeti, Guardians, and Challenges that take the fight straight to enemy creatures.', 'Challenge', 'challenge'],
];

function home(featured) {
  return shell('Home', 'Home', `<section class="hero"><div class="hero-world" aria-hidden="true"></div><div class="wrap hero-inner">
  <div class="hero-copy"><div class="eyebrow"><span class="status-dot"></span> A BROWSER CARD GAME · IN PLAYTEST</div>
  <h1>Pick a faction.<br>Make your <em>move.</em></h1><p class="hero-description">Soldiers. Shape-shifters. Scrap-built machines.<br class="desktop-break"> Build your deck and bring your own kind of trouble to the battlefield.</p>
  <div class="actions">${button('Play cardgame', '/play/')}${button('Learn to play', '/rulebook/', true)}</div><p class="load-note">Play in your browser. The game downloads when you open it.</p></div>
  <div class="hero-cards" aria-label="Cards from three of the five factions">${cardMarkup(featured[1], 'back-left')}${cardMarkup(featured[2], 'back-right')}${cardMarkup(featured[0], 'front-card')}<span class="orbit-label">YOUR DECK. YOUR NEXT MOVE.</span></div>
  </div><div class="wrap hero-bottom"><span>TURN-BASED STRATEGY</span><span>FIVE DISTINCT FACTIONS</span><span>PLAY AGAINST AI OR FRIENDS</span></div></section>
  <section class="wrap introduction"><div><span class="eyebrow">THE BATTLEFIELD IS YOURS</span><h2>A little planning.<br>A lot of possibilities.</h2></div><div class="intro-copy"><p>Play creatures, cast stratagems, and use Locations to shape the board. Spend your mana, choose your attacks, and push the opposing hero to zero.</p><div class="rule-numbers"><div><strong>30</strong><span>starting health</span></div><div><strong>7</strong><span>board slots</span></div><div><strong>10</strong><span>maximum mana</span></div></div></div></section>
  <section id="factions" class="factions-section"><div class="wrap"><div class="section-heading"><div><span class="eyebrow">FIND YOUR SIDE</span><h2>Five factions.<br>Five ways to start trouble.</h2></div><a class="text-link" href="/rulebook/#deckbuilding">How decks work ${arrow}</a></div>
  <div class="faction-list">${factions.map(([number, name, color, line, copy, keyword, anchor]) => `<article class="faction-row ${color}"><span class="faction-number">${number}</span><div class="faction-heading"><span class="faction-swatch" aria-hidden="true"></span><h3>${name}</h3></div><div class="faction-copy"><h4>${line}</h4><p>${copy}</p></div><a class="keyword-link" href="/glossary/#${anchor}">${keyword} ${arrow}</a></article>`).join('')}</div></div></section>
  <section class="wrap learn-section"><div class="section-heading"><div><span class="eyebrow">GET YOUR BEARINGS</span><h2>Your first game starts here.</h2></div></div><div class="learning-grid">
  <a class="learn-tile" href="/rulebook/"><span class="tile-number">01 / THE BASICS</span><h3>Learn the rules.</h3><p>From your opening hand to your final attack. A practical guide to the battlefield.</p><span class="text-link">Open the rulebook ${arrow}</span></a>
  <a class="learn-tile" href="/glossary/"><span class="tile-number">02 / THE DETAILS</span><h3>Know your keywords.</h3><p>Guardian? Rummage? Pilot? Look up the abilities printed on your cards.</p><span class="text-link">Browse the glossary ${arrow}</span></a></div></section>
  <section class="wrap final-cta"><span class="eyebrow">ENOUGH READING?</span><h2>There’s a move with<br>your name on it.</h2>${button('Enter the game', '/play/')}<p>Use a desktop browser with JavaScript and WebGL 2 enabled. Open the hosted game over HTTPS.</p></section>`, 'Play cardgame in your browser. Discover five factions, learn the rules, and look up every printed keyword.');
}

const chapters = [
  ['the-goal', '01', 'One hero left standing', `<p>Both heroes begin with <strong>30 health</strong>. Reduce the opposing hero to zero to win. Your creatures can attack enemy creatures or the enemy hero, subject to abilities such as <a href="/glossary/#guardian">Guardian</a>.</p><p>Start with a game against the AI to get familiar with the board. The game also includes online multiplayer.</p>`],
  ['opening-hand', '02', 'Your opening hand', `<p>A random choice decides who goes first. The first player starts with <strong>3 cards</strong>; the second starts with <strong>4</strong>. During the opening mulligan, select the cards you want to replace and confirm once. Selected cards return to your deck, which is shuffled before replacements are drawn.</p><p>Neither player draws on their own first turn. On later turns, the active player draws one card at the start.</p>`],
  ['your-turn', '03', 'Make the most of your turn', `<ol class="turn-steps"><li><strong>Gain mana.</strong> Your maximum mana increases by one, up to 10, and your available mana refreshes.</li><li><strong>Draw.</strong> After your first turn, draw one card from your deck.</li><li><strong>Take your actions.</strong> Play affordable cards, attack with ready creatures, and resolve any target or ability prompts. You can choose the order of your legal actions.</li><li><strong>End your turn.</strong> When you are done, use End Turn. The other player takes their turn.</li></ol><p>Unused mana does not carry over. Card costs and effects can be modified during a game; use the value shown on the card in your hand.</p>`],
  ['card-types', '04', 'Three kinds of cards', `<div class="type-list"><div><span class="type-label">CREATURE</span><h3>Your presence on the board.</h3><p>A creature has attack and health and occupies board space. It normally waits until your next turn to attack. <a href="/glossary/#rush">Rush</a> lets it attack on the turn it is played.</p></div><div><span class="type-label">STRATAGEM</span><h3>A play that changes the situation.</h3><p>Pay its mana cost, choose a target if prompted, and resolve its effect. Stratagems do not occupy a board slot.</p></div><div><span class="type-label">LOCATION</span><h3>A lasting battlefield effect.</h3><p>A Location occupies board space and has health. It has health rather than an attack stat and cannot attack. Its printed effect applies while it remains in play.</p></div></div>`],
  ['combat', '05', 'Choose your fights', `<p>A ready creature with attack above zero can normally attack once per turn. Select a valid enemy creature or the enemy hero. In creature combat, both sides deal their attack damage to each other; surviving health carries forward.</p><p>Enemy Guardians must be attacked before other targets. <a href="/glossary/#ambush">Ambush</a> can prevent targeting. Abilities such as <a href="/glossary/#shielded">Shielded</a>, <a href="/glossary/#ethereal">Ethereal</a>, and <a href="/glossary/#dual-strike">Dual Strike</a> change how combat resolves.</p><p>Card text matters. A Challenge or an on-play effect can behave differently from a normal attack. Resolve the choices shown by the game.</p>`],
  ['board-and-hand', '06', 'Know your limits', `<dl class="limits"><div><dt>7 board slots</dt><dd>Creatures and Locations use board space. A <a href="/glossary/#colossal">Colossal</a> creature uses two slots instead of one.</dd></div><div><dt>10 cards in hand</dt><dd>If your hand is full when you draw, the drawn card is burned rather than added to your hand.</dd></div><div id="fatigue"><dt>An empty deck means fatigue</dt><dd>Trying to draw from an empty deck deals increasing damage to your hero: 1 on the first attempt, then 2, then 3, and so on.</dd></div></dl>`],
  ['deckbuilding', '07', 'Build around a faction', `<p>Choose a faction for your deck. Use cards from that faction and the Generic pool. Decks can contain <strong>up to 40 cards</strong>, with at most <strong>two copies</strong> of a card. Legendary cards are limited to <strong>one copy</strong>.</p><p>Look for cards that work together: Sapiens and Reinforce, the Coven’s transformations, Junkling graveyard tools, Gundari Pilots and Mechs, or Mokotai Yeti and Challenges. The faction themes are a starting point; the full card text describes what each card actually does.</p>`],
  ['special-abilities', '08', 'When a card bends the rules', `<p>Keywords are shorthand for an ability. Some include a number, such as Shielded or Pilot bonuses; use the number printed on that card. On-play, on-death, and transformation text can create further effects and choices.</p><p>For Pilot, look for an eligible friendly, unpiloted Mech. If no valid target exists, there may be nothing to select. Follow the game’s target prompts and the individual card’s text.</p><p><a class="text-link" href="/glossary/">Look up all printed keywords ${arrow}</a></p>`],
];

function rulebook(featured) {
  return shell('Rulebook', 'Rulebook', `<section class="wrap page-heading"><span class="eyebrow">THE FIELD GUIDE / 01</span><h1>Learn the <em>game.</em></h1><p>Your opening hand. Your next attack. Everything you need to find your feet on the battlefield.</p></section>
  <div class="wrap book-layout"><aside class="book-nav"><span class="eyebrow">IN THIS GUIDE</span><nav aria-label="Rulebook chapters">${chapters.map(([id, number, title]) => `<a href="#${id}"><span>${number}</span>${title}</a>`).join('')}</nav><a class="text-link" href="/glossary/">Need a definition? ${arrow}</a></aside>
  <div class="book-content"><section class="quick-start"><span class="eyebrow">BEFORE YOUR FIRST MATCH</span><h2>The short version.</h2><p>Spend mana to play cards. Use your creatures to control the board. Bring the opposing hero from 30 health to zero.</p><div class="quick-facts"><span>30 health</span><span>7 board slots</span><span>10 mana cap</span></div></section>
  ${chapters.map(([id, number, title, body], i) => `<section class="chapter" id="${id}"><span class="chapter-number">${number}</span><h2>${title}</h2>${body}${i === 3 ? `<figure class="card-example">${cardMarkup(featured[0])}<figcaption><h3>Reading a creature card</h3><p>The number at the top is its mana cost. At the bottom, the left value is attack and the right value is health. Text in the middle describes its abilities.</p><p>Cocky Commando costs 2 mana and starts at 2 attack and 1 health. <a href="/glossary/#reinforce">Reinforce</a> gives it another chance on the battlefield.</p></figcaption></figure>` : ''}</section>`).join('')}
  <div class="book-end"><h2>Ready to try it?</h2><p>The best next step is a match.</p>${button('Play cardgame', '/play/')}</div></div></div>`, 'Learn cardgame: opening hands, turns, mana, combat, board limits, deckbuilding and card abilities.');
}

function glossary(keywords) {
  const entries = Object.entries(keywords).sort(([a], [b]) => a.localeCompare(b, 'en'));
  return shell('Glossary', 'Glossary', `<section class="wrap page-heading"><span class="eyebrow">THE FIELD GUIDE / 02</span><h1>Every keyword.<br><em>One place.</em></h1><p>Know what your cards can do. These are the keyword definitions used by the game.</p></section>
  <section class="wrap glossary-layout" aria-label="Keyword glossary"><div class="glossary-toolbar"><form class="search-form" role="search" hidden data-glossary-search><label for="keyword-search">Find a keyword</label><div class="search-input-row"><span aria-hidden="true">⌕</span><input id="keyword-search" type="search" placeholder="Try Guardian, Pilot, or combat…" autocomplete="off"><button type="button" id="clear-search">Clear</button></div></form><p class="term-count" role="status" aria-live="polite" id="result-count">${entries.length} keywords</p></div>
  <p class="glossary-note">A number on a keyword comes from the individual card. For turn structure, deck limits, and fatigue, see the <a href="/rulebook/">rulebook</a>.</p>
  <div class="keyword-grid">${entries.map(([name, description], i) => `<article class="keyword-entry" id="${slug(name)}" data-keyword><div class="keyword-top"><span class="keyword-number">${String(i + 1).padStart(2, '0')}</span><a class="permalink" href="#${slug(name)}" aria-label="Link to ${escapeHtml(name)}">#</a></div><h2>${escapeHtml(name)}</h2><p>${escapeHtml(description.replace("Add's", 'Adds'))}</p></article>`).join('')}</div>
  <div class="empty-search" id="no-results" hidden><h2>No keywords found.</h2><p>Try a shorter word, an ability name, or a word from its description.</p><button class="button secondary" type="button" id="reset-search">Show all keywords</button></div>
  <div class="glossary-bottom"><p>New to the battlefield? Start with the basics.</p><a class="text-link" href="/rulebook/">Read the rulebook ${arrow}</a></div></section>`, 'Search cardgame keyword definitions, including Guardian, Reinforce, Rummage, Pilot, Challenge, and Colossal.');
}

export function renderPages({ featured, keywords }) {
  return { 'index.html': home(featured), 'rulebook/index.html': rulebook(featured), 'glossary/index.html': glossary(keywords),
    'play/index.html': shell('Play', 'Play', '<iframe id="game" class="game-window" title="cardgame game window" src="/play/game.html" allow="fullscreen" allowfullscreen></iframe>', 'Play cardgame with the site navigation available above the game.') };
}
