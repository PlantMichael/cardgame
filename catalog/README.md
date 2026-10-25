# Public card catalog

A static, versioned, read-only copy of the game's printed card data for deck builders, bots and card browsers. No API key, no login, no database. Generated from the same six faction files the game loads (`data/cards/{green,crimson,black,orange,teal,generic}.json`); the game itself never reads from it.

> **Status: candidate, not published.** `release-input.json` is a *proposal* for owner review. The version label (`0.1.0-candidate.1`) and `gameVersion` (`unreleased`) are placeholders, and nothing here has been deployed. See [Open decisions](#open-decisions).

## URLs

```text
GET /data/v1/latest.json
GET /data/v1/releases/<catalog-version>/cards.json
GET /data/v1/releases/<catalog-version>/keywords.json
GET /healthz                       (operator health check, not part of the data contract)
```

There is no server-side filtering and no per-card route. **Download once, index by `id`, filter locally.** `?query=` strings are ignored, not implemented.

URLs in `latest.json` are root-relative: resolve them against the origin you fetched `latest.json` from (`new URL(latest.cardsUrl, origin)`).

### `latest.json`

```json
{
  "schemaVersion": 1,
  "catalogVersion": "0.1.0-candidate.1",
  "gameVersion": "unreleased",
  "cardsUrl": "/data/v1/releases/0.1.0-candidate.1/cards.json",
  "keywordsUrl": "/data/v1/releases/0.1.0-candidate.1/keywords.json"
}
```

- `schemaVersion` — the shape of these files. Changes only when the contract changes, not when a card is rebalanced.
- `catalogVersion` — identifies immutable content. A release is **write-once**: any correction ships as a new version.
- `gameVersion` — which game release the content describes. Not derived from the git branch.

### `cards.json`

An envelope (`schemaVersion`, `catalogVersion`, `gameVersion`) plus `cards`, sorted by `id`:

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

The same envelope plus:

- `keywords` — `{ id, name, description }`, from `data/keywords.json` (the same text the game's tooltips use). `id` is the lower-snake-case name.
- `abilityKeywords` — for **every ability key that appears in `cards.json`**, the keyword it belongs to, or `null`. A parameterised key resolves through its base: `shielded_1` → `shielded`, `pilot_2_2` → `pilot`, `reinforce_4` → `reinforce`. Three keys are aliased in [`data/keyword_abilities.json`](../data/keyword_abilities.json) because the keyword's printed name differs from the ability key (`combat_immune` → Ethereal, `enemy_damage_amp` → Amplify, `two_slot` → Colossal).

**Known gap:** most ability keys (about 75 at the time of writing, mostly "On Play…" / "On Death…" triggers) have **no keyword entry** and map to `null`. Their readable text lives in the card's `description`. The exporter prints the list on every run; filling it in means adding entries to `data/keywords.json` — it is not scraped from GDScript.

Building something on this API? [`stats-website-spec.md`](stats-website-spec.md)
is a self-contained brief for a third-party statistics site: both schemas
written out, the suppression rules, fixtures to develop against, and what is
not published yet.

## Local use

```bash
curl -s http://localhost:8080/data/v1/latest.json
node examples/consume.mjs http://localhost:8080
```

```js
// Browser or Node 18+: fetch latest, resolve, index by id, filter locally.
const origin = 'https://YOUR-CATALOG-DOMAIN';           // placeholder
const latest = await (await fetch(`${origin}/data/v1/latest.json`)).json();
const { cards } = await (await fetch(new URL(latest.cardsUrl, origin))).json();
const byId = new Map(cards.map((c) => [c.id, c]));
const cheapGuardians = cards.filter((c) => c.collectible && c.manaCost <= 3 && c.abilities.includes('guardian'));
```

Pin a version by fetching `/data/v1/releases/<catalog-version>/cards.json` directly: its bytes never change. Responses carry `Access-Control-Allow-Origin: *` (no credentials) and expose `ETag`; send `If-None-Match` to get a `304`. `latest.json` is `Cache-Control: no-cache`; release files are `public, max-age=31536000, immutable`.

Errors: unknown paths return a real `404` JSON body (never a fallback page), other methods `405`. Handle non-2xx explicitly, as `examples/consume.mjs` does.

## Running and testing

Node ≥ 20, no dependencies (`npm install` is not needed).

```bash
npm test                 # exporter + HTTP tests (node:test)
npm start                # serve ./public on $PORT (default 8080)
npm run export           # export release-input.json into ./public
```

`node --test` and `curl` are the only tools used. The server never starts the Godot game, `server/relay.js`, or Postgres.

## Release process

1. **Prepare.** Edit `release-input.json`: new `catalogVersion`, the real `gameVersion`, and the explicit `cards` list (`{ "id", "collectible" }` — it selects content; names, stats and text always come from the faction JSON). Include any token/form a selected card references; the export fails rather than pulling in an unreleased card.
2. **Validate + export.** `npm run export`. The whole candidate is validated before anything is written; any failure (bad JSON, duplicate id, unknown id, invalid field, dangling transform reference, unsafe label) exits nonzero and leaves the existing output untouched. Re-running with identical inputs is a byte-identical no-op; the same version with different content is refused.
3. **Retain.** `public/` is committed. Previous releases stay in `public/data/v1/releases/` and are served forever, so a stateless rebuild keeps history.
4. **Review** the diff of `public/` — that is exactly what becomes public.
5. **Publish** (needs owner approval of target and spend, see below): deploy the `catalog/` directory.
6. **Switch latest.** The export already points `latest.json` at the new release (`--no-latest` exports without switching). Complete release files are written before `latest.json`.
7. **Roll back** without rewriting any release: `node src/export.mjs --set-latest <older-version>`.

Nothing publishes automatically from a development commit.

## Deploying to Railway (prepared, not done)

- Create a service from this repository with **Root Directory = `catalog/`** — the serving code and the prepared releases are both inside it; nothing outside `catalog/` is needed at runtime.
- `railway.json` sets `node src/server.mjs` as the start command and `/healthz` as the health check. `/healthz` is 200 only when `latest.json` and the two files it links to exist, so a bound port with missing data is reported unhealthy.
- No environment variables are required (`PORT` is injected). No `DATABASE_URL`, no secrets.
- Public domain, spend limits and rate limiting are platform settings the operator chooses; no developer-key system is built.

## What is verified, and what is not

Verified locally by `npm test` and a live run: projection and exclusions, deterministic bytes, write-once versions, failure preservation, retained history across an update, rollback, real 404s, traversal/dotfile/non-JSON refusal, CORS headers and preflight, `Cache-Control`, `ETag` → `304`, `HEAD`, and `/healthz`.

**Not verified** (needs an authorised deploy): the Railway build context, public HTTPS domain, deployed CORS / content-type / cache / ETag behaviour behind Railway's CDN, old-release retention across a real redeploy, and resource usage. Do not treat the API as live.

## Open decisions

- **Initial public card selection.** `release-input.json` proposes every card in the six files (176) except three just-implemented, not-yet-balance-tested cards: `gen_str_005` Emergency Extraction, `t_str_004` Whiteout, `t_027` Snowdrift Matriarch. Being in the repository is not approval to publish.
- **`catalogVersion` and `gameVersion`.** Placeholders until the owner states them.
- **Keyword text** for the unmapped ability keys (above).
