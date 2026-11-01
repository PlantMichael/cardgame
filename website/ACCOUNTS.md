# Site accounts and Google sign-in

Browser login, registration, logout and the profile live on the website. The embedded game takes its account from the page. Native/editor builds keep their password login screen.

## What lives where

| Piece | Owner |
|---|---|
| Browser session (`localStorage` key `cardgame_session`, `{token, username}`) | `website/account.js`. The embedded game never reads, writes or clears it. |
| Account truth (rank, balances, portrait, Google link) | The relay and PostgreSQL. The page only displays it. |
| Banner, login/register dialogs, `/account/` profile, Google button | `website/account.js`, `website/pages.mjs`, `website/style.css` |
| Game side of the hand-off | `scripts/game/site_bridge.gd` (+ `auth.gd`, `main.gd`) |
| Google verification, challenges, link/register | `server/google_auth.js` |
| Account snapshot, schema | `server/relay.js`, `server/schema_legacy.js` |

## Relay messages added for the site

All JSON over the existing relay websocket (see the header of `server/google_auth.js` for the Google ones).

- `get_account_snapshot {token, request_id}` -> `account_snapshot_result {request_id, success, account}` or `{success:false, unauthorized:true}` (token unknown, expired or logged out) or `{success:false, unauthorized:false}` (server trouble: the page keeps what it has and offers a retry). `account` carries `player_id, username, pfp_id, wins, losses, rank_*, ranked_*, currency, dust, google_linked, has_password`. It never carries password material, a Google subject, or the hidden matchmaking rating. `resume_session` now also returns `pfp_id` (it used to omit it).
- `google_config`, `google_challenge`, `google_signin`, `google_register`, `google_link` (and their `*_result`).

The old messages (`register`, `login`, `resume_session`, `logout`, ...) are unchanged, so native clients and old web builds keep working.

## Page <-> game bridge (version 1)

Same origin, exact window checks, no token in URLs or logs.

| Direction | Message | Meaning |
|---|---|---|
| game -> page | `{cg:1, type:'ready'}` | The game is up and wants a session. Re-sent on retry. |
| game -> page | `{cg:1, type:'account-dirty'}` | A ranked result or balance change happened; re-read from the server. A hint only. |
| game -> page | `{cg:1, type:'session-invalid'}` | The page's token no longer resumes. |
| page -> game | `{cg:1, type:'session', token}` | Sent only to the iframe's own window, to this origin, in answer to its `ready`. |
| page -> game | `{cg:1, type:'account-changed', pfp_id}` | The portrait changed on the site. |

The page accepts messages only when `event.origin === location.origin` and `event.source` is the game iframe. The game does the mirror check in JavaScript before Godot sees anything, queues messages in `window.__cgBridge.inbox` and polls it (no callbacks to keep alive). `Net` uses the relay named by the page's `<meta name="cg-relay">`, so a test or staging site and its game share a relay.

Account change or logout removes the game iframe first (stopping the engine), then changes identity, so an old match can never report as a new account. Pending ranked reports stay under their original username in `cardgame_pending_ranked` and are untouched.

A raw `/play/game.html` with no parent page shows "Sign in and play from the website" and a button to `/play/`. If the page does not answer within 10 seconds the game offers a retry; if the game does not start within 25 seconds the page offers one.

## Google sign-in: operator setup

Nothing is configured yet, so Google shows as unavailable and password login is unaffected.

1. In Google Cloud, create an OAuth client of type **Web application**. Add **Authorized JavaScript origins**: `https://cardgame-xi-orpin.vercel.app` (and any custom domain or local test origin such as `http://localhost:8943`). No client secret and no redirect URI are used. Configure the consent screen (add test users while it is in testing).
2. On the **relay** service set `GOOGLE_CLIENT_ID` (the client ID) and `SITE_ORIGINS` (comma-separated exact origins from step 1, e.g. `https://cardgame-xi-orpin.vercel.app,http://localhost:8943`). Restart. Both are required; if either is missing Google stays off and the relay logs why.
3. Only browser pages from `SITE_ORIGINS` can use Google messages (checked against the websocket `Origin`). Native clients send no origin and cannot.

How it works: the page asks for a single-use challenge (bound to the connection and to `signin` or `link`), gives Google its nonce, and sends the signed ID token back. The relay checks signature, issuer, audience and expiry with `google-auth-library`, requires the token's nonce to match the challenge, and uses only the verified `sub`. Nothing from the Google profile (name, e-mail, picture) is stored, and the credential is never logged or sent into the game. A new Google identity must choose a game username (with an "I already have an account" route); linking requires being signed in and an explicit click, and an identity already on another player is refused without changing either account. Unlinking and merging are out of scope.

## Database

`schema_legacy.js` is additive and safe to rerun: `players.google_sub` (unique), `players.google_linked_at`, and `password_hash`/`salt` become nullable with a CHECK that every player has a password or a Google identity. Existing hashes, balances, decks, ownership and ranks are untouched (tested against a populated legacy schema).

**Rollback.** The migration is not reversed. Do not drop `google_sub` or restore `NOT NULL` on the password columns once any Google-only player exists; they would have no way to sign in. Older relay builds keep working with the new schema for password accounts (they ignore the new columns), but a Google-only player cannot sign in on an old relay, so keep the new relay deployed if the site/game release is reverted.

## Build, run, test

```sh
# export the game first (stale packed GDScript would hide bridge changes)
godot --headless --path . --export-release Web build/index.html
CARDGAME_RELAY_URL=ws://127.0.0.1:8781 node website/build.mjs   # default: wss://cardgame-relay-production.up.railway.app
node website/preview.mjs
node --test website/test/site.test.mjs
cd server && DATABASE_URL=<disposable db> node --test test/site_account.test.js test/google_auth.test.js
python website/tools/make-thumbs.py   # only to regenerate website/assets/* from the game art
```

## Verified, and what is not

Verified: schema migration (fresh, populated, repeated); snapshot contents and `unauthorized` vs failure; Google proofs through the real `google-auth-library` verifier with throwaway-key signed tokens served over its own key-fetch path (wrong audience/issuer, expired, over-long, unknown/forged signature, `alg=none`, tampering, missing/wrong/replayed nonce, wrong connection, wrong purpose, oversized, rate limit); account creation, linking, conflict and concurrent-race behaviour against PostgreSQL; and, in a real browser against a local relay and the exported game: registration, login, reload restore, the game resuming the page's session and reaching the menu with no in-game login/profile bar, balance and rank refresh after an `account-dirty` hint, a forged same-window message being ignored, an invalid session being cleared by the page, logout removing the engine and the stored session, the raw game page redirect message, and portrait save.

**Not yet verified:** Google's real consent screen, real Google signing keys and a real sign-in/link/cancel (needs the OAuth client above); cross-tab logout and account switching during a running match beyond the storage-event code path; relay loss and recovery mid-session; the narrow-width layout beyond a manual look; keyboard/focus review of the dialogs beyond the native `<dialog>` behaviour. These remain owner-assisted checks.
