# Patch 0.0.2 additional card buffs

The original eight-card task below is complete. The subsequent user-requested
five-card follow-up at the end supersedes its earlier draft-only exclusions.

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

Web pack: 66,653,744 bytes, SHA256
`09971A47B9818871C55DD625B056A86E8FBB233D38FD92CB7CAC4A1BB2A6E16B`.
Inspected/restored import-only generated defaults. All 19 changed packed scenes
compare identically after normalizing resource/node identifiers; other packed
deltas are the intended JSON and compiled scripts. Existing texture-UID fallback
warnings occurred in both before/after scene dumps; referenced paths and assets
are unchanged. Raw evidence and disposable proofs use private card-buffs-* scratch
files. No new permanent harness; retained tests protect attack-only targeting and
Icewhip sequencing through GameState.execute.

Inner review found a stale greedy readiness guard: Icewhip was skipped on an
empty enemy board despite its guaranteed buff. The correction retains Poke Bear's
enemy requirement and lets Icewhip target a friendly Yeti without enemies. The
existing no-enemy case now selects through greedy AI before execution, so the old
guard fails its buff assertion. Rebuilt the pack, reran source/packed core
(940/0 each) and bot checks (163/0); catalog and Board proof remain valid because
their consumers/data did not change. Rechecked all 19 final packed scenes for
equivalence after identifier normalization. Final raw logs carry the -final suffix.

The final Board proof also starts the drag through `_input()` and checks target
states before dropping. Supply Drop alone enables the existing highlight
helper's optional creature filter, excluding Locations; other effects retain
their prior highlighting. Friendly creatures get the helpful highlight; enemy
and Location targets do not, and both hero styles remain unchanged. All four
drop outcomes still pass. An initial proof assertion incorrectly assumed heroes
had no baseline panel override; comparing their actual pre-drag styles corrected
the oracle. The disposable source is card-buffs-ui-proof-final.gd. Re-exported
without the fixture, verified packed core 940/0, inspected the final inventory
and 19 normalized scenes again; this UI-only delta reuses source core, bot and
catalog evidence. Latest build/proof logs and manifests use the -outer suffix.

## Follow-up: implement the five earlier Orange notes

The user explicitly requested the remaining five changes after asking whether
they had been implemented. On base 92c5032, implemented Duster 2/3, Sweeper 3/2,
Scrap Rummager 1/3 with Rush retained, Morph Drones gaining Rush with its existing
Headshot, and Carbon Mesh giving all friendly Mechs Shielded 2 until the end of
the opponent's next turn. Their mana costs and unrelated fields are unchanged.
The existing draft notes already describe these values. No publication or reset.

Fast follow-up: bounded local card edits using the existing targetless-play,
shield replacement/expiry and Headshot owners; no new schema, wire fields,
serialized state or lifecycle. Required fresh inner and broad after-inner outer
implementation reviews use configured gpt-6.1-sol/xhigh. Codex remains selected.
No formal spec or new harness. The existing shield replacement semantics remain;
this task changes their scope to every friendly Mech and their amount to two.

Carbon Mesh keeps its existing effect key, now marked untargeted. The canonical
PlayerState.can_play_card precondition requires a friendly Mech, so rules, UI and
AI agree before card or mana consumption. AI greedy selection supplies no target.
The same temporary-shield entries and expiry owner handle every affected Mech.
RulesVersion increments to 10 under its card-change rule; app release and public
patch feed remain unchanged. Refreshed all.json, public catalog and Web pack.
Owning game-logic documentation records the availability and fan-out behavior.

Godot 4.7.2, isolated task user data: source and packed `--core-tests` each pass
955 checks. `--bot-tests` passes 163; Node22 `node --test catalog/test/*.test.mjs`
passes 25 with no skips after the 185-card catalog export. Static comparison to
92c5032 confirms exactly five requested Orange edits, unchanged unrelated fields
and matching grouped snapshot. Existing Headshot proof now plays Morph Drones
from hand and attacks immediately; the same proof retains self-destruction and
capped healing checks. One focused command-boundary Carbon Mesh scenario covers
no-friendly-Mech atomic rejection, AI enumeration/greedy use, all-friendly-only
fan-out, real enemy-turn damage reduction, end-of-opponent-turn expiry and clone
isolation. These are distinct durable regressions at their existing owners.

Disposable native Board proof starts dragging through _input: a targetless
empty-space drop with two friendly Mechs reaches real rules and shields both;
without a friendly Mech, the card returns without a command, cost or card loss.
The fixture was removed before export; only private orange-buffs-* source/logs
remain. Export used the existing pinned Web route. Inspected/restored generated
import defaults. Pack has no added/removed entries or temporary fixture; changed
content is expected JSON/compiled scripts plus six regenerated model identifiers.
All 19 decoded scenes remain equivalent after identifier normalization.

Follow-up Web pack: 66,656,016 bytes, SHA256
`FCBA345059649D31504968CA1BF3FB50872882F1C908AEBA2E4E784DBDDEEF18`.
Raw verification logs, UI proof, inventory and scene comparison use the private
orange-buffs-* scratch prefix. No live service or database actions occurred.
