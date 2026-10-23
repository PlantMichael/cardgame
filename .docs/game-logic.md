# Game Logic Scripts

## minion.gd

Runtime creature instance. Created when a card is played to the board.

```gdscript
class_name Minion
extends RefCounted

var data: CardData
var owner_id: String
var current_attack: int
var current_health: int
var max_health: int
var has_attacked: bool = false
var is_exhausted: bool = false
var divine_shield: bool = false
var is_piloted: bool = false
var abilities: Array[String] = []
var is_newly_reinforced: bool = false
var is_newly_transformed: bool = false
var is_nulled: bool = false
var transform_counter: int = 0
var instance_id: String
var piloted_by: CardData = null
var pilot_atk_bonus: int = 0
var pilot_hp_bonus: int = 0

func has_ability(ability: String) -> bool:
func is_location() -> bool:
    return data.card_type == CardData.CardType.LOCATION
func can_attack() -> bool:
    return not is_location() and not has_attacked and not is_exhausted and current_attack > 0
```

**Locations** (`CardData.CardType.LOCATION`, first one: Crypt Chapel) are `Minion` instances sharing the same `board` array as creatures. They're played from hand into a board slot, hold only health, can be attacked and destroyed (dealing no retaliation damage, since their attack is 0), and their passive abilities fire from the board like any other watcher. `can_attack()` refuses explicitly rather than relying on 0 attack, so a stray buff can't arm one. `CardData.occupies_board()` is what every "does this need a board slot / go to the board" check asks — hand plays, the drop zone, and the AI's action enumeration.

## player_state.gd

Per-player state container.

```gdscript
class_name PlayerState
extends RefCounted

const MAX_BOARD_SIZE = 7
const MAX_HAND_SIZE = 10
const MAX_MANA = 10

var player_id: String
var hero_health: int = 30
var max_mana: int = 0
var current_mana: int = 0
var hand: Array[CardData] = []
var board: Array[Minion] = []
var deck: Array[CardData] = []
var graveyard: Array[CardData] = []
var fatigue_damage: int = 0
```

Key behaviors:
- `draw_card()` — deck-out increments `fatigue_damage` by 1 and deals that much damage (1, then 2, then 3, ... — same as Hearthstone; never resets mid-game); hand-full burns the top card (no fatigue)
- `gain_mana_crystal()` — increments max_mana up to 10 and refills current_mana
- `get_guardian_minions()` — returns board minions with the `"guardian"` ability

Board space is measured in **slots**, not bodies: `MAX_BOARD_SIZE` is 7 slots and a `TWO_SLOT` ("Colossal") creature occupies 2 of them. Every path that puts a creature on the board goes through these instead of comparing `board.size()` to `MAX_BOARD_SIZE`:
- `slots_for(abilities: Array[String]) -> int` (static) — 2 for a Colossal creature, else 1
- `board_slots_used() -> int` — sum of `slots_for()` across the board
- `has_room_for(abilities: Array[String]) -> bool` — whether a creature with those abilities still fits
- `can_fit_card(card: CardData) -> bool` — `has_room_for()` for creatures, always true for stratagems

## game_state.gd

Authoritative match state. All game actions go through here.

```gdscript
class_name GameState
extends RefCounted

enum Phase { WAITING, PLAYER_TURN, OPPONENT_TURN, GAME_OVER }

var player: PlayerState
var opponent: PlayerState
var current_phase: Phase
var active_player_id: String
var turn_number: int
var winner_id: String
var pending_drawn_cards: Array[CardData] = []
var pending_fatigue_damage: Array[String] = []
var pending_rummages: Array[Dictionary] = []
var pending_tank_shots: Array[String] = []
var pending_nulls: Array[Dictionary] = []
var pending_overwatch_challenges: Array[String] = []
var pending_buff_friendly_health: Array[String] = []
var pending_tank_specialist_buffs: Array[String] = []
var pending_on_reinforce_damages: Array[Dictionary] = []
var temp_shielded: Array[Dictionary] = []
var growvin_granted: Array[Dictionary] = []
var death_reinforce_used: Array[String] = []
var node_modifier_ability: String = ""  # Campaign node modifier granted to every creature played, both sides
```

