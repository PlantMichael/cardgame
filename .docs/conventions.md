# Conventions & Gotchas

## GDScript Style

- Use **tabs**, not spaces, for indentation
- All game logic lives in `game_state.gd` — `board.gd` is purely visual

## Identity & IDs

- `Minion.instance_id` is the runtime identity for attack targeting — format: `"{card_id}_{randi()}"`
- Local player ID: `"player_1"`
- Opponent/AI player ID: `"player_2"`

## Board Refresh

- `board.refresh()` must be called after every `GameState` mutation to sync the UI
- It performs a full teardown-and-rebuild of all card/minion nodes — there is no incremental update
- `await get_tree().process_frame` twice before `refresh()` after playing cards to let `queue_free` process

## Input Handling

- `board.gd` handles all input via `_input()` checking global rects — **not** via signal connections on nodes
- `Area2D` input doesn't work reliably inside `Control` containers

## Scene Structure

- Cards in hand are wrapped in `Button` nodes inside `HBoxContainer`s
- Cards on board are wrapped in `Control` nodes inside `HBoxContainer`s
- Card scenes are `Area2D` with `Control` children — positions are managed by containers, not manually

## Stratagem Targeting

Resolved in `Board._on_card_dropped()` by hit-testing node rects under the mouse. The target `Minion` object (or player_id string) is then passed through the `action_play_stratagem` signal.

## Game Limits

| Constant | Value |
|---|---|
| `PlayerState.MAX_BOARD_SIZE` | 7 |
| `PlayerState.MAX_HAND_SIZE` | 10 |
| `PlayerState.MAX_MANA` | 10 |
| Starting hero health | 30 |
