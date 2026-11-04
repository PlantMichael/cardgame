# Deck builder visual redesign

Revision 2. Standard task on patch/0.0.2, base 0c3a758. User asks for a large
deck-building redesign matching the rest of the game and explicitly selected
"Collection with deck sidebar": large collection, compact deck list and mana
curve on the right, using the newer dark-blue/cyan main-menu style. Codex remains
the selected author. The earlier review waiver concerned simple balance edits;
this larger interaction/layout change uses required fresh inner and broad
after-inner outer spec/implementation reviews, configured gpt-6.1-sol/xhigh.

## Outcome and boundaries

Redesign the saved-deck hub, faction-selection presentation and editor together.
Use existing space wallpaper, Orbitron headings, main-menu panel/text/accent
colors (main.gd:1037-1092,1547-1574), faction swatches and real CardScene artwork.
Baseline rendered editor has tiny cards across eight upper columns, a short
collection below and a permanently reserved preview pane. Replace it with a
full-height readable collection and a right sidebar with deck name, count,
compact mana-sorted card rows, copy counts, readiness and an eight-bucket mana
curve (0 through 6, then 7+). Use Card.Size.MEDIUM for collection cards. Keep
faction/generic filtering and name/description search; add local mana and type
filters, result/empty states, and contextual card/keyword previews on demand.
Preserve click-to-add, click-a-deck-row-to-remove and existing copy/40-card caps.
At capacity, cards remain readable, additions are disabled and inspection remains
keyboard-accessible through a separate preview affordance.

Keep DeckBuilderScene's path and back_pressed integration. Reuse the existing CardDatabase non-token faction/generic pool and DeckManager
for copy limits and save/load/delete, preserving faction IDs,
card IDs, schema, account ownership, offline files/web storage and incomplete
deck saves. No collection-ownership rules, matchmaking, cards, AI, server or
rules-version changes. Preserve name-keyed save-as behavior: changing a saved
deck's name saves a new copy, clearly label that action and update the editor's
current delete identity after save. Never delete the old copy automatically.
Respect the existing 1–40-character save-name contract after trimming
(relay.js:588-595). Validate before saving, preserve invalid typed text/edits,
and show actionable feedback rather than clipping names silently.
Use the existing optimistic editor snapshot; do not claim server acknowledgement
or introduce synchronization/retry machinery. Blank names refuse saving with
visible feedback and preserved edits. Preserve Back's save/discard/cancel flow,
with keyboard focus confined to the prompt and restored on cancellation.
Delete/Clear retain their current explicit button actions, without new dialogs.
No production push/deployment, data reset or account maintenance is requested.

## Minimum shape and implementation

Follow CardListScreen's programmatic native-container pattern (card_list_screen.gd:
54-104), keeping one layout owner rather than retaining conflicting scene offsets
and dynamic reparenting. Reduce DeckBuilderScreen.tscn to its existing entry root
and script; rebuild its three pages in deck_builder_screen.gd. Retain existing
state/keyword/save owners where valid. No UI framework, service or dependency.
Use native Buttons, LineEdit, OptionButton, ScrollContainer and ProgressBars.
The editor flexes between collection and sidebar, never horizontally clips at
1920x1080,1280x800 or960x640. Hub tiles and faction selection reflow; sidebar and
collection scroll independently. Long deck/card names truncate visibly with full
accessible names/tooltips; no controls move offscreen. Reuse the faction picker
widget with native keyboard-accessible faction actions alongside it if needed.

Preview can be reached by hover or keyboard, includes canonical CardScene and
existing keyword descriptions, stays within viewport and does not consume
permanent editor width. Prefer a native one-shot child Timer for hide timing so
screen destruction cancels it; no custom retry/generation lifecycle. All controls
have visible focus and accessible names; keyboard can add/remove/preview/save,
navigate filters and complete/cancel the unsaved prompt. Escape dismisses preview
or prompt before navigating away; Ctrl+F and Ctrl+S may reuse search/save actions.

## Verification and delivery

First falsifier is the actual native Board-sized UI: render a full 40-card editor
and hostile long names at wide/narrow sizes, inspect screenshots and exercise
real controls before broadening. Reuse existing CardScene and DeckManager proof;
add one focused UI fixture/test in server/test using the existing Godot/Node
fixture pattern. Exercise actual mouse/keyboard dispatch: faction creation,
search/filter results including no results/reset, add up to copy/cap limits,
remove a row, mana curve/count synchronization, preview at capacity, blank-name
and 41-character rejection with preserved edits, accepted 40-character names,
and save/discard/cancel with focus containment. Save, reload and delete
through actual DeckManager offline files in an exclusively task-owned APPDATA
directory using synthetic decks; prove save-as preserves the old copy and delete
targets the current copy. No real accounts or production calls. Exit during
preview hide timing must not create errors or lingering controls.

Keep fixture breadth bounded to this view and existing production owners; do not
duplicate deck legality or persistence in a harness. Source core and existing
card-inspect checks protect adjacent consumers; rebuild Web pack and run the
focused UI fixture from it. Capture wide/narrow editor, populated/empty hub and
faction page, plus relevant focus/full/empty states, using the native renderer.
Do not substitute a resting screenshot for interaction or save/reload proof.
Inspect generated exports/imports, preserve earlier patch changes and stop once
the affected checks pass. Update owning architecture/conventions/card-size
comments and add the redesign to the unreleased draft notes. Commit before review.
Store raw captures privately; present useful before/after previews as deliverables.

