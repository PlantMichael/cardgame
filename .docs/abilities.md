# Abilities System

## On-play decisions live in the core

`Abilities._fire_on_play_decisions()` (called from `fire_on_play`) requests the
decision-bearing on-play effects in a fixed order: transform choice, on-play
damage, challenge, Yeti challenge, Rampage (`challenge_all`, automatic),
pilot, challenge-with-win-buff, swap health, devour. They used to run in four
controllers; see `.docs/game-logic.md` for the choice model. Note
`on_play_damage_high_attack` (Heavy Bounty Hunter) is *not* plain on-play damage.

## Shared operations

Effects do not mutate creatures directly; they call the shared operation, which
owns the reaction chain that has to follow. Adding an effect means calling one
of these, not copying a four-line sequence:

| Operation | Use for |
|---|---|
| `GameState.gain_max_health(target, n)` | +n to both current and maximum health (a buff) |
| `GameState.restore_health(target, n)` | heal up to the existing maximum (no max change) |
| `GameState.apply_on_play_damage(target, n, source_id)` | on-play / triggered damage, with amplification |
| `GameState.sanguine_recipients(actor_id, donor)` | legal Drain recipients |

`gain_max_health()` runs Crypt Hunger's replacement, Apothecary's bonus and the
max-health transform check. Ten sites in `abilities.gd` used to open-code that
sequence and all but one omitted the transform check, so a creature buffed over
its threshold by an ability did not transform while the same creature buffed by
Supply Drop did. `restore_health()` deliberately skips the transform check —
`_try_health_transform()` triggers off `max_health`, which a pure heal cannot
raise.

## Effect resolution order

`GameState.PENDING_QUEUES` is the authoritative order queued effects resolve
in, and `has_pending()` drives "repeat until stable". Local play, the
multiplayer host and the headless search all iterate that list rather than
each keeping its own sequence — they previously disagreed (local took tank
shots before rummages, the search did the reverse) and multiplayer never
drained `pending_tank_specialist_buffs` at all.

Deaths are resolved in **groups**: `_remove_dead_minions()` collects everything
lethal, removes the whole group, and only then fires their death triggers, so
simultaneous lethal damage is genuinely simultaneous and no trigger can rescue
a creature out of the group. Order within a group is the active player's board
first, then the opponent's, left to right. A consequence worth remembering: a
replacement creature's recorded slot may no longer exist when its trigger runs,
which is why `_safe_board_index()` clamps it.

## Targeted on-play effects

`on_play_restore_health`, `on_play_buff_other_friendly` and
`on_play_damage_high_attack` open a `GameState` pending choice instead of
resolving against a target the caller picked. Legality is decided once in the
rules core, so human play, the AI, the multiplayer host/guest and the search
all answer the same question and resolve through the same shared operation.
No legal target means no prompt and no effect.

## Reinforce

Reinforce carries its remaining returns in **one** ability string:
`reinforce` is one return, `reinforce_4` is four (Commander Maurice). Use
`Abilities.reinforce_uses_of(minion)` rather than `has_ability(REINFORCE)`,
which misses the counted form.

It is deliberately not N repeated `reinforce` entries: a single death would
fire the handler once per entry (several copies from one death) and each copy
would inherit the full printed count again, so the budget would never run
down. A replacement is built from the card definition and then has its
Reinforce stripped and the *reduced* count put back.

Corporal Garrick's save is its own effect, not a Reinforce use, so a creature
it saves keeps whatever returns it still had.

## Resolved rules decisions

**Crypt Hunger (Delos, `cr_019`) — "when this creature gains health, lose it
and draw a card."** The gain is reverted in whatever stat was raised, then a
card is drawn. `GameState._try_heal_to_draw(target, gained, max_gained)` takes
both deltas: a +N/+N buff (Apothecary, Supply Drop, tank specialist) passes
both so the creature ends where it started, while a **pure heal** — restoring
damage, capped at the existing maximum — passes `0` for `max_gained`. Passing
the current-health gain for both is what used to shrink the creature: a
3-max/1-current Delos healed for 2 came out 1-max/1-current.

