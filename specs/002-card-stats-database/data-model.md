# Data Model: Card Statistics Database

All tables live in the existing Postgres database, created idempotently from
`server/stats/schema.js` (called from `initDb()`), following the
`CREATE TABLE IF NOT EXISTS` / `ADD COLUMN IF NOT EXISTS` convention already
used for `players`, `decks`, `owned_cards` and `ranked_settlements`.

**Privacy zone**: every `stat_*` table is *private*. None is returned by any
relay message. Only the maintainer CLI reads them. Only the release builder
output (a file) leaves the private zone.

## Private tables

### `stat_matches` — one row per match (spec: Match Record)

| Column | Type | Notes |
|---|---|---|
| `match_id` | TEXT PK | Server-issued (`rk_*`, `cp_*`, lobby id) or client-issued (`ai_*`, unverified only) |
| `match_type` | TEXT | `ranked`, `casual`, `campaign`, `ai` |
| `game_version` | TEXT | From the client report, checked against the server's allowed list |
| `status` | TEXT | `pending`, `verified`, `unverified`, `disputed`, `rejected` — see transitions |
| `status_reason` | TEXT | Machine code: `ok`, `single_report`, `winner_conflict`, `deck_illegal`, `public_plays_mismatch`, `implausible_duration`, `unknown_version`, `report_timeout`, … |
| `end_reason` | TEXT | `completed`, `conceded`, `disconnected`, `abandoned` |
| `first_seat` | TEXT | `host`, `guest`, `ai` — who moved first |
| `winner_seat` | TEXT NULL | NULL for draw/abandoned |
| `turns` | INTEGER | Agreed turn count |
| `duration_s` | INTEGER | Server-observed |
| `relay_msgs` | INTEGER | Server-observed total relayed action messages |
| `created_at` / `settled_at` | TIMESTAMPTZ | Private; never published |

Indexes: `(status, game_version, match_type)`, `(settled_at)` for retention.

### `stat_sides` — one row per participant (spec: Side)

| Column | Type | Notes |
|---|---|---|
| `match_id` | TEXT FK → `stat_matches` ON DELETE CASCADE | |
| `seat` | TEXT | `host`, `guest`, `ai` |
| `player_id` | INTEGER NULL FK → `players(id)` **ON DELETE SET NULL** | NULL for AI seat, and after unlink |
| `account_key` | TEXT NULL | `HMAC(STATS_KEY, player_id)` truncated; NULLed by unlink |
| `tier_group` | TEXT | `low`, `mid`, `high`, `legend`, `none` — derived **server-side at match start** from `players.rank_*` |
| `factions` | TEXT | Sorted, comma-joined faction names (1–2) |
| `deck_hash` | TEXT | Hash of the sorted starting card-id list |
| `report_received_at` | TIMESTAMPTZ NULL | NULL until that seat reports |
| `reported_won` | BOOLEAN NULL | That seat's own claim |
| PK `(match_id, seat)` | | Idempotency key for reports |

### `stat_deck_cards` — one row per distinct starting-deck card per side (spec: Deck Card Fact)

| Column | Type | Notes |
|---|---|---|
| `match_id`, `seat` | FK → `stat_sides` | |
| `card_id` | TEXT | Stable catalog id |
| `copies` | SMALLINT | Copies in the starting deck |
| `drawn_copies` | SMALLINT | ≤ `copies`; includes opening hand |
| `kept_copies` | SMALLINT | Opening-hand copies kept through the mulligan |
| `played_copies` | SMALLINT | Times played (a replay counts again) |
| `first_played_turn` | SMALLINT NULL | NULL if never played |
| `attested` | BOOLEAN | TRUE when the draw/keep facts came only from the host's report for a guest seat |
| PK `(match_id, seat, card_id)` | | |

Constraints: `kept_copies ≤ drawn_copies ≤ copies`; `played_copies ≥ 0`.
Index `(card_id)`.

### `stat_created_cards` — cards not from the starting deck (spec: Created Card Fact)

`(match_id, seat, card_id, count, played_count)`, PK `(match_id, seat, card_id)`.
Never joined into draw/keep/deck figures (FR-005).

### `stat_reports` — raw submissions for dispute audit

`(match_id, seat, received_at, payload JSONB)`, PK `(match_id, seat)`. Kept for
disputed/rejected matches and pruned with the match on retention.

### `stat_audit` — append-only log

`(id, at, actor, action, detail JSONB)`. `actor` is `relay` (rejected/abusive
report attempts, with reason code) or `cli:<os-user>` (every maintainer
command). No player identifiers beyond `player_id` already private here.

## Derived tables (rebuilt by `stats.js aggregate`, private)

### `stat_summary_card`

Key `(game_version, tier_group, match_type, faction_pair, card_id)`;
columns: `matches_with`, `drawn_matches`, `kept_matches`, `played_matches`,
`wins_with`, `wins_drawn`, `wins_kept`, `wins_played`, plus the same counts
**after the per-account (10) and pair (5) caps** (`*_capped`). Only
`status = 'verified'` rows and `end_reason IN ('completed','conceded')` feed
it; draws/abandons are counted separately as data-quality fields.

### `stat_summary_deck`

Key `(game_version, tier_group, match_type, faction_pair)` (published) and a
private variant keyed additionally by `deck_hash`. Columns: `matches`,
`wins`, capped equivalents.

### `stat_releases`

`(release_id PK, game_version, built_at, content_hash, status, approved_at,
min_sample, account_cap, pair_cap)`; `status` ∈ `draft`, `published`,
`withdrawn`. A `published` row is write-once.

## Public (file) entities

Not tables — see [contracts/published-card-stats.md](./contracts/published-card-stats.md):
**Summary Release** with **Card Summary** and **Deck Archetype Summary** entries.

## State transitions — `stat_matches.status`

```text
            first report                      second report agrees + checks pass
 (registered) ───────────▶ pending ──────────────────────────────────────────▶ verified
                              │  second report conflicts / checks fail ────────▶ disputed
                              │  window (120 s) expires with one report ───────▶ unverified (single_report)
 (never registered, client id) ── one authenticated report ───────────────────▶ unverified (ai)
 (non-participant / unknown human match / replay after settle) ─────────────────▶ rejected (not stored, audit only)
```

`verified` is terminal. `disputed` and `unverified` may be re-evaluated only by
a maintainer command that records its reason in `stat_audit`. `rejected`
reports create no `stat_matches` row, only an audit row.

## Relationships

`stat_matches 1—2 stat_sides 1—N stat_deck_cards`;
`stat_sides 1—N stat_created_cards`; `stat_sides.player_id → players` (nullable);
`stat_summary_*` are functions of verified `stat_*` rows;
`stat_releases` reference the summaries by content hash only.

## Retention

A maintainer command (`stats.js purge --older-than 24m`) deletes
`stat_matches` (cascading to sides, cards, reports) older than the retention
period after the aggregates for their versions are archived into
`stat_releases`/published files; the default is 24 months and is a setting,
not a constant.
