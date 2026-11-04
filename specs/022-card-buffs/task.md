# Patch 0.0.2 additional card buffs

Revision 2. Standard implementation selected by the user's eight-card request.
Worktree: existing patch/0.0.2 checkout, integrating current master 6c6d937
with the existing notes-only draft a2f24b5. No production release or reset.

## Scope and acceptance

Implement Panic Button 1 mana; Snow Bank 2; Kevlar +0/+4 at its existing
2 mana; Lone Operative 2/1 at 1 mana with Ambush; Supply Drop +3/+0 for
2 mana; Icewhip "Give a Yeti you control +2/+2 and make it Challenge."
at its existing 2 mana; Junior Pilot 1 mana; Nanotech 2 mana.
The user delegated Lone Operative's stat choice; +1 attack preserves its fragile
Ambush identity. All other properties stay unchanged. Preserve the five older
Orange buffs in the draft notes; implementing those notes-only selections is
outside this additional eight-card task.

Supply Drop targets a friendly creature, never a hero, enemy or Location, and
changes attack only. Invalid commands consume neither mana nor the card.
Human targeting metadata, server validation and both AI action enumeration and
greedy targeting must agree. Existing permissive behavior of other buff effects
is not broadened into this task.

Icewhip gives both stats before the enemy Challenge choice, using the existing
health-gain owner and its reactions. The buff remains if there is no eligible
enemy or the player declines combat. A winning Challenge gives no second buff;
other win-buff Challenge cards retain their bonus. Keep existing friendly-Yeti
validation and enemy Challenge eligibility. No new choice or combat subsystem.

## Grounding and shape

Card definitions live in data/cards/{green,orange,teal}.json; all.json is the
grouped snapshot (.docs/card-data.md:123). Supply Drop currently uses the
symmetric buff_creature effect (game_state.gd:1671), so add the smallest generic
buff_attack counterpart rather than a card-ID exception or a larger buff schema.
CardData target predicates (card_data.gd:114-124), shared command validation
(game_state.gd:1317), and HeadlessTurn's enumerator/greedy target picker
(headless_turn.gd:265,364) own its consumers. Only Icewhip uses force_challenge
in card data; change that effect to pre-buff with gain_max_health
(game_state.gd:1248), then request CHOICE_CHALLENGE with zero win bonus
(game_state.gd:1769). The existing resolver also serves creature win bonuses
(game_state.gd:724), so preserve those semantics.

Bump RulesVersion 8 to 9 under its documented card-change rule. Keep application
release 0.0.1 and published patch-notes feed unchanged until release is requested.
Refresh source snapshots/catalog and the existing Web pack so the patch branch
is internally consistent, without publishing to master or deploying services.
Update owning game-logic docs and draft PATCH_NOTES.md only as needed.

## Proof and review

Extend existing CoreTests at the command boundary. First falsifier: execute
Supply Drop on a wounded friendly creature and observe +3 attack with identical
current/max health. Cover invalid target atomicity and AI legal/greedy use once.
Revise the existing Icewhip scenario to prove pre-combat stats and no duplicate
win bonus; add non-winning combat and no-enemy buff retention. Existing Challenge
family coverage protects unchanged win-buff creatures and hidden enemies.
Use one disposable catalog/source check for eight static edits rather than
permanent assertions freezing balance numbers. Run core tests and existing bot
tests, catalog export/tests, then packed core proof with the pinned Godot route.
Add buff_attack to Board's friendly highlight and Location-exclusion paths.
Use disposable real Board interaction proof: drop Supply Drop on a friendly
creature successfully; enemy, hero and Location drops return the card without
spending mana. Reuse the existing layout; no new UI or screenshot pass.
Inspect generated changes and preserve unrelated imports. No live statistics,
database or provider proof is required for this unreleased change.

Required fresh inner and broad after-inner outer spec/implementation reviews use
configured gpt-6.1-sol/xhigh. Codex author override remains authorized. Commit
implementation before review; no force operations or unrelated changes.

## Execution evidence

Revision 2 passed fresh inner and blind outer spec review. Implemented the eight
edits, attack-only target/effect consumers and pre-combat Icewhip buff. The older
five Orange changes remain draft notes only. RulesVersion is 9; application
version and published patch feed remain unchanged. No deployment or reset.

Windows Godot 4.7.2 with isolated task user data: source and rebuilt-pack
`--core-tests` each passed 940 checks; `--bot-tests` passed all 163 checks.
`node --test catalog/test/*.test.mjs` passed 25 tests with no skips after the
185-card export. Disposable comparison against c6a349a verified exactly eight
source card edits, all other fields preserved, and grouped snapshot agreement.
Real Board drag/drop proof passed friendly success and enemy/hero/Location
rejection with card and mana preservation. The initial headless proof could not
move the dummy display's pointer; native Windows execution with viewport mouse
warping exercised the actual drop path successfully. The disposable fixture was
removed from source before export and is absent from the pack inventory.

Web pack: 66,653,856 bytes, SHA256
`EFCD3D2CD3FBD4A5A51B8BCB997279ED1F036B190CC34304A4F679148E131FEF`.
Inspected/restored import-only generated defaults. All 19 changed packed scenes
compare identically after normalizing resource/node identifiers; other packed
deltas are the intended JSON and compiled scripts. Existing texture-UID fallback
warnings occurred in both before/after scene dumps; referenced paths and assets
are unchanged. Raw evidence and disposable proofs use private card-buffs-* scratch
files. No new permanent harness; retained tests protect attack-only targeting and
Icewhip sequencing through GameState.execute. Implementation reviews pending.
