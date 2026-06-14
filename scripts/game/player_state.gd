class_name PlayerState
extends RefCounted

var player_id: String
var hero_health: int = 30
var max_mana: int = 0
var current_mana: int = 0
var hand: Array[CardData] = []
var board: Array[Minion] = []
var deck: Array[CardData] = []
var graveyard: Array[CardData] = []
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
	var card: CardData = deck.pop_back().duplicate()
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
	return current_mana >= card.effective_cost()

func play_card_from_hand(card: CardData) -> bool:
	if not can_play_card(card):
		return false
	if card.card_type == CardData.CardType.CREATURE and board.size() >= MAX_BOARD_SIZE:
		return false
	hand.erase(card)
	spend_mana(card.effective_cost())
	return true

func place_minion(minion: Minion) -> void:
	board.append(minion)

func remove_minion(minion: Minion) -> void:
	board.erase(minion)

func get_guardian_minions() -> Array[Minion]:
	var guardians: Array[Minion] = []
	for m in board:
		if m.has_ability(Abilities.GUARDIAN):
			guardians.append(m)
	return guardians

func is_dead() -> bool:
	return hero_health <= 0

func reset_for_new_turn() -> void:
	for minion in board:
		minion.reset_for_new_turn()

func to_dict() -> Dictionary:
	var hand_ids = hand.map(func(c): return c.id)
	var board_data = board.map(func(m): return m.to_dict())
	return {
		"player_id": player_id,
		"hero_health": hero_health,
		"max_mana": max_mana,
		"current_mana": current_mana,
		"hand_size": hand.size(),
		"hand": hand_ids,
		"board": board_data,
		"deck_size": deck.size()
	}

var _serialized_deck_size: int = -1

func get_deck_size() -> int:
	if _serialized_deck_size >= 0 and deck.is_empty():
		return _serialized_deck_size
	return deck.size()

func to_net_dict() -> Dictionary:
	return {
		"player_id": player_id,
		"hero_health": hero_health,
		"max_mana": max_mana,
		"current_mana": current_mana,
		"hand": hand.map(func(c): return {"id": c.id, "cost_modifier": c.cost_modifier, "rummage_count": c.rummage_count}),
		"board": board.map(func(m): return m.to_net_dict()),
		"deck_size": deck.size(),
		"graveyard": graveyard.map(func(c): return c.id),
	}

static func from_net_dict(d: Dictionary) -> PlayerState:
	var ps := PlayerState.new(str(d["player_id"]), [])
	ps.hero_health = int(d["hero_health"])
	ps.max_mana = int(d["max_mana"])
	ps.current_mana = int(d["current_mana"])
	ps.hand.clear()
	for h in d["hand"]:
		var card = CardDatabase.get_card(str(h["id"]))
		if card != null:
			var c := card.duplicate()
			c.cost_modifier = int(h.get("cost_modifier", 0))
			c.rummage_count = int(h.get("rummage_count", 0))
			ps.hand.append(c)
	ps.board.clear()
	for bd in d["board"]:
		var minion = Minion.from_net_dict(bd)
		if minion != null:
			ps.board.append(minion)
	ps._serialized_deck_size = int(d.get("deck_size", 0))
	ps.graveyard.clear()
	for gid in d["graveyard"]:
		var card = CardDatabase.get_card(str(gid))
		if card != null:
			ps.graveyard.append(card)
	return ps
