# Quests

Daily and weekly quest definitions live in `data/quests.json` — a flat array of
quest objects, same shape as `data/campaign_modifiers.json` and
`data/shop_packs.json`. This file is the **pool** every quest is rolled from,
not the player's active quest list.

> **Status:** the pool exists and is documented here, but nothing loads it yet.
> There is no `QuestManager` autoload, no progress tracking, and no quest UI —
> see "Not built yet" at the bottom.

## Intended shape (from the reference UI)

- **3 daily quest slots**, refreshed on a daily boundary. An empty slot reads
  "No Quest Available" rather than being hidden.
- **1 weekly quest slot** below them, refreshed on a weekly boundary.
- Each row shows a progress ring (`current / goal`), the quest `name`, and its
  reward on the right.

Slot counts are a game rule, not data — they belong in the loader's constants,
not in `quests.json`.

## Quest Fields

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | String | yes | Unique, snake_case, prefixed `daily_` / `weekly_`. This is what a player's saved progress keys off, so **never reuse or renumber an id** — retire one instead. |
| `pool` | String | yes | `"daily"` or `"weekly"`. Which slot set this quest can roll into. |
| `name` | String | yes | The line rendered on the quest row, e.g. `"Play 3 Versus AI games"`. Phrase it as the objective, not a flavor title. |
| `description` | String | yes | Longer explainer for a hover tooltip. Spell out anything ambiguous (does a loss count? do generic cards count?). |
| `track` | String | yes | Which counter this quest watches — see **Track Keys**. |
| `goal` | int | yes | Value of the tracked counter that completes the quest. |
| `accumulate` | String | no | `"total"` (default) sums the counter across every match. `"best_in_match"` takes the largest single-match value instead — use it for "win with 25+ health left", never for "deal 40 damage total". |
| `filters` | Dictionary | no | Narrows which events count — see **Filters**. Omit entirely to count everything. |
| `reward` | Dictionary | yes | `{"currency": "glimmer" \| "cyllats", "amount": int}`. |
| `weight` | int | no | Relative roll chance within its pool (default 10). Higher = more common. Give hard or novelty quests a lower weight. |

## Track Keys

| `track` | Counts | Notes |
|---|---|---|
| `games_played` | Completed matches | Wins and losses both count. |
| `games_won` | Matches won | |
| `cards_played` | Cards played from hand | Use `filters` to narrow by type, color, rarity, or cost. |
| `creatures_destroyed` | Enemy creatures destroyed | Any cause — combat, challenge, stratagem, deathrattle. |
| `damage_to_hero` | Damage dealt to enemy heroes | |
| `hero_health_remaining` | Your hero health at match end | Only meaningful with `"accumulate": "best_in_match"`. |

Adding a new `track` key means adding the counter that feeds it, so keep this
table and the loader in step.

## Filters

Every key is optional; omitting one means "no restriction on that axis". A key
whose value is an array passes if the event matches **any** entry.

| Key | Type | Values |
|---|---|---|
| `mode` | Array[String] | `"vs_ai"`, `"ranked"`, `"multiplayer"`, `"campaign"` |
| `card_type` | Array[String] | `"CREATURE"`, `"STRATAGEM"`, `"LOCATION"` (`CardData.CardType`) |
| `color` | Array[String] | `"GREEN"`, `"CRIMSON"`, `"BLACK"`, `"ORANGE"`, `"TEAL"`, `"GENERIC"` (`CardData.CardColor`) |
| `rarity` | Array[String] | `"COMMON"`, `"RARE"`, `"EPIC"`, `"LEGENDARY"` (`CardData.CardRarity`) |
| `tribe` | Array[String] | `"yeti"`, `"mech"`, `"tank"`, `"sprite"`, `"monstrosity"` (`Abilities.TRIBES`) |
| `min_cost` / `max_cost` | int | Inclusive bounds on `CardData.effective_cost()` |
| `result` | String | `"win"` or `"loss"` — only count events from matches with that outcome |

## Currencies & Reward Sizing

The two currencies are **Glimmer** (`Economy.dust`) and **Cyllats**
(`Economy.currency`). `server/relay.js` still calls them `dust` and `currency`
internally.

Following the split `relay.js`'s `claim_earn_reward` already uses — Glimmer for
day-to-day play, Cyllats for milestones — **dailies pay Glimmer and weeklies pay
Cyllats**.

For scale: crafting costs 40 / 100 / 400 / 1600 Glimmer by rarity
(`CRAFT_COST_BY_RARITY`), and a Standard Pack costs 100 Cyllats
(`data/shop_packs.json`). So the sample values are:

| Tier | Reward |
|---|---|
| Easy daily | 50 Glimmer (≈ one Common craft) |
| Normal daily | 75 Glimmer |
| Hard daily | 100 Glimmer (three dailies ≈ one Rare craft) |
| Weekly | 200–250 Cyllats (2–2½ packs) |

## Example

```json
{
	"id": "daily_play_vs_ai_3",
	"pool": "daily",
	"name": "Play 3 Versus AI games",
	"description": "Finish 3 matches against the AI. Wins and losses both count.",
	"track": "games_played",
	"goal": 3,
	"filters": {
		"mode": ["vs_ai"]
	},
	"reward": {
		"currency": "glimmer",
		"amount": 50
	},
	"weight": 12
}
```

## Adding a Quest

1. Add an entry to `data/quests.json` with a fresh `id`.
2. If it needs a counter that isn't in **Track Keys**, add the `track` key here
	 first, then wire the counter that feeds it.
3. Set `weight` relative to its difficulty — rare/hard quests get a lower one.
4. Keep the file valid JSON (tabs for indentation, no trailing commas).

## Not built yet

Everything below is design intent, not implemented:

- A `QuestManager` autoload to load the pool, roll slots, and expose progress.
- Per-account quest progress. It has to be **server-authoritative** like
	`Economy` and the ranked ladder are — a client-side counter is trivially
	forged, and quests pay real currency. That means new `relay.js` tables and
	message types, plus daily/weekly reset timestamps on the account.
- Counters feeding the track keys, emitted from `GameState`/`GameManagerAutoload`.
- The quest panel UI and its main-menu entry point.
