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
| `SAFEGUARD` | `"safeguard"` | Cannot be targeted by stratagems from either player |
| `TACTICAL_OFFICER` | `"tactical_officer"` | Passive: whenever a friendly creature reinforces, give the reinforce copy +1 attack |
| `TRANSFORM` | `"transform_N"` (e.g. `"transform_3"`) | After attacking N times, transforms into the card specified by `CardData.transform_into`; retains damage taken |
| `TRANSFORM_AT_MAX_HEALTH` | `"transform_at_max_health_N"` (e.g. `"transform_at_max_health_5"`) | Transforms when `max_health` reaches N (triggered by buff stratagems or Pilot); uses `CardData.transform_into`; retains damage taken |
| `DEATHRATTLE_RETURN_STRATAGEM` | `"deathrattle_return_stratagem"` | On death: return a stratagem from your graveyard to your hand |
| `DEATHRATTLE_DRAW_CARD` | `"deathrattle_draw_card"` | On death: draw a card from your deck |
| `RUMMAGE_BUFF` | `"rummage_buff"` | Passive: whenever the owner completes a rummage, this minion gains +0/+1 health |
| `RUMMAGE_DRAW` | `"rummage_draw"` | Passive: whenever the owner completes a rummage, draw a card |
| `SPRITE` | `"sprite"` | Tribe tag |
| `NULL` | `"null"` | On play: silence a chosen creature (clear all its abilities) |
| `COMBAT_IMMUNE` | `"combat_immune"` | Cannot take damage from combat (attacks and challenge); can still be targeted by stratagems. Opposite of Safeguard. |
| `ON_PLAY_TRANSFORM_CHOICE` | `"on_play_transform_choice"` | On play: show a picker to choose one form from `CardData.transform_choices`; the minion immediately transforms into the chosen card |
| `ON_PLAY_RUMMAGE_BUFF` | `"on_play_rummage_buff"` | On play: gain +1/+1 for each time this card has been rummaged (tracked by `CardData.rummage_count`) |
| `ATTACK_BUFF_FRIENDLY_HEALTH` | `"attack_buff_friendly_health"` | When this attacks: give a random friendly creature +1 current and max health |
| `MIRROR_TRANSFORM` | `"mirror_transform"` | When a friendly creature transforms: transform too. If `CardData.transform_into` is set, transforms into that specific card; otherwise copies the triggering creature's new form |
| `ON_PLAY_BUFF_FRIENDLY_HEALTH` | `"on_play_buff_friendly_health"` | On play: queue a prompt for the player to choose a friendly minion to give +1 max health |
| `WHEN_ATTACKED_BUFF_FRIENDLY` | `"when_attacked_buff_friendly"` | When this is attacked: give all friendly minions +1 max health (displayed as "Lifegift") |
| `APOTHECARY` | `"apothecary"` | Passive: whenever a friendly creature gains health, it gains an extra +1 max health |
| `COMBAT_IMMUNE` | `"combat_immune"` | Cannot take damage from combat (attacks and challenges); can still be targeted by stratagems (displayed as "Ethereal") |
| `ON_PLAY_TRANSFORM_CHOICE` | `"on_play_transform_choice"` | On play: show a picker to choose one form from `CardData.transform_choices`; the minion immediately transforms |
| `ON_YETI_CHALLENGE_BUFF` | `"on_yeti_challenge_buff"` | When a friendly Yeti completes a challenge: this minion gains +1/+1 (displayed as "Yeti Bond") |
| `ON_YETI_DEATH_CHALLENGE` | `"on_yeti_death_challenge"` | When a friendly Yeti dies: queue an Overwatch challenge prompt |
| `ON_FRIENDLY_YETI_DEATH_BUFF` | `"on_friendly_yeti_death_buff"` | When a friendly Yeti dies: this minion gains +2 max health (displayed as "Yeti Bond") |
| `ON_PLAY_BUFF_FRIENDLY_YETI_ATK` | `"on_play_buff_friendly_yeti_attack"` | On play: give all friendly Yetis +2 attack |
| `ON_PLAY_BUFF_IF_YETI` | `"on_play_buff_if_yeti"` | On play: if you control a friendly Yeti, this minion gains +2/+1 |
| `DEATHRATTLE_AOE_TRANSFORM` | `"deathrattle_aoe_transform"` | On death: deal 1 damage to all creatures on both boards, then place the card specified by `CardData.transform_into` on the owner's board at the same index |
| `STINKPILE_PASSIVE` | `"stinkpile_passive"` | Passive ("Salvage"): when the owner completes a rummage, instead of adding the card to hand, immediately play it to the board for free (if board space available) |

The `Abilities` autoload holds all constants and their display metadata in `DEFINITIONS`. PILOT and ON_PLAY_DAMAGE are handled separately via helper functions (`is_pilot`, `get_pilot_attack`, `get_pilot_health`, `is_on_play_damage`, `get_on_play_damage_value`) because their display strings are dynamic.

## Tribes vs Keywords

Abilities fall into two display categories in `card.gd`:

- **Keywords** — abilities with active effects; shown via the card's `description` text field.
- **Tribes** — type tags; listed in `Abilities.TRIBES` (`YETI`, `MECH`, `TANK`, `SPRITE`). Rendered as a badge in the **bottom right** of the StatsRow. Other cards reference tribes (e.g. Pilot targets Mechs, Yeti Rancher draws Yetis, Engineer draws Tanks). Note: `TANK` also has active effects (on-play hero damage, reinforce death shot) in addition to being a tribe.

To add a new tribe: add its constant to `TRIBES` in `abilities.gd`.

## Adding a New Ability

1. Add a constant and entry in `DEFINITIONS` in `abilities.gd`
2. Handle it in `trigger_death()` if it has a death effect
3. Handle it in `ai_controller.gd` if the AI needs to factor it into decisions
