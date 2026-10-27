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
| `server/authoritative/schema.js` | the match DDL (`CREATE TABLE IF NOT EXISTS`) and `PgStore` |
| `server/schema_legacy.js` | the account/ladder DDL (`players`, `sessions`, `decks`, `owned_cards`, `ranked_settlements`), which `relay.js` runs at boot. It lives here because `relay.js` cannot be required without starting a server, so a test had no way to create the schema it tests against except by re-typing it |
| `server/authoritative/memory_store.js` | the same store interface in memory, for tests and a database-less dev relay |
| `server/authoritative/settle.js` | idempotent ladder settlement from the **server's** result, using `server/ladder.js` |
| `server/ladder.js` | `nextRankState`/`nextElo`, extracted verbatim from `relay.js` so both paths share one ladder math |
| `server/tools/matches.js` | maintainer CLI (`status`, `history`, `replay`, `audit`); reads `DATABASE_URL`, no network endpoint, every call writes an audit row |
| `server/test/load.js` | the load test (not part of `npm test`): N matches at once through one host, p95 accepted-action latency |
| `server/test/e2e_ranked.js` | the end-to-end run (not part of `npm test`): a real relay, two websocket clients, a real Postgres, from registration to settlement |
| `server/test/pg_store.test.js` | `PgStore`/`PgSettleRepo` against a real Postgres; skipped unless `DATABASE_URL` is set and looks disposable |

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

### Running the whole thing locally

The DB-backed tests and the end-to-end script need a **disposable** Postgres;
they truncate `players`, `decks` and the `ranked_*` tables, and refuse to run
against a URL that does not look disposable (local host, or a database name
containing test/tmp/scratch).

```bash
docker run -d --name cardgame-pg -e POSTGRES_PASSWORD=pg -p 5432:5432 postgres:16
export DATABASE_URL=postgres://postgres:pg@127.0.0.1:5432/postgres
export GODOT_BIN=/path/to/godot
cd server && npm test                 # 53/53 with the database, 42/42 without
node test/e2e_ranked.js --turns=80    # two scripted clients, start to settlement
```

Any local cluster works — the runs recorded above used a Debian-packaged
Postgres 14 inside WSL, reached from Windows on `127.0.0.1:5432`, because
Docker Desktop would not start on that machine. Both schemas are created on
demand: the account/ladder tables from `server/schema_legacy.js` (the same
statements `relay.js` runs at boot) and the match tables from
`server/authoritative/schema.js`.

`e2e_ranked.js` starts its own relay on port 8099 and kills the process tree
when it is done; nothing is left listening.

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

### Ranked AI summaries

Public win rates are exposed read-only at `/data/v1/stats/card-winrates.json` by the relay and the catalog service. `server/card_winrates.js` shares the relay port with websocket upgrades and uses the existing pool; the catalog proxies only validated public aggregate fields. It counts BOTH recorded AI starting decks (human outcome and opposite AI outcome), plus settled authoritative PvP seats, deduplicates copies per seat-game, and filters the committed published collectible catalog at both endpoints. Custom decks count; shared cards get one win and one loss per match. Historical saved decks count on read without a backfill or extra settlements; missing/malformed deck fields add no samples for that seat. A successful snapshot is cached for 60 seconds; failed reads return generic 503 without blocking matchmaking. The relay Docker image must include `catalog/public/data/v1/`.

