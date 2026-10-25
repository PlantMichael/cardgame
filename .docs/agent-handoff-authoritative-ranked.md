# Agent handoff: server-authoritative ranked matches (spec 003)

Spec: `specs/003-authoritative-ranked-server/` (spec, plan, research, data-model, contracts, quickstart, tasks.md with ticks and honest notes per task).
Goal: ranked human-vs-human matches run their rules on the server so a modified client cannot change rules, see hidden cards or fake a result.
Reference doc (read this first): [`.docs/authoritative-server.md`](authoritative-server.md) — architecture, both protocols, the env knobs, the deploy/drain procedure, the security review and the verified/not-verified list.
State: code complete, load-tested, security-reviewed, documented. **Flag still off by default**, and **still never played by two real clients against a live relay with Postgres.**

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

- `cd server && GODOT_BIN=<godot console exe> npm test`: **42/42** (protocol, hidden-info, 216-case cheating, manager flows, settlement, relay glue, facts handoff, frame budgets).
- `godot --headless --path . -- --core-tests`: 703 checks pass. `-- --parity-test`: 1000 matches replay identically.
- `GODOT_BIN=<godot> node server/test/load.js --matches=100 --turns=40`: 100 concurrent matches on one host process, p50 136 ms / p95 159 ms / p99 178 ms / max 307 ms accepted-action latency (budget 300 ms p95), 586 MB peak host memory, 609 accepted actions/s, 75 of 100 played to game over. Numbers and two measurement traps in `research.md` §13.
- Security review done (findings and fixes listed in `.docs/authoritative-server.md`): per-socket frame budget before the session lookup, verified-token cache, joins/pings metered, the host's `replay` op tightened.
- After adding a `class_name` script (or after a fresh clone, since `.godot/` is not in git) run `godot --headless --path . --import` once, or every `class_name` added since the last import fails to resolve; then `git checkout` any churned `.import` files.

## NOT verified / not done

- **T005 Docker image still never built.** Docker Desktop's engine would not come up on this machine (`docker info` fails with `dockerDesktopLinuxEngine: The system cannot find the file specified`), so image size and cold start are still unknown. Prepared for it: a `.dockerignore` (without it the build context includes a 2.2 GB `.git` and 145 MB `.godot`) and the five case-mismatched card art paths (`LaserBarrage.png`, `BlackHole.png`, `Twinfang.png`, `Voidstalker.png`, `LogiRunner.png`) now match the files on disk, which is what would silently drop that art on a case-sensitive Linux image. Note `COPY assets` is 294 MB of art the rules do not need, but `main.gd` preloads `Board.tscn` and menu textures, so trimming it needs a host-only entry scene first.
- PgStore / PgSettleRepo never run against real Postgres. Table columns were matched to the legacy path by reading it.
- Client never played against a live relay; reconnect (T056), mulligan flow, choice prompts, game-over display unproven. Manual runs T050, T057, T062, T076 pending.
- T077 deploy + release note not done (deliberately last; the deploy/drain procedure is written up).
- Known edge: if the client's 10 s search timeout falls back to AI just as the server pairs it, the paired opponent waits alone until the grace forfeit/abandon.
- Fatigue damage is not announced by the thin client (host clears draws; no fatigue event).

## Suggested next steps

1. Start Docker Desktop by hand, then `docker build -f server/Dockerfile -t cardgame-relay .`; record size and cold start in `research.md` §7, and check the Linux host boots (`docker run --rm -e GODOT_BIN=/usr/local/bin/godot -e PROJECT_DIR=/app -w /app/server cardgame-relay npm test` runs the whole suite inside the image).
2. Stand up Postgres (a container is enough), run the relay with `RANKED_AUTHORITATIVE=1`, and play two clients through mulligan, a challenge, a rummage and a transform choice, a drop/rejoin and a concede (T050, T057, T062).
3. Walk `quickstart.md` Phases A–D, tick SC-001…SC-010 with evidence (T076), then turn the flag on in the deployed relay with the release note (T077).
