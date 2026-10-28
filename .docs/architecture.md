# Architecture

## Layer Separation

The codebase has a clean split between **game logic** (pure GDScript classes, no Node dependencies) and **presentation** (scene nodes):

| Script | Role |
|---|---|
| `scripts/game/event_presenter.gd` | `EventPresenter` - turns the rules core's advisory events into log lines and challenge/laser animations; shared by every controller that renders a match |
| `scripts/game/parity_test.gd` | `ParityTest` - replays seeded AI-vs-AI matches from (seed, decks, command log) and requires identical state at every step; run via `--parity-test` |
| `scripts/game/match_host.gd` | `MatchHost` - the server's headless rules host for server-run ranked matches: `--match-host` runs a `TCPServer` on `127.0.0.1`, holds one `GameState` per live match and answers the relay's `hello`/`create`/`command`/`timeout`/`view`/`replay`/`drop`/`stats` ops. Builds no UI and opens no network autoload connection; see [Authoritative Server](authoritative-server.md) |
| `scripts/game/remote_match_client.gd` | `RemoteMatchClient` - the **thin** ranked client: sends commands with an increasing `client_seq`, holds no rules, rebuilds the board from each server `match_view` and plays animations from that seat's filtered events |
| `scripts/game/match_recorder.gd` | `MatchRecorder` - per-match card facts (drawn/kept/played counts, first-played turn, created-vs-deck) read off the event feed; runs inside the match host and never on a simulation copy (spec 002) |
| `scripts/game/rules_version.gd` | `RulesVersion.RULES_VERSION` - bumped when rules or card data change; a ranked client with a different version is told to update |
| `scripts/game/game_state.gd` | Authoritative game state; drives all rule enforcement |
| `scripts/game/core_tests.gd` | `CoreTests` — rules-core regression suite (copy isolation, command validation, card identity, tree-reuse fingerprint, Crypt Hunger, aura lifetime). Run via `--core-tests`; **exits with the failure count**, unlike the older hooks |
| `scripts/game/player_state.gd` | Per-player state (hand, board, mana, deck) |
| `scripts/game/minion.gd` | Runtime minion instance (stats, abilities, instance_id) |
| `scripts/cards/card_data.gd` | `Resource` subclass defining the card schema |
| `scripts/game/abilities.gd` | Ability constants + death-trigger logic (**Autoload: `Abilities`**) |
| `scripts/cards/card_database.gd` | Loads JSON card files at startup (**Autoload: `CardDatabase`**) |
| `scripts/cards/card.gd` | `Card` — the one scene/script every card on screen uses, at any of three sizes (`Card.Size.SMALL`/`MEDIUM`/`LARGE`); draws a per-color frame from `assets/card_assets/` plus the mana orb, rarity gem and tribe-symbol row laid into that frame's slots |
| `scripts/cards/card_3d_layer.gd` | **Unused.** The retired 3D card-mesh layer. Nothing instantiates it any more — cards are flat 2D again (see `card.gd`). Left on disk only so the approach can be picked back up |
| `scripts/cards/legendary_animations.gd` | `LegendaryAnimations` — per-legendary one-off "spectacle" animations (`play_flight()` and the landing half), kept out of `card.gd` so it doesn't grow a per-card-id switch |
| `scripts/game/game_manager.gd` | Orchestrates game flow, wires board signals to game_state (**Autoload: `GameManagerAutoload`**) |
| `scripts/game/ai_controller.gd` | Drives the opponent's turn: asks `MCTSEngine` for one action at a time, applies it to the real `GameState`/`Board` with pacing/logging/animations |
| `scripts/game/ai_heuristics.gd` | Stateless scoring/target-selection heuristics (trade scoring, face pressure, removal/challenge/pilot/heal target pickers) and the search leaf evaluator `evaluate_state`; shared by `AIController`, `HeadlessTurn`, `MCTSEngine` |
| `scripts/game/headless_turn.gd` | Pure `GameState` turn executor (no Node/UI deps): atomic action enumeration/application for MCTS search, plus the greedy one-ply policy used to finish rollouts and simulate future turns |
| `scripts/game/mcts_ai.gd` | `MCTSEngine` — heuristic-guided MCTS (UCT selection/expansion/backprop) over `HeadlessTurn` actions; `AI_LEVEL_CONFIG` defines the 1-10 difficulty knobs |
| `scripts/game/mcts_benchmark.gd` | `MCTSBenchmark` — headless AI-vs-AI win-rate benchmark comparing `MCTSEngine` levels/greedy policy; invoked via `main.gd`'s `--mcts-benchmark` CLI dev hook |
| `scripts/game/ranked_progress.gd` | `RankedProgress` — stateless display/AI-level-derivation math over the ladder state reported by `Auth` (not an autoload; holds no state itself) |
| `scripts/game/campaign_state.gd` | `CampaignState` — pure-logic state for a Campaign run (best-of-3/5/7 sequence of node matches, node modifier assignment/choice, catch-up threshold); not an autoload |
| `scripts/game/campaign_modifiers.gd` | Loads the Campaign node-modifier pool from `data/campaign_modifiers.json` (**Autoload: `CampaignModifiers`**) |
| `scripts/game/deck_manager.gd` | Deck save/load, starter decks, faction metadata (**Autoload: `DeckManager`**) |
| `scripts/ui/deck_builder_screen.gd` | Deck builder UI: hub, faction picker, collection editor |
| `scripts/ui/faction_pie_chart.gd` | `FactionPieChart` — pie-chart faction picker widget used by `deck_builder_screen.gd`'s faction page |
| `scripts/ui/card_list_screen.gd` | `CardListScreen` — read-only browsable list of every card, grouped by color, with color/type/cost filters and search; reached from the main menu's "CARD LIST" button |
| `scripts/ui/campaign_map_screen.gd` | `CampaignMapScreen` — landscape trail map shown before the first Campaign node and between every subsequent one; nodes laid out along a path, click-to-preview modifiers, 30s countdown before the next match |
| `scripts/game/board.gd` | `Board` scene script; pure UI, emits signals upward to game_manager |
| `scripts/game/card_preview.gd` | **Unused.** An older hand-built preview Panel. No scene attaches it and nothing references it (it was already orphaned before the card-frame rework); the board's hover preview is a plain `Card` at `Card.Size.LARGE` |
| `scripts/game/drop_zone.gd` | `DropZone` Control node; highlights and accepts creature card drops |
| `scripts/game/net.gd` | WebSocket client for the relay server: lobbies, ranked matchmaking queue, account auth, ranked result reporting, currency/shop/crafting messages (**Autoload: `Net`**) |
| `scripts/game/auth.gd` | Account/session state (login/register/resume, ranked ladder fields, matchmaking Elo) synced from `Net` (**Autoload: `Auth`**) |
| `scripts/game/economy.gd` | `Economy` — currency/dust/owned-card collection, mirrored from server-authoritative state via `Net`; fetches on login/resume, only ever updates from a `Net` `*_result` signal (**Autoload: `Economy`**) |
| `scripts/game/pack_opener.gd` | `PackOpener` — pure logic (no Node deps) that rolls a pack's contents by rarity odds and converts over-copy-limit duplicates to dust; mirrors the roll `relay.js`'s `purchase_pack` handler performs server-side |
| `scripts/ui/shop_screen.gd` | `ShopScreen` — Shop UI: lists purchasable packs from `data/shop_packs.json`, shows the current Gold/Dust balance, and hosts the crafting panel; reached from the main menu's "SHOP" button |
| `scripts/ui/pack_open_screen.gd` | `PackOpenScreen` — sequential Tween-driven reveal of a purchased pack's cards, with a skip/speed-up input |
| `scripts/game/mp_game_manager.gd` | `MpGameManager` — drives a live host/guest multiplayer match over `Net`'s relay (casual lobby or ranked matchmade), mirrored `GameState` on both sides |

