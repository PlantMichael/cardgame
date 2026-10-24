# Agent handoff: Public versioned card catalog

Prepared October 23, 2026.

Repository: https://github.com/PlantMichael/cardgame

Supporting decision: [Public card-data Explore](cardgame-public-data-explore.md).

## Assignment

Build a static, versioned public card-data interface so third-party developers can download printed card statistics and ability descriptions for deck builders, bots, and card browsers. Generate public JSON from the game's existing definitions. Prepare a Railway-compatible static deployment without making catalog availability depend on the account database or multiplayer relay.

The requested deliverable for this conversation is this handoff document; no game code or hosting changes have been made. This document is an implementation brief with proposed defaults, not a claim of an independently reviewed formal spec or authorization to deploy. The receiving agent must follow the repository's applicable implementation/review workflow and resolve material public-contract choices before promotion or publication.

Read the current checkout's instructions, package scripts, card-data documentation, and hosting configuration before editing. Inspect the branch and preserve unowned changes. Do not reset to the historical review revision. Check whether equivalent export or hosting functionality has since landed and reuse it.

## Outcome and boundaries

A developer should be able to:

1. Fetch a small latest manifest over HTTPS.
2. Follow its links to a complete, versioned card catalog and keyword dictionary.
3. Filter/search that catalog locally by ID, color, type, cost, or ability.
4. Pin an older catalog version and continue receiving identical content after a newer release.
5. Use the interface from a browser without an API key or player login.

First delivery includes public printed definitions and readable mechanics metadata. It does not include live query handlers, account data, match history, win rates, ranked statistics, developer registration, GraphQL, artwork hosting, or a new card database/editor. It does not change Godot's gameplay loading or require the game to fetch definitions from this public interface.

Use a generated static catalog, not a new runtime query API. A dedicated Node API remains a later option if consumers demonstrate that need. Railway is the intended deployment preparation target; no paid service creation or live configuration mutation is included without explicit approval of the actual target and spend.

## Source evidence to revalidate

Latest source inspected during Explore: `4747c9159e7e23f8c6f9f5b603a3f44aba7dbd38`.

| Owner | Evidence and implication |
| --- | --- |
| `scripts/cards/card_database.gd:8` | Loads exactly six faction files. Use the same six sources; do not scan backup folders or invent a second manually maintained catalog. |
| `data/cards/{green,black,crimson,orange,teal,generic}.json` | At that revision, 176 entries and about 65 KB of combined source JSON, excluding artwork. No duplicate IDs were found across those six files. Recompute instead of hardcoding those counts. |
| `.docs/card-data.md` and `scripts/cards/card_data.gd` | Definitions and runtime UID/discount/rummage state have different meanings. Export printed definitions only. The current schema includes `LOCATION` as well as `CREATURE` and `STRATAGEM`. |
| `server/relay.js:131-132` | The Node backend already reads the same sibling `data` directory for shop metadata. Reuse source data ownership, not a rarity-only map as the public catalog. |
| `server/relay.js:524-527` | Database initialization precedes WebSocket startup. Do not import this entrypoint into the exporter or static host. |
| `vercel.json` | Existing game-web output is `build`; this is a configured delivery path, not proof that generated JSON is currently published. Do not overwrite or repurpose the Godot export directory accidentally. |

There is no existing exporter, browser/CORS proof, deployed catalog response, or cost benchmark established by the Explore. Do not claim those capabilities are already verified.

## Proposed public contract

Preserve this small interface unless current repository conventions provide an equivalent, simpler form. Confirm material changes with the owner before promising them to consumers.

```text
GET /data/v1/latest.json
GET /data/v1/releases/<catalog-version>/cards.json
GET /data/v1/releases/<catalog-version>/keywords.json
```

No server-side filtering or per-card route is required for version one. Document that callers download once, index by ID, and filter locally. A static query string must not be advertised as an implemented filter.

### Latest manifest

Proposed shape, using illustrative version strings:

