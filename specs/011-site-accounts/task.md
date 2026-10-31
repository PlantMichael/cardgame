# Site accounts and Google sign-in for cardgame

Revision 1 — specification handoff, 2026-10-30. No implementation or deployment performed. This is the complete input for the implementing agent; inspect the current checkout before starting.

## Requested outcome

Move browser login, registration, logout and profile management from the Godot game into the surrounding website. Keep the existing banner above the game. The banner displays the signed-in account name, profile picture, visible ladder rank and both currency balances. Add Google sign-in. A player signs in once on the website and enters the embedded game as that same account, with existing progress intact.

The user subsequently requested a spec for another agent instead of implementation. This document does not authorize pushes, deployments, production database changes, provider configuration changes or dependency changes. Follow the receiving session's authority for those operations.

## Repository and current behavior

Repository: https://github.com/PlantMichael/cardgame. Existing site: https://cardgame-xi-orpin.vercel.app. Existing relay: wss://cardgame-relay-production.up.railway.app. Reuse these services and the existing Vercel project.

Grounded against feature commit d68ed789c561b3a97893a652f027d8c972f5ca45. Production origin/master was 17f0305a2a3ad30c34d4624dcdd6e1238d1efaf2 during inspection. These differ: reconcile the intended implementation base before work and do not accidentally publish unrelated feature changes. A pre-existing unowned edit to data/cards/crimson.json must remain untouched.

Load-bearing owners, relative to the repo:

- website/pages.mjs:13-16 builds the common banner; :89 embeds /play/game.html in a same-origin iframe. website/build.mjs composes the static site and existing Godot Web export; website/README.md documents the build. The site uses plain HTML/CSS/JavaScript with no frontend dependencies.
- scripts/game/main.gd:145-152 starts the login gate; :1044 builds the in-game profile bar; :1281 builds the profile menu, including picture selection, rank, record and balances; :1605 and :1693 own the login gate and form. Search all other logout/auth entry points too, including multiplayer screens.
- scripts/game/auth.gd:5 stores Web sessions under cardgame_session; :6-7 stores pending ranked reports separately under cardgame_pending_ranked. :114 only flushes the head report for its recorded username. :228 applies account state; :272 and :285 save/load sessions. Native builds also use user files.
- scripts/game/economy.gd:20-52 listens for server results and reloads balances/ownership after login. Keep this game service: moving account UI does not remove gameplay authentication, purchases or collection ownership.
- scripts/game/ranked_progress.gd owns visible ladder naming, LP and rank icons. The hidden matchmaking rating is a different value.
- server/relay.js:192 projects profile fields; :446-520 handles password registration/login/session resume; :576 handles pictures; :599 handles economy snapshots; :897 deletes a session on logout. All account and economy authority lives on the relay/PostgreSQL side.
- server/schema_legacy.js:16-41 defines players and sessions, including required password fields, rank, currency, dust and pfp_id. No external identity or email field currently exists. server/package.json currently depends on pg and ws only.

Recheck these locations on the chosen base. Current profile replies do not include balances or a stable player ID; the resume query also needs checking for pfp_id completeness. Do not perpetuate those omissions in the new site account snapshot.

## User-facing behavior

On every site route, a signed-out banner offers Log in and Register, with Google sign-in available in the account surface. Public home, rulebook and glossary remain readable without login. Play shows the site login surface when signed out. An authenticated Play visit enters the game without a second login form.

The signed-in banner shows the game username, existing selected game portrait, rank icon/name and progress, Cyllats (currency) and Glimmer (dust). Use existing game assets, supplied logo and website styling. Keep all four account details available at narrow widths; a compact account menu is acceptable. Do not show zero balances while loading or replace real rank with matchmaking Elo. Distinguish loading, offline/retry, expired session and signed-out states.

The site profile surface retains the existing picture picker, ranked record, win streak and rank progress. Save picture changes through the relay and display confirmed state. Continue using the game's portrait collection rather than silently replacing it with a Google avatar. Existing shop/gameplay balance displays may stay where they explain a purchase; remove the duplicate browser profile bar, profile modal, login forms and logout controls from the embedded game.

Keep password login/registration working for existing accounts. Linking Google must preserve the same player row, decks, owned cards, balances, rank and history. Google account name/email are not game usernames and must never cause automatic account merging. Provide an explicit Link Google action for a player already authenticated with their existing account. If that Google identity belongs to another player, refuse without changing either account.

