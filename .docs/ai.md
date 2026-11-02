# AI

## Versioned Moon bots

`data/bot_profiles.json` defines Io 1.0 (level 10 tempo), Callisto 1.0 (level 8 combo), Europa 1.0 (level 8 aggro), and Ganymede 1.0 (level 1 random mistakes). `MoonBots` drafts published decks through DeckManager and plays UI-free games with GameState/HeadlessTurn. MCTS accepts an optional style: named search bots score both the immediate position and neutral-greedy future; empty style preserves the ordinary opponent's existing search/evaluation. Ganymede uses random legal actions rather than running a clever search at a lower budget. Named search bots take immediate wins before applying style preferences. The profiles can run as isolated simulation participants or dedicated ranked accounts.

The standalone simulation worker rotates bot pairings and Standard AI, checkpoints completed games and stores them in a separate table. A separate ranked worker provisions four server-owned accounts and launches one `--ranked-bots` process with four ordinary ranked connections. They play from filtered views with public uncertainty priors, automatically requeue, and use normal authoritative matchmaking/rewards. Ranked records snapshot profile/rules/engine versions under mode `ranked_bots`. Their genuine ranked results contribute to the default combined stats page and card aggregates; filtered human-only views and isolated simulations remain separate. The normal queue's widening Elo band is uncapped, so strong bots can still meet Ganymede after waiting. See [Moon bots operations and website contract](../server/MOON_BOTS.md) for activation, reconnect/stop behavior, tests and limits. `--bot-tests` includes deterministic hidden-information scenarios; `--bot-match` remains the isolated simulation entrypoint.

`AIController.POLICY_VERSION` versions the ranked AI policy independently of card/rules changes. New ranked-AI summaries snapshot this version and the actual first-player choice, allowing the deck matchup API to separate playtest cohorts. Increment the policy version when future AI behavior changes; historical reports without a version remain unknown rather than being inferred from difficulty.

The opponent AI is a heuristic-guided Monte Carlo Tree Search (MCTS), not a hand-coded priority list. `AIController` (`scripts/game/ai_controller.gd`) still owns turn pacing and Board/animation glue, but its decisions come from `MCTSEngine` (`scripts/game/mcts_ai.gd`), which searches over `HeadlessTurn` (`scripts/game/headless_turn.gd`) — a UI-free, cloneable turn executor built on the same `GameState` used by the real game.

## Why not classic random-rollout MCTS

Random playouts to a finished game are slow and play badly in this game (long matches, hidden opponent hand). Instead, MCTS searches the real combinatorial space that matters in a turn-based game — the sequence of atomic actions (which cards to play, in what order, which attacks to make) within the *current* turn — and scores leaves with a heuristic evaluator instead of simulating to game-over. The opponent's predicted response (and any further look-ahead turns) is filled in with a fast greedy policy rather than also being tree-searched.

## Architecture

- **AIHeuristics** scores monotonic hero health (health losses below 15 are worse, not beneficial), board stats and persistent mechanics, own-hand affordability, and a small amount of public graveyard reuse potential when a retrieval source exists. A possible retrieval is worth less than a card already in hand; an on-play effect already used on the board is not credited again. Enemy hand contents are not read by this evaluator (only the count); the existing opponent rollout model still operates on the full simulation state and is not a hidden-information model.
- **HeadlessTurn** exposes creature plays, meaningful stratagem targets, attacks, Pilot pairings, end-turn and rules-provided pending-choice answers. Own target/rummage/transform options and permitted declines are separate search actions, including chained choices. Opponent-owned reactive choices use the opponent policy instead of letting the searching side choose a cooperative answer. CardData owns the target-shape predicates shared with Board; printed friendly buffs retain friendly AI targets. GameState validation/execution remains authoritative.
- **apply_action(gs, action, resolve_choices = true)** preserves the completed-action contract for greedy callers. Search and MCTSBenchmark pass false, leaving choices open for the next searched answer. The rollout choice policy compares actual cloned outcomes of every offered answer; the old heuristic is only a tie preference. The rollout's card-play/combat policy is still cheap and approximate; it does not remove branches from the main search.
- **MCTSEngine** clones real rules states and searches atomic sequences. It orders expansion by the actual evaluated outcome of each legal action, retaining all alternatives. Rewards are bounded in [-1, 1], with UCT exploration constant 0.35. A terminal win reached in the tree or a fully executed own-turn continuation takes precedence over visit count; validated continuation commands are retained across decisions and discarded with the tree when actual state differs. A continuation stops at any other player's choice, so it cannot rely on a cooperative answer. Later rollout wins are predictions, discounted by distance, rather than 100000-point certainties that can starve immediate winning branches. Siblings share a rollout horizon measured in individual player turns, including an end-turn action already executed by a child.
- **AIController / GameManager** share one search engine across the AI turn and its pending choices. The controller advances after each real action; the live choice driver searches, executes and advances each answer. Reactive AI choices on a human turn use a fresh engine; human choices still use Board.prompt_choice. Every resumed search checks the current state. The live driver binds the exact match and Board identities across awaits, then checks choice ID and owner before answering; a replacement match cannot reuse an old answer. Draw announcements also stop when their match is replaced. Existing presentation and command validation handle the real effects.

