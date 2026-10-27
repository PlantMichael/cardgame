# Record completed ranked AI games

User request: "it was against an ai. we need the ai in the logs because my game doesnt have a playerbase yet"; "go ahead and add the ai match recording".

## Scope and current behavior

The local AI controller already gives each match an `ai_…` identity and sends its result through `Auth.report_ranked_result` (`scripts/game/game_manager.gd:46,343`). The relay authenticates the reporter and atomically stores one `ranked_settlements` row per match/player with the ladder update (`server/relay.js:763-887`). Only server-run PvP goes into `ranked_matches`; local AI games must remain distinguishable and unverified.

Implement in `codex/ranked-ai-recording`, based on `b6e56ae`. Preserve existing Elo, ladder and rewards, non-ranked games, PvP, and older client messages. No public statistics publishing, per-card draw/play counters, offline durable retry queue, account-data export, or provider changes. Existing network delivery limitations remain explicit.

## Smallest complete change

- Attach an optional `ai_match` object to the existing ranked result message, containing the starting human/AI card ID arrays, AI level, turn count and rules version. Capture starting decks at game creation, rather than reconstructing from depleted decks at the end. Only ranked local games send it.
- Add nullable JSONB `ai_match` to `ranked_settlements` using the existing idempotent schema initializer, including upgrade of populated databases. Keep null for old clients and PvP.
- Validate and project supplied metadata after authentication and existing-result replay, before opening the settlement transaction. Bound match ID, arrays and counters; require known non-token cards, an `ai_` identity and no known PvP match collision. Reject malformed supplied metadata with a failed ranked-result acknowledgment and no writes. Omitted metadata follows the existing behavior unchanged.
- The server adds fixed `mode: ranked_ai` and `source: client_reported` labels; it never accepts client-provided verification/identity labels. Store this projection in the SAME settlement insert and transaction as the existing reward update. A duplicate/retry returns the first result, without replacing telemetry or awarding again. A failed transaction stores neither a settlement nor telemetry.
- Document where to query these logs (`ranked_settlements`, not `ranked_matches`), rollout requiring BOTH new relay and rebuilt client, lack of retroactive/offline recovery, and exclusion from verified PvP statistics. This is a completed-match summary, not an action replay.

## Acceptance and verification

1. A new ranked AI game produces both starting decks, difficulty, turns and rules version in the authenticated player's settlement. Result remains in existing `won`; metadata labels cannot be spoofed.
2. Resending an identical or altered report for the same match/player preserves the first record and changes ladder once; a transaction error preserves neither new telemetry nor rewards.
3. Old client reports still settle without telemetry; legacy/server-run PvP remains unchanged. Non-ranked local matches send no AI metadata.
4. Malformed/oversized/unknown-card AI metadata is refused without database mutation. Session identity owns records; payload identity is ignored. Known PvP IDs cannot acquire AI metadata.
5. Fresh-schema and populated-upgrade checks use real disposable Postgres; real relay websocket tests save/reload metadata and check replay/rejection/rollback. Pure validation checks cover distinct malformed inputs at the validator owner. Client verification must exercise the real report producer against a local relay if Godot is available; otherwise report that exact manual test as outstanding. Existing server settlement tests protect unchanged award math.

Use Node's existing test runner, pinned `npm ci` dependencies and a task-owned disposable Docker Postgres. No production queries, push, or deployment. Update `.docs/authoritative-server.md`, `.docs/status.md` and affected source comments. Review code and contract changes through inner and outer gates (persisted metadata and client/server contract). Full spec is implementation preparation under the user's execution request. Author: current Codex session; configured standalone Claude is unavailable, so continue on the active host. Review profile: configured `codex/gpt-6.1-sol`, xhigh.

## State

Spec approved by fresh inner and independent outer reviewers on 2026-10-27.
Implementation complete. Fresh spec reviewers: `ai_spec_inner` and `ai_spec_outer`, both approved. Implementation review outcomes are reported in the completion message; production rollout remains operator-owned.

Verification on Windows with Node 22.23.2, repo-pinned Godot 4.7.2, and a task-owned disposable Postgres 17 (not a production database):

- `cd server; node --test test/ranked_ai_record.test.js` with disposable `DATABASE_URL` and `GODOT_BIN`: 2/2 passed, including real Godot → relay → Postgres save/reload, original decks after depletion, non-ranked exclusion, metadata validation and provenance, session ownership, replay, legacy PvP settlement, populated-schema upgrade, transactional rollback and retry. Initial failures were a stale fixture card ID, a stopped test database, and launching a fixture with `--script` instead of a scene; all corrected before the passing run.
- `node --test server/test/pg_store.test.js` with disposable `DATABASE_URL`: 11/11 passed. Existing PvP persistence, schema initialization and settlement behavior remained green.
- `cd server; node --test test/settlement.test.js`: 7/7 passed (pre-change baseline, reused because the award math and its owner are unchanged).
- `node --check server/relay.js`, `node --check server/ranked_ai_record.js`, and `git diff --check`: passed.
- Godot import generated changes to tracked `.import` settings. Inspected and restored only those task-generated settings; imported cache stays ignored. No assets, dependencies or lockfiles changed.

Deployment is intentionally not performed. Operator must deploy the updated relay, rebuild/publish the updated client, complete a ranked AI game, and inspect `ranked_settlements.ai_match`. No changes to catalog publication or per-card counters. Test container is stopped/removed after verification; no other stacks are operated on.

## Web export and publication follow-up (2026-10-27)

User authorized pushing the change to GitHub and specifically requested a Godot web export. Source candidate `4445cc4` received both inner and outer implementation approval without changes. This follow-up keeps those source files unchanged and adds the matching generated browser build.

- Installed the official matching Godot 4.7.2 web export templates on this PC.
- `Godot_v4.7.2-stable_win64_console.exe --headless --path . --export-release Web build/index.html`: exit 0. The existing `Web` preset and `vercel.json` remain unchanged. Updated `build/index.html`, `index.js`, `index.pck` and `index.wasm`; also retain the engine-generated UID for the test fixture script. Restored incidental import-setting churn after inspection.
- Served `build/` on a task-owned localhost HTTP server with the correct WebAssembly MIME type. The exported game visibly reached its login screen in the in-app Chromium browser; captured browser console warnings/errors were empty. This checks startup, not an authenticated live game or hosted deployment. The earlier real Godot/relay/Postgres proof covers the report producer.
- Publish the reviewed source and browser build together on `codex/ranked-ai-recording` in `PlantMichael/cardgame`. Existing deployment integrations tracking `master` still require merging this branch. No direct Railway or Vercel configuration mutation is part of the push.
