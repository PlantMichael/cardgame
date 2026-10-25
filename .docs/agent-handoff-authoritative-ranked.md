# Agent handoff: server-authoritative ranked matches (spec 003)

Spec: `specs/003-authoritative-ranked-server/` (spec, plan, research, data-model, contracts, quickstart, tasks.md with ticks and honest notes per task).
Goal: ranked human-vs-human matches run their rules on the server so a modified client cannot change rules, see hidden cards or fake a result.
State: code complete for most of the path, **flag off by default**, **never exercised end-to-end** (no Docker, Postgres or two-client run was possible).

## Architecture
- Node relay (`server/relay.js`) + headless Godot **match host** (`scripts/game/match_host.gd`, localhost TCP, newline JSON, per-boot secret) + `MatchManager` (`server/authoritative/match_manager.js`).
- The rules core is `GameState` (`scripts/game/game_state.gd`): validated `execute(cmd)` boundary, seeded RNG, state hash, per-seat views `to_net_dict(seat)`, event feed, pending-choice model, mulligan gate, concede, `apply_timeout`. Controllers hold no rules (core test enforces).
- Manager: log-before-ack to the store, seats/epochs, clocks (turn 90s, mulligan 90s, grace 60s), forfeits, abandon, resume-from-log after host restart (hash mismatch voids the match), settlement callback.
- Settlement: `server/authoritative/settle.js` (idempotent via `ranked_settlements`), math in `server/ladder.js` (extracted verbatim from relay.js).
- Relay glue: `server/authoritative/relay_wire.js`; relay changes are behind `RANKED_AUTHORITATIVE=1`. Env knobs: `RANKED_MAX_LIVE_MATCHES`, `RANKED_TURN_SECONDS`, `RANKED_MULLIGAN_SECONDS`, `RANKED_GRACE_SECONDS`, `GODOT_BIN`, `PROJECT_DIR`.
- Client: `scripts/game/remote_match_client.gd` (thin client), `net.gd` (`server_ranked_match_found`, `ranked_refused`, `match_message_received`, `send_match`, `publish_settled_outcome`), `auth.gd` (`queue_ranked(deck_name)`), `main.gd` (routing, refusal banner), `board.gd` (`concede_enabled`, `concede_requested`, `show_notice`).
- Stats: `scripts/game/match_recorder.gd` runs in the host, facts returned in `over.facts`, stored in `ranked_matches.facts`; spec 002 amended.
- Maintainer CLI: `server/tools/matches.js` (status/history/replay/audit).
- Server-run matches may use shipped starter decks by name (`data/starters.json`).

## Verified (local)
- `cd server && GODOT_BIN=<godot console exe> npm test`: 38/38 (protocol, hidden-info, 216-case cheating, manager flows, settlement, relay glue, facts handoff).
- `godot --headless --path . -- --core-tests`: 703 checks pass. `-- --parity-test`: 1000 matches replay identically.
- After adding a `class_name` script run `godot --headless --path . --import`, then `git checkout` the churned `.import` files.

## NOT verified / not done
- T005 Docker image never built (`server/Dockerfile` unbuilt): size, cold start unknown. Headless Godot warns about case-mismatched card image names (e.g. `logirunner.png` vs `LogiRunner.png`); this may break on a case-sensitive Linux image. Check first.
- PgStore / PgSettleRepo never run against real Postgres. Table columns were matched to the legacy path by reading it.
- Client never played against a live relay; reconnect (T056), mulligan flow, choice prompts, game-over display unproven. Manual runs T050, T057, T062, T076 pending.
- T073 load test (100 concurrent matches, p95 <= 0.3 s) not written; was about to drive the host over IPC with a bot.
- T074 security review, T075 docs (`.docs/authoritative-server.md`, CLAUDE.md row, architecture/status/overview updates, run sync-docs), T077 deploy + release note not done.
- Known edge: if the client's 10 s search timeout falls back to AI just as the server pairs it, the paired opponent waits alone until the grace forfeit/abandon.
- Fatigue damage is not announced by the thin client (host clears draws; no fatigue event).

## Suggested next steps
1. Build the Docker image, record size/cold start, fix the case-mismatch assets.
2. Stand up Postgres, run relay with `RANKED_AUTHORITATIVE=1`, play two clients through mulligan, a challenge, a rummage and a transform choice, a drop/rejoin, a concede.
3. Write `server/test/load.js`, do the security review, write docs, run `/sync-docs`, tick remaining tasks, then enable the flag.
