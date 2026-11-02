# Moon bots

The simulation worker plays the real Godot rules without rendering, accounts, matchmaking, ladder rewards or a paid AI service. Its results live in `bot_matches`, completely separate from human ranked settlements.

| Bot | Release | Level | Drafting and decisions |
|---|---|---|---|
| Io | 1.0 | 10 | Midrange decks; tempo, board advantage and efficient mana use. |
| Callisto | 1.0 | 8 | Tribal/value decks; supporting combinations, setup and retaining useful pieces. Takes an immediate winning move. |
| Europa | 1.0 | 8 | Aggro decks; lower curve, attack power and early damage to the enemy hero. |
| Ganymede | 1.0 | 1 | Random faction decks and random legal actions; a 35% chance of ending a turn before selecting an action. Can miss obvious wins. |

`data/bot_profiles.json` owns the four identities. Named bots use distinct policies, not trained language models. Io has the largest search budget, but that does not establish a win-rate ordering; matchup results measure it. The normal level 10 opponent is an additional participant, `standard`, with the current numeric AI policy version as its release string.

Every release drafts one repeatable deck per participant/faction using the existing DeckManager builders, restricted to published collectible cards. Gameplay and search seeds vary each match. The schedule covers all six named-bot pairings and each bot against Standard AI. Adjacent rounds swap first player; the full 500-game cycle covers all 25 faction combinations with each first-player choice for all ten pairings. No bot joins the human queue. Bump a bot's release when changing its drafting, scoring or mistakes. Rules and shared AI policy versions are separate snapshot dimensions; historical releases are retained.

## Run

Use the relay image (`server/Dockerfile`), which already includes the pinned Godot binary, imported project, catalog and Node dependencies. Run **one separate worker service**, using the repository root as build context and `node bot_worker.js` as its start command from `/app/server`. It does not need a public port. Leave the relay's existing start command unchanged.

Required environment:

- `DATABASE_URL`: the intended database, using the same connection convention as the relay. Keep it in service secrets.
- `GODOT_BIN`: the installed Godot 4.7.2 binary; already `/usr/local/bin/godot` in the relay image.
- `BOT_STATE_DIR`: a dedicated persistent directory, for example a worker-only mounted volume at `/bot-state`. Keep the volume across restarts and release updates. Do not share it with game clients or delete its pending result.
- Optional `BOT_PAUSE_MS`: pause between saved games, default `60000`. One match runs at a time. This limits CPU use and keeps the default 30-day sample below the API's 50,000-game ceiling. Lower values consume more CPU and may require a shorter API time window.

Start continuously, or run a bounded smoke test:

```sh
node bot_worker.js
node bot_worker.js --matches=2
```

The bounded count means successfully saved games, including a recovered pending game; failed attempts do not consume it. SIGINT/SIGTERM stop play and clean up an active engine. A database advisory lock permits only one worker per database; a duplicate exits with an error. A lost lock stops the engine and fails the process so the supervisor can restart it.

For a Linux service manager, use `Restart=on-failure`, `RestartSec=30`, and `KillMode=control-group`. For Railway, give the worker the same image build, a persistent volume and an on-failure restart policy. Hosting runs continuously and consumes CPU/storage; choose its resource limits before enabling it. No live worker is enabled by this code change.

The worker gives each engine a temporary APPDATA/XDG_DATA_HOME, so it cannot load normal client accounts, saves or pending reports. A child is limited to 11 minutes; the match itself also has turn/action/time limits. Incomplete/stalled/crashed games are failed attempts, never fabricated draws. Failures back off 30 seconds. A completed result is atomically checkpointed in `state.json` before insertion. Retries reuse its UUID; a lost database acknowledgment cannot count it twice. Leave a pending game on its original release until it is saved before changing the roster. Malformed worker state fails closed for operator attention.

