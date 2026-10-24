# Contract: Client ↔ Relay for Server-Run Matches

Follows the existing `relay.js` convention: `{ type: '<action>', ... }` over the
authenticated websocket; the server answers with typed messages. The caller is
identified **only** by the session token; any seat, deck, winner or turn
information a client sends is ignored or rejected.

## Queueing (existing flow, extended)

`queue_ranked` is unchanged except it now also carries:

```json
{ "type": "queue_ranked", "token": "…", "deck_name": "My Teal Deck", "rules_version": 12 }
```

- `deck_name` selects one of the **account's saved decks**; the server reads the
  card list itself. A name that is not one of the caller's decks, or an illegal
  deck, is refused before pairing.
- A `rules_version` that differs from the server's returns
  `{ "type": "update_required", "server_rules_version": 12 }` and the player is
  not queued.
- At capacity: `{ "type": "ranked_busy" }`.

`ranked_match_found` (existing) additionally includes `"authoritative": true`,
the seat label, and the opponent display data already sent today. No opponent
deck or hand is ever included.

## Messages (client → relay)

| `type` | Fields | Notes |
|---|---|---|
| `match_join` | `match_id`, `since_n?` | Sent right after `ranked_match_found` and on every reconnect; takes over the seat (closing a previous connection for it) |
| `match_command` | `match_id`, `client_seq`, `cmd` | `cmd` is one of the plain-value commands (rules-core contract). `client_seq` increases by 1 per command; the server refuses gaps/duplicates |
| `match_mulligan` | `match_id`, `client_seq`, `card_uids` | Carried as a command on the same ordered stream |
| `match_concede` | `match_id` | Immediate concession |
| `match_ping` | `match_id` | Keep-alive; also lets the client sync its clock display |

## Messages (relay → client)

| `type` | Fields | Notes |
|---|---|---|
| `match_view` | `match_id`, `seq`, `view`, `events`, `clock` | The player's own view (never hidden zones of the opponent) and the filtered events produced since the last message; sent to **both** seats after every accepted action |
| `match_ack` | `client_seq`, `accepted: true` | The action was applied (and durably logged) |
| `match_error` | `client_seq`, `reason` | `not_your_turn`, `illegal`, `stale`, `duplicate`, `rate_limited`, `unknown_match`, `not_a_participant` — generic by design; no state change |
| `match_clock` | `turn_remaining_s`, `opponent_disconnect_remaining_s?` | Display only; the server's clock is the only one that counts |
| `match_over` | `winner_is_me`, `end_reason`, `ranked_outcome` | Contains the already-settled ladder change (same shape as today's `ranked_result_ack`); sent after settlement |
| `opponent_disconnected` / `opponent_reconnected` | — | Drives the "opponent disconnected" countdown |
| `match_voided` | `reason` | No rank change |

## Rules for clients

1. A client MUST render only from `match_view`/`events`. It MUST NOT apply a
   command locally before it is acknowledged (a short "pending" state is shown
   instead); it never runs rules for a server-run match.
2. After a reconnect it sends `match_join` with the last `seq` it displayed and
   rebuilds from the returned view.
3. `report_ranked_result` is **not sent** for a server-run match; if it is sent
   it is ignored (settlement already ran from the host's result).
4. Actions are rate-limited per seat (default 20/s) and oversized frames
   (> 8 KB) are dropped and audited.

## Relay obligations

1. Authenticate; look up the match and seat from the token's account, never
   from a client-provided seat.
2. Forward `cmd` to the host as `command` with `expect_seq`; on `ok`, commit the
   action row, then send `match_ack` to the sender and `match_view` to both
   seats.
3. Own the clocks: on turn expiry send the host `timeout`; on disconnect-grace
   expiry end the match as a forfeit.
4. On `over`, settle once through the existing ladder math, store the match
   facts for spec 002, then send `match_over`.
5. Reject any message about a match the caller is not seated in with the same
   generic error as an unknown match.
