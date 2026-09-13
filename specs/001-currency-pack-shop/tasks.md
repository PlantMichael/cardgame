---

description: "Task list for Currency, Shop & Pack Unboxing"
---

# Tasks: Currency, Shop & Pack Unboxing

**Input**: Design documents from `specs/001-currency-pack-shop/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/shop-protocol.md](./contracts/shop-protocol.md), [quickstart.md](./quickstart.md)

**Tests**: Not explicitly requested in spec.md. Per the constitution's Development
Workflow (no formal test suite; verify via headless CLI hooks + manual
playtest), the `--shop-test` headless hook is generated as a Polish-phase
deliverable rather than pre-implementation contract/unit tests.

**Organization**: Tasks are grouped by user story (spec.md priorities P1-P4).
User Story 5 (real-money purchase) is explicitly deferred per plan.md's
Summary and has no tasks here.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1-US4)
- File paths are exact and relative to the repository root

---

## Phase 1: Setup

**Purpose**: Content and schema groundwork shared by every user story

- [X] T001 Create `data/shop_packs.json` with at least one pack definition
      matching the schema in [data-model.md](./data-model.md#card-pack-shop-listing--datashop_packsjson):
      `pack_id`, `display_name`, `price` (integer), `card_count` (integer,
      default 5 per Assumptions), `rarity_weights` (object over
      COMMON/RARE/EPIC/LEGENDARY), `guaranteed_rare_or_better` (boolean),
      `dust_value` (per-rarity object).
- [X] T002 [P] In `server/relay.js`, add `currency` and `dust` integer
      columns to the `players` table via
      `ALTER TABLE players ADD COLUMN IF NOT EXISTS ... DEFAULT 0`, matching
      the existing ranked-ladder column migrations; both fields "never
      negative" (data-model.md).
- [X] T003 [P] In `server/relay.js`, add
      `CREATE TABLE IF NOT EXISTS owned_cards (player_id, card_id, quantity)`
      with primary key `(player_id, card_id)` and `quantity` defaulting to 0,
      per [data-model.md](./data-model.md#owned-card-collection-owned_cards-table--new).

**Checkpoint**: Schema and content exist; no gameplay code depends on them yet.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core client/server plumbing every user story needs

**⚠️ CRITICAL**: No user story task can start until this phase is complete

- [X] T004 Create `scripts/game/economy.gd` and register it as an autoload
      (matching the pattern of `DeckManager`/`Auth`): holds the
      client-side mirror of `currency` and `dust`, exposes
      `earn(amount, source)`/`spend(amount)`-style API that only ever
      reflects server-confirmed values (never locally invents a balance
      change, per plan.md's Constraints), and emits a signal on any balance
      change for UI to react to.
- [X] T005 [P] Create `scripts/game/pack_opener.gd` as a pure-logic script
      with no `Node` dependencies (mirrors `headless_turn.gd`'s style):
      given a pack definition and the full `CardDatabase` pool, rolls
      `card_count` weighted picks by `rarity_weights`, re-rolls one Common
      slot to Rare-or-better if `guaranteed_rare_or_better` and none landed
      (FR-008), and for each pick checks the player's owned quantity against
      its deck-building copy limit — an over-limit pick converts to its
      rarity's `dust_value` instead of a collection increment (FR-012).
- [X] T006 In `server/relay.js`, implement the `get_economy_state` /
      `economy_state_result` handler per
      [contracts/shop-protocol.md](./contracts/shop-protocol.md#get_economy_state--economy_state_result):
      session-authenticated, returns `currency`, `dust`, and `owned_cards`
      (`[{card_id, quantity}]`) for the requesting player.
- [X] T007 Wire `Economy` (T004) to send `get_economy_state` and populate
      itself from `economy_state_result` on login and on session resume,
      alongside the existing profile/deck fetch in `scripts/game/auth.gd`.

**Checkpoint**: Foundation ready — user story implementation can begin.

---

## Phase 3: User Story 1 - Earn Currency by Playing (Priority: P1) 🎯 MVP

**Goal**: Players earn currency via daily/milestone rewards and see their
balance update live on the main menu.

**Independent Test**: Complete a match, confirm the currency balance
increases by the expected reward amount and is visible on the main menu
without an app restart.

### Implementation for User Story 1

- [X] T008 [US1] In `server/relay.js`, implement `claim_earn_reward` /
      `claim_earn_reward_result` per
      [contracts/shop-protocol.md](./contracts/shop-protocol.md#claim_earn_reward--claim_earn_reward_result):
      server decides eligibility and amount for `reason` values
      `daily_first_win`, `ranked_milestone`, `campaign_milestone`; a
      duplicate claim (e.g. daily bonus already granted today) responds
      `success: false` with an explanatory `message` rather than a silent
      no-op, and credits `players.currency` atomically on success.
- [X] T009 [US1] Trigger a `claim_earn_reward` (`reason: "daily_first_win"`)
      call from `scripts/game/game_manager.gd` the first time a match
      completes in a given day.
- [X] T010 [US1] [P] Trigger a `claim_earn_reward`
      (`reason: "ranked_milestone"`) call from `scripts/game/auth.gd` after
      `Auth.report_ranked_result()`'s ack indicates the player reached a new
      rank tier.
- [X] T011 [US1] [P] Trigger a `claim_earn_reward`
      (`reason: "campaign_milestone"`) call from `scripts/game/campaign_state.gd`
      (or its `main.gd` call site) when a Campaign run completes.
- [X] T012 [US1] Add a currency balance label to the main menu in
      `scripts/game/main.gd`, reading its initial value from `Economy`
      (T004/T007).
- [X] T013 [US1] Connect the main menu's balance label (T012) to
      `Economy`'s balance-changed signal (T004) so it updates immediately
      on any earn, satisfying "100% of currency awarded ... reflected ...
      without requiring an app restart" (SC-002).

**Checkpoint**: User Story 1 is independently functional — playable and
verifiable without the Shop, packs, or crafting existing yet.

---

## Phase 4: User Story 2 - Buy a Pack from the Shop (Priority: P2)

**Goal**: A Shop screen lists purchasable packs; spending currency debits
the balance and yields a pack to open.

**Independent Test**: Seed a player with currency, open the Shop, purchase
a pack, and confirm the balance is debited by the pack's price and a
purchase result is returned — independent of how the currency was earned.

### Implementation for User Story 2

- [X] T014 [US2] Create `scenes/ui/ShopScreen.tscn` and
      `scripts/ui/shop_screen.gd`: pure presentation, lists every pack from
      `data/shop_packs.json` with its price and displays the current
      balance from `Economy` (no purchase logic decided client-side, per
      Constitution Principle I).
- [X] T015 [US2] Add a "SHOP" button to the main menu
      (`scripts/game/main.gd`) that opens `ShopScreen`, reachable in no more
      than 2 player actions from the main menu (SC-005).
- [X] T016 [US2] In `server/relay.js`, implement `purchase_pack` /
      `purchase_pack_result` per
      [contracts/shop-protocol.md](./contracts/shop-protocol.md#purchase_pack--purchase_pack_result):
      reject with `success: false` and a message if `currency < price`
      (FR-006, "never negative" per data-model.md) with no partial
      deduction; otherwise debit `currency`, roll the pack (reusing the
      same rarity/duplicate logic as `pack_opener.gd`, per research.md
      decision 3), apply `owned_cards` increments and any `dust` credit
      atomically, and return the full `result.cards` list so a mid-reveal
      disconnect can't lose the outcome (Edge Case in spec.md).
- [X] T017 [US2] Wire `shop_screen.gd`'s purchase button to send
      `purchase_pack` and handle `purchase_pack_result`, updating `Economy`
      on success.
- [X] T018 [US2] [P] Show a clear, non-blocking message in `shop_screen.gd`
      when `purchase_pack_result.success` is `false` (insufficient funds),
      per FR-006's acceptance scenario.

**Checkpoint**: User Stories 1 AND 2 both work independently.

---

## Phase 5: User Story 3 - Open a Pack with a Hearthstone-Style Reveal (Priority: P3)

**Goal**: Opening a purchased pack plays a smooth sequential reveal before
cards land in the player's collection.

**Independent Test**: Feed a seeded `purchase_pack_result`-shaped pack
result directly to the reveal screen and confirm all cards animate in
sequence, skip works without dropping a card, and the result reaches the
collection — independent of the real purchase flow having just run.

### Implementation for User Story 3

- [X] T019 [US3] Create `scenes/ui/PackOpenScreen.tscn` and
      `scripts/ui/pack_open_screen.gd`, accepting a `result.cards` list
      (per [contracts/shop-protocol.md](./contracts/shop-protocol.md#purchase_pack--purchase_pack_result))
      and rendering each entry in order.
- [X] T020 [US3] Implement the per-card reveal using `Tween` (matching
      `animate_creature_attack`'s approach in `board.gd`, per research.md
      decision 4): flip/scale-in plus a brief hold, with an extended
      flourish for Legendary pulls.
- [X] T021 [US3] [P] Implement a skip/speed-up input in
      `pack_open_screen.gd` that completes all remaining reveals
      immediately "without losing any card from the result" (FR-010).
- [X] T022 [US3] On reveal completion (or skip), have `pack_open_screen.gd`
      notify `Economy`/the local collection view of the now-owned cards
      (server-side persistence already happened in T016; this is UI sync
      only, per Constitution Principle II's full-resync-from-authoritative-
      state approach).
- [X] T023 [US3] [P] Wire `shop_screen.gd` (T017) to open `PackOpenScreen`
      with the `purchase_pack_result` immediately after a successful
      purchase.

**Checkpoint**: All three of User Stories 1-3 work independently — the core
earn → shop → open loop is complete.

---

## Phase 6: User Story 4 - Craft a Specific Card with Dust (Priority: P3)

**Goal**: Players spend accumulated dust to obtain one specific chosen card.

**Independent Test**: Seed a player with dust directly (no pack-opening
required) and confirm crafting a specific card debits the exact cost and
adds it to the collection.

### Implementation for User Story 4

- [X] T024 [US4] In `server/relay.js`, implement `craft_card` /
      `craft_card_result` per
      [contracts/shop-protocol.md](./contracts/shop-protocol.md#craft_card--craft_card_result):
      server resolves the requested `card_id`'s rarity/cost from its own
      card-data copy (never trusts a client-supplied cost), rejects with
      `success: false` and `dust_needed` if `dust < cost` ("never negative"
      per data-model.md), otherwise debits `dust` and increments
      `owned_cards`.
- [X] T025 [US4] Add a crafting entry point (a panel within `ShopScreen` or
      `scripts/ui/card_list_screen.gd`) listing the current dust balance and
      a "Craft" action per card.
- [X] T026 [US4] Wire the craft UI (T025) to send `craft_card` and handle
      `craft_card_result`, showing the insufficient-dust message
      (FR-013's second acceptance scenario) when rejected.
- [X] T027 [US4] [P] Surface the dust balance next to the currency balance
      everywhere currency is already shown (main menu from T012, Shop from
      T014), driven by the same `Economy` signal used in T013.

**Checkpoint**: All four in-scope user stories (US1-US4) are independently
functional — the full earn/shop/open/craft loop works end-to-end. User
Story 5 (real-money purchase) remains deferred, per plan.md.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Verification and doc-sync required by the constitution before
calling the feature done

- [X] T028 [P] Implement the `--shop-test` headless CLI hook in
      `scripts/game/main.gd` (alongside `--mcts-benchmark`/`--campaign-test`/
      `--tank-test`), covering the assertions listed in
      [quickstart.md](./quickstart.md#scenario-a--headless-economy-verification-no-gui):
      earn, insufficient-funds rejection, pack purchase, duplicate → dust
      conversion, and crafting. Verified: `godot --headless --path . --
      --shop-test` → `RESULT: PASS`, covering rarity-weighted rolling, the
      guaranteed-rare-or-better rule, duplicate→dust conversion (both
      pre-owned and within one pack), Legendary's 1-copy limit, and token
      exclusion (the pure client-side roll only — see T029 for what this
      doesn't cover). `--campaign-test` and `--tank-test` re-run clean too
      (no regression from the `game_manager.gd`/`board.gd`/`main.gd` edits).
- [ ] T029 Run through [quickstart.md](./quickstart.md#scenario-b--manual-playtest-of-the-shop-and-reveal-animation)'s
      manual playtest end-to-end in the Godot editor and fix any issues
      found (animation smoothness, shop reachability, skip behavior). NOT
      DONE — no GUI/screenshot tooling was available in this environment to
      actually click through the Shop/pack-reveal UI (same limitation noted
      for the Campaign map screen in status.md). Likewise, `purchase_pack`/
      `craft_card`/`claim_earn_reward`/`get_economy_state` in `relay.js`
      have not been exercised against a live Postgres instance. Both need a
      real playtest before this feature is considered fully verified.
- [X] T030 [P] Update `.docs/architecture.md` with the new `Economy`
      autoload and the `pack_opener.gd`/`shop_screen.gd`/
      `pack_open_screen.gd` scripts, per Constitution Principle IV.
- [X] T031 [P] Update `.docs/status.md`'s "What's Working" section to
      reflect the shipped earn/shop/open/craft loop (and TODO/Next Steps if
      anything from spec.md was intentionally left for later), per
      Constitution Principle IV.
- [X] T032 [P] Confirm no starter deck's `in_starter` composition
      (`data/cards/*.json`) was altered by this feature, per Constitution
      Principle V.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately.
- **Foundational (Phase 2)**: Depends on Setup (needs `shop_packs.json`
  and the new columns/table to exist) — BLOCKS every user story.
- **User Stories (Phase 3-6)**: All depend on Foundational completion.
  US1 and US2 are mutually independent. US3 consumes the shape US2's
  `purchase_pack_result` produces but can be built/tested against a seeded
  result without US2 having actually run. US4 only needs the `dust` column
  from Setup and can be tested with seeded dust, independent of US3 having
  produced it for real.
- **Polish (Phase 7)**: Depends on US1-US4 being complete (the headless
  hook and doc updates describe the finished loop).

### User Story Dependencies

- **US1 (P1)**: No dependencies on other stories.
- **US2 (P2)**: No dependencies on other stories (independently testable
  with seeded currency).
- **US3 (P3)**: Functionally follows US2 in the real flow (needs a
  purchased pack), but is independently testable with a seeded pack result.
- **US4 (P3)**: Functionally follows US3 in the real flow (needs dust from
  a duplicate pull), but is independently testable with seeded dust.

### Parallel Opportunities

- T002 and T003 (different schema objects in the same file) can be done
  together, then committed as one migration.
- T010 and T011 (different call sites) are parallel once T008 exists.
- T018, T021, T023 are parallel within their respective story phases.
- T030, T031, T032 (different files) are parallel.

---

## Parallel Example: User Story 1

```bash
# After T008 (claim_earn_reward handler) is done, these two call sites are independent:
Task: "Trigger ranked_milestone claim_earn_reward from scripts/game/auth.gd"
Task: "Trigger campaign_milestone claim_earn_reward from scripts/game/campaign_state.gd"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: confirm currency accrues and displays live
5. This alone is a demonstrable increment even with no Shop yet

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. + US1 → players earn and see currency (MVP)
3. + US2 → players can spend it on packs
4. + US3 → opening a pack is the intended Hearthstone-style payoff
5. + US4 → duplicates stop feeling wasted
6. Polish → headless verification + doc sync, per constitution
7. User Story 5 (real-money purchase) is a separate future feature/spec,
   not part of this delivery.

## Notes

- [P] tasks touch different files and have no unmet dependency.
- Every server-side task (T002, T003, T006, T008, T016, T024) lives in the
  single existing `server/relay.js` file — sequence commits carefully even
  where marked non-conflicting in intent, since they share one file.
- Constitution Principle I is why the roll/duplicate/dust logic exists in
  both `pack_opener.gd` (client, for the headless hook and any future
  client-side prediction) and `relay.js` (server, authoritative) — see
  research.md decision 3 for why this isn't considered duplicated
  source-of-truth (card *data* stays single-sourced in the Godot project;
  only the *roll* is mirrored).
