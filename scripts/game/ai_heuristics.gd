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
	# A location can't hit back, so chipping one costs nothing but the swing.
	# Rated just above the -5 "pointless attack" default (and below any real
	# trade or a lethal face push) so the AI actually works enemy locations
	# down instead of ignoring their passive buff all game.
	elif target.is_location():
		return 2
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
## Picks the answer for the choice that is open on `gs`, from the options the
## rules core listed. This is POLICY, not rules: it may only choose among the
## options (or decline when the choice allows it), never widen or narrow them.
##
## One policy serves the live AI, the search's rollouts and the greedy
## completion, so a decision the AI makes is the same wherever it is made.
## Returns "" to decline.
static func _fallback_choice_answer(gs: GameState, choice: Dictionary) -> String:
	var options: Array = choice["options"]
	if options.is_empty():
		return ""
	var actor_id := str(choice["player_id"])
	var amount := int(choice["amount"])
	var source := gs.find_minion(str(choice["source_instance_id"]))
	var minions: Array[Minion] = []
	var enemy_minions: Array[Minion] = []
	var friendly_minions: Array[Minion] = []
	for o in options:
		var m := gs.find_minion(str(o))
		if m != null:
			minions.append(m)
			if m.owner_id == actor_id:
				friendly_minions.append(m)
			else:
				enemy_minions.append(m)
	var enemy_id := gs._opponent_id(actor_id)
	var pick: Minion = null
	match str(choice["effect"]):
		GameState.CHOICE_RESTORE_HEALTH:
			# The most wounded creature gains the most from it.
			for m in minions:
				if pick == null or (m.max_health - m.current_health) > (pick.max_health - pick.current_health):
					pick = m
		GameState.CHOICE_BUFF_OTHER_FRIENDLY, GameState.CHOICE_BUFF_HEALTH_TARGET, GameState.CHOICE_HEAL_BUFF_TARGET:
			pick = pick_health_buff_target(minions)
		GameState.CHOICE_DAMAGE_HIGH_ATTACK:
			# Prefer something the damage actually kills; else the biggest attacker.
			for m in minions:
				if m.current_health <= amount and (pick == null or m.current_attack > pick.current_attack):
					pick = m
			if pick == null:
				for m in minions:
					if pick == null or m.current_attack > pick.current_attack:
						pick = m
		GameState.CHOICE_DAMAGE_TARGET:
			if not enemy_minions.is_empty():
				pick = pick_best_removal_target(enemy_minions, amount)
			if pick == null:
				if GameState.hero_option(enemy_id) in options:
					return GameState.hero_option(enemy_id)
				return ""
		GameState.CHOICE_CHALLENGE:
			pick = pick_challenge_target(enemy_minions, source) if source != null else null
		GameState.CHOICE_PICK_CHALLENGER:
			for m in friendly_minions:
				if pick == null or m.current_attack > pick.current_attack:
					pick = m
		GameState.CHOICE_PILOT_TARGET:
			pick = pick_best_pilot_target(friendly_minions, source)
		GameState.CHOICE_SWAP_HEALTH:
			var cands: Array[Minion] = friendly_minions.duplicate()
			cands.sort_custom(func(a, b): return a.current_attack > b.current_attack)
			if cands.size() >= 2:
				var recipient: Minion = cands[0]
				var donor: Minion = cands[cands.size() - 1]
				if int(choice["step"]) <= 1:
					# Give health to the most valuable creature from the least valuable.
					if donor.current_health > recipient.current_health:
						pick = recipient
				else:
					pick = donor
			elif int(choice["step"]) > 1 and cands.size() == 1:
				pick = cands[0]
		GameState.CHOICE_DEVOUR:
			# Sacrifice the least valuable creature.
			for m in friendly_minions:
				if pick == null or m.current_attack + m.current_health < pick.current_attack + pick.current_health:
					pick = m
		GameState.CHOICE_TRANSFORM:
			var best_id := str(options[0])
			var best_score := -1
			for cid in options:
				var cd := CardDatabase.get_card(str(cid))
				if cd != null and cd.attack + cd.health > best_score:
					best_score = cd.attack + cd.health
					best_id = str(cid)
			return best_id
		GameState.CHOICE_RUMMAGE:
			var best_card := str(options[0])
			var best_cost := -1
			for cid in options:
				var cd := CardDatabase.get_card(str(cid))
				if cd != null and cd.cost > best_cost:
					best_cost = cd.cost
					best_card = str(cid)
			return best_card
		GameState.CHOICE_NULL_TARGET:
			for m in enemy_minions:
				if pick == null or m.abilities.size() > pick.abilities.size():
					pick = m
		GameState.CHOICE_TANK_BUFF_TARGET:
			for m in friendly_minions:
				if pick == null or m.current_attack + m.current_health > pick.current_attack + pick.current_health:
					pick = m
		_:
			pick = minions[0] if not minions.is_empty() else null
	return pick.instance_id if pick != null else ""

