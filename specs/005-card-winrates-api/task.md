# Public card win rates

User asks to add card win rates to the API and explicitly permits combining AI and real-player games. They also ask whether custom decks count: yes, use the actual starting decks, not starter-deck membership. Source base: `27fdfaf`, branch `codex/card-winrates-api`.

## Outcome and scope

Add `GET /data/v1/stats/card-winrates.json` on the public catalog. Define a card's rate as wins divided by recorded **player-games whose starting deck includes that card**. Two copies count once per player-game. Count the human deck in recorded AI settlements and each settled seat in server-run PvP; a mirror match can contribute one win and one loss. Exclude tokens, legacy results without starting decks, unsettled/voided/drawn matches, and cards outside the published collectible catalog. Custom and starter decks use the same rule. Return match counts, wins, losses, fractions (null for zero samples), generation time, catalog version, and an explicit combined AI/PvP methodology with no minimum-sample suppression. This is intentionally a preliminary aggregate; never return player identifiers, match IDs, raw deck lists, tokens or database errors. Exact small-sample aggregates can permit inference of a deck or outcome by comparing snapshots; they do not promise protection against differencing.

Keep printed card definitions, immutable releases, client recording, ranked rewards and websocket protocol unchanged. No client changes or new web export needed. Preserve the previously proposed immutable `/stats/latest.json` and release contracts as unimplemented; this new live summary does not pretend to implement drawn/played statistics, tiers, historical releases, caps or deck archetypes.

## Grounded design

`ranked_settlements` is already unique on match/player and holds AI `ai_match.player_deck` plus `won` (`server/schema_legacy.js`, `server/relay.js`). Authoritative PvP stores `deck_a`, `deck_b`, participant IDs and terminal status in `ranked_matches` (`server/authoritative/schema.js`); its settlements use the same table (`server/authoritative/settle.js`). Joining these owners prevents retry double counting. The existing relay pool already owns database access; the standalone catalog has no dependencies or credentials (`catalog/package.json`, `catalog/src/server.mjs`).

- Add a small relay aggregation/HTTP owner using existing `pg` and `http`. SQL deduplicates cards per settled player-game, unions AI and eligible PvP without duplicates, and filters published collectible IDs at the relay itself (the relay route is also public). Load the allowlist from the committed catalog manifest and its linked card release; include `catalog/public/data/v1/` in the relay Docker image and adjust `.dockerignore` so that COPY can see it. Missing/bad publication metadata fails only the stats request, not relay startup or matchmaking. If authoritative tables do not exist (flag off), AI aggregation still works; discover table availability rather than migrating unrelated schema.
- Cache one successful aggregate in relay memory for 60 seconds, coalesce concurrent refreshes, and never cache failures. A database failure returns generic 503, not empty success or stale figures. Aggregate reads never mutate the database. Query time is bounded by the existing pool timeout.
- Wire the HTTP server to the existing websocket server on the same port, preserving upgrade behavior and the existing non-endpoint 426 response. The aggregate route allows GET/HEAD/OPTIONS with anonymous CORS; other methods return 405. No user-selected query, player or upstream target.
- Catalog handles the same route, fetching the fixed game-relay origin (default the same deployed origin as `Net.RELAY_URL`; optional operator `CARD_WINRATES_ORIGIN` for local/staging). Use a bounded upstream timeout and response-size limit, validate/project only public aggregate fields, join the published collectible list, and return one row per collectible with null rate for no samples. Invalid/unavailable upstream is generic 503 with no cached error. Existing printed-catalog routes and health check remain independent. No new package or database credential is needed.
- Use short cache headers at the catalog (revalidate) so freshness is dominated by the relay's 60-second cache. Metadata states combined modes, the starting-deck definition, AI human-seat-only counting, and no sample threshold. Preserve existing method/CORS/HEAD behavior. Document actual endpoint, sample JSON, zero/small samples, old missing data, deployment of BOTH relay and catalog, optional origin setting, and no need to rebuild the browser client.

Alternative: adding Postgres directly to catalog would add credentials/dependencies and a second database owner. Batch publishing would require a new scheduled/export/manual operation before games became visible. Reusing the relay pool plus a bounded aggregate-only catalog fetch is sufficient for the current requested live API.

## Acceptance and proof

