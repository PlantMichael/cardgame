# Spec: card statistics website

> **Current live-summary addition (2026-10-27):** `/data/v1/stats/card-winrates.json` is now implemented in source; deploy both updated services to enable it. See [README: live card win rates](README.md#live-card-win-rates) for its complete contract and example. It combines recorded AI human seats and authoritative PvP, counts starting-deck inclusion (custom decks included), and intentionally publishes samples from one game. Counts can permit inference by comparing snapshots. It is separate from the unimplemented batch/release API below; that older API's thresholds, caps, verified-only filtering and drawn/played fields do not apply to this live route. Printed catalog origin is `https://cardgame-catalog-production.up.railway.app`; the old unknown-origin/not-deployed statements below are historical planning context.

A brief for whoever (or whatever) builds a public statistics website on top of
this game's card catalog and card-statistics API. It is self-contained: every
schema the site consumes is written out below, so you do not need the game's
source to build against it.

Read §1 before planning anything — part of this API is published data you can
rely on, and part of it does not exist yet.

---

## 1. What exists today

The data source is a **static, anonymous, read-only JSON API**. No API key, no
login, no query parameters, no per-card route, no database. Two separate
release trains share one origin:

| Data | URL space | Status |
|---|---|---|
| Card catalog (printed card data) | `/data/v1/…` | **Built and tested**, release `0.1.0` exported (176 cards), **not deployed to a public domain yet** |
| Card and deck statistics | `/data/v1/stats/…` | **Contract frozen, not implemented.** No release exists, so these URLs 404 today |
| Health check | `/healthz` | Operator-only, not part of the data contract |

Consequences you must design around:

1. **The origin is not known yet.** Take it from configuration
   (`CATALOG_ORIGIN`), never hardcode a domain. Ask the owner for the real one.
2. **The stats files may 404 for a while.** The site has to be useful with the
   catalog alone, and must show an honest empty state ("statistics have not
   been published yet") rather than an error page or zeros.
3. **Statistics are published in batches, not live.** There is no realtime
   feed, no per-match data, no player lookup. A release carries a
   `generatedOn` date; show it.
4. **There is no card art in this API** — art paths are deliberately not
   exported. Build a text/type-based visual design, or ask the owner for an
   image source separately.

## 2. Configuration

```
CATALOG_ORIGIN   e.g. https://catalog.example.com   (required, no trailing slash)
```

For local development the owner can run the catalog server from the game
repository (`cd catalog && npm start`, Node ≥ 20, no dependencies) which serves
the real card data at `http://localhost:8080`. Otherwise use the fixtures in §6.

All URLs inside the API are **root-relative**. Always resolve them against the
origin you fetched the index from:

```js
const latest = await (await fetch(`${origin}/data/v1/latest.json`)).json();
const cardsUrl = new URL(latest.cardsUrl, origin);
```

## 3. The API

### 3.1 Catalog index — `GET /data/v1/latest.json`

```json
{
  "schemaVersion": 1,
  "catalogVersion": "0.1.0",
  "gameVersion": "unreleased",
  "cardsUrl": "/data/v1/releases/0.1.0/cards.json",
  "keywordsUrl": "/data/v1/releases/0.1.0/keywords.json"
}
```

- `schemaVersion` — the shape of these files. Changes only when the contract
  changes, not when a card is rebalanced. **If it is not `1`, stop and show a
  "this site needs updating" notice** rather than guessing.
- `catalogVersion` — identifies immutable content. A release is write-once: a
  correction ships as a new version, never as an edit.
- `gameVersion` — which game release the content describes.

### 3.2 Cards — `GET /data/v1/releases/<catalogVersion>/cards.json`

Envelope (`schemaVersion`, `catalogVersion`, `gameVersion`) plus `cards`,
sorted by `id`. Release 0.1.0 is 176 cards / ~82 KB — small enough to
fetch once and filter in the browser, which is the intended pattern.

| Field | Type | Notes |
|---|---|---|
| `id` | string | Stable across releases. The join key for statistics. |
| `name` | string | |
| `color` | `GREEN` `CRIMSON` `BLACK` `ORANGE` `TEAL` `GENERIC` | `GENERIC` is playable by every faction. |
| `type` | `CREATURE` `STRATAGEM` `LOCATION` | |
| `rarity` | `COMMON` `RARE` `EPIC` `LEGENDARY` | |
| `manaCost` | integer | Printed cost, 1–10 in current data. |
| `attack` | integer \| null | `null` for stratagems and locations. |
| `health` | integer \| null | `null` for stratagems. |
| `tribe` | string \| null | Current values: `bat` `mech` `monstrosity` `tank` `wolf` `yeti`. A tribe is **not** a keyword. |
| `description` | string | Printed rules text, numbers already resolved. |
| `abilities` | string[] | Ability keys as printed, e.g. `guardian`, `shielded_1`, `reinforce_4`. |
| `collectible` | boolean | `false` for tokens/forms that are only in the release because a selected card references them. **Default every list and chart to `collectible: true`.** |
| `isToken` | boolean | |
| `isTransformForm` | boolean | Some card transforms into this one. |
| `transformInto` | string \| null | Id within the same release. |
| `transformChoices` | string[] | Ids within the same release. |

### 3.3 Keywords — `GET /data/v1/releases/<catalogVersion>/keywords.json`

Same envelope plus:

- `keywords` — `[{ id, name, description }]`, the same text the game's tooltips
  use (currently 17).
- `abilityKeywords` — a map from **every ability key that appears in
  `cards.json`** to its keyword id, or `null` (currently 97 keys, 75 of them
  `null`). Parameterised keys resolve through their base: `shielded_1` →
  `shielded`, `reinforce_4` → `reinforce`.

A `null` mapping is normal and permanent for now: those are mostly "On play…" /
"On death…" effects whose readable text is already in the card's
`description`. **Never render a raw ability key** like `rummage_on_death` as
user-facing text — look it up, and fall back to the card's description.

### 3.4 Statistics index — `GET /data/v1/stats/latest.json`

```json
{
  "schemaVersion": 1,
  "releaseId": "stats-1.0.0-r1",
  "gameVersion": "1.0.0",
  "catalogVersion": "0.1.0",
  "cardStatsUrl": "/data/v1/stats/releases/stats-1.0.0-r1/card-stats.json",
  "deckStatsUrl": "/data/v1/stats/releases/stats-1.0.0-r1/deck-stats.json"
}
```

`catalogVersion` names the card release these ids resolve against. **Load that
catalog release, not `latest.json`'s**, so names and costs match the statistics
you are showing. If they differ, say so somewhere visible.

### 3.5 Card statistics — `card-stats.json`

```json
{
  "schemaVersion": 1,
  "releaseId": "stats-1.0.0-r1",
  "gameVersion": "1.0.0",
  "generatedOn": "2026-11-07",
  "method": {
    "includes": "verified human-vs-human matches that finished or were conceded",
    "minSample": 100,
    "perAccountCap": 10,
    "pairCap": 5,
    "ratePrecision": "0.1 percentage points",
    "sampleRounding": "down to nearest 10"
  },
  "slices": [
    {
      "tierGroup": "mid",
      "matchType": "ranked",
      "cards": [
        {
          "id": "g_001",
          "matches": 1230,
          "drawRate": 0.612,
          "keepRate": 0.874,
          "playRate": 0.541,
          "winRateWhenDrawn": 0.527,
          "winRateWhenKept": 0.538,
          "winRateWhenPlayed": 0.561,
          "n": { "drawn": 750, "kept": 650, "played": 660 }
        }
      ]
    }
  ]
}
```

- `tierGroup` ∈ `low` `mid` `high` `legend`; `matchType` ∈ `ranked` `casual`
  `campaign`. **That is the only slicing that exists** — do not build UI that
  implies filtering by patch, region, date range, deck or player.
- Rates are fractions in `[0, 1]`, 3 decimals. Render as percentages with one
  decimal place at most; never claim more precision than `ratePrecision`.
- `n.*` are the sample sizes behind the matching rates, **rounded down to the
  nearest 10**. Treat them as approximate; do not recompute rates from them.
- Read `method` from the file and show it. Do not hardcode `minSample: 100`:
  it can change between releases.
- Matches against AI, and any unverified match, never appear.

**Suppression — the rule most likely to be got wrong.** A figure that does not
meet `minSample` after capping is **absent from the card's object**: the key is
missing, not `0`, not `null`. A card with no qualifying figure is absent from
the slice entirely.

So:

- Use `'winRateWhenPlayed' in card`, never `card.winRateWhenPlayed || 0`.
- Render a missing figure as "–" or "not enough data", with a tooltip
  explaining the minimum sample. Never as 0%, and never sort it as 0.
- A card in the catalog but not in a slice is "no published data for this
  slice", not "0% win rate". Make that visually distinct from a bad card.

### 3.6 Deck statistics — `deck-stats.json`

Same envelope; `slices[].decks[]` entries are keyed by faction pair only:

```json
{ "factions": ["GREEN", "TEAL"], "matches": 940, "winRate": 0.508 }
```

A single-faction deck has a one-element `factions`. There is never a card list,
deck code or deck hash — by design, so do not build a "view this deck" feature.

## 4. Client rules

1. **Fetch once, index by `id`, filter locally.** There is no server-side
   filtering; `?query=` strings are ignored. All search, sort and filtering
   happens in the client over the arrays you already hold.
2. **Caching.** Index files (`latest.json`) are `Cache-Control: no-cache` with
   an `ETag`; release files are `public, max-age=31536000, immutable`. Send
   `If-None-Match` and handle `304`. A release's bytes never change, so a
   release file may be cached forever (localStorage/IndexedDB is fine; key it
   by the release id).
3. **CORS.** `Access-Control-Allow-Origin: *`, no credentials. Never send
   cookies or auth headers; there is nothing to authenticate.
4. **Errors are real.** Unknown paths return a `404` with a JSON body (never a
   fallback page); other methods return `405`. Handle every non-2xx explicitly:
   a 404 on the stats index means "not published yet" (empty state), a 404 on a
   release file named by an index means the API is inconsistent (show an error).
5. **Methods.** `GET`, `HEAD`, `OPTIONS` only.
6. **Pin when you link.** A shareable link to a statistic should carry the
   release id so it keeps meaning after the next publish.

TypeScript types to build against:

```ts
type Color = 'GREEN' | 'CRIMSON' | 'BLACK' | 'ORANGE' | 'TEAL' | 'GENERIC';
type CardType = 'CREATURE' | 'STRATAGEM' | 'LOCATION';
type Rarity = 'COMMON' | 'RARE' | 'EPIC' | 'LEGENDARY';
type TierGroup = 'low' | 'mid' | 'high' | 'legend';
type MatchType = 'ranked' | 'casual' | 'campaign';

interface Card {
  id: string; name: string; color: Color; type: CardType; rarity: Rarity;
  manaCost: number; attack: number | null; health: number | null;
  tribe: string | null; description: string; abilities: string[];
  collectible: boolean; isToken: boolean; isTransformForm: boolean;
  transformInto: string | null; transformChoices: string[];
}

// Every statistic is OPTIONAL: an absent key means "suppressed, below minSample".
interface CardStat {
  id: string;
  matches?: number;
  drawRate?: number; keepRate?: number; playRate?: number;
  winRateWhenDrawn?: number; winRateWhenKept?: number; winRateWhenPlayed?: number;
  n?: { drawn?: number; kept?: number; played?: number };
}

interface CardStatsSlice { tierGroup: TierGroup; matchType: MatchType; cards: CardStat[]; }
interface DeckStat { factions: Color[]; matches?: number; winRate?: number; }
```

## 5. What the website must do

Minimum, in priority order:

1. **Card table.** All collectible cards from the current catalog release, with
   client-side search by name and description, and filters for color, type,
   rarity, mana cost and tribe. Sortable columns, including the statistics
   columns when a stats release is loaded.
2. **Slice selector.** One `tierGroup` × `matchType` pair at a time, defaulting
   to `mid` / `ranked`. The current slice must be obvious, and switching it
   must not silently drop cards without saying why (see suppression).
3. **Card detail.** Printed data, keyword explanations resolved through
   `abilityKeywords`, every published figure for that card with its sample
   size, and a clear statement when a figure is suppressed.
4. **Faction win rates.** `deck-stats.json` as a readable comparison of faction
   pairs, with sample sizes.
5. **Provenance, always visible.** `gameVersion`, `catalogVersion`,
   `releaseId`, `generatedOn`, and a methodology page that renders the `method`
   block verbatim plus a plain-language explanation of capping and suppression.
6. **Honest empty states.** No stats release → the site still works as a card
   browser and says statistics are not published yet.

Quality bar: static hosting is enough (no backend, no server-side rendering
needed); works at phone width; keyboard-navigable table; no layout shift when
statistics load after cards; readable without colour alone (the factions are
colour-named — label them in text too).

## 6. Developing before the API is published

Serve these fixtures from `/data/v1/...` locally and switch to `CATALOG_ORIGIN`
later. They are deliberately minimal but schema-accurate; the shapes are what
matter, including one card with suppressed figures.

`cards.json`:

```json
{
  "schemaVersion": 1, "catalogVersion": "0.0.0-dev", "gameVersion": "dev",
  "cards": [
    { "id": "b_001", "name": "Garbage Addict", "color": "BLACK", "type": "CREATURE",
      "rarity": "COMMON", "manaCost": 3, "attack": 1, "health": 1, "tribe": null,
      "description": "On play: Rummage. On death: Rummage.",
      "abilities": ["rummage", "rummage_on_death"], "collectible": true,
      "isToken": false, "isTransformForm": false, "transformInto": null, "transformChoices": [] },
    { "id": "t_019", "name": "Serene Yeti", "color": "TEAL", "type": "CREATURE",
      "rarity": "EPIC", "manaCost": 4, "attack": 2, "health": 4, "tribe": "yeti",
      "description": "Ambush", "abilities": ["ambush"], "collectible": true,
      "isToken": false, "isTransformForm": false, "transformInto": null, "transformChoices": [] },
    { "id": "gen_str_001", "name": "Orbital Strike", "color": "GENERIC", "type": "STRATAGEM",
      "rarity": "RARE", "manaCost": 3, "attack": null, "health": null, "tribe": null,
      "description": "Deal 3 damage to any target.", "abilities": [], "collectible": true,
      "isToken": false, "isTransformForm": false, "transformInto": null, "transformChoices": [] }
  ]
}
```

`keywords.json` — `rummage_on_death` is a real example of the `null` mapping,
so a card can carry one key that resolves and one that does not:

```json
{
  "schemaVersion": 1, "catalogVersion": "0.0.0-dev", "gameVersion": "dev",
  "keywords": [
    { "id": "ambush", "name": "Ambush", "description": "Cannot be targeted when played. Loses Ambush after it attacks." },
    { "id": "rummage", "name": "Rummage", "description": "Select a card of lesser value in your graveyard, then return it to your hand. It costs one less." }
  ],
  "abilityKeywords": { "ambush": "ambush", "rummage": "rummage", "rummage_on_death": null }
}
```

`stats/card-stats.json` — note `t_019` has a suppressed `winRateWhenPlayed`
and `gen_str_001` is absent from the slice entirely:

```json
{
  "schemaVersion": 1, "releaseId": "stats-0.0.0-dev", "gameVersion": "dev",
  "generatedOn": "2026-10-24",
  "method": { "includes": "verified human-vs-human matches that finished or were conceded",
    "minSample": 100, "perAccountCap": 10, "pairCap": 5,
    "ratePrecision": "0.1 percentage points", "sampleRounding": "down to nearest 10" },
  "slices": [
    { "tierGroup": "mid", "matchType": "ranked", "cards": [
      { "id": "b_001", "matches": 1230, "drawRate": 0.612, "keepRate": 0.874, "playRate": 0.541,
        "winRateWhenDrawn": 0.527, "winRateWhenKept": 0.538, "winRateWhenPlayed": 0.561,
        "n": { "drawn": 750, "kept": 650, "played": 660 } },
      { "id": "t_019", "matches": 300, "drawRate": 0.41, "winRateWhenDrawn": 0.492,
        "n": { "drawn": 120 } }
    ] }
  ]
}
```

`stats/deck-stats.json`:

```json
{
  "schemaVersion": 1, "releaseId": "stats-0.0.0-dev", "gameVersion": "dev",
  "generatedOn": "2026-10-24",
  "method": { "includes": "verified human-vs-human matches that finished or were conceded",
    "minSample": 100, "perAccountCap": 10, "pairCap": 5,
    "ratePrecision": "0.1 percentage points", "sampleRounding": "down to nearest 10" },
  "slices": [
    { "tierGroup": "mid", "matchType": "ranked", "decks": [
      { "factions": ["GREEN", "TEAL"], "matches": 940, "winRate": 0.508 },
      { "factions": ["BLACK"], "matches": 410, "winRate": 0.473 }
    ] }
  ]
}
```

## 7. Non-goals and hard limits

Do not build, and do not ask the API for:

- Player profiles, leaderboards, match history, or anything per-account. The
  published data contains no player or match identifiers, by design and by an
  automated privacy scan on the publishing side.
- Deck lists, deck codes or "top decks" — `deck-stats.json` is faction pairs
  only.
- Date-range, patch-over-time or region filters. Releases are snapshots; the
  only history you have is older release ids.
- Realtime or per-match feeds, webhooks, or writing anything back. The API is
  `GET`/`HEAD`/`OPTIONS` static JSON.
- Scraping the game client, the game's relay server, or the game repository's
  `data/cards/*.json` as a substitute. The catalog is the supported surface;
  the raw files include internal effect data that is deliberately not public.
- Inventing endpoints (`/cards/:id`, `?color=`, `/search`). They do not exist
  and will 404.

## 8. Questions for the owner before launch

1. What is the public origin for `CATALOG_ORIGIN`?
2. Has the catalog release been deployed yet? The content is settled -
   `catalogVersion` 0.1.0, `gameVersion` 0.1.0, 176 cards - and is what you
   will get once an origin exists.
3. Do card statistics exist yet? They are specified but not implemented, so
   plan for the card-browser-only mode first.
4. Is there an image source for card art? The API has none.
5. Where should the site be hosted, and under which domain?

## 9. Definition of done

- [ ] Loads `latest.json`, resolves release URLs against the configured origin,
      and refuses politely on an unknown `schemaVersion`.
- [ ] Card table with search, the five filters, and sorting; defaults to
      collectible cards only.
- [ ] Keyword text resolved through `abilityKeywords`, with the description
      fallback; no raw ability key ever shown to a user.
- [ ] Statistics render per slice, with sample sizes, and suppressed figures
      shown as "not enough data" — verified against a fixture where keys are
      absent (a test, not a manual look).
- [ ] A missing stats release yields a working card browser plus an honest
      notice; a 404 on a release file named by an index yields a visible error.
- [ ] Faction-pair win rates page.
- [ ] Provenance (`gameVersion`, `catalogVersion`, `releaseId`, `generatedOn`)
      visible on every page that shows a statistic, and a methodology page
      rendering `method` verbatim.
- [ ] Release files cached by release id; `If-None-Match` used for index files.
- [ ] Works at phone width; table is keyboard-navigable.
- [ ] No credentials, no cookies, no third-party analytics that receive card or
      query data without the owner's say-so.
