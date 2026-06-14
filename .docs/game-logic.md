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
```

Key behaviors:
- `draw_card()` — deck-out causes 1 fatigue damage per draw; hand-full burns the top card
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
var pending_rummages: Array[Dictionary] = []
var pending_tank_shots: Array[String] = []
var pending_nulls: Array[Dictionary] = []
var pending_overwatch_challenges: Array[String] = []
var pending_buff_friendly_health: Array[String] = []
var pending_on_reinforce_damages: Array[Dictionary] = []
```

Key methods:
- `start_game(first_player_id)` — deals 3 cards each, begins first turn
- `end_turn()` — swaps active player, calls `_begin_turn()`
- `play_creature(acting_player_id, card)` → returns `Minion`
- `play_stratagem(acting_player_id, card, target_minion, target_player_id)` → bool; returns false if target has Safeguard or player can't afford it
- `attack(attacker, target_minion, target_player_id)` — enforces taunt, resolves damage, removes dead minions
- `apply_challenge(challenger: Minion, target: Minion)` — resolves mini-combat between two minions (used by CHALLENGE ability)
- `apply_on_play_damage(target: Minion, damage: int)` — applies direct damage and checks win condition
- `apply_pilot(pilot_minion, target_mech, pilot_owner)` — buffs mech with pilot stats, removes pilot from board; triggers `ON_PILOTED_GAIN_RUSH` if present
- `apply_eject_pilot(target_mech, owner)` — reverses a pilot merge: restores mech stats, returns pilot card to board (or hand if board full); reusable from any card effect
- `apply_null(target: Minion)` — clears all abilities from target and sets `is_nulled = true`
- `apply_transform_choice(minion, chosen_id)` — transforms minion into the card with the given id, retaining damage taken
- `apply_buff_friendly_health(target: Minion)` — gives target +1 max health; triggers Apothecary and health-threshold transform
- `apply_heal_buff(target: Minion, amount: int)` — gives target +amount max and current health; triggers Apothecary and health-threshold transform
Key methods also include:
Rummage methods:
- `get_rummage_options(player_id, max_cost, type_filter)` → `Array[CardData]`; returns unique graveyard cards matching filters (`""`, `"creature"`, `"stratagem"`, `"mech"`); `max_cost = -1` means no cost filter
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
- `"eject_pilot"` — reverses a pilot merge on a friendly piloted Mech; calls `apply_eject_pilot()`
- `"deal_damage_all_enemy"` — deals `effect_value` damage to every enemy minion (no target needed); e.g. Noxious Bombardment
- `"force_challenge"` — prompts player to pick a friendly Yeti to immediately challenge a chosen enemy; if `effect_value > 0` and the target dies, the Yeti gains +`effect_value`/+`effect_value`; e.g. Icewhip
