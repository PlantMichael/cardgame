# Deck matchup API: website developer contract

Build the stats site around exact starting decks and their opponent records. Exact deck lists and aggregate results are public. Player identities, match IDs and individual histories are not returned. This contract describes the implemented API; hosted availability requires deploying the updated relay and catalog.

## Origins and routes

Use `CATALOG_ORIGIN=https://cardgame-catalog-production.up.railway.app` for the published catalog service. The relay also serves the two stats routes. No login, credentials or API key is required.

| Route | Purpose |
|---|---|
| `/data/cards.json` | Printed definitions in `{cards:[...]}`; join card IDs here for names, text and stats. |
| `/data/keywords.json` | `{keywords:[...],abilityKeywords:{...}}`; keyword text and ability mappings. |
| `/data/stats/deck-matchups.json` | Exact decks and opponent records for one selected cohort. |
| `/data/stats/card-winrates.json` | Existing starting-deck card inclusion metric; unchanged and combines modes/versions. |

Printed card fields and catalog maintenance are documented in [README.md](README.md). Static files support ETag revalidation. The stats routes use successful relay snapshots cached for 60 seconds; `generatedAt` is snapshot time. Stats failures are generic 503 responses with `Cache-Control: no-store`, never stale or fabricated zero results.

## Select one cohort

```js
const url = new URL('/data/stats/deck-matchups.json', CATALOG_ORIGIN);
url.search = new URLSearchParams({
  mode: 'ranked_ai', days: '30', rulesVersion: 'latest', aiVersion: 'latest', aiLevel: '10'
});
const response = await fetch(url);
if (!response.ok) throw new Error(`Stats unavailable (${response.status})`);
const snapshot = await response.json();
```

| Parameter | Allowed values | Default |
|---|---|---|
| `mode` | `ranked_ai`, `authoritative_pvp` | `ranked_ai` |
| `days` | Integer 1–365 | 30 |
| `rulesVersion` | Positive integer up to 1,000,000, `latest`, `unknown` | `latest` |
| `aiVersion` | Positive integer up to 1,000,000, `latest`, `unknown`; AI mode only | `latest` |
| `aiLevel` | Integer 1–10; AI mode only | 10 |

PvP example: `/data/stats/deck-matchups.json?mode=authoritative_pvp&days=30&rulesVersion=latest`. Do not send AI parameters in PvP mode. Unknown keys, repeated parameters, empty values, signed/decimal/noncanonical numbers and irrelevant AI parameters return 400. Unsupported methods return 405. GET, HEAD, OPTIONS and anonymous CORS are supported.

The window runs from snapshot time minus `days × 24 hours` through snapshot time, inclusive, using AI settlement time or PvP ended time. Modes and versions are never pooled. Resolution order is: valid mode/time records → AI level and all explicit versions → highest remaining known rules version → highest remaining known AI policy version within that rules version. A latest selection resolves to `unknown` only when no known version remains. Selecting an explicit nonexistent version returns an empty cohort.

`filters` echoes resolved values. PvP returns `aiVersion:null, aiLevel:null`. `availableFilters` provides:

- `rulesVersions`: mode/time/level choices conditioned on any explicit AI version.
- `aiVersions`: mode/time/level choices within the resolved rules version, ignoring the requested AI version.
- `aiLevels`: all valid levels in the mode/time window; discovery choices do not promise every version combination exists. Empty for PvP.

Older AI summaries lack `ai_version` and/or `first_player`. Missing policy versions remain in the explicit `aiVersion=unknown` cohort; missing first-player facts contribute to `unknownFirst`. New clients report `AIController.POLICY_VERSION` (initially 1). Difficulty is not a substitute for policy version. Version fields do not version the printed catalog and cannot reconstruct historical card definitions.

## Response and joins

The response has `generatedAt`, `filters`, `availableFilters`, `methodology`, `games`, `decks`, and `matchups`. No eligible games is a successful response with `games:0`, `decks:[]`, and `matchups:[]`.

A `decks` entry contains:

```text
id: SHA-256 hex string
cards: [{id: card ID, copies: integer}, ...]
factions: sorted non-GENERIC printed colors, or ["GENERIC"]
role: "human" | "ai"
...statistics
```

A `matchups` entry contains:

```text
deckId, role: this deck's ID and controller role
opponentDeckId, opponentRole: the opposing deck's ID and controller role
...statistics
```

Always join with **both ID and role**. The same composition can have separate human and AI records. PvP uses human for both sides. Every matchup includes its reverse perspective with opposite results. Do not add the reverse row when displaying one deck's win rate.

```js
const byKey = new Map(snapshot.decks.map(d => [`${d.id}/${d.role}`, d]));
const humanDecks = snapshot.decks.filter(d => d.role === 'human');
function opponents(deck) {
  return snapshot.matchups
    .filter(m => m.deckId === deck.id && m.role === deck.role)
    .map(m => ({ ...m, opponent: byKey.get(`${m.opponentDeckId}/${m.opponentRole}`) }));
}
```