A returning linked Google identity signs into its existing player. A new Google identity chooses an available game username before account creation; show an existing-account/login-and-link route so players do not accidentally abandon progress. Reuse existing username rules. Handle cancellation, taken usernames and concurrent registration without partially creating/linking accounts. Google-only registration must not require a made-up password.

Scope is browser account UI. Preserve existing native/editor password login unless the owner explicitly expands scope. Native Google login, password recovery, email collection, account merging/deletion, provider unlinking, website statistics and game balance changes are excluded.

## Technical shape and contracts

Use the existing static website and relay session model. A new frontend framework, separate identity database or replacement auth platform adds unnecessary migration risk. Implementation may use simpler equivalent internals while preserving the following boundaries.

1. The website owns browser session persistence and account UI. Reuse or migrate cardgame_session safely so existing valid sessions resume. The embedded Web game must not independently race the parent to restore, overwrite or clear that key. Keep native persistence intact. Do not erase or reassign the separate pending-ranked queue.
2. Supply an authenticated relay account snapshot containing stable player identity, username, pfp_id, all visible ladder/record fields, currency, dust and Google-link status. Never expose password hashes, salts, provider tokens or private identities in public statistics APIs. Existing game protocol consumers remain compatible. Correlate new site requests/replies and ignore stale replies after logout/account change; distinguish unauthorized from a transient transport/server failure.
3. The parent establishes its session, installs listeners and mounts the game. A ready handshake transfers only the existing game session token to the child; the child resumes against the relay before gameplay. Use a versioned, small postMessage contract, for example ready, session, account-changed and session-invalid. Both sides check exact origin, expected source window and message shape. Parent messages target the exact origin, never '*'. Do not put tokens in URLs, HTML attributes or logs, or interpolate them into executable JavaScript. Use Godot's JavaScriptBridge with callbacks kept alive for their required lifetime.
4. Rank/economy changes in game notify the parent to refresh from the relay. Child messages are invalidation hints, never authority to grant currency or overwrite rank. Picture changes on the site refresh the game's account presentation/state where needed. A same-account snapshot refresh must not restart an active game.
5. Logout/account replacement first stops and removes the old engine, then changes identity; never swap Auth identity underneath an ongoing match. Otherwise an old match can submit its result as the newly signed-in player. Follow existing disconnect/queue behavior without inventing a new win/loss rule. Invalidate the logged-out token on the relay; if offline, clear local access immediately, report incomplete remote logout and never claim server revocation succeeded. Fence delayed callbacks and storage events across open tabs so an old reply cannot restore a logged-out account. Preserve old-account pending reports for their original account.
6. A raw /play/game.html opened without the supported parent must direct users to /play/ rather than displaying another browser login form. Keep old runtime asset compatibility URLs functional. A bridge timeout or expired token returns a useful site recovery state rather than an indefinite spinner.

Document the exact implemented wire message names, request/reply shapes, errors and bridge lifecycle beside their owners. Avoid a second general-purpose networking framework.

## Google identity and persistence

Use Google's rendered Identity Services button with a browser credential callback and server-side ID-token verification. Configure matching public web client ID and server audience; validate signature, issuer, audience and expiry. Use verified sub as the identity key. Official references: https://developers.google.com/identity/gsi/web/guides/verify-google-id-token and https://developers.google.com/identity/gsi/web/reference/js-reference (checked 2026-10-30).

Bind each Google attempt to a short-lived, single-use server challenge/nonce, connection and purpose (sign in or link); compare the verified token nonce. Linking also requires the current valid game session and explicit user action. Reject unsolicited, replayed, wrong-purpose and conflicting proofs. Restrict new browser Google messages to configured exact site/dev origins without breaking native legacy WebSocket clients. Bound credential size, retries and verification time; keep credentials out of logs and persistence. Never send a Google credential into the game. Logout must not immediately trigger automatic Google re-entry.

Prefer a maintained Google verification library over custom JWT cryptography; obtain any dependency approval required by the receiving environment before adding it. Cache provider keys through the library. Do not accept a client-selected issuer, key endpoint or audience.

