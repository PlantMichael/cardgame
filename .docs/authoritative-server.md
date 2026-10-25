# Server-Authoritative Ranked Matches

Ranked human-vs-human matches run their **rules on the server**, so a modified
client cannot change a rule, see a hidden card or fake a result. Everything here
is behind one switch (`RANKED_AUTHORITATIVE`); with the switch off the relay
behaves exactly as it did before (peer-hosted ranked matches, client-reported
results).

Spec and contracts: [`specs/003-authoritative-ranked-server/`](../specs/003-authoritative-ranked-server/).

## The three processes

| Process | What it is | What it owns |
|---|---|---|
| **Relay** (`server/relay.js`, Node) | the only process a client talks to | accounts, sessions, matchmaking, clocks, the database, settlement |
| **Match host** (`scripts/game/match_host.gd`, headless Godot) | `godot --headless --path <project> -- --match-host --port=<n>` | the rules: one `GameState` per live match, nothing else |
| **Postgres** | the log | `ranked_matches`, `ranked_match_actions`, `ranked_match_audit`, `ranked_settlements`, `players` |

The host binds `127.0.0.1` only, speaks newline-delimited JSON, and requires a
`hello` frame carrying a per-boot secret passed in `MATCH_HOST_SECRET` (an empty
secret refuses every connection). It holds no accounts, no tokens, no database
handle and reads no wall clock inside the rules: it only answers "what do the
rules allow". The relay is its only client.

## Server-side files

| File | Role |
|---|---|
| `server/authoritative/relay_wire.js` | the glue `relay.js` uses: the flag, env knobs, per-socket frame budget, the short-lived session-token cache, pairing and routing |
| `server/authoritative/match_manager.js` | seats, epochs, the command path (validate → host → **log** → ack → broadcast), clocks, disconnects, forfeits, resume-from-log, settlement hand-off |
| `server/authoritative/host_process.js` | supervises the Godot host: spawn, secret, `hello`, `request(op, payload)` with `rid` correlation, 5 s pings, restart after 3 misses |
| `server/authoritative/protocol.js` | validation of every client match message: 8 KB frame cap, strict field allow-lists, 20 actions/s per seat, 30 frames/s per socket, generic refusal reasons |
| `server/authoritative/decks.js` | loads `data/cards/*.json` and `data/starters.json`; `validateDeck` mirrors `DeckManager`'s size/copy/faction rules |
| `server/authoritative/schema.js` | the DDL (`CREATE TABLE IF NOT EXISTS`) and `PgStore` |
| `server/authoritative/memory_store.js` | the same store interface in memory, for tests and a database-less dev relay |
| `server/authoritative/settle.js` | idempotent ladder settlement from the **server's** result, using `server/ladder.js` |
| `server/ladder.js` | `nextRankState`/`nextElo`, extracted verbatim from `relay.js` so both paths share one ladder math |
| `server/tools/matches.js` | maintainer CLI (`status`, `history`, `replay`, `audit`); reads `DATABASE_URL`, no network endpoint, every call writes an audit row |
| `server/test/load.js` | the load test (not part of `npm test`): N matches at once through one host, p95 accepted-action latency |

## Client-side files

| File | Role |
|---|---|
| `scripts/game/match_host.gd` | `MatchHost` — the headless rules host described above (it ships in the game project because the rules do) |
| `scripts/game/remote_match_client.gd` | `RemoteMatchClient` — the **thin** ranked client: sends commands, holds no rules, rebuilds the board from each `match_view`, plays animations from the filtered events |
| `scripts/game/match_recorder.gd` | `MatchRecorder` — per-match card facts observed from the event feed, returned in `over.facts` (spec 002) |
| `scripts/game/net.gd` | `queue_ranked(deck_name)`, `send_match`, `match_message_received`, `server_ranked_match_found`, `ranked_refused`, `publish_settled_outcome` |
| `scripts/game/main.gd` | routes a `server_run` match to `RemoteMatchClient` (otherwise `MpGameManager`), shows the refusal banner |

## What a match looks like

1. **Queue.** `queue_ranked` carries the deck *name* and the client's
   `RULES_VERSION`. A version mismatch answers `ranked_refused: update_required`;
   at the live-match ceiling, `ranked_busy`; an unknown or illegal deck,
   `invalid_deck`; a player already in a match, `already_in_match`.
2. **Pairing.** The relay picks the match id (`rk_` + random), the seed
   (`crypto`), the first seat and both decks — read from the `decks` table by
   name, or from `data/starters.json` for a shipped starter deck — and validates
   them against its own card files. Nothing about a match comes from a client.
