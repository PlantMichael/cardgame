# Phase 0 Research: Currency, Shop & Pack Unboxing

All Technical Context items were resolvable directly from the existing
codebase and constitution; no items remain marked NEEDS CLARIFICATION. This
document records the resulting decisions and the alternatives considered.

## 1. Where currency/dust balances live

**Decision**: Add `currency` and `dust` integer columns to the existing
`players` table in `server/relay.js`, using the same
`ALTER TABLE players ADD COLUMN IF NOT EXISTS ... DEFAULT 0` migration
pattern already used for every ranked-ladder column (`rank_bracket`,
`rank_lp`, etc.).

**Rationale**: The project already has exactly one server-authoritative,
per-account persistence mechanism (Postgres via `pg`), and exactly one
established migration convention for growing it. Reusing both means the
economy gets the same account-binding, session-auth, and reconnect behavior
ranked play already has, for free.

**Alternatives considered**:
- *New standalone service/database for the economy* — rejected: this is a
  solo-maintained hobby project (constitution: prefer the smallest change
  that works); a second datastore would duplicate auth/session plumbing that
  `relay.js` already owns.
- *Client-local storage only* — rejected: spec FR-015 explicitly requires
  server-side persistence so currency/collection follow the account, not one
  device, matching how custom decks already behave.

## 2. Modeling card ownership

**Decision**: Add a new `owned_cards` table (`player_id`, `card_id`,
`quantity`), keyed by the same `card_id` strings `CardDatabase` already uses
(e.g. `"g_001"`).

**Rationale**: No ownership concept exists anywhere in the codebase today —
`CardDatabase`/the deck builder currently treat every card as available to
everyone. This feature is what introduces ownership, so it needs its own
table rather than overloading `decks` (which stores deck *composition*, not
account-wide *possession*).

**Alternatives considered**:
- *A JSON/array column on `players`* (e.g. `owned_cards jsonb`) — rejected:
  a per-(player, card) row is simpler to increment/decrement atomically
  (pack opens, crafting, future dust refunds) than read-modify-write on a
  single JSON blob, and matches the relational style already used for
  `decks`.

## 3. Pack content rolling & the guaranteed-rare rule

**Decision**: `pack_opener.gd` is a pure-logic script (no `Node`
dependencies, following the `headless_turn.gd`/`ai_heuristics.gd` style):
given a pack definition (card count + rarity weight table from
`data/shop_packs.json`) and the full card pool from `CardDatabase`, it rolls
N independent weighted picks, then — if none landed Rare-or-better — replaces
one Common slot with a re-rolled Rare-or-better pick to satisfy FR-008.
Each picked card is then checked against the player's current owned quantity
and deck-building copy limit; an over-limit result is converted to a dust
amount (from a per-rarity dust table in the same JSON file) instead of a
collection increment.

**Rationale**: Keeping this pure logic (no scene/UI/network calls inside it)
means it can be exercised by the `--shop-test` headless hook the same way
`--mcts-benchmark` exercises `MCTSEngine`, satisfying Constitution Principle
I without inventing a new verification mechanism.

**Alternatives considered**:
- *Rolling packs server-side in `relay.js`* — considered, since currency
  deduction must be server-authoritative anyway. Rejected for the roll
  itself: card definitions/rarities live in the Godot project's JSON, not on
  the server, so duplicating `CardDatabase`'s data into Node would create a
  second source of truth. Instead the **server authorizes the purchase and
  records the resulting card list/dust it is told about**, while trusting
  the roll math is deterministic-enough to sanity-check server-side (see
  contracts/shop-protocol.md) rather than re-implementing it — a pragmatic
  middle ground for a solo project's threat model (no real-money purchases
  yet, so incentive to cheat is low).

## 4. Reveal animation approach

**Decision**: Sequential per-card reveal built with Godot `Tween` (the same
tool already driving `animate_creature_attack`/`animate_creature_challenge`
in `board.gd`), on a dedicated `pack_open_screen.gd`: cards animate in one
at a time (flip/scale-in + brief hold), with rarity-based flourish (e.g.
Legendary holds longer / has an extra flourish tween) — a lightweight nod to
Hearthstone's escalating-rarity pacing without requiring new engine features
or asset pipelines.

**Rationale**: Reuses an animation approach the codebase already has proven
patterns for, keeping this feature's "smooth animation" requirement
achievable without introducing a new animation framework.

**Alternatives considered**:
- *`AnimationPlayer` timeline authored per-pack in the editor* — rejected as
  primary approach: pack size/order is data-driven and randomized at
  runtime, which fits a scripted `Tween` sequence better than a fixed,
  hand-authored timeline; `AnimationPlayer` remains an option for any
  fixed shared flourish (e.g. a pack-shake-open clip) layered underneath.

## 5. Verifying the feature without a GUI

**Decision**: Add `--shop-test` to `main.gd`'s existing headless dev CLI
hook set, driving: grant currency → purchase pack → roll pack →
apply/convert results → craft a card — asserting balances and collection
counts at each step, printed to console.

**Rationale**: Matches the project's only existing verification strategy
(`--campaign-test`, `--tank-test`, `--mcts-benchmark`) instead of introducing
a new one, per the constitution's Development Workflow section.

**Alternatives considered**: A GDScript unit-test addon (e.g. GUT) —
rejected for this feature: it would be the first test framework in the
project, a larger footprint than one more CLI hook for verifying one
feature's logic.
