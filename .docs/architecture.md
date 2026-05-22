# Architecture

## Layer Separation

The codebase has a clean split between **game logic** (pure GDScript classes, no Node dependencies) and **presentation** (scene nodes):

| Script | Role |
|---|---|
| `scripts/game/game_state.gd` | Authoritative game state; drives all rule enforcement |
| `scripts/game/player_state.gd` | Per-player state (hand, board, mana, deck) |
| `scripts/game/minion.gd` | Runtime minion instance (stats, abilities, instance_id) |
| `scripts/cards/card_data.gd` | `Resource` subclass defining the card schema |
| `scripts/game/abilities.gd` | Ability constants + death-trigger logic (**Autoload: `Abilities`**) |
| `scripts/cards/card_database.gd` | Loads JSON card files at startup (**Autoload: `CardDatabase`**) |
| `scripts/game/game_manager.gd` | Orchestrates game flow, wires board signals to game_state (**Autoload: `GameManagerAutoload`**) |
| `scripts/game/ai_controller.gd` | AI that plays cards and attacks each turn |
| `scripts/game/deck_manager.gd` | Deck save/load, starter decks, faction metadata (**Autoload: `DeckManager`**) |
| `scripts/ui/deck_builder_screen.gd` | Deck builder UI: hub, faction picker, collection editor |
| `scripts/game/board.gd` | `Board` scene script; pure UI, emits signals upward to game_manager |
| `scripts/game/card_preview.gd` | Large card preview panel shown on hover (right side of screen) |
| `scripts/game/drop_zone.gd` | `DropZone` Control node; highlights and accepts creature card drops |

## File Structure

```
res://
├── data/cards/
│   ├── green.json
│   ├── crimson.json
│   ├── black.json
│   ├── orange.json
│   ├── teal.json
│   └── generic.json        (cross-faction cards; color = GENERIC)
├── scenes/
│   ├── cards/
│   │   ├── Card.tscn       (Area2D root, card.gd attached)
│   │   └── CardBack.tscn   (Panel, face-down opponent cards)
│   ├── game/
│   │   ├── Board.tscn      (Node2D root, board.gd attached)
│   │   └── Main.tscn       (Node root, main.gd attached)
│   └── ui/
│       └── DeckBuilderScreen.tscn
└── scripts/
    ├── cards/
    │   ├── card_data.gd        (Resource, card blueprint)
    │   ├── card_database.gd    (Autoload: "CardDatabase")
    │   └── card.gd             (Card scene script, Area2D; handles visuals, drag/drop, badges)
    ├── game/
    │   ├── minion.gd           (Runtime creature instance)
    │   ├── player_state.gd     (Hand, board, deck, mana, HP)
    │   ├── game_state.gd       (Full match state, all actions)
    │   ├── board.gd            (Visual board, input handling)
    │   ├── hero.gd             (Hero panel script)
    │   ├── game_manager.gd     (Autoload: "GameManager", glue)
    │   ├── deck_manager.gd     (Autoload: "DeckManager"; decks, factions)
    │   ├── ai_controller.gd    (AI turn logic)
    │   ├── card_preview.gd     (Hover preview panel, right side)
    │   ├── drop_zone.gd        (DropZone Control, creature drop target)
    │   └── main.gd             (Entry point, main menu, deck select)
    └── ui/
        └── deck_builder_screen.gd  (Hub / faction picker / editor UI)
```

## Signal Flow

```
Board (UI events) → signals → GameManagerAutoload → GameState mutations → board.refresh()
```

`board.refresh()` is a full teardown-and-rebuild of all card/minion nodes from `GameState`. There is no incremental update.

## Autoloads (Global Singletons)

| Name | File | Role |
|---|---|---|
| `CardDatabase` | `scripts/cards/card_database.gd` | Card lookup |
| `GameManagerAutoload` | `scripts/game/game_manager.gd` | Game orchestration |
| `Abilities` | `scripts/game/abilities.gd` | Ability constants + death triggers |
| `DeckManager` | `scripts/game/deck_manager.gd` | Deck save/load, faction names/swatches |
