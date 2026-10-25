---

description: "Task list for Server-Authoritative Ranked Matches"
---

# Tasks: Server-Authoritative Ranked Matches

**Input**: Design documents from `specs/003-authoritative-ranked-server/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Goal in one line**: players must not be able to modify game logic. After this
list is done, every rule of a ranked match is decided by the server running the
shipped GDScript rules; a modified client can only send commands that the
server validates.

**Tests**: The plan names its test suites explicitly (`--core-tests` additions,
`--parity-test`, `node --test server/test/`, a load script), so test tasks are
included and placed before the code they cover.

**Organization**: Phase 2 (Foundational) is the plan's **Phase A — complete the
rules core**. It blocks every user story, but it is shippable on its own (no
server needed) and fixes an existing violation of Constitution Principle I.
User stories then follow the spec priorities (US1/US2 = P1, US3/US4 = P2,
US5 = P3). The whole server-run path stays behind `RANKED_AUTHORITATIVE`
(default off) until the end.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1–US5 (user-story phases only)
- Paths are relative to the repository root. GDScript uses **tabs**.
- Most Phase 2 tasks edit `game_state.gd`/`abilities.gd`, so they are
  deliberately **not** marked [P].

---

## Phase 1: Setup

**Purpose**: Scaffolding and the two de-risking spikes the plan calls out.

- [X] T001 Create `scripts/game/rules_version.gd` with `const RULES_VERSION := 1` (integer, bumped whenever rules or `data/cards/*.json` change) and add a comment naming the bump rule; reference it from `.docs/conventions.md` in T104.
- [X] T002 [P] Create the directory `server/authoritative/` with empty module stubs `host_process.js`, `match_manager.js`, `protocol.js`, `settle.js`, `schema.js` (CommonJS, matching `server/relay.js`) and add a `"test": "node --test test/"` script to `server/package.json`.
- [X] T003 [P] Create `server/test/helpers.js` with helpers to start a disposable Postgres connection from `DATABASE_URL`, spawn the Godot match host from `GODOT_BIN`, and open fake websocket clients; document required env vars at the top of the file.
- [X] T004 Spike — headless safety: run `godot --headless --path . -- --core-tests` with network unavailable and confirm the `Net`, `Auth` and `Economy` autoloads (`project.godot`) do nothing at startup without a connection; record findings (and any autoload that must be guarded, e.g. skip when `--match-host` is in `OS.get_cmdline_user_args()`) in `specs/003-authoritative-ranked-server/research.md` §7.
- [ ] T005 (written; build still unproven — Docker Desktop's engine would not start on the machine this was attempted on. `.dockerignore` added so the build context is the project rather than the 2.2 GB `.git` + 145 MB `.godot`; the 5 case-mismatched card art paths that would break on a case-sensitive filesystem are fixed) Spike — container: write `server/Dockerfile` (Node + a version-pinned Godot Linux headless binary matching the editor version, `project.godot`, `scripts/`, `data/`, minimum `assets/`, and a build-time `godot --headless --import`), build it, and record image size and cold-start time in `research.md` §7; if textures preloaded by `card.gd`/`ranked_progress.gd` force large assets into the image, note whether to split them or export a server PCK.

---

## Phase 2: Foundational — Complete the Rules Core (plan Phase A)

**Purpose**: After this phase `GameState` alone decides every rule and every
decision; no controller contains effect logic. This is what makes it safe to
host and the reason players can no longer influence rules.

**⚠️ CRITICAL**: No user story can start until this phase passes `--core-tests`
and `--parity-test`.

### Core mechanisms

- [X] T006 Extend the choice model in `scripts/game/game_state.gd` per [contracts/rules-core-choices-events.md](./contracts/rules-core-choices-events.md): choice `kind` (`target`/`pick_card`/`pick_card_id`), `effect`, `step`/`steps`, `options` (minions, players, card uids, card ids), `allow_none`, and a deterministic `default`; keep `request_choice`, `answer_choice` (now also a command), `choice_options_for` as the only entry points and keep refusing every other command while a choice is open.
- [X] T007 In `scripts/game/game_state.gd` add `CMD_ANSWER_CHOICE` and `CMD_CONCEDE` to `validate()`/`execute()`; `answer_choice` validates "open choice id, owned by actor, selection ∈ options"; `concede` ends the match with the actor as loser; both return `{ok, error?, events}`.
- [X] T008 In `scripts/game/game_state.gd` add the event feed: an ordered `events` buffer with types `play, attack, challenge, damage, heal, death, draw, discard_burn, transform, reinforce, buff, announce, turn_start, turn_end, game_over`; append at the existing chokepoints (`play_creature`, `play_stratagem`, `attack`, `apply_challenge`, `_remove_dead_minions`, `PlayerState.draw_card`, heal/buff helpers); `execute()` drains and returns it; `duplicate_for_sim()` MUST leave the buffer empty and never emit.
- [X] T009 In `scripts/game/game_state.gd` add `resolve_to_quiescence()`: after any accepted command, run `PENDING_QUEUES` repeatedly until nothing is pending or a choice opens; `execute()` calls it so no controller loops over queues any more.
- [X] T010 In `scripts/game/game_state.gd` add `resolve_defaults(actor_id)` (answers the open choice with its stored `default`, ends the actor's turn, tags the result `timeout_default`) using the fixed ordering "own board left→right, then enemy, then heroes".
- [X] T011 In `scripts/game/game_state.gd` add `state_hash()` (stable hash over the full state including hidden zones, generator state and pending choice) and `filter_events_for(seat, events)` (opponent `draw` carries no uid/card id; `play`/`announce` are public; no event names a hidden-zone card); extend `to_net_dict(for_player_id)` so `pending_choice` appears only for the seat that must answer it.
- [X] T012 [P] Add a determinism guard to `scripts/game/core_tests.gd`: fail if any file under `scripts/game/` rules scripts (`game_state.gd`, `player_state.gd`, `minion.gd`, `abilities.gd`) calls `randi(`, `randf(`, `.shuffle(` or reads `Time.`/`OS.get_ticks`; fix any hit found by routing it through `GameState.rand_*`/`shuffle_array`.
- [X] T013 [P] Add core tests in `scripts/game/core_tests.gd` for T006–T011: choice open/answer/refuse (stale id, wrong actor, illegal selection), `concede`, event emission and per-seat filtering, `resolve_to_quiescence`, `resolve_defaults`, `state_hash` equality across two runs from the same seed and difference after any action, and "sim copies emit nothing".

### Migrate every effect into the core (one family per task: move the logic out of the controllers, request a choice, add a core test)

- [X] T014 Migrate **on-play damage** (`on_play_damage_N`; today `game_manager._run_player_on_play`, `mp_game_manager._host_run_on_play`, `ai_controller._handle_on_play_effects`, `headless_turn._handle_on_play`) into `scripts/game/abilities.gd` + `game_state.gd` as a `target` choice (enemy minions or heroes) with the damage applied through `apply_on_play_damage`; add a test in `scripts/game/core_tests.gd`.
- [X] T015 Migrate **challenge** and **challenge-win buff** (`ON_PLAY_CHALLENGE_WIN_BUFF`: the +1/+1 on win currently applied in `game_manager.gd`) into the core as one `target` choice whose resolution applies `apply_challenge` and the buff; test in `scripts/game/core_tests.gd`.
- [X] T016 Migrate **yeti challenge**, **Icewhip `force_challenge`** and **overwatch** (`pending_overwatch_challenges`) into the core as a two-step choice (friendly Yeti → enemy target, `step`/`steps`); test in `scripts/game/core_tests.gd`.
- [X] T017 Migrate **`challenge_all` (Rampage)** into the core as an automatic loop inside the originating command (no choice), resolving each challenge fully before the next; test in `scripts/game/core_tests.gd`.
- [X] T018 Migrate **pilot** (`ON_PLAY_PILOT_MECH` free pilot and the manual `pilot` command / `_host_on_pilot`) into the core as a `target` choice over friendly un-piloted Mechs plus a validated `pilot` command; test in `scripts/game/core_tests.gd`.
- [X] T019 Migrate **swap friendly health** (`ON_PLAY_SWAP_FRIENDLY_HEALTH`) into the core as a two-step choice; test in `scripts/game/core_tests.gd`.
- [X] T020 Migrate **devour friendly** (`ON_PLAY_DEVOUR_FRIENDLY`) into the core as a `target` choice over friendly minions other than the source; test in `scripts/game/core_tests.gd`.
- [X] T021 Migrate the **transform choice** (`ON_PLAY_TRANSFORM_CHOICE`, today `board.show_transform_picker`) into the core as a `pick_card_id` choice over `transform_choices`; test in `scripts/game/core_tests.gd`.
- [X] T022 Migrate the **rummage family** (`pending_rummages`: rummage, rummage-and-play, spell rummage, death rummage, mech rummage, return-stratagem; today `board.show_graveyard_picker`) into the core as a `pick_card` choice over graveyard card uids with `allow_none`; keep discount/play rules in `complete_rummage`; test in `scripts/game/core_tests.gd`.
- [X] T023 Migrate **tank shots** and **on-reinforce damage** (`pending_tank_shots`, `pending_on_reinforce_damages`) into the core as `target` choices; test in `scripts/game/core_tests.gd`.
- [X] T024 Migrate **null/silence** (`pending_nulls`) into the core as a `target` choice over non-cloaked minions; test in `scripts/game/core_tests.gd`.
- [X] T025 Migrate **buff-friendly-health** and **tank specialist** (`pending_buff_friendly_health`, `pending_tank_specialist_buffs`) and the **stratagem second prompts** (blood transfusion, sanguine, in `mp_game_manager._host_stratagem_followup*`) into the core as `target` choices over friendly minions; test in `scripts/game/core_tests.gd`.

### Make every controller a thin caller

- [X] T026 Reduce `scripts/game/game_manager.gd` to a command sender and renderer: replace `_run_player_on_play`, `_process_pending_*` and the stratagem follow-ups with "send `answer_choice` from the player's click, animate from returned events, call `board.refresh()`"; delete the rules that moved.
- [X] T027 Reduce the host/guest paths in `scripts/game/mp_game_manager.gd` the same way (`_host_run_on_play`, `_host_process_*`, `_host_stratagem_followup*`), keeping the existing message shapes for casual/campaign multiplayer working.
- [X] T028 Reduce `scripts/game/ai_controller.gd` (`_handle_on_play_effects`, `_play_stratagem_action`, …) to policy: pick commands and choice answers via `AIHeuristics`, apply them through `GameState.execute`, animate from events.
- [X] T029 Make `scripts/game/headless_turn.gd` a policy-only layer: delete `_handle_on_play` and the private effect copies, and use `answer_pending_choice` over the core's choices (`MCTSEngine` and `--mcts-benchmark` must still run).
- [X] T030 [P] Add the controller-purity check to `scripts/game/core_tests.gd`: fail if `game_manager.gd`, `mp_game_manager.gd`, `ai_controller.gd`, `remote_match_client.gd` or `board.gd` call a rules mutator directly (`apply_*`, `take_damage(`, `hero_health`, `_remove_dead_minions`, `complete_rummage`).

### Prove it

- [X] T031 Add the `--parity-test` hook in `scripts/game/main.gd` (beside the existing `--newcards-test`/`--locations-test` hooks) that plays 1,000 seeded AI-vs-AI matches, records `(seed, decks, command log)`, replays each into a fresh `GameState`, and requires identical `state_hash` per step and identical winners; exit code = failure count.
- [X] T032 Run `godot --headless --path . -- --core-tests`, `--parity-test`, `--newcards-test`, `--locations-test`, `--tank-test`, `--campaign-test` and `--mcts-benchmark`; fix regressions; note results in `.docs/status.md`.
- [X] T033 Update `.docs/game-logic.md`, `.docs/abilities.md` and `.docs/conventions.md` to describe the completed choice model, event feed and "controllers hold no rules" rule (Constitution Principle IV).

**Checkpoint**: The rules are in one place, deterministic and replayable.
Phase A can be merged and shipped before anything below.

---

## Phase 3: User Story 1 — Play a Ranked Match Nobody Can Cheat (Priority: P1) 🎯 MVP

**Goal**: A ranked match between two normal clients runs entirely on the
server's rules; altered clients cannot change rules, see hidden cards or fake a
result.

**Independent Test**: With `RANKED_AUTHORITATIVE=1`, play a full ranked match
between two clients, then repeat with a client modified to send illegal actions,
claim a win, read the opponent's hand, and use altered local card data — all
fail and the result is unaffected (quickstart Phase B).

### Tests for User Story 1 (write first; they fail until the code exists)

- [X] T034 [P] [US1] `server/test/protocol.test.js`: spawn the match host, `hello`/`create`/`command`/`view`, assert both seats receive views and events and that refused commands do not advance `seq`.
- [X] T035 [P] [US1] `server/test/hidden_info.test.js`: for every outbound frame to each seat across a scripted match, assert it contains no hand contents, deck contents/order, or unrevealed draw of the other seat (SC-001).
- [X] T036 [P] [US1] `server/test/cheating.test.js`: ≥ 200 cases — illegal action, out of turn, stale/duplicate `client_seq`, forged seat, forged winner, client-supplied deck, another player's `match_id`, oversized or malformed frame, `report_ranked_result` for a server-run match, **and a client whose local `data/cards` has cost-0 cards or altered stats**; assert none changes state or the result and each is audited.

### Implementation for User Story 1

- [X] T037 [P] [US1] Create `server/authoritative/schema.js` with `CREATE TABLE IF NOT EXISTS` DDL for `ranked_matches`, `ranked_match_actions` (PK `(match_id, seq)`) and `ranked_match_audit` exactly as in [data-model.md](./data-model.md) (including `seed BIGINT`, `deck_a`/`deck_b JSONB`, `state_hash TEXT`, status values `waiting, active, finished, voided`), and call it from `initDb()` in `server/relay.js`.
- [X] T038 [US1] Create `scripts/game/match_host.gd`: a `--match-host` mode (hook in `scripts/game/main.gd`, never instantiating `Board`, UI, or network autoload connections) that runs a `TCPServer` bound to `127.0.0.1`, requires a `hello` frame with the secret from the environment, and implements `hello`, `create`, `command`, `view`, `stats`, `drop` from [contracts/match-host-ipc.md](./contracts/match-host-ipc.md); replies include per-seat `views`, filtered `events`, `seq`, `state_hash`, and `expect_seq` enforcement.
- [X] T039 [US1] In `scripts/game/match_host.gd` build `create` from `(seed, first_seat, deck_a, deck_b, rules_version)`: reject a `rules_version` ≠ `RULES_VERSION`, validate decks against `CardDatabase` (unknown id, token), call `GameState.set_gameplay_seed(seed)`, run the opening deal, and open the mulligan state for both seats (mulligan answered through a command on the same ordered stream).
- [X] T040 [US1] Create `server/authoritative/host_process.js`: spawn `GODOT_BIN --headless --path <project> -- --match-host` with a random per-boot secret, connect, `hello`, expose `request(op, payload)` with `rid` correlation, ping `stats` every 5 s, restart on three misses, and report `ready`/`down`.
- [X] T041 [US1] Create `server/authoritative/protocol.js`: schema validation for `match_join`, `match_command`, `match_mulligan`, `match_concede`, `match_ping` per [contracts/client-match-protocol.md](./contracts/client-match-protocol.md); 8 KB frame cap, 20 actions/s per seat, strict field allow-lists; every rejection returns a generic reason and writes `ranked_match_audit`.
- [X] T042 [US1] Create `server/authoritative/match_manager.js`: on pairing create the match (server-chosen `rk_` id, `crypto` seed, first seat), **load each deck from the `decks` table by the queued `deck_name` and validate it against the server's `data/cards` (ids exist, not tokens, copy/size/faction rules mirrored from `scripts/game/deck_manager.gd`)**, insert `ranked_matches`, call host `create`, and keep the in-memory Match Session/Seat model from data-model.md.
- [X] T043 [US1] In `server/authoritative/match_manager.js` implement the command path: authenticate by session token → derive seat from the account → check `client_seq` order → host `command` with `expect_seq` → **commit the `ranked_match_actions` row (PK `(match_id,seq)`) before sending `match_ack`** → send `match_view` to both seats; refused commands send `match_error` and audit only.
- [x] T044 [US1] Extend `queue_ranked` in `server/relay.js`: accept `deck_name` and `rules_version`; refuse unknown/illegal decks; reply `update_required` on a version mismatch and `ranked_busy` at the live-match ceiling (setting, default 100); when `RANKED_AUTHORITATIVE=1` and the host is `ready`, `startRankedMatch` creates a server-run match and `ranked_match_found` carries `authoritative: true` and the seat label; otherwise the legacy flow runs unchanged. (done; the found message carries `server_run: true` + `match_id`, refusals arrive as `ranked_refused` with reason `update_required`/`ranked_busy`/`invalid_deck`/`already_in_match`; seat label arrives with `match_view` on join)
- [x] T045 [US1] In `server/relay.js` wire the new message types (`match_join`, `match_command`, `match_mulligan`, `match_concede`, `match_ping`) to `server/authoritative/match_manager.js`, and make `report_ranked_result` and the legacy `relay` message a no-op (audited) for any match id owned by a server-run match. (done; match messages are token-authenticated and size-capped; legacy `report_ranked_result` is refused for server-run ids, the legacy `relay` message is unreachable because server-run players never enter a lobby; refusals are audited by the manager)
- [x] T046 [P] [US1] Create `scripts/game/remote_match_client.gd`: the thin ranked client — sends `match_join`/`match_command` with increasing `client_seq`, holds **no rules**, shows a pending state until `match_ack`, rebuilds from `match_view` via `GameState.from_net_dict` + `board.refresh()`, and plays animations from the filtered events; includes the update/busy messages. (written and compiles; NOT yet exercised against a live relay - no Postgres/two-client run was possible)
- [x] T047 [US1] Add the client networking in `scripts/game/net.gd` (`queue_ranked` with `deck_name`/`rules_version`, `match_*` senders and signals for `match_view`, `match_ack`, `match_error`, `update_required`, `ranked_busy`) and route the ranked flow in `scripts/game/main.gd` (`_begin_ranked_search` and `_on_ranked_match_found`) to `RemoteMatchClient` when the found message says `authoritative`, falling back to `MpGameManager` otherwise. (done; the found message is `server_ranked_match_found`, refusals are `ranked_refused`; covered by a core test of Net routing)
- [x] T048 [US1] In `scripts/game/board.gd` and `scripts/game/remote_match_client.gd` map every board interaction (play, attack, end turn, choice clicks, mulligan toggles, concede) to the command/answer messages and render the open `pending_choice` options from the view exactly as listed (highlight only server-provided options). (done; one command in flight at a time, choices rendered from the server-listed options via the existing `board.prompt_choice`; concede is the pause-menu button when `board.concede_enabled`)
- [x] T049 [US1] Add a visible, non-blocking notice in `scripts/game/main.gd` for `update_required` ("Update the game to play ranked") and `ranked_busy`, and make sure neither leaves the player stuck on the searching screen. (done as a transient banner plus ending the search; update_required / ranked_busy / invalid_deck / already_in_match / ranked_unavailable)
- [ ] T050 [US1] Run `cd server && npm test` (T034–T036 must pass) and play one full manual two-client ranked match with the flag on, including a mulligan, a challenge, a rummage and a transform choice; record the outcome in `.docs/status.md`.

**Checkpoint**: Ranked can be played cheat-proof end to end (clocks and settlement
below make it complete).

---

## Phase 4: User Story 2 — Disconnects, Timers and Forfeits Are Handled Fairly (Priority: P1)

**Goal**: A dropped player resumes the same match; stalling and abandoning are
handled by the server.

**Independent Test**: Drop a connection 10 s and rejoin → same state; let a turn
timer expire → turn ends with defaults; stay away past grace → forfeit.

### Tests for User Story 2

- [X] T051 [P] [US2] `server/test/clock_reconnect.test.js` with a fake clock: turn expiry calls host `timeout` and logs `timeout_default`; rejoin within grace resumes at the right `seq`; grace expiry settles a forfeit; both gone → `abandoned`; a second connection for a seat closes the first (FR-013); `concede` ends the match immediately.

### Implementation for User Story 2

- [X] T052 [US2] Add `timeout`, `concede` and `view` (with `since_n`) ops to `scripts/game/match_host.gd` per the IPC contract (`timeout` → `GameState.resolve_defaults`).
- [X] T053 [US2] In `server/authoritative/match_manager.js` add the `Clock` model: 90 s turn limit and 60 s disconnect grace as settings, reset on turn change, relay-owned wall time only; on expiry send host `timeout` and log a `timeout_default` action row; broadcast `match_clock`.
- [X] T054 [US2] In `server/authoritative/match_manager.js` handle connection loss: mark the seat disconnected, send `opponent_disconnected` with the countdown, start the grace timer; on `match_join` restore the seat with a new `controller_epoch`, close any older connection, reply with the seat's current `match_view`, and send `opponent_reconnected`.
- [X] T055 [US2] In `server/authoritative/match_manager.js` implement match endings: concede → `finished (conceded)`, grace expiry → `finished (forfeit_disconnect)`, both seats gone → `finished (abandoned)` with no settlement, a seat that never arrives → `voided`; update `ranked_matches.status/end_reason` in one transaction.
- [x] T056 [US2] In `scripts/game/remote_match_client.gd` add reconnection: on socket loss show a "reconnecting" state, on resume send `match_join` with the last displayed `seq` and rebuild; show the opponent-disconnected countdown and the concede button wiring in `scripts/game/board.gd`. (written: reconnect loop, `match_join` with last seq, opponent-disconnect countdown; NOT exercised with a real drop)
- [ ] T057 [US2] Run T051 and a manual drop/rejoin test with two clients; record in `.docs/status.md`.

**Checkpoint**: Server-run ranked is fair under real connections.

---

## Phase 5: User Story 3 — The Ladder and Rewards Settle From the Server's Result (Priority: P2)

**Goal**: The server settles rank, rating, streak and rewards once from its own
result; client claims are ignored; queueing is unchanged.

**Independent Test**: Finish a match and send no/duplicate/contradictory
`report_ranked_result` — ladder changes exactly once by the ladder rules.

### Tests for User Story 3

- [x] T058 [P] [US3] `server/test/settlement.test.js`: win/loss settle once via the existing `nextRankState`/`nextElo`; duplicate, missing and contradictory client reports change nothing; draw/void/abandoned/fault change nothing; a retry returns the stored outcome; the queue/found/bot-fallback flow still works with the flag on and off. (done for settlement/idempotency/draw-void-fault cases against an in-memory repo; contradictory client reports are moot because reports are not read; the flag on/off queue flow is not covered by an automated test)

### Implementation for User Story 3

- [x] T059 [US3] Create `server/authoritative/settle.js`: on host `over`, derive each seat's `won` from the host result only, read ratings/tiers from the `players` table (never from a client), reuse `nextRankState`/`nextElo` (export them from `server/relay.js` or move them to a shared module without changing their math), and write `ranked_settlements` + `players` in one transaction using the existing `INSERT … ON CONFLICT DO NOTHING` idempotency. (done; PgSettleRepo is untested against real Postgres)
- [x] T060 [US3] In `server/authoritative/match_manager.js` call `settle` exactly once on entry to `finished (completed|conceded|forfeit_*)`; skip it for `abandoned`/`voided`; then send `match_over` with `ranked_outcome` (same shape as today's `ranked_result_ack`). (done in the manager in the earlier checkpoint)
- [x] T061 [US3] In `scripts/game/remote_match_client.gd` and `scripts/game/board.gd` show the existing game-over/rank-change screen from `match_over` (`Auth` fields updated from `ranked_outcome`), and do **not** call `Auth.report_ranked_result` for server-run matches (`scripts/game/auth.gd`, `scripts/game/mp_game_manager.gd`). (done; `match_over.ranked_outcome` feeds the existing game-over rank display via `Net.publish_settled_outcome`; the thin client never calls `Auth.report_ranked_result`)
- [ ] T062 [US3] Run T058; manually finish one match each as winner, loser, conceder and forfeiter and confirm the ladder values; record in `.docs/status.md`.

---

## Phase 6: User Story 4 — The Statistics Database Gets Authoritative Data (Priority: P2)

**Goal**: Server-run matches produce verified, server-attested card facts for
both sides for spec 002.

**Independent Test**: A scripted match with known plays yields exactly the
expected facts, marked verified, regardless of anything clients send.

### Tests for User Story 4

- [x] T063 [P] [US4] `scripts/game/core_tests.gd` suite for `MatchRecorder` over the event feed: drawn/kept/played counts, first-played turn, created-vs-deck cards, and that `duplicate_for_sim()` copies stay silent; plus `server/test/stats_handoff.test.js` asserting the stored record is `verified`, `attested_by = 'server'`, with facts for both seats. (done: core MatchRecorder suite + `server/test/stats_handoff.test.js`; the "stored record is `verified`/`attested_by = server`" part waits for spec 002 ingestion, so the test asserts the facts are stored on the match)

### Implementation for User Story 4

- [x] T064 [P] [US4] Create `scripts/game/match_recorder.gd` (RefCounted, logic layer, as designed in `specs/002-card-stats-database`) consuming the event feed plus the starting decks and mulligan result; never attached to simulation copies. (done)
- [x] T065 [US4] Attach the recorder inside `scripts/game/match_host.gd` for every `create`d match and return its `facts` in the `over` reply (IPC contract). (done; recorder also fed during `replay`, so a resumed match keeps its facts)
- [x] T066 [US4] In `server/authoritative/match_manager.js` persist the facts at match end: if spec 002's `stat_*` ingestion exists, call it with `status='verified'`, `attested_by='server'`; otherwise store them in a `facts JSONB` column added to `ranked_matches` so they can be imported later — keeping the two specs decoupled. (done via the `facts JSONB` fallback: spec 002 ingestion does not exist yet)
- [x] T067 [US4] Update `specs/002-card-stats-database/spec.md` and `plan.md` to state that server-run ranked matches are verified by construction (replacing the two-report cross-check for them) and that casual/campaign/AI keep the weaker labels. (done)

---

## Phase 7: User Story 5 — Operate, Audit and Roll Back Safely (Priority: P3)

**Goal**: The maintainer can see, replay, switch off and safely restart.

**Independent Test**: Live status; replay of a finished match reproduces its
hash; flag off routes new matches to the old flow while live ones finish;
restart mid-match resumes or voids without rank change.

### Tests for User Story 5

- [X] T068 [P] [US5] `server/test/restart_replay.test.js`: kill the host mid-match → relay restarts it, replays the log and the match continues; corrupt one log row → `state_hash` mismatch → match voided, no rank change; replay of a finished match matches `final_state_hash`; `RANKED_AUTHORITATIVE` toggled off mid-match does not end live matches.

### Implementation for User Story 5

- [X] T069 [US5] Add the `replay` op (and optional per-step hashes) to `scripts/game/match_host.gd` using the same engine the live path uses.
- [X] T070 [US5] In `server/authoritative/match_manager.js` implement resume-on-restart: at boot and after a host restart, load every `active` match, call host `replay` with its `(seed, decks, log)`, compare to the last stored `state_hash`, resume on match, otherwise mark `voided (voided_fault)` and message both players via `match_voided`.
- [x] T071 [P] [US5] Create `server/tools/matches.js` (maintainer CLI, `DATABASE_URL`, no network endpoint): `status` (live count, capacity, recent failures), `history <match_id>` (action log), `replay <match_id>` (re-run and confirm the hash), `audit` (refusals); every call appends to the audit table. (done; never run against a real database, so the queries themselves are unverified)
- [x] T072 [US5] In `server/relay.js` enforce the live-match ceiling and the `RANKED_AUTHORITATIVE` switch exactly as in FR-023/FR-025 (new pairings only; live matches untouched) and document the deploy procedure in `.docs/authoritative-server.md` (drain before restart; running matches resume from the log). (done; ceiling and switch were already enforced via `canStart()`/`isEnabled()` with the env knobs, and the deploy procedure is now written in that doc)

---

## Phase 8: Polish & Cross-Cutting

- [x] T073 [P] `server/test/load.js`: bot clients drive 100 concurrent matches; assert p95 accepted-action latency ≤ 0.3 s (SC-003/SC-007) and record host CPU/memory in `research.md` §13; shard host processes by `match_id` only if the measurement requires it. (done and run: 100 matches on one host, p50 136 ms / p95 159 ms / p99 178 ms / max 307 ms, 586 MB peak, 609 accepted actions/s, 75 of 100 played to game over; no sharding needed — numbers and the two measurement traps are in research.md §13. Measured with the in-memory store on one Windows desktop, so it covers the rules host and the relay's work, not Postgres or real network latency)
- [x] T074 [P] Security review of the new surface in `server/authoritative/` and `scripts/game/match_host.gd`: host binds `127.0.0.1` only, secret required, no host operation reachable from a client message, no deck/hand/seed ever sent to a client, frame caps enforced; fix findings. (done; the review table and the accepted risks are in `.docs/authoritative-server.md`. Three findings fixed: match frames reached the `sessions` query before anything metered them (now a per-socket 30 frames/s budget plus a 10 s verified-token cache), joins and pings were not metered (the per-seat limiter now covers every message type, `test/rate_limit.test.js`), and the host's `replay` op accepted command types the live path refuses and could overwrite a live match id)
- [x] T075 [P] Create `.docs/authoritative-server.md` (architecture, protocols, flag, deploy, what was and was not verified) and add its row to the table in `CLAUDE.md`; update `.docs/architecture.md` (new files and the match-host process), `.docs/status.md` and `.docs/overview.md` per Constitution Principle IV. (done; architecture.md gained the three new scripts and a "Server Processes" section, status.md gained the feature and the load numbers and had its stale "no headless server exists" item corrected, overview.md's networking bullet mentions the match host)
- [ ] T076 Run every quickstart scenario (`quickstart.md` Phases A–D) end to end and tick each success criterion SC-001…SC-010 with evidence; note any that remain unproven.
- [ ] T077 Turn on `RANKED_AUTHORITATIVE` in the deployed relay only after T076, keeping the previous flow one switch away; add the release note.

---

## Dependencies & Execution Order

### Phase dependencies

- **Phase 1 (Setup)** → no dependencies. T004/T005 spikes can finish while Phase 2 starts, but must finish before T038/T040.
- **Phase 2 (Foundational)** → depends on T001; **blocks all user stories**. Internal order: T006→T007→T008→T009→T010→T011 (core mechanisms), then migrations T014–T025 (each depends on T006–T011, not on each other except where they share a file), then controller reduction T026–T030, then T031–T033.
- **US1 (Phase 3)** → depends on Phase 2 and T002–T005. **US2** depends on US1. **US3** depends on US1 (needs a result) and can proceed in parallel with US2. **US4** depends on Phase 2 (recorder) and US1 (host). **US5** depends on US1 and uses US2's endings.
- **Polish** → after the stories you intend to ship.

### Within a user story

Tests first (they must fail) → host/server data → relay wiring → client → manual
check.

### Parallel opportunities

- Phase 1: T002, T003 (different files) while T004/T005 run.
- Phase 2: T012 and T013 (tests, same file but additive, coordinate), T030 once controllers are reduced.
- US1 tests T034/T035/T036 together; T037 and T046 are independent files.
- US3's T058, US4's T063/T064 and US5's T068/T071 are independent files.
- Polish T073/T074/T075 together.

### Parallel example (User Story 1)

```text
T034 server/test/protocol.test.js
T035 server/test/hidden_info.test.js
T036 server/test/cheating.test.js
T037 server/authoritative/schema.js
T046 scripts/game/remote_match_client.gd
```

## Implementation Strategy

1. **Ship Phase 2 on its own.** It needs no server, has no player-visible
   change, fixes a constitution violation, and every later step depends on it.
   It is also where most of the effort and risk is.
2. **MVP = Phases 1–4** behind `RANKED_AUTHORITATIVE`: cheat-proof ranked with
   clocks and reconnect. Settlement can temporarily remain the legacy
   `report_ranked_result` path **only** if you accept that the result claim is
   still client-reported for that interim; the plan's intent is to ship US3 with
   US1/US2.
3. Add US3 (settlement) → US4 (stats) → US5 (operations), validating each at
   its checkpoint.
4. Turn the flag on in production only after T076.

## Notes

- Casual lobbies, campaign multiplayer and AI matches keep their current,
  client-run behavior and are labeled unverified; nothing here changes them
  (their controller code is only touched in Phase 2 to remove duplicated rules).
- Tasks T014–T025 change gameplay code paths used by **every** mode, so each
  must keep the existing headless hooks green before the next starts.
- Commit after each task or logical group; run `--core-tests` after every
  Phase 2 task.
