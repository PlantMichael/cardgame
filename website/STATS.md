# Stats tab

`/stats/` shows exact-deck results from the catalog's deck-matchups API, folded into the site from the separate statistics project. It is a static page driven by `stats.js` (rendering and fetching) and `stats-core.mjs` (pure logic, shared with the tests).

## Views (all in the address, so a link reopens the same analysis)

| View | Address keys | What it shows |
|---|---|---|
| Decks | `view` omitted | Three columns: deck, win rate and games played. Faction and deck/card-name search are visible; role, excluded card, minimum games and extra sorting live under More filters. Small samples get a plain-language warning. |
| Deck detail | `view=deck&deck=<id>&role=<human\|ai>` | Starting cards, win rate, games played and a three-column opponent table. `opp` and `oppRole` select an opponent and show its cards. Record, statistical range, testers, average turns, turn-order splits and full deck ID are available in optional details. |
| Exact-deck matchups | `view=matrix&rows=&cols=` | Row deck's result against each column deck. "No games" is shown for a missing pairing and is different from a real 0-win record. Every cell is a button; a list of all pairings is available below. |
| Cards | `view=cards` | Printed cards with the starting-deck inclusion win rate, labelled as not controlled card strength and not following the cohort. |

The cohort bar sends only `mode, days, rulesVersion, aiVersion, aiLevel` to the server. Switching to PvP removes the AI keys from the address and the request. Results are shown with the resolved `filters` from the response, not the requested "latest". A newer selection supersedes a slower older request, successful snapshots are reused for 60 seconds, and failures are shown as unavailable, never as zero games.

The game type/date/version controls are collapsed under “Change game type or date range”; a short line always identifies the resolved game type, date range and total games. “About these results” retains source, version and sampling limitations. Public results do not contain saved player deck names: labels use the faction plus a number when distinct lists share it, with two high-cost card names beneath each list row for recognition. The same list has the same label in both roles. Numbers are local to the returned results and can change when the selected data changes; links continue to use the exact ID and role. No lists or outcomes are merged by their display labels.

## Configuration and build

`CARDGAME_CATALOG_ORIGIN` (default `https://cardgame-catalog-production.up.railway.app`) is baked into the page as `<meta name="cg-catalog">` at build time. No key or login is needed.

## Demo data

`/stats/?demo=1` loads `media/stats-demo.json`, a **synthetic** snapshot in the real schema (real card ids, invented results; `website/tools/stats-fixture.mjs`), and shows a banner saying so. It exists to review the layout while the live route is unavailable and to drive the tests. The page never falls back to it by itself.

## Tests

```sh
node --test website/test/stats.test.mjs website/test/site.test.mjs
```

`stats.test.mjs` covers the arithmetic and routing rules from the API contract against the synthetic fixture: the same deck in both roles, reversed matchup perspectives, a real 0% record against a missing matchup, null turns, 2 of 3 as 66.7%, AI keys removed for PvP, address round trips, filters and sorting, and rejection of malformed snapshots. The rendering and request-race code in `stats.js` was checked by hand in a browser at desktop and phone widths, not by automated DOM tests.

## Service availability

The configured catalog must serve `/data/stats/deck-matchups.json`. If unavailable, the live page shows an error and Retry; it never substitutes demo results or treats a failed request as zero games. This presentation change does not change the relay, catalog contract or aggregation.