```json
{
  "schemaVersion": 1,
  "catalogVersion": "0.1.0",
  "gameVersion": "0.1.0",
  "cardsUrl": "/data/v1/releases/0.1.0/cards.json",
  "keywordsUrl": "/data/v1/releases/0.1.0/keywords.json"
}
```

- `schemaVersion` describes the public data contract, independently of card balance changes.
- `catalogVersion` identifies immutable content. A data correction requires a new catalog version; do not silently replace a published version.
- `gameVersion` identifies the game release the content is intended to describe. Do not invent a production version or equate the current branch with a released game.
- URLs should remain valid when served locally or on the chosen Railway domain. Document how callers resolve root-relative URLs against the origin.
- Use a safe, validated version label that cannot escape output directories. Never derive filesystem paths from unvalidated input.

### Card catalog

Use one envelope with the same version metadata and a `cards` array. Define and document a stable allowlisted projection. A minimum proposed card shape is:

```json
{
  "id": "example_id",
  "name": "Example Creature",
  "color": "GREEN",
  "type": "CREATURE",
  "rarity": "COMMON",
  "manaCost": 2,
  "attack": 3,
  "health": 2,
  "tribe": null,
  "description": "",
  "abilities": [],
  "collectible": true,
  "isToken": false,
  "transformInto": null,
  "transformChoices": []
}
```

This is an example contract, not a real card or an instruction to create one.

- Map existing `card_name`, `card_type`, `cost`, and related definition fields into this projection once. Keep IDs stable across releases.
- Use documented enum strings, including `LOCATION`. Do not reject valid existing zero-cost or zero-attack cards through assumed gameplay limits.
- For stats not applicable to a type, use documented `null` values rather than presenting a spell as a zero-attack creature. Preserve Location health where the current definition provides it.
- Export explicit ability keys and tribe separately. Do not confuse tags inserted by the Godot loader with intrinsic triggered abilities.
- Include transformation references needed to understand published cards. A reference must resolve within the published release or be intentionally absent/null according to the schema; do not leak an unreleased definition merely to repair a dangling reference.
- Do not expose `res://` art paths, runtime UIDs, current health, cost modifiers, rummage counters, private match state, credentials, or other arbitrary source fields. Omit image URLs in version one; image publishing is a later task.
- Do not expose internal executable effect definitions unless there is a documented current consumer requirement. Readable text and stable mechanics references are sufficient for this catalog task.

### Keyword dictionary

Publish stable keyword identifiers and human-readable names/descriptions from the existing owning metadata where available. Inspect `data/keywords.json` and current ability presentation code before choosing the mapping. Parameterized abilities such as `shielded_1` need a documented relationship to their base keyword; a tribe is not automatically a keyword.

Avoid introducing a second hand-edited copy of every rule. If current readable metadata is incomplete, identify the specific gaps and add a small canonical metadata source at the existing owner rather than scraping GDScript with fragile regular expressions. Do not execute the game/account server merely to read metadata.

## Publication scope: explicit release selection

Do not automatically publish everything in a development checkout. Prepare one small release-input manifest containing version metadata and the approved public card IDs or an equally explicit repository-conventional release selection.

- Keep names, stats, descriptions, and abilities in the existing faction JSON. The manifest selects content; it must not duplicate those fields.
- Distinguish public visibility, collectible status, token status, and transformation-form status. `is_token: false` alone is not proof that a card is released or collectible.
- Include public tokens/forms needed by selected public cards, classified appropriately, after checking references. All included IDs must exist in the six canonical sources.
- Create a proposed initial manifest for owner review. Initial public card selection and authoritative `gameVersion` need a recorded owner decision before live publication. Preparing/exporting a candidate locally may proceed while that decision is outstanding.
- Do not infer publication approval from a card being in the previous brainstorming handoffs or in the GitHub repository.

This resolves the mechanism while leaving the consequential release-content decision visible. Do not hold unrelated local implementation work for a deployment or publication approval.

## Minimum implementation shape

Prefer a small standalone exporter using the repository's existing runtime. Node built-ins are sufficient for JSON/file handling and hashing; a new framework or dependency is not required.

