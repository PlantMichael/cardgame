# Stop callbacks into freed web UI

User reports the deployed Firefox game freezes about ten seconds after an update; clearing the game's browser cache temporarily fixes it. Their console screenshot shows freed GDScript lambda captures followed by a WebAssembly "indirect call to null" trap. Base `dcbac61`, branch `codex/fix-web-connection-freeze`.

## Diagnosis and boundary

The public Vercel HTML/JS/PCK/WASM ETags match local MD5s, their browser cache headers require revalidation, and the current export has PWA disabled/no service worker. Existing history already tried cache headers and removing COOP/COEP. Do not add another cache workaround without causal evidence.

`main.gd:1621` uses a captured Boolean `fired` for connection success versus an eight-second timeout. GDScript captures scalar locals by value, so the success lambda cannot update the timeout lambda's copy. A disposable Godot 4.7.2 scene ran the exact function extracted from production with a local signal producer (no network), freed its ready-screen label, then waited nine seconds: it reproduced the same freed-capture error and invoked BOTH callbacks (`ready:1, timeout:1`, exit1). Output retained in ignored `.godot/web-freeze-probe/before.log`. This proves the callback defect; the exact Firefox WASM trap still needs a browser reproduction.

Related auth loading indicators repeat the captured-Boolean error. Auth result handlers and `_currency_cell` subscribe to persistent autoload signals while capturing disposable controls; their subscriptions need the same screen-lifetime boundary. Keep the change limited to these connected paths, not all UI/gameplay callbacks.

## Selected correction

- Give each pending connection a small Node owner, parented to the relevant UI screen (or canvas for the plain multiplayer call). Use named connection/timer methods and explicit terminal cleanup; exactly one of ready/timeout runs, successful connection stops its timer, timeout disconnects late success, and leaving the screen silently cancels/relinquishes callbacks. Preserve immediate-ready and the existing no-timeout-callback behavior. This lifecycle owner avoids nested mutable closure state, stale captured controls and reference cycles.
- Scope Auth login/register/resume result subscriptions and currency updates to their existing UI owner, disconnecting on tree exit before captured controls are freed. Use one small owner-binding helper shared by these real consumers; do not rewrite auth or economy protocols/state. Replace loading animation stop flags with shared reference state so terminal updates actually stop the animation.
- Preserve UI layout, copy, account/session storage, relay protocol, ranked outcomes and cache config. No clearing user data, new dependencies, browser preference changes or engine upgrade. Re-export Web with the existing matching Godot 4.7.2 preset/templates so the fix ships in PCK.

## Proof and delivery

Use a focused Godot scene fixture with the real connection owner/timer and real Main screen/subscription helpers, local signals and synthetic outcomes only. Prove success-before-deadline after UI disposal, timeout followed by late success, cancellation/retry, immediate readiness, loading stops at failure, and repeated screen/currency refresh after owner teardown. Check no freed-capture/runtime errors, not merely exit status. Drive it through existing Node test conventions and `GODOT_BIN`; no production login or ranked-game submissions. Run the rules-core guard if Main/controller changes require it; no broad database suites for unchanged server code.

Firefox is installed; initial detached probes could not retain a listener. A foreground-owned isolated headless Firefox 159 probe successfully opened its BiDi listener; use it for console/network and fresh/warm startup when practical, preserving the normal user profile. Chromium fresh/warm public login page showed no console error; it does not establish Firefox behavior. Finish a local exported-browser smoke and check the eight-second window. If the exact hosted Firefox reproduction requires the user's saved session or GPU, report that residual honestly rather than claiming the cache symptom fully proven.

Update `.docs/status.md` and `.docs/conventions.md` (the captured-scalar/persistent-UI pattern repeats in multiple functions), plus this evidence owner. Formal spec and implementation use fresh inner/outer reviews under configured `codex/gpt-6.1-sol` xhigh/broad after-inner policy. Current Codex authors because standalone configured Claude is unavailable. No push/merge authority is inferred from the earlier, unrelated API publication; complete the fix/export/review locally before a concrete publication request. No production deployment by the agent.

## Implementation and verification

Delivered a screen-owned `connection_wait.gd` with named completion/timeout methods, terminal timer/signal cleanup and silent exit cancellation. Main scopes auth/currency subscriptions to their controls and uses separate reference-state tokens for connecting and authenticating animations. UI layout, account data, wire protocol, server and cache configuration are unchanged.

On Windows, Node 22.23.2 and existing Godot 4.7.2:

- `GODOT_BIN=<existing 4.7.2 console binary> node --test server/test/web_connection_client.test.js`: 1 test passed, no skips or runtime errors. It drives production wait ownership and Main's actual auth/reconnect/currency controls with local signals; no relay connection or account mutation. Synthetic currency changes are in memory and restored.
- `godot --headless --path . -- --core-tests`: 707 checks, zero failed, `RESULT: PASS` (`.godot/web-freeze-probe/core.log`). No broader DB tests selected: no server/data-path change.
- `godot --headless --path . --export-release Web build/index.html`: succeeded using existing matching templates; HTML pack size updated and PCK rebuilt. Export rewrote 241 tracked import sidecars with tool defaults; inspected and restored that generated noise. `project.godot` restored byte-for-byte after a separate disposable fixture export. All 437 current PCK entry checksums validated; base had 431. Pack delta is Main, new owner/fixture resources and UID cache, plus six regenerated GLB imports (`pack-diff.log`). JS/WASM unchanged.
- Isolated headless Firefox 159.0 / WebGL2: production Web export reached login with no error in cold/warm phases and remained alive through four five-second observations after navigation (`firefox-after.log`). A first attempt to select the fixture through release CLI args failed because path overrides are disabled in the standard release template; this is a harness limitation, not a game failure. A disposable export changing only the main scene to the fixture then passed in the same release WASM: `WEB_CONNECTION_RESULT {"calls":{"ready":3,"timeout":1},"failures":[]}`, no runtime errors, beyond eight seconds (`firefox-fixture.log`). This test does not alter the shipped export's main scene.

Raw evidence and disposable probes remain ignored under `.godot/web-freeze-probe/` while review is open. Exact hosted Firefox freeze/cache correlation remains operator proof: publish the reviewed export, open an existing affected saved session without clearing its cache, and use menus for more than ten seconds while watching console errors. No live login, match recording, publication or deployment was performed.
