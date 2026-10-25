# Agent handoff: server-authoritative ranked matches (spec 003)

Spec: `specs/003-authoritative-ranked-server/` (spec, plan, research, data-model, contracts, quickstart, tasks.md with ticks and honest notes per task).
Goal: ranked human-vs-human matches run their rules on the server so a modified client cannot change rules, see hidden cards or fake a result.
Reference doc (read this first): [`.docs/authoritative-server.md`](authoritative-server.md) — architecture, both protocols, the env knobs, the deploy/drain procedure, the security review and the verified/not-verified list.
State: code complete, load-tested, security-reviewed, documented, and the server image builds and passes the suite on Linux. **Flag still off by default**, and **still never played by two real clients against a live relay with Postgres.**

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
- `docker build -f server/Dockerfile -t cardgame-relay .`: **1.3 GB**, match host ready 3.3-3.6 s after process start (~11.5 s cold / ~4.9 s warm from `docker run`), and `docker run --rm cardgame-relay sh -c 'node --test test/*.test.js'` is **42/42 in 22 s** — so the rules really do run on Linux, on a case-sensitive filesystem. Two fixes it forced: `libxrandr1` does not exist in bookworm (it is `libxrandr2`), and the headless binary needs no X/GL libraries at all, which saved 300 MB. Remaining size levers in `research.md` §7.
- Security review done (findings and fixes listed in `.docs/authoritative-server.md`): per-socket frame budget before the session lookup, verified-token cache, joins/pings metered, the host's `replay` op tightened.
- After adding a `class_name` script (or after a fresh clone, since `.godot/` is not in git) run `godot --headless --path . --import` once, or every `class_name` added since the last import fails to resolve; then `git checkout` any churned `.import` files.

## NOT verified / not done

- The image is **1.3 GB** and 409 MB of that is `assets` plus their build-time imports, which the rules never touch. They are in there only because `main.gd` (which owns the `--match-host` hook) preloads `Board.tscn`, the menu wallpaper, the cursor and a font; trimming them needs a host-only entry scene that does not reach the UI first. Not done, and not blocking.
- PgStore / PgSettleRepo never run against real Postgres. Table columns were matched to the legacy path by reading it.
- Client never played against a live relay; reconnect (T056), mulligan flow, choice prompts, game-over display unproven. Manual runs T050, T057, T062, T076 pending.
- T077 deploy + release note not done (deliberately last; the deploy/drain procedure is written up).
- Known edge: if the client's 10 s search timeout falls back to AI just as the server pairs it, the paired opponent waits alone until the grace forfeit/abandon.
- Fatigue damage is not announced by the thin client (host clears draws; no fatigue event).

## Suggested next steps

1. Stand up Postgres (a container is enough), run the relay with `RANKED_AUTHORITATIVE=1`, and play two clients through mulligan, a challenge, a rummage and a transform choice, a drop/rejoin and a concede (T050, T057, T062).
2. Walk `quickstart.md` Phases A–D, tick SC-001…SC-010 with evidence (T076), then turn the flag on in the deployed relay with the release note (T077).
