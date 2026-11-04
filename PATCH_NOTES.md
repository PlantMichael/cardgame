# Patch 0.0.2: Opening choices and balance

Draft, not yet released.

Choose your advantage when going second, alongside buffs across Orange, Green and Teal and targeted nerfs.

## Going second: choose your opening bonus

In ranked matches against players or AI opponents, the player going second chooses one option **before the mulligan**:

| Option | Starting hand | Bonus |
|---|---|---|
| Coin | **4 cards + a Coin** | A **0-mana** card that grants **1 extra mana for the turn you play it**. You can save it for a later turn. |
| Extra card | **5 cards total** | One additional card from your deck, with no Coin or Recruit. |
| Recruit | **4 cards** | Start with a **1/1 Recruit** on your battlefield. It cannot attack on your first turn; it can attack on your second turn. |

The Coin is added to your hand after the mulligan, so it cannot be exchanged. Its mana bonus expires at the end of the turn; it does not permanently increase your mana.

## Balance changes

Stats below are **attack/health**.

### Orange — Gundari

| Card | Mana | Change |
|---|---:|---|
| Duster | 2 | Stats changed from **1/2 to 2/3**. |
| Sweeper | 2 | Stats changed from **2/1 to 3/2**. |
| Scrap Rummager | 1 | Stats changed from **1/2 to 1/3**. Still has Rush. |
| Morph Drones | 1 | Now has **Rush**, so it can attack the enemy player the turn it is played. Headshot is unchanged. |
| Carbon Mesh | 2 | Now gives **all friendly mechs Shielded 2** instead of one friendly mech Shielded 3. Still lasts until the end of your opponent's next turn. |
| Panic Button | **2 → 1** | Effect unchanged. |
| Junior Pilot | **2 → 1** | Still a 1/1 with Pilot 2/2. |
| Nanotech | **3 → 2** | Still gives +2/+2. |

### Green — Sapiens

| Card | Mana | Change |
|---|---:|---|
| Lone Operative | 1 | Stats changed from **1/1 to 2/1**. Still has Ambush. |
| Kevlar | 2 | Now gives **+0/+4** instead of +0/+3. |
| Supply Drop | **3 → 2** | Now gives **+3/+0** instead of +2/+2. |

### Teal — Mokotai

| Card | Mana | Change |
|---|---:|---|
| Snow Bank | **3 → 2** | Still gives +2/+2. |
| Icewhip | 2 | Give a Yeti you control **+2/+2, then make it Challenge**. The buff no longer depends on winning. |

### Black — Junk

| Card | Mana | Change |
|---|---:|---|
| StinkPile, Lord of Garbage | **9 → 8** | Attack **7 → 6**, health remains 5. On-play Rummage **3 → 2**; summon passive unchanged. |
| Rust Grenade | 9 | Its Rummage now selects a **non-legendary creature**. Still puts it on the battlefield after the wipe. |
| Decaying Junkling | 5 | On play: deal **1 damage to all creatures**, replacing 2 damage to enemies only. Includes itself. Printed stats remain 2/2. |

### Generic

| Card | Mana | Change |
|---|---:|---|
| Twin Fang | 3 | Stats changed from **3/2 to 2/2**. Retains Dualstrike. |

### Effect details

- Morph Drones with Rush can attack the player right away to trigger its Headshot (self-destruct and heal all friendly minions 2). It can still be held until it has a clear path to the enemy player.
- Carbon Mesh still needs at least one friendly mech on the battlefield.

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
