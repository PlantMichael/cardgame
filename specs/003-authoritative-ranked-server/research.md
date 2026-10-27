# Research: Server-Authoritative Ranked Matches

Decisions that resolve the plan's unknowns, grounded in what the repository
does today.

## 1. How to run the real rules on a server

**Evidence**: `GameState`, `PlayerState`, `Minion`, `Abilities`, `CardDatabase`
are RefCounted/autoload scripts with no scene-tree dependency; `--core-tests`,
`--mcts-benchmark` and the other headless hooks already run full matches
inside `godot --headless`. `execute(cmd)` takes plain-value commands;
`duplicate_for_sim()` and `to_net_dict(for_player)` already exist; randomness
is a seeded per-match generator; card/minion identity uses counters, not
`randi()` (see `.docs/conventions.md`).

**Decision**: Host the rules in a **headless Godot "match host" process**
started by the relay (`godot --headless --path <project> -- --match-host`,
matching the existing `main.gd` CLI-hook convention). One long-lived process
holds many `GameState` instances keyed by match id.

**Rationale**: It is the only option that satisfies FR-007 ("the same rules")
with no second implementation. The existing headless tooling proves the rules
run without a screen.

**Alternatives rejected**:
- *Port the rules to JavaScript* — ~14k lines of GDScript, more cards every
  week; two sources of truth guarantee drift.
- *Replay-only verification* — catches some result fraud afterwards but does
  not stop hidden-information leaks or illegal play during the match (FR-005).
- *Godot as the public server* — would need its own accounts/sessions/DB.
- *Godot compiled to WASM inside Node* — not a supported, mature path.

**Residual risks**: headless autoload safety (see §7) and container size.

## 2. The rules core is incomplete — inventory of what must move

**Evidence**: `game_manager.gd` (785 lines) `_run_player_on_play()` and the
`_process_pending_*` functions decide outcomes (e.g. after `challenge_target_
selected` it calls `apply_challenge` and grants +1/+1 on a win; swap/devour/
pilot likewise) and are copied in `mp_game_manager.gd` (1,271 lines),
`ai_controller.gd` (353) and `headless_turn.gd._handle_on_play` (715). Only
three effects (`restore_health`, `buff_other_friendly`, `damage_high_attack`)
use the migrated pending-choice model (`game_state.gd`, `CHOICE_*`).

**Inventory** (each becomes a `GameState` choice kind; legality computed once
in the core):

| Family | Today | Choice shape |
|---|---|---|
| On-play damage (`on_play_damage_N`) | board target signal | any enemy minion or hero |
| Challenge / on-play challenge win-buff | target signal; win-buff applied in controller | enemy minion; win-buff moves into core |
| Yeti challenge (`ON_PLAY_YETI_CHALLENGE`, Icewhip `force_challenge`) | two sequential signals | step 1 friendly Yeti → step 2 enemy |
| `challenge_all` | automatic loop in controller | no choice; loop moves into core |
| Pilot-on-play (`ON_PLAY_PILOT_MECH`), manual pilot | target signal | friendly un-piloted Mech |
| Swap friendly health | two signals | friendly A → friendly B |
| Devour friendly | signal | friendly other than source |
| Transform choice (`ON_PLAY_TRANSFORM_CHOICE`) | `show_transform_picker` | one of N card ids |
| Rummage family (`pending_rummages`) | `show_graveyard_picker` | graveyard card uid (or none) |
| Tank shots, on-reinforce damage | target signals | any enemy minion / hero |
| Null (`pending_nulls`) | target signal | any minion (non-cloaked) |
| Buff-friendly-health, tank-specialist buff | target signal | friendly minion |
| Overwatch challenges | yeti + target | friendly Yeti → enemy |
| Stratagem follow-ups (blood transfusion, sanguine second pick) | target signal | friendly minion |

**Decision**: Generalize the existing choice model (see
[contracts/rules-core-choices-events.md](./contracts/rules-core-choices-events.md)):
options may be minions, heroes, card uids in a pile, or card ids; a choice may
chain a second step; every choice has a deterministic **default** (used by
timeouts and by the AI). Controllers stop containing effect logic; they send
`answer_choice` and render. `HeadlessTurn` and `AIController` keep only *policy*
(which option to pick).