The minimum schema can attach one unique Google subject to players. A separate identity table is acceptable if simpler in the actual codebase, but multiple providers are out of scope. Support Google-only accounts by explicitly modeling absent password credentials; reject password login safely for those rows. Preserve old password hashes/salts and prevent accounts with no usable sign-in method. Enforce identity uniqueness transactionally, including two concurrent link/create attempts. Never use a shared placeholder password. Migration must work on a fresh database and a populated existing schema, and be safe to rerun.

No Google client ID has been supplied. The owner must configure a web OAuth client, consent/test-user settings as applicable, and authorized JavaScript origins for the existing Vercel hostname and selected local test origin. This credential callback approach needs no browser client secret. Missing configuration must leave password access functional and Google visibly unavailable, with clear operator setup instructions. Never claim live Google verification based only on a stubbed credential.

## Implementation sequence and acceptance proof

Keep this one end-to-end account migration Task: shipping the UI removal before its replacement works is invalid. Develop in an isolated checkout preserving unowned work. Implement additive relay/schema support first, then site accounts, then the Web bridge/UI removal. Keep old clients working during the transition. Regenerate the Godot Web export using the existing preset before composing the website; stale packed GDScript would hide all bridge changes.

Use existing test owners and the smallest real boundaries:

1. First falsifier: prove a real exported Web game can receive a synthetic account's session from the same-origin parent, resume against a disposable relay/database and reach the authenticated menu. Headless native tests or source assertions do not establish this bridge.
2. Real PostgreSQL migration tests: fresh schema, populated legacy upgrade and repeated initialization. Save/reload existing password credentials, decks, ownership, balances, rank and portrait unchanged. Exercise Google-only account creation, linking conflict/race and transaction rollback through the real relay path.
3. Auth contract tests: legacy password login/resume/logout, snapshot completeness, forged/expired/wrong-audience Google proof, missing/reused nonce, unauthorized linking and duplicate subject rejection. Exercise actual cryptographic verification with test-signed tokens and an isolated key-fetch seam; mocking a verifier to return valid claims is insufficient security proof. No production issuer/key override should be introduced just for tests.
4. Browser integration with synthetic accounts on a fresh task-owned origin: existing stored session restore; login and registration; reload/navigation; profile picture save/reload; game purchase/reward and ranked-result header refresh from server truth; logout and account switch during a running game; delayed callbacks and cross-tab logout; forged-origin/wrong-window bridge messages; relay loss and recovery. Check old reports cannot become another account's reports. Do not read, reset or copy normal browser sessions or real pending queues for QA.
5. Render and interact at wide and narrow widths using the actual site/engine. Verify header visibility, long usernames, large balances, failed pictures, keyboard focus, labeled controls, modal focus/Escape behavior, loading/error messages and readable contrast. Learning links keep the game alive as today. Same-account refresh does not reset gameplay. No duplicate browser login/profile UI remains.
6. Run node --test website/test/site.test.mjs, the focused new relay/account tests plus relevant existing server tests, and the actual Godot Web export/build. Inspect generated changes and source status after commands. Retain meaningful contract/migration/bridge regressions; avoid brittle source-text checks for UI absence.

The real Google consent/sign-in/link flow remains an explicit owner-assisted proof after OAuth configuration: new Google account, existing linked account, explicit linking of a synthetic legacy account, cancellation and logout. State that proof as pending until observed; local test tokens cannot discharge it. No real purchases or player-account mutations are needed.

## Rollout and completion

Update website/README.md and relay setup documentation with configuration, account flows, bridge contract, migration/export commands and test instructions. Keep secrets out of source. Describe rollback honestly: do not drop Google identities or restore NOT NULL password columns over Google-only players. Preserve a compatible relay and usable Google sign-in path if the new game/site release is reverted; reconcile that path before production cutover.

Prepare a reviewed deployment plan: additive relay/schema first, configured OAuth second, then compatible exported game and website. Password access must remain valid throughout. Verify Vercel and Railway target identities and branch contents; publication/production migration requires the receiving session's authorization. Do not overwrite current game/API work merely to deploy the site.

Completion means the implemented site and exported game meet the behaviors above, data-preservation/security tests pass, required source reviews close, and remaining live proof is named accurately. This handoff itself contains planned verification only, not test results or implementation approval.

Spec author: current Codex session. The preferred standalone Claude author host is unavailable because it is not logged in. Required fresh inner and broad outer spec review apply to identity, persistence and site/game cutover. Reviewer verdicts are recorded separately from the portable task body.
