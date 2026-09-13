extends Node

## Autoload: "CampaignModifiers" — loads the node-modifier pool for Campaign
## mode (see campaign_state.gd) from data/campaign_modifiers.json, mirroring
## card_database.gd's load pattern.

var modifiers: Array[Dictionary] = []

func _ready() -> void:
	_load()

func _load() -> void:
	var file := FileAccess.open("res://data/campaign_modifiers.json", FileAccess.READ)
	if not file:
		push_error("Could not open campaign_modifiers.json")
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("Failed to parse campaign_modifiers.json")
		return
	for entry in json.data:
		modifiers.append({
			"id": str(entry["id"]),
			"name": str(entry["name"]),
			"description": str(entry["description"]),
			"ability": str(entry["ability"]),
		})

func get_all() -> Array[Dictionary]:
	return modifiers.duplicate(true)

## Two distinct random modifiers for the loser-of-last-node choice screen.
func random_two() -> Array[Dictionary]:
	var pool := modifiers.duplicate(true)
	pool.shuffle()
	return pool.slice(0, mini(2, pool.size()))

## One random modifier, used for the very first node (no prior loser to pick).
func random_one() -> Dictionary:
	if modifiers.is_empty():
		return {}
	return modifiers[randi() % modifiers.size()]
