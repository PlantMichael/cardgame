# AI Controller

`AIController` (`scripts/game/ai_controller.gd`) runs after the player ends their turn.

## Decision Priority

1. **Lethal check** — if the player hero can be killed this turn, do it
2. **Trades** — attack opponent minions to remove threats
3. **Go face** — attack the opponent hero directly

## Behavior Details

- Uses `THINK_DELAY = 0.6s` pauses between actions to feel natural
- Calls `board.log_action()` to report each play to the combat log
- Handles the `RUSH` ability when deciding which minions can attack immediately
- Handles the `CHALLENGE` ability: after playing a creature with Challenge, picks the best trade target on the player's board and calls `game_state.apply_challenge()`
- Handles the `ON_PLAY_YETI_CHALLENGE` ability: directs a friendly Yeti to challenge after a trigger card is played
- Handles the `PILOT` ability: after playing a Pilot, buffs the strongest eligible Mech
- Handles on-play damage: targets the highest-attack enemy minion it can kill; otherwise targets the biggest threat
- Filters Cloaked and Ambush minions from all stratagem target picks
- Filters Ambush minions from attack candidates and CHALLENGE_ALL loops
- Handles `ON_PLAY_DEVOUR_FRIENDLY`: sacrifices the lowest-value (attack+health) friendly minion
- Handles `ON_PLAY_SWAP_FRIENDLY_HEALTH`: gives health to highest-attack minion, takes from lowest-value minion
- Plays `buff_all_friendly_attack` stratagems (e.g. Commanding Shout) when it has creatures on board

## Extending AI

When adding new abilities that affect combat decisions (e.g., a minion that gains bonuses for attacking), add handling in `ai_controller.gd` so the AI can factor those into its priority calculations.
