# Implementation Plan: Card Statistics Database

**Branch**: `002-card-stats-database` | **Date**: 2026-10-24 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/002-card-stats-database/spec.md`

## Summary

Record a private, verified fact sheet for every finished match — each side's
starting deck, per-card drawn / kept-through-mulligan / played facts, result,
ranked tier group and game version — and turn it into per-card and per-deck
win-rate summaries the maintainer reads privately and, after an explicit
review step, publishes as immutable, anonymous, minimum-sample-gated JSON
releases next to the existing `catalog/` public card catalog.

The approach follows how the game already works rather than inventing a new
trust model:

- The **relay server runs no game rules** — the host's Godot client is the
  authority for a multiplayer match and the relay forwards opaque payloads.
  So "server validation" cannot mean re-simulating the match. It means what the
  ranked ladder already does (`rankedMatches.claims` in `server/relay.js`):
  the **server owns the match identity, the participants and their tiers**,
  and a result is only *verified* when **both participants' independent reports
  agree** with each other, with the server's own observation (who was seated,
  how long the match ran, how much traffic the relay carried) and with
  server-side checks (deck legality, card ids exist, ownership). Anything else is
  stored as **disputed** or **unverified** and never feeds a published number.
- AI matches run only on the player's device, so they are recorded as
  **unverified** and kept out of verified and published figures by default.
- **Raw data has no network read path at all.** The game's websocket gains one
  write-only message (`report_match_stats`); reading raw records, private
  summaries and building releases are maintainer CLI commands run with database
  credentials. Unauthorized "requests" therefore have nothing to call.
- Facts are captured in the **logic layer** (a recorder attached to
  `GameState`, never to the UI and never to AI search copies).

## Technical Context

**Language/Version**: GDScript (Godot 4.3, tabs) for the client recorder and
report sender; Node.js (CommonJS, matching `server/relay.js`) for server
ingestion; Node ES modules for the maintainer/publishing tooling (matching
`catalog/`).

**Primary Dependencies**: None new. Server reuses `pg`, `ws`, `crypto`
already in `server/package.json`; publishing reuses `catalog/src/export.mjs`
conventions (versioned, write-once, atomic writes) with Node built-ins only.

**Storage**: The existing PostgreSQL database, new tables prefixed `stat_`
created with the same `CREATE TABLE IF NOT EXISTS` / `ALTER TABLE ... IF NOT
EXISTS` pattern as `initDb()`. Raw rows reference players through a nullable
`player_id` (`ON DELETE SET NULL`) and a keyed pseudonym `account_key`. Published releases are
static files under `catalog/public/data/v1/stats/`, retained in the repo like
catalog releases.

**Testing**: Three layers, all existing styles. (1) `--core-tests` gains a
`MatchRecorder` suite (headless, no scene tree). (2) New `node --test` suites
under `server/test/` for ingestion/verification against a real Postgres, and
under `catalog/test/` for the privacy-gated release builder. (3) A new
`--stats-test` headless hook plays AI-vs-AI matches and checks the produced
report against hand-computed expectations. Manual playtest for the first-match
disclosure notice.

**Target Platform**: Same as today — Godot web/desktop client, Node relay on
Railway with its Postgres plugin. No new service or deployment unit.

**Project Type**: Existing game client + existing relay server (extended), plus
the existing `catalog/` publishing package (extended). No new package.

**Performance Goals**: Recording adds no wait to the post-match screen (SC-007):
the report is sent after the result screen is already up, fire-and-forget with a
local retry queue. A report is ≤ ~8 KB; one ingestion transaction ≤ 50 ms.

**Constraints**: No client-reported figure is ever trusted alone; no read path
to raw data from the websocket; published output contains only coarse, capped,
thresholded aggregates; the match itself, ranked settlement and rewards must
behave exactly as before if recording fails.

**Scale/Scope**: Hundreds of cards, tens of thousands of matches in the
retention window (24 months). ~30 deck-card rows per side per match
(≈ 60 rows/match) → low millions of rows worst case; indexed by
`(match_id)`, `(game_version, tier_group, match_type)`, `(card_id)`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design below.*

| Principle | Assessment |
|---|---|
| I. Logic/Presentation Separation (NON-NEGOTIABLE) | **Pass.** Fact capture is a new logic-layer class (`scripts/game/match_recorder.gd`) observed by `GameState`/`PlayerState` at their existing chokepoints (`draw_card`, `mulligan_swap`, `play_creature`, `play_stratagem`). `board.gd` and all UI are untouched except one non-blocking disclosure notice in `scripts/ui/`. The recorder is **not** copied by `duplicate_for_sim()`, so AI search can never record. |
| II. Explicit State Sync | **Pass / n/a.** No UI state is patched incrementally. |
| III. Data-Driven Card Content | **Pass.** Facts key off stable card ids from `data/cards/*.json`; there are no per-card branches. The server validates against the same JSON files `relay.js` already reads for shop data. |
| IV. Docs Stay in Sync | **Gate for tasks.** Tasks include updating `architecture.md`, `game-logic.md`, `card-data.md`, `status.md` and a new `.docs/stats.md` row in `CLAUDE.md`. |
| V. Starter Deck Integrity | **Pass / n/a.** No cards or starter decks change. |
| Constraint: server-authoritative ranked/matchmaking state | **Pass.** Tier groups come from server data captured at match start, never from the client. |
| Workflow: prefer smallest change, no speculative frameworks | **Pass with note.** No new service, dependency or generalized event bus. One justified addition: a `server/stats/` module (see Complexity Tracking). |
| Workflow: verify via headless hooks / playtest | **Pass.** Plan extends `--core-tests`, adds `--stats-test`, plus Node test suites. |

## Project Structure

### Documentation (this feature)

```text
specs/002-card-stats-database/
├── plan.md              # This file
├── research.md          # Phase 0 decisions
├── data-model.md        # Phase 1: tables, entities, state transitions
├── quickstart.md        # Phase 1: how to prove it works end to end
├── contracts/
│   ├── match-stats-protocol.md   # client -> relay report message
│   ├── published-card-stats.md   # public release file schema + privacy rules
│   └── maintainer-cli.md         # private read/aggregate/publish commands
├── checklists/requirements.md
└── tasks.md             # Phase 2 (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
scripts/game/
├── match_recorder.gd        # NEW  logic-layer fact capture (RefCounted, no Node deps)
├── game_state.gd            # +hooks: start/draw/mulligan/play/end -> recorder (null on sim copies)
├── player_state.gd          # +draw hook call site
├── game_manager.gd          # +send report after local match over (AI/campaign-vs-AI)
├── mp_game_manager.gd       # +send report from host and guest after match over
├── net.gd                   # +report_match_stats(), retry queue flush on login/resume
├── core_tests.gd            # +MatchRecorder suite
scripts/ui/
└── stats_notice.gd          # NEW  one-time disclosure notice (non-blocking)

server/
├── relay.js                 # +require('./stats'), +register match, +'report_match_stats' case
├── stats/
│   ├── schema.js            # stat_* table DDL (called from initDb)
│   ├── registry.js          # in-memory server-observed match registry (seats, tiers, timing)
│   ├── validate.js          # deck legality, plausibility, cross-report agreement
│   └── ingest.js            # idempotent settle -> stat_* rows in one transaction
├── tools/
│   └── stats.js             # maintainer CLI: inspect / aggregate / unlink / purge / audit
└── test/                    # node --test (ingest, validate, privacy)

catalog/
├── src/stats-release.mjs    # NEW  build a reviewed, gated stats release from aggregate tables
├── src/server.mjs           # (unchanged: already serves /data/v1/**.json read-only)
├── public/data/v1/stats/    # retained published stats releases
└── test/stats-release.test.mjs

.docs/
└── stats.md                 # NEW  how recording, verification and publication work
```

**Structure Decision**: Extend the three places that already own the relevant
responsibility — the Godot logic layer (what happened), `server/` (who may
report and what is stored) and `catalog/` (what becomes public) — rather than
adding a service. Raw reads live in a CLI, not in `relay.js`, so the websocket
process has no code path that returns stored match data.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| New `server/stats/` module directory instead of inline in `relay.js` | Ingestion, verification and DDL are ~400 lines with their own tests; `relay.js` is already a 1,100-line single file | Inlining would make the new tests impossible to run without booting the whole relay and would bury the privacy-critical code in an unrelated file |
| A second tooling surface (`server/tools/stats.js` CLI) | Raw/private reads must exist for the maintainer yet must not be reachable over the network | A websocket/HTTP admin endpoint would create exactly the attack surface FR-013 forbids; a CLI with DB credentials is the smallest safe option |
| Pseudonymous `account_key` alongside nullable `player_id` | Needed to cap one account's influence (FR-012) while allowing deletion to unlink (FR-018) | `player_id` alone is deleted-on-unlink and breaks capping for retained rows; storing nothing makes capping impossible |

## Post-Design Constitution Re-Check

Re-evaluated after `data-model.md` and `contracts/`:

- **I** still holds: all rules-relevant observation is in `match_recorder.gd`;
  the report is a plain dictionary built from it. UI code only shows a notice.
- **III** still holds: no table or contract contains card-specific logic; `card_id`
  is an opaque catalog identifier validated against the JSON.
- **IV** is enforced through explicit doc tasks, including a new `CLAUDE.md`
  docs-table row for `.docs/stats.md`.
- No principle is violated, so no entry beyond the Complexity Tracking table
  above is needed.

## Amendment (spec 003)

Server-run ranked matches supply **server-observed, verified** facts (the
recorder runs inside the server's match host), replacing the two-report
cross-check for those matches. Only casual/campaign/AI matches still use the
client-reported path and its weaker labels.
