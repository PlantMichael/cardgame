# Feature Specification: Currency, Shop & Pack Unboxing

**Feature Branch**: `001-currency-pack-shop`

**Created**: 2026-09-11

**Status**: Draft

**Input**: User description: "Implement a currency and pack unboxings for the cardgame. Generate a shop and currency that you can buy or earn through playing. Pack opens should have a smooth animation like hearthstone"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Earn Currency by Playing (Priority: P1)

A player finishes a match (casual, ranked, or campaign) and is rewarded with
in-game currency, which they can see accumulate in their balance from the
main menu.

**Why this priority**: Currency is worthless without a way to earn it, and
earning-through-play is the core loop the feature depends on — it must exist
before a shop or packs mean anything.

**Independent Test**: Can be fully tested by playing and completing one match
and confirming the player's currency balance increases by the expected
amount, visible on the main menu without needing the shop or packs to exist.

**Acceptance Scenarios**:

1. **Given** a logged-in player with a starting balance, **When** they
   complete a match, **Then** their currency balance increases by the
   reward amount for that match's outcome.
2. **Given** a player has just earned currency, **When** they return to the
   main menu, **Then** the updated balance is displayed without requiring
   an app restart.

---

### User Story 2 - Buy a Pack from the Shop (Priority: P2)

A player opens a Shop screen, sees one or more card packs for sale priced in
the currency, and spends currency to purchase one.

**Why this priority**: The shop is the bridge between earning currency and
the pack-opening payoff; without it currency has no destination.

**Independent Test**: Can be fully tested by giving a player a currency
balance, opening the Shop, purchasing a pack, and confirming the balance is
debited by the pack's price and a purchased pack is queued for opening.

**Acceptance Scenarios**:

1. **Given** a player with enough currency, **When** they purchase a pack,
   **Then** the currency cost is deducted immediately and the pack becomes
   available to open.
2. **Given** a player without enough currency for a pack, **When** they
   attempt to purchase it, **Then** the purchase is blocked and the player
   is shown a clear reason why.

---

### User Story 3 - Open a Pack with a Hearthstone-Style Reveal (Priority: P3)

A player opens a purchased pack and watches a smooth, sequential reveal
animation showing each card before the cards are added to their collection.

**Why this priority**: This is the emotional payoff of the loop and the
feature's headline request, but it depends on Stories 1 and 2 already
existing to produce a pack worth opening.

**Independent Test**: Can be fully tested by granting a player one
already-purchased pack, opening it, and confirming every card in the pack is
revealed in sequence and then present in the player's collection.

**Acceptance Scenarios**:

1. **Given** a player has an unopened pack, **When** they choose to open it,
   **Then** each card in the pack is revealed one at a time with a smooth
   animation before the pack-opening screen is dismissed.
2. **Given** a player is mid-reveal, **When** they input a skip/speed-up
   action, **Then** the remaining reveals complete immediately without
   losing any card from the result.
3. **Given** a pack-opening has finished, **When** the player goes to their
   collection or deck builder, **Then** every card from that pack appears as
   owned.

---

### User Story 4 - Craft a Specific Card with Dust (Priority: P3)

A player who has accumulated crafting currency ("dust") from duplicate pack
pulls spends it to obtain one specific card of their choosing, rather than
relying on luck alone.

**Why this priority**: Duplicate pulls need a destination or they feel
wasted; crafting gives dust a purpose and closes the loop opened by Story 3's
duplicate handling. It ships alongside pack-opening rather than after it.

**Independent Test**: Can be fully tested by granting a player enough dust
for one card's crafting cost, having them choose and craft a specific card,
and confirming their dust is debited and the chosen card is added to their
collection.

**Acceptance Scenarios**:

1. **Given** a player has enough dust for a card's crafting cost, **When**
   they choose to craft that specific card, **Then** the dust is deducted
   and the card is added to their owned collection.
2. **Given** a player does not have enough dust for a card, **When** they
   attempt to craft it, **Then** the action is blocked and they are shown
   how much more dust they need.

---

