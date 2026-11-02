# Stats tab

`/stats/` shows exact-deck results from the catalog's deck-matchups API, folded into the site from the separate statistics project. It is a static page driven by `stats.js` (rendering and fetching) and `stats-core.mjs` (pure logic, shared with the tests).

## Views (all in the address, so a link reopens the same analysis)

| View | Address keys | What it shows |
|---|---|---|
| Decks | `view` omitted | Three columns: deck, win rate and games played. Faction and deck/card-name search are visible; excluded card, minimum games and extra sorting live under More filters (role selection only for old filtered links). Small samples get a plain-language warning. |
| Deck detail | `view=deck&deck=<id>&role=<combined\|human\|ai>` | Starting cards, win rate, games played and a three-column opponent table. `opp` and `oppRole` select an opponent and show its cards. Record, statistical range, testers, average turns, turn-order splits and full deck ID are available in optional details. |
| Exact-deck matchups | `view=matrix&rows=&cols=` | A deck picker and Opponent / Win rate / Games played table. Selected pair details and cards expand on demand; the optional comparison grid retains real-zero versus missing-pair distinctions. |
| Cards | `view=cards` | The screenshot metrics: In % of decks, Average copies, Deck win rate, Times played; sortable, searchable and filtered by faction. Card text/details expand from the name. Uses the same snapshot/date/rules selection as every tab. |

The cohort bar sends only `mode, days, rulesVersion, aiVersion, aiLevel` to the server. Switching to PvP removes the AI keys from the address and the request. Results are shown with the resolved `filters` from the response, not the requested "latest". A newer selection supersedes a slower older request, successful snapshots are reused for 60 seconds, and failures are shown as unavailable, never as zero games.

Default mode=all pools eligible ranked-AI, human PvP and automated ranked-bot games and controller roles. The bots' existing results contribute to deck records, matchups and card metrics without backfilling or changing stored versions. “Players recorded” counts distinct humans, so a bot-only record can show zero. The game-type/AI controls are removed. Date/rules controls are collapsed under “Date range and game version”; a short line identifies the resolved dataset and total games. Existing filtered API URLs and role keys remain supported. “About these results” explains the mixed sources and that repeated bot games can dominate samples. Public results do not contain saved player deck names: labels use the faction plus a number when distinct lists share it, with two high-cost card names beneath each list row for recognition. The same list has the same label in both roles. Numbers are local to the returned results and can change when the selected data changes; links continue to use the exact ID and role. No lists or outcomes are merged by their display labels. Isolated non-ranked simulations remain separate.

## Configuration and build

`CARDGAME_CATALOG_ORIGIN` (default `https://cardgame-catalog-production.up.railway.app`) is baked into the page as `<meta name="cg-catalog">` at build time. No key or login is needed.

## Demo data

`/stats/?demo=1` loads `media/stats-demo-combined.json` (old filtered links use `media/stats-demo.json`), a **synthetic** snapshot in the real schema (real card ids, invented results; `website/tools/stats-fixture.mjs`), and shows a banner saying so. It exists to review the layout while the live route is unavailable and to drive the tests. The page never falls back to it by itself.

## Tests

```sh
node --test website/test/stats.test.mjs website/test/site.test.mjs
```

`stats.test.mjs` covers the arithmetic and routing rules from the API contract against the synthetic fixture: the same deck in both roles, reversed matchup perspectives, a real 0% record against a missing matchup, null turns, 2 of 3 as 66.7%, AI keys removed for PvP, address round trips, filters and sorting, and rejection of malformed snapshots. The rendering and request-race code in `stats.js` was checked by hand in a browser at desktop and phone widths, not by automated DOM tests.

## Service availability

The configured catalog must serve `/data/stats/deck-matchups.json`. If unavailable, the live page shows an error and Retry; it never substitutes demo results or treats a failed request as zero games. Deploy the compatible relay/catalog additions before switching the website to mode=all. See the catalog developer contract for pooling, privacy, count bounds and partial historical play coverage.

## Card statistics

Card metrics weight exact starting lists by recorded deck appearances. Average copies is conditional on inclusion; deck win rate measures outcomes of the whole deck. Times played uses actual recorded events, including replays/generated copies, and is independent of inclusion. No play coverage displays an em dash; incomplete coverage displays a lower bound (≥) with a visible note and exact coverage under About card statistics. Old AI games lack these events; older PvP history can be partial. Never turn unavailable/unknown recording into a zero. Definitions and formulas are in [the API contract](../catalog/stats-website-spec.md#recorded-plays-and-card-table-formulas).
