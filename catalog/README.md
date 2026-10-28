# Public card catalog

A read-only copy of the game's printed card data for deck builders, bots and card browsers, plus a live card win-rate summary. No API key or login. The catalog service needs no database credentials. Printed definitions are generated from the same six faction files the game loads (`data/cards/{green,crimson,black,orange,teal,generic}.json`); the game itself never reads from it.

> Printed catalog origin: `https://cardgame-catalog-production.up.railway.app`. `public/` holds the 176 published cards. **Nothing is versioned:** there are no version numbers, release folders or `latest.json`; every export simply replaces `cards.json` and `keywords.json`. The live win-rate route requires deploying the updated relay AND catalog before it is available there.

## URLs

```text
GET /data/cards.json
GET /data/keywords.json
GET /data/stats/card-winrates.json
GET /healthz                       (operator health check, not part of the data contract)
```

There is no server-side filtering and no per-card route. **Download once, index by `id`, filter locally.** `?query=` strings are ignored, not implemented.

### Live card win rates

Fetch `/data/stats/card-winrates.json` and join `cards[].id` to the printed catalog. Example row and envelope (other cards omitted):

```json
{
  "generatedAt": "2026-10-27T16:00:00.000Z",
  "methodology": {
    "metric": "starting_deck_inclusion",
    "modes": ["ranked_ai", "authoritative_pvp"],
    "aiSeats": "both",
    "copies": "once_per_player_game",
    "rulesVersions": "combined",
    "minSample": 1,
    "preliminary": true,
    "privacy": "No raw identities or deck lists. Small sample changes may reveal deck inclusion or outcomes."
  },
  "cards": [{"id":"g_001","matches":2,"wins":1,"losses":1,"winRate":0.5}]
}
```

`matches` means recorded **seat-games with the card in the starting deck**, whether starter or custom. Two copies count once per seat. Ranked AI counts BOTH decks: the human's cards receive the recorded outcome, and the AI's cards receive the opposite outcome. Settled authoritative PvP also counts both players. A card on both sides therefore gets one win and one loss from that match. AI results are client-reported, not verified PvP. All rules versions are combined. Created, drawn or played cards do not change this metric; it measures deck-inclusion outcomes rather than a card's causal strength.

Every currently published collectible has a row. No recorded sample means counts of zero and `winRate: null`; otherwise the rate is a fraction from 0 to 1, visible from the first game. Legacy settlements without deck summaries, uncompleted/voided/drawn PvP, tokens and unpublished cards do not count. Already-recorded AI summaries include both saved starting decks automatically on the next refresh after deployment, without rewriting history or awarding results again. Missing/malformed historical deck fields contribute nothing for that seat; old missing decks cannot be reconstructed.

For Railway's database query box, copy [server/tools/card-winrates.sql](../server/tools/card-winrates.sql). It counts both AI seats and settled PvP, replacing the earlier human-only query. This raw database view includes all recorded IDs (publication filtering lives in the API's file-based catalog), and requires `ranked_matches` to exist. The API also supports an AI-only schema without that table. Neither query nor API modifies match records.

This is preliminary testing data. The owner explicitly selected the one-game minimum, superseding the earlier 100-game/anti-differencing policy **for this endpoint**. No raw identity, match ID or deck list is returned, but comparing small-sample snapshots can reveal a player's card inclusion and result. Do not describe this as protection against inference.

The relay caches successful aggregates for 60 seconds and shares concurrent refreshes. `generatedAt` is snapshot time, not a match timestamp. Responses use `Cache-Control: no-cache`; failures are generic JSON **503**, `no-store`, never zero-filled or stale success. GET/HEAD/OPTIONS and anonymous CORS are supported. Printed card files and `/healthz` remain available during stats failures. Versioned stats releases do not exist; this endpoint does not supply drawn/played rates, tiers, caps or deck archetypes.

Deploy BOTH services together. The stats route moved to `/data/stats/card-winrates.json` on the relay as well as the catalog, so the catalog returns a generic 503 until the relay is redeployed too (deploy the relay, then the catalog, or either order and wait for both). The catalog also requires upstream `methodology.aiSeats: "both"`. The relay image includes `catalog/public/data/`; it reads the committed publication allowlist and uses its existing database pool. No new database tables or variables are required. The catalog defaults to `https://cardgame-relay-production.up.railway.app`; optionally set **`CARD_WINRATES_ORIGIN`** on the catalog to an HTTP(S) origin for staging/local testing (no path, query, userinfo or fragment). The fetch has a 5-second timeout, 1 MiB response limit, refuses redirects, and validates/projects counts. The stats response carries no version fields. No Godot browser export is needed for this API-only change.