1. Actual HTTP GET from catalog backed by a real local relay and disposable Postgres returns correct wins/matches for mixed AI/PvP, custom decks, duplicates and mirror matches; zero samples are null. Only currently published collectible IDs appear at BOTH the catalog and direct relay endpoint. Test a withheld card (`gen_str_005`, `t_str_004` or `t_027`) in a recorded deck against both endpoints. Missing relay publication files return stats 503 while websocket operation remains available. Check the Docker context/image COPY boundary with the canonical image build when practical; otherwise record exact remaining container proof.
2. Repeated settlement, pending/voided/drawn PvP, unknown IDs, AI opponent decks and legacy rows without summaries do not inflate rates. AI-only schema works before authoritative tables exist.
3. Concurrent requests share a refresh; cached results refresh after 60 seconds, and a failed query can recover on the next request. Check observable counts with controlled clock and a real pool, not mock-call counts.
4. Existing websocket clients still connect/settle. GET/HEAD/OPTIONS/405, CORS, generic 503, upstream timeout/size/malformed data and absence of private fields are checked through real HTTP. Ordinary printed catalog remains available if stats are unavailable. Existing catalog server tests remain green.
5. Reuse the pinned Node runner, existing `pg`/`ws`, catalog fixtures, and a task-owned Postgres container; separate test schemas preserve other suites' data. Run the smallest real relay/catalog/SQL integration and affected existing websocket/HTTP checks. No production DB reads, pushes, deploys or new services under this implementation request. Operator proof is deploying both services, fetching the new route, and checking a new game after cache expiry.

Owning docs: `catalog/README.md`, `catalog/stats-website-spec.md`, `.docs/authoritative-server.md` and `.docs/status.md`. New formal spec and implementation receive configured inner/outer reviews for the public aggregate contract and HTTP/websocket seam. Author: current Codex session; configured standalone Claude is unavailable. Review profile: `codex/gpt-6.1-sol`, xhigh. Provider publication is a later operator step.

## Operator decision

On 2026-10-27 the user selected "Show small samples for now (1+ games)" after being told about the earlier 100-game rule and that exact small samples can reveal cards in a single player deck through changing counts. This testing policy explicitly supersedes the old minimum-sample and anti-differencing policy for this new live endpoint only. The response and docs must describe the preliminary, unsuppressed aggregate and its inference limitation. No privacy batching subsystem is required.

## State

Inner review correction: the initial design filtered publication only at the catalog; direct relay output also needs the same published-card allowlist. The revision above adds this at its source plus the required Docker data input. Inner and outer spec reviews approved the corrected design; the outer review also approved the explicit small-sample operator decision.


## Implementation evidence

Implemented the relay aggregate/HTTP owner, catalog projection, publication allowlists, Docker input, and owning docs. No database schema, client, dependency or web-export changes. The added tests ship because they protect distinct SQL/HTTP behavior, upstream failure boundaries and continued websocket operation; existing recorder/static-server tests cover unchanged consumers.

- `server`: `node --test test/card_winrates.test.js test/ranked_ai_record.test.js` with task-owned local disposable PostgreSQL 17: 3/3 pass. Full SQL -> relay HTTP -> catalog HTTP proof includes AI-only schema, custom/duplicate/mirror decks, canonical PvP settlements and replay, excluded pending/voided/drawn/legacy data, unpublished/token/unknown IDs, 60-second cache/concurrent refresh, failed-read recovery, generic errors, methods/CORS/HEAD and websocket upgrades. Existing real relay recorder regression also passes. After strengthening clock/invalid-ID assertions, `node --test test/card_winrates.test.js`: 1/1 pass.
- `catalog`: `node --test 'test/*.test.mjs'`: 24/24 pass, including bounded local upstream HTTP failure/timeout/redirect/size/malformed-count cases and static route regression.
- Docker root-context probe: `FROM scratch` plus the production `COPY catalog/public/data/v1 /catalog/public/data/v1` succeeds using the actual root `.dockerignore`, transferring 90.52 kB, image `sha256:93a54eeb6aadb2860d3ea8a42f1773c8076c7f85a266ee731ee2e8fe91c27292`. This proves the changed COPY/input boundary. Full Godot relay image rebuild is intentionally unrun; unchanged engine download/import layers are outside this delta.
- `git diff --check`: pass. Tests write only disposable private database schemas/temp fixtures. Godot producer hook was not rerun (no client changes); existing relay result submission passed.

Implementation source approved by fresh inner and outer reviews on `b028709` (base `27fdfaf`); no outstanding findings. Outer independently reran the SQL/HTTP test (1/1), real relay recorder tests (2/2), and catalog upstream test (1/1), all passing. Remaining operator proof: deploy both services, fetch the new route and compare counts after a newly completed game/cache expiry. Nothing pushed or deployed by this work item.

