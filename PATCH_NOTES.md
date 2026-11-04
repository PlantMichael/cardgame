# Patch 0.1.0: Opening Choices & Deck Builder Update

November 4, 2026

Choose your advantage when going second, build decks in a redesigned editor, and explore balance changes across four factions.

## Going Second: Choose Your Bonus

- The second player now chooses an opening bonus before mulligan in ranked matches against players or AI.
- Coin: Start with four cards. After mulligan, receive a 0-mana Coin that grants one extra mana for the turn you play it. You can save it for a later turn.
- Extra Card: Start with five cards total.
- Recruit: Start with four cards and a 1/1 Recruit on your battlefield. It cannot attack on your first turn, but can attack on your second.
- The Coin cannot be exchanged during mulligan. Its mana bonus expires at the end of the turn.

## Deck Builder Redesign

- Updated the saved-deck hub, faction selection, and editor to match the main menu.
- Larger collection cards with search and faction, card type, and mana filters.
- A deck sidebar showing copy counts, deck readiness, and a live mana curve.
- Card and keyword previews remain available when your deck is full.
- Improved keyboard controls and clearer feedback for invalid deck names.
- Renaming a saved deck saves a new copy, preserving the original.

## Shop

- The shop is disabled.

## Balance Changes — Gundari

- Duster: Stats increased from 1/2 → 2/3.
- Sweeper: Stats increased from 2/1 → 3/2.
- Scrap Rummager: Stats increased from 1/2 → 1/3. Retains Rush.
- Morph Drones: Gains Rush, allowing it to attack the enemy player immediately and activate Headshot.
- Carbon Mesh: Now gives all friendly Mechs Shielded 2, instead of giving one friendly Mech Shielded 3. Lasts until the end of your opponent’s next turn and requires a friendly Mech.
- Panic Button: Mana cost reduced from 2 → 1.
- Junior Pilot: Mana cost reduced from 2 → 1.
- Nanotech: Mana cost reduced from 3 → 2.

## Balance Changes — Sapiens

- Lone Operative: Stats increased from 1/1 → 2/1. Retains Ambush.
- Kevlar: Now grants +0/+4, increased from +0/+3.
- Supply Drop: Mana cost reduced from 3 → 2. Now grants +3/+0, replacing +2/+2.
- Requisitioner: Stats increased from 2/5 → 3/5. Its on-play health bonus is unchanged.

## Balance Changes — Mokotai

- Snow Bank: Mana cost reduced from 3 → 2.
- Icewhip: Now gives a friendly Yeti +2/+2 before making it Challenge. The buff no longer depends on winning.
- Ambusher Yeti: Renamed from the 4-mana Serene Yeti. Stats increased from 2/4 → 3/4. Retains Ambush. The 8-mana Serene Yeti is unchanged.

## Balance Changes — Junklings

- StinkPile, Lord of Garbage: Mana cost reduced from 9 → 8. Attack reduced from 7 → 6. On-play Rummage reduced from 3 → 2.
- Rust Grenade: Its Rummage now selects a non-legendary creature.
- Decaying Junkling: On play, now deals 1 damage to all creatures, including itself, replacing 2 damage to enemy creatures only.

## Balance Changes — Generic

- Twin Fang: Stats reduced from 3/2 → 2/2. Retains Dualstrike.

---

# Patch 0.0.1: Headshot card update

November 3, 2026

Ten new cards, a new keyword, and the removal of Crypt Chapel.

## New keyword: Headshot

After a creature directly attacks the enemy player, its Headshot effect activates.
Attacking a creature does not activate Headshot.

## New cards

Stats below are **attack/health**. Stratagems have no attack or health.

### Green — Sapiens

| Card | Mana | Stats | Rarity | Effect |
|---|---:|---|---|---|
| The Staller Mk3 | 6 | 1/11 | Legendary | Guardian. |
| Beam Rifle Soldier | 4 | 2/2 | Uncommon | Headshot: Deal 1 damage to a minion. |

### Black — Junklings

| Card | Mana | Stats | Rarity | Effect |
|---|---:|---|---|---|
| Splinterkin Behemoth | 7 | 5/7 | Epic | Headshot: Rummage. |
| Scrap Courier | 7 | 6/6 | Epic | When this creature takes damage, Rummage. |
| Rust Grenade | 9 | Stratagem | Uncommon | Destroy all minions, then Rummage a creature and put it on the battlefield. |
| Lord Knucklepunch | 4 | 7/1 | Legendary | Ambush. Headshot: Shuffle this creature into its owner's library. |
| Splinterkin Runt | 2 | 1/1 | Common | On play: If you have more than 10 cards in your graveyard, gain +0/+1 permanently. |

### Orange — Gundari

| Card | Mana | Stats | Rarity | Effect |
|---|---:|---|---|---|
| Morph Drones | 1 | 1/1 | Uncommon | Headshot: Self-destruct and heal all friendly minions 2. |
| Morphling Flyer | 3 | 1/1 | Uncommon | Pilot 3/3. On pilot: Heal the Mech to full. |

### Teal — Mokotai

| Card | Mana | Stats | Rarity | Effect |
|---|---:|---|---|---|
| Pa'tael | 3 | 1/1 | Legendary | Ethereal (immune to combat damage). Headshot: Challenge. |

### Effect details

- Rust Grenade uses the normal Rummage cost limit and can revive a creature destroyed by its board wipe.
- Scrap Courier also triggers when damage kills it. Fully prevented damage and destruction do not count as damage.
- Splinterkin Runt's earned health stays with that copy through death and Rummage for the rest of the match. Another qualifying play can add another +0/+1.
- Pa'tael's Headshot lets you choose an enemy creature to Challenge after attacking the player.
- Morphling Flyer heals the Mech after its Pilot bonuses are applied.

## Balance changes

- **Plated Soldier (Generic):** stats changed from **2/4 to 2/3**.
- **Frontier Medic (Generic):** stats changed from **2/3 to 1/3**.
- **Dump Scummer (Black):** stats changed from **3/5 to 2/4**.

## Bug fixes

- Fixed a bug where **Debris Hauler** incorrectly had **Cloaked**.

## Removed card

- **Crypt Chapel** has been removed from the card pool.

## Earlier cards included on this branch

These cards are also committed and included in the game on this branch. Avalanche was already present before this update.

| Card | Color | Mana | Stats | Rarity | Effect |
|---|---|---:|---|---|---|
| Avalanche | Teal | 3 | Stratagem | Common | Deal 3 damage to all creatures. |
| Whiteout | Teal | 5 | Stratagem | Common | Deal 2 damage to all enemy creatures. If any die from this damage, draw a random Yeti from your deck. |
| Snowdrift Matriarch | Teal | 5 | 3/6 | Common | On play: Restore 2 health to each other friendly Yeti. |
| Emergency Extraction | Generic | 2 | Stratagem | Common | Return a friendly creature to your hand. |

Whiteout, Snowdrift Matriarch, and Emergency Extraction remain excluded from the public website catalog, despite being included in the game.

## Playtest notes

- The ten new cards currently reuse existing faction artwork as placeholders.
- Rummage pickers show earned stats, discounts, and scaled card text consistently in local and network play.
- Fixed Abominus leaving a frozen card on screen and blocking input when it dies during its on-play challenges.