**Damage amplification scope.** `_get_enemy_damage_amp(source)` is the bonus a
player's own board adds to damage **they** deal to the enemy. It applies to
on-play damage (`apply_on_play_damage`), combat (`attack`/`apply_challenge`),
and on-play area damage that hits only enemy creatures. It is **not** applied
to the two deathrattle effects that damage both boards symmetrically
(`DEATHRATTLE_AOE_TRANSFORM`, deathrattle-damage-all-except-mech): there is no
single amplifier that applies to both halves. Amplifying only the enemy half is
defensible but has not been decided — flagged, not silently chosen.

**Drain / Sanguine recipients (`cr_str_003`).** "Take 2 health from a creature
you control and give it to **another** creature you control" — the donor is not
a legal recipient. Enforced centrally by `GameState.sanguine_recipients()`. The
simulation already excluded the donor; local play and multiplayer did not, so
the card could be played as a no-op that healed the creature it had just
damaged.

**Aura lifetime.** Lasting contributions are bound to a source that must still
qualify. Anything that strips or replaces a creature's abilities — silence
(`apply_null`), transformation — calls
`GameState.reconcile_lasting_effects(owner_id)`, which withdraws grants whose
source is gone. Only what the aura actually granted is withdrawn:
`_apply_growvin_aura_to_mech()` records a grant only when it really added the
ability, so a creature that owns that ability in its own right keeps it.

Abilities are plain strings stored on `CardData.abilities` and copied to `Minion.abilities`.

## Canonical Constants (abilities.gd Autoload)

