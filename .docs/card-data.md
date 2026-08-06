# Card Data

## Pipeline

Card definitions live in `data/cards/{color}.json` (green, crimson, black, orange, teal, generic). `CardDatabase` parses them at `_ready()` and exposes `get_card(id)` / `get_all_cards()`. Cards with `color = GENERIC` are usable by every faction in deckbuilding. An optional `"art"` JSON field holds a `res://` path; if present and the resource exists, `CardDatabase` loads it into `CardData.art` (art coverage is partial — see `.docs/status.md`).

## CardData Fields

| Field | Used for |
|---|---|
| `card_type` | `CREATURE` or `STRATAGEM` |
| `abilities` | Array of string keys (`"guardian"`, `"rush"`, `"reinforce"`) |
| `effect` / `effect_value` | Stratagem behavior (`"deal_damage"`, `"buff_creature"`, `"buff_health"`) |

## CardData Schema (card_data.gd)

```gdscript
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
@export var art: Texture2D

var cost_modifier: int = 0  # runtime only; set by rummage (-1 discount)
var rummage_count: int = 0  # runtime only; number of times rummaged (for ON_PLAY_RUMMAGE_BUFF)

func effective_cost() -> int:
    return clamp(cost + cost_modifier, 1, 10)

@export var attack: int = 0
@export var health: int = 0
@export var abilities: Array[String] = []  # e.g. ["guardian", "rush", "reinforce"]
@export var transform_into: String = ""    # card id to become after transform
@export var transform_choices: Array[String] = []  # for on_play_transform_choice
@export var is_token: bool = false

# Stratagem only
@export var effect: String = ""
@export var effect_value: int = 0
```

## JSON Card Format

```json
{
  "id": "g_001",
  "card_name": "Thornback",
  "cost": 2,
  "color": "GREEN",
  "card_type": "CREATURE",
  "rarity": "COMMON",
  "description": "Guardian.",
  "attack": 1,
  "health": 4,
  "tribe": "",
  "abilities": ["guardian"],
  "art": "res://assets/green/thornback.png",
  "effect": "",
  "effect_value": 0
}
```

`"art"` is optional and omitted from most existing card entries; it is only present on cards that already have art added.
