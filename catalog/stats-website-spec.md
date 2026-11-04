# Deck matchup API: website developer contract

The [Moon bots API](../server/MOON_BOTS.md#website-api), `/data/stats/bot-matchups.json?mode=ranked&days=30`, supplies detailed genuine ranked results for Io, Callisto, Europa, Ganymede and Amalthea with anonymous human-opponent buckets. Their initial release is `1.0`; stored results retain bot/rules/engine versions. By owner request, genuine ranked-bot games also contribute to the existing combined deck/card statistics below, so the default stats page shows their results alongside human and local ranked-AI games. Explicit filtered AI/human-PvP views retain their cohorts. `mode=simulation` (the bot API default) retains isolated non-ranked simulations, which remain outside shared ranked statistics. No data is fabricated before activation.

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
  mode: 'all', days: '30', rulesVersion: 'latest'
});
const response = await fetch(url);
if (!response.ok) throw new Error(`Stats unavailable (${response.status})`);
const snapshot = await response.json();
```

| Parameter | Allowed values | Default |
|---|---|---|
| `mode` | `all`, `ranked_ai`, `authoritative_pvp` | `ranked_ai` (legacy API default; website explicitly selects `all`) |
| `days` | Integer 1–365 | 30 |
| `rulesVersion` | Positive integer up to 1,000,000, `latest`, `unknown` | `latest` |
| `aiVersion` | Positive integer up to 1,000,000, `latest`, `unknown`; AI mode only | `latest` |
| `aiLevel` | Integer 1–10; AI mode only | 10 |

PvP example: `/data/stats/deck-matchups.json?mode=authoritative_pvp&days=30&rulesVersion=latest`. Do not send AI parameters in all or PvP mode. Unknown keys, repeated parameters, empty values, signed/decimal/noncanonical numbers and irrelevant AI parameters return 400. Unsupported methods return 405. GET, HEAD, OPTIONS and anonymous CORS are supported.

The window runs from snapshot time minus `days × 24 hours` through snapshot time, inclusive, using AI settlement time or PvP ended time. In filtered modes, populations remain separate. Resolution order is: valid mode/time records → AI level and all explicit versions → highest remaining known rules version → highest remaining known AI policy version within that rules version. A latest selection resolves to `unknown` only when no known version remains. Selecting an explicit nonexistent version returns an empty cohort.

`filters` echoes resolved values. All/PvP return `aiVersion:null, aiLevel:null`; their available AI filter arrays are empty. `availableFilters` provides:

- `rulesVersions`: mode/time/level choices conditioned on any explicit AI version.
- `aiVersions`: mode/time/level choices within the resolved rules version, ignoring the requested AI version.
- `aiLevels`: all valid levels in the mode/time window; discovery choices do not promise every version combination exists. Empty for PvP.

Older AI summaries lack `ai_version` and/or `first_player`. Missing policy versions remain in the explicit `aiVersion=unknown` cohort; missing first-player facts contribute to `unknownFirst`. New clients report `AIController.POLICY_VERSION` (initially 1). Difficulty is not a substitute for policy version. Version fields do not version the printed catalog and cannot reconstruct historical card definitions.

## Combined playtest results

Explicit mode=all pools eligible ranked-AI, authoritative-player and genuine automated ranked-bot matches within the chosen date window and rules version. It includes every AI difficulty/policy, including missing historical policy metadata. Latest rules resolves across the union; it does not pool different rules versions. AI-specific query parameters are invalid. API calls without mode retain the old ranked-AI default for compatibility. Isolated simulations remain excluded.

All controller types contribute to each exact composition's combined record. Physical games are counted once; both deck results contribute, including mirrors. Distinct testers union real human participants across sources, excluding bot seats using immutable match snapshots, never sums of already-aggregated counts. A bot-only record has zero human testers; mixed human/bot games count their human participant. Raw source/provenance and AI metadata remain stored; all is a read-only view, not a historical rewrite. Repeated automated games can dominate playtest samples and do not establish causal card strength.

## Response and joins

The response has `generatedAt`, `filters`, `availableFilters`, `methodology`, `games`, `playStats`, `decks`, and `matchups`. No eligible games is a successful response with `games:0`, `decks:[]`, and `matchups:[]`.

A `decks` entry contains:

```text
id: SHA-256 hex string
cards: [{id: card ID, copies: integer}, ...]
factions: sorted non-GENERIC printed colors, or ["GENERIC"]
role: "combined" | "human" | "ai"
...statistics
```

A `matchups` entry contains:

```text
deckId, role: this deck's ID and controller role
opponentDeckId, opponentRole: the opposing deck's ID and controller role
...statistics
```

Always join with **both ID and role**. In filtered modes the same composition can have separate human and AI records; PvP uses human for both sides. In all mode both roles are combined, so each exact composition has one record. Every matchup includes its reverse perspective with opposite results. Do not add the reverse row when displaying one deck's win rate.

```js
const byKey = new Map(snapshot.decks.map(d => [`${d.id}/${d.role}`, d]));
const displayedDecks = snapshot.decks.filter(d => d.role === (snapshot.filters.mode === 'all' ? 'combined' : 'human'));
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