## Compare the actual results of every offered choice, not a card/target
## priority list. This cheap policy completes rollouts; MCTS still branches
## over all choices and can see payoffs beyond the immediate state.
static func pick_choice_answer(gs: GameState, choice: Dictionary) -> String:
	if str(choice["effect"]) == GameState.CHOICE_OPENING_BONUS:
		var ones := 0
		var twos := 0
		for card in gs.find_player(str(choice["player_id"])).hand:
			if card.effective_cost() == 1: ones += 1
			if card.effective_cost() == 2: twos += 1
		return "coin" if twos >= 2 else ("token" if ones >= 2 else "five_cards")
	var preferred := _fallback_choice_answer(gs, choice)
	var selections: Array = [preferred]
	for selection in choice["options"]:
		if selection not in selections:
			selections.append(selection)
	if bool(choice["allow_none"]) and "" not in selections:
		selections.append("")
	var best := preferred
	var best_value := -INF
	for selection in selections:
		var after := gs.duplicate_for_sim()
		var result := after.execute({"type": GameState.CMD_ANSWER_CHOICE, "actor": str(choice["player_id"]),
			"choice_id": str(choice["id"]), "selection": str(selection)})
		if not result["ok"]:
			continue
		var value := evaluate_state(after, str(choice["player_id"]))
		if value > best_value:
			best_value = value
			best = str(selection)
	return best

static func evaluate_state(gs: GameState, ai_player_id: String, style: String = "") -> float:
	if gs.current_phase == GameState.Phase.GAME_OVER and gs.winner_id != "":
		return 100000.0 if gs.winner_id == ai_player_id else -100000.0

	var me: PlayerState = gs.player if ai_player_id == gs.player.player_id else gs.opponent
	var enemy: PlayerState = gs.opponent if me == gs.player else gs.player

	var score := 0.0
	score += _hero_health_value(me.hero_health) - _hero_health_value(enemy.hero_health)

	var my_board_power := 0.0
	for m in me.board:
		my_board_power += _minion_value(m)
	var enemy_board_power := 0.0
	for m in enemy.board:
		enemy_board_power += _minion_value(m)
	score += my_board_power - enemy_board_power

	score += _hand_value(me) - enemy.hand.size() * 3.0
	score += _retrieval_value(me) - _retrieval_value(enemy, false)

	if gs.active_player_id == me.player_id:
		score -= (me.max_mana - me.current_mana) * 0.5

	match style:
		"tempo":
			# Board advantage and using the current turn's mana outrank chip damage.
			score += (my_board_power - enemy_board_power) * 0.9
			if gs.active_player_id == me.player_id:
				score -= (me.max_mana - me.current_mana) * 1.5
		"aggro":
			# Race the opposing hero; tolerate damage to our own hero to keep pressure.
			score += (30 - enemy.hero_health) * 3.5 - (30 - me.hero_health) * 0.25
			for m in me.board:
				score += m.current_attack * 0.8
		"combo":
			score += _combo_value(me) - _combo_value(enemy) * 0.35
	return score

## Reward supported pairs, not merely a hand full of expensive cards. A live
## payoff is more valuable than holding it; a held enabler still has option value.
static func _combo_value(p: PlayerState) -> float:
	var bodies: Array[Minion] = p.board
	var score := 0.0
	for i in bodies.size():
		for j in range(i + 1, bodies.size()):
			score += _combo_pair(bodies[i], bodies[j]) * 12.0
	for card in p.hand:
		for body in bodies:
			score += _combo_pair(card, body) * 4.0
	return score

static func _combo_pair(a, b) -> float:
	return _combo_direction(a, b) + _combo_direction(b, a)

