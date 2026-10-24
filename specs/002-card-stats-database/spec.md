# Feature Specification: Card Statistics Database

**Feature Branch**: `002-card-stats-database`

**Created**: 2026-10-24

**Status**: Draft

**Input**: User description: "A secure card information database that records statistics for every card in the game. For each card it captures usage and outcome data from finished matches (which decks and cards were played, drawn, and kept after mulligan, and match results by ranked tier and game version) so that card win rates, deck win rates and similar summaries can be computed. Raw match records are private and access-controlled; only anonymous, aggregated summaries (with minimum sample sizes and no player identities) may be published to third parties alongside the existing static public card catalog. Must work with the existing Godot client, the Node relay server with Postgres, and AI/ranked/multiplayer matches, and must not trust client-reported results without server validation."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Record Every Finished Match Trustworthily (Priority: P1)

When a match ends — ranked, casual multiplayer, campaign, or against the AI —
the game's server keeps a private record of what happened: which deck each
side brought, which cards were drawn, kept after the opening-hand mulligan and
played, who won, and under which ranked tier and game version. A report that
cannot be trusted (forged, duplicated, from a player who was not in the
match, or contradicted by the other player) is never counted.

**Why this priority**: Every summary, balance decision and published number
depends on this data being complete and honest. Recording nothing means no
statistics ever; recording forgeable data means the statistics are worthless
and can be gamed. It is also time-critical: matches played before recording
starts can never be recovered.