Suggested responsibilities, with filenames adaptable to current repository conventions:

1. **Exporter:** read the six files and release manifest; validate; project public fields; write versioned output and latest metadata. Do not import `server/relay.js` or initialize Postgres/WebSockets.
2. **Public release store:** retain approved generated release files independently of transient build cleanup. A small checked-in release-data directory is a reasonable default at this catalog size, unless an existing immutable artifact owner already exists. Do not let a stateless Railway rebuild retain only the newest release by accident.
3. **Static serving package:** serve only the prepared public output, with safe path handling, required headers, and a configured port. Use an established static server or a minimal standalone Node server if appropriate; no account/database startup dependency.
4. **Tests and developer documentation:** exercise generation and real HTTP behavior, and describe release/update/rollback operations.

Do not create extra packages or multiple deployment systems solely to match these responsibility names. Keep source input and generated output directories distinct. Never recursively delete the repository root, `build`, or arbitrary configured paths to clean an export.

### Export correctness and failure behavior

- Validate malformed JSON, duplicate IDs across all six files, invalid required fields, unknown manifest IDs, and unresolved published references. Errors identify the affected file/card and fail with a nonzero exit.
- Validate the whole candidate before changing an existing release or latest manifest. Failed generation must leave the previous usable output unchanged.
- Sort cards and metadata deterministically. Re-exporting the same inputs/version yields identical bytes; avoid a new wall-clock timestamp on every run.
- An existing published version is write-once: identical bytes may be treated as a no-op; differing content under the same version must fail and request a new version label.
- Retain previous releases in the next packaged deployment. Publish complete versioned files before switching latest; do not let latest point at missing or partially uploaded objects.
- Record the source revision through existing release metadata/documentation where useful. A revision is provenance, not a substitute for the game-release version.

## HTTP and Railway preparation

Serve the export as an independent static catalog, not an additional route on the current relay. If repository evidence reveals an existing independent public asset owner that meets the same contract, reuse it and document the smaller approach rather than adding redundant infrastructure.

- Bind the static server to the hosting interface and Railway's injected `PORT`; local startup must also be documented. Require no `DATABASE_URL` or account secrets.
- Use a deployment context that includes both the serving package and prepared public releases. A root set to `server/` cannot automatically read sibling source files at build time; package inputs deliberately.
- Prepare the minimal repository-conventional build/start or Docker configuration. Do not assume the game’s Vercel export is the Railway build output.
- Serve JSON as `application/json` with UTF-8 encoding. Public GET/HEAD responses use `Access-Control-Allow-Origin: *` and no credentialed CORS. Expose ETag to browser callers if clients need to inspect it; support `If-None-Match` requests/preflight where used.
- Proposed cache policy: latest uses `Cache-Control: no-cache` with an ETag so clients revalidate; immutable versioned data uses `Cache-Control: public, max-age=31536000, immutable`. Test the actual static host behavior. On Railway, JSON needs explicit freshness directives for CDN caching.
- Unknown files return a real 404, not the game HTML or a successful fallback. Do not expose directory listings, source directories, configuration, or filesystem traversal targets.
- Provide a simple health check that does not depend on Postgres and verifies the prepared catalog is present. Avoid letting a port-only health check conceal missing release files.
- Keep public read access anonymous. Use platform controls if actual abuse requires rate limiting; do not add a developer-key database to this task.

Railway supports the required HTTP/HTTPS/domain and static hosting capabilities, but the Explore did not inspect a live Railway account or prove this application’s deployment. Do not promise a fixed monthly bill. Prepare configuration and exact operator steps; service creation, domain changes, and production publication require approval for the named target and applicable spending bound.

## Ordered implementation steps