## Delivered behavior and verification

Revision 2 completed its fresh inner and blind outer spec gates before execution.
Implementation uses the existing native-container/CardScene/DeckManager owners;
no new persistence, backend, dependency or rules-version surface. The native
scene entry and back signal remain unchanged. Saved-name changes preserve the
old deck and update the current delete identity; snapshots remain optimistic.

The focused UI fixture ships because it protects the redesigned view's real
mouse/keyboard controls, copy/cap limits, combined filters, full-deck inspection,
curve synchronization, name validation and offline save/reload/delete lifecycle.
It uses actual DeckManager files in fresh synthetic user storage, with no account
or production traffic. Native captures are one-off visual proof rather than
screenshot assertions. Exit-during-preview proof caught a timer start after tree
removal; the callback now checks its child Timer's tree membership.

Godot 4.7.2 source core: 971 checks, zero failures. Source Node UI and adjacent
card-inspect checks: 2 passing, no skips. After the added hover/keyboard cases,
focused source UI passed again. The Web release export exited 0; final packed
UI and card-inspect checks passed 2/2 with no skips or runtime errors. Commands:
`Godot --headless --path . -- --core-tests`,
`node --test server/test/deck_builder.test.js server/test/card_inspect.test.js`,
`Godot --headless --path . --export-release Web build/index.html`, and the same
Node checks with `GODOT_PACK=build/index.pck` and pinned `GODOT_BIN`.

Native OpenGL fixture also passed with failures=[], including mouse hover,
keyboard actions, saved-file reload, prompt focus containment and teardown.
Inspected full editor at 1920x1080/1280x800/960x640, empty/populated hub, faction
page at wide/narrow sizes, no results, invalid name, preview and focused prompt.
Long names truncate in tiles and scroll in the editable field. Native captures
and logs remain private under the deck-builder/deck-ui scratch prefixes.

Final initial-candidate pack: 66,669,364 bytes, SHA256
`83DCC895FA5B25547EC39CAB424FAFBD0CE7D2B2471B32FBC63F49088D5E4078`.
Reviewed/restored exporter-only import defaults. Export logs retain the same
pre-existing unused ThickCard MTL and two import-MD5 warnings as the preceding
Ambusher export; UI runtime logs are clean. No temporary baseline scene or
scratch resource is in the pack. Documentation/card-size guidance and unreleased
0.0.2 notes describe the redesign. No push, deployment or data reset performed.

User follow-up removes the top-right tagline. Historical saved decks containing
retired IDs now show an unavailable-card row, preserve those IDs on save and let
the player explicitly remove them. Known cards and their curve still render;
readiness says Check cards while an unavailable ID remains. Name validation uses
the relay's UTF-16-unit count; native input/save/reload proves 20 supplementary
characters accepted, 21 refused with typed text and dirty state preserved.

Focused source and native UI fixtures pass after these changes; refreshed native
captures show the tagline removed and retired-card state at 960x640. Rebuilt Web
pack exits0 and the updated packed UI fixture passes1/1, no skips/runtime errors.
The adjacent card-inspect and core evidence remains causally valid. Import-default
churn was inspected/restored; export retains unused-resource/import-MD5 diagnostics
(three MD5 messages this run) but no UI script/runtime errors. Final correction
pack is 66,670,676 bytes, SHA256
`F8EAEAD14AC3EECDAFCD8F778612C3D98FAAB9056712842741816D12787D9AC2`.
Private logs use deck-ui-packed-corrections and deck-ui-export-corrections; native
captures/logs retain the deck-builder/deck-ui prefixes. `git diff --check` passes.

Name normalization now matches the relay's ECMAScript trim whitespace set, used
consistently by validation, save-as labels and dirty comparisons. The set was
checked against the local Node22 String.trim producer, including U+00A0/U+FEFF.
Real UI tests reject a nonbreaking-space-only name without losing typed text or
cards, save 40 characters plus trailing NBSP under the canonical 40-character
name, and keep dirty/save-as comparisons canonical with NBSP on both ends.
Source focused UI1/1 and native full fixture exit0 with clean stderr. Logs:
deck-ui-source-whitespace.log and deck-ui-native-whitespace*.log.

The first export attempt inherited the synthetic APPDATA used by the native test
and failed because its export-template directory was empty; it did not update the
pack. The subsequent green check on that old pack was not used as evidence for
this correction. Rebuilt in the normal installed-template environment: export0,
updated packed UI1/1 with no skips/errors (deck-ui-export-whitespace-final.log,
deck-ui-packed-whitespace-final.log). Import-default churn inspected/restored;
existing unused-resource diagnostics remain. Final pack is 66,671,604 bytes,
SHA256 `07468D80AFC1B33BFBFE5886F6DD7C6B7387A9664B053E5621BC7E7EF667489D`.
Earlier core/adjacent-consumer proof is reused because their source and behavior
are unchanged; the baseline core raw log is ambusher-core.log. Current initial-UI
core output also reported 971/0 in the tool result rather than a retained log.
