# Contract: Client → Relay Match Stats Report

Follows the existing `relay.js` convention: the client sends
`{ type: '<action>', ...payload }` over the already-authenticated websocket; the
server replies `{ type: '<action>_result', success: bool, ...payload }`. The
caller's identity comes **only** from its session `token`; anything the client
says about *who it is* or *which seat it holds* is ignored.

This is the **only** stats-related message in the relay protocol. It is
write-only: no response ever contains another player's data or any stored
record other than the caller's own status.

## `report_match_stats` → `report_match_stats_result`

Sent once per match per participant, after the result screen is already shown
(never before ranked settlement). Safe to re-send.

### Request

```json
{
  "type": "report_match_stats",
  "token": "<session token>",
  "match_id": "rk_ab12cd34",
  "game_version": "1.0.0",
  "end_reason": "completed",
  "won": true,
  "turns": 11,
  "first_seat_was_me": true,
  "deck": [ { "card_id": "g_001", "copies": 2 }, { "card_id": "gen_str_001", "copies": 1 } ],
  "facts": [
    { "card_id": "g_001", "drawn": 2, "kept": 1, "played": 3, "first_turn": 2 }
  ],
  "created": [ { "card_id": "cr_001t", "count": 1, "played": 1 } ],
  "opponent_played": [ { "card_id": "t_001", "played": 2 } ]
}
```

| Field | Rules |
|---|---|
| `match_id` | Required. Server-issued ids must be a match the caller is seated in. Ids starting `ai_` are client-issued (unverified path). |
| `game_version` | Required, ≤ 32 chars, `[0-9A-Za-z._-]`; checked against the server's allowed list. |
| `end_reason` | `completed` \| `conceded` \| `disconnected` \| `abandoned`. |
| `won` | The caller's own claim; `null` for a draw/abandon. |
| `deck` | The caller's **starting** deck: distinct card ids with copies. Validated server-side (see data-model / research §3). |
| `facts` | Per deck card: drawn / kept / played copies and first turn played. Each ≤ that card's `copies`; `kept ≤ drawn`. A guest sends `facts: []`; its draw/keep facts are attested by the host (research §5). |
| `created` | Cards that entered the match outside the starting deck. |
| `opponent_played` | Public information: cards the caller saw the opponent play. Used **only** for cross-checking against the opponent's `facts.played`. |

Size limit: 16 KB. Larger, malformed or schema-invalid messages are rejected
and audited.

### Response

```json
{ "type": "report_match_stats_result", "success": true, "status": "pending" }
```

`status` is the caller's view of the match: `pending` (waiting for the other
seat), `verified`, `unverified`, `disputed`, or `duplicate` (already settled for
this seat; the stored status is returned). On failure:

```json
{ "type": "report_match_stats_result", "success": false, "message": "Session expired." }
```

Failure messages are deliberately generic (`Session expired.`, `Not a
participant.`, `Invalid report.`, `Rate limited.`) and never reveal whether
another player's record exists. A client treats anything but `success: true`
as "keep the pending file and retry later", except `Invalid report.` and `Not a
participant.`, which discard it.

## Server behavior (normative)

1. Resolve the session; reject if expired.
2. Reject if `match_id` is a server-issued id and the caller is not a seated
   participant; reject if `match_id` is `ai_*` but the server registered that
   id as a human match.
3. Validate the schema, the deck and the facts' internal constraints.
4. Upsert `stat_reports` by `(match_id, seat)`; a second report from the same
   seat **cannot change** an already-stored report (replay returns `duplicate`).
5. When both seats have reported, or the 120 s window expires, settle in one
   transaction: compute status per the transitions in `data-model.md`, write
   `stat_matches`, `stat_sides`, `stat_deck_cards`, `stat_created_cards`.
6. Any rejection or conflict appends to `stat_audit` with a reason code.
7. **Nothing in this handler may delay, alter or depend on**
   `report_ranked_result`; the two are independent messages.

## Client behavior (normative)

1. At match end, the recorder produces the report dictionary from the logic
   layer; the UI is not involved.
2. Save to `user://pending_stats.json` (keyed by `match_id` + seat) **before**
   sending.
3. Send without awaiting; delete the pending entry on `success: true`.
4. On login/resume, re-send every pending entry; drop entries older than 14
   days.
5. Never block, delay or alter the result screen, rewards or ranked
   settlement because of this message.