### User Story 5 - Buy Currency with Real Money (Priority: P5, future phase)

A player purchases the shop's currency directly with real money instead of
(or in addition to) earning it through play.

**Why this priority**: Confirmed as wanted, but explicitly deferred — the
earn-only loop (Stories 1-4) should ship first since it is simpler to build
and already delivers the full shop/pack/crafting experience. Real-money
purchase is an additional acquisition path into the same currency, added
later without changing how currency is spent.

**Independent Test**: Can be tested independently of Stories 1-4 once
built, by completing a real-money purchase and confirming the same currency
balance used elsewhere in the game increases accordingly.

**Acceptance Scenarios**:

1. **Given** a player chooses a real-money currency bundle, **When** the
   purchase completes successfully, **Then** their currency balance
   increases by that bundle's amount.
2. **Given** a real-money purchase fails or is cancelled, **When** the
   player returns to the shop, **Then** their currency balance is unchanged
   and no partial credit is granted.

**Status**: Out of scope for this feature's initial implementation. Included
here so the Currency Balance and Shop are designed to accommodate this path
later without rework (see FR-014).

---

### Edge Cases

- What happens when a player tries to buy a pack and their currency balance
  is insufficient? (Purchase is blocked; no partial deduction.)
- What happens when a player earns currency while a match result is still
  being reported to the server (e.g., ranked result ack) — is the reward
  applied optimistically or only after server confirmation?
- What happens when a player opens several packs back-to-back — does each
  play its own full reveal, or do queued packs batch together?
- What happens when a player disconnects or force-quits mid-reveal, after the
  pack was already debited but before cards were confirmed added to the
  collection?
- What happens when a pack pull would exceed the existing deck-building copy
  limit for that card (e.g., a duplicate Legendary, which decks may only run
  one copy of)? (Resolved: the excess pull converts to dust — see FR-012.)
- What happens when a player tries to craft a card they already own the
  maximum usable copies of? (System should allow it — dust conversion and
  crafting are both about collection completeness, not just deck legality.)
- What happens when a player has enough dust for a craft but the target card
  is later removed/renamed in a content update? (Out of scope for this
  feature; content removal is not a currently supported operation.)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST maintain a persistent currency balance per player
  account.
- **FR-002**: System MUST award currency via daily and milestone bonuses
  rather than flat per-match income: a once-per-day first-win bonus, plus
  occasional rewards for ranked-ladder and campaign milestones (e.g.
  reaching a new rank tier, completing a campaign run). Exact bonus amounts
  and milestone triggers are a tuning detail for the implementation plan.
- **FR-003**: System MUST display the player's current currency balance on
  the main menu and within the Shop screen, updated immediately after any
  change.
- **FR-004**: System MUST provide a Shop screen listing every purchasable
  card pack with its currency price.
- **FR-005**: Players MUST be able to purchase a card pack using their
  currency balance; the cost is deducted at the moment of purchase.
- **FR-006**: System MUST prevent a pack purchase when the player's balance
  is less than the pack's price and MUST show the player a clear reason.
- **FR-007**: Each card pack MUST contain a fixed number of cards drawn
  according to a rarity-weighted distribution across the game's existing
  Common/Rare/Epic/Legendary rarities.
- **FR-008**: Each card pack MUST guarantee at least one Rare-or-better card.
- **FR-009**: Opening a pack MUST play a sequential reveal animation showing
  each card in the pack, one at a time, before the cards are committed to
  the player's collection.
- **FR-010**: Players MUST be able to skip or fast-forward the reveal
  animation without losing any card from the result.
- **FR-011**: Every card obtained from a pack MUST be added to the player's
  owned collection and become usable in deck-building immediately once the
  reveal completes (or is skipped).
- **FR-012**: When a pack yields a card the player already owns at or beyond
  its deck-building copy limit (e.g., a duplicate Legendary), the system
  MUST convert that pull into crafting currency ("dust") instead of adding
  a redundant copy. The dust amount per rarity is a tuning detail for the
  implementation plan.
