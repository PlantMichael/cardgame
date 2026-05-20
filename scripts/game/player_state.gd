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
