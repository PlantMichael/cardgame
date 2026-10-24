# Data Model: Server-Authoritative Ranked Matches

## Durable tables (Postgres, created idempotently from `server/authoritative/`)

### `ranked_matches` — one row per server-run match (spec: Ranked Match)

| Column | Type | Notes |
|---|---|---|
| `match_id` | TEXT PK | `rk_*`; same identity the ladder already settles on (`ranked_settlements.match_id`) |
| `mode` | TEXT | `authoritative` (this feature) — legacy matches have no row here |
| `status` | TEXT | `waiting`, `active`, `finished`, `voided` |
| `end_reason` | TEXT NULL | `completed`, `conceded`, `forfeit_disconnect`, `forfeit_timeout`, `abandoned`, `voided_fault` |
| `rules_version` | INTEGER | Version of rules + card data the match runs under |
| `seed` | BIGINT | Server-generated; reproduces all randomness |
| `first_seat` | TEXT | `a` or `b`, chosen by the server |
| `seat_a_player_id`, `seat_b_player_id` | INTEGER FK → `players` ON DELETE SET NULL | |
| `deck_a`, `deck_b` | JSONB | Card-id lists **copied from the `decks` table at match start** (never from the client) |
| `winner_seat` | TEXT NULL | NULL for draw/void/abandoned |
| `final_state_hash` | TEXT NULL | Hash of the final state; used to confirm replays |
| `created_at`, `started_at`, `ended_at` | TIMESTAMPTZ | |

### `ranked_match_actions` — append-only action log (spec: Action History)

| Column | Type | Notes |
|---|---|---|
| `match_id` | TEXT FK → `ranked_matches` ON DELETE CASCADE | |
| `seq` | INTEGER | 1, 2, 3 … assigned by the host; gapless |
| `seat` | TEXT | `a`, `b`, or `system` |
| `kind` | TEXT | `command`, `answer`, `timeout_default`, `concede`, `forfeit` |
| `command` | JSONB | The plain-value command exactly as the rules core accepted it |
| `state_hash` | TEXT | State hash **after** applying it (cheap divergence detector) |
| `at` | TIMESTAMPTZ | |
| PK `(match_id, seq)` | | A duplicate/stale insert fails — enforces single ordering (FR-006) |

An action is acknowledged to the client only after its row is committed.
Refused actions are **not** logged as actions; they go to the audit trail below.

### `ranked_match_audit` — refused/abusive actions

`(id, match_id NULL, player_id NULL, at, reason, detail JSONB)` with reasons
such as `illegal_action`, `stale_seq`, `not_your_turn`, `bad_frame`,
`version_mismatch`, `seat_takeover`. Maintainer-readable only.

### Existing table reused unchanged

`ranked_settlements (match_id, player_id, won, outcome JSONB, settled_at)` —
settlement for a server-run match writes the same row, derived only from the
host's result; its primary key keeps settlement idempotent (FR-015).

## In-memory entities (relay)

| Entity | Fields | Notes |
|---|---|---|
| **Seat** | `match_id`, `seat` (`a`/`b`), `player_id`, `connection` (nullable), `controller_epoch` | Exactly one controlling connection; a newer epoch closes the older (FR-013) |
| **Clock** | `turn_deadline`, `disconnect_deadline`, `paused_for` | Relay-owned; the host never reads wall time |
| **Match Session** | `host_match_handle`, `last_seq`, `last_state_hash`, `seats[2]`, `status` | Rebuilt from the log on restart |
| **Pending client request** | `client_seq`, `received_at` | Used to refuse duplicates / stale actions |

## In-host entities (Godot match host)

| Entity | Notes |
|---|---|
| **Match** | A `GameState` plus `seed`, `rules_version`, `last_seq`, event buffer; no wall clock, no I/O |
| **View(seat)** | `GameState.to_net_dict(seat)` extended with `pending_choice` (visible to its owner only) and `clock` fields supplied by the relay |
| **Event** | Ordered, per-seat-filtered record (see contracts) |

## State transitions — `ranked_matches.status`

```text
(paired) ─ create ─▶ waiting ─ both seats present + mulligan done ─▶ active
active ─ win/loss detected by rules ──────────────────────────────▶ finished (completed)
active ─ concede ─────────────────────────────────────────────────▶ finished (conceded)
active ─ turn timer expiry repeated / disconnect grace expiry ─────▶ finished (forfeit_*)
active ─ both seats gone past grace ──────────────────────────────▶ finished (abandoned, no rank change)
active ─ host/relay restart, replay hash mismatch or unrecoverable ▶ voided (voided_fault, no rank change)
waiting ─ a seat never arrives ───────────────────────────────────▶ voided (no rank change)
```

`finished` and `voided` are terminal. Settlement runs exactly once on entry to
`finished`; `voided` and `abandoned` settle nothing.

## Relationships

`ranked_matches 1—N ranked_match_actions`; `ranked_matches 1—2 players`;
`ranked_matches 1—N ranked_match_audit`; `ranked_matches 1—2 ranked_settlements`
(via `match_id`); statistics facts (spec 002) hang off the same `match_id`.

## Retention

Action logs follow the statistics retention window (default 24 months) and are
deleted with their match. `ranked_match_audit` keeps 90 days by default.
