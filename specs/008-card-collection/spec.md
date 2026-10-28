# Feature Specification: Card Collection, Crafting Tokens and Pack Tuning

**Feature Branch**: `008-card-collection`
**Created**: 2026-10-27
**Status**: Draft - decisions below are agreed; items under "Open questions" need an answer before the matching step is built.

**Input**: "Add the last chunk of the game: collecting cards. 1. A collection, getting cards from packs. 2. A visual update to the deck builder and shop. 3. Packs which give you 5 random cards. Also the ability to give accounts all cards for play testing."

## Where we are today

Spec `001-currency-pack-shop` already built most of the plumbing. This feature finishes it, so most of the work is **gating, a new duplicate/crafting model, visuals and tuning**, not new infrastructure.

| Exists | Where |
|---|---|
| Server-authoritative balances `currency` (Cyllats) and `dust` (Glimmer) | `players` table, `server/relay.js` |
| `owned_cards (player_id, card_id, quantity)` | `server/schema_legacy.js` |
| One pack, `standard_pack` (100 `currency`, 5 cards, guaranteed rare+) | `data/shop_packs.json`, `rollPack` in `relay.js` |
| Duplicates beyond the copy limit become dust | `rollPack`, `PackOpener.roll_pack` (**the roll is implemented twice**, in JS and GDScript) |
| Crafting a chosen card for dust | `craft_card` in `relay.js` (`CRAFT_COST_BY_RARITY`) |
| Shop, pack-reveal screens | `scripts/ui/shop_screen.gd`, `pack_open_screen.gd` |
| Five 40-card starter decks (35 faction + 5-7 generic) | `data/starters.json` |
| Server-run ranked deck validation (legality only, **no ownership check**) | `server/authoritative/decks.js` |

**The gap:** the deck builder ignores ownership, and the shop/pack screens have never been playtested against a live server.

## Decisions already made

1. **No faction packs.** 171 collectible cards (79 common, 57 rare, 23 epic, 12 legendary) is too small a pool; one pack type only.
2. **Arena-style crafting.** Duplicates beyond the copy limit fill a **per-rarity progress counter**; a full counter yields a **crafting token of that rarity**; a token crafts one card of the same rarity. Dust is removed.
3. **Starter collection:** all generic cards, plus, for each faction, exactly the faction cards in that faction's starter deck in `data/starters.json`.
4. **Existing accounts are granted every card** (once, at migration).
5. **Tokens can be bought in the shop.**
6. **Tester flag:** only accounts the owner names get "all cards", and the UI shows it.
7. **Packs are bought with Cyllats** (`players.currency`), as today. Glimmer (`players.dust`) is untouched by this feature: it is no longer produced by duplicates or spent on crafting, and keeps its current sources (dailies). What Glimmer is for is a separate decision.

## Goals / non-goals

**Goals:** ownership means something; a new account can play immediately; a player can always work toward a specific card; the owner can unlock everything on chosen accounts for playtests.
**Non-goals:** real-money purchases; trading; selling cards back; faction packs; new card content; changing card balance; changing win-rate recording.

## Requirements

### A. Starter collection and new accounts

- **A1.** On registration, the server grants the starter collection **in the same transaction** as account creation.
- **A2.** Starter collection = every non-token card with `color == GENERIC` at its max copies (2; 1 for legendary), plus, per faction, the card counts in that faction's starter deck from `data/starters.json`. One data source; no second hand-maintained list.
- **A3.** The five premade starter decks must remain legal for every account (they are within the starter collection by construction). A test asserts each starter deck is fully covered by a fresh account's collection.
- **A4.** Tokens are never granted at registration.

### B. Existing accounts (one-time migration)

- **B1.** A one-time migration grants every non-token card at max copies to every account that exists when it runs. Where a row exists, quantity is raised to max (`GREATEST`), never lowered.
- **B2.** The migration is recorded in a marker table and is **idempotent**: re-running it, or restarting the relay, does not grant anything to accounts created later.
- **B3.** Existing token/progress state starts at zero. Existing `dust` stays as the account's Glimmer balance (see Open question 1).

### C. Duplicates, progress and tokens

- **C1.** A pulled card the player already owns at max copies (2, or 1 for legendary) is **not stored**. It adds 1 to that rarity's progress counter.
- **C2.** When the counter reaches the rarity's threshold, it resets (carrying any remainder) and the player gains 1 token of that rarity.
- **C3.** Starting thresholds (data-driven, in `data/shop_packs.json`): **common 3, rare 2, epic 2, legendary 2**. These are placeholders to be tuned with the simulation in section H.
- **C4.** A token of rarity R crafts exactly one card of rarity R. A craft is refused if the player already owns the card at max copies. Tokens are never converted back into cards' progress or into currency.
- **C5.** Ownership never decreases. There is no disenchanting.
- **C6.** Duplicates no longer award dust. `dust_awarded` is removed from the pack result.

