<!--
Sync Impact Report
- Version change: [TEMPLATE] → 1.0.0 (initial ratification)
- Modified principles: n/a (first concrete adoption; template placeholders replaced)
- Added sections:
  - Core Principles I–V (Logic/Presentation Separation, Explicit State Sync,
    Data-Driven Card Content, Docs Stay in Sync with Code, Starter Deck Integrity)
  - Technology & Project Constraints
  - Development Workflow
  - Governance
- Removed sections: none
- Templates requiring follow-up: none — plan/spec/tasks templates reference the
  constitution generically and need no edits for this ratification.
- Deferred TODOs: none
-->

# Cardgame Constitution

## Core Principles

### I. Logic/Presentation Separation (NON-NEGOTIABLE)
`scripts/game/game_state.gd` (and the state it owns via `player_state.gd`,
`minion.gd`) is the single authoritative source of game rules and match state.
`scripts/game/board.gd` and every other scene script under `scripts/ui/` and
`scripts/cards/` MUST remain pure presentation: they read state and emit
signals, but MUST NOT decide game outcomes, mutate rules-relevant state
directly, or duplicate logic that already lives in `GameState`. Any new game
mechanic is implemented in the logic layer first; the visual layer only
reflects it.
**Rationale**: This split is what lets the AI (`ai_controller.gd`,
`headless_turn.gd`, `mcts_ai.gd`) and headless dev/test hooks
(`--mcts-benchmark`, `--campaign-test`, `--tank-test`) run and verify full
matches with no scene tree at all. Blurring the split breaks headless
verification, which is this project's only automated testing strategy.

### II. Explicit State Sync
UI code MUST NOT attempt incremental, partial updates of board visuals.
After any `GameState` mutation, the visual layer is resynced by calling
`board.refresh()` (a full teardown-and-rebuild of card/minion nodes), awaiting
`get_tree().process_frame` as needed to let `queue_free` complete first.
**Rationale**: Incremental UI patching has repeatedly been a source of
desync bugs in this codebase; a full rebuild from `GameState` is slower but
always correct, which matters more for a solo-maintained project than raw
frame cost at this scale.

### III. Data-Driven Card Content
Card definitions live as data (`data/cards/*.json`, one file per faction,
loaded through `CardData`/`CardDatabase`), never as hardcoded per-card
branches in GDScript. New mechanics are implemented as reusable, named
ability constants/handlers in `scripts/game/abilities.gd` (optionally
parameterized, e.g. `shielded_N`) so a card's JSON entry only ever *selects*
behavior, it never defines new behavior inline.
**Rationale**: Keeps the card count scalable by a single developer — adding a
card should mean editing JSON and, at most, adding one reusable ability
function, not touching game flow code.

### IV. Documentation Stays in Sync with Code
`.docs/*.md` describes the actual implemented system, not aspirational
design. Whenever a change alters a documented signature, file path, autoload,
ability constant, AI behavior, or the working/TODO status of a feature, the
corresponding doc file (see the table in `CLAUDE.md`) MUST be updated in the
same change, following the source-of-truth mapping and rules already defined
in `.claude/skills/sync-docs.md`.
**Rationale**: This is a solo project without a team wiki; stale docs are
worse than no docs because future work (including AI-assisted work) trusts
them as ground truth.

### V. Starter Deck Integrity
New cards default to excluded from every starter deck (`"in_starter": false`
in their JSON entry) unless a design decision explicitly adds them to a named
starter deck's composition.
**Rationale**: Starter decks are curated, fixed lists (e.g. the Teal starter
deck's exact 40-card makeup documented in `.docs/status.md`); new content
must not silently change what a new player receives.

## Technology & Project Constraints

- Engine/language: Godot 4.3, GDScript, tabs (not spaces) for indentation.
- No CLI build step for local play: the game is run and iterated on inside
  the Godot editor (F5 / Play). Headless CLI dev hooks
  (`--mcts-benchmark`, `--campaign-test`, `--tank-test`) exist specifically to
  verify logic that has no visual surface to manually click through.
- Card/ability data lives under `data/cards/*.json` and
  `data/campaign_modifiers.json`; runtime singletons are registered as
  autoloads per the table in `.docs/architecture.md` and MUST be kept current
  there when added, renamed, or removed.
- Networking (relay server, ranked/multiplayer) lives in `server/relay.js`
  and the `Net`/`Auth` autoloads; server state (ladder rank, matchmaking Elo)
  is authoritative on the server, never reconstructed client-side.

## Development Workflow

- There is no formal unit-test suite; correctness is verified through (a) the
  headless dev CLI hooks for AI/logic-only paths, and (b) manual playtesting
  in the editor for anything with a visual surface. New game-logic features
  should be checked against at least one of these before being considered
  done.
- Changes that add or alter a feature update `.docs/status.md`'s "What's
  Working" / "TODO" sections per Principle IV — do not mark something working
  without evidence it runs.
- Given the solo-maintainer scope, prefer the smallest change that correctly
  implements the requested behavior over speculative abstraction, config
  flags, or generalized frameworks for cases that do not yet exist.

## Governance

This constitution supersedes ad-hoc practice for anything it explicitly
covers. Where it is silent, follow `.docs/conventions.md` and the other
`.docs/*.md` files.

**Amendment procedure**: edit this file directly (via `/speckit-constitution`
or by hand), regenerate the Sync Impact Report at the top of the file, and
bump the version per the policy below. No separate approval body exists for
this solo project; the amendment itself, committed with a `docs:` commit, is
the record.

**Versioning policy** (semantic versioning applied to governance):
- MAJOR: a principle is removed or redefined in a backward-incompatible way.
- MINOR: a new principle or section is added, or existing guidance is
  materially expanded.
- PATCH: wording, typo, or clarification changes with no rule-level change.

**Compliance review**: when implementing a feature via Spec Kit commands
(`/speckit-plan`, `/speckit-implement`, etc.), check the plan against these
principles before generating tasks; a violation must be justified in the
plan's Complexity Tracking (or equivalent) section or the plan must be
revised.

**Version**: 1.0.0 | **Ratified**: 2026-09-11 | **Last Amended**: 2026-09-11