The owner selected one-game publication for testing, mixing AI/PvP and rules versions. AI results remain unverified. Raw identities/deck lists are absent, but changing small counts can reveal card inclusion/outcomes; this is not an anti-differencing API. Deploy catalog first, then relay: catalog requires upstream `methodology.aiSeats: "both"` and returns 503 for old human-only metadata. No client/web export or new schema is needed. See [catalog contract](../catalog/README.md#live-card-win-rates) for response fields, optional catalog `CARD_WINRATES_ORIGIN`, failure behavior and operator proof. For a read-only Railway query covering both sides, use `server/tools/card-winrates.sql` (requires authoritative tables; includes all recorded IDs).

Completed ranked games against the local AI are recorded separately from
server-run PvP. The local manager snapshots both starting decks and attaches an
optional `ai_match` object to `report_ranked_result`, with `player_deck` and
`opponent_deck` (card ID arrays), `ai_level` (1–10), `turns` and `rules_version`.
The relay validates bounded fields and known non-token IDs, and adds fixed
`mode: "ranked_ai"` and `source: "client_reported"` labels. These records are
unverified and must not be counted as verified PvP statistics. They are summaries,
not replays or per-card draw/play counters.

The summary lives in **`ranked_settlements.ai_match`**, with the existing `won`,
`player_id`, `match_id` and `settled_at`. It is inserted in the same transaction
as the ladder update. Retrying a settled result preserves the first summary and
awards nothing twice; matchmaking Elo remains unchanged for AI. These records
work with `RANKED_AUTHORITATIVE` either on or off. They do not create a row in
`ranked_matches` or any public catalog files.

```sql
SELECT match_id, won, settled_at,
       ai_match->>'ai_level' AS ai_level,
       ai_match->>'turns' AS turns,
       ai_match
FROM ranked_settlements
WHERE ai_match IS NOT NULL
ORDER BY settled_at DESC
LIMIT 10;
```

Deploy the new relay first (boot adds the nullable JSONB column to existing
databases), then rebuild and publish the game client. Older clients still settle
results but send no summaries; older rows keep `ai_match = NULL`. Only completed
ranked AI games on the updated client are captured. Quitting mid-game, results
lost while disconnected, and games played before this update are not recovered;
there is no new offline retry queue. Malformed supplied summaries fail the result
acknowledgment without writing a settlement. Campaign and casual AI games are
unchanged. No additional environment variable is needed.

Run `cd server && node --test test/ranked_ai_record.test.js`: validation runs
without services; setting a disposable `DATABASE_URL` enables real relay and
Postgres persistence/upgrade/replay/rollback checks. With `GODOT_BIN` also set,
the same test launches `test/fixtures/ranked_ai_client.tscn` against its localhost
relay to exercise the real GameManager → Auth → Net result producer. It creates
and removes its own database schema and never truncates other suites' records.

### Checking on server-run PvP

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

- `cd server && GODOT_BIN=<godot> npm test` — 42/42: host IPC protocol, a
  per-frame hidden-information sweep, 216 cheating cases, manager flows
  (clocks, reconnect, forfeits, restart-replay), settlement idempotency, relay
  glue, frame budgets, the stats hand-off. With `DATABASE_URL` also set it is
  **53/53**: the 11 extra are `test/pg_store.test.js`, which runs `PgStore` and
  `PgSettleRepo` against a real Postgres (14.24) — row round-trips with the
  types `resume()` expects, the `(match_id, seq)` key, `setStatus` COALESCE,
  `loadDeck`, and settlement awarding once under a retry and under two
  transactions racing. They skip when `DATABASE_URL` is unset, and refuse to
  run unless it looks disposable (local, or a name containing test/tmp/scratch).
- `GODOT_BIN=<godot> DATABASE_URL=<disposable> node server/test/e2e_ranked.js`
  — **30/30 checks**: a real `node relay.js` with the flag on, two websocket
  clients that register, queue with shipped starter decks, mulligan, play a
  full match to game over with a socket drop and rejoin in the middle, then a
  second match ended by conceding. It asserts against the database as it goes:
  the match row before either client joins, the action log numbered without a
  gap with the last hash equal to the final hash, the facts for spec 002, one
  settlement row per player, the winner's stored outcome equal to what their
  client was shown, and `report_ranked_result` refused for a server-run match.
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

- **The Godot client has still never played a server-run match.** The
  *protocol* has, through `server/test/e2e_ranked.js`, but
  `remote_match_client.gd`, the mulligan dialog, `board.prompt_choice`, the
  game-over/rank display and the concede button have not been driven by a
  person against a live relay (spec tasks T050, T057, T062, T076). The scripted
  run also never produced a challenge or a transform choice specifically: its
  bots answer whatever choice comes up with that choice's own default.
- **Postgres is a local 14.24 cluster, not the deployed one.** The deployed
  database already holds the legacy tables, so the first run with the flag on
  creates the `ranked_*` tables against existing data for the first time.
- A client whose 10 s search timeout falls back to an AI opponent at the moment
  the server pairs it leaves the paired opponent waiting for the grace forfeit.
- Fatigue damage is not announced by the thin client (the host clears the
  local-draw list and there is no fatigue event in the feed).
