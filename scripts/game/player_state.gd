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
## Fatigue: each draw attempted with an empty deck deals one more damage than
## the last (1, then 2, then 3, ...), same as Hearthstone. Never resets
## mid-game — there's no deck-reshuffle mechanic here.
var fatigue_damage: int = 0
const MAX_BOARD_SIZE = 7
const MAX_HAND_SIZE = 10
const MAX_MANA = 10

## Monotonic counter behind mint_card_uid(). Deliberately a counter and not
## randi(): minting identity for a new card must not consume the match's
## gameplay randomness, or merely drawing a card would shift every later
## random roll (and a simulation branch that draws a different number of
## cards would desync from the real match for no good reason).
var _next_card_uid: int = 0

## Note the deck is NOT shuffled here. GameState shuffles it with the match's
## own generator (see GameState.rng) - shuffling here would use the global
## random stream, which a simulation copy must not disturb.
func _init(id: String, starting_deck: Array[CardData]) -> void:
	player_id = id
	deck = starting_deck.duplicate()

## A fresh per-match identity for one physical card. Scoped by player_id so
## the two players' allocators can run independently without colliding.
func mint_card_uid() -> String:
	_next_card_uid += 1
	return "%s-c%d" % [player_id, _next_card_uid]

## The one card in hand with this uid, or null. Callers must address a card
## by uid rather than by definition id: two copies of the same card can carry
## different discounts and rummage history, so "the first one with this id"
## can play the wrong physical card.
func find_card_in_hand(uid: String) -> CardData:
	if uid.is_empty():
		return null
	for c in hand:
		if c.uid == uid:
			return c
	return null

func draw_card() -> CardData:
	if deck.is_empty():
		fatigue_damage += 1
		hero_health -= fatigue_damage
		return null
	if hand.size() >= MAX_HAND_SIZE:
		deck.pop_back()
		return null
	# A drawn card is a NEW physical card: it gets its own identity, and the
	# deck entry it came from is a shared catalog definition that must not be
	# mutated by whatever happens to the card in hand.
	var card: CardData = deck.pop_back().new_instance(mint_card_uid())
	hand.append(card)
	return card

func gain_mana_crystal() -> void:
	max_mana = min(max_mana + 1, MAX_MANA)
	current_mana = 0

func spend_mana(amount: int) -> bool:
	if current_mana + amount > max_mana:
		return false
	current_mana += amount
	return true

func can_play_card(card: CardData) -> bool:
	return current_mana + card.effective_cost() <= max_mana

## Board space is counted in slots rather than bodies: a Colossal creature
## (Ancient Abominable) fills two of the seven. Everything that puts a
## creature on the board goes through has_room_for()/can_fit_card() instead of
## comparing board.size() to MAX_BOARD_SIZE.
static func slots_for(abilities: Array[String]) -> int:
	return 2 if Abilities.TWO_SLOT in abilities else 1

func board_slots_used() -> int:
	var used := 0
	for m in board:
		used += slots_for(m.abilities)
	return used

func has_room_for(abilities: Array[String]) -> bool:
	return board_slots_used() + slots_for(abilities) <= MAX_BOARD_SIZE

func can_fit_card(card: CardData) -> bool:
	return not card.occupies_board() or has_room_for(card.abilities)

## Low-level commit step: assumes the caller has already validated the play
## (see GameState.execute()). Still re-checks hand membership, affordability
## and board room itself so no path can spend mana for a card that was never
## in hand - `hand.erase()` on a missing card silently does nothing, which
## used to let a stale or forged card reference pay nothing and still resolve.
func play_card_from_hand(card: CardData) -> bool:
	if card == null:
		return false
	if not hand.has(card):
		return false
	if not can_play_card(card):
		return false
	if not can_fit_card(card):
		return false
	hand.erase(card)
	spend_mana(card.effective_cost())
	return true

## at_index lets a caller (see Board's drag-and-drop - board.gd's
## _board_insert_index_for_x()) choose where in the row the minion lands
## instead of always appending at the end; out-of-range values (including
## the default -1) fall back to appending.
func place_minion(minion: Minion, at_index: int = -1) -> void:
	if at_index < 0 or at_index >= board.size():
		board.append(minion)
	else:
		board.insert(at_index, minion)

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

