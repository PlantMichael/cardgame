class_name CardData
extends Resource

enum CardColor { GREEN, CRIMSON, BLACK, ORANGE, TEAL, GENERIC }
enum CardType { CREATURE, STRATAGEM }
enum CardRarity { COMMON, RARE, EPIC, LEGENDARY }

@export var id: String = ""
@export var card_name: String = ""
@export var cost: int = 0
@export var color: CardColor = CardColor.GREEN
@export var card_type: CardType = CardType.CREATURE
@export var rarity: CardRarity = CardRarity.COMMON
@export var tribe: String = ""
@export var description: String = ""

var cost_modifier: int = 0
var rummage_count: int = 0

func effective_cost() -> int:
	return clamp(cost + cost_modifier, 1, 10)

## Substitutes "{n}" in description with effect_value + rummage_count, for
## cards whose stated number grows each time they're rummaged (e.g. Sludge
## Spray). No-op for every other card since their description has no "{n}".
func effective_description() -> String:
	if not description.contains("{n}"):
		return description
	return description.replace("{n}", str(effect_value + rummage_count))
@export var art: Texture2D

# Creature only
@export var attack: int = 0
@export var health: int = 0
@export var abilities: Array[String] = []
@export var transform_into: String = ""
@export var transform_choices: Array[String] = []
@export var is_token: bool = false

# Stratagem only
@export var effect: String = ""
@export var effect_value: int = 0
