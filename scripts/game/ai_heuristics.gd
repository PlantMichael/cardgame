class_name AIHeuristics
extends RefCounted

## Shared scoring and target-selection heuristics used by AIController,
## SimRunner, HeadlessTurn, and MCTSEngine. Consolidated here so trade/threat
## evaluation exists in exactly one place instead of being forked per caller.

# --- Combat scoring ---

## Score a trade: positive = worth doing, negative = avoid.
static func score_trade(attacker: Minion, target: Minion, game_state: GameState) -> int:
	if target.has_ability(Abilities.COMBAT_IMMUNE):
		return -999

	var target_shield := get_shield_value(target)
	var attacker_shield := get_shield_value(attacker)
	var attacker_amp := game_state._get_enemy_damage_amp(attacker.owner_id)

	var hits := 2 if attacker.has_ability(Abilities.DUAL_STRIKE) else 1
	var damage_to_target := maxi(0, attacker.current_attack + attacker_amp - target_shield) * hits

	var we_kill: bool
	if attacker.has_ability(Abilities.VOIDTOUCH):
		we_kill = true  # voidtouch sets target health to 0 regardless of shield
	else:
		we_kill = damage_to_target >= target.current_health

	var damage_to_us := maxi(0, target.current_attack - attacker_shield)
	var we_survive := attacker.current_health > damage_to_us

	if we_kill and we_survive:
		return target.current_attack * 2 + target.current_health + 10
	elif we_kill:
		var target_value   = target.current_attack   + target.current_health
		var attacker_value = attacker.current_attack + attacker.current_health
		return target_value - attacker_value + 1
	elif we_survive:
		return -5
	else:
		return -15

## How urgently should the acting side hit face right now?
static func face_pressure_score(hero_health: int, my_board_size: int, their_board_size: int) -> int:
	var score: int
	if hero_health <= 8:
		score = 30
	elif hero_health <= 12:
		score = 18
	elif hero_health <= 16:
		score = 8
	elif hero_health <= 20:
		score = 3
	else:
		score = 0
	if my_board_size > their_board_size + 1:
		score += 6
	return score

static func get_shield_value(minion: Minion) -> int:
	for ability in minion.abilities:
		if Abilities.is_shielded(ability):
			return Abilities.get_shield_value(ability)
	return 0

# --- Target selection ---

static func pick_best_removal_target(minions: Array[Minion], damage: int) -> Minion:
	if minions.is_empty():
		return null
	var best_kill: Minion = null
	var highest_attack: Minion = null
	for m in minions:
		if m.current_health <= damage:
			if best_kill == null or m.current_attack > best_kill.current_attack:
				best_kill = m
		if highest_attack == null or m.current_attack > highest_attack.current_attack:
			highest_attack = m
	return best_kill if best_kill != null else highest_attack

static func pick_challenge_target(minions: Array[Minion], challenger: Minion) -> Minion:
	var best_favorable: Minion = null
	var best_kill: Minion = null
	var highest_attack: Minion = null
	for m in minions:
		if m.has_ability(Abilities.AMBUSH):
			continue
		var we_kill    = challenger.current_attack >= m.current_health
		var we_survive = challenger.current_health > m.current_attack
		if we_kill and we_survive:
			if best_favorable == null or m.current_attack > best_favorable.current_attack:
				best_favorable = m
		elif we_kill:
			if best_kill == null or m.current_attack > best_kill.current_attack:
				best_kill = m
		if highest_attack == null or m.current_attack > highest_attack.current_attack:
			highest_attack = m
	if best_favorable != null: return best_favorable
	if best_kill      != null: return best_kill
	return highest_attack

