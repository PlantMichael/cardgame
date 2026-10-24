# Contract: Maintainer CLI (private)

`server/tools/stats.js` is the **only** way to read raw or private data. It
connects with `DATABASE_URL` (the project's existing root credential); there is
no network endpoint behind it. Every invocation appends a `stat_audit` row
(`actor = cli:<os-user>`, command, arguments without secrets).

```text
node server/tools/stats.js <command> [options]
```

| Command | Purpose | Output |
|---|---|---|
| `status` | Counts of matches by `status`, `match_type`, `game_version`; oldest pending; rows near retention | Table to stdout |
| `show-match <match_id>` | One match with sides, deck cards, reports, status reason | JSON to stdout (private — contains `player_id`) |
| `disputes [--version v]` | List disputed matches with reason codes | Table |
| `reevaluate <match_id> --reason "<text>"` | Re-run verification on a disputed/unverified match; reason is mandatory and audited | New status |
| `aggregate [--version v]` | Rebuild `stat_summary_card` / `stat_summary_deck` from verified rows, applying caps | Row counts |
| `card <card_id> [--version v --tier t --type m]` | Private per-card summary with sample sizes (uncapped and capped) | Table |
| `decks [--version v]` | Private deck summaries incl. exact-list (`deck_hash`) rows with ≥ minSample | Table |
| `unlink --player <id>` | Null `player_id` and `account_key` on all of that player's `stat_sides` rows; used for account deletion | Row count |
| `purge --older-than <N>m [--dry-run]` | Retention: delete matches older than N months; refuses if their version has no archived aggregate | Row counts |
| `audit [--since <date>] [--action <a>]` | View denied/abusive report attempts and CLI use | Table |

Rules:

- Commands that change data (`reevaluate`, `aggregate`, `unlink`, `purge`)
  print what they will do and require `--yes` unless `--dry-run`.
- `show-match` and `card --uncapped` are the only commands that can reveal
  `player_id`; their output is for the maintainer's terminal and is never
  written to `catalog/`.
- Exit code `0` on success, nonzero on any failure; failure never leaves a
  half-applied change (each mutating command is one transaction).
- Release building and publishing are a separate tool
  (`catalog/src/stats-release.mjs`, see `published-card-stats.md`) so that the
  tool that can see `player_id` and the tool that writes public files share
  no code path except the already-anonymous summary tables.