## File Structure

```
res://
├── data/
│   ├── cards/
│   │   ├── green.json
│   │   ├── crimson.json
│   │   ├── black.json
│   │   ├── orange.json
│   │   ├── teal.json
│   │   └── generic.json        (cross-faction cards; color = GENERIC)
│   ├── campaign_modifiers.json (Campaign mode node-modifier pool)
│   ├── shop_packs.json         (Shop pack definitions: price, card count, rarity odds, dust value)
│   ├── quests.json             (Daily/weekly quest pool: track key, goal, reward)
│   ├── keywords.json           (Keyword -> tooltip text; read by board.gd, deck builder, card list)
│   └── starters.json           (Starter deck lists per faction; read by DeckManager)
├── catalog/                  (public card catalog: export.mjs, server.mjs, release-input.json, public/ data files, tests; see catalog/README.md)
├── scenes/
│   ├── cards/
│   │   ├── Card.tscn         (Area2D root, card.gd attached)
│   │   ├── Card3DLayer.tscn  (unused — retired 3D mesh layer)
│   │   └── CardBack.tscn     (TextureRect, face-down opponent cards / deck icon)
│   ├── game/
│   │   ├── Board.tscn      (Node2D root, board.gd attached)
│   │   └── Main.tscn       (Node root, main.gd attached)
│   └── ui/
│       └── DeckBuilderScreen.tscn
└── scripts/
    ├── cards/
    │   ├── card_data.gd        (Resource, card blueprint)
    │   ├── card_database.gd    (Autoload: "CardDatabase")
    │   ├── card.gd             (Card scene script, Area2D; handles visuals, drag/drop, badges)
    │   ├── card_3d_layer.gd    (unused — retired 3D mesh layer)
    │   └── legendary_animations.gd (Per-legendary spectacle animations)
    ├── game/
    │   ├── minion.gd             (Runtime creature instance)
    │   ├── player_state.gd       (Hand, board, deck, mana, HP)
    │   ├── game_state.gd         (Full match state, all actions)
    │   ├── board.gd              (Visual board, input handling)
    │   ├── hero.gd               (Hero panel script)
    │   ├── game_manager.gd       (Autoload: "GameManagerAutoload", glue)
    │   ├── deck_manager.gd       (Autoload: "DeckManager"; decks, factions)
    │   ├── ai_controller.gd      (AI turn loop; applies MCTSEngine's chosen actions)
    │   ├── ai_heuristics.gd      (Shared scoring/target-pick heuristics + state evaluator)
    │   ├── headless_turn.gd      (Pure GameState turn executor for search/rollouts)
    │   ├── mcts_ai.gd            (MCTSEngine: UCT search over HeadlessTurn actions)
    │   ├── mcts_benchmark.gd     (MCTSBenchmark: headless AI-vs-AI win-rate CLI tool)
    │   ├── ranked_progress.gd    (RankedProgress: ladder display/AI-level math)
    │   ├── campaign_state.gd     (CampaignState: best-of-N node-match sequence, modifier assignment/choice)
    │   ├── campaign_modifiers.gd (Autoload: "CampaignModifiers"; loads data/campaign_modifiers.json)
    │   ├── net.gd                (Autoload: "Net"; WebSocket relay client)
    │   ├── auth.gd               (Autoload: "Auth"; account/session/ranked state)
    │   ├── economy.gd            (Autoload: "Economy"; currency/dust/owned-card collection)
    │   ├── pack_opener.gd        (PackOpener: pure pack-rolling/duplicate-to-dust logic)
    │   ├── mp_game_manager.gd    (MpGameManager: live host/guest multiplayer match)
    │   ├── match_host.gd         (MatchHost: the server's headless rules host, --match-host)
    │   ├── remote_match_client.gd (RemoteMatchClient: thin client for server-run ranked matches)
    │   ├── match_recorder.gd      (MatchRecorder: per-match card facts from the event feed)
    │   ├── card_preview.gd       (unused — orphaned older preview panel)
    │   ├── drop_zone.gd          (DropZone Control, creature drop target)
    │   └── main.gd               (Entry point, main menu, deck select)
    └── ui/
        ├── deck_builder_screen.gd  (Hub / faction picker / editor UI)
        ├── faction_pie_chart.gd    (Pie-chart faction picker widget)
        ├── card_list_screen.gd     (Browsable card list, grouped by color)
        ├── campaign_map_screen.gd  (Campaign trail map between nodes)
        ├── shop_screen.gd          (Shop: pack listings, balance, crafting panel)
        └── pack_open_screen.gd     (Sequential pack-reveal animation)
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
| `CampaignModifiers` | `scripts/game/campaign_modifiers.gd` | Campaign mode node-modifier pool lookup |
| `GameManagerAutoload` | `scripts/game/game_manager.gd` | Game orchestration |
| `Abilities` | `scripts/game/abilities.gd` | Ability constants + death triggers |
| `DeckManager` | `scripts/game/deck_manager.gd` | Deck save/load, faction names/swatches |
| `Net` | `scripts/game/net.gd` | WebSocket client for the relay server (lobbies, ranked matchmaking, auth, ranked results, currency/shop/crafting) |
| `Auth` | `scripts/game/auth.gd` | Account/session state, ranked ladder fields, matchmaking Elo |
| `Economy` | `scripts/game/economy.gd` | Currency/dust balance + owned-card collection, mirrored from server-authoritative state |

## Server Processes

The relay is a separate Node.js program (`server/`), not part of the Godot
project. With ranked matches running on the server (`RANKED_AUTHORITATIVE=1`)
there is a **second** process: a headless Godot that runs the rules and nothing
else. Full description and operating notes: [Authoritative Server](authoritative-server.md).

```
server/
├── relay.js                     (the WebSocket server clients talk to: accounts, lobbies,
│                                 matchmaking, currency/shop, legacy ranked reporting)
├── ladder.js                    (nextRankState/nextElo — the ladder math both ranked paths share)
├── schema_legacy.js             (players/sessions/decks/owned_cards/ranked_settlements DDL,
│                                 run by relay.js at boot and by the DB-backed tests)
├── Dockerfile                   (relay + pinned Godot match host in one image)
├── authoritative/               (server-run ranked matches; inert unless RANKED_AUTHORITATIVE=1)
│   ├── relay_wire.js            (flag, env knobs, per-socket frame budget, pairing, routing)
│   ├── match_manager.js         (seats, command path, clocks, forfeits, resume-from-log)
│   ├── host_process.js          (spawns/supervises the headless Godot match host)
│   ├── protocol.js              (client message validation, frame cap, rate limits)
│   ├── decks.js                 (loads data/cards + data/starters.json; mirrors DeckManager's deck rules)
│   ├── schema.js                (ranked_matches / _actions / _audit DDL and PgStore)
│   ├── memory_store.js          (the same store interface in memory, for tests)
│   └── settle.js                (idempotent ladder settlement from the server's own result)
├── tools/matches.js             (maintainer CLI: status / history / replay / audit)
└── test/                        (node --test; pg_store.test.js needs a disposable DATABASE_URL.
                                 load.js and e2e_ranked.js are standalone manual runs:
                                 a load test and a two-client end-to-end match)
```

```
client ──websocket──> relay.js ──newline JSON on 127.0.0.1──> match_host.gd (headless Godot)
                         │                                         │
                         └──> Postgres (match log, audit, ladder) <─┘ (rules only; no DB, no accounts)
```
