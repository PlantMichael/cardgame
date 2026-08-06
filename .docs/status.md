# Project Status

## What's Working

- Card data system loading from per-color JSON files
- Board scene with all zones (hand, board, heroes, center bar)
- Drag and drop card playing from hand to board
- Stratagem targeting (drag to any creature or hero)
- Mana system (1 crystal per turn, refreshes each turn)
- Draw card each turn
- Fatigue: drawing with an empty deck deals incrementing damage (1, then 2, then 3, ...) instead of a flat 1, for both the player and the AI; the game now also checks for a lethal fatigue draw immediately when a turn begins rather than only on the next unrelated action
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
- AI controller: per-decision heuristic-guided MCTS search (`MCTSEngine`, UCT selection/expansion/backprop over the current turn's atomic action sequence via `HeadlessTurn`, leaf-scored by `AIHeuristics.evaluate_state`), replacing the old one-ply greedy scorer; `AIController.ai_level` (1-10, `MCTSEngine.AI_LEVEL_CONFIG`) scales search budget, look-ahead depth, and an injected mistake-rate
- Ranked mode: main-menu "RANKED" flow vs. a random-faction AI opponent at the player's current ladder position; ladder state (21 bracketed tiers Orbital-Cosmic, then continuous-rating Legend tiers) is authoritative on the server (`Auth.rank_*`, updated via `Auth.report_ranked_result()` → `server/relay.js`'s `nextRankState()`), not a local client-side file; `RankedProgress` (`scripts/game/ranked_progress.gd`) is stateless display/AI-level-derivation math over whatever `Auth` reports
- Ranked tier floors: `rank_floor` (server-authoritative, `relay.js`'s `nextRankState()`/`tierFloor()`) tracks the highest tier "III" sub-rank ever reached; a loss can never drop the bracket below that floor (Hearthstone-style safety net), shown on the Ranked menu via `RankedProgress.get_floor_display_string()`
- Ranked game-over screen shows the rank change (e.g. "Lunar III -> Lunar II") once the server acks `report_ranked_result`, instead of only updating the Ranked menu on the next visit; Play Again now actually re-rolls the opponent and re-fetches the new AI level for the next ranked match (previously it silently reloaded the whole scene back to the main menu instead of chaining into the next match)
- Ranked matchmaking: START MATCH queues on the server (`relay.js`'s in-memory `rankedQueue`) for up to 10s looking for a human opponent within a widening rating band (`sweepRankedQueue`/`ratingBandAt`), showing a Searching screen with Cancel (`main.gd`'s `_begin_ranked_search` and friends); a match reuses the existing lobby/relay plumbing (`startRankedMatch` synthesizes a `lobbies` entry) so the game itself runs through the same `MpGameManager` host/guest flow as a casual lobby, just tagged `is_ranked`. A brief "Match Found" confirmation (opponent name + rating) shows before the game starts. No match in time falls back to the existing AI opponent with a random fake name (`RankedProgress.random_bot_name()`). PvP ranked results move the same bracket/Legend ladder as AI matches (unified rank), plus a separate invisible Elo (`players.rating`, `relay.js`'s `nextElo`) used only for pairing, updated via `report_ranked_result`'s new `opponent_rating` field. The opponent's name (real username or bot name) shows in a top-right nameplate (`Board.set_opponent_name`). Known gap: if a matched opponent disconnects between match-found and the game actually starting, the local player can be left stuck awaiting a deck exchange that will never arrive (same pre-existing limitation as the casual lobby flow, not something this pass fixed).
- Account system and multiplayer networking: login/register required at app startup (`Auth`/`Net` autoloads, `scripts/game/auth.gd`/`net.gd`) against a custom WebSocket relay server (`server/relay.js`, Node.js) — not Nakama; MULTIPLAYER menu flow supports host/join lobbies (`MpGameManager`, `scripts/game/mp_game_manager.gd`) relaying real-time actions between two live players, separate from the AI-opponent paths
- Win/loss overlay (modal with "You Win!" / "You Lose!" and Play Again button)
- Transform system: attack-count transform (`transform_N`) and max-health-threshold transform (`transform_at_max_health_N`, fires at that value *or higher*, not just exactly); Haven Guard → Hungering Wolf (5/4 Rush) at 4+ max health; threshold now fires on every health-gain path, including ones that previously skipped the check entirely when they granted health in a single large jump (Devour, Yeti challenge-win buff, healing a topped-out minion, Metamorphosis's transform-buff-self), not just the +1-at-a-time paths (Moonchild, Blood Transfusion, Sanguine, Apothecary, Pilot, stratagem buffs)
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
- `on_play_devour_friendly` ability: destroy a friendly, gain double its health (Crypt Lurker)
- `tainted_blood` stratagem effect: destroy a target friendly creature and deal damage to the enemy hero equal to its health times N (Tainted Blood)
- `bloodlet` stratagem effect: heal N to a friendly target (minion or own hero) or deal N damage to an enemy target (Bloodlet)
- `feast_attendant` ability: at end of owner's turn, give board-adjacent friendly creatures +0/+1 (Feast Attendant)
- `on_play_devour_all` ability: destroy every other creature on both boards and gain their combined attack and health (Blood Drenched)
- `exsanguinate` stratagem effect: deal damage to a target enemy minion equal to its own health (Exsanguinate)
- `blood_boil` stratagem effect: double a target friendly creature's current health (permanently, via current+max health gain) (Blood boil)
- `deathrattle_rummage_creature` ability: on death, rummage a non-legendary creature (Stinkherder)
- `rummage_equal_cost` ability: passive — while on board, rummages may retrieve equal-cost cards (Clutterpunk)
- AI simulation mode: headless AI-vs-AI loop accessible from main menu; tracks win rates per faction. Both sides are driven by `MCTSEngine` at level 10 (see `SimRunner._sim_play_turn`), so measured card/faction win rates reflect strong play rather than the old one-ply greedy policy — at the cost of speed: real search on both sides runs roughly a minute per game rather than the old near-instant greedy games, so batches need to be sized accordingly
- `rejuvenate_N` ability: at end of owner's turn, heals N health per minion that has it; handled via `_apply_rejuvenate` in `end_turn()`
- `broodtender_aura` ability: while on board, all friendly monstrosities gain Rejuvenate 2; applied on-play and on new monstrosity entry; removed on death
- `growvin_aura` ability (Growvin the Architect): while on board, all friendly mechs gain Cloaked, Rejuvenate 1, and Shielded 1; tracked via `growvin_granted`; handles two-Growvin edge case
- `on_friendly_transform_buff_self` ability (Metamorphosis): when any friendly creature transforms, gain +1/+1; fires via `_try_mirror_transform` hook (covers all transform types)
- Cloaked fix: cloaked now only blocks *enemy* stratagem and attack targeting; friendly stratagems can target cloaked creatures (fixes self-buff aura interaction)
- Deck builder UI refresh: collection uses real `Card.tscn` instances at 0.5 scale; hovering a card shows a full-size preview + keyword tooltip blocks in a fixed right panel

## TODO / Not Working Yet

- Dead minions not visually confirmed working (need to test with AI)
- Card art (partial — some faction art added under `assets/`, e.g. `assets/crimsoncard.png`, `assets/teal/*.png`, but not all cards have art yet)
- Sound

## Next Steps

1. Test that dead minions are properly removed after combat
2. Finish card art coverage for remaining cards
3. Continue tuning MCTS AI difficulty levels against real play (see `.docs/ai.md` for `MCTSBenchmark`/`SimRunner` verification tools)
