# Implementation Plan: Server-Authoritative Ranked Matches

**Branch**: `003-authoritative-ranked-server` | **Date**: 2026-10-24 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/003-authoritative-ranked-server/spec.md`

## Summary

Run ranked human-vs-human matches on the server by hosting the game's **own
GDScript rules core** (`GameState`) in a headless Godot "match host" process
that the Node relay manages, instead of porting the rules to JavaScript or
trusting a player's client. The relay stays the public face (accounts,
sessions, matchmaking, timers, connections, Postgres); the match host is a
private, localhost-only rules engine that never touches the internet or the
database. Players' clients become thin: they send command values, and receive
a per-player *view* plus an *event feed* to animate.

The central finding of the research is that **the rules core is not yet
complete enough to host**. `GameState.execute(cmd)`, seeded randomness,
hidden-information views and state copying already exist, but a large share of
rules still lives in four controllers — `game_manager.gd` (human),
`mp_game_manager.gd` (multiplayer host), `ai_controller.gd` and
`headless_turn.gd` (search) — each with its own copy, and every older
effect that needs a decision (challenge, pilot, devour, swap, rummage, tank
shot, null, transform, overwatch, …) waits on a `Board` signal. So the work is
phased, and Phase A is valuable on its own and fixes an existing constitution
violation:

- **Phase A — Complete the rules core.** Move every remaining effect and
  decision into `GameState` as pending choices, add an event feed, and make all
  four controllers call it. Verified headlessly; no server needed.
- **Phase B — Match host + thin client behind a flag.** Spawn the host, define
  the protocols, implement the thin ranked client path, keep the old path as
  the fallback.
- **Phase C — Clocks, reconnect, persistence, restart.**
- **Phase D — Settlement, statistics hand-off, operations, rollout.**

## Technical Context

**Language/Version**: GDScript (Godot 4.7, tabs) for the rules core, match host
and thin client; Node.js (CommonJS, existing `server/relay.js`) for the relay
and process management.

**Primary Dependencies**: None new in Node (`ws`, `pg`, `crypto`,
`child_process`, `net` are built-in or already used). The server container
gains the **Godot Linux headless binary**, version-pinned to the project's
engine version. Godot side uses only built-ins (`TCPServer`/`StreamPeerTCP`,
`JSON`, `Thread`).

**Storage**: Existing PostgreSQL. New tables `ranked_matches` (match header and
status) and `ranked_match_actions` (append-only action log) plus a seed/deck
snapshot column — see [data-model.md](./data-model.md). The match host itself
holds only in-memory state and is rebuilt from the log.

**Testing**: (1) `--core-tests` gains rules-core suites for every migrated
effect and the event feed; (2) new `--parity-test` replays seeded AI-vs-AI
matches through the old and new paths and through the replay engine and asserts
identical results (SC-002); (3) `node --test server/test/` for protocol,
cheating, reconnect, timer and restart behavior against a real host process and
Postgres; (4) a bot-client load script for SC-007; (5) manual two-client
playtest.

**Target Platform**: Railway container running Node + the Godot headless
binary; clients unchanged (web/desktop Godot).

**Project Type**: Existing game client + relay, extended with one new internal
process type (the match host).

**Performance Goals**: p95 accepted-action round trip ≤ 0.3 s including
network; a single host process sustains 100 concurrent matches (SC-003/007).
GDScript rules are cheap without UI; target < 5 ms per command.

**Constraints**: The host binds `127.0.0.1` only and requires a shared secret;
no hidden information ever leaves it except through a per-seat view; every
accepted action is durably logged **before** it is acknowledged; the existing
ladder math (`nextRankState`/`nextElo`) is reused unchanged; non-ranked modes
are untouched.

**Scale/Scope**: ~16 effect families to migrate (inventory in research.md §2);
four controller copies to collapse; ~100 concurrent ranked matches; one host
process initially, shardable by match id.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design below.*

| Principle | Assessment |
|---|---|
| I. Logic/Presentation Separation (NON-NEGOTIABLE) | **Currently violated by existing code, and this feature is what fixes it.** `game_manager._run_player_on_play`, the `_process_pending_*` family, `mp_game_manager` and `ai_controller` all decide rules outcomes outside `GameState`. Phase A moves them into the logic layer; after it, `board.gd`/`game_manager.gd` only send commands and render. The plan **adds no new violations**: the thin client holds no rules, and the match host is just `GameState` plus a transport. |
| II. Explicit State Sync | **Pass.** The thin client still full-rebuilds from a view via `board.refresh()`; events only drive animations, never state. |
| III. Data-Driven Card Content | **Pass.** No per-card branches; migrated effects stay named, reusable ability handlers selected by JSON. |
| IV. Docs Stay in Sync | **Gate for tasks.** Tasks update `architecture.md`, `game-logic.md`, `abilities.md`, `conventions.md`, `status.md` and add `.docs/authoritative-server.md`. |
| V. Starter Deck Integrity | **Pass / n/a.** |
| Constraint: server state authoritative (ladder, matchmaking) | **Strengthened.** Results and decks now also come from the server. |
| Workflow: smallest change, no speculative frameworks | **Pass with justification.** The new process and protocol are the minimum that satisfies FR-001/007; see Complexity Tracking. |
| Workflow: verified via headless hooks / playtest | **Pass.** Extends the same hooks; adds Node tests for the server side. |

## Project Structure

### Documentation (this feature)

```text
specs/003-authoritative-ranked-server/
├── plan.md              # This file
├── research.md          # Phase 0 decisions and the rules-core inventory
├── data-model.md        # Phase 1: tables, in-memory entities, states
├── quickstart.md        # Phase 1: how to prove it works
├── contracts/
│   ├── rules-core-choices-events.md   # Phase A: choice model + event feed
│   ├── match-host-ipc.md              # relay <-> match host (localhost)
│   └── client-match-protocol.md       # client <-> relay for server-run matches
├── checklists/requirements.md
└── tasks.md             # Phase 2 (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
scripts/game/
├── game_state.gd         # +choice kinds for every migrated effect, +event feed, +default-resolution
├── abilities.gd          # on-play/death handlers request choices instead of returning to a controller
├── headless_turn.gd      # becomes a thin policy over GameState (no private rules copy)
├── game_manager.gd       # local path: command sender + renderer only (rules removed)
├── mp_game_manager.gd    # old casual/campaign path: same; ranked path -> RemoteMatchClient
├── ai_controller.gd      # AI picks answers; GameState applies them
├── remote_match_client.gd  # NEW thin ranked client: commands out, views+events in
├── match_host.gd         # NEW headless rules host: TCP server, match table, no Node deps
├── match_recorder.gd     # (from spec 002) consumes the event feed
├── core_tests.gd         # +migrated-effect suites, +event feed, +replay parity
scripts/ui/
└── (unchanged except board signal wiring for command answers)

