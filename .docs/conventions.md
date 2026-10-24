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

## Card Sizes

Every card on screen is the same `Card.tscn`, shown at one of exactly four presets — never an ad-hoc scale:

| Preset | Scale / pixels | Used for |
|---|---|---|
| `Card.Size.SMALL` | `0.46` / 101×147 | the deck builder's collection grid |
| `Card.Size.BOARD` | `0.64` / 141×205 | the battlefield (both board rows) |
| `Card.Size.MEDIUM` | `0.62` / 136×198 | the hand, and the graveyard / mulligan / rummage / transform pickers |
| `Card.Size.LARGE` | `1.20` / 264×384 | hover previews (board, deck builder, card list) and pack reveals |

- `Card.CARD_SIZE` (220×320) is the design space every node rect in `Card.tscn` is laid out in. Nothing draws at that size; a preset is applied as a uniform `scale` on the whole node.
- Those rects are the frame art's own slots, measured off the 1042×1510 PNGs (averaging all six frames so per-color texture noise cancels and only the metal bevels remain), then scaled by 220/1042 and 320/1510. Re-measure rather than eyeball if the frame art is ever redrawn.
- The description box is the one rect deliberately **inset** from its measured slot (4px all round). Sized to the slot exactly, the longest descriptions fit by arithmetic but drew with no margin, so their 3px glyph outline overlapped the panel bevel and read as text spilling out. Text elements that carry an outline need that margin built in.
- Stratagems use their own frames (`assets/cardgame/Strategems/stratagem-<color>.png`, same 1042×1510 canvas). They share every slot with the creature frames except the description panel, which runs down through where the attack/health boxes would be. So `card.gd` swaps the frame and the description box by card type: `DESCRIPTION_BOX_DEFAULT` (36,191 148×60, must match `DescriptionLabel` in `Card.tscn`) vs `DESCRIPTION_BOX_STRATAGEM` (36,191 148×107; the panel's bottom bevel sits at 1421px vs 1199px in the art, +47 in design space). Card size is identical for both.
- Use `card.apply_size(Card.Size.X)`, or `Card.SCALE_X` / `Card.PIXELS_X` when a `const` is needed (a wrapper's `custom_minimum_size`, say) — GDScript won't call a function in a constant expression.
- The one deliberate exception is the deck builder's deck-list strip (`DECK_W`), which is a column of slivers rather than cards meant to be read.
- `rendering/textures/canvas_textures/default_texture_filter=2` (Nearest Mipmap) is set project-wide, and `mipmaps/generate=true` is on for everything in `assets/card_assets/` and the per-faction card-art folders. Both halves matter: the art is authored far bigger than the slot it lands in (a 1254px mana orb into a 29-72px slot, a 1042px frame into 132-330px), so without mipmaps any filter is just subsampling a fraction of the texels — nearest turns the orb into noise, linear turns it into mush. Mipmaps pick a correctly pre-averaged level; nearest then keeps it crisp rather than soft.
- So: **any new card-facing art needs `mipmaps/generate=true` on its import**, or it will look wrong at card sizes. Don't override `texture_filter` per node without a reason.

## Window shape (web)

Board positions are absolute in a 1920x1080 design space. In the browser the viewport can be larger than that (expand aspect, set in `main.gd`), so any code placing something from a viewport size or a mouse/`get_global_rect()` position must use **global** coordinates (`global_position`), not `position` - `Board` is offset to center itself and the two differ there. Previews and keyword blocks already do.

## Rules commands

- Player actions enter the rules through `GameState.execute(cmd)` only — human,
  AI and multiplayer share it. Do not call `play_creature()` / `play_stratagem()`
  / `attack()` from an adapter; those are the commit step behind validation.
- Commands are plain values naming entities by `uid` / `instance_id`. Never put
  a `CardData` or `Minion` object in one: it cannot cross a state copy, which is
  exactly what AI search does.
- `validate()` must stay side-effect free; `execute()` commits only after it
  passes, so a rejected command leaves the state untouched.
- Never `Resource.duplicate()` a `CardData` — see [Card Data](card-data.md).
  Use `clone_instance()` (same card) or `new_instance(uid)` (new card).
- Minting identity (cards or minions) uses counters, not `randi()`: creating an
  entity must not consume gameplay randomness, or copying a state would shift
  the real match's later rolls.

## Randomness

- A rule's roll uses the match generator: `GameState.rand_index()`,
  `rand_pick()`, `shuffle_array()`. Never `randi()`, `randf()` or
  `Array.shuffle()` inside the rules — those are the global stream, and a
  simulation copy rolling on it changes what the real match does next.
- `Array.shuffle()` in menu, deck-builder or campaign code is fine; that is
  outside a match.

## Tests

`godot --headless --path <checkout> -- --core-tests` runs the rules-core
regression suite (`scripts/game/core_tests.gd`) and **exits with the failure
count**, so pass/fail is machine-detectable. `-- --selftest-fail` is a
deliberate failure for checking the harness itself reports one. The older
`--fatigue-test` / `--tank-test` / `--haven-test` / `--newcards-test` /
`--locations-test` / `--shop-test` hooks still print `RESULT: PASS|FAIL` but
always exit 0 — treat their logs, not their exit status, as the result.

A headless hook that drives a real match must set `Board.auto_confirm_mulligan`
before starting it. The mulligan blocks on a button press no headless run can
deliver, and a hook that does not set it will sit in the mulligan and report
whatever its own stall detector concludes — `--live-ai-test` spent a long time
blaming the AI for exactly this.

## Stratagem Targeting

Resolved in `Board._on_card_dropped()` by hit-testing node rects under the mouse. The target `Minion` object (or player_id string) is then passed through the `action_play_stratagem` signal.

## Game Limits

| Constant | Value |
|---|---|
| `PlayerState.MAX_BOARD_SIZE` | 7 |
| `PlayerState.MAX_HAND_SIZE` | 10 |
| `PlayerState.MAX_MANA` | 10 |
| Starting hero health | 30 |
