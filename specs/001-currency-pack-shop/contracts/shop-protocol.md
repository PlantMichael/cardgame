# Contract: Client ↔ Relay Shop/Economy Protocol

Follows the existing `relay.js` convention: the client sends
`{ type: '<action>', ...payload }` over the authenticated WebSocket
connection (same connection used for login/ranked/decks); the server
replies `{ type: '<action>_result', success: bool, ...payload }`. All
actions require a valid session (same `token`/session lookup used by
`save_deck`/`report_ranked_result`); an expired session replies with
`success: false, message: 'Session expired.'`, matching existing handlers.

## `get_economy_state` → `economy_state_result`

Fetched on login/resume (alongside the existing profile/deck fetch) so the
client's `Economy` autoload starts from the server-authoritative values.

Request:
```json
{ "type": "get_economy_state" }
```

Response:
```json
{
  "type": "economy_state_result",
  "success": true,
  "currency": 250,
  "dust": 40,
  "owned_cards": [ { "card_id": "g_001", "quantity": 2 } ]
}
```

## `purchase_pack` → `purchase_pack_result`

Request:
```json
{ "type": "purchase_pack", "pack_id": "standard_pack" }
```

Server behavior: looks up `pack_id` in the server's copy of
`data/shop_packs.json` (server holds the same file as a content source, not
a second schema), verifies `currency >= price`, debits `currency`, rolls the
pack server-side against the player's current `owned_cards` (see
data-model.md §Pack Opening Result), applies collection increments and any
dust credit atomically, then returns the result for the client to animate.

Response (success):
```json
{
  "type": "purchase_pack_result",
  "success": true,
  "currency": 150,
  "dust": 55,
  "result": {
    "pack_id": "standard_pack",
    "cards": [
      { "card_id": "g_014", "was_new": true },
      { "card_id": "cr_003", "was_new": true },
      { "card_id": "bl_009", "was_new": false },
      { "card_id": "g_002", "was_new": true },
      { "card_id": "tl_011", "was_new": true }
    ],
    "dust_awarded": 15
  }
}
```

Response (insufficient funds, FR-006):
```json
{
  "type": "purchase_pack_result",
  "success": false,
  "message": "Not enough currency for this pack."
}
```

**Client contract**: the client MUST treat `purchase_pack_result` as the
sole source of truth for what was in the pack — it renders the reveal
animation from `result.cards` rather than rolling anything locally. If the
connection drops after sending `purchase_pack` but before a response
arrives, the client re-fetches `get_economy_state` on reconnect rather than
assuming the purchase failed (Edge Case: mid-reveal disconnect).

## `craft_card` → `craft_card_result`

Request:
```json
{ "type": "craft_card", "card_id": "g_014" }
```

Server behavior: looks up `card_id`'s rarity (client sends the id; server
resolves rarity/cost from its own copy of card data, not from client input),
verifies `dust >= cost`, debits `dust`, increments `owned_cards`.

Response (success):
```json
{ "type": "craft_card_result", "success": true, "dust": 40, "card_id": "g_014" }
```

Response (insufficient dust):
```json
{
  "type": "craft_card_result",
  "success": false,
  "message": "Not enough dust to craft this card.",
  "dust_needed": 15
}
```

## `claim_earn_reward` → `claim_earn_reward_result`

Fired by the client when a daily-first-win or milestone condition (FR-002)
is met (e.g. immediately after a `report_ranked_result` ack indicates a new
rank tier, or after the first match-complete of the day). The server is the
one that decides eligibility and amount — the client only signals "this
condition just happened," it does not claim an amount.

Request:
```json
{ "type": "claim_earn_reward", "reason": "daily_first_win" }
```

Response (always carries both balances, whichever one the reward actually
changed - `daily_first_win` grants dust/Glimmer, `ranked_milestone` and
`campaign_milestone` grant currency/Cyllats):
```json
{
  "type": "claim_earn_reward_result",
  "success": true,
  "currency": 250,
  "dust": 300,
  "amount_awarded": 50,
  "reason": "daily_first_win"
}
```

If the condition was already claimed (e.g. daily bonus already granted
today), the server responds `success: false` with an explanatory `message`
rather than silently no-op'ing, so the client doesn't show a false reward
animation.