Roll out the relay and catalog from the same revision, then start the worker. The relay creates the additive table/index; the worker can also initialize them. No account migration, new login or Web export is needed. Before rollout the route is unavailable on old services; new services with no bot table return empty aggregates. Production deployment and continuous activation are separate operator actions.

## Website API

```js
const response = await fetch(`${CATALOG_ORIGIN}/data/stats/bot-matchups.json?days=30`);
if (!response.ok) throw new Error('Simulation stats unavailable');
const { bots, decks, matchups, games } = await response.json();
```

Both relay and catalog expose this anonymous GET/HEAD/OPTIONS route with CORS. `days` is 1–365, default 30; unknown, duplicate and malformed query fields return 400. Other methods return 405. Successful relay snapshots are cached/coalesced for 60 seconds. The catalog projects and validates public fields, refuses redirects, and limits upstream time to 5 seconds and size to 4 MiB. Errors return generic 503, without stale success or fabricated zero results. More than 50,000 source games or 4 MiB of aggregate data also returns 503: request a shorter window rather than silently dropping games. This first release does not provide pagination.

The envelope has `generatedAt`, `days`, physical `games`, `methodology`, `bots`, `decks`, and `matchups`. Methodology labels `source: "bot_simulation"`, `metric: "exact_starting_deck_matchup"`, `unit: "seat_game"`, `draws: "excluded_from_win_rate"`, `humanStats: "excluded"`.

- A bot row contains `key`, `id`, `name`, string `version`, numeric `level`, `style`, `rulesVersion`, `engineVersion` and statistics. Its key includes all those identity/version dimensions except display name/style, which must be changed under a new release.
- A deck row contains `key`, `botKey`, canonical composition `id`, sorted `cards: [{id,copies}]`, `factions` and statistics. Composition IDs use the existing deck API's sorted-copy SHA-256 identity. The same composition used by two personalities has two deck keys. Never join solely on composition ID.
- A matchup row contains `deckKey`, `opponentDeckKey` and statistics. Resolve both through `decks`, then `botKey` through `bots`. Each match supplies both perspectives; do not add the reverse again when displaying one deck's record.
- Statistics are `matches`, `wins`, `losses`, `draws`, `winRate`, `averageTurns`, `first` and `second`. `winRate` excludes draws and is null for all-draw samples; each first/second split contains `matches` and `wins`. They count seat-games, so bot/deck/matchup sample totals are twice `games`. A physical draw contributes two drawn seat-games. `averageTurns` is the rules engine's round-style turn counter, matching existing ranked-AI telemetry.

Keep a separate **Bot simulations** view. Keep bot release, rules version and engine version distinct when comparing results, and distinguish Standard AI from named personalities. For card inclusion rates, sum a card's containing deck rows within the desired bot/version/rules cohort; copies count once per seat-game. Exact starting decks describe inclusion, not a card's causal strength. Bot IDs are public synthetic identities; no player IDs, match IDs, random seeds or individual histories are exposed. Existing human `/data/stats/card-winrates.json` and `/data/stats/deck-matchups.json` routes retain their semantics and exclude this table entirely.

## Verify locally

Use a task-owned disposable PostgreSQL database and isolated Godot user storage:

```sh
godot --headless --path . -- --bot-tests
godot --headless --path . -- --core-tests
node --test server/test/moon_bots.test.js server/test/deck_matchups.test.js server/test/card_winrates.test.js server/test/ranked_ai_record.test.js
node --test 'catalog/test/*.test.mjs'
```

Set `GODOT_BIN` and disposable `DATABASE_URL` for the server tests; unset `DATABASE_URL` for catalog tests. The new server test crosses worker → actual Godot → PostgreSQL save/reload → relay HTTP → catalog HTTP. It also covers replay after a lost acknowledgment/write failure, historical version separation, public-deck rejection, draws, mirrors, human-stat exclusion, duplicate-worker refusal and child abort/timeout cleanup. CLI policy scenarios protect deck legality, style-specific decisions, immediate wins and Ganymede's legal mistakes. These checks do not establish production capacity or long-run balance.