### Pending choices

A decision a player must make is held as match **state**, not as a suspended
function waiting on a UI signal.

- `pending_choice` — the open choice, or `{}`. Carries `id`, `player_id`,
  `effect`, `amount`, `source_instance_id` and the legal `options`.
- `choice_options_for(effect, actor_id, source)` — the rules compute legality
  once; the UI highlights exactly those options rather than re-deriving them.
- `request_choice(...)` — opens one, or returns false and opens nothing when
  there is no legal target (the effect simply does not happen).
- `answer_choice(id, selection)` — validated: a stale id, an illegal target or
  a duplicate reply is rejected and the choice stays open.
- `execute()` refuses every ordinary command while a choice is open.

A choice is plain data, so it is copied with the state and travels in the
network view to the client that must answer it.

**Migration status:** the three targeted on-play effects (Frontier Medic,
Supply Quartermaster, Heavy Bounty Hunter) use this. The older prompts
(rummage, tank shot, null, buff-friendly, overwatch, transform, devour,
challenge, pilot) still suspend on board signals and have not been migrated.

### Per-player views

`to_net_dict(for_player_id)` builds the view for **one** recipient: their own
hand in full, the opponent's reduced to a count with no card ids or uids.
`PlayerState.get_hand_size()` is how to ask for a hand's size when the state
might be an opponent view — `hand.size()` is 0 there by design.

A view is **not** a save. It omits deck contents and the match generator, so
it cannot resume a match; that split is deliberate.

### Randomness

- `rng` — the match's own `RandomNumberGenerator`. Every roll a *rule* makes
  (shuffles, random targets, random rummage picks) comes from here, via
  `rand_index()` / `rand_pick()` / `shuffle_array()`, never global
  `randi()`/`randf()`.
- `set_gameplay_seed(n)` — fixes the match's randomness for a reproducible run.
- `duplicate_for_sim()` copies the generator's **position** (seed *and* state),
  so a clone continues the same sequence and then diverges on its own without
  touching the parent. On the global stream, the AI merely thinking changed
  what the real match rolled next.
- Search exploration uses `MCTSEngine._search_rng`, and cosmetic effects stay
  on the global stream. How hard the AI thinks is not part of the game.
- Still on the global stream, deliberately: menu/deck-building/campaign/bot-name
  randomness, which is outside any match.

### Effect resolution

- `PENDING_QUEUES` — the authoritative order queued effects resolve in. Every
  adapter iterates this rather than hard-coding a sequence.
- `has_pending()` — true while queued work remains (false once the match ends);
  adapters loop on it so effects queued by a late entry still resolve.
- `_remove_dead_minions()` — collects every lethal creature, removes the whole
  group, *then* fires their death triggers. Simultaneous lethal damage is
  simultaneous; nothing can be rescued out of the group.

### Shared operations

- `gain_max_health(target, n)` / `restore_health(target, n)` — the only two
  routes by which health goes up; they own the Crypt Hunger / Apothecary /
  transform reaction chain.
- `sanguine_recipients(actor_id, donor)` — legal Drain recipients (excludes the
  donor).

### Command boundary (how an action enters the rules)

Every player-initiated action goes through one validated entry point rather
than calling the mutators directly. Human play (`game_manager.gd`), the AI
(`ai_controller.gd`) and the search (`headless_turn.gd`) all use it, so they
cannot drift apart on what is legal.

- `execute(cmd) -> {"ok": bool, "error": String, ...}` — validates, then
  commits only if valid. A rejected command mutates nothing.
