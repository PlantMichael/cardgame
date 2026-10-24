# Quickstart: Validating Server-Authoritative Ranked

Runnable scenarios proving the feature end to end, phase by phase. Details live
in [data-model.md](./data-model.md) and [contracts/](./contracts/).

## Prerequisites

- Node ≥ 20, the Godot 4.7 console build on `PATH` (`GODOT_BIN` for the server
  tests), a **disposable** Postgres (`DATABASE_URL=postgres://localhost/cardgame_auth_test`).
- `cd server && npm install`.

## Phase A — rules core is complete (no server needed)

```bash
godot --headless --path . -- --core-tests
godot --headless --path . -- --parity-test
```

Expect `0 failed` and `RESULT: PASS`:
- every migrated effect family has a core test that plays its full decision
  sequence **through `answer_choice` only** (no controller);
- the controller-purity check passes (no rules mutators called from
  `game_manager.gd`, `mp_game_manager.gd`, `ai_controller.gd`);
- `--parity-test` plays 1,000 seeded AI-vs-AI matches, replays each from its
  `(seed, decks, command log)` and confirms identical final state hashes
  (SC-002), and that the local and rules-core results agree.
- Existing hooks still pass: `--newcards-test`, `--locations-test`, `--tank-test`,
  `--campaign-test`.

## Phase B — the host and a thin client

```bash
cd server && npm test
```

Expect all of these to pass:
- **Protocol**: `create` → `command` → views for both seats; the opponent's view
  never contains hand contents, deck order, or unrevealed draws (frame scan, SC-001).
- **Cheating suite** (≥ 200 cases): illegal action, out-of-turn, stale/duplicate
  `client_seq`, forged seat, forged winner, a client-supplied deck, an action for
  another player's match, oversized/malformed frames, `report_ranked_result` for
  a server-run match — none changes state or the result; each is audited.
- **Version**: a mismatched `rules_version` returns `update_required` and never
  queues.

Manual: run two clients against a local relay with `RANKED_AUTHORITATIVE=1`, play
a full ranked match including a mulligan, a challenge, a rummage and a transform
choice. Everything behaves as in today's ranked.

## Phase C — clocks, reconnect, persistence

```bash
cd server && npm test -- --grep "clock|reconnect|restart"
```

Expect: a 10-second disconnect then `match_join` resumes at the right state; a
turn timer expiry ends the turn with defaults and logs `timeout_default`;
passing the 60 s grace settles a forfeit; both gone → `abandoned`, no rank
change; killing the host process mid-match → relay restarts it, replays the log,
and the match continues (or is voided with no rank change if hashes differ).

## Phase D — settlement, statistics, operations

- Finish a server-run match: each player's ladder state moves **once**, by the
  existing ladder rules; sending `report_ranked_result` afterwards (or twice, or
  with the opposite result) changes nothing (SC-005).
- The stats store holds a `verified`, `attested_by = server` record with
  draw/keep/play facts for **both** sides (SC-006).
- `RANKED_AUTHORITATIVE=0` → new ranked matches use the previous flow; running
  server-run matches finish (SC-008).
- Load: `node server/test/load.js --matches 100` keeps p95 action latency under
  0.3 s (SC-003/007).

## Done when

All automated suites above pass, one manual two-client match is played in each
phase's mode, and `.docs/authoritative-server.md` records what was verified and
what was not (notably: headless-container size/cold start, and capacity numbers
from the load run).
