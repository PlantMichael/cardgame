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
