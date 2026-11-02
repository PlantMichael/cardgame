# Moon bots

Moon bots have two independent modes. The **ranked worker** controls four persistent accounts in the normal authoritative ranked queue, with ordinary matchmaking and rewards. The **simulation worker** plays isolated headless games in `bot_matches` without accounts or ladder rewards. Both use the profiles below; neither uses a paid AI service.

| Bot | Release | Level | Drafting and decisions |
|---|---|---|---|
| Io | 1.0 | 10 | Midrange decks; tempo, board advantage and efficient mana use. |
| Callisto | 1.0 | 8 | Tribal/value decks; supporting combinations, setup and retaining useful pieces. Takes an immediate winning move. |
| Europa | 1.0 | 8 | Aggro decks; lower curve, attack power and early damage to the enemy hero. |
| Ganymede | 1.0 | 1 | Random faction decks and random legal actions; a 35% chance of ending a turn before selecting an action. Can miss obvious wins. |

`data/bot_profiles.json` owns the four identities. Named bots use distinct policies, not trained language models. Io has the largest search budget, but that does not establish a win-rate ordering; matchup results measure it. The normal level 10 opponent is an additional participant, `standard`, with the current numeric AI policy version as its release string.

Every release drafts repeatable decks per participant/faction using the existing DeckManager builders, restricted to published collectible cards. Gameplay and search vary each match. The standalone simulation schedule covers all six named-bot pairings and each bot against Standard AI. Adjacent simulation rounds swap first player; the full 500-game simulation cycle covers all 25 faction combinations with each first-player choice for all ten pairings. The simulation worker never joins ranked. Bump a bot's release when changing its drafting, scoring or mistakes. Rules and shared AI policy versions are separate snapshot dimensions; historical releases are retained.

## Ranked mode

Deploy the updated authoritative relay first (`RANKED_AUTHORITATIVE=1`), then run a separate worker service from the same revision/image, from `/app/server`:

```sh
node ranked_bot_worker.js
```

Required environment is `DATABASE_URL` for that relay's database, `GODOT_BIN` (already `/usr/local/bin/godot` in the image), and `RANKED_BOT_URL` for that same relay's `ws://` or `wss://` address. It needs no public port or persistent user-save volume. Keep database credentials in service secrets. No production worker is activated by this source change.

The privileged worker transactionally provisions Io, Callisto, Europa and Ganymede, associates server-owned identities in `ranked_bot_accounts`, and issues ordinary session tokens in the child's environment. It never adopts a pre-existing human name or resets ratings. Case-insensitive bot names are reserved in public registration. A name collision fails closed for operator attention. Its four tokens are removed on owned shutdown; player accounts and ranks remain. These accounts have unknowable random password hashes rather than human login credentials.

One headless Godot process polls four independent sockets. Each authenticates, saves its style deck, enters `queue_ranked`, joins its server-selected match, mulligans, answers choices and sends normal commands. Moves are paced at 0.6 seconds; the bot queues again five seconds after a match. Factions rotate. There is no local-AI fallback, special pairing, reward reduction or repeated-opponent restriction. A non-authoritative or mismatched service is refused before drafting or queueing.

Hidden Elo starts at the normal account default and changes through ordinary settlement, including the floor of 100. It is separate from visible bracket/LP progress. The normal rating window starts at ±100 and widens 60 points/second **without a cap**, so strong bots can still face Ganymede after waiting. Human opponents see labels such as `Io [Bot 1.0]`; client-supplied bot flags cannot create that identity.

Ranked policy uses filtered player views, not privileged opponent hands/decks or the actual draw order. Search samples unknown cards from visible counts and public priors; its own known draft can inform its own draw prior. These approximate beliefs do not establish a live win-rate ordering. Commands are validated and executed only by the authoritative host.

Configure one worker replica per database, `Restart=on-failure`, a 30-second restart delay, and process-group cleanup (`KillMode=control-group` under systemd; keep the engine in the same container on container hosts). The supervisor must stop all children if the parent dies. A database advisory lock rejects duplicate workers; losing it stops the engine and fails the process. The held connection checks ownership every five seconds with a five-second query timeout, bounding silently broken transport detection to about ten seconds; the CLI also enables TCP keepalive. Socket reconnects back off and rejoin the bot's own active match. Initial relay recovery completes before accepting queues, and match creation reserves accounts/capacity during asynchronous pairing. Newer views invalidate stale search completion; joined views restore the authenticated seat's command sequence.

Stopping or upgrading during games causes normal disconnect/timeout consequences. Drain matches before planned service/rules/release changes. `--matches=N` is for disposable tests: it stops after N distinct observed completions across the four clients and may interrupt other active games. Persistent accounts keep their ratings through restarts. Hosting consumes CPU/database resources; choose resource limits before activating the service.

## Standalone simulation mode

Use the relay image (`server/Dockerfile`), which already includes the pinned Godot binary, imported project, catalog and Node dependencies. Run **one separate worker service**, using the repository root as build context and `node bot_worker.js` as its start command from `/app/server`. It does not need a public port. Leave the relay's existing start command unchanged.

