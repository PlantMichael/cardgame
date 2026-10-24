# Research: Card Statistics Database

Decisions that resolve the unknowns in the plan's Technical Context. Each is
grounded in what the repository does today (cited) and lists what was rejected.

## 1. What "server validation" can mean when the server runs no rules

**Evidence**: `server/relay.js` `case 'relay'` forwards `msg.payload` verbatim
between host and guest; `mp_game_manager.gd` runs `GameState` on the host and
mirrors it to the guest (`GameState.from_net_dict`). The server has never
simulated a match. The ranked ladder already compensates: `startRankedMatch()`
stores participants and ratings server-side, and `report_ranked_result` treats
two identical win claims as a conflict ("until the rules run on a trusted
server there is no way to tell which").

**Decision**: Verification = *agreement of independent evidence*, never one
client's word:
1. The server creates the match identity and participant list itself (already
   true for ranked `rk_*` and campaign `cp_*`; extend to casual lobbies).
2. **Both** seats must report (`report_match_stats`), each authenticated by its
   own session token, each naming only its own seat.
3. The two reports must agree on the winner (exactly one side, or both "draw").
4. Each side's reported deck must pass server-side checks (§3).
5. The server's own observation must be plausible: both seats connected, match
   duration and relayed action count above floors (§4).
6. Facts both players can see (the multiset of card ids each side **played**,
   the turn count) must agree between the two reports. Private facts (own
   draws, own mulligan) come from the owner's report and are accepted only
   when 1–5 hold.

If any check fails the match is stored `disputed` with a reason code and is
excluded from every figure.

**Rationale**: Reuses the pattern the ladder already trusts and adds
cross-checks without a rules server. **Residual risk, stated plainly**: two
colluding accounts can fabricate an agreeing match. Mitigations are
statistical (caps, thresholds, pair caps — §6), not cryptographic.

**Alternatives rejected**: (a) Re-simulate matches server-side — would require
porting GDScript rules to Node; far beyond scope. (b) Trust the host alone —
a lying host decides every stat. (c) Signed client reports — the client is the
attacker; a shipped key is extractable.

## 2. AI and offline matches

**Evidence**: `game_manager.gd` creates ids like `ai_<unix>_<rand>`; the server
doesn't know them (`rankedMatches.get(id)` is undefined → "settles with no
rating change").

**Decision**: Accept a single report for ids the server never registered, from
an authenticated session, store it with `status = 'unverified'`,
`match_type = 'ai'`, and exclude it from verified-only and published
summaries by default. Limit to 200 such records per account per day and
reject reports whose `match_id` the server registered as a human match.

**Alternatives rejected**: Dropping AI data entirely (loses the only data
source until multiplayer volume exists and is useful for maintainer balance
work); publishing it (unverifiable, trivially forged — spec FR-010).

## 3. Server-side deck legality check

**Evidence**: `relay.js` already loads `data/cards/*.json` for shop data and
has `decks`/`owned_cards` tables. Deck-size rules live in `DeckManager`
(`deck_manager.gd`).

**Decision**: Ingestion rejects a side whose deck: contains an unknown card id
or a token (`is_token`), exceeds the per-card copy limit and deck-size bounds
(values read from the same constants the deck builder uses — to be mirrored in
one small server config, source named in tasks), mixes more than two factions,
or (when economy ownership is enforced) uses more copies than the account owns.
**Open implementation detail**: the exact numeric limits are copied from
`deck_manager.gd`; tasks include a test that fails if the two drift.

**Rationale**: Cheap, deterministic, catches fabricated and impossible decks.

## 4. Plausibility floors from server observation

**Decision**: The registry counts, per match: seats connected, first/last relay
timestamps, and the number of relayed messages per seat (by `payload.type`,
read-only). A match is "plausible" if duration ≥ 30 s, ≥ 6 relayed action
messages in total, both seats sent at least one message, and the reported turn
count ≤ elapsed-time ceiling (≥ 2 s/turn average). Values are config
constants, tuned later.

**Rationale**: Blocks instant "matches" submitted purely to inflate counts, with
no rules knowledge. **Alternatives rejected**: parsing payload semantics for
legality (couples server to client protocol details that change often).

## 5. Where facts are captured on the client

**Evidence**: Chokepoints already exist: `PlayerState.draw_card()` (appends to
hand), `GameState.mulligan_swap()` (returns the replacements, changed earlier
in this project), `GameState.play_creature()` / `play_stratagem()` (consume the
hand card by uid), `GameState.start_game()` (decks + mulligan), and
`GameState.duplicate_for_sim()` (AI search copies; must stay silent).
`CardData.uid` identifies one physical copy; tokens and effect-created cards
get uids minted by `PlayerState.mint_card_uid()` through `new_instance`.

**Decision**: A `MatchRecorder` (RefCounted) holds, per seat, the starting deck
as `card_id -> copies`, and per `card_id`: `drawn_copies`, `kept_copies`,
`played_copies`, `first_played_turn`. A card counts as *from the deck* iff its
`uid` was in the starting deck's uid set captured at `start_game()`; any other
uid seen entering hand or board is a *created card* (recorded separately,
spec FR-005). The recorder is created in `start_game()` only for real matches
(constructed by `GameManager`/`MpGameManager`), never in `duplicate_for_sim()`
or headless search.

**Guest mirror problem**: on a guest, `GameState` is rebuilt from host
snapshots each update, so guest-side hooks do not fire. **Decision**: the guest
reports only what it knows locally and can cross-check — its own submitted deck
(from its saved deck), its mulligan choice, and the public *played* cards it
observed from received state diffs. The **host's** report supplies draw/keep/
play facts for both seats; the guest's report validates the deck multiset and
public plays. Draw/keep facts for a guest side are therefore *host-attested,
guest-deck-checked* and marked `attested` in the data model.

**Alternatives rejected**: Event-bus refactor of `GameState` (violates "smallest
change"); parsing the combat log (presentation text).

## 6. Anonymity, publication thresholds and gaming resistance

**Decision**:
- **Minimum sample**: a published figure needs ≥ 100 qualifying matches *after*
  per-account capping (below). Configurable; default recorded in the release.
- **Per-account cap**: for each (card, slice) at most 10 matches per
  `account_key` count toward published numerators and denominators
  (`row_number() OVER (PARTITION BY account_key ...) <= 10`).
- **Pair cap**: two accounts' matches against each other count at most 5 times
  per slice, blunting win-trading.
- **Coarse slices only**: tier groups `low` (Orbital–Planetary), `mid`
  (Solar–Galactic), `high` (Cosmic), `legend` (Superluminal+); `game_version`;
  `match_type` ∈ {`ranked`, `casual`, `campaign`}; faction pair. No finer
  cross-tabs, no per-deck-list output.
- **Rounding**: rates to 0.1 percentage point; sample sizes rounded down to the
  nearest 10 for display.
- **Release granularity**: cumulative per game version, generated at most once
  per 7 days; no timestamps below the release date. Because releases are
  cumulative snapshots, two consecutive releases cannot be differenced into a
  small window finer than the cadence.
- **Review step**: building a release writes a *draft* plus a human-readable
  diff and a privacy scan report; nothing reaches `catalog/public/` until the
  maintainer runs `publish --approve <draft>`.

**Rationale**: Standard small-cell suppression plus contribution bounding; no
statistical-noise machinery, which is out of proportion at this scale.
**Alternatives rejected**: differential privacy noise (hard to explain to
third parties, disproportionate); publishing exact deck lists (identifies
individuals — FR-015).

## 7. Access control without a new network surface

**Evidence**: The relay's only inbound interface is the game websocket; the
only database credential in use is `DATABASE_URL`.

**Decision**: No message in the relay protocol returns stored match data. The
single new message, `report_match_stats`, is write-only and replies only with
`{ success, status }` for the caller's own seat. Maintainer reads happen in
`server/tools/stats.js` (CLI) run with `DATABASE_URL`; access control is
possession of that credential, which is already the project's root secret. The
CLI appends every invocation to `stat_audit`. Where the hosting database
supports additional roles, a read-only role is recommended for the CLI;
Railway's default single role is noted as a limitation, not a blocker.

**Rationale**: Satisfies "readable only by maintainers; denied attempts
logged" — unauthorized parties have no endpoint to attempt; attempted abuse of
`report_match_stats` (wrong seat, unknown match, replays) is logged to
`stat_audit` with reason codes. **Alternatives rejected**: an authenticated
HTTP admin API (new attack surface, new auth system, for one user).

## 8. Account deletion and `account_key`

**Evidence**: `players` rows have `ON DELETE CASCADE` children but the game has
no account-deletion feature yet.

**Decision**: `stat_sides.player_id` is `ON DELETE SET NULL`; `account_key` =
`HMAC-SHA256(STATS_KEY, player_id)` truncated, stored beside it. The unlink
operation (used by future account deletion and available now as
`stats.js unlink --player <id>`) nulls **both** columns. Aggregates already
published are unaffected (anonymous). The `STATS_KEY` secret lives only in the
server environment; rotating it breaks capping continuity for old rows, which
is acceptable and documented.

**Alternatives rejected**: storing raw `player_id` only (cap breaks on unlink);
a separate mapping table (a second place that must be scrubbed).

## 9. Game version identity

**Evidence**: `project.godot` has no `config/version`; docs mention
"Godot 4.3" but features say 4.7.

**Decision**: Add `application/config/version` to `project.godot` (maintainer
bumps it when card/balance data changes) and send it with each report. The
server records the client-reported value but **also** the version of the
`data/cards` content hash it holds; a report whose version label is unknown to
the server's allowed list is stored `unverified` with reason
`unknown_version`. Summaries never merge versions (FR-023).

**Alternatives rejected**: deriving version from a git hash (not available in
the web export); letting any string through (pollutes slices).

## 10. Delivery reliability

**Decision**: The client writes the finished report to
`user://pending_stats.json` before sending, deletes it on `ack`, and
re-sends pending reports on login/resume. Ingestion is idempotent on
`(match_id, seat)`; a duplicate returns the stored status. A failed or slow
send never blocks the result screen or ranked settlement.

**Alternatives rejected**: blocking the post-match screen on the ack (violates
SC-007).

## 11. Archetype definition for v1

**Decision**: v1 *published* deck figures are by **faction pair** (one or two
colors) per slice — coarse enough to never identify a deck. The private store
also keeps `deck_hash` (hash of the sorted card-id list) so the maintainer can
see exact-list win rates once ≥ 100 identical lists exist, and the data model
leaves room for a "core cards" archetype later without migration.

**Alternatives rejected**: overlap-clustering archetypes now (heavier analysis,
needs real data to tune).