### D. Packs

- **D1.** One pack type, priced in **Cyllats** (100 today). 5 cards. Slot rarity weights stay at 70/22/6/2 (common/rare/epic/legendary) as the starting point. The existing "at least one rare or better" guarantee stays.
- **D2.** **Legendary pity:** a per-account counter of packs opened since the last legendary card. At 25, the next pack is guaranteed to contain one legendary card; the counter then resets. (Placeholder, tune with the simulation.)
- **D3.** **Bonus token pity:** every 6th pack opened also awards one bonus token of a rarity rolled with weights common 50 / rare 35 / epic 12 / legendary 3. (Placeholder.)
- **D4.** **Duplicate protection:** a slot whose rolled card is already owned at max rerolls once, within the same rarity, if that rarity still has a card the player does not own at max. The second roll stands.
- **D5.** Token cards, `is_token` cards and cards outside the published pool are never rolled.
- **D6.** The roll is implemented **once, on the server**. `PackOpener.roll_pack` stops being a second copy of the rules; it either becomes a thin test/simulation helper over the same JSON config or is removed. The two implementations drifting apart is the highest-risk part of the old design.
- **D7.** A purchase is atomic: the player row is locked, price deducted, cards/progress/tokens/pity updated and returned in one transaction (as `purchase_pack` does today).

### E. Shop

- **E1.** Layout: the pack is the focal item, with price and **drop odds visible** (rarity weights, the guarantee, the pity rules in plain words). A separate **Tokens** section sells tokens per rarity. A **Craft** section lets the player spend tokens on a chosen card.
- **E2.** Token prices (placeholders, Cyllats - the same currency as packs): **common 40, rare 100, epic 300, legendary 1000**. Final numbers come from the simulation: a token should cost clearly more than the average value a player gets by simply buying packs, or nobody buys packs.
- **E3.** After a pack opens, the result screen shows what each duplicate did (e.g. "Duplicate: Common progress 2/3") and any token gained, including the pity token.
- **E4.** Insufficient-funds and server-error states keep the existing clear messages.

### F. Deck builder and collection

- **F1.** The deck builder shows **every card**. Unowned copies are greyed out with a count badge (`owned/max`, e.g. `1/2`). A **"Owned only"** toggle hides unowned cards. Existing search and faction/generic filters stay; add **rarity** and **mana cost** filters.
- **F2.** A deck cannot be saved with more copies of a card than the account owns. The server rejects it in `save_deck` with a clear message; the client prevents it before sending.
- **F3.** Selecting an unowned card offers **Craft** (if the player has a matching token) in place; otherwise it explains what is missing.
- **F4.** A **Collection** view (menu entry) reuses the card grid in browse mode and shows completion: owned copies out of total, overall and per faction/rarity, plus current tokens and progress counters.
- **F5.** A deck that is no longer legal (only possible when a tester flag is removed) stays saved, is marked **Invalid**, and cannot be queued for ranked.
- **F6.** Visual update: card grid with clear owned / missing / playtest states, a persistent deck list with mana curve, and the hover-preview behaviour already built. The pack-reveal animation is kept and polished, not rebuilt. Exact art and layout are decided in the first design pass, with the owner reviewing a screenshot.

### G. Tester flag ("all cards")

- **G1.** Controlled by a server environment variable **`ALL_CARDS_ACCOUNTS`**, a comma-separated list of usernames. Only the server reads it. No client request can set it, and it adds no database schema.
- **G2.** For a listed account the server treats every non-token card as owned at max copies, everywhere it checks ownership (save deck, ranked deck validation, economy state). The `owned_cards` rows are **not** modified, so removing a name from the list restores the real collection exactly.
- **G3.** The economy state returned to the client includes `all_cards: true`; the deck builder, collection view and profile show a clearly visible **"Playtest account: all cards unlocked"** badge.
- **G4.** Packs, tokens and crafting keep working for such an account (progress and tokens accrue normally), so shop flows can still be tested.
- **G5.** The username list is matched case-sensitively against `players.username`; an unknown name is ignored with a log line.

### H. Tuning simulation (required before the numbers ship)

