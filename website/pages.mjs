import { TIERS, SUB_RANKS, LEGEND_TIERS, LP, LEGEND_STEP, DIVISION_COUNT, MATCH_SEARCH_SECONDS, REWARDS, exampleClimb } from './ranked-data.mjs';
export const escapeHtml = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const slug = value => value.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const arrow = '<span aria-hidden="true">↗</span>';
const button = (label, href, secondary = false) => `<a class="button${secondary ? ' secondary' : ''}" href="${href}"><span>${label}</span></a>`;

// Set by renderPages: where the relay is and which portraits the game offers.
let siteConfig = { relayUrl: '', portraits: [], catalogOrigin: '' };

function shell(title, active, content, description) {
  const nav = [['Home', '/'], ['Ranked', '/ranked/'], ['Glossary', '/glossary/'], ['Stats', '/stats/']];
  const playing = active === 'Play';
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${title === 'Home' ? 'cardgame — Space-age card battles in your browser' : `${title} — cardgame`}</title>
  <meta name="description" content="${escapeHtml(description)}"><meta name="theme-color" content="#060814">
  <link rel="icon" href="/media/logo.png" type="image/png"><meta name="cg-relay" content="${escapeHtml(siteConfig.relayUrl)}"><link rel="stylesheet" href="/style.css"><script type="application/json" data-portraits>${JSON.stringify(siteConfig.portraits).replace(/</g, '\\u003c')}</script><script src="/app.js" defer></script><script src="/account.js" defer></script>${active === 'Stats' ? `<meta name="cg-catalog" content="${escapeHtml(siteConfig.catalogOrigin)}"><script type="module" src="/stats.js"></script>` : ''}</head>
  <body${playing ? ' class="play-page"' : ''}><a class="skip-link" href="#main">Skip to content</a><header class="site-header"><div class="wrap header-inner">
  <a class="brand" href="/" aria-label="cardgame home"><img src="/media/logo.png" width="40" height="40" alt=""><span class="brand-word">CARD<b>GAME</b></span></a>
  <nav aria-label="Main navigation">${nav.map(([label, href]) => `<a href="${href}" ${active === label ? 'aria-current="page"' : ''}${playing && label !== 'Home' ? ' target="_blank" rel="noopener" aria-label="' + label + ' (opens in a new tab)"' : ''}>${label}</a>`).join('')}</nav>
  <div class="account-slot" data-account-slot aria-live="polite"><noscript><a class="account-link" href="/play/">Log in</a></noscript></div>
  <a class="nav-play" href="${playing ? '#play-area' : '/play/'}"${playing ? ' aria-current="page"' : ''}>${playing ? 'Playing' : 'Play now'}</a></div></header>
  <main id="main">${content}</main>
  ${playing ? '' : `<footer class="site-footer"><div class="wrap footer-inner"><a class="brand small" href="/"><img src="/media/logo.png" width="28" height="28" alt=""><span class="brand-word">CARD<b>GAME</b></span></a>
  <nav aria-label="Footer navigation"><a href="/rulebook/">Learn to play</a><a href="/glossary/">Keywords</a><a href="/play/">Enter the game</a></nav><span class="footer-note">Playtest build. Cards and rules may change.</span></div></footer>`}</body></html>`;
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
  ['01', 'Sapiens', 'green', 'sapiens', 'Hold the line.', 'Soldiers, tanks and a force that keeps coming back for another fight.', 'Reinforce', 'reinforce'],
  ['02', 'Moonlight Coven', 'crimson', 'coven', 'Become something else.', 'Creatures that grow, change shape and reward every transformation.', 'Ambush', 'ambush'],
  ['03', 'Junklings', 'black', 'junklings', 'Nothing goes to waste.', 'Dig through the graveyard and turn yesterday’s scrap into your next move.', 'Rummage', 'rummage'],
  ['04', 'Gundari', 'orange', 'gundari', 'Get in the machine.', 'Pair Pilots with Mechs and put something huge on the battlefield.', 'Pilot', 'pilot'],
  ['05', 'Mokotai', 'teal', 'mokotai', 'Meet them head-on.', 'Yeti, Guardians and Challenges that take the fight straight to your enemy.', 'Challenge', 'challenge'],
];

function home(featured, cardCount) {
  return shell('Home', 'Home', `<section class="hero"><div class="hero-art" aria-hidden="true"></div><div class="hero-grid" aria-hidden="true"></div><div class="wrap hero-inner">
  <div class="hero-copy"><p class="hero-kicker"><span class="status-dot"></span>Playtest build online</p>
  <h1 class="hero-title"><span class="sr-only">cardgame. </span><span aria-hidden="true">CARD<b>GAME</b></span></h1>
  <p class="hero-tagline">Space-age card battles. Pick a faction, build a deck, and take the board.</p>
  <div class="actions">${button('Play free', '/play/')}${button('How to play', '/rulebook/', true)}</div><p class="load-note">Runs in your browser. Nothing to install.</p></div>
  <div class="hero-cards" aria-label="Cards from three of the five factions">${cardMarkup(featured[1], 'back-left')}${cardMarkup(featured[2], 'back-right')}${cardMarkup(featured[0], 'front-card')}</div>
  </div><div class="hud-strip"><div class="wrap hud-inner"><span><b>${cardCount}</b> cards</span><span><b>5</b> factions</span><span><b>40</b> card decks</span><span>Versus AI or friends</span></div></div></section>
  <section id="factions" class="factions-section"><div class="wrap section-top"><h2>Choose your faction</h2><a class="text-link" href="/rulebook/#deckbuilding">How decks work ${arrow}</a></div>
  <div class="faction-rail">${factions.map(([number, name, color, art, line, copy, keyword, anchor]) => `<article class="faction ${color}" style="--art:url(/media/art/${art}.jpg)"><div class="faction-body"><span class="faction-number">${number}</span><h3>${name}</h3><h4>${line}</h4><p>${copy}</p><a class="keyword-chip" href="/glossary/#${anchor}">${keyword} ${arrow}</a></div></article>`).join('')}</div></section>
  <section class="wrap basics"><div class="basics-copy"><h2>Simple to start.<br>Hard to master.</h2><p>Play creatures, cast stratagems and use Locations to shape the board. Spend your mana, choose your attacks and bring the other hero to zero.</p></div>
  <div class="readouts"><div class="readout"><strong>30</strong><span>hero health</span></div><div class="readout"><strong>7</strong><span>board slots</span></div><div class="readout"><strong>10</strong><span>mana cap</span></div></div></section>
  <section class="wrap learn-grid"><a class="learn-tile" style="--art:url(/media/art/coven.jpg)" href="/rulebook/"><span class="tile-tag">Rulebook</span><h3>Learn the rules.</h3><p>From your opening hand to your last attack.</p><span class="text-link">Open the rulebook ${arrow}</span></a>
  <a class="learn-tile" style="--art:url(/media/art/mokotai.jpg)" href="/glossary/"><span class="tile-tag">Glossary</span><h3>Know your keywords.</h3><p>Guardian, Rummage, Pilot, Challenge and every other ability on the cards.</p><span class="text-link">Browse the glossary ${arrow}</span></a></section>
  <section class="final-cta"><div class="hero-art" aria-hidden="true"></div><div class="wrap final-inner"><h2>The board is waiting.</h2>${button('Enter the game', '/play/')}<p>Use a desktop browser with JavaScript and WebGL 2 enabled.</p></div></section>`, 'Play cardgame in your browser. Five factions, space-age card battles, learn the rules and look up every keyword.');
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


function ranked() {
  const climb = exampleClimb(3);
  const tierRow = (tier, index) => `<li class="ladder-tier" style="--tier:${tier.color}" data-tier="${index}"><img src="/media/ranks/${tier.icon}.png" width="72" height="72" alt="">
  <div class="tier-body"><h3>${tier.name}</h3><ol class="divisions" aria-label="${tier.name} divisions, highest first">${[...SUB_RANKS].reverse().map((sub) => {
    const division = index * SUB_RANKS.length + SUB_RANKS.indexOf(sub);
    return `<li data-division="${division}"><span class="division-name">${tier.name} ${sub}</span><span class="division-no">Division ${division + 1} of ${DIVISION_COUNT}</span></li>`;
  }).join('')}</ol></div></li>`;
  const legendRow = (tier, index) => `<li class="ladder-tier legend" style="--tier:${tier.color}" data-legend="${index}"><img src="/media/ranks/${tier.icon}.png" width="72" height="72" alt="">
  <div class="tier-body"><h3>${tier.name}</h3><p class="band">${tier.to === null ? `Rating ${tier.from.toLocaleString('en')} and up` : `Rating ${tier.from.toLocaleString('en')}–${tier.to.toLocaleString('en')}`}</p></div></li>`;
  return shell('Ranked', 'Ranked', `<section class="wrap page-heading"><span class="eyebrow">THE LADDER</span><h1>Climb the <em>ladder.</em></h1><p>Every ranked game moves you up or down a ladder of ${DIVISION_COUNT} divisions and three Legend bands. Here is exactly how it works, and every rung.</p></section>
  <section class="wrap ranked-how" aria-labelledby="how-heading"><h2 id="how-heading" class="sr-only">How ranked works</h2><div class="how-grid">
  <article class="how-card"><span class="how-no">01</span><h3>Play a ranked game</h3><p>Hit Ranked and the game searches for a human of similar skill for up to ${MATCH_SEARCH_SECONDS} seconds. If nobody is found you play a bot instead, so every search ends in a match. Bots start at difficulty 3 in Orbital III and get stronger as you climb, reaching difficulty 10 at Cosmic I. All Legend tiers use difficulty 10.</p></article>
  <article class="how-card"><span class="how-no">02</span><h3>Earn Ladder Points</h3><p>A win is worth <strong>+${LP.win} LP</strong>. From your <strong>${LP.winStreakFrom}rd win in a row</strong>, every win is worth <strong>+${LP.winStreak} LP</strong> until you lose. A loss costs <strong>${LP.loss} LP</strong>.</p></article>
  <article class="how-card"><span class="how-no">03</span><h3>Move up a division</h3><p>Each division holds <strong>${LP.perDivision} LP</strong>. Fill the bar and you move up, keeping any extra points. <strong>Losses never knock you down a division</strong>: your LP just stops at zero.</p></article>
  <article class="how-card"><span class="how-no">04</span><h3>Reach Legend</h3><p>Win from Cosmic I and you enter Legend. There are no divisions there: your Legend rating goes <strong>up ${LEGEND_STEP}</strong> for a win and <strong>down ${LEGEND_STEP}</strong> for a loss, and Universal has no ceiling.</p></article></div>
  <div class="ranked-notes"><div class="example" aria-label="Example"><h3>Example: a first division</h3><p>You start at 0 LP in Orbital III and win three games in a row.</p><ol>${climb.steps.map((s) => `<li>Win ${s.win}: +${s.gain} LP → <strong>${s.total} LP</strong></li>`).join('')}</ol><p>${climb.promoted ? `That passes ${LP.perDivision}, so you move up to Orbital II with <strong>${climb.carried} LP</strong> already banked.` : ''}</p></div>
  <div class="example"><h3>What else to know</h3><ul><li>Rank rewards: <strong>${REWARDS.rankUpCyllats} Cyllats</strong> each time you reach a new division.</li><li>Bot games count for your rank. The hidden rating used to pair you with other players is only changed by games against humans.</li><li>Falling out of Legend takes a loss while your Legend rating is under ${LEGEND_STEP}: you drop back to Cosmic I.</li><li>Playtest numbers can change as the game is tuned.</li></ul></div></div></section>
  <section class="wrap ladder-section" aria-labelledby="ladder-heading"><div class="section-top"><h2 id="ladder-heading">The whole ladder</h2><p class="ladder-you" data-ladder-you hidden></p></div>
  <p class="ladder-intro">Top of the ladder first. Within each tier, <strong>III is the lowest division and I is the highest</strong>. Every division takes ${LP.perDivision} LP to clear.</p>
  <ol class="ladder" data-ladder aria-label="Every rank, highest first"><li class="ladder-group"><h3 class="group-title">Legend <small>rating, no divisions</small></h3><ol class="ladder-tiers">${[...LEGEND_TIERS].reverse().map((t) => legendRow(t, LEGEND_TIERS.indexOf(t))).join('')}</ol></li>
  <li class="ladder-group"><h3 class="group-title">Divisions <small>${LP.perDivision} LP each</small></h3><ol class="ladder-tiers">${[...TIERS].reverse().map((t) => tierRow(t, TIERS.indexOf(t))).join('')}</ol></li></ol></section>
  <section class="final-cta"><div class="hero-art" aria-hidden="true"></div><div class="wrap final-inner"><h2>Your first division starts now.</h2>${button('Play ranked', '/play/')}</div></section>`, 'How cardgame ranked works: ladder points, divisions, the Legend tiers, and every rank from Orbital III to Universal.');
}

export function renderPages({ featured, keywords, relayUrl = '', portraits = [], cardCount = 0, catalogOrigin = '' }) {
  siteConfig = { relayUrl, portraits, catalogOrigin };
  return { 'index.html': home(featured, cardCount), 'rulebook/index.html': rulebook(featured), 'glossary/index.html': glossary(keywords),
    'play/index.html': shell('Play', 'Play', '<div id="play-area" class="game-mount" data-game-mount data-game-src="/play/game.html"><div class="game-message"><noscript><p>cardgame needs JavaScript to log you in and run the game.</p></noscript></div></div>', 'Play cardgame with the site navigation available above the game.'),
    'ranked/index.html': ranked(),
    'stats/index.html': shell('Stats', 'Stats', '<div class="wrap stats-page" data-stats-app><p class="state"><noscript>The statistics pages need JavaScript. </noscript>Loading…</p></div>', 'Exact-deck results from cardgame playtests: win rates, opponents and matchups, with sample sizes.'),
    'account/index.html': shell('Account', 'Account', '<section class="wrap profile-page" data-profile><p class="profile-message"><noscript>Your profile needs JavaScript. </noscript>Loading your account…</p></section>', 'Your cardgame account: rank, balances, profile picture and sign-in methods.') };
}