**Rationale**: This is also what makes AI, search, local play and the server
provably identical. It is the largest single block of work (Phase A) and is
independently shippable.

## 3. Events for animation

**Evidence**: Animations are triggered by controller code that knows what just
happened (`animate_creature_attack`, `animate_creature_challenge`,
`animate_laser_kill`, `animate_draw`, `play_opponent_card_with_slam`, card
announce).

**Decision**: `GameState` appends compact **events** (play, attack, challenge,
damage, death, draw, transform, heal, reinforce, announce) to an ordered
buffer at its existing chokepoints. Commands return the events they produced;
the server sends them with the new view. Clients animate from events and then
`board.refresh()` from the view, so events are advisory and state is
authoritative (Principle II). The statistics recorder from spec 002 consumes
the same feed.

**Alternatives rejected**: Client diffing successive snapshots — cannot infer
*who attacked whom*; sending animation commands from the server — mixes
presentation into rules.

## 4. Transport between relay and match host

**Decision**: The host listens on `127.0.0.1:<port>` (TCP) using Godot's
`TCPServer`; the relay is its only client. Frames are newline-delimited JSON.
The relay passes a random shared secret via environment; the first frame must
present it. The host does no I/O besides this socket.

**Alternatives rejected**: stdio pipes (Godot's stdout log noise and blocking
stdin on the main thread); a public WebSocket (needs its own auth); a shared
file/queue (latency, locking).

## 5. Who owns what

| Concern | Owner | Why |
|---|---|---|
| Accounts, sessions, queue, pairing, ranked math, Postgres | Relay (Node) | Already built and trusted |
| Rules, state, hidden info, win detection | Match host (Godot) | FR-001/007 |
| Turn/disconnect clocks | Relay | It owns connections and wall time; host stays deterministic |
| Decks | Relay reads from the `decks` table at match start | The client must not supply a deck |
| Seed, first player, match id | Relay (cryptographic randomness) | FR-008 |
| Settlement | Relay, from the host's final result | FR-015 |

## 6. Determinism, action log and restart

**Decision**: A match is fully described by `(seed, rules_version, deck A, deck
B, first player)` plus the ordered list of accepted commands (including
timeout-default actions, recorded as such). The relay writes each accepted
command to `ranked_match_actions` **before** acking the client. After a host or
relay restart the manager replays each active match's log into a fresh
`GameState`; if replay's final state hash does not match the last stored hash,
the match is voided with no rank change (FR-024).

**Prerequisites** (Phase A tasks): every rule roll uses `GameState.rand_*`
(already a project convention — add a core test that fails if rule code calls
global `randi()`/`randf()`/`shuffle()`); minion/card ids are counter-based
(already true); no wall-clock reads inside rules.

**Rationale**: Gives audit (FR-019), resume (FR-024) and the parity test
(SC-002) from one mechanism.

## 7. Making Godot run well headless on Railway

**Evidence**: `--core-tests` already runs headless against the full project.
`project.godot` autoloads (`CardDatabase`, `Abilities`, `DeckManager`, `Net`,
`Auth`, `Economy`, …) all initialize in that mode. Several scripts `preload`
textures (e.g. `card.gd`, `ranked_progress.gd`).

**Decision**: Build the server image with the pinned Godot Linux headless
binary, copy `project.godot`, `scripts/`, `data/` and the minimum of `assets/`,
and run `godot --headless --import` once at build time so resource references
resolve. Add a `--match-host` CLI hook that never instantiates `Board`,
`Net` connections or UI. **Spike task**: confirm the autoloads (`Net`, `Auth`,
`Economy`) are inert without a connection in this mode and measure image size
and cold start; if `preload` of textures forces large assets, split card art
and UI textures out of the rules-only path or export a server PCK.

**Findings so far (T004/T005)**:
- `Net`, `Auth` and `Economy` only connect signals in `_ready()`; `Net` opens a
  socket only when `connect_to_relay()` is called, so the autoloads are inert in
  `--match-host` mode. `--core-tests` already runs headless with them loaded.
