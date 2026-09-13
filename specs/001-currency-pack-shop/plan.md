# Implementation Plan: Currency, Shop & Pack Unboxing

**Branch**: `001-currency-pack-shop` | **Date**: 2026-09-11 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/001-currency-pack-shop/spec.md`

## Summary

Add a server-authoritative currency ("gold") and crafting currency ("dust")
economy: players earn gold from daily/milestone play rewards, spend it in a
new Shop screen to buy card packs, watch a Hearthstone-style sequential
reveal animation when opening a pack, and see new cards land in a
(newly-introduced) owned-card collection — with any pull that would exceed a
card's deck-building copy limit converting to dust instead, spendable to
craft a specific card. Real-money purchase of gold is confirmed as wanted
but explicitly deferred (User Story 5) — this plan only covers the earn/shop
/open/craft loop.

## Technical Context

**Language/Version**: GDScript (Godot 4.3) for the client; Node.js
(existing `server/relay.js`) for server-authoritative economy state.

**Primary Dependencies**: Godot 4.3 engine + existing autoloads
(`CardDatabase`, `DeckManager`, `Auth`, `Net`); Godot `Tween`/`AnimationPlayer`
for the pack-reveal animation (same tooling already used for
`animate_creature_attack`/`animate_creature_challenge` in `board.gd`); server
side reuses the existing `ws` and `pg` (PostgreSQL client) dependencies
already in `server/relay.js` — no new dependencies.

**Storage**: PostgreSQL, via the existing `players` table in
`server/relay.js` (extended with `currency` and `dust` integer columns,
following the established `ALTER TABLE players ADD COLUMN IF NOT EXISTS`
migration pattern already used for the ranked-ladder columns) plus one new
`owned_cards` table (`player_id`, `card_id`, `quantity`). No per-account card
ownership currently exists anywhere in the codebase — the deck builder's
"collection editor" today lists every card unconditionally — so this feature
introduces real ownership gating for the first time.

**Testing**: No formal automated test suite exists in this project (by
design — see constitution). Verification follows the existing pattern: a new
headless dev CLI hook (`--shop-test`, alongside `--campaign-test`/
`--tank-test`/`--mcts-benchmark` in `main.gd`) exercises earn → purchase →
open → duplicate → craft with no GUI, plus manual playtesting in the editor
for the reveal animation and Shop UI.

**Target Platform**: Same as the existing game — Godot desktop build,
1280x720, Forward Plus renderer. No new platform.

**Project Type**: Single Godot client + its existing Node.js relay server
(this feature extends both, it does not add a new service).

**Performance Goals**: Reveal animation runs at the project's existing
smooth-animation bar (comparable to `animate_creature_attack`'s ~0.33s
per-step feel) with no visible stutter for a full 5-card pack (SC-003).

**Constraints**: Currency/dust/collection mutations MUST be
server-authoritative (the client never locally invents or trusts a balance
change) — the same authority model already used for ranked ladder state via
`Auth.report_ranked_result()` → `relay.js`. Balance changes MUST reflect in
the UI without an app restart (SC-002).

**Scale/Scope**: Single-player-focused hobby project; no new infrastructure
beyond the existing relay server and its Postgres database. MVP is
earn-and-spend only — real-money purchase (User Story 5) is out of scope for
this plan but the schema/message design must not preclude adding it later
(a `source` tag on currency credits is enough; see data-model.md).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Check | Result |
|---|---|---|
| I. Logic/Presentation Separation | New economy logic (balance math, pack rolling, duplicate→dust conversion) lives in new pure-logic scripts (`economy.gd`, `pack_opener.gd`), not in `shop_screen.gd`/`pack_open_screen.gd`, which stay presentation-only and emit signals upward — mirrors the existing `game_state.gd` vs `board.gd` split. | PASS |
| II. Explicit State Sync | Shop/collection UI screens rebuild their displayed list from the authoritative server-confirmed balance/collection after every mutation (purchase, open, craft) rather than optimistically patching individual widgets. | PASS |
| III. Data-Driven Card Content | Pack definitions (price, card count, rarity odds) live in a new `data/shop_packs.json`, read the same way `data/cards/*.json` is read today; no per-card branches are added to game logic. | PASS |
| IV. Docs Stay in Sync with Code | `.docs/architecture.md` (new autoloads), `.docs/status.md` (new working features) must be updated once implemented — tracked as explicit tasks in `/speckit-tasks`, not skipped. | PASS (planned) |
| V. Starter Deck Integrity | Packs never modify starter deck composition; unaffected. | PASS |

No violations requiring justification. Complexity Tracking table is empty.

**Post-Phase-1 re-check**: data-model.md and contracts/shop-protocol.md keep
all economy math (balance debits, pack rolling, dust conversion) server-side
in `relay.js` and in the pure-logic `pack_opener.gd`/`economy.gd`, with
`shop_screen.gd`/`pack_open_screen.gd` only ever rendering a server-returned
result — consistent with Principle I as designed, not just as summarized
above. No new violations introduced by the Phase 1 design.

## Project Structure

### Documentation (this feature)

```text
specs/001-currency-pack-shop/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md         # Phase 1 output
├── quickstart.md         # Phase 1 output
├── contracts/            # Phase 1 output (client<->relay message contracts)
└── tasks.md              # Phase 2 output (/speckit-tasks - not created here)
```

### Source Code (repository root)

```text
data/
└── shop_packs.json            # NEW: pack definitions (price, card count, rarity odds)

scripts/
├── game/
│   ├── economy.gd              # NEW autoload "Economy": currency/dust balance state,
│   │                            #   mirrors server-confirmed values, exposes earn/spend API
│   ├── pack_opener.gd          # NEW: pure logic - rolls a pack's cards from CardDatabase
│   │                            #   by rarity odds, applies guaranteed-rare rule, converts
│   │                            #   over-limit duplicates to dust (no Node dependencies)
│   └── main.gd                 # MODIFIED: add `--shop-test` headless CLI hook
└── ui/
    ├── shop_screen.gd          # NEW: Shop UI (balance display, pack listings, purchase)
    └── pack_open_screen.gd     # NEW: sequential card-reveal animation + skip handling

server/
└── relay.js                    # MODIFIED: players.currency/dust columns, owned_cards
                                 #   table, new message types (see contracts/)
```

**Structure Decision**: Follows the existing single-Godot-client +
Node.js-relay layout (no new top-level project). New client logic sits
alongside its existing analogues (`economy.gd` next to `deck_manager.gd`;
`pack_opener.gd` next to `headless_turn.gd`'s pure-logic style); new UI sits
alongside `deck_builder_screen.gd`/`card_list_screen.gd` in `scripts/ui/`;
server changes extend `relay.js` in place, matching how ranked-ladder support
was added to the same file rather than a new service.

## Complexity Tracking

*No entries — no constitution violations identified.*
