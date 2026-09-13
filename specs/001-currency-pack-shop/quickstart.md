# Quickstart: Validating Currency, Shop & Pack Unboxing

## Prerequisites

- Godot 4.3 editor with this project open.
- `server/relay.js` running locally against a reachable Postgres instance
  (same setup already required for login/ranked/decks), with the migration
  in this feature's tasks applied (`currency`/`dust` columns + `owned_cards`
  table).
- `data/shop_packs.json` present (added by this feature).

## Scenario A — Headless economy verification (no GUI)

Mirrors the existing `--campaign-test`/`--tank-test`/`--mcts-benchmark`
pattern; use it first since it doesn't require manually reaching thresholds
in a real match.

```bash
godot4 --headless --path . -- --shop-test
```

**Expected console output**: a sequence of assertions covering, in order:
1. A fresh account starts at `currency = 0, dust = 0`.
2. Claiming a `daily_first_win` reward increases `currency` by the
   configured amount exactly once; a second claim the same day is rejected
   (SC covers earn correctness).
3. Purchasing a pack below its price is rejected with no balance change
   (SC-003).
4. Purchasing an affordable pack debits exactly the pack price and returns a
   result with `card_count` entries, at least one Rare-or-better (FR-008).
5. Feeding the same result twice (simulating a player who already owns
   every card in it) produces `dust_awarded > 0` and no new `owned_cards`
   rows for the already-maxed cards (FR-012, SC-006).
6. Crafting a specific card with sufficient dust succeeds and debits the
   exact per-rarity cost (SC-007); crafting with insufficient dust is
   rejected.

Any assertion failure prints which step and expected-vs-actual values, per
the existing dev-hook convention.

## Scenario B — Manual playtest of the Shop and reveal animation

The animation quality/feel (SC-003's "no visible stutter") and UI reachability
(SC-005) are not machine-checkable — verify by hand:

1. Press F5 to launch the game and log in.
2. From the main menu, confirm the current currency balance is visible.
3. Navigate to the Shop in 2 or fewer actions from the main menu (SC-005).
4. With enough currency, purchase a pack; confirm the balance updates
   immediately (no restart needed — SC-002).
5. Open the pack: watch the sequential reveal play smoothly for all 5 cards.
6. Mid-reveal, trigger the skip/speed-up input; confirm all remaining cards
   still appear (no card silently dropped — FR-010) before the screen
   dismisses.
7. Open the deck builder / card list and confirm every newly-revealed card
   is now present in the collection.
8. Trigger a duplicate pull (open packs until one repeats an owned
   Legendary, or use the `--shop-test` hook's seeded state) and confirm the
   dust counter increases instead of a phantom duplicate appearing in the
   collection.
9. Spend dust to craft a specific missing card from the shop/collection
   screen and confirm it appears owned afterward.

## Out of scope for this quickstart

Real-money currency purchase (User Story 5) has no validation steps here —
it is not implemented by this feature (see plan.md Summary).
