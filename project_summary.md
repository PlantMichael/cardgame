# Card Game Project Summary for Claude Code

## Project Overview
A Hearthstone-style online card game built in **Godot 4** (GDScript). The game features a colored faction system with 5 colors, creature cards, and stratagem (spell) cards. Currently building toward online multiplayer via Nakama, but first completing a local AI opponent.

## Tech Stack
- **Engine:** Godot 4 (GDScript)
- **Future networking:** Nakama game server
- **Card data:** JSON files per color

## Game Design
- **5 colors:** GREEN, RED, BLACK, ORANGE, TEAL
- **Deck building:** 30 cards, 1-2 colors per deck
- **Card types:** CREATURE (played to battlefield) and STRATAGEM (instant spell effect)
- **Keywords:** Taunt (must be attacked first), Charge (can attack immediately)
- **Turn structure:** Hearthstone-style — gain 1 mana crystal per turn (max 10), draw 1 card, take actions in any order, end turn
- **Win condition:** Reduce opponent hero to 0 HP (both start at 30)
- **Board:** Max 7 creatures per side

## File Structure
```
res://
├── data/cards/
│   ├── green.json
│   ├── red.json
│   ├── black.json
│   ├── orange.json
│   └── teal.json
├── scenes/
│   ├── cards/
│   │   ├── Card.tscn       (Area2D root, card.gd attached)
│   │   └── CardBack.tscn   (Panel, face-down opponent cards)
│   └── game/
│       ├── Board.tscn      (Node2D root, board.gd attached)
│       └── Main.tscn       (Node root, main.gd attached)
└── scripts/
    ├── cards/
    │   ├── card_data.gd        (Resource, card blueprint)
    │   └── card_database.gd    (Autoload: "CardDatabase")
    └── game/
        ├── minion.gd           (Runtime creature instance)
        ├── player_state.gd     (Hand, board, deck, mana, HP)
        ├── game_state.gd       (Full match state, all actions)
        ├── board.gd            (Visual board, input handling)
        ├── hero.gd             (Hero panel script)
        ├── game_manager.gd     (Autoload: "GameManager", glue)
        ├── ai_controller.gd    (AI turn logic)
        └── main.gd             (Entry point, instantiates board)
```

## Autoloads (Project Settings → Globals → Autoload)
- `CardDatabase` → `res://scripts/cards/card_database.gd`
- `GameManager` → `res://scripts/game/game_manager.gd`

## Key Scripts

### card_data.gd
```gdscript
class_name CardData
extends Resource

enum CardColor { GREEN, RED, BLACK, ORANGE, TEAL }
enum CardType { CREATURE, STRATAGEM }
enum CardRarity { COMMON, RARE, EPIC, LEGENDARY }

@export var id: String = ""
@export var card_name: String = ""
@export var cost: int = 0
@export var color: CardColor = CardColor.GREEN
@export var card_type: CardType = CardType.CREATURE
@export var rarity: CardRarity = CardRarity.COMMON
@export var description: String = ""
@export var art: Texture2D
@export var attack: int = 0
@export var health: int = 0
@export var has_taunt: bool = false
@export var has_charge: bool = false
@export var effect: String = ""
@export var effect_value: int = 0
```

### minion.gd
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
var has_taunt: bool
var has_charge: bool
var instance_id: String

func _init(card_data: CardData, owner: String) -> void:
	data = card_data
	owner_id = owner
	current_attack = card_data.attack
	current_health = card_data.health
	max_health = card_data.health
	has_taunt = card_data.has_taunt
	has_charge = card_data.has_charge
	is_exhausted = not has_charge
	instance_id = "%s_%d" % [data.id, randi()]

func take_damage(amount: int) -> void:
	current_health -= amount

func heal(amount: int) -> void:
	current_health = min(current_health + amount, max_health)

func is_dead() -> bool:
	return current_health <= 0

func reset_for_new_turn() -> void:
	has_attacked = false
	is_exhausted = false

func can_attack() -> bool:
	return not has_attacked and not is_exhausted and current_attack > 0

