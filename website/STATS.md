# Stats tab

`/stats/` shows exact-deck results from the catalog's deck-matchups API, folded into the site from the separate statistics project. It is a static page driven by `stats.js` (rendering and fetching) and `stats-core.mjs` (pure logic, shared with the tests).

## Views (all in the address, so a link reopens the same analysis)

| View | Address keys | What it shows |
|---|---|---|
| Decks | `view` omitted | Deck explorer: win rate, record, seat-games, testers, Wilson interval, average turns, mana curve, share of human seat-games. Sort, faction, include/exclude card, minimum sample (starts at 1), human or AI decks. |
| Deck detail | `view=deck&deck=<id>&role=<human\|ai>` | Full starting list, record, splits by turn order, and an opponent table. `opp` and `oppRole` select an opponent and show its full list beside the table. |
| Exact-deck matchups | `view=matrix&rows=&cols=` | Row deck's result against each column deck. "No games" is shown for a missing pairing and is different from a real 0-win record. Every cell is a button; a list of all pairings is available below. |
| Cards | `view=cards` | Printed cards with the starting-deck inclusion win rate, labelled as not controlled card strength and not following the cohort. |

The cohort bar sends only `mode, days, rulesVersion, aiVersion, aiLevel` to the server. Switching to PvP removes the AI keys from the address and the request. Results are shown with the resolved `filters` from the response, not the requested "latest". A newer selection supersedes a slower older request, successful snapshots are reused for 60 seconds, and failures are shown as unavailable, never as zero games.

## Configuration and build

`CARDGAME_CATALOG_ORIGIN` (default `https://cardgame-catalog-production.up.railway.app`) is baked into the page as `<meta name="cg-catalog">` at build time. No key or login is needed.

## Demo data

`/stats/?demo=1` loads `media/stats-demo.json`, a **synthetic** snapshot in the real schema (real card ids, invented results; `website/tools/stats-fixture.mjs`), and shows a banner saying so. It exists to review the layout while the live route is unavailable and to drive the tests. The page never falls back to it by itself.

## Tests

```sh
node --test website/test/stats.test.mjs website/test/site.test.mjs
```

`stats.test.mjs` covers the arithmetic and routing rules from the API contract against the synthetic fixture: the same deck in both roles, reversed matchup perspectives, a real 0% record against a missing matchup, null turns, 2 of 3 as 66.7%, AI keys removed for PvP, address round trips, filters and sorting, and rejection of malformed snapshots. The rendering and request-race code in `stats.js` was checked by hand in a browser at desktop and phone widths, not by automated DOM tests.

## Open integration items

- The deck-matchups route is not on `master` and is not deployed: it lives in commit `e3c9c9e` on the `codex/green-card-frame` branch. Until the relay and catalog serving it are deployed, the live page shows its "not available on this server yet" state.
- That branch already uses the flat `/data/stats/...` paths this page calls, so no path changes are expected. It was cut before the site redesign and Google sign-in merged, so merging it is an ordinary merge of its relay and catalog files; deploy the relay, then the catalog.
