# Project Status

## What's Working

- Card data system loading from per-color JSON files
- Board scene with all zones (hand, board, heroes, center bar)
- Drag and drop card playing from hand to board
- Stratagem targeting (drag to any creature or hero)
- Mana system (1 crystal per turn, refreshes each turn)
- Draw card each turn
- End turn flow
- Card preview on hover (right side of screen)
- Board zone highlights when dragging cards
- Target highlights when dragging stratagems
- Attack target highlights (purple) when attacker selected
- Taunt enforcement
- Gold glow on attackable minions
- Color theming on cards (5 faction colors)
- Keywords shown in card description text
- Tribe tags (Yeti, Mech) displayed as a badge in the bottom-right of the StatsRow
- Challenge ability (on-play mini-combat: pick an enemy to fight)
- Yeti tag and deathrattle draw (teal faction mechanics, Yeti Rancher)
- Tank ability (on-play hero damage + reinforce death-trigger shot)
- Pilot/Mech system (pilot merges into a Mech, buffing its stats; F4lcon gains Rush when piloted via `on_piloted_gain_rush`)
- Eject pilot mechanic (`apply_eject_pilot`): reverses a pilot merge, restoring mech stats and returning pilot to the field; used by Panic Button stratagem
- Rummage system (retrieve cards from graveyard; on-play, on-death, and spell variants)
- Cloaked keyword (cannot be targeted by any stratagem from either player)
- Tactical Officer (passive: reinforce copies get +1 attack per Officer on board)
- Drone Pilot deathrattle (on death: return a stratagem from graveyard to hand)
- Commanding Shout (buff_all_friendly_attack: +1 attack to all friendly creatures, no target)
- Mortar (deal_damage 4 to target creature)
- AI controller (tactical: plays cards, trades minions, goes face, checks lethal, handles Challenge, Pilot, on-play damage, Cloaked filtering, Commanding Shout)
- Win/loss overlay (modal with "You Win!" / "You Lose!" and Play Again button)
- Transform system: attack-count transform (`transform_N`) and max-health-threshold transform (`transform_at_max_health_N`); Haven Guard → Haven Warden (5/4 Rush at 5 max health); threshold fires on all health-gain paths (Moonchild, Blood Transfusion, Sanguine, Apothecary, Pilot, stratagem buffs)
- Crimson faction: Crypt Gangrel deathrattle (AOE 1 damage → Fleshripper); Blood Transfusion (steal 2 health from enemy creature, give to friendly); Sanguine (move 2 health from one friendly to another)
- Cascade death handling: `_remove_dead_minions` loops until no more deaths, so AOE deathrattles chain correctly
- Faction selection buttons uniform width via `SIZE_EXPAND_FILL` in a fixed-width HBoxContainer
- Main menu with Play and Deck Builder buttons
- Deck select screen (choose player deck, then opponent starter deck)
- Deck builder UI: hub listing saved decks, faction picker, collection editor with search, filter buttons (All / Faction / Generic), save to disk
- Generic card color (`CardData.CardColor.GENERIC`): cards usable by all factions; appear in a separate section after faction cards in the collection browser
- Inyuites (Teal) starter deck: 2× every non-legendary teal card + 1× Abominus + 1× each of the 5 generic cards = 40
- `challenge_all` ability (Rampage): on play, challenges every enemy creature left-to-right; each challenge resolves fully before the next
- `rummage_and_play` ability: retrieve a creature from graveyard and immediately play it to board (Greedy Junkling)
- `force_challenge` stratagem effect: prompts a Yeti to challenge; if `effect_value > 0` and the Yeti kills the target, it gains that many +atk/+hp (Icewhip)
- `deal_damage_all_enemy` stratagem effect: deals damage to every enemy minion with no target prompt (Noxious Bombardment)
- Rummage vs Fetch distinction: black rummage mechanics discount retrieved cards by 1 mana; orange/green fetch mechanics (`rummage_mech_on_death`, `deathrattle_return_stratagem`) do not
- Stinkpile on-play sequencing: rummaged cards' on-play effects and all pending queues resolve between each rummage prompt
- `on_play_aoe_enemy_N` ability: on-play creature ability that deals N damage to all enemy minions (distinct from the `deal_damage_all_enemy` stratagem effect)
- `on_reinforce_damage_N` ability: on reinforce death trigger, deal N damage to a chosen target; prompts via `pending_on_reinforce_damages`
- `on_any_reinforce_shot_N` ability: passive watcher — whenever any friendly reinforces, deal N damage to a chosen target
- `on_play_challenge_win_buff` ability: on play, fight a chosen enemy; if this minion wins (target dies, this survives), gain +1/+1
- Creature-vs-creature attack animation (`animate_creature_attack`) and challenge animation (`animate_creature_challenge`): attacker slides to target and back (~0.33s), triggers a `damage_flash` on the target
- `dual_strike` ability: attacks twice per combat; doubles face damage
- `voidtouch` ability: forces target health ≤ 0 after dealing damage (bypasses remaining health)
- `shielded_N` parameterized ability: reduces incoming damage by N in all combat interactions; helper functions `is_shielded` / `get_shield_value` in abilities.gd
- `ambush` ability: immune to enemy attacks and stratagem targeting until it attacks first; stripped on first attack
- `enemy_damage_amp_N` parameterized ability: passive aura adding +N to all owner damage vs enemy creatures; stacks across board
- `on_play_swap_friendly_health` ability: swap current health of two chosen friendlies (Blood Merchant)
- `on_play_devour_friendly` ability: destroy a friendly, gain half its health rounded up (Crypt Lurker)
- `deathrattle_rummage_creature` ability: on death, rummage a non-legendary creature (Stinkherder)
- `rummage_equal_cost` ability: passive — while on board, rummages may retrieve equal-cost cards (Clutterpunk)
- AI simulation mode: headless AI-vs-AI loop accessible from main menu; tracks win rates per faction; runs ~hundreds of games per second with no UI overhead
- `rejuvenate_N` ability: at end of owner's turn, heals N health per minion that has it; handled via `_apply_rejuvenate` in `end_turn()`
- `broodtender_aura` ability: while on board, all friendly monstrosities gain Rejuvenate 2; applied on-play and on new monstrosity entry; removed on death
- `growvin_aura` ability (Growvin the Architect): while on board, all friendly mechs gain Cloaked, Rejuvenate 1, and Shielded 1; tracked via `growvin_granted`; handles two-Growvin edge case
- `on_friendly_transform_buff_self` ability (Metamorphosis): when any friendly creature transforms, gain +1/+1; fires via `_try_mirror_transform` hook (covers all transform types)
- Cloaked fix: cloaked now only blocks *enemy* stratagem and attack targeting; friendly stratagems can target cloaked creatures (fixes self-buff aura interaction)
- Deck builder UI refresh: collection uses real `Card.tscn` instances at 0.5 scale; hovering a card shows a full-size preview + keyword tooltip blocks in a fixed right panel

## TODO / Not Working Yet

- Dead minions not visually confirmed working (need to test with AI)
- Card art (images not added to cards yet)
- Networking (Nakama — planned after AI is solid)
- Sound

## Next Steps

1. Test that dead minions are properly removed after combat
2. Test the full AI turn loop
3. Add card art support
4. Move to Nakama networking
