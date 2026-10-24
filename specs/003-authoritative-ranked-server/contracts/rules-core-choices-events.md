# Contract: Rules-Core Choices and Event Feed (Phase A)

The in-process contract every controller (local play, multiplayer, AI, search,
match host) uses. It generalizes the pending-choice model already in
`GameState` (`request_choice` / `answer_choice` / `choice_options_for`) so that
**no controller contains effect logic any more**.

## Commands (unchanged style — plain values)

```text
play_creature   {actor, card_uid, at_index}
play_stratagem  {actor, card_uid, target_instance_id?, target_player_id?}
attack          {actor, attacker_instance_id, target_instance_id? | target_player_id?}
pilot           {actor, pilot_instance_id, mech_instance_id}        # manual pilot action
end_turn        {actor}
answer_choice   {actor, choice_id, selection}                       # NEW as a command
concede         {actor}                                             # NEW
```

`execute(cmd)` stays the only mutation entry. It returns
`{ok, error?, events: [...]}`. A refused command changes nothing.

## Choice model

At most one choice is open per match (the existing rule: `execute()` refuses
every other command while one is open).

```json
{
  "id": 17,
  "player_id": "a",
  "kind": "target",
  "effect": "challenge",
  "source_instance_id": "g_012#41",
  "step": 1,
  "steps": 1,
  "options": { "minions": ["t_003#9"], "players": [], "cards": [], "card_ids": [] },
  "allow_none": false,
  "default": { "minions": ["t_003#9"] }
}
```

| Field | Meaning |
|---|---|
| `kind` | `target` (minions/heroes), `pick_card` (card uids in a pile, e.g. graveyard), `pick_card_id` (catalog ids, e.g. transform options) |
| `effect` | Stable name of the rule that asked (`challenge`, `on_play_damage`, `swap_health`, `devour`, `pilot`, `rummage`, `tank_shot`, `null`, `buff_friendly`, `overwatch`, `transform`, …) |
| `step`/`steps` | Multi-step effects (swap, yeti-then-target) open step 2 only after step 1 is answered; the core remembers step 1 |
| `options` | Computed **once** by the core (`choice_options_for`). A client may highlight only these. |
| `allow_none` | Whether declining is legal (decline/skip buttons) |
| `default` | The deterministic answer used on timeout and by the AI's fallback. Rule: first legal option in a fixed order (own board left→right, then enemy, then heroes), or "none" when `allow_none`. |

`answer_choice(choice_id, selection)` validates `choice_id` is the open one,
the actor owns it, and `selection` ∈ `options` (or none when allowed). A stale
id, wrong actor, or illegal selection is refused and the choice stays open.

**Effects that currently resolve without asking** (e.g. `challenge_all`'s loop,
the win-buff after a winning challenge) become code inside the core that runs
as part of the originating command or the answering command — never in a
controller.

**Resolve-to-quiescence rule**: after any accepted command the core runs all
queued effects (`PENDING_QUEUES`) until either nothing is pending or a choice
opens. Controllers no longer loop over queues; they only answer the open choice
if it is theirs.

## Event feed

`GameState.events` is an ordered buffer; `execute()` drains it into the result.
Events are **advisory** (animation/log); state is read from the view.

```json
{ "n": 41, "type": "attack",   "attacker": "g_012#41", "target": "t_003#9", "target_hero": "" }
{ "n": 42, "type": "damage",   "target": "t_003#9", "amount": 3, "source": "g_012#41" }
{ "n": 43, "type": "death",    "instance": "t_003#9", "owner": "b", "card_id": "t_003" }
{ "n": 44, "type": "draw",     "owner": "a", "uid": "a-c7", "card_id": "g_001" }
{ "n": 45, "type": "play",     "owner": "a", "uid": "a-c7", "card_id": "g_001", "kind": "creature" }
```

Types: `play`, `attack`, `challenge`, `damage`, `heal`, `death`, `draw`,
`discard_burn`, `transform`, `reinforce`, `buff`, `announce`, `turn_start`,
`turn_end`, `game_over`.

**Per-seat filtering** (host, before sending): a `draw` for the opponent carries
no `uid`/`card_id`; a `play` is public (the card becomes visible when played);
`announce` follows the same rule. No event ever names a card in a hidden zone.

## Determinism requirements (verified by core tests)

1. All rule randomness goes through `GameState.rand_*` / `shuffle_array`.
2. No rule code reads wall-clock time.
3. Ids are counter-based.
4. Given `(seed, decks, first player)` and the same ordered commands, the final
   state hash is identical across runs and across processes.
5. `duplicate_for_sim()` copies never emit events or touch the recorder.

## Controller obligations after Phase A

| Controller | Allowed | Not allowed |
|---|---|---|
| `game_manager.gd` (local) | send commands, render events, answer *its* choices from clicks | call `apply_*`, mutate state, decide effect outcomes |
| `mp_game_manager.gd` (casual/campaign) | same | same |
| `ai_controller.gd` / `headless_turn.gd` | pick commands and answers (policy) | contain effect logic |
| `remote_match_client.gd` | send commands, render views/events | hold any rules |

A `--core-tests` check fails the build if a controller file calls a rules
mutator directly (`apply_*`, `take_damage`, `hero_health`, `_remove_dead_minions`).