1. Revalidate current source/schema, card metadata, scripts, release conventions, and hosting owners. Identify any existing exporter or tests to reuse.
2. Document the proposed schema and release-selection defaults above. Resolve material conflicts before freezing a public contract.
3. Implement the standalone generator and candidate release manifest. Generate a local release from real current inputs without starting the relay or database.
4. Add deterministic generation and failure-preservation tests at the real exporter boundary.
5. Prepare retained versioned artifacts and static serving/deployment configuration. Verify actual packaged output, not just a development directory.
6. Add a consumer example that fetches latest, resolves its catalog URL, indexes by ID, and filters locally. Handle HTTP errors clearly. It should not need an SDK or Godot.
7. Verify local HTTP/CORS/cache behavior and preservation of a previous release across an update. Finish normal repository review before calling the change ready.
8. Present the exact candidate catalog, release metadata, deployment target, and expected operating costs/limits for publication approval. Keep live checks explicitly outstanding if no deployment is authorized.

## Acceptance and proportional verification

The smallest initial falsifier is a real export of the current six files into a disposable public output followed by consumption of its manifest/catalog. If actual card types, references, or keyword metadata cannot be represented, fix the proposal before building hosting around it.

| Behavior | Required proof |
| --- | --- |
| Public projection is useful and scoped | Run the exporter on current source and controlled fixtures; assert published names/stats/types/classification and the absence of excluded draft IDs/runtime fields. Cover one creature, stratagem, Location, and referenced public form/token when present. |
| Errors preserve the previous release | Run the real exporter against malformed input, a duplicate ID, an unknown manifest ID, or a dangling published reference; verify nonzero failure and unchanged prior output. Share setup where these exercise the same failure boundary. |
| Versions are stable | Same input/version produces the same bytes; changed content under that version fails; a new version can be emitted without deleting the old one. |
| Packaged delivery works | Build the real serving artifact and fetch latest plus its linked files through its actual HTTP server. Assert successful shape/content, expected 404 behavior, and no database prerequisite. |
| Cache behavior | Fetch a versioned file and latest, inspect the actual headers, and send a matching `If-None-Match` to prove 304/no body. Assert an updated latest resolves to the new release. |
| Browser use | From a different local origin, fetch latest and its catalog successfully with anonymous CORS. If the example uses conditional request headers, verify that path too. |
| History survives updates | Package release A, then package release B with retained A; through HTTP, verify latest selects B and A remains retrievable unchanged. |
| Release-selection safety | Excluded records stay unpublished; all exposed transformation links resolve within the approved public set. No raw source-directory fallback bypasses that selection. |

Use current supported commands and record them exactly once known; do not invent pre-existing script names. Lightweight Node scripts may use the built-in test runner if it fits the repository. Reuse equivalent existing proof rather than duplicating the matrix in every layer.

Inspect working-tree status/diffs after any generator or build that can rewrite tracked files. A second passing run after a tool repaired files does not prove the original candidate passed. Keep disposable output separate from retained public release artifacts.

Remaining operator/platform proof: authorized Railway build context, public HTTPS domain, deployed CORS/content-type/cache/ETag behavior, old-version retention on redeployment, and observed resource usage. The implementing agent must name what it proved locally and what remains for an authorized deploy; local tests do not certify Railway settings.

## Documentation and completion

Update the narrow card-data/deployment owner and add a short developer guide covering URLs, schema versus catalog version, field meanings, optional/null fields, collectible/token/form handling, local filtering, caching, and errors. Include one browser/JavaScript example and one command-line fetch example using the actual chosen origin or a clearly labeled placeholder.

Document the release process: prepare manifest, validate/export, retain old files, review public contents, build, publish with approval, switch latest, and roll back latest without rewriting immutable releases. Do not configure automatic public publication from every development commit unless that release policy is explicitly selected.

At handoff completion, report files changed, actual generation/HTTP tests, the candidate version and card counts, preserved old releases, review status, and outstanding release-content or hosting decisions. Do not claim a public API is live unless it was deployed and verified with authorization.

## Reference material

