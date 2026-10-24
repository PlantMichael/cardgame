# Contract: Relay ↔ Match Host (localhost)

Private. The match host (`godot --headless --path <project> -- --match-host`)
listens on `127.0.0.1:<port>`; the relay is its only client. Newline-delimited
JSON, one request → one reply, matched by `rid`. The first frame on a
connection MUST be `hello` carrying the shared secret passed through the
environment; any other first frame closes the connection.

The host performs no network or database access beyond this socket and reads no
wall-clock time inside rules.

## Requests (relay → host)

| `op` | Fields | Effect |
|---|---|---|
| `hello` | `secret`, `rules_version` | Authenticates; host replies with its own `rules_version` and capacity |
| `create` | `match_id`, `seed`, `first_seat`, `deck_a`, `deck_b`, `rules_version` | Builds a match; runs the opening deal; replies with both seats' initial views (mulligan state) |
| `command` | `match_id`, `seat`, `cmd` | Validates and applies via `execute()`; replies `{ok, error?, seq, state_hash, events_by_seat, views_by_seat, over?}` |
| `timeout` | `match_id`, `seat` | Applies the deterministic defaults for that seat's open choice and ends its turn; same reply as `command`, `kind: timeout_default` |
| `concede` | `match_id`, `seat` | Ends the match with that seat as loser |
| `view` | `match_id`, `seat` | Current view for a (re)connecting seat, plus events since an optional `since_n` |
| `replay` | `match_id`, `seed`, `first_seat`, `deck_a`, `deck_b`, `rules_version`, `actions: [{seat,kind,cmd}]` | Rebuilds a match by re-applying the log; replies the final `state_hash` (and per-step hashes on request) |
| `drop` | `match_id` | Frees a finished/voided match |
| `stats` | — | `{live_matches, uptime_s, last_error}` for health checks |

`seat` is only ever `a` or `b`. **Identity is the relay's job**: the host never
sees usernames, tokens or account ids.

## Replies (host → relay)

```json
{
  "rid": 812,
  "ok": true,
  "seq": 57,
  "state_hash": "9f2c…",
  "kind": "command",
  "views": { "a": { }, "b": { } },
  "events": { "a": [ ], "b": [ ] },
  "over": { "winner": "a", "reason": "completed" },
  "facts": null
}
```

- `views[seat]` is `GameState.to_net_dict(seat)` plus the open `pending_choice`
  **only in the view of the seat that must answer it**.
- `events[seat]` are already filtered per seat (see rules-core contract).
- On refusal: `{ "rid", "ok": false, "error": "not_your_turn" }` with **no**
  state change and no `seq` advance.
- On match end `over` is set and `facts` carries the statistics recorder output
  (per-card drawn/kept/played for both sides) for the relay to store.
- Errors the host cannot handle return `{ok:false, error:"host_fault"}`; the
  relay then voids the match (no rank change) and restarts the host.

## Guarantees and checks

- Strict single-writer ordering per match: the host rejects a `command` whose
  `expect_seq` ≠ its current `seq`, so a duplicate or reordered command from the
  relay fails closed.
- `state_hash` is a stable hash of the full authoritative state (including
  hidden zones). It is never sent to clients; it is stored in the action log and
  compared on replay.
- The relay refuses to start ranked authoritative matches until `hello`
  succeeds and `rules_version` matches.
- Health: the relay pings `stats` every 5 s; three misses restart the host and
  trigger resume-from-log for every active match.