After deployment, fetch the new route, complete a ranked game using a client with AI-summary recording, then fetch again after 60 seconds and check the affected card counts. Local aggregate verification: from `server`, run `node --test test/card_winrates.test.js test/ranked_ai_record.test.js` with a disposable `DATABASE_URL`; from `catalog`, run `node --test 'test/*.test.mjs'` without `DATABASE_URL`.

### `cards.json`

An object with one key, `cards`, sorted by `id`:

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Stable across releases. |
| `name` | string | |
| `color` | `GREEN` `CRIMSON` `BLACK` `ORANGE` `TEAL` `GENERIC` | `GENERIC` is usable by every faction. |
| `type` | `CREATURE` `STRATAGEM` `LOCATION` | |
| `rarity` | `COMMON` `RARE` `EPIC` `LEGENDARY` | |
| `manaCost` | integer | Printed cost. In play the game clamps the effective cost to 1–10. |
| `attack` | integer \| `null` | `null` for stratagems and Locations (a Location never attacks). |
| `health` | integer \| `null` | Creatures and Locations; `null` for stratagems. |
| `tribe` | string \| `null` | e.g. `yeti`. A tribe is not a keyword. |
| `description` | string | Rules text. `{n}` is already resolved to the printed value (a card that grows when rummaged shows its base number). |
| `abilities` | string[] | Explicit ability keys as printed in the source, e.g. `guardian`, `shielded_1`, `reinforce_4`. Tribe tags the Godot loader adds at runtime are **not** included. |
| `collectible` | boolean | Part of the release selection: `false` for tokens/forms included only because a selected card references them. |
| `isToken` | boolean | Marked as a token in the game data. `isToken: false` alone does not mean "released" or "collectible". |
| `isTransformForm` | boolean | Some published card transforms into this one. |
| `transformInto` | string \| `null` | Id of a card in this same release. |
| `transformChoices` | string[] | Ids of cards in this same release. |

Not exported, on purpose: art paths, internal effect definitions (`effect`, `effect_value`), starter-deck flags, and any runtime state (uids, damage, cost modifiers, rummage counters).

### `keywords.json`

An object with:

