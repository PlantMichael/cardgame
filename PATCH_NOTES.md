# Patch notes: Headshot card update

November 2, 2026 · `codex/headshot-cards`

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
