# Contract: Published Card Statistics Release

Public, anonymous, immutable. Served by the existing `catalog/` static server
(read-only, `GET`/`HEAD`/`OPTIONS`, `Access-Control-Allow-Origin: *`, no
account). It extends the catalog's URL space; it does not add a server.

```text
GET /data/v1/stats/latest.json
GET /data/v1/stats/releases/<release-id>/card-stats.json
GET /data/v1/stats/releases/<release-id>/deck-stats.json
```

`latest.json` is `Cache-Control: no-cache` with an ETag; release files are
`public, max-age=31536000, immutable` — identical to the catalog's cache
policy (see `catalog/src/server.mjs`). A published release never changes; a
correction is a new release id. Earlier releases stay retrievable.

## `latest.json`

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

`catalogVersion` names the card catalog release these ids resolve against.
Card ids are exactly the catalog's `id` values.

## `card-stats.json`

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

Field rules:

- A card appears in a slice only if **every** figure shown for it meets
  `minSample` *after capping*. A figure below it is omitted from that card's
  object (the key is absent), not shown as `0` or `null`; if no figure
  qualifies the card is absent from the slice.
- `n.*` are sample sizes backing the matching rates, rounded down to the
  nearest 10.
- Rates are fractions in `[0, 1]` rounded to 3 decimals (0.1 pp).
- `tierGroup` ∈ `low`, `mid`, `high`, `legend`; `matchType` ∈ `ranked`,
  `casual`, `campaign`. **No other slicing exists.** AI and unverified
  matches never appear.
- `generatedOn` is a calendar date only.

## `deck-stats.json`

Same envelope. `slices[].decks[]` entries are keyed by faction pair only:

```json
{ "factions": ["GREEN", "TEAL"], "matches": 940, "winRate": 0.508 }
```

Single-faction decks use a one-element `factions`. Subject to the same
`minSample`/cap rules. There is never a card list, deck code or deck hash.

## Privacy invariants (enforced by the release builder, verified by tests)

A release MUST NOT contain, anywhere in either file: usernames, account or
player identifiers, `account_key`, match identifiers, session data, timestamps
finer than a date, per-deck card lists, deck hashes, or any figure from fewer
than `minSample` capped qualifying matches. The builder runs an automated scan
over the serialized output for these patterns and for every known username /
match id in the private tables, and **refuses to write a draft** if anything
matches.

## Build and publication flow (maintainer only)

1. `stats.js aggregate` → rebuild private summaries.
2. `stats-release.mjs build --game-version <v>` → writes a **draft** under
   `catalog/.drafts/` plus a human-readable review report: counts per slice,
   what was suppressed and why, the privacy-scan result, and a diff vs the
   previous release.
3. Maintainer reviews, then `stats-release.mjs publish --approve <draft>` →
   atomically writes the release (write-once, identical bytes = no-op,
   different bytes under the same id = refuse), then switches `latest.json`.
4. Rollback: `stats-release.mjs set-latest <release-id>` (never rewrites a
   release).

Nothing publishes automatically and no step is reachable from the game server.