## Deep copy for AI search simulation. Every CardData reached from hand/deck/
## graveyard is cloned so a simulated rollout can never mutate the real game's
## cards (some effects mutate CardData in place, e.g. cost_modifier). Cloning
## goes through clone_instance(), NOT Resource.duplicate(): duplicate() drops
## every non-exported field, so a simulated hand used to lose its discounts
## and rummage history and the search evaluated the wrong costs.
func duplicate_for_sim() -> PlayerState:
	var p := PlayerState.new(player_id, [])
	p.hero_health = hero_health
	p.max_mana = max_mana
	p.current_mana = current_mana
	p.fatigue_damage = fatigue_damage
	p._next_card_uid = _next_card_uid
	var hand_copy: Array[CardData] = []
	for c in hand:
		hand_copy.append(c.clone_instance())
	p.hand = hand_copy
	var board_copy: Array[Minion] = []
	for m in board:
		board_copy.append(m.duplicate_for_sim())
	p.board = board_copy
	var deck_copy: Array[CardData] = []
	for c in deck:
		deck_copy.append(c.clone_instance())
	p.deck = deck_copy
	var graveyard_copy: Array[CardData] = []
	for c in graveyard:
		graveyard_copy.append(c.clone_instance())
	p.graveyard = graveyard_copy
	return p

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
## Set when this state arrived as an OPPONENT view, where the hand is a count
## and not a list of cards. -1 means the hand is really here.
var _serialized_hand_size: int = -1

## How many cards are in hand. Use this rather than hand.size() anywhere the
## state might be an opponent's view: there, the cards themselves are
## deliberately absent and only the count is known.
func get_hand_size() -> int:
	if _serialized_hand_size >= 0 and hand.is_empty():
		return _serialized_hand_size
	return hand.size()

func get_deck_size() -> int:
	if _serialized_deck_size >= 0 and deck.is_empty():
		return _serialized_deck_size
	return deck.size()

## `reveal_hand` false produces an OPPONENT view: the hand becomes a count,
## with no card ids, uids or modifiers. A player must not be able to read
## their opponent's hand out of a payload they receive, and the only reliable
## way to guarantee that is for the information never to be sent.
func to_net_dict(reveal_hand: bool = true) -> Dictionary:
	if not reveal_hand:
		return {
			"player_id": player_id,
			"hero_health": hero_health,
			"max_mana": max_mana,
			"current_mana": current_mana,
			"fatigue_damage": fatigue_damage,
			"hand": [],
			"hand_size": get_hand_size(),
			"board": board.map(func(m): return m.to_net_dict()),
			"deck_size": deck.size(),
			"graveyard": graveyard.map(func(c): return {"id": c.id, "uid": c.uid}),
		}
	return {
		"player_id": player_id,
		"hero_health": hero_health,
		"max_mana": max_mana,
		"current_mana": current_mana,
		"fatigue_damage": fatigue_damage,
		"hand": hand.map(func(c): return {"id": c.id, "uid": c.uid, "cost_modifier": c.cost_modifier, "rummage_count": c.rummage_count}),
		"board": board.map(func(m): return m.to_net_dict()),
		"deck_size": deck.size(),
		"graveyard": graveyard.map(func(c): return {"id": c.id, "uid": c.uid}),
	}

static func from_net_dict(d: Dictionary) -> PlayerState:
	var ps := PlayerState.new(str(d["player_id"]), [])
	ps.hero_health = int(d["hero_health"])
	ps.max_mana = int(d["max_mana"])
	ps.current_mana = int(d["current_mana"])
	ps.fatigue_damage = int(d.get("fatigue_damage", 0))
	ps.hand.clear()
	for h in d["hand"]:
		var card = CardDatabase.get_card(str(h["id"]))
		if card != null:
			var c := card.new_instance(str(h.get("uid", "")))
			c.cost_modifier = int(h.get("cost_modifier", 0))
			c.rummage_count = int(h.get("rummage_count", 0))
			ps.hand.append(c)
	ps.board.clear()
	for bd in d["board"]:
		var minion = Minion.from_net_dict(bd)
		if minion != null:
			ps.board.append(minion)
	ps._serialized_deck_size = int(d.get("deck_size", 0))
	# An opponent view carries a count instead of the cards.
	ps._serialized_hand_size = int(d["hand_size"]) if d.has("hand_size") else -1
	ps.graveyard.clear()
	for g in d["graveyard"]:
		# Older peers sent bare id strings here; accept both shapes.
		var gid := str(g["id"]) if g is Dictionary else str(g)
		var guid := str(g.get("uid", "")) if g is Dictionary else ""
		var card = CardDatabase.get_card(gid)
		if card != null:
			ps.graveyard.append(card.new_instance(guid))
	return ps