- `server/Dockerfile` is **built and exercised** (Docker 28.5.2, linux/amd64):

  | | |
  |---|---|
  | image size | **1.3 GB** |
  | build | ~37 s with warm layers; a cold build is dominated by the 146 MB Godot download and the 31 s build-time `--import` |
  | match host ready | **3.3-3.6 s** from the supervising process's start (`HostProcess.start()` to a `stats` answer) |
  | container start → host ready | ~11.5 s on the first run of a fresh image, ~4.9 s once the image's pages are cached |
  | the suite inside the image | **42/42 pass in 22 s** (`docker run --rm cardgame-relay sh -c 'node --test test/*.test.js'`) — the Linux host really runs matches, the hidden-info sweep, the 216 cheating cases, restart-replay and settlement |

  Two things the build taught us:

  - `libxrandr1` does not exist in bookworm (it is `libxrandr2`), so the first
    build failed outright at `apt-get install`.
  - The headless binary needs **no** X or GL libraries at all. Dropping
    `libfontconfig1 libgl1 libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6`
    took the image from 1.6 GB to 1.3 GB with the host still booting in 3.5 s
    and the suite still 42/42, so they are gone from the Dockerfile.

- Remaining size levers, in order of value: `COPY assets` is 305 MB and the
  build-time `--import` of it is another 104 MB — 409 MB the rules never touch.
  They are in the image only because `main.gd` (which owns the `--match-host`
  hook) `preload`s `Board.tscn`, the menu wallpaper, the cursor and a font, so
  trimming them needs a host-only entry scene that does not reach the UI first.
  After that the apt layer (236 MB → mostly removed already) and a multi-stage
  build to drop `curl`/`unzip` are small change.

**Alternatives rejected**: exporting a Linux dedicated-server build (extra
export pipeline for a first release).

## 8. Hidden information

**Evidence**: `GameState.to_net_dict(for_player_id)` already reduces the
opponent hand to a count and omits decks and generator state; `from_net_dict`
rebuilds a mirror.