- [Explore and repository evidence](cardgame-public-data-explore.md)
- [Riot Data Dragon](https://developer.riotgames.com/docs/lor#data-dragon)
- [HearthstoneJSON](https://hearthstonejson.com/)
- [Railway static hosting](https://docs.railway.com/guides/static-hosting)
- [Railway public networking](https://docs.railway.com/networking/public-networking)
- [Railway CDN and conditional requests](https://docs.railway.com/networking/cdn)
- [Railway pricing](https://docs.railway.com/pricing)

These references informed the design on October 23, 2026. Recheck platform-specific settings before implementation/deployment; no provider purchase is selected by listing Railway documentation.

---

## Part Two: Game changes

Use this part to collect additional game changes alongside the API implementation handoff. These are separate work items from the static catalog in Part One; the API task's non-goals do not erase the explicitly listed changes here.

### Emergency Extraction

Added October 23, 2026. Add the Generic stratagem below as a separate game-content work item. This section was moved from the faction-card handoff at the project owner's request. Existing faction-card designs remain in their own document. Editing this handoff does not itself implement the card or authorize live publication.

#### Approved card

| Field | Value |
| --- | --- |
| File | `data/cards/generic.json` |
| Name | Emergency Extraction |
| Color | `GENERIC` |
| Type | `STRATAGEM` |
| Rarity | `COMMON` |
| Mana cost | 2 |
| Rules text | Return a friendly creature to your hand. |
| Tribe | None |
| Token | No |

Purpose: provide a utility alternative to Generic's damage and board-clearing stratagems. Recover a creature, free a board slot, or replay an on-play effect at the cost of this card, 2 mana, and the returned creature's subsequent play cost. Do not attach a draw, discount, Rush, heal, or other additional effect.

#### Implementation instructions

1. Check whether the card or a shared return-to-hand operation already exists in the current checkout. Allocate one unused stratagem definition ID under the existing `gen_str_` convention; do not rename existing definitions or create duplicate copies.
2. Select a living friendly creature currently on the acting player's board, subject to applicable targeting rules. Enemy creatures, heroes, and Locations are not legal targets. Validate identity and zone membership before spending mana or consuming the stratagem.
3. Resolve a return-to-hand zone transition through the shared rules core. Remove exactly the selected creature from the board and put exactly its corresponding runtime card instance in the owner's hand. Preserve its identity and supported card history; never modify the shared catalog definition.
4. Returning is not dying, drawing, reinforcing, or Rummaging. Do not fire death abilities, create a Reinforce replacement, grant Rummage discounts, increment rummage history, or trigger Rummage payoffs merely because the creature was returned. Ordinary board-leave/aura reconciliation still applies.
5. Preserve Commander Maurice's remaining Reinforce uses through return, private save/copy, and replay from hand. Extraction must not refill his four returns. More generally, do not reconstruct partial ability budgets from the original definition when replaying the returned instance.
6. Playing the returned card later is a separate normal play: charge its normally applicable mana cost and run its on-play effects then. Extraction itself does not replay them or waive costs. For example, Heavy Bounty Hunter must be played again before its damage effect can trigger.
7. Reuse existing bounce rules for damage, temporary board buffs, silence, transformation, and attached pilots if those rules are already explicit. If no such owner exists, record and resolve those lifecycle choices before declaring the card complete. Do not silently delete or duplicate an attached pilot, arbitrarily undo a transformation, or imply an unapproved healing/reset rule. Maurice's preserved Reinforce budget remains an explicit requirement regardless of the ordinary bounce reset policy.
8. Proposed full-hand default: reject this play before any mutation when the hand has no capacity after the stratagem would be consumed. Account for the slot freed by playing Extraction itself; an initially full hand normally has room for one returned card after that consumption. If the game's established return policy instead burns an overflowed card, identify that conflict and settle the behavior before implementation. A stale target must never consume resources or remove a different creature.
9. Use the same target validation and zone-transition implementation for human play, AI, multiplayer, and headless simulation. Expose the action/choice to those adapters without duplicating its rules. Preserve private hand information in opponent-facing views.
10. Follow the existing missing-art behavior and ownership/catalog rules. Do not add account grants, alter starter decks, or bundle new art generation into this task.

#### Acceptance checks

- The new definition loads once with the exact name, 2-mana cost, Generic color, Common rarity, stratagem type, and rules text. Attack/health are not creature stats for this card; use the current stratagem schema convention.
- A successful play spends 2 mana through the normal resource accounting, consumes Extraction normally, removes only the chosen friendly creature, and adds one corresponding card to hand. The board slot becomes available.
- Enemy, hero, Location, missing, or stale targets are rejected without mutation. Full-hand checks correctly account for the slot freed by consuming Extraction.
- Returning Archive Courier produces no death draw; returning a Reinforce creature produces no replacement or reinforce event; returning a Black creature does not count as Rummaging or change its rummage count.
- A partly used Maurice retains the same remaining return count after extraction and replay. Test a zero-remaining Maurice as well as one with uses left.
- Replaying Supply Quartermaster or Heavy Bounty Hunter charges its normally applicable cost and resolves its normal on-play effect exactly once; Extraction does not trigger that effect itself.
- Aura sources reconcile when removed. Any established pilot, buff, damage, silence, and transformation return policies are exercised at the real zone-transition boundary, including save/copy behavior, without losing or duplicating runtime instances.
- All supported play modes produce equivalent results for the same choices. Opponents receive the permitted hand-count/public zone changes, not newly exposed private hand contents.
- Report actual local verification and remaining rules decisions. The card has not been implemented or balance-tested in this conversation.

#### Count adjustment

Emergency Extraction adds one Generic card if it is not already present. Recount the current catalog before and after implementation; the API work itself adds no card definitions. The separate faction-card handoff retains its original ten-creature batch and counts.

### Whiteout

Add this Teal stratagem as a separate game-content work item in Part Two. The owner selected this design; the other Teal stratagem/creature ideas from the conversation are not included unless separately listed in this handoff.

#### Approved card

| Field | Value |
| --- | --- |
| File | `data/cards/teal.json` |
| Name | Whiteout |
| Color | `TEAL` |
| Type | `STRATAGEM` |
| Mana cost | 5 |
| Rules text | Deal 2 damage to all enemy creatures. If any die from this damage, draw a random Yeti from your deck. |
| Tribe | None |
| Token | No |

Rarity was not selected in the design discussion. Use the project's established rarity convention or record Common as an initial implementation default; do not silently designate this card Legendary.

Purpose: provide a slower, enemy-only alternative to Avalanche that preserves friendly support creatures and can replenish one Yeti when the damage kills an enemy.

#### Implementation instructions

- Check for an existing definition before adding one, and allocate an unused Teal stratagem ID using the current convention. Preserve the approved cost and base damage.
- Resolve one area-damage effect over the enemy creatures eligible under the game's ordinary area-damage rules. Do not damage friendly creatures, heroes, or Locations. Do not apply targeted-spell restrictions indiscriminately to untargeted area damage.
- Use the shared damage operation with the acting player/card as its source. Apply relevant damage modifiers and prevention consistently with other stratagem damage, and follow the common simultaneous-damage/death checkpoints.
- Record whether at least one creature actually dies as a direct result of this damage. Do not use a simple before/after board-size comparison: summons, transformations, and Reinforce replacements can hide a death, while unrelated effects can remove other creatures.
- A kill from a resulting deathrattle or another later effect does not satisfy Whiteout's condition. If Whiteout directly kills several creatures, perform only one Yeti search/draw.
- On a qualifying kill, select a random Yeti card already in the owner's deck using match-owned gameplay randomness, then resolve the canonical filtered draw. Do not generate a new card, summon it directly, or draw a random non-Yeti instead.
- If the deck contains no Yeti, the search does nothing and causes no search-specific fatigue. Respect normal full-hand/burn behavior and preserve the selected runtime card's identity/history.
- Implement the damage, kill attribution, and conditional draw once in the shared core. Human, AI, multiplayer, and headless modes must not each perform their own approximate kill check.

#### Acceptance checks

- The definition loads once with the exact name, 5-mana cost, Teal color, stratagem type, and approved rules text.
- Damage affects only enemy creatures and uses the common damage/prevention rules. Test no enemies, enemies surviving, and an applicable damage modifier.
- A direct Whiteout kill produces exactly one Yeti draw; multiple direct kills still produce one. A direct death followed by Reinforce still qualifies even if board size does not decrease.
- An enemy killed only by a resulting deathrattle does not enable the draw when Whiteout itself killed none. Record deaths by causal effect rather than by a final board snapshot.
- A successful search draws an existing Yeti instance; no eligible Yeti causes no fallback draw or fatigue. Test full-hand behavior and deterministic random selection.
- All supported modes resolve the same scenario consistently. Report actual verification and any unresolved area-damage timing rule; no balance testing has been completed in this conversation.

### Snowdrift Matriarch

Add this Yeti creature to Teal. Only this creature from the latest seven-Yeti brainstorm is selected by this request.

#### Approved card

| Field | Value |
| --- | --- |
| File | `data/cards/teal.json` |
| Name | Snowdrift Matriarch |
| Color | `TEAL` |
| Type | `CREATURE` |
| Mana cost | 5 |
| Attack | 3 |
| Health | 6 |
| Tribe | `yeti` |
| Token | No |
| Rules text | On play: Restore 2 health to each other friendly Yeti. |

Rarity was not selected in the design discussion. Use the project's established rarity convention or record Common as an initial implementation default.

Purpose: recover several damaged Yeti challenge survivors without permanently growing the board or adding another persistent trigger engine.

#### Implementation instructions

- Check for an existing definition and allocate an unused Teal creature ID under the current convention. Use the exact printed 5-mana 3/6 values and Yeti tribe.
- On play, resolve one healing group over other living friendly Yetis. Exclude the Matriarch source, enemies, non-Yetis, heroes, and Locations. Do not open one target picker per recipient.
- Restore up to 2 missing current health per recipient, capped at that creature's existing maximum health. Do not increase maximum health or provide a base benefit to a full-health creature.
- Use the canonical healing/replacement/reaction pipeline. Independent abilities such as Apothecary or Crypt Hunger follow the game's shared rules, rather than Matriarch creating its own ordering. A full-health recipient must not emit a fabricated positive-healing event.
- Snapshot the applicable recipient identities at the defined group-resolution checkpoint and process them through the common resolver. Do not iterate a mutating board in a way that skips or double-heals recipients; if a recipient disappears before its effect can resolve, follow the existing missing-target policy.
- Store Yeti in `tribe`; do not add a second duplicate tribe entry if the loader supplies runtime tags. This card has no intrinsic Guardian, Rush, Challenge, or ongoing healing aura.
- Reuse the same on-play implementation in every play mode and obey existing distinctions between playing and summoning. Do not fire on-play healing solely because a Reinforce return or other summon occurred if normal summon rules do not trigger on-play effects.

#### Acceptance checks

- The definition loads once with the exact name, 5-mana cost, 3 attack, 6 health, Teal color, creature type, and Yeti tribe.
- Two damaged friendly Yetis each restore up to 2 health. A creature missing only 1 health restores only 1; healthy recipients gain nothing from the base effect.
- The source, friendly non-Yetis, enemies, heroes, and Locations receive no base healing. Playing with no other friendly Yetis still completes normally.
- Maximum health is unchanged by the base effect. Applicable health-gain replacements/reactions use the shared semantics, with no fabricated heal on a healthy recipient.
- Group resolution does not skip or repeat recipients when reactions modify the board. Ordinary play and non-play summoning follow their existing trigger rules.
- Human, AI, multiplayer, and headless paths agree. Use existing missing-art and catalog/ownership conventions; do not grant accounts cards or alter starter decks as part of this definition.

### Part Two content summary

Part Two now contains three selected game-content additions: **Emergency Extraction** (Generic stratagem), **Whiteout** (Teal stratagem), and **Snowdrift Matriarch** (Teal Yeti creature). Add only definitions not already present. Relative to the implementation checkout before these changes, the intended delta is one Generic card and two Teal cards, three cards total. Recompute actual counts rather than treating earlier conversational totals as current repository facts.