Required simulation environment:

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
const response = await fetch(`${CATALOG_ORIGIN}/data/stats/bot-matchups.json?mode=ranked&days=30`);
if (!response.ok) throw new Error('Simulation stats unavailable');
const { bots, decks, matchups, games } = await response.json();
```

Both relay and catalog expose this anonymous GET/HEAD/OPTIONS route with CORS. Select `mode=ranked` for genuine ranked bot games or `mode=simulation` for isolated simulations (the default, preserving existing consumers). They are never pooled. `days` is 1–365, default 30; unknown, duplicate and malformed query fields return 400. Other methods return 405. Successful relay snapshots are cached/coalesced for 60 seconds per mode/window. The catalog projects public fields, refuses redirects, and limits upstream time to 5 seconds and size to 4 MiB. Errors return generic 503, without stale success or fabricated zero results. More than 50,000 source games or 4 MiB of aggregate data also returns 503: request a shorter window rather than silently dropping games. This release does not provide pagination.

The envelope has `generatedAt`, `days`, `mode`, physical `games`, `methodology`, `bots`, `decks`, and `matchups`. Methodology labels `source: "server_verified"` for ranked or `"bot_simulation"` for simulation, `metric: "exact_starting_deck_matchup"`, `unit: "seat_game"`, `draws: "excluded_from_win_rate"`, `humanStats: "excluded"` (excluded from human-only aggregates).

Ranked games live in `ranked_matches` with `mode='ranked_bots'`, immutable `bot_a`/`bot_b` profile snapshots and `engine_version`, and use ordinary ranked settlements/rewards. Only finished games with consistent canonical winner/loser settlements and a settling end reason enter this public cohort. Unfinished/voided/contradictory/unsettled wins are excluded. Current canonical rules produce wins rather than draws; simulations retain their draw accounting. A match containing an unpublished human deck is excluded whole, without publishing a partial composition.

- A bot row contains `key`, `id`, `name`, string `version`, numeric `level`, `style`, `rulesVersion`, `engineVersion` and statistics. Its key includes all those identity/version dimensions except display name/style, which must be changed under a new release.
- Ranked human opponents share an anonymous bucket: `id: "human"`, `name: "Human players"`, `version: "unversioned"`, `level: null`, `style: "human"`. No real name/account ID is exposed. Human decks use the normal legal size of 1–40; named bot decks have 40 cards.
- A deck row contains `key`, `botKey`, canonical composition `id`, sorted `cards: [{id,copies}]`, `factions` and statistics. Composition IDs use the existing deck API's sorted-copy SHA-256 identity. The same composition used by two personalities has two deck keys. Never join solely on composition ID.
- A matchup row contains `deckKey`, `opponentDeckKey` and statistics. Resolve both through `decks`, then `botKey` through `bots`. Each match supplies both perspectives; do not add the reverse again when displaying one deck's record.
- Statistics are `matches`, `wins`, `losses`, `draws`, `winRate`, `averageTurns`, `first` and `second`. `winRate` excludes draws and is null for all-draw samples; each first/second split contains `matches` and `wins`. They count seat-games, so bot/deck/matchup sample totals are twice `games`. A physical draw contributes two drawn seat-games. `averageTurns` is the rules engine's round-style turn counter, matching existing ranked-AI telemetry.

Keep separate **Ranked bots** and **Bot simulations** views, with bot/rules/engine versions distinct. For card inclusion rates, sum a card's containing deck rows within the desired mode/bot/version/rules cohort; copies count once per seat-game. Inclusion is not a card's causal strength. No player IDs, real names, match IDs, seeds or individual histories are public. Existing human `/data/stats/card-winrates.json` and `/data/stats/deck-matchups.json` routes retain human-only semantics and exclude both isolated simulations and ranked-bot games, including human seats in those games.

## Verify locally

Use a task-owned disposable PostgreSQL database and isolated Godot user storage:

```sh
godot --headless --path . -- --bot-tests
godot --headless --path . -- --core-tests
node --test server/test/moon_bots.test.js server/test/deck_matchups.test.js server/test/card_winrates.test.js server/test/ranked_ai_record.test.js
node --test server/test/ranked_bots.test.js server/test/manager.test.js server/test/settlement.test.js server/test/hidden_info.test.js
node --test 'catalog/test/*.test.mjs'
```

Set `GODOT_BIN` and disposable `DATABASE_URL` for the server tests; unset `DATABASE_URL` for catalog tests. The new server test crosses worker → actual Godot → PostgreSQL save/reload → relay HTTP → catalog HTTP. It also covers replay after a lost acknowledgment/write failure, historical version separation, public-deck rejection, draws, mirrors, human-stat exclusion, duplicate-worker refusal and child abort/timeout cleanup. CLI policy scenarios protect deck legality, style-specific decisions, immediate wins and Ganymede's legal mistakes. These checks do not establish production capacity or long-run balance.

The ranked suite additionally crosses four real Godot sockets → normal queue → authoritative host → PostgreSQL settlements → relay/catalog ranked stats. It covers normal human wins/losses, collision rollback, populated schema upgrades, fresh-worker rejoin, duplicate worker refusal, lock loss and legacy-service refusal. The existing focused manager, hidden-information, settlement, persistence and relay suites cover shared owners.
