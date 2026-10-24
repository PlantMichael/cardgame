class_name GameState
extends RefCounted

enum Phase { WAITING, PLAYER_TURN, OPPONENT_TURN, GAME_OVER }

var player: PlayerState
var opponent: PlayerState
var current_phase: Phase = Phase.WAITING
var active_player_id: String = ""
var turn_number: int = 0
var winner_id: String = ""
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
## Whoever has already spent Corporal Garrick's once-per-turn save. Cleared at
## every turn boundary rather than only on its owner's turn, since creatures
## die on the enemy's turn too and the card promises one save per turn either
## way.
var death_reinforce_used: Array[String] = []
## Campaign mode only (see campaign_state.gd): battlefield-wide ability
## granted to every creature either side plays, e.g. "ambush" for a Dunes
## node. Empty outside Campaign matches.
var node_modifier_ability: String = ""
var _opening_hand_dealt: bool = false
## player_id -> true once that player has completed their very first turn -
## see _begin_turn(). Neither player draws a card on their first turn
## (they've already got their opening hand); tracked per-player rather than
## derived from turn_number, since turn_number only increments when control
## returns to `player` (see end_turn()) and so reads as 1 for BOTH sides'
## first turns when `player` goes first, but jumps to 2 before `player`'s
## own first turn if `opponent` went first instead - not a reliable "is this
## anyone's first turn" check on its own.
var _first_turn_taken: Dictionary = {}

## The match's own gameplay randomness.
##
## Everything a rule rolls - shuffles, a random target, a random rummage pick -
## comes from here rather than the global randi()/randf(). Two reasons:
##
##  1. A simulation branch must not disturb the real match. The AI copies this
##     state hundreds of times per turn and rolls inside each copy; on the
##     global stream, merely thinking changed what the real game would roll
##     next.
##  2. A match is reproducible from its starting state plus this generator's
##     state, which is what makes a replay or a bug report re-runnable.
##
## Search exploration and cosmetic effects deliberately do NOT use this - see
## MCTSEngine's own generator. Copying a state copies the generator's position,
## so a clone continues the same sequence independently of its parent.
var rng := RandomNumberGenerator.new()

func _init(local_player_id: String, opponent_player_id: String,
		   player_deck: Array[CardData], opponent_deck: Array[CardData]) -> void:
	player = PlayerState.new(local_player_id, player_deck)
	opponent = PlayerState.new(opponent_player_id, opponent_deck)
	# Shuffled here, not in PlayerState, so the opening decks come off the
	# match's generator and a seeded match deals the same opening hands.
	shuffle_array(player.deck)
	shuffle_array(opponent.deck)

## Fixes the match's gameplay randomness, for a reproducible match.
func set_gameplay_seed(seed_value: int) -> void:
	# Assigning `seed` is what resets the generator. Do NOT also zero `state`:
	# that replaces the seed-derived state with a degenerate one, and every
	# seed then produced the same sequence.
	rng.seed = seed_value

## A uniform index into a collection of `size` items, or -1 when it is empty.
func rand_index(size: int) -> int:
	return rng.randi_range(0, size - 1) if size > 0 else -1

## A uniform element of `arr`, or null when empty.
func rand_pick(arr: Array):
	var i := rand_index(arr.size())
	return arr[i] if i >= 0 else null

