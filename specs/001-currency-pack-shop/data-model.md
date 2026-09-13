# Phase 1 Data Model: Currency, Shop & Pack Unboxing

Entities below correspond to the Key Entities in [spec.md](./spec.md).
Server-side fields live in PostgreSQL (`server/relay.js`); client-side
fields mirror them in the new `Economy` autoload for display, but the
server copy is always authoritative (Technical Context: server-authoritative
constraint).

## Currency Balance (`players.currency`)

| Field | Type | Notes |
|---|---|---|
| `player_id` | FK → `players.id` | One row per account (column on existing table, not a new table) |
| `currency` | integer, default 0 | Spendable balance ("gold"); never negative |

**Validation rules**:
- A spend (pack purchase) MUST be rejected server-side if it would take
  `currency` below 0 (FR-006).
- A credit (earn reward) is always additive; source of the credit
  (`daily_bonus` / `ranked_milestone` / `campaign_milestone`) is logged for
  the earn-history/telemetry needed by SC-002, and leaves room for a future
  `purchase` source (User Story 5) without a schema change.

**State transitions**: `currency` only ever increases (earn/future-purchase)
or decreases (pack purchase). No other entity depends on its value changing
except pack purchase eligibility (FR-006).

## Crafting Currency / Dust (`players.dust`)

| Field | Type | Notes |
|---|---|---|
| `player_id` | FK → `players.id` | Column on existing `players` table |
| `dust` | integer, default 0 | Never negative |

**Validation rules**:
- Credited only as a side effect of a pack pull that exceeds a card's
  deck-building copy limit (FR-012) — amount determined by that card's
  rarity (see Card Pack below).
- Debited only by crafting a specific card (FR-013); rejected server-side if
  it would go below 0.

## Card Pack (Shop Listing) — `data/shop_packs.json`

Data-driven per Constitution Principle III; not a database table (packs are
content, not player state).

| Field | Type | Notes |
|---|---|---|
| `pack_id` | string | e.g. `"standard_pack"` |
| `display_name` | string | Shown in the Shop |
| `price` | integer | Cost in currency |
| `card_count` | integer | Cards per pack (default 5, per Assumptions) |
| `rarity_weights` | object | `{ "COMMON": n, "RARE": n, "EPIC": n, "LEGENDARY": n }` — relative roll weights |
| `guaranteed_rare_or_better` | boolean | Enforces FR-008 |
| `dust_value` | object | Per-rarity dust amount awarded when a pull is an over-limit duplicate (`{ "COMMON": n, ... }`) |

## Pack Opening Result (ephemeral, not persisted as its own table)

| Field | Type | Notes |
|---|---|---|
| `pack_id` | string | Which listing was opened |
| `cards` | array of `{ card_id, was_new: bool }` | `was_new = false` entries were converted to dust, not added to the collection |
| `dust_awarded` | integer | Sum of dust from any `was_new = false` entries |

**Relationships**: Produced by rolling a purchased Card Pack against the
player's current Owned Card Collection (to determine `was_new`); its effects
(collection increments + dust credit) are applied atomically server-side so
a mid-reveal disconnect (Edge Case) can't leave currency debited with no
result recorded — the roll result is persisted before the client animates it.

## Owned Card Collection (`owned_cards` table — NEW)

| Field | Type | Notes |
|---|---|---|
| `player_id` | FK → `players.id` | |
| `card_id` | string | References a `CardDatabase` card id |
| `quantity` | integer, default 0 | How many copies the player owns |

**Validation rules**:
- Incremented by pack-opening results where `was_new = true`, and by
  crafting.
- A card's *usable-in-deck* copy limit (e.g. max 1 Legendary) is a
  deck-building rule, not a cap on `quantity` here — `quantity` can exceed
  the usable limit only via crafting-then-owning duplicates deliberately;
  normal pack pulls never push a pull past the limit because over-limit
  pulls convert to dust before reaching this table (FR-012).

**Relationships**: Primary key `(player_id, card_id)`. Read by the deck
builder (existing `deck_builder_screen.gd`) once ownership gating is wired
in — out of this feature's UI scope beyond exposing the data (deck-builder
enforcement itself is not a requirement listed in spec.md).

## Shop (client-side view, no new persistence)

Composed at render time from: current `Currency Balance` (via `Economy`
autoload) + the static `data/shop_packs.json` listings. Not a stored entity.
