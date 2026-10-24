# Quickstart: Validating the Card Statistics Database

Runnable scenarios that prove the feature end to end. Detail lives in
[data-model.md](./data-model.md) and [contracts/](./contracts/); this file only
says what to run and what to expect.

## Prerequisites

- Node ≥ 20, the Godot 4.7 editor/console build, and a **disposable** local
  Postgres database (never the production one):
  `DATABASE_URL=postgres://localhost/cardgame_stats_test`.
- `STATS_KEY=<any long random string>` in the environment (the server refuses
  to start recording without it).
- From the repo root: `cd server && npm install` (already a dependency set).

## 1. Client recorder (headless, no database)

```bash
godot --headless --path . -- --core-tests
godot --headless --path . -- --stats-test
```

Expect: `CORE TESTS ... 0 failed`, including the `MatchRecorder` suite; and
`--stats-test` plays a fixed-seed AI-vs-AI match and prints `RESULT: PASS`,
confirming the produced report's deck, drawn/kept/played counts match a
hand-computed expectation, that cards created by effects land in `created` not
`facts`, and that an AI-search copy (`duplicate_for_sim`) produced **no**
recorder activity.

## 2. Server ingestion and verification

```bash
cd server && npm test
```

Expect all of these to pass (spec SC-001, SC-002):

- Two agreeing reports for a registered `rk_*` match → exactly one
  `stat_matches` row, `status = verified`.
- Duplicate reports, a replayed report, a report from a non-participant, a
  report for an unknown human match id, and a conflicting winner → no extra
  rows; conflicting winner stored `disputed` / `winner_conflict`.
- Illegal decks (unknown id, token, too many copies, three factions) →
  `deck_illegal`.
- A single report for an unregistered `ai_*` id → `unverified`, excluded from
  every summary.
- An implausibly short match → `implausible_duration`.

## 3. Privacy-gated release

```bash
cd catalog && npm test
node ../server/tools/stats.js aggregate --version 1.0.0 --yes
node src/stats-release.mjs build --game-version 1.0.0
```

Expect the build to print a **review report** and write only a draft; a
fixture with thinly sampled cards shows those cards absent, and an injected
username/match id in the data makes the build **refuse** (SC-004, SC-005).
Then:

```bash
node src/stats-release.mjs publish --approve <draft>
npm start   # serves catalog/public on :8080
curl -s http://localhost:8080/data/v1/stats/latest.json
node examples/consume-stats.mjs http://localhost:8080
```

Expect `latest.json` to point at the release, the example to print one card's
win-when-played using only the public file (SC-010), and re-running `publish`
for the same draft to be a no-op.

## 4. Real-match smoke test (manual)

1. Launch two clients against a local relay; play a short ranked match to
   completion on both. Result screen and ranked rank change must appear with no
   added delay (SC-007).
2. `node server/tools/stats.js status` → one `verified` match.
3. `node server/tools/stats.js show-match <id>` → both decks, per-card facts,
   tier groups, game version.
4. Play one match vs the AI → appears as `unverified`, `match_type = ai`.
5. Kill one client mid-match → recorded `disconnected`, absent from card
   figures.
6. First recorded match shows the one-time disclosure notice exactly once.

## 5. Deletion and retention

```bash
node server/tools/stats.js unlink --player <id> --yes
node server/tools/stats.js purge --older-than 24m --dry-run
```

Expect zero rows in `stat_sides` still carrying that `player_id`/`account_key`
(SC-008), and the purge dry-run to list what it would remove.

## Done when

Scenarios 1–3 pass automatically, scenario 4 is checked by hand once, and
`.docs/stats.md` describes what was verified and what was not.