Deck identity ignores card order and preserves copy counts. Count each ID, sort IDs lexicographically, serialize `[cardId,copies]` pairs with compact JSON and hash UTF-8 bytes with SHA-256. For example, `['g_002','g_001','g_001']` hashes `[["g_001",2],["g_002",1]]`. One changed card or copy count creates a different deck ID. The public `cards` array uses that sorted order.

Only full valid compositions are included: 1–40 cards, at most two copies per card (one for LEGENDARY), and every card must be collectible and not a token in the currently committed public catalog. If either deck fails, the whole match is omitted. The API never publishes a partial list as an exact deck. Small custom test decks remain distinct valid compositions. Transformed, generated and drawn cards do not alter starting-deck identity: a transforming Crimson card belongs to the deck under its original card ID.

## Statistics on every deck and matchup row

| Field | Meaning |
|---|---|
| `matches`, `wins`, `losses` | Integer seat-game counts; wins + losses = matches. |
| `winRate` | Wins / matches, a fraction from 0 to 1. |
| `winRateInterval` | `{lower,upper}`, Wilson 95% interval, also fractions. |
| `testers` | Distinct human participants involved, including human opponents; never AI accounts. |
| `averageTurns` | Mean recorded game turn count, or null when no turn samples exist. |
| `turnSamples` | Seat-games with a valid recorded turn count. |
| `first`, `second`, `unknownFirst` | Each has matches/wins/losses/winRate; zero-count split rate is null. |

For example, a record with 3 matches, 2 wins and 1 loss has `winRate:0.6666666666666666` and a Wilson interval approximately `{lower:0.208,upper:0.939}`. Render as percentages but retain integer sample counts. Show `testers` and label small samples as preliminary. Repeated games by the same people are not independent observations; these intervals do not establish causal card strength or guarantee population balance.

`games` counts physical matches. Summing all deck `matches` yields twice `games`, and summing all deck `wins` yields `games`. A PvP mirror contributes two seat-games (one win, one loss) to the same human deck and matchup bucket. An AI mirror contributes one human result and one separate AI result. A deck overall record combines its opponent rows; distinct tester counts cannot be summed across rows.

`methodology` identifies `metric:"exact_starting_deck_matchup"`, `unit:"seat_game"`, `rolesSeparated:true`, `minSample:1`, and `preliminary:true`. Its `source` is `client_reported` for ranked AI or `server_verified` for authoritative PvP. AI reports are authenticated client submissions, not server-simulated proof. PvP requires a finished authoritative match, a settling reason, and consistent canonical settlements for both participants. Legacy peer-to-peer PvP and unfinished/drawn/voided/contradictory matches are excluded. Missing authoritative tables produce empty PvP results.

## Display and failure behavior

Use a human-deck list with overall record and sample count, then an opponent table for the selected deck. Keep AI/PvP and version/difficulty selectors visible. Display compositions using the printed catalog. Similar compositions remain separate; there is no archetype grouping endpoint. Existing per-card inclusion statistics remain available, but the deck matchup route does not provide drawn, played or mulligan card rates.

The owner authorized public exact deck lists and results beginning at one sample. Counts and compositions can permit inference even though names and individual histories are absent. Do not describe these data as proof of anonymous, independent or unbiased balance testing.

The relay reads at most 50,000 source matches in the selected mode/time window **before** version filtering, and returns 503 if that ceiling or the 4 MiB response ceiling is exceeded. Reduce `days` rather than showing an incomplete sample. Successful per-query snapshots are cached 60 seconds with at most 64 keys; identical concurrent requests share a refresh. Failures are not cached. The catalog uses a 5-second, 4 MiB upstream limit, refuses redirects and validates/project public fields. A 503 can mean unavailable service/data or a safety bound; never label it as zero games. Poll no more frequently than the snapshot cadence.

## Rollout and local proof

Deploy the relay, then catalog. Until the new relay route is available the catalog returns 503 for it; old card/static routes remain compatible. Both use the existing `CARD_WINRATES_ORIGIN` catalog setting (default relay origin), existing DB pool and JSON columns; no schema migration or backfill is required. Deploy the updated Web client for future policy/first-player metadata. Older saved decks can already contribute in their recorded/unknown cohorts.

From the repository root, with an exclusively disposable `DATABASE_URL` and `GODOT_BIN` set:

```sh
node --test server/test/deck_matchups.test.js server/test/card_winrates.test.js server/test/ranked_ai_record.test.js
```

Run `node --test 'catalog/test/*.test.mjs'` without `DATABASE_URL`. The producer test redirects Godot user storage into an isolated temporary directory and uses synthetic login data. Never point these tests at a production database.

After deployment, fetch both modes, verify CORS and 503 handling behind the hosting proxy, complete a ranked AI game using the new client, then verify its deck/opponent results after cache expiry under the correct rules, AI version and level. Hosted deployment and this live smoke check remain operator work.