func to_dict() -> Dictionary:
	return {
		"instance_id": instance_id,
		"card_id": data.id,
		"owner_id": owner_id,
		"current_attack": current_attack,
		"current_health": current_health,
		"max_health": max_health,
		"has_attacked": has_attacked,
		"is_exhausted": is_exhausted,
		"has_taunt": has_taunt,
		"has_charge": has_charge
	}
```

### player_state.gd
```gdscript
class_name PlayerState
extends RefCounted

var player_id: String
var hero_health: int = 30
var max_mana: int = 0
var current_mana: int = 0
var hand: Array[CardData] = []
var board: Array[Minion] = []
var deck: Array[CardData] = []

const MAX_BOARD_SIZE = 7
const MAX_HAND_SIZE = 10
const MAX_MANA = 10

func _init(id: String, starting_deck: Array[CardData]) -> void:
	player_id = id
	deck = starting_deck.duplicate()
	deck.shuffle()

func draw_card() -> CardData:
	if deck.is_empty():
		hero_health -= 1
		return null
	if hand.size() >= MAX_HAND_SIZE:
		deck.pop_back()
		return null
	var card = deck.pop_back()
	hand.append(card)
	return card

func gain_mana_crystal() -> void:
	max_mana = min(max_mana + 1, MAX_MANA)
	current_mana = max_mana

func spend_mana(amount: int) -> bool:
	if current_mana < amount:
		return false
	current_mana -= amount
	return true

func can_play_card(card: CardData) -> bool:
	return current_mana >= card.cost

func play_card_from_hand(card: CardData) -> bool:
	if not can_play_card(card):
		return false
	if card.card_type == CardData.CardType.CREATURE and board.size() >= MAX_BOARD_SIZE:
		return false
	hand.erase(card)
	spend_mana(card.cost)
	return true

func place_minion(minion: Minion) -> void:
	board.append(minion)

func remove_minion(minion: Minion) -> void:
	board.erase(minion)

func get_taunt_minions() -> Array[Minion]:
	var taunts: Array[Minion] = []
	for m in board:
		if m.has_taunt:
			taunts.append(m)
	return taunts

func is_dead() -> bool:
	return hero_health <= 0

func reset_for_new_turn() -> void:
	for minion in board:
		minion.reset_for_new_turn()
```

### game_state.gd
```gdscript
class_name GameState
extends RefCounted

enum Phase { WAITING, PLAYER_TURN, OPPONENT_TURN, GAME_OVER }

var player: PlayerState
var opponent: PlayerState
var current_phase: Phase = Phase.WAITING
var active_player_id: String = ""
var turn_number: int = 0
var winner_id: String = ""

func _init(local_player_id: String, opponent_player_id: String,
		   player_deck: Array[CardData], opponent_deck: Array[CardData]) -> void:
	player = PlayerState.new(local_player_id, player_deck)
	opponent = PlayerState.new(opponent_player_id, opponent_deck)

func start_game(first_player_id: String) -> void:
	active_player_id = first_player_id
	current_phase = Phase.PLAYER_TURN if first_player_id == player.player_id else Phase.OPPONENT_TURN
	turn_number = 1
	for i in 3:
		player.draw_card()
		opponent.draw_card()
	_begin_turn()

func _begin_turn() -> void:
	var active = _get_active_player()
	active.gain_mana_crystal()
	active.draw_card()
	active.reset_for_new_turn()

func end_turn() -> void:
	if active_player_id == player.player_id:
		active_player_id = opponent.player_id
		current_phase = Phase.OPPONENT_TURN
	else:
		active_player_id = player.player_id
		current_phase = Phase.PLAYER_TURN
		turn_number += 1
	_begin_turn()

func play_creature(acting_player_id: String, card: CardData) -> Minion:
	var acting = _get_player_by_id(acting_player_id)
	if not acting.play_card_from_hand(card):
		return null
	var minion = Minion.new(card, acting_player_id)
	acting.place_minion(minion)
	return minion