## Fisher-Yates on the match's generator. Array.shuffle() would use the global
## stream, which is the thing this all exists to stay off.
func shuffle_array(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp

func start_game(first_player_id: String) -> void:
	active_player_id = first_player_id
	current_phase = Phase.PLAYER_TURN if first_player_id == player.player_id \
					else Phase.OPPONENT_TURN
	turn_number = 1
	for i in 3:
		player.draw_card()
		opponent.draw_card()
	# Going first gives tempo (acts on an empty board before the other player
	# gets to do anything), so the second player draws a compensating 4th
	# opening card instead of the usual 3.
	var second_player := opponent if first_player_id == player.player_id else player
	second_player.draw_card()
	_begin_turn()
	_opening_hand_dealt = true

## Mulligan: swaps each of cards_to_swap out of acting player's hand, back
## into their deck, and draws a same-count replacement. Called at most once
## per player right after start_game() - the caller's own UI (one modal,
## closed for good after a single confirm) is what enforces "each card can
## only be mulliganed once", not anything here. Silently skips any card no
## longer in hand (stale reference).
## Returns the cards that came in as replacements, in draw order, so a caller
## can show them (the mulligan screen deals each into the slot it replaced).
func mulligan_swap(acting_player_id: String, cards_to_swap: Array[CardData]) -> Array[CardData]:
	var acting := _get_player_by_id(acting_player_id)
	var incoming: Array[CardData] = []
	var swapped_count := 0
	for card in cards_to_swap:
		if card not in acting.hand:
			continue
		acting.hand.erase(card)
		acting.deck.append(card)
		swapped_count += 1
	if swapped_count == 0:
		return incoming
	shuffle_array(acting.deck)
	for i in swapped_count:
		var drawn := acting.draw_card()
		if drawn != null:
			incoming.append(drawn)
	return incoming

func _begin_turn() -> void:
	var active = _get_active_player()
	death_reinforce_used.clear()
	active.gain_mana_crystal()
	if not _first_turn_taken.get(active.player_id, false):
		_first_turn_taken[active.player_id] = true
	else:
		var was_deck_empty: bool = active.deck.is_empty()
		var drawn := active.draw_card()
		if was_deck_empty:
			pending_fatigue_damage.append(active.player_id)
		elif _opening_hand_dealt and drawn != null and active.player_id == player.player_id:
			pending_drawn_cards.append(drawn)
	active.reset_for_new_turn()
	_check_win_condition()

func end_turn() -> void:
	_expire_temp_shields_for(active_player_id)
	_apply_rejuvenate(active_player_id)
	_apply_feast_attendant(active_player_id)
	_apply_mech_repair(active_player_id)
	_apply_life_siphon(active_player_id)
	_apply_yeti_discount(active_player_id)
	if active_player_id == player.player_id:
		active_player_id = opponent.player_id
		current_phase = Phase.OPPONENT_TURN
	else:
		active_player_id = player.player_id
		current_phase = Phase.PLAYER_TURN
		turn_number += 1
	_begin_turn()

# --- Effect resolution order (the timing specification) ---
#
# An action does not finish when its own effect resolves: it can leave work in
# the pending_* queues (a tank's free shot, a rummage, a silence, ...) that has
# to be worked off before the next command is accepted.
#
# PENDING_QUEUES is the authoritative order that work is taken in, and every
# adapter - local play, multiplayer host, and the headless search - resolves
# against this list rather than hard-coding a sequence of its own. They used to
# each keep their own: local play and the search disagreed about whether tank
# shots or rummages went first, and multiplayer simply never drained
# pending_tank_specialist_buffs, so a Tank Specialist's buff silently never
# happened in a networked match. Ordering differences like that are invisible
# until two players disagree about the board.
#
# The rules this encodes:
#
#  1. Queues are drained in PENDING_QUEUES order, earlier queues first.
#  2. Within a queue, entries resolve in the order they were added (FIFO).
#  3. Resolution repeats until nothing is pending. An effect may enqueue more
#     work, including into a queue that has already been drained this pass, and
#     that work must still resolve rather than being stranded until some later
#     unrelated action happens to drain it.
#  4. Resolution stops immediately once the match is over.
#
# Deliberately NOT claimed here: that a single FIFO list answers every timing
# question. Interacting triggers that need genuine simultaneity are handled
# where they arise - see _remove_dead_minions(), which collects a whole lethal
# group before resolving any of its death triggers.
const PENDING_QUEUES: Array[String] = [
	"pending_tank_shots",
	"pending_rummages",
	"pending_nulls",
	"pending_buff_friendly_health",
	"pending_tank_specialist_buffs",
	"pending_on_reinforce_damages",
	"pending_overwatch_challenges",
]

## Legal recipients for Drain / Sanguine (cr_str_003): "Take 2 health from a
## creature you control and give it to ANOTHER creature you control."
##
## The donor is excluded, per that "another". Each mode used to decide this
## for itself and they disagreed: the simulation excluded the donor while
## local play and multiplayer let the player hand the health straight back to
## the creature it came from, making the card a no-op that drew no card and
## cost nothing. Targeting legality is a rule, so it lives here and every mode
## asks rather than re-implementing it.
func sanguine_recipients(acting_player_id: String, donor: Minion) -> Array[Minion]:
	var out: Array[Minion] = []
	var acting := find_player(acting_player_id)
	if acting == null:
		return out
	for m in acting.board:
		if m != donor:
			out.append(m)
	return out

## True while any queued effect still has to resolve. Adapters loop on this so
## effects created by a late queue still get their turn (rule 3 above).
func has_pending() -> bool:
	if current_phase == Phase.GAME_OVER:
		return false
	for queue_name in PENDING_QUEUES:
		var queue: Array = get(queue_name)
		if not queue.is_empty():
			return true
	return false

# --- Pending choices ---
#
# A decision a player has to make before the match can continue, held as match
# STATE rather than as a suspended function waiting on a UI signal.
#
# The difference matters for three reasons:
#  1. Legality is computed once, here, and handed to whoever presents the
#     choice. The UI highlights exactly the options the rules produced instead
#     of re-deriving them and possibly disagreeing.
#  2. An answer is checked against the choice that is actually open. A stale,
#     duplicated or wrong-player reply is rejected instead of resolving an
#     effect a second time.
#  3. The choice is plain data, so it survives being copied with the state and
#     could be written to a save. A continuation captured inside a suspended
#     `await` cannot.
#
# Ordinary commands are refused while a choice is open (see validate()), so a
# match cannot be driven forward around an unanswered decision.
#
# Scope: the three targeted on-play effects below are built on this. The older
# prompts (rummage, tank shot, null, buff-friendly, overwatch, transform,
# devour, challenge, pilot) still suspend on board signals and have NOT been
# migrated - doing one effect family first and proving it is the intended
# order, not an oversight.

## What an answered choice does. Each is resolved through a shared operation,
## never by touching the creature directly.
const CHOICE_RESTORE_HEALTH := "restore_health"
const CHOICE_BUFF_OTHER_FRIENDLY := "buff_other_friendly"
const CHOICE_DAMAGE_HIGH_ATTACK := "damage_high_attack"

## Attack threshold Heavy Bounty Hunter's target must meet. Measured against
## CURRENT attack, so a buffed or debuffed creature counts as it stands now.
const BOUNTY_HUNTER_MIN_ATTACK := 5

## The open choice, or {} when none. Shape:
##   id                 unique within the match; answers must quote it
##   player_id          who must answer
##   effect             one of the CHOICE_* constants above
##   amount             how much (heal 1, buff 1, damage 4)
##   source_instance_id the creature whose ability asked
##   options            legal target instance_ids, computed by the rules
var pending_choice: Dictionary = {}
var _next_choice_id: int = 0

func has_pending_choice() -> bool:
	return not pending_choice.is_empty()

## Can `actor_id` target `target` at all? Enemy creatures hiding behind
## Cloaked or Ambush cannot be chosen; a player's own creatures always can.
func is_targetable_by(target: Minion, actor_id: String) -> bool:
	if target == null:
		return false
	if target.owner_id == actor_id:
		return true
	return not target.has_ability(Abilities.CLOAKED) and not target.has_ability(Abilities.AMBUSH)

## The legal targets for `effect`, as instance_ids. Returning an empty list
## means the effect simply does not happen - no choice is opened, and the
## creature still enters play (handoff: "do not leave an impossible mandatory
## prompt waiting").
func choice_options_for(effect: String, actor_id: String, source: Minion) -> Array[String]:
	var out: Array[String] = []
	var actor := find_player(actor_id)
	if actor == null:
		return out
	var enemy := find_player(_opponent_id(actor_id))
	match effect:
		CHOICE_RESTORE_HEALTH:
			# Any living creature on either board. A full-health creature is
			# still a legal target - it just gains nothing - and heroes never
			# are.
			for p in [actor, enemy]:
				for m in p.board:
					if is_targetable_by(m, actor_id):
						out.append(m.instance_id)
		CHOICE_BUFF_OTHER_FRIENDLY:
			# "ANOTHER friendly creature" - the source cannot pick itself.
			for m in actor.board:
				if m != source:
					out.append(m.instance_id)
		CHOICE_DAMAGE_HIGH_ATTACK:
			for m in enemy.board:
				if m.current_attack >= BOUNTY_HUNTER_MIN_ATTACK and is_targetable_by(m, actor_id):
					out.append(m.instance_id)
	return out

## Opens a choice if it has any legal target. Returns false (and opens
## nothing) when it does not, so the caller can simply continue.
func request_choice(player_id: String, effect: String, amount: int, source: Minion) -> bool:
	var options := choice_options_for(effect, player_id, source)
	if options.is_empty():
		return false
	_next_choice_id += 1
	pending_choice = {
		"id": "choice-%d" % _next_choice_id,
		"player_id": player_id,
		"effect": effect,
		"amount": amount,
		"source_instance_id": source.instance_id if source != null else "",
		"options": options,
	}
	return true

## The open choice's legal targets as live minions, for a caller that needs
## objects (the UI highlighting them, the AI scoring them).
func pending_choice_targets() -> Array[Minion]:
	var out: Array[Minion] = []
	if not has_pending_choice():
		return out
	for iid in pending_choice["options"]:
		var m := find_minion(str(iid))
		if m != null:
			out.append(m)
	return out

## Answers the open choice. `selection_instance_id` must be one of its
## options, or "" to decline.
##
## Returns {"ok": true} or {"ok": false, "error": ...}. A rejection resolves
## nothing and leaves the choice open, so a wrong answer cannot consume it.
func answer_choice(choice_id: String, selection_instance_id: String) -> Dictionary:
	if not has_pending_choice():
		return _reject("no choice is pending")
	if choice_id != str(pending_choice["id"]):
		# A reply to a choice that has already been answered - a duplicate or
		# a message that arrived late. Dropping it is the whole point of
		# carrying the id.
		return _reject("stale choice id")
	var effect := str(pending_choice["effect"])
	var amount := int(pending_choice["amount"])
	var actor_id := str(pending_choice["player_id"])

	if selection_instance_id.is_empty():
		pending_choice = {}
		return {"ok": true, "declined": true}
	if selection_instance_id not in pending_choice["options"]:
		return _reject("selection is not a legal target")
	var target := find_minion(selection_instance_id)
	if target == null:
		return _reject("target is no longer on the board")

	# Clear BEFORE resolving: the effect can itself queue work or open the
	# next choice, and it must not find this one still occupying the slot.
	pending_choice = {}
	match effect:
		CHOICE_RESTORE_HEALTH:
			restore_health(target, amount)
		CHOICE_BUFF_OTHER_FRIENDLY:
			target.current_attack += amount
			gain_max_health(target, amount)
		CHOICE_DAMAGE_HIGH_ATTACK:
			apply_on_play_damage(target, amount, actor_id)
	_check_win_condition()
	return {"ok": true}

## Abandons the open choice without resolving it - used when a match is torn
## down, so nothing is left waiting on an answer that will never come.
func cancel_pending_choice() -> void:
	pending_choice = {}

# --- Validated command boundary ---
#
# Every player-initiated action goes through validate()/execute(). Commands
# are plain values - player ids, a card's uid, a minion's instance_id - never
# live CardData/Minion objects. Two reasons:
#
#  1. Objects cannot cross a state boundary. AI search copies a GameState and
#     applies actions to the copy; an action holding the parent's Minion
#     mutated the PARENT while the copy's death cleanup ran against the copy,
#     and hand.erase(parent_card) silently removed nothing from the child.
#     Resolving ids against the state receiving the command makes that
#     impossible to express.
#  2. The id has to be re-checked anyway. A command naming a card that has
#     left hand, or a minion that has died, must be rejected rather than
#     resolved against a stale reference.
#
# validate() must not mutate. execute() validates first and only then
# commits, so a rejected command leaves the state untouched.

## Command types accepted by execute().
const CMD_PLAY_CREATURE := "play_creature"
const CMD_PLAY_STRATAGEM := "play_stratagem"
const CMD_ATTACK := "attack"
const CMD_END_TURN := "end_turn"

## Unknown ids map to null rather than silently falling through to the
## opponent the way _get_player_by_id() does - a command from an unrecognised
## actor must fail, not be credited to whoever happens not to be `player`.
func find_player(id: String) -> PlayerState:
	if id == player.player_id:
		return player
	if id == opponent.player_id:
		return opponent
	return null

func find_minion(instance_id: String) -> Minion:
	if instance_id.is_empty():
		return null
	for p in [player, opponent]:
		for m in p.board:
			if m.instance_id == instance_id:
				return m
	return null

static func _reject(reason: String) -> Dictionary:
	return {"ok": false, "error": reason}

## Checks a command completely without changing anything. Returns
## {"ok": true, ...resolved objects...} or {"ok": false, "error": reason}.
## The resolved entries let execute() avoid looking everything up twice.
func validate(cmd: Dictionary) -> Dictionary:
	var cmd_type: String = str(cmd.get("type", ""))
	if cmd_type.is_empty():
		return _reject("missing command type")
	if current_phase == Phase.GAME_OVER:
		return _reject("game is over")
	if has_pending_choice():
		# The match cannot be driven forward around an unanswered decision.
		return _reject("a pending choice must be answered first")

	var actor_id: String = str(cmd.get("actor", ""))
	var actor := find_player(actor_id)
	if actor == null:
		return _reject("unknown actor")
	if actor_id != active_player_id:
		return _reject("not this player's turn")

	match cmd_type:
		CMD_END_TURN:
			return {"ok": true, "actor": actor}
		CMD_PLAY_CREATURE:
			return _validate_play(actor, cmd, true)
		CMD_PLAY_STRATAGEM:
			return _validate_play(actor, cmd, false)
		CMD_ATTACK:
			return _validate_attack(actor, cmd)
	return _reject("unknown command type")

func _validate_play(actor: PlayerState, cmd: Dictionary, as_creature: bool) -> Dictionary:
	var card := actor.find_card_in_hand(str(cmd.get("card_uid", "")))
	if card == null:
		return _reject("card not in hand")
	if as_creature:
		if not card.occupies_board():
			return _reject("card does not go to the board")
	elif card.card_type != CardData.CardType.STRATAGEM:
		return _reject("card is not a stratagem")
	if not actor.can_play_card(card):
		return _reject("cannot afford card")
	if not actor.can_fit_card(card):
		return _reject("no board room")

	var target: Minion = null
	var target_id: String = str(cmd.get("target_instance_id", ""))
	if not target_id.is_empty():
		target = find_minion(target_id)
		if target == null:
			return _reject("target minion is no longer on the board")
	if as_creature:
		return {"ok": true, "actor": actor, "card": card}

	var target_player_id: String = str(cmd.get("target_player_id", ""))
	if not target_player_id.is_empty() and find_player(target_player_id) == null:
		return _reject("unknown target player")
	var target_error := _stratagem_target_error(card, target, target_player_id, actor)
	if not target_error.is_empty():
		return _reject(target_error)
	# Targeting protection is a rule, not a UI convenience: enforce it here so
	# AI, multiplayer and a hand-built command all obey it, not just the
	# pointer-based board code that used to be the only thing checking.
	if target != null and card.effect != "eject_pilot" and target.owner_id != actor.player_id:
		if target.has_ability(Abilities.CLOAKED) or target.has_ability(Abilities.AMBUSH):
			return _reject("target cannot be targeted")
	return {"ok": true, "actor": actor, "card": card, "target": target, "target_player_id": target_player_id}

func _validate_attack(actor: PlayerState, cmd: Dictionary) -> Dictionary:
	var attacker := find_minion(str(cmd.get("attacker_instance_id", "")))
	if attacker == null:
		return _reject("attacker is no longer on the board")
	if attacker.owner_id != actor.player_id or attacker not in actor.board:
		return _reject("attacker does not belong to this player")
	if not attacker.can_attack():
		return _reject("attacker cannot attack right now")

	var defending := find_player(_opponent_id(actor.player_id))
	var guardians := defending.get_guardian_minions()
	var target_id: String = str(cmd.get("target_instance_id", ""))
	var target_player_id: String = str(cmd.get("target_player_id", ""))

	if target_id.is_empty():
		if target_player_id.is_empty():
			return _reject("attack names no target")
		if target_player_id != defending.player_id:
			return _reject("can only attack the opposing hero")
		if not guardians.is_empty():
			return _reject("a Guardian must be attacked first")
		return {"ok": true, "actor": actor, "attacker": attacker, "target": null, "target_player_id": target_player_id}

	var target := find_minion(target_id)
	if target == null:
		return _reject("target is no longer on the board")
	if target not in defending.board:
		return _reject("can only attack an enemy creature")
	if not guardians.is_empty() and target not in guardians:
		return _reject("a Guardian must be attacked first")
	if target.has_ability(Abilities.AMBUSH):
		return _reject("target cannot be attacked")
	return {"ok": true, "actor": actor, "attacker": attacker, "target": target, "target_player_id": ""}

## Validates `cmd` and, only if it passes, commits it. Never mutates on a
## rejection. On success returns {"ok": true} plus whatever the command
## produced ("minion" for a creature play), so callers that need the result
## do not have to re-find it.
func execute(cmd: Dictionary) -> Dictionary:
	var check := validate(cmd)
	if not check["ok"]:
		return check
	var actor: PlayerState = check["actor"]
	match str(cmd["type"]):
		CMD_END_TURN:
			end_turn()
			return {"ok": true}
		CMD_PLAY_CREATURE:
			var minion := play_creature(actor.player_id, check["card"], int(cmd.get("at_index", -1)))
			if minion == null:
				return _reject("play failed after validation")
			return {"ok": true, "minion": minion}
		CMD_PLAY_STRATAGEM:
			var ok := play_stratagem(actor.player_id, check["card"], check["target"], check["target_player_id"])
			if not ok:
				return _reject("stratagem failed after validation")
			return {"ok": true, "card": check["card"], "target": check["target"]}
		CMD_ATTACK:
			attack(check["attacker"], check["target"], check["target_player_id"])
			return {"ok": true}
	return _reject("unhandled command type")

# --- Actions ---

func play_creature(acting_player_id: String, card: CardData, at_index: int = -1) -> Minion:
	var acting = _get_player_by_id(acting_player_id)
	if not acting.play_card_from_hand(card):
		return null
	var minion = Minion.new(card, acting_player_id)
	if not node_modifier_ability.is_empty() and not minion.has_ability(node_modifier_ability):
		minion.abilities.append(node_modifier_ability)
		# Granting Rush this way has to also clear is_exhausted itself, same
		# as _apply_stratagem's "give_ability" effect - see that comment for
		# why (Minion._init() only reads starting abilities for this).
		if node_modifier_ability == Abilities.RUSH:
			minion.is_exhausted = false
	acting.place_minion(minion, at_index)
	Abilities.fire_on_play(minion, acting, self)
	if minion.has_ability(Abilities.MECH) and minion in acting.board:
		var has_growvin := false
		for _gm in acting.board:
			if _gm != minion and _gm.has_ability(Abilities.GROWVIN_AURA):
				has_growvin = true
				break
		if has_growvin:
			_apply_growvin_aura_to_mech(minion, acting_player_id)
	return minion

# --- Shared health operations ---
#
# Every route that raises a creature's health goes through one of these two.
# They exist because the reaction chain that has to follow a health gain -
# Crypt Hunger's replacement, Apothecary's bonus, the max-health transform
# check - was previously open-coded at each call site, and most sites
# remembered only part of it. Ten places in abilities.gd raised max health and
# ran Crypt Hunger and Apothecary but never the transform check, so a creature
# buffed over its transform threshold by an ability simply did not transform,
# while the same creature buffed by Supply Drop did.
#
# Adding a new effect that grants health means calling one of these, not
# copying a four-line sequence and hoping it is the current one.

## +amount to BOTH current and maximum health (a buff: Supply Drop, Apothecary,
## tank specialist, the on-play and death-trigger buffs).
func gain_max_health(target: Minion, amount: int) -> void:
	if target == null or amount <= 0:
		return
	var pre := target.current_health
	target.current_health += amount
	target.max_health += amount
	_try_heal_to_draw(target, target.current_health - pre, amount)
	_try_apothecary_bonus(target.owner_id, target)
	_try_health_transform(target)

## Restores up to `amount` damage, capped at the existing maximum (Rejuvenate,
## Mech Station, the heal stratagem on a wounded target). Maximum health is
## untouched, which is why Crypt Hunger is told 0 was gained there.
##
## No transform check: _try_health_transform() triggers off max_health, and a
## pure heal cannot raise it.
func restore_health(target: Minion, amount: int) -> void:
	if target == null or amount <= 0:
		return
	var pre := target.current_health
	target.current_health = mini(target.current_health + amount, target.max_health)
	var gained := target.current_health - pre
	if gained <= 0:
		return
	_try_heal_to_draw(target, gained, 0)
	_try_apothecary_bonus(target.owner_id, target)

func apply_buff_friendly_health(target: Minion) -> void:
	gain_max_health(target, 1)

func apply_heal_buff(target: Minion, amount: int) -> void:
	gain_max_health(target, amount)

func apply_tank_specialist_buff(target: Minion) -> void:
	target.current_attack += 1
	gain_max_health(target, 2)

## Silences the target: strips abilities and reverts attack/health to the
## card's printed base stats (damage already taken carries over, clamped so
## the revert itself can't kill the minion, matching apply_transform_choice's
## convention). If the target is a piloted mech, the pilot is killed outright
## (sent to the graveyard, not ejected alive like apply_eject_pilot) since its
## bonuses are wiped along with everything else.
func apply_null(target: Minion) -> void:
	if target.is_piloted and target.piloted_by != null:
		_get_player_by_id(target.owner_id).graveyard.append(target.piloted_by)
		target.is_piloted = false
		target.piloted_by = null
		target.pilot_atk_bonus = 0
		target.pilot_hp_bonus = 0
	var had_aura := target.has_ability(Abilities.GROWVIN_AURA)
	target.abilities.clear()
	target.is_nulled = true
	# Silencing an aura SOURCE has to withdraw what that source granted.
	# Clearing its ability list alone left every mech it had buffed holding
	# Cloaked/Shielded/Rejuvenate for the rest of the match, with stale
	# growvin_granted bookkeeping that nothing would ever clean up.
	if had_aura:
		reconcile_lasting_effects(target.owner_id)
	var damage_taken := target.max_health - target.current_health
	target.current_attack = target.data.attack
	target.max_health = target.data.health
	target.current_health = max(1, target.data.health - damage_taken)

## Effect names for the stratagems that need rules of their own (below).
const EFFECT_RETURN_FRIENDLY := "return_friendly_to_hand"
const EFFECT_DAMAGE_ENEMIES_DRAW_YETI := "deal_damage_all_enemy_draw_yeti"

## Why `target` is not a legal pick for `card` - or "" when it is. Kept in the
## rules core so every route (command, AI, host, guest) refuses the same way
## and BEFORE any mana is spent or the card consumed.
func _stratagem_target_error(card: CardData, target: Minion, target_player_id: String,
							 actor: PlayerState) -> String:
	if card.effect == EFFECT_RETURN_FRIENDLY:
		if not target_player_id.is_empty():
			return "a hero is not a legal target"
		if target == null:
			return "no creature chosen"
		if target.owner_id != actor.player_id or target not in actor.board:
			return "target must be a creature on your own board"
		if target.data.card_type != CardData.CardType.CREATURE:
			return "target must be a creature"
		# The play removes this card from hand first, so the returned card
		# needs the slot that frees. A hand at capacity cannot exist with the
		# card still in it, but the rule is stated rather than assumed.
		if actor.hand.size() > PlayerState.MAX_HAND_SIZE:
			return "no room in hand"
	return ""

func play_stratagem(acting_player_id: String, card: CardData,
					target_minion: Minion = null, target_player_id: String = "") -> bool:
	if not _stratagem_target_error(card, target_minion, target_player_id,
			_get_player_by_id(acting_player_id)).is_empty():
		return false
	if target_minion != null and card.effect != "eject_pilot":
		if target_minion.has_ability(Abilities.CLOAKED) and target_minion.owner_id != acting_player_id:
			return false
		if target_minion.has_ability(Abilities.AMBUSH) and target_minion.owner_id != acting_player_id:
			return false
	var acting = _get_player_by_id(acting_player_id)
	if not acting.play_card_from_hand(card):
		return false
	acting.graveyard.append(card)
	_apply_stratagem(card, target_minion, target_player_id, acting_player_id)
	return true

func attack(attacker: Minion, target_minion: Minion = null,
			target_player_id: String = "") -> void:
	if not attacker.can_attack():
		return

	var defending = _get_player_by_id(_opponent_id(attacker.owner_id))
	var guardians = defending.get_guardian_minions()
	if not guardians.is_empty() and target_minion not in guardians:
		return
	if target_minion != null and target_minion.has_ability(Abilities.AMBUSH):
		return

	attacker.has_attacked = true
	attacker.transform_counter += 1
	if attacker.has_ability(Abilities.AMBUSH):
		attacker.abilities.erase(Abilities.AMBUSH)

	var attacker_shield := _get_shield_value(attacker)
	var attacker_amp := _get_enemy_damage_amp(attacker.owner_id)

	if target_minion:
		var target_shield := _get_shield_value(target_minion)
		if not target_minion.has_ability(Abilities.COMBAT_IMMUNE):
			_strike_minion(attacker, target_minion, attacker_amp, target_shield, defending)
		if not attacker.has_ability(Abilities.COMBAT_IMMUNE):
			attacker.take_damage(maxi(0, target_minion.current_attack - attacker_shield))
		Abilities.fire_on_attack(attacker, _get_player_by_id(attacker.owner_id), self)
		Abilities.fire_on_defend(target_minion, _get_player_by_id(target_minion.owner_id), self)
		_remove_dead_minions()
		var acting = _get_player_by_id(attacker.owner_id)
		if attacker in acting.board:
			_try_transform(attacker, acting)
		# Dual Strike: automatic second hit on same target
		if attacker.has_ability(Abilities.DUAL_STRIKE) and attacker in acting.board and target_minion in defending.board:
			if not target_minion.has_ability(Abilities.COMBAT_IMMUNE):
				_strike_minion(attacker, target_minion, attacker_amp, target_shield, defending)
			if not attacker.has_ability(Abilities.COMBAT_IMMUNE):
				attacker.take_damage(maxi(0, target_minion.current_attack - attacker_shield))
			Abilities.fire_on_attack(attacker, acting, self)
			Abilities.fire_on_defend(target_minion, defending, self)
			_remove_dead_minions()
			if attacker in acting.board:
				_try_transform(attacker, acting)
	elif target_player_id != "":
		var target_player = _get_player_by_id(target_player_id)
		var hits := 2 if attacker.has_ability(Abilities.DUAL_STRIKE) else 1
		target_player.hero_health -= attacker.current_attack * hits
		Abilities.fire_on_attack(attacker, _get_player_by_id(attacker.owner_id), self)
		_try_transform(attacker, _get_player_by_id(attacker.owner_id))

	_check_win_condition()

func apply_challenge(challenger: Minion, target: Minion) -> void:
	var was_yeti = challenger.has_ability(Abilities.YETI)
	var owner_id = challenger.owner_id
	var challenger_shield := _get_shield_value(challenger)
	var target_shield := _get_shield_value(target)
	var challenger_amp := _get_enemy_damage_amp(challenger.owner_id)
	if not target.has_ability(Abilities.COMBAT_IMMUNE):
		_strike_minion(challenger, target, challenger_amp, target_shield, _get_player_by_id(target.owner_id))
	if not challenger.has_ability(Abilities.COMBAT_IMMUNE):
		challenger.take_damage(maxi(0, target.current_attack - challenger_shield))
	_remove_dead_minions()
	var owner = _get_player_by_id(owner_id)
	if was_yeti and challenger in owner.board:
		for m in owner.board:
			if m.has_ability(Abilities.ON_YETI_CHALLENGE_BUFF):
				challenger.current_attack += 1
				var pre := challenger.current_health
				challenger.current_health += 1
				challenger.max_health += 1
				_try_heal_to_draw(challenger, challenger.current_health - pre)
				_try_apothecary_bonus(owner_id, challenger)
				_try_health_transform(challenger)
				break

	if was_yeti:
		var enemy := _get_player_by_id(_opponent_id(owner_id))
		for m in owner.board.duplicate():
			if not m.has_ability(Abilities.ON_YETI_CHALLENGE_ATTACK) or not m.can_attack():
				continue
			if target not in enemy.board or current_phase == Phase.GAME_OVER:
				break
			var m_shield := _get_shield_value(m)
			var t_shield := _get_shield_value(target)
			var m_amp := _get_enemy_damage_amp(owner_id)
			if not target.has_ability(Abilities.COMBAT_IMMUNE):
				_strike_minion(m, target, m_amp, t_shield, enemy)
			if not m.has_ability(Abilities.COMBAT_IMMUNE):
				m.take_damage(maxi(0, target.current_attack - m_shield))
			m.has_attacked = true
			Abilities.fire_on_attack(m, owner, self)
			_remove_dead_minions()
			if m in owner.board:
				_try_transform(m, owner)

	_check_win_condition()

## One attacker-to-minion hit, shared by attacks, the Dual Strike follow-up,
## and both challenge paths: damage after shields and amplify, Voidtouch's
## instant kill, then Trample spilling whatever exceeded the defender's health
## onto `defending`'s hero. Overkill is measured against health *before* the
## hit, so it reflects the damage that was actually wasted.
func _strike_minion(attacker: Minion, target: Minion, amp: int, target_shield: int, defending: PlayerState) -> void:
	var dealt := maxi(0, attacker.current_attack + amp - target_shield)
	var overkill := dealt - maxi(0, target.current_health)
	target.take_damage(dealt)
	if attacker.has_ability(Abilities.VOIDTOUCH):
		target.current_health = mini(target.current_health, 0)
	if overkill > 0 and attacker.has_ability(Abilities.TRAMPLE):
		defending.hero_health -= overkill

func apply_swap_friendly_health(minion_a: Minion, minion_b: Minion) -> void:
	var a_health := minion_a.current_health
	minion_a.current_health = mini(minion_b.current_health, minion_a.max_health)
	minion_b.current_health = mini(a_health, minion_b.max_health)
	_remove_dead_minions()

func apply_devour_friendly(devourer: Minion, target: Minion, owner: PlayerState) -> void:
	var gain := target.current_health
	owner.remove_minion(target)
	owner.graveyard.append(target.data)
	var pre := devourer.current_health
	devourer.max_health += gain
	devourer.current_health += gain
	_try_heal_to_draw(devourer, devourer.current_health - pre)
	_try_health_transform(devourer)

func apply_on_play_damage(target: Minion, damage: int, source_player_id: String = "") -> void:
	var amp := _get_enemy_damage_amp(source_player_id) if source_player_id != "" else 0
	target.take_damage(damage + amp)
	_remove_dead_minions()
	_check_win_condition()

## consume_pilot: false leaves pilot_minion on the board instead of sending it
## to the graveyard after applying its buff - used for Newt Nano's free
## on-play pilot (see ON_PLAY_PILOT_MECH callers), which shouldn't cost the
## card itself. A later *manual* use of the same minion's own pilot ability
## still consumes it as normal - callers pick true/false per call site, not
## per-card, since it's the trigger (on-play vs. manual) that differs.
func apply_pilot(pilot_minion: Minion, target_mech: Minion, pilot_owner: PlayerState, consume_pilot: bool = true) -> void:
	for ability in pilot_minion.abilities:
		if Abilities.is_pilot(ability):
			target_mech.current_attack += Abilities.get_pilot_attack(ability)
			var hp_bonus = Abilities.get_pilot_health(ability)
			var pre := target_mech.current_health
			target_mech.current_health += hp_bonus
			target_mech.max_health += hp_bonus
			_try_heal_to_draw(target_mech, target_mech.current_health - pre)
			target_mech.is_piloted = true
			target_mech.piloted_by = pilot_minion.data
			target_mech.pilot_atk_bonus = Abilities.get_pilot_attack(ability)
			target_mech.pilot_hp_bonus = hp_bonus
			if target_mech.has_ability(Abilities.ON_PILOTED_GAIN_RUSH):
				if Abilities.RUSH not in target_mech.abilities:
					target_mech.abilities.append(Abilities.RUSH)
				target_mech.is_exhausted = false
			if target_mech.has_ability(Abilities.ON_PILOTED_GAIN_CLOAKED):
				if Abilities.CLOAKED not in target_mech.abilities:
					target_mech.abilities.append(Abilities.CLOAKED)
			if pilot_minion.has_ability(Abilities.PILOT_GIVES_RUSH):
				if Abilities.RUSH not in target_mech.abilities:
					target_mech.abilities.append(Abilities.RUSH)
				target_mech.is_exhausted = false
			if pilot_minion.has_ability(Abilities.PILOT_GIVES_CLOAKED):
				if Abilities.CLOAKED not in target_mech.abilities:
					target_mech.abilities.append(Abilities.CLOAKED)
			if pilot_minion.has_ability(Abilities.PILOT_GIVES_GUARDIAN):
				if Abilities.GUARDIAN not in target_mech.abilities:
					target_mech.abilities.append(Abilities.GUARDIAN)
			if target_mech.has_ability(Abilities.ON_PILOTED_STAT_BOOST):
				target_mech.current_attack += 1
				var pre_boost := target_mech.current_health
				target_mech.current_health += 1
				target_mech.max_health += 1
				_try_heal_to_draw(target_mech, target_mech.current_health - pre_boost)
			if hp_bonus > 0:
				_try_apothecary_bonus(target_mech.owner_id, target_mech)
			_try_health_transform(target_mech)
			break
	if consume_pilot:
		pilot_owner.remove_minion(pilot_minion)
		pilot_owner.graveyard.append(pilot_minion.data)
		for m in pilot_owner.board:
			if m.has_ability(Abilities.ON_FRIENDLY_PILOT_DRAW):
				var drawn = pilot_owner.draw_card()
				if drawn != null and pilot_owner.player_id == player.player_id:
					pending_drawn_cards.append(drawn)

func apply_eject_pilot(target_mech: Minion, owner: PlayerState) -> Minion:
	if not target_mech.is_piloted or target_mech.piloted_by == null:
		return null
	target_mech.current_attack -= target_mech.pilot_atk_bonus
	target_mech.max_health -= target_mech.pilot_hp_bonus
	target_mech.current_health = max(1, target_mech.current_health - target_mech.pilot_hp_bonus)
	target_mech.is_piloted = false
	var pilot_data := target_mech.piloted_by
	target_mech.piloted_by = null
	target_mech.pilot_atk_bonus = 0
	target_mech.pilot_hp_bonus = 0
	if owner.has_room_for(pilot_data.abilities):
		var pilot_minion := Minion.new(pilot_data, owner.player_id)
		owner.place_minion(pilot_minion)
		return pilot_minion
	elif owner.hand.size() < PlayerState.MAX_HAND_SIZE:
		owner.hand.append(pilot_data)
	return null

func apply_transform_choice(minion: Minion, chosen_id: String) -> void:
	var new_data = CardDatabase.get_card(chosen_id)
	if new_data == null:
		return
	var damage_taken = minion.max_health - minion.current_health
	minion.data = new_data
	minion.current_attack = new_data.attack
	minion.max_health = new_data.health
	minion.current_health = max(1, new_data.health - damage_taken)
	minion.abilities = new_data.abilities.duplicate()
	reconcile_lasting_effects(minion.owner_id)
	if minion.has_ability(Abilities.RUSH):
		minion.is_exhausted = false
	minion.is_newly_transformed = true
	_try_mirror_transform(new_data, minion, _get_player_by_id(minion.owner_id))

func _try_health_transform(minion: Minion) -> void:
	for ability in minion.abilities:
		if not Abilities.is_transform_at_max_health(ability):
			continue
		if minion.max_health < Abilities.get_transform_health_threshold(ability):
			return
		if minion.data.transform_into.is_empty():
			return
		var new_data = CardDatabase.get_card(minion.data.transform_into)
		if new_data == null:
			return
		var damage_taken = minion.max_health - minion.current_health
		minion.data = new_data
		minion.current_attack = new_data.attack
		minion.max_health = new_data.health
		minion.current_health = max(1, new_data.health - damage_taken)
		minion.abilities = new_data.abilities.duplicate()
		reconcile_lasting_effects(minion.owner_id)
		if minion.has_ability(Abilities.RUSH):
			minion.is_exhausted = false
		minion.is_newly_transformed = true
		_try_mirror_transform(new_data, minion, _get_player_by_id(minion.owner_id))
		return

func _try_transform(minion: Minion, owner: PlayerState) -> void:
	for ability in minion.abilities:
		if not Abilities.is_transform(ability):
			continue
		if minion.transform_counter < Abilities.get_transform_threshold(ability):
			return
		if minion.data.transform_into.is_empty():
			return
		var new_data = CardDatabase.get_card(minion.data.transform_into)
		if new_data == null:
			return
		var damage_taken = minion.max_health - minion.current_health
		minion.data = new_data
		minion.current_attack = new_data.attack
		minion.max_health = new_data.health
		minion.current_health = max(1, new_data.health - damage_taken)
		minion.abilities = new_data.abilities.duplicate()
		reconcile_lasting_effects(minion.owner_id)
		minion.transform_counter = 0
		if minion.has_ability(Abilities.RUSH):
			minion.is_exhausted = false
		minion.is_newly_transformed = true
		_try_mirror_transform(new_data, minion, owner)
		return

func _apply_stratagem(card: CardData, target_minion: Minion,
					  target_player_id: String, acting_player_id: String = "") -> void:
	match card.effect:
		"deal_damage":
			if target_minion:
				var amp := _get_enemy_damage_amp(acting_player_id) if acting_player_id != "" else 0
				target_minion.take_damage(card.effect_value + amp)
				_remove_dead_minions()
			elif target_player_id != "":
				var target = _get_player_by_id(target_player_id)
				target.hero_health -= card.effect_value
				_check_win_condition()
		"buff_creature":
			if target_minion:
				target_minion.current_attack += card.effect_value
				var pre := target_minion.current_health
				target_minion.current_health += card.effect_value
				target_minion.max_health += card.effect_value
				_try_heal_to_draw(target_minion, target_minion.current_health - pre)
				_try_apothecary_bonus(target_minion.owner_id, target_minion)
				_try_health_transform(target_minion)
		"buff_health":
			if target_minion:
				var pre := target_minion.current_health
				target_minion.current_health += card.effect_value
				target_minion.max_health += card.effect_value
				_try_heal_to_draw(target_minion, target_minion.current_health - pre)
				_try_apothecary_bonus(target_minion.owner_id, target_minion)
				_try_health_transform(target_minion)
		"give_ability":
			if target_minion and not card.abilities.is_empty():
				var ability: String = card.abilities[0]
				if ability not in target_minion.abilities:
					target_minion.abilities.append(ability)
					# Granting Rush this way (e.g. Hot Garbage) has to also
					# clear is_exhausted itself, same as every other place
					# that grants it (apply_pilot(), apply_transform_choice(),
					# ...) - it's only ever set once, at Minion._init(), off
					# whatever abilities the minion started with, so a rush
					# grant that arrives later never gets picked up on its
					# own. Without this the target could still not attack
					# this turn even after "gaining" rush, making the card
					# look like it doesn't do anything.
					if ability == Abilities.RUSH:
						target_minion.is_exhausted = false
		"destroy_all_creatures":
			for p in [player, opponent]:
				for minion in p.board.duplicate():
					minion.current_health = 0
			_remove_dead_minions()
			_check_win_condition()
		"deal_damage_all_creatures":
			for p in [player, opponent]:
				for minion in p.board.duplicate():
					minion.take_damage(card.effect_value)
			_remove_dead_minions()
		"deal_damage_all_enemy":
			var acting := _get_player_by_id(acting_player_id)
			var enemy := opponent if acting == player else player
			var amp := _get_enemy_damage_amp(acting_player_id) if acting_player_id != "" else 0
			for minion in enemy.board.duplicate():
				minion.take_damage(card.effect_value + amp)
			_remove_dead_minions()
			_check_win_condition()
		"sludge_spray":
			var acting := _get_player_by_id(acting_player_id)
			var enemy := opponent if acting == player else player
			var amp := _get_enemy_damage_amp(acting_player_id) if acting_player_id != "" else 0
			var dmg := card.effect_value + card.rummage_count
			for minion in enemy.board.duplicate():
				minion.take_damage(dmg + amp)
			_remove_dead_minions()
			_check_win_condition()
		"buff_all_friendly_attack":
			if acting_player_id != "":
				var acting = _get_player_by_id(acting_player_id)
				for m in acting.board:
					m.current_attack += card.effect_value
		"buff_all_friendly_health":
			if acting_player_id != "":
				var acting := _get_player_by_id(acting_player_id)
				for m in acting.board:
					var pre := m.current_health
					m.current_health += card.effect_value
					m.max_health += card.effect_value
					_try_heal_to_draw(m, m.current_health - pre)
				for m in acting.board.duplicate():
					_try_apothecary_bonus(acting_player_id, m)
		"poke_bear":
			if target_minion:
				target_minion.take_damage(card.effect_value)
				_remove_dead_minions()
				_check_win_condition()
		"blood_transfusion":
			if target_minion:
				target_minion.take_damage(card.effect_value)
				_remove_dead_minions()
				_check_win_condition()
		"sanguine":
			if target_minion:
				target_minion.take_damage(card.effect_value)
				_remove_dead_minions()
				_check_win_condition()
		"exsanguinate":
			if target_minion:
				target_minion.take_damage(target_minion.current_health * card.effect_value)
				_remove_dead_minions()
				_check_win_condition()
		"blood_boil":
			if target_minion:
				var gain := target_minion.current_health * card.effect_value
				var pre := target_minion.current_health
				target_minion.current_health += gain
				target_minion.max_health += gain
				_try_heal_to_draw(target_minion, target_minion.current_health - pre)
				_try_apothecary_bonus(target_minion.owner_id, target_minion)
				_try_health_transform(target_minion)
		"tainted_blood":
			if target_minion:
				var acting := _get_player_by_id(acting_player_id)
				var enemy := opponent if acting == player else player
				enemy.hero_health -= target_minion.current_health / 2
				acting.remove_minion(target_minion)
				acting.graveyard.append(target_minion.data)
				_check_win_condition()
		"bloodlet":
			if target_minion:
				if target_minion.owner_id == acting_player_id:
					var pre := target_minion.current_health
					target_minion.current_health = mini(target_minion.current_health + card.effect_value, target_minion.max_health)
					_try_heal_to_draw(target_minion, target_minion.current_health - pre, 0)
					_try_apothecary_bonus(target_minion.owner_id, target_minion)
				else:
					var amp := _get_enemy_damage_amp(acting_player_id) if acting_player_id != "" else 0
					target_minion.take_damage(card.effect_value + amp)
					_remove_dead_minions()
					_check_win_condition()
			elif target_player_id != "":
				var target_p := _get_player_by_id(target_player_id)
				if target_player_id == acting_player_id:
					target_p.hero_health += card.effect_value
				else:
					target_p.hero_health -= card.effect_value
				_check_win_condition()
		"heal":
			if target_minion:
				var pre := target_minion.current_health
				if target_minion.current_health >= target_minion.max_health:
					target_minion.max_health += 1
					target_minion.current_health += 1
					_try_heal_to_draw(target_minion, 1)
					_try_apothecary_bonus(target_minion.owner_id, target_minion)
					_try_health_transform(target_minion)
				else:
					target_minion.current_health = min(target_minion.current_health + card.effect_value, target_minion.max_health)
					_try_heal_to_draw(target_minion, target_minion.current_health - pre, 0)
		EFFECT_RETURN_FRIENDLY:
			if target_minion != null:
				return_minion_to_hand(target_minion)
		EFFECT_DAMAGE_ENEMIES_DRAW_YETI:
			var acting := _get_player_by_id(acting_player_id)
			var enemy := opponent if acting == player else player
			var amp := _get_enemy_damage_amp(acting_player_id) if acting_player_id != "" else 0
			var struck: Array[Minion] = []
			for minion in enemy.board:
				if minion.data.card_type == CardData.CardType.CREATURE:
					struck.append(minion)
			for minion in struck:
				minion.take_damage(card.effect_value + amp)
			# Attribution is read at THIS checkpoint, before any removal runs a
			# deathrattle or Reinforce: a creature already at 0 here died to
			# this card's own damage. Comparing board sizes afterwards would
			# miss a death that Reinforce refilled, and would count one caused
			# by a later trigger.
			var directly_killed := false
			for minion in struck:
				if minion.is_dead():
					directly_killed = true
					break
			_remove_dead_minions()
			_check_win_condition()
			if directly_killed and current_phase != Phase.GAME_OVER:
				draw_random_yeti(acting)
		"eject_pilot":
			if target_minion != null and target_minion.is_piloted:
				apply_eject_pilot(target_minion, _get_player_by_id(acting_player_id))
		"eject_all_pilots":
			var acting := _get_player_by_id(acting_player_id)
			for minion in acting.board.duplicate():
				if minion.is_piloted:
					apply_eject_pilot(minion, acting)
		"give_mech_shielded_temp":
			if target_minion and target_minion.has_ability(Abilities.MECH):
				var ability := Abilities.SHIELDED + "_" + str(card.effect_value)
				for existing in target_minion.abilities.duplicate():
					if Abilities.is_shielded(existing):
						target_minion.abilities.erase(existing)
				target_minion.abilities.append(ability)
				temp_shielded.append({
					"instance_id": target_minion.instance_id,
					"ability": ability,
					"expires_after": _opponent_id(acting_player_id)
				})

## Takes one random Yeti out of `owner`'s deck and into their hand, using the
## match's own generator. No Yeti in the deck means nothing happens at all -
## no fallback draw, and no fatigue (this is a search, not a draw from an
## empty deck). A full hand burns the pick the way an ordinary draw does.
func draw_random_yeti(owner: PlayerState) -> CardData:
	var candidates: Array[CardData] = []
	for c in owner.deck:
		if c.card_type == CardData.CardType.CREATURE and Abilities.YETI in c.abilities:
			candidates.append(c)
	if candidates.is_empty():
		return null
	var chosen: CardData = rand_pick(candidates)
	owner.deck.erase(chosen)
	if owner.hand.size() >= PlayerState.MAX_HAND_SIZE:
		return null
	var card: CardData = chosen.new_instance(owner.mint_card_uid())
	owner.hand.append(card)
	if owner.player_id == player.player_id:
		pending_drawn_cards.append(card)
	return card

## Returns a creature from the board to its owner's hand. NOT a death: no
## deathrattle, no Reinforce, no rummage, no graveyard entry - the card simply
## changes zone and the creature stops existing.
##
## Lifecycle decisions (the rules had no bounce before this):
##  - The card keeps its identity (`card_uid`) and its rummage history. It
##    comes back in the form it currently has, so a transformed creature is
##    not undone. A one-off cost discount is not carried: replaying it costs
##    its normally applicable mana.
##  - Everything that lived on the Minion - damage, buffs, silence, granted or
##    temporary abilities, summoning state, aura grants - is gone with it.
##  - A remaining Reinforce budget is written onto the returned card, since
##    Minion.new() rebuilds abilities from the card: without that a half-spent
##    Commander Maurice would replay with a fresh four.
##  - An attached pilot is not lost or duplicated: it takes the creature's
##    place on the board (hand, then graveyard, if there is no room).
## Returns the card now in hand, or null if nothing moved.
func return_minion_to_hand(minion: Minion) -> CardData:
	var owner := find_player(minion.owner_id)
	if owner == null or minion not in owner.board:
		return null
	if owner.hand.size() >= PlayerState.MAX_HAND_SIZE:
		return null
	var index := owner.board.find(minion)
	owner.remove_minion(minion)

	var card: CardData = minion.data.clone_instance()
	card.uid = minion.card_uid if not minion.card_uid.is_empty() else owner.mint_card_uid()
	card.cost_modifier = 0
	var printed_reinforce := false
	for printed in minion.data.abilities:
		if Abilities.is_reinforce(printed):
			printed_reinforce = true
	if printed_reinforce:
		var kept: Array[String] = []
		for printed in card.abilities:
			if not Abilities.is_reinforce(printed):
				kept.append(printed)
		var left := Abilities.reinforce_ability(Abilities.reinforce_uses_of(minion))
		if not left.is_empty():
			kept.append(left)
		card.abilities = kept
	owner.hand.append(card)

	# Bookkeeping that names this creature by id and would otherwise dangle.
	var kept_shields: Array[Dictionary] = []
	for entry in temp_shielded:
		if entry["instance_id"] != minion.instance_id:
			kept_shields.append(entry)
	temp_shielded = kept_shields
	var kept_grants: Array[Dictionary] = []
	for entry in growvin_granted:
		if entry["instance_id"] != minion.instance_id:
			kept_grants.append(entry)
	growvin_granted = kept_grants

	if minion.is_piloted and minion.piloted_by != null:
		var pilot_card: CardData = minion.piloted_by
		if owner.has_room_for(pilot_card.abilities):
			var pilot_minion := Minion.new(pilot_card, owner.player_id)
			owner.place_minion(pilot_minion, mini(index, owner.board.size()))
		elif owner.hand.size() < PlayerState.MAX_HAND_SIZE:
			owner.hand.append(pilot_card)
		else:
			owner.graveyard.append(pilot_card)

	# The creature may have been an aura source.
	reconcile_lasting_effects(owner.player_id)
	return card

## Removes everything that has died and resolves its death triggers.
##
## Deaths are resolved in GROUPS, not one at a time. Each pass collects every
## creature that is lethal right now, removes the whole group from the board,
## and only then fires any of their death triggers. The pass repeats while
## those triggers kill more.
##
## That grouping is the rule, not an implementation detail. Resolving one
## death completely before looking at the next - which is what this used to do
## - meant an area-damage effect that left three creatures at 0 health could
## have the first one's deathrattle heal or buff the second back above 0
## before anything had checked it, so it never died. Whether a creature dies
## then depended on board order. Collecting the group first makes simultaneous
## lethal damage actually simultaneous: everything that was dead at the
## checkpoint dies, and nothing can be rescued out of the group afterwards.
##
## Order within a group (deterministic, so every mode agrees): the active
## player's creatures first, then the opponent's; within a board, left to
## right by board position. Positions are captured before any removal, so a
## trigger that cares where its creature died sees where it actually was.
func _remove_dead_minions() -> void:
	for _pass in 32:  # safety cap: a trigger loop must not hang the match
		# 1. Collect the group.
		var dying: Array[Dictionary] = []
		var first := _get_active_player()
		var second := opponent if first == player else player
		for p in [first, second]:
			for i in p.board.size():
				var m: Minion = p.board[i]
				if m.is_dead():
					dying.append({"minion": m, "owner": p, "index": i})
		if dying.is_empty():
			return

		# 2. Remove the whole group before any trigger runs.
		for entry in dying:
			var m: Minion = entry["minion"]
			var p: PlayerState = entry["owner"]
			p.remove_minion(m)
			p.graveyard.append(m.data)

		# 3. Only now resolve what each death triggers.
		for entry in dying:
			var minion: Minion = entry["minion"]
			var p: PlayerState = entry["owner"]
			var idx: int = entry["index"]
			var enemy := _get_player_by_id(_opponent_id(p.player_id))
			var death_result := Abilities.fire_on_death(minion, p, idx, enemy, self)
			if p.player_id == player.player_id:
				pending_drawn_cards.append_array(death_result["drawn"])
			for _i in death_result["tank_shots"]:
				pending_tank_shots.append(p.player_id)
			if minion.data.tribe == "tank":
				for watcher in p.board:
					if watcher.has_ability(Abilities.ON_FRIENDLY_TANK_DEATH_BUFF_TANK):
						pending_tank_specialist_buffs.append(p.player_id)
			# An aura source that just died stops granting (see
			# reconcile_lasting_effects); death is the third way a source can
			# stop qualifying, alongside silence and transformation.
			if minion.has_ability(Abilities.GROWVIN_AURA):
				reconcile_lasting_effects(p.player_id)

func _check_win_condition() -> void:
	if opponent.is_dead():
		winner_id = player.player_id
		current_phase = Phase.GAME_OVER
	elif player.is_dead():
		winner_id = opponent.player_id
		current_phase = Phase.GAME_OVER

func get_rummage_options(player_id: String, max_cost: int = -1, type_filter: String = "", allow_equal_cost: bool = false) -> Array[CardData]:
	var p = _get_player_by_id(player_id)
	var seen_ids: Array[String] = []
	var options: Array[CardData] = []
	for card in p.graveyard:
		if max_cost >= 0:
			if allow_equal_cost and card.cost > max_cost:
				continue
			elif not allow_equal_cost and card.cost >= max_cost:
				continue
		if type_filter == "creature" and card.card_type != CardData.CardType.CREATURE:
			continue
		if type_filter == "stratagem" and card.card_type != CardData.CardType.STRATAGEM:
			continue
		if type_filter == "mech" and Abilities.MECH not in card.abilities:
			continue
		if type_filter == "creature_nonlegendary":
			if card.card_type != CardData.CardType.CREATURE or card.rarity == CardData.CardRarity.LEGENDARY:
				continue
		if card.id not in seen_ids:
			seen_ids.append(card.id)
			options.append(card)
	return options

func complete_rummage(player_id: String, card: CardData, play_it: bool = false, discount: bool = true, buff_creature: bool = false) -> Minion:
	var p = _get_player_by_id(player_id)
	for i in p.graveyard.size():
		if p.graveyard[i].id == card.id:
			p.graveyard.remove_at(i)
			break
	# Salvager's +1/+1 rides on the CardData itself, so it sticks for the rest
	# of the match. Applied before anything below reads the card's stats.
	if buff_creature and card.card_type == CardData.CardType.CREATURE:
		card.attack += 1
		card.health += 1
	var has_stinkpile := false
	for m in p.board:
		if m.has_ability(Abilities.STINKPILE_PASSIVE):
			has_stinkpile = true
			break
	var placed: Minion = null
	if (has_stinkpile or play_it) and card.card_type == CardData.CardType.CREATURE and p.has_room_for(card.abilities):
		card.rummage_count += 1
		placed = Minion.new(card, player_id)
		p.place_minion(placed)
		Abilities.fire_on_play(placed, p, self)
	elif p.hand.size() < PlayerState.MAX_HAND_SIZE:
		if discount:
			card.cost_modifier = -1
		card.rummage_count += 1
		p.hand.append(card)
	Abilities.fire_on_rummage(p, self)
	return placed

func is_local_player_turn() -> bool:
	return active_player_id == player.player_id

## Deep copy for AI search simulation (distinct from to_net_dict/from_net_dict,
## which serve wire serialization). Safe for a search rollout to mutate freely
## without affecting the real match.
func duplicate_for_sim() -> GameState:
	var gs := GameState.new(player.player_id, opponent.player_id, [], [])
	gs.player = player.duplicate_for_sim()
	gs.opponent = opponent.duplicate_for_sim()
	gs.current_phase = current_phase
	gs.active_player_id = active_player_id
	gs.turn_number = turn_number
	gs.winner_id = winner_id
	# Not copied: these hold references to THIS state's own card objects
	# (they exist only to tell the UI what was just drawn). Carrying them
	# into a clone would leave the clone pointing at the parent's cards.
	gs.pending_drawn_cards = []
	gs.pending_fatigue_damage = pending_fatigue_damage.duplicate()
	gs.pending_rummages = pending_rummages.duplicate(true)
	gs.pending_tank_shots = pending_tank_shots.duplicate()
	gs.pending_nulls = pending_nulls.duplicate(true)
	gs.pending_overwatch_challenges = pending_overwatch_challenges.duplicate()
	gs.pending_buff_friendly_health = pending_buff_friendly_health.duplicate()
	gs.pending_tank_specialist_buffs = pending_tank_specialist_buffs.duplicate()
	gs.pending_on_reinforce_damages = pending_on_reinforce_damages.duplicate(true)
	gs.temp_shielded = temp_shielded.duplicate(true)
	gs.growvin_granted = growvin_granted.duplicate(true)
	gs.death_reinforce_used = death_reinforce_used.duplicate()
	gs.node_modifier_ability = node_modifier_ability
	gs._opening_hand_dealt = _opening_hand_dealt
	gs._first_turn_taken = _first_turn_taken.duplicate()
	# Copy the generator's POSITION, not just its seed: the clone has to
	# continue the same sequence the parent is partway through, and must then
	# advance on its own without touching the parent.
	gs.rng.seed = rng.seed
	gs.rng.state = rng.state
	gs.pending_choice = pending_choice.duplicate(true)
	gs._next_choice_id = _next_choice_id
	return gs

## Builds the view for ONE recipient: their own hand in full, the opponent's
## reduced to a count. Pass "" only for an internal dump where both sides are
## already known.
##
## This is a player VIEW, not a save. It omits deck contents and the match
## generator's state on purpose, so it cannot be used to resume a match - see
## the handoff's split between internal snapshots and per-player views.
func to_net_dict(for_player_id: String = "") -> Dictionary:
	var reveal_host := for_player_id.is_empty() or for_player_id == "host"
	var reveal_guest := for_player_id.is_empty() or for_player_id == "guest"
	var host_state: PlayerState = player if player.player_id == "host" else opponent
	var guest_state: PlayerState = opponent if player.player_id == "host" else player
	return {
		"phase": current_phase,
		"active_player_id": active_player_id,
		"turn_number": turn_number,
		"winner_id": winner_id,
		"host_state": host_state.to_net_dict(reveal_host),
		"guest_state": guest_state.to_net_dict(reveal_guest),
		"pending_choice": pending_choice.duplicate(true),
		"pending_rummages": pending_rummages.duplicate(true),
		"pending_tank_shots": pending_tank_shots.duplicate(),
		"pending_nulls": pending_nulls.duplicate(true),
		"pending_buff_friendly_health": pending_buff_friendly_health.duplicate(),
		"pending_tank_specialist_buffs": pending_tank_specialist_buffs.duplicate(),
		"pending_on_reinforce_damages": pending_on_reinforce_damages.duplicate(true),
		"pending_overwatch_challenges": pending_overwatch_challenges.duplicate(),
		"pending_drawn_cards": pending_drawn_cards.map(func(c): return c.id),
		"pending_fatigue_damage": pending_fatigue_damage.duplicate(),
	}

static func from_net_dict(d: Dictionary, my_id: String) -> GameState:
	var opp_id := "guest" if my_id == "host" else "host"
	var gs := GameState.new(my_id, opp_id, [], [])
	gs.player = PlayerState.from_net_dict(d["host_state"] if my_id == "host" else d["guest_state"])
	gs.opponent = PlayerState.from_net_dict(d["guest_state"] if my_id == "host" else d["host_state"])
	gs.current_phase = int(d["phase"])
	gs.active_player_id = str(d["active_player_id"])
	gs.turn_number = int(d["turn_number"])
	gs.winner_id = str(d.get("winner_id", ""))
	gs.pending_choice = (d.get("pending_choice", {}) as Dictionary).duplicate(true)
	gs.pending_rummages.clear()
	for r in d.get("pending_rummages", []):
		gs.pending_rummages.append(r)
	gs.pending_tank_shots.clear()
	for t in d.get("pending_tank_shots", []):
		gs.pending_tank_shots.append(str(t))
	gs.pending_nulls.clear()
	for n in d.get("pending_nulls", []):
		gs.pending_nulls.append(n)
	gs.pending_buff_friendly_health.clear()
	for b in d.get("pending_buff_friendly_health", []):
		gs.pending_buff_friendly_health.append(str(b))
	gs.pending_tank_specialist_buffs.clear()
	for b in d.get("pending_tank_specialist_buffs", []):
		gs.pending_tank_specialist_buffs.append(str(b))
	gs.pending_on_reinforce_damages.clear()
	for od in d.get("pending_on_reinforce_damages", []):
		gs.pending_on_reinforce_damages.append(od)
	gs.pending_overwatch_challenges.clear()
	for oc in d.get("pending_overwatch_challenges", []):
		gs.pending_overwatch_challenges.append(str(oc))
	gs.pending_drawn_cards.clear()
	for cid in d.get("pending_drawn_cards", []):
		var card = CardDatabase.get_card(str(cid))
		if card != null:
			gs.pending_drawn_cards.append(card)
	gs.pending_fatigue_damage.clear()
	for pid in d.get("pending_fatigue_damage", []):
		gs.pending_fatigue_damage.append(str(pid))
	gs._opening_hand_dealt = true
	return gs

func _try_apothecary_bonus(owner_id: String, target: Minion) -> void:
	var owner = _get_player_by_id(owner_id)
	for m in owner.board:
		if m.has_ability(Abilities.APOTHECARY):
			var pre := target.current_health
			target.current_health += 1
			target.max_health += 1
			_try_heal_to_draw(target, target.current_health - pre)
			return

## Crypt Hunger (Delos, cr_019): "When this creature gains health, lose it
## and draw a card." The gain is handed back, then a card is drawn.
##
## Handing it back has to revert exactly what was raised, which is why the
## caller states both deltas:
##  - `gained` is the rise in CURRENT health.
##  - `max_gained` is the rise in MAXIMUM health. It defaults to `gained`
##    because most callers are +N/+N style buffs (Apothecary, Supply Drop,
##    tank specialist) where both moved together and both must come back, so
##    the creature ends where it started and the drawn card is the effect.
##
## A pure heal - restoring damage, capped at the existing maximum - passes 0,
## because nothing raised the maximum and taking it away permanently shrank
## the creature. That was the bug: a 3-max/1-current Delos healed for 2 came
## out 1-max/1-current, and repeated healing ground it down to nothing.
func _try_heal_to_draw(target: Minion, gained: int, max_gained: int = -1) -> void:
	if gained <= 0 or not target.has_ability(Abilities.HEAL_TO_DRAW):
		return
	target.current_health -= gained
	target.max_health -= gained if max_gained < 0 else max_gained
	_get_player_by_id(target.owner_id).draw_card()

func _try_mirror_transform(new_data: CardData, transforming: Minion, owner: PlayerState) -> void:
	var candidates: Array[Minion] = []
	for m in owner.board:
		if m != transforming and m.has_ability(Abilities.MIRROR_TRANSFORM):
			candidates.append(m)
	for m in candidates:
		if m not in owner.board:
			continue
		var target_data: CardData = new_data
		if not m.data.transform_into.is_empty():
			var own_target = CardDatabase.get_card(m.data.transform_into)
			if own_target != null:
				target_data = own_target
		var damage_taken = m.max_health - m.current_health
		m.data = target_data
		m.current_attack = target_data.attack
		m.max_health = target_data.health
		m.current_health = max(1, target_data.health - damage_taken)
		m.abilities = target_data.abilities.duplicate()
		reconcile_lasting_effects(m.owner_id)
		if m.has_ability(Abilities.RUSH):
			m.is_exhausted = false
		m.is_newly_transformed = true

	if transforming in owner.board:
		for m in owner.board:
			if m != transforming and m.has_ability(Abilities.ON_FRIENDLY_TRANSFORM_GIVE_AMBUSH):
				if not transforming.has_ability(Abilities.AMBUSH):
					transforming.abilities.append(Abilities.AMBUSH)
		for m in owner.board:
			if m != transforming and m.has_ability(Abilities.ON_FRIENDLY_TRANSFORM_BUFF_SELF):
				m.current_attack += 1
				var pre := m.current_health
				m.current_health += 1
				m.max_health += 1
				_try_heal_to_draw(m, m.current_health - pre)
				_try_apothecary_bonus(owner.player_id, m)
				_try_health_transform(m)

## One creature healed by `amount`, capped at its existing maximum - the
## shape every "restore damage" effect shares. Split out so the rules (and
## tests) have a single pure-heal entry point rather than each caller
## open-coding the cap and the Crypt Hunger follow-up.
func _apply_rejuvenate_to(m: Minion, amount: int) -> void:
	restore_health(m, amount)

func _apply_rejuvenate(player_id: String) -> void:
	var owner := _get_player_by_id(player_id)
	var broodtender_active := owner.board.any(func(m): return m.has_ability(Abilities.BROODTENDER_AURA))
	for m in owner.board:
		var regen := 0
		for ab in m.abilities:
			if Abilities.is_rejuvenate(ab):
				regen = maxi(regen, Abilities.get_rejuvenate_value(ab))
				break
		if broodtender_active and m.has_ability(Abilities.MONSTROSITY):
			regen = maxi(regen, 2)
		if regen > 0:
			var pre := m.current_health
			m.current_health = mini(m.current_health + regen, m.max_health)
			var gained := m.current_health - pre
			if gained > 0:
				_try_heal_to_draw(m, gained, 0)
				_try_apothecary_bonus(player_id, m)

func _apply_feast_attendant(player_id: String) -> void:
	var owner := _get_player_by_id(player_id)
	for i in range(owner.board.size()):
		if not owner.board[i].has_ability(Abilities.FEAST_ATTENDANT):
			continue
		for j in [i - 1, i + 1]:
			if j < 0 or j >= owner.board.size():
				continue
			var neighbor: Minion = owner.board[j]
			var pre := neighbor.current_health
			neighbor.current_health += 1
			neighbor.max_health += 1
			_try_heal_to_draw(neighbor, neighbor.current_health - pre)
			_try_apothecary_bonus(player_id, neighbor)
			_try_health_transform(neighbor)

## Mech Station: tops the owner's mechs back up at end of turn. Two stations
## heal twice as much, same as any other stacking board effect here.
func _apply_mech_repair(player_id: String) -> void:
	var owner := _get_player_by_id(player_id)
	var heal := 0
	for m in owner.board:
		if m.has_ability(Abilities.END_TURN_HEAL_MECHS):
			heal += 2
	if heal == 0:
		return
	for m in owner.board:
		if not m.has_ability(Abilities.MECH):
			continue
		var pre := m.current_health
		m.current_health = mini(m.current_health + heal, m.max_health)
		var gained := m.current_health - pre
		if gained > 0:
			_try_heal_to_draw(m, gained, 0)
			_try_apothecary_bonus(player_id, m)

## Animus Hoarder: takes a point of health off a random enemy creature at end
## of turn and keeps it, so the hoarder grows every turn it survives.
func _apply_life_siphon(player_id: String) -> void:
	var owner := _get_player_by_id(player_id)
	var enemy := _get_player_by_id(_opponent_id(player_id))
	var drained := false
	for m in owner.board:
		if not m.has_ability(Abilities.END_TURN_DRAIN_RANDOM_ENEMY) or enemy.board.is_empty():
			continue
		var victim: Minion = rand_pick(enemy.board)
		victim.take_damage(1)
		drained = true
		var pre := m.current_health
		m.current_health += 1
		m.max_health += 1
		_try_heal_to_draw(m, m.current_health - pre)
		_try_apothecary_bonus(player_id, m)
		_try_health_transform(m)
	if drained:
		_remove_dead_minions()
		_check_win_condition()

## Tutkiun: end-of-turn discount on every Yeti still in hand. effective_cost()
## floors at 1, so this can't drive a card below one mana however long
## Tutkiun sticks around.
func _apply_yeti_discount(player_id: String) -> void:
	var owner := _get_player_by_id(player_id)
	var discount := 0
	for m in owner.board:
		if m.has_ability(Abilities.END_TURN_YETI_DISCOUNT):
			discount += 1
	if discount == 0:
		return
	for card in owner.hand:
		if Abilities.YETI in card.abilities:
			card.cost_modifier -= discount

func _expire_temp_shields_for(ending_player_id: String) -> void:
	var keep: Array[Dictionary] = []
	for entry in temp_shielded:
		if entry["expires_after"] == ending_player_id:
			var iid: String = entry["instance_id"]
			var ab: String = entry["ability"]
			for p in [player, opponent]:
				for m in p.board:
					if m.instance_id == iid:
						m.abilities.erase(ab)
		else:
			keep.append(entry)
	temp_shielded = keep

func _apply_growvin_aura_to_mech(mech: Minion, owner_id: String) -> void:
	for ab in [Abilities.CLOAKED, "shielded_1", "rejuvenate_1"]:
		if mech.has_ability(ab):
			continue
		if ab == "shielded_1" and _get_shield_value(mech) > 0:
			continue
		if ab == "rejuvenate_1":
			var has_regen := false
			for existing in mech.abilities:
				if Abilities.is_rejuvenate(existing):
					has_regen = true
					break
			if has_regen:
				continue
		mech.abilities.append(ab)
		growvin_granted.append({"instance_id": mech.instance_id, "ability": ab, "owner_id": owner_id})

## Re-checks every lasting contribution owned by `owner_id` and withdraws the
## ones whose source no longer qualifies. Call this after ANYTHING that can
## strip or replace a creature's abilities - silence, transformation, death -
## rather than leaving each of those paths to remember the bookkeeping.
## Safe to call when nothing changed: each withdrawal re-checks for a still-
## active source first.
func reconcile_lasting_effects(owner_id: String) -> void:
	_remove_growvin_aura(owner_id)

func _remove_growvin_aura(owner_id: String) -> void:
	for m in _get_player_by_id(owner_id).board:
		if m.has_ability(Abilities.GROWVIN_AURA):
			return
	var keep: Array[Dictionary] = []
	for entry in growvin_granted:
		if entry["owner_id"] != owner_id:
			keep.append(entry)
			continue
		var iid: String = entry["instance_id"]
		var ab: String = entry["ability"]
		for p in [player, opponent]:
			for m in p.board:
				if m.instance_id == iid:
					m.abilities.erase(ab)
	growvin_granted = keep

func _get_enemy_damage_amp(source_player_id: String) -> int:
	var total := 0
	for m in _get_player_by_id(source_player_id).board:
		for ability in m.abilities:
			if Abilities.is_enemy_damage_amp(ability):
				total += Abilities.get_enemy_damage_amp_value(ability)
	return total

func _get_shield_value(minion: Minion) -> int:
	for ability in minion.abilities:
		if Abilities.is_shielded(ability):
			return Abilities.get_shield_value(ability)
	return 0

func _get_active_player() -> PlayerState:
	return _get_player_by_id(active_player_id)

func _get_player_by_id(id: String) -> PlayerState:
	return player if id == player.player_id else opponent

func _opponent_id(id: String) -> String:
	return opponent.player_id if id == player.player_id else player.player_id
