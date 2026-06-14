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

func _init(card_data: CardData, owner: String) -> void:
	data = card_data
	owner_id = owner
	current_attack = card_data.attack
	current_health = card_data.health
	max_health = card_data.health
	abilities = card_data.abilities.duplicate()
	is_exhausted = not has_ability(Abilities.RUSH)
	instance_id = _generate_id()

func has_ability(ability: String) -> bool:
	return ability in abilities

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

func _generate_id() -> String:
	return "%s_%d" % [data.id, randi()]

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
	var m := Minion.new(card, str(d["owner_id"]))
	m.instance_id = str(d["instance_id"])
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
	m.piloted_by = CardDatabase.get_card(piloted_by_id) if piloted_by_id != "" else null
	m.abilities.clear()
	for a in d["abilities"]:
		m.abilities.append(str(a))
	return m