- `keywords` — `{ id, name, description }`, from `data/keywords.json` (the same text the game's tooltips use). `id` is the lower-snake-case name.
- `abilityKeywords` — for **every ability key that appears in `cards.json`**, the keyword it belongs to, or `null`. A parameterised key resolves through its base: `shielded_1` → `shielded`, `pilot_2_2` → `pilot`, `reinforce_4` → `reinforce`. Three keys are aliased in [`data/keyword_abilities.json`](../data/keyword_abilities.json) because the keyword's printed name differs from the ability key (`combat_immune` → Ethereal, `enemy_damage_amp` → Amplify, `two_slot` → Colossal).

**Known gap:** most ability keys (about 75 at the time of writing, mostly "On Play…" / "On Death…" triggers) have **no keyword entry** and map to `null`. Their readable text lives in the card's `description`. The exporter prints the list on every run; filling it in means adding entries to `data/keywords.json` — it is not scraped from GDScript.

Building something on this API? [`stats-website-spec.md`](stats-website-spec.md)
is a self-contained brief for a third-party statistics site: both schemas
written out, the suppression rules, fixtures to develop against, and what is
not published yet.

## Local use

```bash
curl -s http://localhost:8080/data/cards.json
node examples/consume.mjs http://localhost:8080
```

```js
// Browser or Node 18+: fetch, index by id, filter locally.
const origin = 'https://YOUR-CATALOG-DOMAIN';           // placeholder
const { cards } = await (await fetch(`${origin}/data/cards.json`)).json();
const byId = new Map(cards.map((c) => [c.id, c]));
const cheapGuardians = cards.filter((c) => c.collectible && c.manaCost <= 3 && c.abilities.includes('guardian'));
```

Nothing is versioned, so the files change whenever the catalog is re-exported. Responses carry `Access-Control-Allow-Origin: *` (no credentials) and expose `ETag`; send `If-None-Match` to get a `304`. Every file is `Cache-Control: no-cache`, so a client always revalidates and gets a `304` when nothing changed.

Errors: unknown paths return a real `404` JSON body (never a fallback page), other methods `405`. Handle non-2xx explicitly, as `examples/consume.mjs` does.

## Running and testing

Node ≥ 20, no dependencies (`npm install` is not needed).

```bash
npm test                 # exporter + HTTP tests (node:test)
npm start                # serve ./public on $PORT (default 8080)
npm run export           # export release-input.json into ./public
```

`node --test` and `curl` are the only tools used. The server never starts the Godot game, `server/relay.js`, or Postgres.

## Updating the catalog

1. **Select.** Edit `release-input.json`: the explicit `cards` list (`{ "id", "collectible" }`) selects which cards are public; names, stats and text always come from the faction JSON. Include any token/form a selected card references; the export fails rather than pulling in an unreleased card.
2. **Validate + export.** `npm run export`. The whole candidate is validated before anything is written; any failure (bad JSON, duplicate id, unknown id, invalid field, dangling transform reference) exits nonzero and leaves the existing output untouched. Re-running with identical inputs is a byte-identical no-op. A changed export replaces `public/data/cards.json` and `keywords.json`.
3. **Review** the diff of `public/` - that is exactly what becomes public. `public/` is committed; there is no history of old versions beyond git.
4. **Publish:** deploy the `catalog/` directory - see [Deploying to Railway](#deploying-to-railway).

## Deploying to Railway

Everything inside this directory is deploy-ready: no dependencies or database
credentials, `PORT` honoured, `/healthz` implemented, and the data files committed
under `public/`. The live stats route uses the default relay origin unless the
operator sets `CARD_WINRATES_ORIGIN`.

The published content is whatever is in `public/data/`, so the thing to check
before deploying is the diff of `public/`, which is exactly what becomes public.

```bash
railway login                  # opens a browser; the saved login expires
cd catalog
railway init                   # or: railway link, to attach to an existing project
railway up                     # builds and deploys this directory
railway domain                 # generates the public *.up.railway.app origin
```

- **Root Directory must be `catalog/`.** There is no `package.json` at the
  repository root, so a service rooted there has nothing for Nixpacks to build.
  `railway init` run from this directory sets it; in the dashboard it is
  Settings → Source → Root Directory. A build that fails looking for a start
  command is almost always this.
- `railway.json` supplies the rest: Nixpacks, `node src/server.mjs`, `/healthz`
  as the health check (200 only when `cards.json` and `keywords.json` both exist and
  parse, so a bound port with missing data is reported unhealthy), and
  restart-on-failure. `watchPatterns: ["catalog/**"]` keeps game-only commits
  from rebuilding the catalog; the patterns are read relative to the repository
  root, so drop them if a catalog change ever fails to trigger a deploy.
- Public domain, spend limits and rate limiting are platform settings the
  operator chooses. No developer-key system is built, by design.

### Verifying a deploy

```bash
curl -s https://<origin>/healthz                        # {"status":"ok"}
node examples/consume.mjs https://<origin>              # card count, keyword count, a filtered list
curl -sI https://<origin>/data/cards.json               # ETag, Cache-Control: no-cache, CORS
```

Every file should come back `Cache-Control: no-cache`, and re-requesting with
`If-None-Match` should give `304`. All of that passes locally (`npm test`). This task has not rechecked
the printed catalog's behavior through Railway's CDN.

Give consumers the origin as `CATALOG_ORIGIN` in
[`stats-website-spec.md`](stats-website-spec.md). The live
`/data/stats/card-winrates.json` route requires both updated services;
unavailable stats return 503. Versioned stats release routes do not exist. Consumers
must distinguish unavailable figures from genuine zero samples.

## What is verified, and what is not

Verified locally by `npm test` and a live run: projection and exclusions, deterministic bytes, replacement on change, failure preservation, real 404s, traversal/dotfile/non-JSON refusal, CORS headers and preflight, `Cache-Control`, `ETag` → `304`, `HEAD`, and `/healthz`.

**Remaining operator proof:** the new live route after deploying both services, deployed CORS / content-type / cache / ETag behavior behind Railway's CDN, and resource usage. The owner reports the printed catalog is deployed at the origin above; this task verifies the new win-rate API locally only. The changed relay Docker COPY boundary was checked with a scratch image using the actual root build context and ignore rules; a full production image rebuild was not run.

## Decided

- **Initial public card selection.** Every card in the six files (176) except three just-implemented, not-yet-balance-tested cards, held back by owner decision: `gen_str_005` Emergency Extraction, `t_str_004` Whiteout, `t_027` Snowdrift Matriarch. They can be added to `release-input.json` later.
- **No versioning.** Owner decision: no version numbers, release folders or `latest.json` for now. A versioning scheme can be reintroduced later if consumers need to pin content.

## Still open

- **Keyword text** for the unmapped ability keys (above): 76 of them export as `null` in `abilityKeywords`, which consumers must handle. Writing player-facing text for them is content work, not a code change.
- **Win-rate rollout.** Deploy both updated services and verify counts after a game and cache expiry; see [Deploying to Railway](#deploying-to-railway).