- `validate(cmd) -> {"ok": ...}` — the same checks with no side effects.
- `find_player(id) -> PlayerState` / `find_minion(instance_id) -> Minion` —
  return `null` for unknown ids. (`_get_player_by_id()` is the old internal
  helper and maps anything unrecognised to the *opponent*, so it must not be
  used to resolve a command's actor.)

Commands are **plain values**, never live objects:

```gdscript
{"type": "play_creature",  "actor": pid, "card_uid": uid, "at_index": -1}
{"type": "play_stratagem", "actor": pid, "card_uid": uid,
                           "target_instance_id": "", "target_player_id": ""}
{"type": "attack",         "actor": pid, "attacker_instance_id": iid,
                           "target_instance_id": "", "target_player_id": ""}
{"type": "end_turn",       "actor": pid}
```

Ids are resolved against *the state receiving the command*. This is what lets
the AI enumerate actions against one state and apply them to a copy: passing a
`Minion` object across that boundary used to mutate the original while the
copy's death cleanup ran against the copy, and `hand.erase(other_states_card)`
silently removed nothing.

Validated per command: actor is known and active, the match is not over, the
card is in that player's hand, card type matches the command, cost, board
room, target exists and is on the correct board, Guardian, Ambush and Cloaked.

Key methods:
- `start_game(first_player_id)` — deals 3 opening cards each, plus a compensating 4th to whoever goes *second* (going first is a tempo advantage), then begins the first turn
- `mulligan_swap(acting_player_id, cards_to_swap)` — called at most once per player right after `start_game()`: puts each listed card back into that player's deck and draws a same-count replacement. Silently skips any card no longer in hand. "Each card can only be mulliganed once" is enforced by the caller's one-shot modal, not here
- `end_turn()` — expires temp shields, then runs the ending player's end-of-turn effects in order: Rejuvenate, Feast Attendant (`_apply_feast_attendant`, gives adjacent board-index neighbors +0/+1), `_apply_mech_repair` (Mech Station heals friendly Mechs 2, stacking), `_apply_life_siphon` (Animus Hoarder drains 1 health off a random enemy creature onto itself), `_apply_yeti_discount` (Tutkiun gives Yetis in hand `cost_modifier -= 1`); then swaps active player and calls `_begin_turn()`
- `_begin_turn()` — clears `death_reinforce_used` (Corporal Garrick's once-per-turn save, cleared at every turn boundary since creatures die on both players' turns), grants a mana crystal and draws for the new active player; if their deck was already empty, records the player id in `pending_fatigue_damage` instead of a card draw, then calls `_check_win_condition()` immediately (so a lethal fatigue draw ends the game the instant the turn begins, not whenever some later action happens to check)
- `play_creature(acting_player_id, card)` → returns `Minion`
- `play_stratagem(acting_player_id, card, target_minion, target_player_id)` → bool; returns false if target has Cloaked (enemy only) or Ambush (enemy only) or player can't afford it
- `attack(attacker, target_minion, target_player_id)` — enforces taunt, resolves damage, removes dead minions
- `_strike_minion(attacker, target, amp, target_shield, defending)` — the single attacker-to-minion hit shared by attacks, the Dual Strike follow-up, and both challenge paths: damage after shields/amplify, Voidtouch's instant kill, then Trample spilling overkill (damage beyond the target's pre-hit health) onto `defending`'s hero
- `apply_challenge(challenger: Minion, target: Minion)` — resolves mini-combat between two minions (used by CHALLENGE ability)
- `apply_on_play_damage(target: Minion, damage: int, source_player_id: String = "")` — applies direct damage (plus ENEMY_DAMAGE_AMP bonus if source_player_id provided) and checks win condition
- `apply_pilot(pilot_minion, target_mech, pilot_owner)` — buffs mech with pilot stats, removes pilot from board; triggers `ON_PILOTED_GAIN_RUSH` if present
- `apply_eject_pilot(target_mech, owner)` — reverses a pilot merge: restores mech stats, returns pilot card to board (or hand if board full); reusable from any card effect
- `apply_null(target: Minion)` — clears all abilities from target and sets `is_nulled = true`; if the target was an aura *source*, also calls `reconcile_lasting_effects()` so its grants are withdrawn
- `reconcile_lasting_effects(owner_id)` — re-checks source-bound grants (currently Growvin's aura) and withdraws any whose source no longer qualifies. Call after anything that strips or replaces a creature's abilities (silence, transformation); it is idempotent
- `apply_transform_choice(minion, chosen_id)` — transforms minion into the card with the given id, retaining damage taken
- `apply_buff_friendly_health(target: Minion)` — gives target +1 max health; triggers Apothecary and health-threshold transform
- `apply_heal_buff(target: Minion, amount: int)` — gives target +amount max and current health; triggers Apothecary and health-threshold transform
Key methods also include:
Rummage methods:
- `get_rummage_options(player_id, max_cost, type_filter, allow_equal_cost: bool = false)` → `Array[CardData]`; returns unique graveyard cards matching filters (`""`, `"creature"`, `"stratagem"`, `"mech"`, `"creature_nonlegendary"`); `max_cost = -1` means no cost filter; `allow_equal_cost` makes the cost filter inclusive (≤ instead of <)
- `apply_swap_friendly_health(minion_a, minion_b)` — swaps current_health between two minions, each capped at the other's max_health; removes dead minions afterward
- `apply_devour_friendly(devourer, target, owner)` — removes target from board (added to graveyard), grants `target.current_health` to devourer's max and current health
- `complete_rummage(player_id, card, play_it: bool = false, discount: bool = true, buff_creature: bool = false)` — removes card from graveyard; if `play_it` is true (or Stinkpile is on board) and card is a creature with board space, places it directly; otherwise adds to hand with optional `-1 cost_modifier` (black rummage only — non-black fetch mechanics pass `discount: false`). `buff_creature` (Salvager) permanently adds +1/+1 to the retrieved creature's `CardData` before anything reads its stats; the pending-rummage entry carries it as `"buff_creature": true`

Stratagem effects handled in `_apply_stratagem()`:
- `"deal_damage"` — damages target minion or hero
- `"buff_creature"` — increases attack and health
- `"buff_health"` — increases health only
- `"give_ability"` — grants an ability from `card.abilities[0]` to the target minion
- `"deal_damage_all_creatures"` — deals damage to every minion on both sides
- `"buff_all_friendly_attack"` — gives all friendly creatures +N attack (no target needed)
- `"poke_bear"` — deals N damage to a target creature; equivalent to `"deal_damage"` in game_state
- `"blood_transfusion"` — deals N damage to a target enemy creature; a second prompt selects a friendly to receive +N health
- `"sanguine"` — deals N damage to a target friendly creature; a second prompt selects another friendly to receive +N health
- `"heal"` — restores N health to target minion (capped at max_health)
- `"tainted_blood"` — destroys a target friendly creature (added to graveyard) and deals `target.current_health / 2` (rounded down) damage to the enemy hero
- `"bloodlet"` — if target (minion or hero) belongs to the acting player, heals it N (minions capped at max_health); otherwise deals N damage to it
- `"exsanguinate"` — deals damage to a target enemy minion equal to `target.current_health * N` (always lethal)
- `"blood_boil"` — adds `target.current_health * N` to a target friendly creature's current and max health (doubles current health at N=1)
- `"eject_pilot"` — reverses a pilot merge on a friendly piloted Mech; calls `apply_eject_pilot()`
- `"eject_all_pilots"` — reverses all pilot merges on all friendly piloted Mechs
- `"destroy_all_creatures"` — sets every minion's health to 0 on both boards, then removes them all
- `"deal_damage_all_enemy"` — deals `effect_value` damage to every enemy minion (no target needed); e.g. Noxious Bombardment
- `"force_challenge"` — prompts player to pick a friendly Yeti to immediately challenge a chosen enemy; if `effect_value > 0` and the target dies, the Yeti gains +`effect_value`/+`effect_value`; e.g. Icewhip