**Independent Test**: Play one ranked multiplayer match, one casual match and
one AI match to completion. Confirm the private store holds exactly one record
for each, containing both decks (or the player's deck for AI play), per-card
draw/keep/play facts, the result, tier and game version. Then submit a forged
and a duplicate result and confirm neither changes the totals.

**Acceptance Scenarios**:

1. **Given** two players finish a ranked match and both report the same
   winner, **When** the server settles the match, **Then** exactly one record
   is stored, marked as verified, with both decks and every card's
   drawn/kept/played facts.
2. **Given** one player reports a win and the other reports a win (or a loss
   that disagrees with what the server itself observed), **When** the server
   settles the match, **Then** the record is stored as disputed and is
   excluded from every summary until resolved.
3. **Given** a result for a match identifier that was already settled, **When**
   it is submitted again, **Then** nothing is added or changed.
4. **Given** a person who was not a participant submits a result for a match,
   **When** the server receives it, **Then** it is rejected and not stored.
5. **Given** a player finishes a match against the AI on their own device,
   **When** the result is submitted, **Then** it is stored but labeled
   unverified (the server cannot observe an AI match) and kept out of
   verified-only summaries.
6. **Given** a player disconnects or concedes mid-match, **When** the server
   settles the match, **Then** it is recorded with how it ended (completed,
   conceded, disconnected) so incomplete matches can be excluded from card
   statistics.

---

### User Story 2 - Maintainer Reviews Card and Deck Performance Privately (Priority: P2)

The game's maintainer opens private summaries to see how each card and each
kind of deck is performing — win rate when drawn, when played, when kept
through the mulligan, how often it is played at all — and can slice by ranked
tier, game version and match type, to inform balance changes.

**Why this priority**: This is the reason the data exists. It delivers value
on its own (better balance decisions) before anything is shared externally.

**Independent Test**: With a known set of recorded matches, request the
private summary for one card and confirm its win-when-drawn, win-when-played
and play-rate figures match numbers computed by hand from those records, and
that changing the tier or version filter changes the figures accordingly.

**Acceptance Scenarios**:

1. **Given** recorded verified matches, **When** the maintainer views a card,
   **Then** they see the number of matches it appeared in, how often it was
   drawn, kept and played, and the win rate for each, with the sample size
   shown beside every figure.
2. **Given** decks built from the same cards in the same faction(s), **When**
   the maintainer views deck summaries, **Then** those decks are grouped as one
   archetype and a win rate is shown per group.
3. **Given** a card was changed in a new game version, **When** the maintainer
   filters by version, **Then** figures from before and after the change are
   never mixed.
4. **Given** a person who is not the maintainer, **When** they try to open the
   private summaries or raw records, **Then** access is denied and the attempt
   is logged.

---

### User Story 3 - Third Parties Consume Anonymous Published Summaries (Priority: P3)

Developers of deck builders, bots and card browsers download a published,
versioned summary file (next to the existing public card catalog) giving each
card's and each deck archetype's aggregate figures, without any information
about individual players or matches.

**Why this priority**: It extends the value outward, but only after the data
is collected (P1) and understood internally (P2). Publication is also the
point where privacy and abuse risk is highest, so it follows the private
capability.

**Independent Test**: Publish a summary from a prepared data set containing
both well-sampled and thinly-sampled cards. Confirm a third party can fetch it
without an account, that thinly-sampled figures are absent, and that nothing
in the file identifies a player or a single match.

**Acceptance Scenarios**:

1. **Given** a card with at least the minimum number of qualifying matches,
   **When** a summary release is published, **Then** its win-when-drawn,
   win-when-played and play-rate figures appear, each with its sample size.
2. **Given** a card or archetype below the minimum sample size, **When** a
   release is published, **Then** its figures are omitted (not shown as zero).
3. **Given** a published release, **When** a third party downloads it, **Then**
   it contains no usernames, account identifiers, match identifiers,
   timestamps finer than the release period, or per-deck lists traceable to
   one person.
4. **Given** a release is published, **When** a newer release follows, **Then**
   the earlier release is still retrievable and unchanged.
5. **Given** the next release is being prepared, **When** the maintainer
   reviews it, **Then** they see exactly what will become public before it
   is released, and nothing is published automatically.

---

### User Story 4 - Players' Data Is Handled Responsibly (Priority: P3)

Players are told that anonymous match statistics are collected, their personal
identity is never part of what leaves the private store, and when an account
is deleted its matches stop being attributable to the person.

**Why this priority**: Required for trust and for responsible handling of
player data, but it constrains P1–P3 more than it adds a separate user flow.

**Independent Test**: Delete a test account that has recorded matches; confirm
no raw record can still be linked back to that person and that previously
published releases (already anonymous) are unaffected.

**Acceptance Scenarios**:

1. **Given** a player's account is deleted, **When** deletion completes,
   **Then** their matches no longer carry any identifier linking them to that
   person, while the aggregate counts they contributed remain valid.
2. **Given** a new player starts a first match, **When** they use the game,
   **Then** it is disclosed that anonymous match statistics are recorded.

---

### Edge Cases

- A match ends in a draw or an abandoned state with no winner: recorded with
  its end reason and excluded from win-rate figures but kept for play-rate and
  data-quality counts.
- Both players disconnect, or one disconnects and the other never reports:
  recorded as unsettled after a defined wait; counted nowhere until settled.
- A report arrives after a newer game version has shipped: the match is
  recorded under the version it was actually played on, never the current one.
- A player changes or saves their deck while a match is in progress: the deck
  recorded is the deck the match started with.
- Cards created during a match (tokens, transformed forms, cards copied or
  conjured by effects) are not counted as "drawn from the deck"; only cards
  that came from the starting deck are, so deck-based figures stay meaningful.
- A card is played more than once in a match, returned to hand and replayed,
  or rummaged back: "played" counts matches in which it was played at least
  once, and separately how many times.
- A card in the opening hand that is mulliganed away is counted as drawn but
  not kept.
- A very small group of players dominates a card or archetype: published
  figures must not make an individual's results inferable, even by comparing
  two releases or overlapping segments.
- The same account plays a very large share of the matches (including
  automated or farmed play): per-account contribution to any published figure
  is limited so one account cannot move it.
- A card is retired or renamed: its history stays attached to its stable
  identifier.
- The recording service is unavailable when a match ends: the match still
  completes for the players, and the result is not silently lost nor
  double-counted when it is delivered later.

## Requirements *(mandatory)*

### Functional Requirements

**Recording**

- **FR-001**: The system MUST create exactly one private record per finished
  match, regardless of how many times or from how many parties its result is
  reported.
- **FR-002**: Each record MUST capture: match type (ranked, casual
  multiplayer, campaign, AI), game version, the ranked tier bracket of each
  human participant at the start, how the match ended, which side went first,
  and the winning side.
- **FR-003**: Each record MUST capture each side's starting deck as a list of
  stable card identifiers, plus its faction(s).
- **FR-004**: For every card in a starting deck, the record MUST capture
  whether it was drawn, whether it was kept or replaced in the opening-hand
  mulligan, whether it was played (and how many times), and the turn it was
  first played.
- **FR-005**: Cards that did not come from the starting deck (tokens,
  transformed forms, effect-created copies) MUST be recorded separately from
  deck cards and MUST NOT count toward draw or deck-based figures.
- **FR-006**: Statistics MUST be derived for every card that exists in the
  game's card catalog, including cards added later, using the card's stable
  identifier.

**Trust and validation**

- **FR-007**: The system MUST NOT accept a match result on the word of a
  single client alone for matches between two human players. A result is
  verified only when it agrees with the other participant's report and with
  what the server itself observed of the match.
- **FR-008**: Results that conflict, or that cannot be confirmed, MUST be
  stored as disputed and MUST be excluded from all figures until resolved.
- **FR-009**: Reports from anyone who was not a participant in the match, for
  a match that never took place, or for an already-settled match MUST be
  rejected without changing any data.
- **FR-010**: Matches played against the AI on the player's own device, which
  the server cannot observe, MUST be stored as unverified and MUST be excluded
  from verified-only and published summaries by default.
- **FR-011**: The system MUST record each match's verification status
  (verified, unverified, disputed) and end reason, and summaries MUST be able
  to filter on both.
- **FR-012**: The system MUST limit how much any single account can
  contribute to a published figure.

**Access control and privacy**

- **FR-013**: Raw match records, per-account data and private summaries MUST
  be readable only by authorized maintainers; every other request MUST be
  denied, and denied attempts MUST be logged.
- **FR-014**: Raw records MUST reference players only through an internal
  identifier that is never included in any summary or published output.
- **FR-015**: Published output MUST contain no usernames, account or session
  identifiers, match identifiers, exact timestamps, or any list of cards
  attributable to one player or one match.
- **FR-016**: Any figure backed by fewer than the minimum sample size (default
  100 qualifying matches) MUST be withheld from published output rather than
  shown.
- **FR-017**: Published segmentation MUST be limited to coarse, pre-defined
  categories (ranked tier bracket, game version, match type, faction) so
  figures cannot be combined to identify individuals.
- **FR-018**: On account deletion, the system MUST remove the link between
  that account and its recorded matches while keeping the anonymous match
  data.
- **FR-019**: Players MUST be informed, before their first recorded match,
  that anonymous match statistics are collected.
- **FR-020**: Raw records MUST be retained for a defined period (default 24
  months) and then either deleted or reduced to anonymous aggregates.

**Summaries and publication**

- **FR-021**: The system MUST compute, per card: matches containing it, draw
  rate, keep-through-mulligan rate, play rate, and win rate when drawn, kept
  and played, with sample sizes alongside.
- **FR-022**: The system MUST compute, per deck archetype (decks sharing the
  same faction(s) and the same core cards): matches played and win rate.
- **FR-023**: Every figure MUST be sliceable by game version, ranked tier
  bracket and match type, and figures from different game versions MUST never
  be merged.
- **FR-024**: Published summaries MUST be generated as versioned, immutable
  releases; a published release MUST NOT change, and earlier releases MUST
  remain retrievable.
- **FR-025**: Publication MUST require an explicit maintainer action after
  reviewing the exact contents of the release; nothing is published
  automatically.
- **FR-026**: Published summaries MUST be available to third parties without
  an account, from the same place and in the same style as the existing
  public card catalog, and MUST reference cards by the catalog's identifiers.
- **FR-027**: Third parties MUST be unable to reach any raw record, private
  summary or per-account data through the publication channel.

**Reliability and integration**

- **FR-028**: Recording a match MUST NOT delay, block or alter the match
  itself, nor the existing ranked result and rewards handling.
- **FR-029**: If a result cannot be delivered when a match ends, it MUST be
  retried later without losing it or counting it twice.
- **FR-030**: The feature MUST work for ranked, casual multiplayer, campaign
  and AI matches, using the same card identifiers the game already uses.

### Key Entities

- **Match Record**: One finished (or abandoned) match. Holds match type,
  game version, how it ended, who went first, the winner, a verification
  status, and the ranked tier bracket of each human participant. One per
  match; never shown outside the private store.
- **Side**: One participant in a match (a human player or the AI). Holds the
  starting deck, faction(s), and a private link to an account when human.
- **Deck Card Fact**: For one deck card in one side of one match — drawn
  (yes/no), kept or replaced in the mulligan, times played, first turn
  played.
- **Created Card Fact**: A card that appeared in a match without coming from
  the starting deck (token, transformed form, effect-created copy); kept
  apart from deck facts.
- **Verification Status**: Verified, unverified (AI/local), or disputed, with
  the reason; decides whether a record can contribute to a figure.
- **Card Summary**: Aggregate figures for one card, for one combination of
  game version, tier bracket and match type: counts, rates and sample sizes.
- **Deck Archetype Summary**: Aggregate figures for a group of similar decks
  under the same slicing.
- **Summary Release**: A published, immutable, versioned set of summaries
  with the minimum-sample rule applied, ready for third-party download.
- **Maintainer**: An authorized person allowed to view private records and
  summaries and to approve a release.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every match played to completion in ranked, casual multiplayer
  and campaign modes produces exactly one record; in a test of 200 mixed
  matches including deliberate duplicate and out-of-order reports, record
  count equals match count with zero duplicates.
- **SC-002**: In a test of 100 forged, duplicated, non-participant or
  conflicting result submissions, none changes any published or private
  figure.
- **SC-003**: A private card summary's figures match hand-computed values
  from the same records for 100% of 20 spot-checked cards across at least 3
  slicings.
- **SC-004**: Zero published releases contain a player name, account
  identifier, match identifier or exact timestamp, verified by an automated
  scan of every release plus a manual review before each publication.
- **SC-005**: Every figure in a published release is backed by at least the
  minimum sample size; no card or archetype below it appears.
- **SC-006**: Unauthorized requests for private data are denied 100% of the
  time in testing, and each denial is logged.
- **SC-007**: A player finishing a match notices no added wait: the
  post-match screen and rewards appear within the same time as before this
  feature (no more than 0.5 seconds slower in typical conditions).
- **SC-008**: After an account is deleted, a search of all stored data finds
  no field that links any retained match to that person.
- **SC-009**: A maintainer can produce, review and publish a release for a
  new game version in under 30 minutes of hands-on time.
- **SC-010**: A third-party developer can fetch the latest summary and look
  up a given card's win rate in a few lines of code, without registering for
  anything.

## Assumptions

- Match results for two-human matches come from the game's existing
  multiplayer relay, which already sees every action exchanged in a match;
  that action stream is the server's own observation used to verify results.
- Matches against the AI run entirely on the player's device, so the server
  cannot verify them; they are recorded for the maintainer but excluded from
  published figures by default. (Whether to ever publish them is a later,
  separate decision.)
- "Deck archetype" means decks with the same faction(s) and a high overlap of
  core cards; the exact grouping rule is a planning decision.
- The default minimum sample size is 100 qualifying matches per published
  figure; the default raw-record retention is 24 months. Both are
  adjustable settings, not fixed forever.
- Only one maintainer role exists initially (the project owner); finer roles
  are out of scope.
- Published summaries use the existing static, versioned publication style of
  the public card catalog and are released manually by the maintainer; live
  query endpoints and per-player statistics for players are out of scope.
- Players cannot opt out of anonymous statistics in the first version, but are
  informed, and deletion of an account removes the link to their matches.
- This feature records and summarizes data; it does not change game rules,
  matchmaking, ranked ratings, rewards or card balance.
- Matches played before this feature ships are not recoverable and are not
  part of any statistics.