**Decision**: The host only ever emits `view(seat)` built from that function
(extended for choices and clocks) plus events filtered per seat (e.g. an
opponent's draw event carries no card id; a played card is public). A test
inspects every outbound frame for each seat for any card uid/id of hidden zones
(SC-001).

## 9. Clocks, disconnects and forfeits

**Decision**: Relay timers: 90 s per turn (reset on turn change, paused while a
seat is the *waiting* side only for choice prompts caused by the opponent),
60 s disconnect grace. On turn expiry the relay sends `timeout(seat)`; the host
resolves open choices with their deterministic defaults, ends the turn, and
the action is logged as `timeout_default`. On grace expiry the relay settles a
forfeit. Both-gone → `abandoned`, no rank change.

**Open policy value**: whether a forfeit counts as a full ladder loss (spec
default: yes). Revisit after data.

## 10. Client versions

**Decision**: `rules_version` (integer) in a single constant shared by client
and host, bumped when rules or card data change. The queue handshake sends it;
a mismatch returns `update_required` before pairing. The match header stores it
for replay.

## 11. Rollout and fallback

**Decision**: Environment flag `RANKED_AUTHORITATIVE` (default off). When on,
new ranked pairings create server-run matches; when off (or if the host process
is down/at capacity), ranked uses today's flow. Each match records its `mode`.
Live matches are never migrated between modes (FR-023).

## 12. Statistics hand-off (spec 002)

**Decision**: The match recorder runs **inside the host** over the event feed
for server-run matches and returns facts to the relay at match end; the relay
stores them as `verified`, `attested_by = 'server'`, bypassing the
two-report cross-check. 002's report message remains for casual/AI/campaign.

## 13. Capacity

**Decision**: One host process, single-threaded GDScript; commands are tiny.
Measure with the bot-client load script; shard by `match_id % N` across
multiple host processes if needed. Refuse new ranked pairings with a "busy"
message at a configured live-match ceiling (FR-025).

### Measured (T073)

`server/test/load.js` drives the real client path (message validation →
`MatchManager` → host IPC → store → `match_ack`) for N matches at once through
**one** host process, with bots that answer choices, play creatures, attack and
end turns. The store is the in-memory one, so these numbers are the rules host
plus the relay's own work, not Postgres.

`GODOT_BIN=<godot 4.7.2> node test/load.js --matches=100 --turns=40`, Windows 11,
Node 24.11, one desktop machine, host and driver on the same box:

| | |
|---|---|
| matches | 100 concurrent (75 played to game over) |
| accepted actions | 8728 (748 refused as illegal by the bots' own bad attacks) |
| throughput | 609 accepted actions/s over 14.3 s |
| latency p50 | 136 ms |
| **latency p95** | **159 ms** (budget 300 ms — SC-003 met) |
| latency p99 | 178 ms |
| latency max | 307 ms |
| host peak memory | 586 MB (a 10-match run peaks at 580 MB: nearly all of it is Godot's own baseline, not per-match) |
| host CPU | 19.8 s over 14.3 s wall (138% of one core; the engine is not single-threaded) |

Sharding is **not** needed at 100 matches: one host holds them with p95 well
inside the budget, and the memory cost is the engine itself rather than the
matches. The tail (p99 178 ms, max 307 ms) comes from the single IPC socket
serialising bursts, so it is the number to watch if the ceiling is ever raised;
`match_id % N` across several host processes is still the lever. A 10-match run
sits at p95 15 ms, so the latency at 100 is queueing, not rules cost.

Two incidental findings: bots driven flat out trip the seat's own 20 actions/s
budget (the script now waits one out and retries), and the per-seat limiter is
therefore exercised under load as well as in `test/rate_limit.test.js`.

Two measurement traps, both now avoided in the script and worth remembering:

- Sampling the host's memory/CPU **synchronously** (`execFileSync` to
  PowerShell, every 2 s) blocks Node's event loop while every request is in
  flight, and reported p95 ≈ 2040 ms — pure measurement overhead. The sampler
  is asynchronous.
- On Windows, `Godot_*_console.exe` is a shim that runs the engine as a child
  process: sampling the spawned pid alone reports ~7 MB and no CPU. The sampler
  sums the pid and its direct children.

## 14. The end-to-end run with a real relay and a real Postgres (T050/T062 groundwork)

`server/test/e2e_ranked.js` plays server-run matches through a real
`node relay.js` with `RANKED_AUTHORITATIVE=1`, a real Godot host and a real
Postgres, with two websocket clients. 30/30 checks pass: registration, a stale
`rules_version` refused, pairing on shipped starter decks, hidden hands,
mulligan, a full match to game over with a socket drop and rejoin partway, the
action log and facts in the database, one settlement per player, a client's own
`report_ranked_result` refused, and a second match ended by conceding.

Nothing on the server had to change for it. Postgres was exercised for the
first time here and by `test/pg_store.test.js`: `PgStore` and `PgSettleRepo`
passed on the first run against Postgres 14.24, including the settlement race
(two transactions settling the same match award once, the loser of the race
replaying the stored outcome).

Two traps a *client* falls into, neither of them a server fault, both worth
knowing for any future client:

- **The ack and the view are separate frames.** `match_ack` is sent to the
  actor and `match_view` to both seats, as two messages. A client that decides
  its next action the moment the ack resolves is reading the board as it was
  *before* its own move. The first scripted run spent 94 refusals on
  `not this player's turn` doing exactly that; the script now waits for the
  view whose `seq` is past the one it acted on. `remote_match_client.gd` is not
  affected — it renders and acts from views, never from acks.
- **A pending choice is shown only to the seat that owes it, and while it is
  open the *other* seat's every action is refused.** A client loop that only
  lets the active player act therefore deadlocks when an ability asks the
  inactive seat something: the second run stalled with 229
  `a pending choice must be answered first` refusals. The script now offers
  both seats the chance to answer before either takes a turn.
  `remote_match_client.gd` already calls `_maybe_prompt_choice()` on every view
  and gates only on `choice.player_id == _my_id`, not on whose turn it is, so
  the real client handles this correctly.

Also worth recording: a stale `match_view` left sitting in a client's queue
made a rejoin look as though the server had handed back `seq` 1 for a match
already at `seq` 4. A view is state, not a notification — it must replace what
the client knows, never queue behind older ones.