There are no production card-ID strategies. Slime Launcher is a regression fixture demonstrating general sacrifice/retrieval/replay planning, alongside ready-attacker buffs, mandatory transforms, chained choices and no-payoff sacrifices.

## Difficulty levels (1-10)

`AIController.ai_level` (default 5) selects a row of `MCTSEngine.AI_LEVEL_CONFIG`: `iterations` (search budget), `depth_plies` (how many additional full turns get simulated forward before scoring a leaf), and `mistake_rate` (chance to discard the search's pick for a uniformly random *legal* action instead). Level 10 = full node budget, zero deliberate mistakes. Each decision also has a wall-clock ceiling of 100ms × level (1000ms at level 10), checked between simulations. A single simulation cannot be preempted, so observed time can exceed the ceiling by that work and a frame. Follow-up searches retain the 24-iteration ceiling. Search yields after eight iterations or about 8ms of accumulated work, whichever comes first. One engine, no forked "easy mode" logic — difficulty uses those policy settings plus the elapsed-time ceiling.

## Ranked mode

Ranked searches for a human opponent, then falls back to a random-faction archetype AI when nobody is found. Ranked progress belongs to the signed-in account and is authoritative on the server:

- **`Auth`** (autoload, `scripts/game/auth.gd`) holds `rank_bracket`/`rank_in_legend`/`rank_legend_rating`/`rank_lp`/`ranked_win_streak`/`ranked_wins`/`ranked_losses`, fetched on login/register/resume and updated via `Auth.report_ranked_result(won)` → a `report_ranked_result` relay message → `server/relay.js`'s `nextRankState()` (the authoritative progression math) → the `players` table.
- **`RankedProgress`** (`scripts/game/ranked_progress.gd`) is a stateless static-math utility, not an autoload — it holds no state of its own, only the display/derivation math over whatever `Auth` currently reports:
  - **Bracketed tiers** — `TIER_NAMES` (Orbital, Lunar, Planetary, Solar, Nebular, Galactic, Cosmic) × `SUB_RANKS` (III lowest → I highest) = 21 discrete brackets (`bracket_index` 0-20). Progress within a bracket is an LP bar 0-100 (`LP_PER_BRACKET`): a win adds `LP_WIN_BASE` (34), or `LP_WIN_STREAK` (45) once `ranked_win_streak` hits `LP_WIN_STREAK_THRESHOLD` (3+ wins in a row); hitting 100 promotes to the next bracket, carrying the LP overflow. A loss subtracts `LP_LOSS` (20), floored at 0 — losses never demote a bracket.
  - **Legend-style tiers** — once Cosmic I is beaten at 100 LP, `in_legend` becomes true (carrying the LP overflow into `legend_rating`). Progress becomes a single continuous `legend_rating` (+/-25 per game, no streak bonus); `LEGEND_TIER_NAMES` (Superluminal, Celestial, Universal) are just readable bands over that rating via `LEGEND_TIER_SPAN`, with Universal (highest) uncapped. A loss that would push `legend_rating` below 0 while still in the lowest band (Superluminal) demotes back out to Cosmic I, landing LP carrying the negative overflow the same way bracket promotion does.
  - **AI difficulty** uses one level per named tier: Orbital 3, Lunar 4, Planetary 5, Solar 6, Nebular 7, Galactic 8 and Cosmic 9. All three sub-ranks share their tier level: `3 + floor(clamp(bracket_index, 0, 20) / 3)`. All Legend tiers use 10. Manual Easy/Medium/Hard remains 1/5/10. The actual level and AI policy version are recorded with each ranked-AI summary, so compare matching cohorts rather than mixing difficulty levels.

`main.gd` re-reads `Auth.rank_*` (and rolls a fresh random opponent) on every new ranked match — including "Play Again" — so each match rolls a fresh archetype deck while deriving difficulty from the current rank. This is independent of the multiplayer path (`mp_game_manager.gd`/`server/relay.js`'s lobby code), which has no AI involvement — same relay, separate message types.

**VS AI** (non-ranked) and Campaign have manual difficulty pickers: Easy/Medium/Hard map to `ai_level` 1/5/10. Each screen stores the selection in a shared Dictionary so the start callback receives the most recent choice; assigning a captured integer inside another GDScript lambda does not update that callback.

## Verification

The planning regression runs with `GODOT_BIN=<godot> node --test server/test/ai_planning.test.js`: the real engine searches lethal and sacrifice/replay sequences across fixed seeds, compares affordable rummage alternatives, preserves chained/mandatory choices and clone isolation, and executes wins through AIController/GameManager/Board. Its user data is isolated from normal saves.

Pilot actions use the same validated `GameState.execute()` command in search, rollout, and the live AI controller. `GODOT_BIN=<godot> node --test server/test/ai_controls.test.js` exercises difficulty changes through the actual menu callbacks, ranked fallback at all 21 brackets plus legend and clamping, and a Pilot-to-Rush lethal through search and the live controller without opening a relay. `--core-tests` covers legal Pilot targets, simulated outcomes, and isolation from the live board.

`MCTSBenchmark` (`scripts/game/mcts_benchmark.gd`) runs headless AI-vs-AI games (random decks, no Board/UI) pitting any two policies — an `MCTSEngine` level or the legacy greedy policy — against each other and reports win rate, to check higher levels actually beat lower levels before trusting them in-game. Invoke it via `main.gd`'s `_run_mcts_benchmark_cli()` dev hook: `godot --headless --path <project> -- --mcts-benchmark` (a bare `--script` entry point doesn't work here since autoloads like `DeckManager`/`CardDatabase` aren't initialized outside the real project scene tree). `--mcts-timing` times a single `choose_action()` call per level — useful smoke tests any time `MCTSEngine`'s async/yield behavior changes. Note the benchmark is noisy at its default 6-games-with-random-decks sample size — a weaker level occasionally beating a stronger one there is expected variance, not necessarily a bug (confirmed by comparing against a pre-change baseline when adding tree reuse above).

`--live-ai-test` (`main.gd`'s `_run_live_ai_test_cli()`) drives one real game through the actual `Board`/`GameManagerAutoload`/`AIController` glue instead of the headless `HeadlessTurn` path — tweens, `board.refresh()`, `board.log_action()` and all — forcing the human side to end its turn immediately each round so the AI's turn (the one place the other CLI hooks don't exercise) repeats back-to-back. It flags a stall via a structural state fingerprint (board/hand/health), not `turn_number`/`active_player_id`, since those legitimately hold steady for the whole multi-action span of a real AI turn. This is the tool that originally reproduced the "AI turn reads as a hang" issue tree reuse (above) fixes: `godot --headless --path <project> -- --live-ai-test`.

## Actions are values, not objects

`list_legal_actions()` emits dictionaries that name entities by `card_uid` /
`attacker_instance_id` / `target_instance_id`, never live `CardData` or
`Minion` objects, and `apply_action()` hands them to `GameState.execute()`,
which resolves them against the state being mutated.

That is what makes search expansion sound: actions are enumerated against a
parent node and applied to a freshly copied child. While actions carried
objects, an attack enumerated on the parent mutated the *parent's* minions
while the child's death cleanup inspected the child, and a card play failed to
leave the child's hand because `Array.erase()` was handed a different instance.
A `_translate_to_real()` shim patched the boundary on the way out of the
search but did nothing for parent-to-child expansion; it is gone.

`apply_action()` returns `false` when a command is rejected (an action
enumerated elsewhere can legitimately be illegal here) — callers must not
treat that as a mutation.

## Randomness

`MCTSEngine._search_rng` is the search's own generator — expansion order and
the deliberate-mistake roll. It is separate from the match's `GameState.rng`
on purpose: changing the search budget, or searching at all, must not change
what the match itself rolls. Both are separate from the global stream.

## Tree-reuse fingerprint

Search nodes hold weak parent references so unused branches release their cloned states. Reuse combines GameState.state_hash (choices, queues, zones, board order/readiness, counters and match RNG) with runtime card definition stats, pilot bonuses and per-player minion counters omitted by the replay digest. Different choice options/amounts/IDs and different graveyard contents cannot share a reused node. A mismatch discards the tree and rebuilds from current legal actions. This fingerprint is internal; it does not change replay hashes or the public protocol.

## Extending the AI

Game effects belong in GameState/Abilities. AI valuation and rollout guidance belong in AIHeuristics; action enumeration and rollout completion belong in HeadlessTurn. Keep choice options authoritative in the rules and target-shape metadata shared with Board. Do not add card-specific plans or a second effects implementation in AIController.