`games` counts physical matches. Summing all deck `matches` yields twice `games`, and summing all deck `wins` yields `games`. A PvP mirror contributes two seat-games (one win, one loss) to the same human deck and matchup bucket. A filtered AI mirror contributes one human result and one separate AI result. In all mode either type of mirror contributes two results (one win and one loss) to the same combined bucket. A deck overall record combines its opponent rows; distinct tester counts cannot be summed across rows.

`methodology` identifies `metric:"exact_starting_deck_matchup"`, `unit:"seat_game"`, `rolesSeparated:true` for filtered modes (`false` for all), `minSample:1`, and `preliminary:true`. Its `source` is `mixed` for all, `client_reported` for ranked AI or `server_verified` for authoritative PvP. Mixed describes the eligible sources, even when only one currently has games. AI reports are authenticated client submissions, not server-simulated proof. PvP requires a finished authoritative match, a settling reason, and consistent canonical settlements for both participants. Legacy peer-to-peer PvP and unfinished/drawn/voided/contradictory matches are excluded. Missing authoritative tables produce empty PvP results.

## Recorded plays and card-table formulas

Snapshots additionally expose playStats:

```text
{totalSeats: 2*games, trackedSeats, completeSeats, cards:[{id,plays}]}
```

trackedSeats counts deck results with usable observed play history; completeSeats counts new full tracking. Both are nonnegative integers with completeSeats <= trackedSeats <= totalSeats. New tracking counts actual play events, including replayed/generated copies of published cards. Draws, attacks, transformations and direct summons do not count. Old PvP deck_cards.played_copies can supply known partial counts; missing or malformed optional recording leaves deck results eligible and never invents zero plays. Cards are unique published IDs; known counts are nonnegative integers bounded to one million plays per tracked seat in total. Unknown extra fields and private facts are not forwarded. Old upstream filtered snapshots lacking playStats project to unknown coverage.

New AI summaries optionally send card_plays={player:{cardId:count},opponent:{cardId:count}}. Normalization copies bounded known counts into the existing JSON. Unusable optional counters are omitted without rejecting an otherwise valid result. New authoritative facts put full card_plays inside each facts.seats.a/b object. No schema migration or reconstruction of missing historical events is performed.

Use the selected snapshot's deck rows for all three starting-deck metrics. Let N=sum(deck.matches), I=sum(matches for lists containing the card), C=sum(matches*copies), W=sum(wins for containing lists). In % of decks is I/N, average copies is C/I, and deck win rate is W/I. Counts are game-weighted, not averages over unique lists. A card's two starting copies count as one inclusion per deck result. Undefined ratios display an em dash. These are deck outcomes, not individual card contribution.

Times played comes from playStats.cards, independently of starting-deck inclusion. A generated card may have plays and no starting appearances. If trackedSeats=0, show unavailable play history, not zero. With partial coverage, show recorded counts as lower bounds and explain coverage; with complete coverage, a missing card count means a known zero. Keep small-sample counts available. The legacy lifetime card-winrates route remains unchanged; the new Cards tab uses this selected cohort instead.

## Display and failure behavior

The website defaults to all mode, with a combined exact-deck list and a short opponent table. Game type and AI controls are removed; date/rules filters and methodology remain available. Existing filtered URLs stay valid. Display compositions using the printed catalog. Similar compositions remain separate; there is no archetype grouping endpoint. Existing per-card inclusion statistics remain available, but the deck matchup route provides actual recorded play counts, but not drawn or mulligan card rates.

The owner authorized public exact deck lists and results beginning at one sample. Counts and compositions can permit inference even though names and individual histories are absent. Do not describe these data as proof of anonymous, independent or unbiased balance testing.

The relay reads at most 50,000 source matches in the selected mode/time window **before** version filtering (the combined total across both sources for all), and returns 503 if that ceiling or the 16 MiB response ceiling is exceeded. Reduce `days` rather than showing an incomplete sample. Successful per-query snapshots are cached 60 seconds with at most 64 keys; identical concurrent requests share a refresh. Failures are not cached. The catalog uses a 5-second, 16 MiB upstream limit, refuses redirects and validates/project public fields. A 503 can mean unavailable service/data or a safety bound; never label it as zero games. Poll no more frequently than the snapshot cadence.

## Rollout and local proof

Deploy the compatible relay and catalog update first; once both support all, deploy the website switch and Web client. Old clients remain valid and contribute unknown play coverage. Until the new relay route is available the catalog returns 503 for it; old card/static routes remain compatible. Both use the existing `CARD_WINRATES_ORIGIN` catalog setting (default relay origin), existing DB pool and JSON columns; no schema migration or backfill is required. Deploy the updated Web client for future full-play counts. Older saved decks can already contribute in their recorded/unknown cohorts.

From the repository root, with an exclusively disposable `DATABASE_URL` and `GODOT_BIN` set:

```sh
node --test server/test/deck_matchups.test.js server/test/card_winrates.test.js server/test/ranked_ai_record.test.js
```

Run `node --test 'catalog/test/*.test.mjs'` without `DATABASE_URL`. The producer test redirects Godot user storage into an isolated temporary directory and uses synthetic login data. Never point these tests at a production database.

After deployment, fetch combined and legacy modes and verify public panels, CORS and deployed client bytes. A future normal playtest can confirm new full-play coverage after cache expiry; do not submit artificial matches to production for verification.
