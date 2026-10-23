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

## `p_instance_id` lets a caller supply identity instead of minting new -
## used by duplicate_for_sim()/from_net_dict(), which represent the SAME
## minion in another state and must keep its id so an action naming it
## resolves on both sides.
func _init(card_data: CardData, owner: String, p_instance_id: String = "") -> void:
	data = card_data
	owner_id = owner
	current_attack = card_data.attack
	current_health = card_data.health
	max_health = card_data.health
	abilities = card_data.abilities.duplicate()
	is_exhausted = not has_ability(Abilities.RUSH)
	instance_id = p_instance_id if not p_instance_id.is_empty() else _generate_id()

func has_ability(ability: String) -> bool:
	return ability in abilities

## Deep copy for AI search simulation. `data` is cloned because transform/
## rummage effects mutate `minion.data` in place, and a search rollout must
## never touch the real game's CardData instances. clone_instance(), not
## Resource.duplicate(): duplicate() drops rummage_count, which several
## abilities scale their stats off, and aliases the abilities array.
##
## The id is passed to the constructor rather than assigned afterwards -
## minting one only to overwrite it is wasted work, and back when ids came
## from randi() it also advanced the global random stream every time a state
## was copied, so merely running a search perturbed the real match's rolls.
func duplicate_for_sim() -> Minion:
	var m := Minion.new(data.clone_instance(), owner_id, instance_id)
	m.current_attack = current_attack
	m.current_health = current_health
	m.max_health = max_health
	m.has_attacked = has_attacked
	m.is_exhausted = is_exhausted
	m.divine_shield = divine_shield
	m.is_piloted = is_piloted
	m.abilities = abilities.duplicate()
	m.is_newly_reinforced = is_newly_reinforced
	m.is_newly_transformed = is_newly_transformed
	m.is_nulled = is_nulled
	m.transform_counter = transform_counter
	m.piloted_by = piloted_by.clone_instance() if piloted_by != null else null
	m.pilot_atk_bonus = pilot_atk_bonus
	m.pilot_hp_bonus = pilot_hp_bonus
	return m

func take_damage(amount: int) -> void:
	current_health -= amount

func heal(amount: int) -> void:
	current_health = min(current_health + amount, max_health)

func is_dead() -> bool:
	return current_health <= 0

func reset_for_new_turn() -> void:
	has_attacked = false
	is_exhausted = false

func is_location() -> bool:
	return data.card_type == CardData.CardType.LOCATION

## Locations never attack, checked explicitly rather than relying on their 0
## attack: a stray buff (Supply Drop, Commanding Shout, Apothecary...) would
## otherwise hand a building a weapon.
func can_attack() -> bool:
	return not is_location() and not has_attacked and not is_exhausted and current_attack > 0

## Monotonic per-process counter rather than randi(): creating a minion must
## not consume the match's gameplay randomness (see PlayerState.mint_card_uid
## for the same reasoning). Ids are only ever compared within a single state
## or between a state and its own copy, so a process-wide counter is enough
## to keep them distinct.
static var _next_instance_seq: int = 0
func _generate_id() -> String:
	_next_instance_seq += 1
	return "%s#%d" % [data.id, _next_instance_seq]

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
		"is_piloted": is_piloted,
		"abilities": abilities
	}

func to_net_dict() -> Dictionary:
	return {
		"instance_id": instance_id,
		"card_id": data.id,
		"owner_id": owner_id,
		"current_attack": current_attack,
		"current_health": current_health,
		"max_health": max_health,
		"has_attacked": has_attacked,
		"is_exhausted": is_exhausted,
		"is_piloted": is_piloted,
		"is_nulled": is_nulled,
		"divine_shield": divine_shield,
		"transform_counter": transform_counter,
		"pilot_atk_bonus": pilot_atk_bonus,
		"pilot_hp_bonus": pilot_hp_bonus,
		"piloted_by_id": piloted_by.id if piloted_by != null else "",
		"abilities": abilities,
	}

static func from_net_dict(d: Dictionary) -> Minion:
	var card = CardDatabase.get_card(str(d["card_id"]))
	if card == null:
		return null
	var m := Minion.new(card.new_instance(""), str(d["owner_id"]), str(d["instance_id"]))
	m.current_attack = int(d["current_attack"])
	m.current_health = int(d["current_health"])
	m.max_health = int(d["max_health"])
	m.has_attacked = bool(d["has_attacked"])
	m.is_exhausted = bool(d["is_exhausted"])
	m.is_piloted = bool(d["is_piloted"])
	m.is_nulled = bool(d["is_nulled"])
	m.divine_shield = bool(d["divine_shield"])
	m.transform_counter = int(d["transform_counter"])
	m.pilot_atk_bonus = int(d["pilot_atk_bonus"])
	m.pilot_hp_bonus = int(d["pilot_hp_bonus"])
	var piloted_by_id = str(d.get("piloted_by_id", ""))
	# new_instance(), not the catalog object itself: a minion's pilot card is
	# runtime state and must never alias the shared definition.
	var piloted_by_card = CardDatabase.get_card(piloted_by_id) if piloted_by_id != "" else null
	m.piloted_by = piloted_by_card.new_instance("") if piloted_by_card != null else null
	m.abilities.clear()
	for a in d["abilities"]:
		m.abilities.append(str(a))
	return m
