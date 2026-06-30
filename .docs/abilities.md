# Abilities System

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
| `TRANSFORM_AT_MAX_HEALTH` | `"transform_at_max_health_N"` (e.g. `"transform_at_max_health_5"`) | Transforms when `max_health` reaches N (triggered by buff stratagems or Pilot); uses `CardData.transform_into`; retains damage taken |
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
| `ON_PLAY_DEVOUR_FRIENDLY` | `"on_play_devour_friendly"` | On play: destroy a chosen friendly minion and gain `ceil(target.current_health / 2)` max and current health |
| `DEATHRATTLE_RUMMAGE_CREATURE` | `"deathrattle_rummage_creature"` | On death: rummage a non-legendary creature from your graveyard (any cost; no discount) |
| `RUMMAGE_EQUAL_COST` | `"rummage_equal_cost"` | Passive: while this minion is on the board, rummages may also retrieve cards of equal cost (normally only strictly cheaper cards qualify) |
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

The `Abilities` autoload holds all constants and their display metadata in `DEFINITIONS`. PILOT, ON_PLAY_DAMAGE, ON_PLAY_AOE_ENEMY, ON_REINFORCE_DAMAGE, ON_ANY_REINFORCE_SHOT, TRANSFORM, TRANSFORM_AT_MAX_HEALTH, SHIELDED, and ENEMY_DAMAGE_AMP are handled separately via helper functions (e.g. `is_pilot`, `is_on_play_damage`, `is_shielded`, `get_shield_value`, `is_enemy_damage_amp`, `get_enemy_damage_amp_value`) because their display strings or values are dynamic.

## Tribes vs Keywords

Abilities fall into two display categories in `card.gd`:

- **Keywords** — abilities with active effects; shown via the card's `description` text field.
- **Tribes** — type tags; listed in `Abilities.TRIBES` (`YETI`, `MECH`, `TANK`, `SPRITE`, `MONSTROSITY`). Rendered as a badge in the **bottom right** of the StatsRow. Other cards reference tribes (e.g. Pilot targets Mechs, Yeti Rancher draws Yetis, Engineer draws Tanks). Note: `TANK` also has active effects (on-play hero damage, reinforce death shot) in addition to being a tribe.

To add a new tribe: add its constant to `TRIBES` in `abilities.gd`.

## Adding a New Ability

1. Add a constant and entry in `DEFINITIONS` in `abilities.gd`
2. Handle it in `trigger_death()` if it has a death effect
3. Handle it in `ai_controller.gd` if the AI needs to factor it into decisions