static func pick_best_pilot_target(mechs: Array[Minion], pilot: Minion = null) -> Minion:
	var pilot_atk := 0
	var pilot_hp := 0
	if pilot != null:
		for ab in pilot.abilities:
			if Abilities.is_pilot(ab):
				pilot_atk = Abilities.get_pilot_attack(ab)
				pilot_hp  = Abilities.get_pilot_health(ab)
				break
	var best: Minion = null
	var best_score := -999
	for m in mechs:
		var score := (m.current_attack + pilot_atk) + (m.current_health + pilot_hp)
		if m.has_ability(Abilities.ON_PILOTED_GAIN_RUSH) or \
				(pilot != null and pilot.has_ability(Abilities.PILOT_GIVES_RUSH)):
			score += 4
		if m.has_ability(Abilities.ON_PILOTED_GAIN_CLOAKED) or \
				(pilot != null and pilot.has_ability(Abilities.PILOT_GIVES_CLOAKED)):
			score += 2
		if pilot != null and pilot.has_ability(Abilities.PILOT_GIVES_GUARDIAN):
			score += 3
		if m.has_ability(Abilities.ON_PILOTED_STAT_BOOST):
			score += 2
		if score > best_score:
			best_score = score
			best = m
	return best

## Mulligan heuristic for the AI's opening hand: swap out anything costing 5
## or more mana - a simple stand-in for "keep a low curve" without pulling in
## full hand-evaluation logic just for this one-time decision.
const MULLIGAN_COST_THRESHOLD := 5

static func pick_mulligan_swaps(hand: Array[CardData]) -> Array[CardData]:
	var swaps: Array[CardData] = []
	for card in hand:
		if card.effective_cost() >= MULLIGAN_COST_THRESHOLD:
			swaps.append(card)
	return swaps

static func pick_strongest(minions: Array[Minion]) -> Minion:
	return minions.reduce(func(a, b): return a if a.current_attack > b.current_attack else b)

static func pick_lowest_health(minions: Array[Minion]) -> Minion:
	return minions.reduce(func(a, b): return a if a.current_health < b.current_health else b)

static func pick_highest_health(minions: Array[Minion]) -> Minion:
	return minions.reduce(func(a, b): return a if a.current_health > b.current_health else b)

## Priority target for "give a friendly minion health" effects: a Heal-to-Draw
## minion turns any health gain into a free card (always take it), then a
## Transform-at-max-health minion closest to its threshold (push the payoff),
## then fall back to protecting the weakest body on board.
static func pick_health_buff_target(minions: Array[Minion]) -> Minion:
	if minions.is_empty():
		return null
	for m in minions:
		if m.has_ability(Abilities.HEAL_TO_DRAW):
			return m
	var best_transform: Minion = null
	var best_gap := 999
	for m in minions:
		for ab in m.abilities:
			if Abilities.is_transform_at_max_health(ab):
				var gap: int = Abilities.get_transform_health_threshold(ab) - m.max_health
				if gap >= 0 and gap < best_gap:
					best_gap = gap
					best_transform = m
				break
	if best_transform != null:
		return best_transform
	return pick_lowest_health(minions)

# --- State evaluation (search leaf scoring) ---

## Static board-state evaluator used by MCTSEngine to score a position once a
## search has stopped looking ahead (either at a rollout depth limit or a
## finished game). Higher is better for `ai_player_id`.
static func evaluate_state(gs: GameState, ai_player_id: String) -> float:
	if gs.current_phase == GameState.Phase.GAME_OVER and gs.winner_id != "":
		return 100000.0 if gs.winner_id == ai_player_id else -100000.0

	var me: PlayerState = gs.player if ai_player_id == gs.player.player_id else gs.opponent
	var enemy: PlayerState = gs.opponent if me == gs.player else gs.player

	var score := 0.0
	score += _hero_health_value(me.hero_health) - _hero_health_value(enemy.hero_health)

	var my_board_power := 0.0
	for m in me.board:
		my_board_power += m.current_attack * 1.5 + m.current_health
	var enemy_board_power := 0.0
	for m in enemy.board:
		enemy_board_power += m.current_attack * 1.5 + m.current_health
	score += my_board_power - enemy_board_power

	score += (me.hand.size() - enemy.hand.size()) * 3.0

	if gs.active_player_id == me.player_id:
		score -= (me.max_mana - me.current_mana) * 0.5

	return score

## Losing health matters little from full to ~half; a lot in lethal range, so
## the search values racing/stabilizing much more once either hero is low.
static func _hero_health_value(hp: int) -> float:
	var clamped := maxf(0.0, float(hp))
	return clamped + maxf(0.0, 15.0 - clamped) * 2.0
