# cardgame website

The public home, rulebook and glossary wrap the existing Godot Web export on the same Vercel project. Node 20+ is sufficient; no package installation or framework is needed.

```sh
node website/build.mjs
node website/preview.mjs
node --test website/test/site.test.mjs
```

The preview serves `http://127.0.0.1:8943` (override `PORT` if needed). Run the build again and reload after edits. `/` introduces the game, `/rulebook/` teaches the rules, `/glossary/` provides searchable keyword definitions, and `/play/` embeds the existing game below the site header. Rulebook and Glossary links on Play open separately, keeping the game running; the Playing link focuses the game instead of restarting it. Rulebook and glossary content is readable without JavaScript. Glossary search works locally and sends no search data to a service.

`pages.mjs` owns page copy and shared HTML, `style.css` owns the design, and `app.js` adds glossary filtering. The build reads `data/keywords.json` directly and selected cards from the faction JSON. Card previews use the original illustrations, card frame/mana/symbol textures from `assets/card_assets/`, and `assets/fonts/Orbitron.ttf`, with layout proportions from `scenes/cards/Card.tscn`. The header and favicon use `assets/cardgame/Ranks/cardgame-logo.png` unchanged. Definitions update on the next website build; rules changes also need a source-checked edit to the authored rulebook. Featured card IDs are in `build.mjs`. The source of truth for deck limits is `deck_manager.gd`, opening turns/combat is `game_state.gd`, and health/hand/mana/board limits is `player_state.gd`.

`build/` remains the Godot export source. After a gameplay change, export Web to `build/index.html` using the existing preset, then rebuild the website. The site build copies runtime files unchanged into ignored `website-dist/play/`, naming the original bootstrap `game.html` so `play/index.html` can hold the site shell and same-origin iframe. Its relative script/package URLs still work. It does not export or modify Godot resources. Original root runtime URLs remain as compatibility copies for already cached bootstrap pages. Avoid placing private files in `build/` or the website source.

`vercel.json` selects the dependency-free build and `website-dist/` output. Directory indexes and trailing slashes give static routes without an SPA fallback. Game bootstrap/runtime cache headers cover both the new Play location and the original runtime URLs. Publishing uses the existing Git-connected Vercel project; no separate Sites project or domain is required. After a push, confirm the resulting Vercel deployment succeeds and verify home, learning routes, game initialization and deployed cache headers. The game's account/login screen and same-origin save keys are unchanged. Preview URLs have their own browser origin, so they do not share saves or sessions with a different production hostname.

The Node tests compose a real temporary output and exercise its HTTP URLs, links, keyword content, escaping, original game asset/runtime hashes, MIME types and error statuses. Render and interact at desktop and mobile widths after visual changes; test glossary matches, no matches, clear, anchors, keyboard focus, and the actual unauthenticated game launch inside the frame. Check that the header remains visible and learning links do not reset the frame. No real account or ranked match is needed for website QA.

Accounts, Google sign-in, the page-to-game bridge, relay setup and the account tests are documented in [ACCOUNTS.md](ACCOUNTS.md). The banner, `/account/` profile and `/play/` hand-off come from `account.js`; the Play page no longer embeds the game directly but mounts it once an account is established, and the game takes its session from the page instead of showing its own login.
