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
var is_nulled: bool = false
var instance_id: String

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
```

Key methods:
- `start_game(first_player_id)` — deals 3 cards each, begins first turn
- `end_turn()` — swaps active player, calls `_begin_turn()`
- `play_creature(acting_player_id, card)` → returns `Minion`
- `play_stratagem(acting_player_id, card, target_minion, target_player_id)` → bool; returns false if target has Safeguard or player can't afford it
- `attack(attacker, target_minion, target_player_id)` — enforces taunt, resolves damage, removes dead minions
- `apply_challenge(challenger: Minion, target: Minion)` — resolves mini-combat between two minions (used by CHALLENGE ability)
- `apply_on_play_damage(target: Minion, damage: int)` — applies direct damage and checks win condition
- `apply_pilot(pilot_minion, target_mech, pilot_owner)` — buffs mech with pilot stats, removes pilot from board
- `apply_null(target: Minion)` — clears all abilities from target and sets `is_nulled = true`

Key methods also include:
Rummage methods:
- `get_rummage_options(player_id, max_cost, type_filter)` → `Array[CardData]`; returns unique graveyard cards matching filters (`""`, `"creature"`, `"stratagem"`, `"mech"`); `max_cost = -1` means no cost filter
- `complete_rummage(player_id, card)` — removes card from graveyard and adds it to hand

Stratagem effects handled in `_apply_stratagem()`:
- `"deal_damage"` — damages target minion or hero
- `"buff_creature"` — increases attack and health
- `"buff_health"` — increases health only
- `"give_ability"` — grants an ability from `card.abilities[0]` to the target minion
- `"deal_damage_all_creatures"` — deals damage to every minion on both sides
- `"buff_all_friendly_attack"` — gives all friendly creatures +N attack (no target needed)
