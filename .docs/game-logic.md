# Game Logic Scripts

## minion.gd

Runtime creature instance. Created when a card is played to the board.

```gdscript
class_name Minion
extends RefCounted

var data: CardData
var owner_id: String
var current_attack: int
var current_health: int
var max_health: int
var has_attacked: bool = false
var is_exhausted: bool = false
var divine_shield: bool = false
var is_piloted: bool = false
var abilities: Array[String] = []
var is_newly_reinforced: bool = false
var is_newly_transformed: bool = false
var is_nulled: bool = false
var transform_counter: int = 0
var instance_id: String
var piloted_by: CardData = null
var pilot_atk_bonus: int = 0
var pilot_hp_bonus: int = 0

func has_ability(ability: String) -> bool:
func can_attack() -> bool:
    return not has_attacked and not is_exhausted and current_attack > 0
```

## player_state.gd

Per-player state container.

```gdscript
class_name PlayerState
extends RefCounted

const MAX_BOARD_SIZE = 7
const MAX_HAND_SIZE = 10
const MAX_MANA = 10

var player_id: String
var hero_health: int = 30
var max_mana: int = 0
var current_mana: int = 0
var hand: Array[CardData] = []
var board: Array[Minion] = []
var deck: Array[CardData] = []
var graveyard: Array[CardData] = []
var fatigue_damage: int = 0
```

Key behaviors:
- `draw_card()` — deck-out increments `fatigue_damage` by 1 and deals that much damage (1, then 2, then 3, ... — same as Hearthstone; never resets mid-game); hand-full burns the top card (no fatigue)
- `gain_mana_crystal()` — increments max_mana up to 10 and refills current_mana
- `get_guardian_minions()` — returns board minions with the `"guardian"` ability

## game_state.gd

Authoritative match state. All game actions go through here.

```gdscript
class_name GameState
extends RefCounted

enum Phase { WAITING, PLAYER_TURN, OPPONENT_TURN, GAME_OVER }

var player: PlayerState
var opponent: PlayerState
var current_phase: Phase
var active_player_id: String
var turn_number: int
var winner_id: String
var pending_drawn_cards: Array[CardData] = []
var pending_fatigue_damage: Array[String] = []
var pending_rummages: Array[Dictionary] = []
var pending_tank_shots: Array[String] = []
var pending_nulls: Array[Dictionary] = []
var pending_overwatch_challenges: Array[String] = []
var pending_buff_friendly_health: Array[String] = []
var pending_tank_specialist_buffs: Array[String] = []
var pending_on_reinforce_damages: Array[Dictionary] = []
var temp_shielded: Array[Dictionary] = []
var growvin_granted: Array[Dictionary] = []
```