3. **Join.** Each client sends `match_join`; the first `match_view` tells it
   which seat it is. Both seats connected → the match goes `active` and the
   mulligan clock starts.
4. **Commands.** `match_command` with an increasing `client_seq` →
   validate → host `command` with `expect_seq` → **the action row is committed
   before the ack** → `match_ack` to the sender and `match_view` to both seats,
   each with only that seat's events. A refused command changes nothing, costs
   its `client_seq`, and is audited.
5. **Clocks** (relay wall time only): 90 s per turn or open choice, 90 s for the
   mulligan, 60 s disconnect grace. A turn expiry calls host `timeout`
   (`GameState.resolve_defaults`) and logs a `timeout_default` row; three in a
   row forfeits. Each tick broadcasts `match_clock`.
6. **Endings.** concede → `finished (conceded)`; grace expiry →
   `finished (forfeit_disconnect)`; three timeouts → `forfeit_timeout`; both
   seats gone → `finished (abandoned)`, **no settlement**; a seat that never
   arrives → `voided`; a fault (unloggable action, hash mismatch on resume) →
   `voided (voided_fault)` and `match_voided`, no rank change.
7. **Settlement.** On entry to a settling `finished` state, `settle.js` reads
   both players' ratings from `players`, runs the existing ladder math and writes
   `ranked_settlements` + `players` in one transaction. `INSERT … ON CONFLICT DO
   NOTHING` keyed `(match_id, player_id)` makes it exactly-once; a retry replays
   the stored outcome. `report_ranked_result` from a client is refused (and
   audited) for any server-run match id.

## Protocols

- Client ↔ relay: [`contracts/client-match-protocol.md`](../specs/003-authoritative-ranked-server/contracts/client-match-protocol.md)
  (`match_join`, `match_command`, `match_mulligan`, `match_concede`, `match_ping`
  up; `match_view`, `match_ack`, `match_error`, `match_clock`, `match_over`,
  `match_voided`, `opponent_disconnected`/`_reconnected` down).
- Relay ↔ host: [`contracts/match-host-ipc.md`](../specs/003-authoritative-ranked-server/contracts/match-host-ipc.md)
  (`hello`, `create`, `command`, `timeout`, `view`, `replay`, `drop`, `stats`).
- Rules core events and choices: [`contracts/rules-core-choices-events.md`](../specs/003-authoritative-ranked-server/contracts/rules-core-choices-events.md).

## Operating it

| Variable | Default | Meaning |
|---|---|---|
| `RANKED_AUTHORITATIVE` | unset (off) | `1`/`true` runs ranked matches on the server |
| `GODOT_BIN` | — | the Godot binary the relay spawns as the match host (required when the flag is on) |
| `PROJECT_DIR` | the repo root | the Godot project the host loads |
| `RANKED_MAX_LIVE_MATCHES` | 100 | live-match ceiling; past it, queueing answers `ranked_busy` |
| `RANKED_TURN_SECONDS` | 90 | turn / open-choice limit |
| `RANKED_MULLIGAN_SECONDS` | 90 | mulligan limit |
| `RANKED_GRACE_SECONDS` | 60 | disconnect grace before a forfeit |

The flag only affects **new** pairings. Turning it off leaves live server-run
matches running to their end; turning it on does not disturb peer-hosted matches
already in progress.

### Deploy procedure

1. Build the image: `docker build -f server/Dockerfile -t cardgame-relay .`
   — the relay and the pinned Godot host in one image, **1.3 GB**, with the
   match host ready about 3.5 s after the process starts (`.dockerignore` keeps
   the build context to the project rather than the 2.2 GB `.git`). Smoke-test
   the image itself with
   `docker run --rm cardgame-relay sh -c 'node --test test/*.test.js'`:
   42/42 in ~22 s means the Linux host is running real matches.
2. Deploy with `RANKED_AUTHORITATIVE` **unset** first and watch
   `node tools/matches.js status`. The relay logs the rules version at boot.
3. **Drain before a restart:** stop pairing (unset the flag or take the instance
   out of rotation), let the live matches finish — `tools/matches.js status`
   reports the live count — and only then restart. A restart with matches in
   flight is survivable but not free: at boot the manager loads every `active`
   match, replays its logged commands into a fresh host and resumes it; a replay
   that does not end on the last logged `state_hash` voids that match with no
   rank change.
4. The same resume runs whenever the host process itself dies: the supervisor
   restarts it and the manager replays every live match from the log.
5. Roll back by unsetting the flag and restarting: the previous ranked flow is
   one switch away as long as the client build still has the legacy path.

### Checking on it

