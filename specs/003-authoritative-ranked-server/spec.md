# Feature Specification: Server-Authoritative Ranked Matches

**Feature Branch**: `003-authoritative-ranked-server`

**Created**: 2026-10-24

**Status**: Draft

**Input**: User description: "Server-authoritative ranked matches. For ranked (and, later, other human-vs-human) matches, all game rules run on the server instead of on a player's client, so a modified client cannot change rules, see the opponent's hidden cards, or fake a result. Players' clients only send intended actions and receive the state they are allowed to see; the server validates every action, resolves all effects and choices, determines the winner and settles the ranked result itself. The same rules code that powers the game today should be reused so the server and the game never drift apart. Must cover reconnecting after a disconnect, turn timers and forfeits, and the existing ranked queue, ladder and rewards, and must give the card statistics database (specs/002-card-stats-database) verified, authoritative match data. Single-player AI matches and casual matches may keep running on the player's device initially."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Play a Ranked Match Nobody Can Cheat (Priority: P1)

A player queues for ranked, is matched with another human, and plays a full
match — mulligan, turns, attacks, spells, choices, win or loss. Every rule is
decided by the server. Each player's screen shows only what that player is
allowed to see (their own hand, the public board, the opponent's hand *size*),
and no modification of a player's copy of the game can change a rule, reveal a
hidden card, or alter the outcome.

**Why this priority**: This is the whole point of the feature, and ranked is
where cheating does damage: it moves a public ladder and unlocks rewards. If
this slice works, ranked integrity is real even before anything else here
ships.

**Independent Test**: Play a ranked match between two normal clients and
confirm it plays exactly as ranked plays today. Then repeat with a client
altered to (a) send an illegal action, (b) claim a win it did not earn, (c) try
to read the opponent's hand. Confirm each attempt fails and the match result is
unaffected.

**Acceptance Scenarios**:

1. **Given** two players matched in ranked, **When** they play a match to its
   end, **Then** every action (play card, attack, end turn, answer a choice)
   was validated by the server, and the winner is the one the server's rules
   determined.
2. **Given** a player's client sends an action that is illegal in the current
   state (not their turn, card not in hand, can't afford it, invalid target),
   **When** the server receives it, **Then** it is refused, the match state is
   unchanged, and the player is told the action was not accepted.
3. **Given** a match in progress, **When** either client inspects everything
   it receives, **Then** it never contains the opponent's hand contents, either
   deck's contents or order, or any random outcome before it happens.
4. **Given** a client claims a result (win/loss/concede) that contradicts the
   server's own match state, **When** the claim arrives, **Then** it has no
   effect; only the server's determination settles the match.
5. **Given** both players use unmodified clients, **When** they play, **Then**
   the experience (animations, choices, pacing) feels the same as ranked
   today, with actions visibly resolving without noticeable lag.

---

### User Story 2 - Disconnects, Timers and Forfeits Are Handled Fairly (Priority: P1)

A player who loses their connection mid-match can come back and continue from
exactly where the match is. A player who stalls cannot hold the opponent
hostage: each turn has a time limit, and abandoning a match loses it after a
grace period.

**Why this priority**: Once the server owns the match, the server must also own
the clock and the consequences of people leaving; otherwise ranked is
exploitable (stall, disconnect to dodge a loss) or unfair (a flaky connection
costs an honest player the game). It ships with Story 1.

**Independent Test**: Start a ranked match; drop one player's connection for
10 seconds and reconnect — the match resumes at the same state. Let a turn
timer expire — the turn ends. Stay disconnected past the grace period — the
match is recorded as a forfeit loss for that player.

**Acceptance Scenarios**:

1. **Given** a player disconnects mid-match, **When** they reconnect within the
   grace period, **Then** they rejoin the same match at the current state,
   seeing only what they are allowed to see, and the opponent is told it
   resumed.
2. **Given** it is a player's turn, **When** their turn time runs out, **Then**
   the server ends their turn (resolving any open choice with its default) and
   play continues.
3. **Given** a player is disconnected longer than the grace period, **When** it
   elapses, **Then** the match ends as a forfeit loss for them and a win for the
   opponent, recorded as such.
4. **Given** the opponent disconnects, **When** the remaining player waits,
   **Then** they see a clear "opponent disconnected" countdown, and if the
   grace period passes they receive the win.
5. **Given** a player concedes, **When** they confirm, **Then** the match ends
   immediately as a concession loss.
6. **Given** both players disconnect, **When** neither returns within the grace
   period, **Then** the match ends as abandoned with no rank change for either.

---

### User Story 3 - The Ladder and Rewards Settle From the Server's Own Result (Priority: P2)

When a ranked match ends, the server — which ran the match — settles the ladder
change, rating change, win streak and any ranked rewards itself, exactly once,
using only its own record. Players no longer send "I won" to move the ladder.
Queueing, matchmaking, ratings and rank progression behave as they do today.

**Why this priority**: It removes the last trusted claim in ranked, but the
existing settlement already works acceptably; it depends on Story 1 producing a
server-determined result first.

**Independent Test**: Complete a ranked match; confirm each player's rank,
rating and streak change by the amounts the ladder rules prescribe for the
server's result, exactly once, even if a client reports nothing, reports twice,
or reports a different outcome.

**Acceptance Scenarios**:

1. **Given** a ranked match ends with a winner, **When** the server settles it,
   **Then** each player's ladder state changes once, by the existing ladder
   rules, and the result is shown on their game-over screen.
2. **Given** a client sends no result, a duplicate result or a contradictory
   result, **When** settlement runs, **Then** the outcome is unchanged and no
   second award occurs.
3. **Given** a match ended as a draw, abandonment by both or a server fault,
   **When** it is settled, **Then** no rank or rating changes for either player.
4. **Given** the ranked queue, **When** players queue, **Then** pairing, the
   search screen, the "match found" step and fallback to an AI opponent behave
   as today.

---

### User Story 4 - The Statistics Database Receives Authoritative Match Data (Priority: P2)

For every server-run ranked match, the server itself records which cards were
in each deck, drawn, kept through the mulligan and played, who won and how it
ended, and hands that to the card statistics database as verified data — with
no reliance on what either player's client says.

**Why this priority**: It is what makes published card statistics trustworthy
and removes the weaker "both players agree" verification the statistics
feature would otherwise need for ranked.

**Independent Test**: Play a scripted ranked match with known card plays;
confirm the stored facts match exactly, are marked verified and
server-attested, and that nothing the clients could send changes them.

**Acceptance Scenarios**:

1. **Given** a server-run ranked match ends, **When** its facts are recorded,
   **Then** the record is marked verified because the server ran the match, with
   draw, keep and play facts for **both** sides.
2. **Given** matches that were *not* server-run (AI, casual), **When** their
   facts are recorded, **Then** they keep their weaker labels and stay out of
   verified figures.

---

### User Story 5 - The Maintainer Can Operate and Audit It Safely (Priority: P3)

The maintainer can see how many server-run matches are live, can review a
finished match's full action history to settle a dispute, can switch ranked
back to the previous mode if the new one misbehaves, and can deploy a new
version without silently destroying matches in progress.

**Why this priority**: Needed to run this responsibly, but only valuable after
the rest exists.

**Independent Test**: With several live matches, view the live count; open one
finished match's history and replay it to the same result; flip the switch and
confirm new ranked matches use the previous mode while live ones finish; restart
the server during a match and confirm it resumes or is voided without rank
change.

**Acceptance Scenarios**:

1. **Given** matches are running, **When** the maintainer checks status,
   **Then** they see live match count, capacity and recent failures.
2. **Given** a finished match, **When** the maintainer opens its history,
   **Then** they can replay every action and arrive at the recorded result.
3. **Given** the maintainer disables server-run ranked, **When** players queue
   next, **Then** they get the previous behavior, while matches already running
   finish normally.
4. **Given** the server restarts mid-match, **When** it comes back, **Then**
   each match resumes from its last accepted action, or — if that is impossible
   — is voided with no rank change and both players are told why.

---

### Edge Cases

- Two actions arrive at the same moment, or the same action is sent twice: only
  one is applied, in a defined order; the other is refused as stale/duplicate.
- A player's game is older than the server's rules: the player is told to
  update before queueing, rather than being matched into a mismatch.
- A turn timer expires while the player is in the middle of a choice (target
  selection, rummage pick, mulligan): the server applies a safe default and
  moves on.
- A player reconnects on a second device/tab while the first is still
  connected: the newer connection takes over and the older is closed; the
  match never has two controllers for one seat.
- A client lags badly: actions queue in order and the player sees pending
  state; they are never applied out of order.
- Capacity is exceeded: new ranked queues are told the service is busy instead
  of starting matches that cannot be run well; live matches are never dropped
  to make room.
- The server deploys a new version while matches are live: running matches
  complete under the version they began on, or are voided with no rank change
  if that is impossible.
- A player attempts to observe a match they are not in: refused; no match data
  is returned.
- The existing fallback — no human found, play a bot — remains a local,
  unverified AI match and never settles as a server-run match.
- A draw/stalemate scenario (both heroes lethal at once, turn limit): resolved
  by an explicit, documented rule rather than left to chance.
- A card or effect needs a player decision the player never answers: handled by
  the turn timer and its default.

## Requirements *(mandatory)*

### Functional Requirements

**Authority and validation**

- **FR-001**: For every ranked match between two human players, the system
  MUST run all game rules on the server and treat the server's match state as
  the only truth.
- **FR-002**: A player's device MUST be limited to sending intended actions
  (play, attack, end turn, answer a choice, concede) and displaying the state it
  receives; it MUST NOT be able to change rules, state or results.
- **FR-003**: The system MUST validate every received action against the
  current server state (whose turn, ownership, cost, targets, legality) and
  refuse any invalid action without changing state.
- **FR-004**: The system MUST resolve every effect and every required player
  decision as part of the server's match state, not by waiting on a player's
  device to run logic.
- **FR-005**: Each player MUST receive only the information they are entitled
  to see; the opponent's hand contents, both decks' contents/order and unrevealed
  random outcomes MUST never be sent to a device that is not entitled to them.
- **FR-006**: The system MUST process actions for a match in a single defined
  order and MUST refuse stale, duplicate or out-of-order actions.
- **FR-007**: The rules used to decide ranked matches MUST be the same rules
  the game ships with, such that the same starting conditions and the same
  sequence of actions always produce the same result in both places.

**Match lifecycle**

- **FR-008**: The system MUST start each ranked match with a server-chosen
  match identity, participants, first player and randomness, and MUST NOT accept
  any of those from a device.
- **FR-009**: The system MUST run the opening-hand mulligan, turn flow, win
  detection and all end conditions on the server.
- **FR-010**: The system MUST enforce a per-turn time limit and, on expiry, end
  the turn using safe defaults for any open decision.
- **FR-011**: The system MUST allow a disconnected player to rejoin their
  current match within a grace period and receive the current state they are
  entitled to see.
- **FR-012**: The system MUST end a match as a forfeit loss for a player who
  stays disconnected beyond the grace period, as a concession loss when they
  concede, and as abandoned with no rank change when both players are gone.
- **FR-013**: A seat MUST have at most one active controlling connection;
  taking over from a second connection MUST close the first.
- **FR-014**: The system MUST refuse a player whose game version's rules are
  not compatible with the server's, with a clear instruction to update.

**Settlement and rewards**

- **FR-015**: The system MUST determine each ranked match's result solely from
  its own match state and settle ladder rank, rating, win streak and ranked
  rewards itself, exactly once per player per match.
- **FR-016**: Results, concessions or "I won" claims sent by a device MUST have
  no effect on settlement.
- **FR-017**: Draws, voided matches and server faults MUST NOT change rank or
  rating for either player.
- **FR-018**: Ranked queueing, pairing by rating, the search/found flow and
  the bot fallback MUST continue to work as they do today; a bot fallback
  match MUST remain a local, unverified match.

**Data, statistics and audit**

- **FR-019**: The system MUST keep an append-only action history for every
  server-run match sufficient to replay it to the recorded result.
- **FR-020**: The system MUST record per-card draw, mulligan-keep and play
  facts for both sides from the server's own match state and pass them to the
  card statistics database as verified data (specs/002-card-stats-database).
- **FR-021**: Action histories and match data MUST be readable only by the
  maintainer, never by players or other third parties.

**Operations and safety**

- **FR-022**: The maintainer MUST be able to see live match count, capacity
  and recent failures, and to open a finished match's history.
- **FR-023**: The maintainer MUST be able to switch new ranked matches back to
  the previous mode without ending matches already running.
- **FR-024**: Matches in progress MUST survive a server restart by resuming
  from the last accepted action, or be voided with no rank change and both
  players informed.
- **FR-025**: The system MUST refuse new ranked matches, with a clear message,
  when it is at capacity, and MUST NOT drop live matches to make room.
- **FR-026**: Server-run ranked play MUST remain playable for existing
  players with no new account step, and non-ranked modes MUST be unaffected.

### Key Entities

- **Ranked Match**: One server-run match: server-assigned identity, two
  participants, first player, start time, status (waiting, active, finished,
  voided), end reason, winner, and a link to its action history.
- **Participant Seat**: One player's place in a match: which account holds it,
  connection state, time left on the clock, and the single controlling
  connection.
- **Player Action**: One intended move submitted by a seat (play, attack, end
  turn, answer choice, concede), with the match state it was sent against; it is
  accepted or refused.
- **Match State**: The complete, authoritative state of a match, including
  hidden information; derived views for each player contain only what that
  player may see.
- **Action History**: The ordered record of accepted actions plus the match's
  starting conditions, enough to replay to the same result.
- **Settlement**: The one-time ladder/rating/reward outcome per player per match,
  derived only from the match's result.
- **Match Facts**: The per-card draw/keep/play facts the server records for the
  card statistics database.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a test of at least 200 attempted cheats (illegal actions,
  actions out of turn, forged results, forged identities, attempts to read the
  opponent's hand or deck), 0 change a match's state or result and 0 expose
  hidden information.
- **SC-002**: Across 1,000 seeded matches, replaying each match's recorded
  action history reproduces the recorded result and final state in 100% of
  cases, and the same matches played through the game's own rules produce
  identical results.
- **SC-003**: Players see each accepted action take effect on their screen
  within 0.3 seconds for 95% of actions under normal network conditions, so
  ranked feels as responsive as today.
- **SC-004**: A player who disconnects and rejoins within the grace period is
  back in their match at the correct state within 10 seconds in 95% of trials.
- **SC-005**: 100% of ranked matches that end settle each player's ladder change
  exactly once, matching the ladder rules for the server's result, including
  under duplicate, missing and contradictory client messages.
- **SC-006**: 100% of server-run ranked matches produce statistics facts marked
  verified, with draw/keep/play facts for both sides and none derived from
  client-supplied results.
- **SC-007**: The service supports at least 100 simultaneous ranked matches
  without exceeding the action-response target in SC-003.
- **SC-008**: A maintainer can switch ranked back to the previous mode in under
  5 minutes, and no live match is ended by doing so.
- **SC-009**: When the server restarts with matches live, 100% of them either
  resume correctly or are voided with no rank change, with zero matches left in
  an unresolved state.
- **SC-010**: Existing ranked flows (queue, found screen, mulligan, turns,
  choices, game-over rank change) all work in a server-run match with no
  new steps for the player.

## Assumptions

- The game's existing rules core is already independent of the screen and is
  driven by plain-data actions, which is what makes reusing it on the server
  feasible; this spec requires that reuse (FR-007) but does not prescribe how.
- Several effects that ask a player to choose something are, today, handled by
  pausing on the player's screen rather than as part of the match state.
  Converting every such effect so the server can own it is part of this
  feature's scope; ranked is not considered server-authoritative until all of
  them are converted.
- The first release covers ranked human-vs-human only. Casual lobbies and
  campaign multiplayer keep today's behavior and are labeled unverified for
  statistics. AI matches always remain on the player's device.
- Defaults chosen unless the owner says otherwise (all adjustable settings):
  turn limit 90 seconds, disconnect grace 60 seconds, a conceded or forfeited
  match counts as a normal loss on the ladder.
- A match that cannot be resumed after a server restart is voided with no rank
  change rather than guessed at.
- Existing accounts, sessions, ladder rules and ratings are reused unchanged.
- This feature does not change game rules, card balance, ladder math,
  matchmaking skill bands or rewards; it changes who decides.
- Clients older than the current rules are required to update before queueing
  for ranked.