Key methods:
- `start_game(first_player_id)` — deals 3 cards each, begins first turn
- `end_turn()` — expires temp shields, applies Rejuvenate and Feast Attendant (`_apply_feast_attendant`, gives adjacent board-index neighbors +0/+1) for the ending player, swaps active player, calls `_begin_turn()`
- `_begin_turn()` — grants a mana crystal and draws for the new active player; if their deck was already empty, records the player id in `pending_fatigue_damage` instead of a card draw, then calls `_check_win_condition()` immediately (so a lethal fatigue draw ends the game the instant the turn begins, not whenever some later action happens to check)
- `play_creature(acting_player_id, card)` → returns `Minion`
- `play_stratagem(acting_player_id, card, target_minion, target_player_id)` → bool; returns false if target has Cloaked (enemy only) or Ambush (enemy only) or player can't afford it
- `attack(attacker, target_minion, target_player_id)` — enforces taunt, resolves damage, removes dead minions
- `apply_challenge(challenger: Minion, target: Minion)` — resolves mini-combat between two minions (used by CHALLENGE ability)
- `apply_on_play_damage(target: Minion, damage: int, source_player_id: String = "")` — applies direct damage (plus ENEMY_DAMAGE_AMP bonus if source_player_id provided) and checks win condition
- `apply_pilot(pilot_minion, target_mech, pilot_owner)` — buffs mech with pilot stats, removes pilot from board; triggers `ON_PILOTED_GAIN_RUSH` if present
- `apply_eject_pilot(target_mech, owner)` — reverses a pilot merge: restores mech stats, returns pilot card to board (or hand if board full); reusable from any card effect
- `apply_null(target: Minion)` — clears all abilities from target and sets `is_nulled = true`
- `apply_transform_choice(minion, chosen_id)` — transforms minion into the card with the given id, retaining damage taken
- `apply_buff_friendly_health(target: Minion)` — gives target +1 max health; triggers Apothecary and health-threshold transform
- `apply_heal_buff(target: Minion, amount: int)` — gives target +amount max and current health; triggers Apothecary and health-threshold transform
Key methods also include:
Rummage methods:
- `get_rummage_options(player_id, max_cost, type_filter, allow_equal_cost: bool = false)` → `Array[CardData]`; returns unique graveyard cards matching filters (`""`, `"creature"`, `"stratagem"`, `"mech"`, `"creature_nonlegendary"`); `max_cost = -1` means no cost filter; `allow_equal_cost` makes the cost filter inclusive (≤ instead of <)
- `apply_swap_friendly_health(minion_a, minion_b)` — swaps current_health between two minions, each capped at the other's max_health; removes dead minions afterward
- `apply_devour_friendly(devourer, target, owner)` — removes target from board (added to graveyard), grants `target.current_health * 2` to devourer's max and current health
- `complete_rummage(player_id, card, play_it: bool = false, discount: bool = true)` — removes card from graveyard; if `play_it` is true (or Stinkpile is on board) and card is a creature with board space, places it directly; otherwise adds to hand with optional `-1 cost_modifier` (black rummage only — non-black fetch mechanics pass `discount: false`)

Stratagem effects handled in `_apply_stratagem()`:
- `"deal_damage"` — damages target minion or hero
- `"buff_creature"` — increases attack and health
- `"buff_health"` — increases health only
- `"give_ability"` — grants an ability from `card.abilities[0]` to the target minion
- `"deal_damage_all_creatures"` — deals damage to every minion on both sides
- `"buff_all_friendly_attack"` — gives all friendly creatures +N attack (no target needed)
- `"poke_bear"` — deals N damage to a target creature; equivalent to `"deal_damage"` in game_state
- `"blood_transfusion"` — deals N damage to a target enemy creature; a second prompt selects a friendly to receive +N health
- `"sanguine"` — deals N damage to a target friendly creature; a second prompt selects another friendly to receive +N health
- `"heal"` — restores N health to target minion (capped at max_health)
- `"tainted_blood"` — destroys a target friendly creature (added to graveyard) and deals `target.current_health * N` damage to the enemy hero
- `"bloodlet"` — if target (minion or hero) belongs to the acting player, heals it N (minions capped at max_health); otherwise deals N damage to it
- `"exsanguinate"` — deals damage to a target enemy minion equal to `target.current_health * N` (always lethal)
- `"blood_boil"` — adds `target.current_health * N` to a target friendly creature's current and max health (doubles current health at N=1)
- `"eject_pilot"` — reverses a pilot merge on a friendly piloted Mech; calls `apply_eject_pilot()`
- `"eject_all_pilots"` — reverses all pilot merges on all friendly piloted Mechs
- `"destroy_all_creatures"` — sets every minion's health to 0 on both boards, then removes them all
- `"deal_damage_all_enemy"` — deals `effect_value` damage to every enemy minion (no target needed); e.g. Noxious Bombardment
- `"force_challenge"` — prompts player to pick a friendly Yeti to immediately challenge a chosen enemy; if `effect_value > 0` and the target dies, the Yeti gains +`effect_value`/+`effect_value`; e.g. Icewhip