```
node tools/matches.js status            # live count, capacity, 24 h endings, recent faults
node tools/matches.js history <id>      # the action log for one match
GODOT_BIN=<godot> node tools/matches.js replay <id>   # re-run the log, confirm the hash
node tools/matches.js audit [limit]     # refusals and tool use
```

## Security review (T074)

What was checked, and what it rests on:

| Property | How it holds |
|---|---|
| the host is not reachable from outside | `TCPServer.listen(port, "127.0.0.1")`; a `hello` with the per-boot secret is the only thing an unauthenticated connection may send, and an **empty** `MATCH_HOST_SECRET` refuses everything rather than letting anything through |
| no host operation is reachable from a client message | the client protocol has five message types (`match_join`, `match_command`, `match_mulligan`, `match_concede`, `match_ping`); host ops (`create`, `replay`, `timeout`, `drop`, `view`, `stats`) are only ever called by the manager |
| a client cannot act for someone else | the seat comes from the session token's account, and only the seat's **current** connection may speak for it; the command's own `actor` field is overwritten by the host with the submitting seat |
| a client cannot choose its own cards, seed or opponent | decks are read server-side by name and validated against the server's card files; seed, first seat and match id come from `crypto` on the relay |
| no deck, hand or seed ever reaches a client | per-seat `to_net_dict(seat)` views only, checked frame by frame in `test/hidden_info.test.js`; a view carries no deck contents and no RNG state |
| a result cannot be forged | the winner comes from the host's `over` block; `report_ranked_result` is refused and audited for a server-run match id; settlement reads ratings from `players` |
| frames are capped and metered | 8 KB per frame, 20 actions/s per seat, 30 frames/s per socket; the host drops a connection whose unterminated frame passes 256 KB |

Findings from this pass, all fixed in the same change:

1. **A flood of match frames was a flood of database queries.** Every
   `match_*` message did a `sessions` lookup before anything metered it, so an
   unauthenticated socket could turn cheap frames into database load (and audit
   rows). Fixed with a per-socket 30 frames/s budget spent *before* the lookup,
   a type/length check on the token, and a 10 s per-socket cache of a verified
   token so a normal match is not one query per action.
2. **Joins and pings were not metered.** The per-seat limiter only covered
   commands, but a `match_join` costs a host round trip and an audit row and a
   `match_ping` costs a reply. The limiter now runs for every message type
   (`test/rate_limit.test.js`).
3. **`replay` was looser than the live path.** The host's `replay` op executed
   whatever command type a logged row carried and would overwrite a live match
   of the same id. It now refuses a command outside `ALLOWED_COMMANDS` (the
   caller voids the match), refuses an id it already holds, and honours the
   match ceiling.

Accepted, with reasons:

- A session token is a bearer credential: any socket presenting a valid token
  acts as that account. That is how the rest of the relay already works, and
  the 10 s cache bounds how long a revoked token keeps working on a socket that
  already used it.
- An invalid frame still writes one audit row. That is the spec's requirement
  (FR/T041); the per-socket budget is what bounds it.

## Verified / not verified

Verified locally (Windows, Godot 4.7.2, Node 24):

- `cd server && GODOT_BIN=<godot> npm test` — 39/39: host IPC protocol, a
  per-frame hidden-information sweep, 216 cheating cases, manager flows
  (clocks, reconnect, forfeits, restart-replay), settlement idempotency, relay
  glue, the stats hand-off.
- `godot --headless --path . -- --core-tests` — 703 checks, and
  `-- --parity-test` — 1000 matches replay identically.
- `GODOT_BIN=<godot> node server/test/load.js --matches=100` — see
  [`research.md` §13](../specs/003-authoritative-ranked-server/research.md) for
  the recorded numbers.
- The Docker image builds (1.3 GB) and the Linux host inside it passes the same
  42-test suite in ~22 s. The host answers `stats` 3.3-3.6 s after its process
  starts, and a fresh container reaches that point in ~11.5 s cold / ~4.9 s
  warm. Numbers, the two build fixes and the remaining size levers (409 MB of
  assets and their imports, which need a host-only entry scene) are in
  [`research.md` §7](../specs/003-authoritative-ranked-server/research.md).

Not verified:

- **No two-client manual run.** Mulligan, choice prompts, reconnect, the
  game-over/rank display and the concede button have never been exercised
  against a live relay by real clients (spec tasks T050, T057, T062, T076).
- **Postgres.** `PgStore` and `PgSettleRepo` have only been run against the
  in-memory store; the column lists were matched to the legacy path by reading
  it.
- A client whose 10 s search timeout falls back to an AI opponent at the moment
  the server pairs it leaves the paired opponent waiting for the grace forfeit.
- Fatigue damage is not announced by the thin client (the host clears the
  local-draw list and there is no fatigue event in the feed).