func play_stratagem(acting_player_id: String, card: CardData,
		target_minion: Minion = null, target_player_id: String = "") -> bool:
	var acting = _get_player_by_id(acting_player_id)
	if not acting.play_card_from_hand(card):
		return false
	_apply_stratagem(card, target_minion, target_player_id)
	return true

func attack(attacker: Minion, target_minion: Minion = null,
		target_player_id: String = "") -> void:
	if not attacker.can_attack():
		return
	var defending = _get_player_by_id(_opponent_id(attacker.owner_id))
	var taunts = defending.get_taunt_minions()
	if not taunts.is_empty() and target_minion not in taunts:
		return
	attacker.has_attacked = true
	if target_minion:
		target_minion.take_damage(attacker.current_attack)
		attacker.take_damage(target_minion.current_attack)
		_remove_dead_minions()
	elif target_player_id != "":
		var target_player = _get_player_by_id(target_player_id)
		target_player.hero_health -= attacker.current_attack
	_check_win_condition()

func _apply_stratagem(card: CardData, target_minion: Minion,
		target_player_id: String) -> void:
	match card.effect:
		"deal_damage":
			if target_minion:
				target_minion.take_damage(card.effect_value)
				_remove_dead_minions()
			elif target_player_id != "":
				var target = _get_player_by_id(target_player_id)
				target.hero_health -= card.effect_value
		"buff_creature":
			if target_minion:
				target_minion.current_attack += card.effect_value
				target_minion.current_health += card.effect_value
				target_minion.max_health += card.effect_value
		"buff_health":
			if target_minion:
				target_minion.current_health += card.effect_value
				target_minion.max_health += card.effect_value

func _remove_dead_minions() -> void:
	for p in [player, opponent]:
		for minion in p.board.duplicate():
			if minion.is_dead():
				p.remove_minion(minion)

func _check_win_condition() -> void:
	if opponent.is_dead():
		winner_id = player.player_id
		current_phase = Phase.GAME_OVER
	elif player.is_dead():
		winner_id = opponent.player_id
		current_phase = Phase.GAME_OVER

func is_local_player_turn() -> bool:
	return active_player_id == player.player_id

func _get_active_player() -> PlayerState:
	return _get_player_by_id(active_player_id)

func _get_player_by_id(id: String) -> PlayerState:
	return player if id == player.player_id else opponent

func _opponent_id(id: String) -> String:
	return opponent.player_id if id == player.player_id else player.player_id
```

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
- Keyword badges (TAUNT, CHARGE)
- AI controller (tactical: plays cards, trades minions, goes face, checks lethal)

## What's NOT Working Yet / TODO
- Dead minions not visually confirmed working (need to test with AI)
- Card art (images not added to cards yet)
- Win/loss screen (currently just prints to console)
- Networking (Nakama — planned after AI is solid)
- Deck builder UI
- Main menu
- Animations
- Sound

## Current Task
Just finished building the AI controller. Need to:
1. Test that dead minions are properly removed after combat
2. Test the full AI turn loop
3. Add card art support
4. Build win/loss screen
5. Then move to Nakama networking

## JSON Card Format
```json
{
  "id": "g_001",
  "card_name": "Thornback",
  "cost": 2,
  "color": "GREEN",
  "card_type": "CREATURE",
  "rarity": "COMMON",
  "description": "Taunt.",
  "attack": 1,
  "health": 4,
  "has_taunt": true,
  "has_charge": false,
  "effect": "",
  "effect_value": 0
}
```

## Player IDs
- Local player: `"player_1"`
- Opponent/AI: `"player_2"`

## Notes for Claude Code
- Use tabs not spaces for GDScript indentation
- All game logic lives server-side in game_state.gd (board.gd is purely visual)
- board.gd handles all input via _input() checking global rects, NOT via signal connections on nodes (Area2D input doesn't work well inside Control containers)
- Cards in hand are wrapped in Button nodes inside HBoxContainers
- Cards on board are wrapped in Control nodes inside HBoxContainers  
- Card scenes are Area2D with Control children — positions are handled by containers not manually
- When refresh() is called it rebuilds hand and board from scratch
- await get_tree().process_frame x2 before refresh() after playing cards to let queue_free process