static func _combo_direction(enabler, payoff) -> float:
	var tags: Array[String] = enabler.abilities.duplicate()
	if enabler is CardData and not enabler.effect.is_empty():
		tags.append(enabler.effect)
	var health_gain := tags.any(func(t): return "buff" in t and "health" in t or t in ["heal", "blood_boil", "blood_transfusion", "sanguine"])
	var score := 0.0
	for ability in payoff.abilities:
		if health_gain and (ability == Abilities.HEAL_TO_DRAW or Abilities.is_transform_at_max_health(ability)):
			score += 1.0
		if ability.begins_with("on_friendly_") and ability.contains("mech") and Abilities.MECH in tags:
			score += 0.7
		if ability.begins_with("on_friendly_") and ability.contains("yeti") and Abilities.YETI in tags:
			score += 0.7
		if ability.begins_with("on_piloted_") and tags.any(func(t): return Abilities.is_pilot(t)):
			score += 1.0
		if ability.begins_with("on_friendly_transform") and tags.any(func(t): return t.contains("transform")):
			score += 1.0
	return score

## Losing health matters little from full to ~half; a lot in lethal range, so
## the search values racing/stabilizing much more once either hero is low.
static func _hero_health_value(hp: int) -> float:
	var clamped := maxf(0.0, float(hp))
	return clamped - maxf(0.0, 15.0 - clamped) * 2.0

## Persistent mechanics are worth more than vanilla stats; an on-play effect
## already spent is not counted again as board value.
static func _minion_value(m: Minion) -> float:
	var value := m.current_attack * 1.5 + m.current_health
	if m.has_ability(Abilities.DUAL_STRIKE):
		value += m.current_attack * 1.5
	if m.has_ability(Abilities.VOIDTOUCH):
		value += 3.0
	if m.has_ability(Abilities.COMBAT_IMMUNE):
		value += m.current_attack * 2.0
	value += get_shield_value(m) * 1.5
	for ability in m.abilities:
		if ability in [Abilities.RUMMAGE_DRAW, Abilities.HEAL_TO_DRAW, Abilities.ATTACK_RUMMAGE,
			Abilities.GROWVIN_AURA, Abilities.BROODTENDER_AURA, Abilities.TACTICAL_OFFICER]:
			value += 4.0
		elif ability.begins_with("deathrattle_") or ability == Abilities.RUMMAGE_ON_DEATH:
			value += 2.0
	return value

## Public graveyard resources matter only alongside an available retrieval
## source. Credit at most the best accessible replay, not every dead card as
## if it were already in hand. The search must still execute the real chain.
static func _card_potential(card: CardData) -> float:
	var value := card.attack * 1.5 + card.health
	for ab in card.abilities:
		if ab.begins_with("on_play_damage_"):
			value += float(ab.get_slice("_", 3)) * 2.5
	return value

static func _hand_value(p: PlayerState) -> float:
	var value := p.hand.size() * 3.0
	for card in p.hand:
		if p.can_play_card(card):
			value += minf(3.0, _card_potential(card) * 0.2)
	return value

static func _retrieval_value(p: PlayerState, include_hand: bool = true) -> float:
	var best := 0.0
	var sources: Array[CardData] = []
	if include_hand:
		for card in p.hand:
			if p.can_play_card(card):
				sources.append(card)
	for m in p.board:
		# A battlecry already spent on the board is not a future retrieval.
		if p.hand.size() < PlayerState.MAX_HAND_SIZE and m.abilities.any(func(ab): return ab in [Abilities.RUMMAGE_ON_DEATH, Abilities.ATTACK_RUMMAGE]):
			sources.append(m.data)
	for source in sources:
		var retrieves := source.abilities.any(func(ab): return ab in [Abilities.RUMMAGE,
			Abilities.RUMMAGE_ON_DEATH, Abilities.ATTACK_RUMMAGE, Abilities.RUMMAGE_AND_PLAY,
			Abilities.RUMMAGE_BUFF_CREATURE])
		if not retrieves:
			continue
		for card in p.graveyard:
			if card.cost >= source.cost or card.card_type != CardData.CardType.CREATURE:
				continue
			# A possible retrieval must be worth less than an actual hand card.
			best = maxf(best, minf(2.0, _card_potential(card) * 0.25))
	return best
