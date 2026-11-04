class_name CardData
extends Resource

## A card's printed definition plus the per-copy runtime state that rides
## along with one physical card.
##
## The `@export`-ed fields below are the *definition*: they come from
## data/cards/*.json via CardDatabase and are shared by every copy of that
## card. Catalog definitions are immutable: writing to CardDatabase's object
## edits every copy in every match. A physical clone may carry permanent
## attack/health changes (Salvager, Splinterkin Runt); these travel with it
## through zone changes, simulation and network views.
##
## Everything under "Runtime instance state" belongs to one physical copy and
## is expected to differ between two copies of the same card. Those fields
## are deliberately NOT exported, which has a consequence worth knowing:
## Godot's Resource.duplicate() only copies properties with STORAGE usage, so
## it silently drops all of them, and it copies array properties by reference
## so `abilities` would be shared with the source. Both are easy to miss and
## neither raises an error. So runtime copies never call duplicate() directly
## - they go through clone_instance() or new_instance() below.

enum CardColor { GREEN, CRIMSON, BLACK, ORANGE, TEAL, GENERIC }
enum CardType { CREATURE, STRATAGEM, LOCATION }
enum CardRarity { COMMON, RARE, EPIC, LEGENDARY }

# --- Definition (shared across every copy; treat as immutable) ---

@export var id: String = ""
@export var card_name: String = ""
@export var cost: int = 0
@export var color: CardColor = CardColor.GREEN
@export var card_type: CardType = CardType.CREATURE
@export var rarity: CardRarity = CardRarity.COMMON
@export var tribe: String = ""
@export var description: String = ""
@export var flavor_text: String = ""
@export var artist_name: String = ""
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

# --- Runtime instance state (one physical copy's own) ---

## Stable identity for one physical card, unique within a match and preserved
## across zone changes and simulation copies. Empty on a catalog definition
## (nothing in a player's hand/deck/graveyard should have an empty uid).
## Minted by PlayerState.mint_card_uid() - deliberately not from randi(), so
## creating a card never consumes gameplay randomness.
var uid: String = ""
var cost_modifier: int = 0
var rummage_count: int = 0

func effective_cost() -> int:
	if id == "gen_token_coin":
		return 0
	return clamp(cost + cost_modifier, 1, 10)

## Locations share the board row with creatures: played from hand into a board
## slot, attackable, destroyed at 0 health — they just never attack. Anything
## deciding "does this card need board space / go to the board" asks this
## rather than comparing against CREATURE alone.
func occupies_board() -> bool:
	return card_type == CardType.CREATURE or card_type == CardType.LOCATION

## Substitutes "{n}" in description with effect_value + rummage_count, for
## cards whose stated number grows each time they're rummaged (e.g. Sludge
## Spray). No-op for every other card since their description has no "{n}".
func effective_description() -> String:
	if not description.contains("{n}"):
		return description
	return description.replace("{n}", str(effect_value + rummage_count))

## Copies the fields Resource.duplicate() misses or aliases. See the class
## comment: non-exported vars are dropped, exported arrays are shared.
func _carry_runtime_state_into(c: CardData) -> void:
	c.abilities = abilities.duplicate()
	c.transform_choices = transform_choices.duplicate()
	c.cost_modifier = cost_modifier
	c.rummage_count = rummage_count

## The SAME physical card copied into another state - a simulation clone or a
## deserialized mirror. Keeps `uid`, so an action naming this card resolves to
## the corresponding card on either side of the copy.
func clone_instance() -> CardData:
	var c: CardData = duplicate()
	_carry_runtime_state_into(c)
	c.uid = uid
	return c

## A NEW physical card - an initial draw, minted as a token, or copied by
## an effect that creates a separate card. Takes its own identity, so it is
## never confused with the card it came from.
func new_instance(new_uid: String) -> CardData:
	var c: CardData = duplicate()
	_carry_runtime_state_into(c)
	c.uid = new_uid
	return c

# Target semantics shared by human presentation and AI enumeration.
func stratagem_needs_target() -> bool:
	return effect not in ["opening_coin", "destroy_all_creatures", "destroy_all_rummage_creature", "deal_damage_all_creatures", "deal_damage_all_enemy", "deal_damage_all_enemy_draw_yeti", "buff_all_friendly_attack", "buff_all_friendly_health", "eject_all_pilots", "sludge_spray"]

func stratagem_needs_creature_target() -> bool:
	return effect in ["give_ability", "buff_creature", "buff_health", "force_challenge", "poke_bear", "blood_transfusion", "sanguine", "heal", "eject_pilot", "give_mech_shielded_temp", "tainted_blood", "exsanguinate", "blood_boil", "return_friendly_to_hand"]

func stratagem_needs_friendly_yeti() -> bool:
	return effect in ["force_challenge", "poke_bear"]

func stratagem_needs_enemy_creature_only() -> bool:
	return effect in ["blood_transfusion", "exsanguinate"]

func stratagem_needs_friendly_creature_only() -> bool:
	return effect in ["sanguine", "heal", "give_ability", "tainted_blood", "blood_boil", "return_friendly_to_hand"]

func stratagem_needs_friendly_piloted_mech() -> bool:
	return effect == "eject_pilot"

func stratagem_needs_friendly_mech() -> bool:
	return effect == "give_mech_shielded_temp"