- **FR-013**: Players MUST be able to spend accumulated dust to craft one
  specific card of their choosing; crafting deducts the card's dust cost
  (scaled by rarity, defined during planning) and adds that card to the
  player's owned collection.
- **FR-014**: For this feature's initial implementation, System MUST support
  acquiring currency exclusively through play (earning); a real-money
  purchase path into the same currency (User Story 5) is confirmed as wanted
  but is explicitly deferred to a later phase. The Currency Balance and Shop
  MUST be designed so that path can be added later without redesigning
  either (e.g., currency additions are not assumed to only ever originate
  from match/milestone rewards).
- **FR-015**: Currency balance, dust balance, and owned-card collection MUST
  be persisted server-side against the player's account, consistent with how
  custom decks are already account-bound, rather than relying solely on
  local device storage.

### Key Entities

- **Currency Balance**: A per-account numeric total of in-game currency the
  player has earned and/or purchased; increases from play rewards, decreases
  from pack purchases.
- **Card Pack (Shop Listing)**: A purchasable bundle definition — its
  currency price, how many cards it contains, and its rarity odds.
- **Pack Opening Result**: The specific set of cards rolled for one
  purchased-and-opened pack instance, including which of those cards were
  new to the player versus duplicates.
- **Shop**: The screen presenting the player's currency balance alongside
  every purchasable pack.
- **Owned Card Collection**: The player's existing account-bound card
  ownership record (already implied by the deck builder's collection
  editor), extended to track how many copies of each card the player owns
  so pack results can add to it.
- **Crafting Currency (Dust)**: A secondary per-account balance accumulated
  when a pack pull would exceed a card's deck-building copy limit; spendable
  to craft one specific chosen card.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A player can go from finishing a match to owning the cards
  from one fully-opened pack, using only currency earned from that match, in
  under 60 seconds of menu/shop interaction (excluding match and animation
  time).
- **SC-002**: 100% of currency awarded for a completed match is reflected in
  the player's visible balance without requiring an app restart.
- **SC-003**: 0% of attempted pack purchases succeed when the player's
  balance is below the pack's price.
- **SC-004**: The pack-opening reveal animation completes for a full pack
  with no dropped or skipped-without-input cards, verified across 100
  consecutive test opens.
- **SC-005**: The player's currency balance and shop are reachable from the
  main menu in no more than 2 player actions (clicks/taps).
- **SC-006**: 100% of pack pulls that would exceed a card's deck-building
  copy limit convert to dust instead of a redundant collection entry,
  verified across 100 consecutive test pack opens.
- **SC-007**: A player with sufficient dust can craft any specific card they
  choose in a single action, with the correct dust amount deducted every
  time, verified across 100 consecutive test crafts.

## Assumptions

- Pack size defaults to 5 cards per pack, matching the genre convention the
  request explicitly references ("like Hearthstone").
- Two balances are in scope: the earned/spendable main currency (used to buy
  packs) and dust (a crafting currency sourced only from duplicate pulls,
  used only to craft specific cards). A real-money purchase path into the
  main currency is confirmed as wanted for a future phase (User Story 5) but
  is not implemented by this feature.
- The "guaranteed Rare-or-better" pack rule is adopted as an industry-standard
  default since the request did not specify pack odds; exact rarity
  percentages, dust amounts per rarity, and craft costs per rarity are
  tuning details for the implementation plan, not this spec.
- Currency, dust, and collection data are stored server-side via the existing
  account/relay-server system (`Auth`, `server/relay.js`), the same way
  custom decks are already account-bound, so that currency and owned cards
  follow the player across devices/sessions rather than living only on one
  machine.
- Existing deck-building copy limits (e.g., max 1 Legendary copy per deck)
  are not changed by this feature; a pack pull that would exceed that limit
  converts to dust (FR-012) rather than changing the limit itself.
- Real-money purchase (User Story 5 / FR-014's deferred path) will require
  its own follow-up specification once prioritized, covering payment
  provider choice, receipt validation, refunds, and platform-specific
  (Steam/mobile) requirements — none of which are decided by this spec.
