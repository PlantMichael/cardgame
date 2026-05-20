Keep `.docs/*.md` in sync with the actual GDScript source code in this project.

Each doc file has a specific source of truth in the codebase. If the code has changed but the doc has not, update the doc to match the code — not the other way around.

| Doc | Source of truth |
|---|---|
| `.docs/status.md` | Read all `.gd` files; determine what is actually implemented vs missing. Update "What's Working" and "TODO" sections based on evidence in code, not assumptions. |
| `.docs/architecture.md` | Read `scripts/` file tree. Verify every file listed in the table and file-structure block still exists at that path. Update autoloads table from `project.godot` if accessible, or from `class_name` declarations and `@tool` annotations in scripts. |
| `.docs/game-logic.md` | Read `scripts/game/minion.gd`, `player_state.gd`, `game_state.gd`. Update every public function signature, exported property, and signal listed in the doc to match the actual code. |
| `.docs/abilities.md` | Read `scripts/game/abilities.gd`. Update the constants list and any death-trigger / on-play logic described in the doc. |
| `.docs/ai.md` | Read `scripts/game/ai_controller.gd`. Update the decision-priority list and any behavioral notes. |
| `.docs/card-data.md` | Read `scripts/cards/card_data.gd` and one JSON file from `data/cards/`. Update the schema table and JSON format example. |
| `.docs/conventions.md` | Only update if a convention is provably violated across multiple files (e.g., naming scheme changed). Do not modify conventions based on a single outlier. |
| `.docs/overview.md` | Only update the "What's Working" summary bullet and the main scene path if they change. Leave design intent text alone. |

## Steps

1. Read each source-of-truth file listed above.
2. Read the corresponding doc file.
3. Diff mentally: are any signatures, constants, file paths, or behavioral descriptions stale?
4. If stale: edit only the stale sections. Do not rewrite sections that are still accurate.
5. After all docs are checked, report a one-line summary:
   - "Docs are up to date." — if no changes were needed.
   - "Updated: `<doc1>`, `<doc2>`" — listing only docs that were actually edited.

## Rules

- Never remove a TODO item from `status.md` unless the corresponding feature is confirmed implemented in code.
- Never add a "What's Working" item unless the feature has a code implementation (not just a stub or comment).
- Do not update `overview.md` game design text — that is intentional design, not derived from code.
- If a file listed in the docs no longer exists on disk, flag it as a broken reference but do not silently delete the row.
