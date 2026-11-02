# Card Data

## Definition vs. runtime instance

`CardData` carries a card's printed **definition** (every `@export`-ed field)
*and* the per-copy **runtime state** that rides along with one physical card:

```gdscript
var uid: String = ""        # identity of ONE physical card, unique per match
var cost_modifier: int = 0  # discounts (rummage, Tutkiun)
var rummage_count: int = 0  # how often this copy has been rummaged
```

`CardDatabase` hands out one shared catalog object per id, so the exported
fields on that shared object must be treated as immutable. Physical clones may
carry permanent attack/health changes (Salvager and Splinterkin Runt); these stay
on that copy through death, Rummage and replay within the match. Hand, graveyard
and board network views carry those stats; simulation clones and replay hashes
preserve the distinction. Rummage pickers display the first matching physical
graveyard copy, rather than its unmodified catalog definition.

**Never call `Resource.duplicate()` on a `CardData`.** It only copies
properties with STORAGE usage, so it silently drops `uid`, `cost_modifier` and
`rummage_count`, and it copies `abilities` by reference so the copy aliases the
original's array. Neither failure raises an error. Use instead:

- `clone_instance()` — the SAME physical card in another state (a simulation
  copy, a deserialized mirror). Keeps `uid`.
- `new_instance(uid)` — a NEW physical card (initial draw, token, created copy).
  Takes its own identity.
- `PlayerState.instantiate_drawn_card(entry)` — initial catalog deck entries get
  a new UID; an already-instanced returned card keeps its UID and runtime state.
  All four deck-to-hand paths share this distinction while retaining their
  existing fatigue, search and hand-capacity rules.

Identity is minted by `PlayerState.mint_card_uid()`, a per-player counter
rather than `randi()`, so creating a card never consumes gameplay randomness.
Address a card in hand with `PlayerState.find_card_in_hand(uid)` — looking it
up by definition id picks "the first copy with this id", which plays the wrong
card when two copies carry different discounts or rummage history.

## Pipeline

Card definitions live in `data/cards/{color}.json` (green, crimson, black, orange, teal, generic). `CardDatabase` parses them at `_ready()` and exposes `get_card(id)` / `get_all_cards()`. Cards with `color = GENERIC` are usable by every faction in deckbuilding. An optional `"art"` JSON field holds a `res://` path; if present and the resource exists, `CardDatabase` loads it into `CardData.art` (art coverage is partial — see `.docs/status.md`).

## CardData Fields

| Field | Used for |
|---|---|
| `card_type` | `CREATURE`, `STRATAGEM`, or `LOCATION` |
| `abilities` | Array of string keys (`"guardian"`, `"rush"`, `"reinforce"`) |
| `effect` / `effect_value` | Stratagem behavior (`"deal_damage"`, `"buff_creature"`, `"buff_health"`) |

## CardData Schema (card_data.gd)

```gdscript
class_name CardData
extends Resource

enum CardColor { GREEN, CRIMSON, BLACK, ORANGE, TEAL, GENERIC }
enum CardType { CREATURE, STRATAGEM, LOCATION }
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

## Public catalog

A read-only, unversioned export of these definitions for third-party tools lives in [`catalog/`](../catalog/README.md): `catalog/src/export.mjs` projects an explicit release selection (`catalog/release-input.json`) from the same six faction files into `catalog/public/data/`, and `catalog/src/server.mjs` serves it statically. It is independent of the Godot game, `server/relay.js` and Postgres. `data/keyword_abilities.json` maps the few ability keys whose keyword has a different printed name (e.g. `combat_immune` → Ethereal). The first release is a candidate awaiting owner decisions (see the catalog README).

## Headshot batch

RulesVersion 4 adds ten cards and removes Crypt Chapel (`cr_021`) without reusing
its ID. Requested uncommon cards use the existing internal `RARE` tier. New cards
reuse faction artwork as placeholders and have no inferred tribes. The public
catalog includes the new cards, while Emergency Extraction, Whiteout and Snowdrift
Matriarch remain held back. Source data has 180 non-token cards plus eight forms;
the selected public catalog has 177 collectible cards plus eight forms.