| Constant | String Key | Description |
|---|---|---|
| `GUARDIAN` | `"guardian"` | Must be attacked first (Taunt) |
| `RUSH` | `"rush"` | Can attack immediately (Charge) |
| `REINFORCE` | `"reinforce"` | Has a death-trigger effect |
| `YETI` | `"yeti"` | Tag; used as a search target by `DEATHRATTLE_DRAW_YETI` |
| `DEATHRATTLE_DRAW_YETI` | `"deathrattle_draw_yeti"` | On death: search deck for a random Yeti card and draw it |
| `CHALLENGE` | `"challenge"` | On play: immediately fight a chosen enemy minion (mini-combat) |
| `RECON` | `"recon"` | On play: draw a card |
| `TANK` | `"tank"` | On play: deal 1 damage to the enemy hero; on reinforce death-trigger: deal 1 damage to any target |
| `DEATHRATTLE_DRAW_TANK` | `"deathrattle_draw_tank"` | On death: search deck for a random Tank card and draw it |
| `RUMMAGE` | `"rummage"` | On play: retrieve a card from your graveyard costing less than this card |
| `RUMMAGE_ON_DEATH` | `"rummage_on_death"` | On death: retrieve a card from your graveyard costing less than this card |
| `RUMMAGE_MECH_ON_DEATH` | `"rummage_mech_on_death"` | On death: retrieve any Mech card from your graveyard |
| `RUMMAGE_SPELL` | `"rummage_spell"` | On play: retrieve any stratagem from your graveyard |
| `PILOT` | `"pilot_A_H"` (e.g. `"pilot_2_3"`) | On play: buff a friendly Mech +A/+H and merge into it |
| `MECH` | `"mech"` | Tag; valid target for PILOT ability |
| `ON_PLAY_DAMAGE` | `"on_play_damage_N"` (e.g. `"on_play_damage_3"`) | On play: deal N damage to a target creature |
| `ON_PLAY_YETI_CHALLENGE` | `"on_play_yeti_challenge"` | On play: a friendly Yeti immediately fights a chosen enemy minion |
| `CLOAKED` | `"cloaked"` | Cannot be targeted by enemy stratagems or attacks until it attacks; friendly stratagems can still target cloaked creatures |
| `TACTICAL_OFFICER` | `"tactical_officer"` | Passive: whenever a friendly creature reinforces, give the reinforce copy +1 attack |
| `TRANSFORM` | `"transform_N"` (e.g. `"transform_3"`) | After attacking N times, transforms into the card specified by `CardData.transform_into`; retains damage taken |
| `TRANSFORM_AT_MAX_HEALTH` | `"transform_at_max_health_N"` (e.g. `"transform_at_max_health_5"`) | Transforms when `max_health` reaches N *or more* (checked via `GameState._try_health_transform`, called from every effect that raises max_health — buff stratagems, Pilot, Devour, Yeti challenge-win buff, healing a topped-out minion, Metamorphosis); uses `CardData.transform_into`; retains damage taken |
| `DEATHRATTLE_RETURN_STRATAGEM` | `"deathrattle_return_stratagem"` | On death: return a stratagem from your graveyard to your hand |
| `DEATHRATTLE_DRAW_CARD` | `"deathrattle_draw_card"` | On death: draw a card from your deck |
| `RUMMAGE_BUFF` | `"rummage_buff"` | Passive: whenever the owner completes a rummage, this minion gains +0/+1 health |
| `RUMMAGE_DRAW` | `"rummage_draw"` | Passive: whenever the owner completes a rummage, draw a card |
| `SPRITE` | `"sprite"` | Tribe tag |
| `NULL` | `"null"` | On play: silence a chosen creature (clear all its abilities) |
| `COMBAT_IMMUNE` | `"combat_immune"` | Cannot take damage from combat (attacks and challenge); can still be targeted by stratagems. Opposite of Cloaked. |
| `ON_PLAY_TRANSFORM_CHOICE` | `"on_play_transform_choice"` | On play: show a picker to choose one form from `CardData.transform_choices`; the minion immediately transforms into the chosen card |
| `ON_PLAY_RUMMAGE_BUFF` | `"on_play_rummage_buff"` | On play: gain +1/+1 for each time this card has been rummaged (tracked by `CardData.rummage_count`) |
| `ATTACK_BUFF_FRIENDLY_HEALTH` | `"attack_buff_friendly_health"` | When this attacks: give a random friendly creature +1 current and max health |
| `MIRROR_TRANSFORM` | `"mirror_transform"` | When a friendly creature transforms: transform too. If `CardData.transform_into` is set, transforms into that specific card; otherwise copies the triggering creature's new form |
| `ON_PLAY_BUFF_FRIENDLY_HEALTH` | `"on_play_buff_friendly_health"` | On play: queue a prompt for the player to choose a friendly minion to give +1 max health |
| `WHEN_ATTACKED_BUFF_FRIENDLY` | `"when_attacked_buff_friendly"` | When this is attacked: give all friendly minions +1 max health (displayed as "Lifegift") |
| `APOTHECARY` | `"apothecary"` | Passive: whenever a friendly creature gains health, it gains an extra +1 max health |
| `ON_YETI_CHALLENGE_BUFF` | `"on_yeti_challenge_buff"` | When a friendly Yeti completes a challenge: this minion gains +1/+1 (displayed as "Yeti Bond") |
| `ON_YETI_DEATH_CHALLENGE` | `"on_yeti_death_challenge"` | When a friendly Yeti dies: queue an Overwatch challenge prompt |
| `ON_FRIENDLY_YETI_DEATH_BUFF` | `"on_friendly_yeti_death_buff"` | When a friendly Yeti dies: this minion gains +2 max health (displayed as "Yeti Bond") |
| `ON_PLAY_BUFF_FRIENDLY_YETI_ATK` | `"on_play_buff_friendly_yeti_attack"` | On play: give all friendly Yetis +2 attack |
| `ON_PLAY_HEAL_FRIENDLY_YETIS` | `"on_play_heal_friendly_yetis"` | On play: restore 2 health to each *other* friendly Yeti (Snowdrift Matriarch). One untargeted group: recipients are snapshotted, each goes through `restore_health()` (capped at max, no event for a full-health Yeti). A Reinforce return is a summon, not a play, so it does not fire |
| `ON_PLAY_BUFF_IF_YETI` | `"on_play_buff_if_yeti"` | On play: if you control a friendly Yeti, this minion gains +2/+1 |
| `DEATHRATTLE_AOE_TRANSFORM` | `"deathrattle_aoe_transform"` | On death: deal 1 damage to all creatures on both boards, then place the card specified by `CardData.transform_into` on the owner's board at the same index |
| `STINKPILE_PASSIVE` | `"stinkpile_passive"` | Passive ("Salvage"): when the owner completes a rummage, instead of adding the card to hand, immediately play it to the board for free (if board space available) |
| `ON_PILOTED_GAIN_RUSH` | `"on_piloted_gain_rush"` | When a pilot merges into this Mech: gain Rush (can attack immediately); displayed as "Boost: Rush" |
| `ON_PILOTED_GAIN_CLOAKED` | `"on_piloted_gain_cloaked"` | When a pilot merges into this Mech: gain Cloaked; displayed as "Boost: Cloaked" |
| `EJECT_PILOT_ON_DEATH` | `"eject_pilot_on_death"` | On death: reverse the pilot merge — mech stats restore and pilot returns to board (or hand if full) |
| `RUMMAGE_AND_PLAY` | `"rummage_and_play"` | On play: retrieve a creature from your graveyard costing less than this card and immediately play it to the board (bypassing hand) |
| `CHALLENGE_ALL` | `"challenge_all"` | On play: challenge every enemy creature left-to-right in sequence; each challenge resolves fully (including deathrattles) before the next; displayed as "Rampage" |
| `ON_PLAY_CHALLENGE_WIN_BUFF` | `"on_play_challenge_win_buff"` | On play: fight a chosen enemy minion; if this minion wins (target dies and this survives), gain +1/+1 |
| `ON_PLAY_AOE_ENEMY` | `"on_play_aoe_enemy_N"` (e.g. `"on_play_aoe_enemy_2"`) | On play: deal N damage to all enemy minions |
| `ON_REINFORCE_DAMAGE` | `"on_reinforce_damage_N"` (e.g. `"on_reinforce_damage_2"`) | On reinforce death trigger: deal N damage to a chosen target |
| `ON_ANY_REINFORCE_SHOT` | `"on_any_reinforce_shot_N"` (e.g. `"on_any_reinforce_shot_1"`) | Passive: whenever any friendly creature reinforces, deal N damage to a chosen target |
| `PILOT_GIVES_RUSH` | `"pilot_gives_rush"` | When this pilot merges into a Mech: grant the Mech Rush |
| `PILOT_GIVES_CLOAKED` | `"pilot_gives_cloaked"` | When this pilot merges into a Mech: grant the Mech Cloaked |
| `PILOT_GIVES_GUARDIAN` | `"pilot_gives_guardian"` | When this pilot merges into a Mech: grant the Mech Guardian |
| `ON_PILOTED_STAT_BOOST` | `"on_piloted_stat_boost"` | When a pilot merges into this Mech: gain +1/+1 in addition to the pilot's base stats |
| `ON_PLAY_PILOT_MECH` | `"on_play_pilot_mech"` | On play: immediately pilot a chosen friendly Mech (self-removes from board and merges) |
| `HEAL_TO_DRAW` | `"heal_to_draw"` | When this creature gains health: remove that health gain and draw a card instead (displayed as "Crypt Hunger") |
| `DUAL_STRIKE` | `"dual_strike"` | Attacks twice per combat — both against the same minion target (each hit triggers on_attack/on_defend) and doubles hero damage when attacking face |
| `VOIDTOUCH` | `"voidtouch"` | After dealing combat or challenge damage, force the target's health to ≤ 0 (instant kill, bypasses remaining health) |
| `SHIELDED` | `"shielded_N"` (e.g. `"shielded_2"`) | Reduces incoming damage by N in every combat interaction (attack, challenge, retaliation); stacks from `_get_shield_value()` |
| `AMBUSH` | `"ambush"` | Cannot be targeted by enemy stratagems or attacks until it attacks first; stripped on first attack |
| `ENEMY_DAMAGE_AMP` | `"enemy_damage_amp_N"` (e.g. `"enemy_damage_amp_1"`) | Passive aura: all damage dealt by the owner to enemy creatures (attacks, challenges, on-play damage, stratagem AOE) is increased by N; stacks across all friendly minions with this ability |
| `ON_PLAY_SWAP_FRIENDLY_HEALTH` | `"on_play_swap_friendly_health"` | On play: swap the current health values of two chosen friendly minions (each capped at the other's max_health) |
| `ON_PLAY_DEVOUR_FRIENDLY` | `"on_play_devour_friendly"` | On play: destroy a chosen friendly minion and gain `target.current_health * 2` max and current health |
| `DEATHRATTLE_RUMMAGE_CREATURE` | `"deathrattle_rummage_creature"` | On death: rummage a non-legendary creature from your graveyard (any cost; no discount) |
| `RUMMAGE_EQUAL_COST` | `"rummage_equal_cost"` | Passive: while this minion is on the board, rummages may also retrieve cards of equal cost (normally only strictly cheaper cards qualify) |
| `ON_PLAY_BUFF_ALL_FRIENDLY_HEALTH` | `"on_play_buff_all_friendly_health"` | On play: give all friendly minions (including itself) +0/+1 |
| `ON_PLAY_VOIDTOUCH_IF_RUMMAGED` | `"on_play_voidtouch_if_rummaged"` | On play: if this card's `rummage_count` is > 0 (i.e. it was retrieved by a rummage before being played), permanently gain Voidtouch |
| `ON_PLAY_RECON_IF_FEWER_CARDS` | `"on_play_recon_if_fewer_cards"` | On play: draw a card if the owner now holds fewer cards than the opponent. The hands are compared *after* this card has left its owner's, which is where it is when on-play effects fire. Junk Blockade (`b_010`) only; covered by `CoreTests._test_conditional_recon` |
| `FEAST_ATTENDANT` | `"feast_attendant"` | At the end of the owner's turn: give board-adjacent friendly creatures (index ±1) +0/+1 max and current health (displayed as "Feast") |
| `ON_PLAY_DEVOUR_ALL` | `"on_play_devour_all"` | On play: destroy every other creature on both boards (fires death triggers), then gain the sum of their attack and health |
| `REJUVENATE` | `"rejuvenate_N"` (e.g. `"rejuvenate_1"`) | At end of owner's turn, this minion heals N health (up to max_health); parsed via `is_rejuvenate` / `get_rejuvenate_value` |
| `MONSTROSITY` | `"monstrosity"` | Tribe tag; targeted by `BROODTENDER_AURA` |
| `BROODTENDER_AURA` | `"broodtender_aura"` | Aura: while on board, all friendly monstrosities have Rejuvenate 2 |
| `GROWVIN_AURA` | `"growvin_aura"` | Aura (displayed as "Architect"): while on board, all friendly mechs gain Cloaked, Rejuvenate 1, and Shielded 1; applied on play and when new mechs enter; removed when Growvin dies |
| `ON_FRIENDLY_TRANSFORM_BUFF_SELF` | `"on_friendly_transform_buff_self"` | When a friendly creature transforms: this minion gains +1/+1 (displayed as "Metamorphosis"); fires via `_try_mirror_transform` hook |
| `ON_FRIENDLY_MECH_DEATH_BUFF` | `"on_friendly_mech_death_buff"` | When a friendly Mech dies: this minion gains +1/+1 (displayed as "Mech Bond") |
| `ON_FRIENDLY_TRANSFORM_GIVE_AMBUSH` | `"on_friendly_transform_give_ambush"` | When a friendly creature transforms: give it Ambush |
| `ON_FRIENDLY_PILOT_DRAW` | `"on_friendly_pilot_draw"` | When a friendly Pilot merges into a Mech: draw a card (displayed as "Pilot Bond") |
| `ON_YETI_CHALLENGE_ATTACK` | `"on_yeti_challenge_attack"` | When a friendly Yeti challenges: this minion attacks the same target |
| `ON_FRIENDLY_TANK_DEATH_BUFF_TANK` | `"on_friendly_tank_death_buff_tank"` | When a friendly Tank dies: give a friendly Tank +1/+2 |
| `ON_FRIENDLY_DEATH_REINFORCE` | `"on_friendly_death_reinforce"` | Passive (displayed as "Rally"): the first friendly creature to die each turn is reinforced (a copy returns at its board index). Tracked by `GameState.death_reinforce_used`, cleared every turn boundary. The holder is already off the board when its own death resolves, so it can't save itself |
| `ON_PLAY_HEALTH_PER_FRIENDLY` | `"on_play_health_per_friendly"` | On play: gain +0/+1 for each *other* friendly creature on the board |
| `DEATHRATTLE_TRANSFORM` | `"deathrattle_transform"` | On death: place the card named by `CardData.transform_into` on the owner's board at the same index (no damage; the plain version of `DEATHRATTLE_AOE_TRANSFORM`) |
| `END_TURN_DRAIN_RANDOM_ENEMY` | `"end_turn_drain_random_enemy"` | At the end of the owner's turn (displayed as "Siphon"): deal 1 damage to a random enemy creature and gain +0/+1. No-op when the enemy board is empty |
| `STATS_FROM_GRAVEYARD` | `"stats_from_graveyard"` | On play (displayed as "Scrapbuilt"): set attack and health to the owner's graveyard size, floored at 1. Set once on play, not continuously |
| `RUMMAGE_BUFF_CREATURE` | `"rummage_buff_creature"` | On play (displayed as "Refurbish"): rummage; if the retrieved card is a creature it permanently gains +1/+1 (queued as `"buff_creature": true` on the pending rummage) |
| `END_TURN_HEAL_MECHS` | `"end_turn_heal_mechs"` | At the end of the owner's turn (displayed as "Repair Bay"): heal all friendly Mechs 2. Stacks across copies |
| `END_TURN_YETI_DISCOUNT` | `"end_turn_yeti_discount"` | At the end of the owner's turn (displayed as "Provision"): every Yeti in hand gets `cost_modifier -= 1`. `effective_cost()` floors at 1 |
| `TWO_SLOT` | `"two_slot"` | Passive (displayed as "Colossal"): occupies 2 of the 7 board slots. Enforced by `PlayerState.slots_for`/`has_room_for`/`can_fit_card`; `board.gd` renders its cell double-width |
| `TRAMPLE` | `"trample"` | Damage beyond the defending minion's pre-hit health is dealt to the enemy hero. Applied in `GameState._strike_minion`, so it covers attacks, the Dual Strike second hit, challenges, and Yeti challenge follow-ups |
| `ATTACK_RUMMAGE` | `"attack_rummage"` | When this minion attacks: rummage a card from your graveyard costing less than this card (queued via `fire_on_attack`) |
| `ON_PLAY_TRANSFORM` | `"on_play_transform"` | On play: immediately transform into the card named by `CardData.transform_into`, with no player choice (displayed as "On Play: Morph"); the unprompted counterpart to `ON_PLAY_TRANSFORM_CHOICE` |
| `DEATHRATTLE_DAMAGE_ALL_EXCEPT_MECH` | `"deathrattle_damage_all_except_mech_N"` (e.g. `"deathrattle_damage_all_except_mech_3"`) | On death: deal N damage to every creature on **both** boards except those with the `MECH` tag |

The `Abilities` autoload holds all constants and their display metadata in `DEFINITIONS`. PILOT, ON_PLAY_DAMAGE, ON_PLAY_AOE_ENEMY, ON_REINFORCE_DAMAGE, ON_ANY_REINFORCE_SHOT, TRANSFORM, TRANSFORM_AT_MAX_HEALTH, SHIELDED, and ENEMY_DAMAGE_AMP are handled separately via helper functions (e.g. `is_pilot`, `is_on_play_damage`, `is_shielded`, `get_shield_value`, `is_enemy_damage_amp`, `get_enemy_damage_amp_value`) because their display strings or values are dynamic.

## Tribes vs Keywords

Abilities fall into two display categories in `card.gd`:

- **Keywords** — abilities with active effects; shown via the card's `description` text field.
- **Tribes** — type tags; listed in `Abilities.TRIBES` (`YETI`, `MECH`, `TANK`, `SPRITE`, `MONSTROSITY`). Rendered as a badge in the **bottom right** of the StatsRow. Other cards reference tribes (e.g. Pilot targets Mechs, Yeti Rancher draws Yetis, Engineer draws Tanks). Note: `TANK` also has active effects (on-play hero damage, reinforce death shot) in addition to being a tribe.

To add a new tribe: add its constant to `TRIBES` in `abilities.gd`.

## Adding a New Ability

1. Add a constant and entry in `DEFINITIONS` in `abilities.gd`
2. Handle it in `trigger_death()` if it has a death effect
3. If the AI needs to factor it into decisions, add scoring/target-pick logic to `AIHeuristics` and/or on-play/pending-resolution handling to `HeadlessTurn` (see `.docs/ai.md`) — not directly in `ai_controller.gd`, so both the greedy policy and the MCTS search see it consistently