- **H1.** A small script (`server/tools/simulate-packs.js`) uses the real config and roll to report, over many simulated players: packs to first legendary, packs to a complete collection, expected tokens per 100 packs, and share of packs containing at least one new card.
- **H2.** Acceptance: a free-to-play pace of roughly one pack per day-of-play gives a playable collection of a faction within a few weeks, and nobody sees 25+ packs without a legendary. If the numbers fail, adjust the data, not the code.

### I. Server enforcement and trust

- **I1.** Server-run ranked matches (`createMatch`) verify, in addition to legality, that the account owns every card in its chosen deck (premade starters are always allowed, tester accounts bypass via G2). Failure ends the pairing with the existing `invalid_deck` error.
- **I2.** Single-player, campaign and casual lobbies keep their current client-trust model. Ownership gating there is a UI rule. This is deliberate: the relay does not validate decks it does not run.
- **I3.** Win-rate recording is unchanged. Whether games from tester accounts should be excluded from the public win rates is open (Open question 4).

### J. Data model

- New table `collection_progress (player_id, rarity, tokens INT, progress INT, PRIMARY KEY (player_id, rarity))`.
- New columns on `players`: `packs_since_legendary INT`, `packs_opened INT` (drives D2 and D3).
- New table `schema_migrations (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ)` to record the one-time grant (B2). Migration added through `schema_legacy.js` so tests build the same schema.
- `players.dust` and `players.currency` are unchanged; `dust` is no longer touched by pack or craft logic.

### K. Protocol changes

- `economy_state_result`: add `tokens` and `progress` (per rarity), `packs_since_legendary`, `all_cards`.
- `purchase_pack_result`: per card, add whether it was new or became progress; add `tokens_gained`, updated `progress`, and any pity bonus token. Remove `dust_awarded`.
- `craft_card`: now spends a rarity token (`craft_card_result` carries remaining tokens).
- New `buy_token` request/result.
- `claim_earn_reward` is unchanged.
- `save_deck` gains ownership validation and a distinct error for "not owned".

## Acceptance tests

1. A fresh account owns exactly the starter collection; all five starter decks validate against it; a 40-card deck can be built in every faction.
2. Migration: existing accounts end with every card at max; a second run changes nothing; an account registered afterwards gets only the starter collection.
3. Pack roll: slot count, rarity guarantee, no token cards, duplicate protection rerolls once, atomic spend, concurrent purchases cannot double-spend or double-grant.
4. Progress/token: counters carry remainders; thresholds come from data; crafting spends exactly one same-rarity token and refuses a maxed card; ownership never decreases.
5. Pity: legendary guarantee fires at the configured count and resets; every Nth pack awards the bonus token.
6. `save_deck` rejects a deck with unowned copies; server-run ranked refuses an unowned deck and accepts starter decks.
7. Tester flag: listed account passes all ownership checks, `owned_cards` is untouched, removing the name restores the real collection, an unlisted account cannot gain it by any client message, the badge state reaches the client.
8. Real-server playtest of shop, pack opening, crafting and deck building (the old feature was only verified headlessly).

## Suggested build order

1. **Server:** schema, migration, starter grant, ownership helpers, the single pack roll, tokens/progress/pity, `craft_card`, `buy_token`, tester flag, ranked ownership check, simulation script. Tests against the disposable Postgres.
2. **Client plumbing:** `Economy` state for tokens/progress/`all_cards`, protocol handlers, remove dust UI from shop/crafting.
3. **Deck builder:** ownership display, filters, save validation, craft-in-place, badge.
4. **Collection view and shop redesign,** with a screenshot review pass.
5. **Tune** with the simulation, then a live playtest.

## Open questions

1. **Resolved: packs cost Cyllats.** One follow-up remains: Cyllats are currently earned only from ranked-tier and campaign milestones (75/100), while a pack costs 100. If packs are the heart of the collection loop, that is a very slow income. Decide how Cyllats are earned (per win, per daily, per quest) before tuning pack pricing. Glimmer needs a purpose too, or should be folded into Cyllats.
2. **Pity and threshold numbers** (C3, D2, D3, E2) are placeholders until the simulation runs.
3. **Names** for the crafting tokens (Arena's "wildcard" is a trademark). Suggest something in the Glimmer/Cyllats vein.
4. **Tester games and public win rates:** exclude games played by `ALL_CARDS_ACCOUNTS` accounts from the win-rate API, or count them? Excluding keeps the statistics about real collections but needs a flag recorded per game.
5. **Ranked for tester accounts:** allowed (current plan) or blocked, so all-cards accounts cannot affect the ladder?
