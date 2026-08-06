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
| `scripts/game/ai_controller.gd` | Drives the opponent's turn: asks `MCTSEngine` for one action at a time, applies it to the real `GameState`/`Board` with pacing/logging/animations |
| `scripts/game/ai_heuristics.gd` | Stateless scoring/target-selection heuristics (trade scoring, face pressure, removal/challenge/pilot/heal target pickers) and the search leaf evaluator `evaluate_state`; shared by `AIController`, `SimRunner`, `HeadlessTurn`, `MCTSEngine` |
| `scripts/game/headless_turn.gd` | Pure `GameState` turn executor (no Node/UI deps): atomic action enumeration/application for MCTS search, plus the greedy one-ply policy used to finish rollouts and simulate future turns |
| `scripts/game/mcts_ai.gd` | `MCTSEngine` — heuristic-guided MCTS (UCT selection/expansion/backprop) over `HeadlessTurn` actions; `AI_LEVEL_CONFIG` defines the 1-10 difficulty knobs |
| `scripts/game/mcts_benchmark.gd` | `MCTSBenchmark` — headless AI-vs-AI win-rate benchmark comparing `MCTSEngine` levels/greedy policy; invoked via `main.gd`'s `--mcts-benchmark` CLI dev hook |
| `scripts/game/ranked_progress.gd` | `RankedProgress` — stateless display/AI-level-derivation math over the ladder state reported by `Auth` (not an autoload; holds no state itself) |
| `scripts/game/sim_runner.gd` | Headless AI-vs-AI simulation runner; pure `RefCounted`, no Node/UI dependencies |
| `scripts/game/deck_manager.gd` | Deck save/load, starter decks, faction metadata (**Autoload: `DeckManager`**) |
| `scripts/ui/deck_builder_screen.gd` | Deck builder UI: hub, faction picker, collection editor |
| `scripts/game/board.gd` | `Board` scene script; pure UI, emits signals upward to game_manager |
| `scripts/game/card_preview.gd` | Large card preview panel shown on hover (right side of screen) |
| `scripts/game/drop_zone.gd` | `DropZone` Control node; highlights and accepts creature card drops |
| `scripts/game/net.gd` | WebSocket client for the relay server: lobbies, ranked matchmaking queue, account auth, ranked result reporting (**Autoload: `Net`**) |
| `scripts/game/auth.gd` | Account/session state (login/register/resume, ranked ladder fields, matchmaking Elo) synced from `Net` (**Autoload: `Auth`**) |
| `scripts/game/mp_game_manager.gd` | `MpGameManager` — drives a live host/guest multiplayer match over `Net`'s relay (casual lobby or ranked matchmade), mirrored `GameState` on both sides |

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
    │   ├── game_manager.gd     (Autoload: "GameManagerAutoload", glue)
    │   ├── deck_manager.gd     (Autoload: "DeckManager"; decks, factions)
    │   ├── ai_controller.gd    (AI turn loop; applies MCTSEngine's chosen actions)
    │   ├── ai_heuristics.gd    (Shared scoring/target-pick heuristics + state evaluator)
    │   ├── headless_turn.gd    (Pure GameState turn executor for search/rollouts)
    │   ├── mcts_ai.gd          (MCTSEngine: UCT search over HeadlessTurn actions)
    │   ├── mcts_benchmark.gd   (MCTSBenchmark: headless AI-vs-AI win-rate CLI tool)
    │   ├── ranked_progress.gd  (RankedProgress: ladder display/AI-level math)
    │   ├── sim_runner.gd       (Headless AI-vs-AI balance sim; RefCounted)
    │   ├── net.gd              (Autoload: "Net"; WebSocket relay client)
    │   ├── auth.gd             (Autoload: "Auth"; account/session/ranked state)
    │   ├── mp_game_manager.gd  (MpGameManager: live host/guest multiplayer match)
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
| `Net` | `scripts/game/net.gd` | WebSocket client for the relay server (lobbies, ranked matchmaking, auth, ranked results) |
| `Auth` | `scripts/game/auth.gd` | Account/session state, ranked ladder fields, matchmaking Elo |
