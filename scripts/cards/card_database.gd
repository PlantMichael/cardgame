extends Node

var cards: Dictionary = {}

func _ready() -> void:
	_load_cards()

func _load_cards() -> void:
	var files = [
		"res://data/cards/green.json",
		"res://data/cards/crimson.json",
		"res://data/cards/black.json",
		"res://data/cards/orange.json",
		"res://data/cards/teal.json",
		"res://data/cards/generic.json",
	]
	for path in files:
		_load_file(path)

func _load_file(path: String) -> void:
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Could not open: " + path)
		return
	var json = JSON.new()
	var result = json.parse(file.get_as_text())
	if result != OK:
		push_error("Failed to parse: " + path)
		return
	for card_dict in json.data:
		var data = CardData.new()
		data.id = card_dict["id"]
		data.card_name = card_dict["card_name"]
		data.cost = card_dict["cost"]
		data.color = CardData.CardColor[card_dict["color"]]
		data.card_type = CardData.CardType[card_dict["card_type"]]
		data.rarity = CardData.CardRarity[card_dict["rarity"]]
		data.description = card_dict["description"]
		data.tribe = card_dict.get("tribe", "")
		data.attack = card_dict.get("attack", 0)
		data.health = card_dict.get("health", 0)
		var new_abilities: Array[String] = []
		for ability in card_dict.get("abilities", []):
			new_abilities.append(str(ability))
		if not data.tribe.is_empty():
			new_abilities.append(data.tribe)
		data.abilities = new_abilities
		data.effect = card_dict.get("effect", "")
		data.effect_value = card_dict.get("effect_value", 0)
		data.transform_into = card_dict.get("transform_into", "")
		var new_choices: Array[String] = []
		for c in card_dict.get("transform_choices", []):
			new_choices.append(str(c))
		data.transform_choices = new_choices
		data.is_token = card_dict.get("is_token", false)
		cards[data.id] = data

func get_card(id: String) -> CardData:
	return cards.get(id, null)

func get_all_cards() -> Array[CardData]:
	var result: Array[CardData] = []
	result.assign(cards.values())
	return result