server/
├── relay.js              # +queue -> create server-run match, +routing, +clocks, +settle
├── authoritative/
│   ├── host_process.js   # spawn/supervise the Godot match host, IPC client, health
│   ├── match_manager.js  # seats, clocks, reconnect, concede/forfeit, persistence, replay-on-restart
│   ├── protocol.js       # message schemas + validation for the client protocol
│   └── settle.js         # derive ladder outcome from the host's result (reuses nextRankState)
├── Dockerfile            # NEW/updated: Node + pinned Godot Linux headless + project data
└── test/                 # node --test: protocol, cheating, reconnect, timers, restart

.docs/authoritative-server.md   # NEW
```

**Structure Decision**: One new process type (Godot match host) beside the
existing relay, rather than a second service or a rules port. Everything
public-facing stays in `relay.js` and its new `server/authoritative/`
modules; everything rules-related stays in `scripts/game/`.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| A second runtime (headless Godot) in the server container | Only way to run the *shipped* rules with no second implementation (FR-007) | Porting rules to JS creates two sources of truth that drift on every card; replay-only verification doesn't stop information leaks (FR-005) |
| A localhost IPC protocol relay ↔ host | Keeps accounts, sockets, timers and Postgres in the proven Node relay while the host stays a pure rules engine | Putting Godot on the public internet would need a second auth/session system and DB access |
| Phase A rewrites rules in four controllers | The rules must exist in one place before any process can host them | Hosting today's `GameState` as-is would silently run only part of the rules |
| An action log + replay | Needed for restart-resume (FR-024), audit (FR-019) and the replay-parity test (SC-002) | Snapshotting full state per action is larger, and unreplayable for audit |

## Post-Design Constitution Re-Check

- **I** holds after Phase A by construction; a new core test asserts no
  controller file mutates rules state (greps for direct `hero_health -=`,
  `take_damage(` and `apply_*` calls outside `game_state.gd`/`abilities.gd`).
- **II** holds; events are advisory, snapshots are authoritative.
- **III** holds; migrated handlers keep card-data-driven selection.
- No principle is violated, so the only entries beyond Complexity Tracking
  are the explicit Phase A deliverables above.
