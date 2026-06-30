class_name AIController
extends Node

const THINK_DELAY = 0.6

func take_turn(game_state: GameState, board: Board) -> void:
	await _play_cards(game_state, board)
	await _attack_phase(game_state, board)

# --- Card playing ---

func _play_cards(game_state: GameState, board: Board) -> void:
	var played = true
	while played:
		played = false
		var hand = game_state.opponent.hand.duplicate()
		hand.sort_custom(func(a: CardData, b: CardData) -> bool:
			# Rush creatures that can kill a guardian go first
			if not game_state.player.get_guardian_minions().is_empty():
				var a_rush = _can_rush_kill_guardian(a, game_state)
				var b_rush = _can_rush_kill_guardian(b, game_state)
				if a_rush != b_rush:
					return a_rush
			# Deprioritize pilots that have no mech target yet so mechs play first
			var a_blocked := _is_pilot_without_target(a, game_state)
			var b_blocked := _is_pilot_without_target(b, game_state)
			if a_blocked != b_blocked:
				return not a_blocked
			return a.cost > b.cost
		)
		for card in hand:
			if not game_state.opponent.can_play_card(card):
				continue
			if card.card_type == CardData.CardType.CREATURE:
				if game_state.opponent.board.size() < PlayerState.MAX_BOARD_SIZE:
					await get_tree().create_timer(THINK_DELAY).timeout
					var new_minion = game_state.play_creature(game_state.opponent.player_id, card)
					board.log_action("Opponent played %s" % card.card_name)
					board.refresh()
					if new_minion:
						await _handle_on_play_effects(new_minion, game_state, board)
					played = true
					break
			elif card.card_type == CardData.CardType.STRATAGEM:
				var pick = _pick_stratagem_targets(card, game_state)
				if not pick["ready"]:
					continue
				await get_tree().create_timer(THINK_DELAY).timeout
				game_state.play_stratagem(game_state.opponent.player_id, card, pick["minion"], pick["player_id"])
				board.log_action("Opponent played %s" % card.card_name)
				if pick["minion"] != null:
					var _as_died: bool = pick["minion"] not in game_state.player.board and pick["minion"] not in game_state.opponent.board
					if _as_died:
						var _as_tgt: Card = board.find_card_node(pick["minion"].instance_id)
						if _as_tgt != null:
							var _as_from: Vector2 = _as_tgt.get_parent().get_global_rect().get_center() + Vector2(0, -600)
							await board.animate_laser_kill(_as_from, _as_tgt)
				board.refresh()
				if card.effect in ["force_challenge", "poke_bear"] and pick["minion"] != null:
					var yeti: Minion = pick["minion"]
					if yeti in game_state.opponent.board and yeti.has_ability(Abilities.YETI) and not game_state.player.board.is_empty():
						var challenge_target = _pick_challenge_target(game_state.player.board.duplicate(), yeti)
						if challenge_target != null:
							await get_tree().create_timer(THINK_DELAY).timeout
							board.log_action("Opponent's %s challenged your %s" % [yeti.data.card_name, challenge_target.data.card_name])
							game_state.apply_challenge(yeti, challenge_target)
							await board.animate_creature_challenge(yeti.instance_id, game_state.opponent.player_id, challenge_target.instance_id)
							board.refresh()
							if card.effect == "force_challenge" and card.effect_value > 0 and challenge_target.is_dead() and yeti in game_state.opponent.board:
								var win_buff: int = card.effect_value
								yeti.current_attack += win_buff
								yeti.current_health += win_buff
								yeti.max_health += win_buff
								board.log_action("Opponent's %s won and gained +%d/+%d!" % [yeti.data.card_name, win_buff, win_buff])
								board.refresh()
				if card.effect == "blood_transfusion" and not game_state.opponent.board.is_empty():
					var recipient = _pick_strongest(game_state.opponent.board.duplicate())
					board.log_action("Opponent's Blood Transfusion gave %s +2 health" % recipient.data.card_name)
					game_state.apply_heal_buff(recipient, 2)
					board.refresh()
				if card.effect == "sanguine" and not game_state.opponent.board.is_empty():
					var candidates: Array[Minion] = []
					for m in game_state.opponent.board:
						if m != pick["minion"]:
							candidates.append(m)
					if not candidates.is_empty():
						var recipient = _pick_strongest(candidates)
						board.log_action("Opponent's Sanguine gave %s +2 health" % recipient.data.card_name)
						game_state.apply_heal_buff(recipient, 2)
						board.refresh()
				played = true
				break

func _can_rush_kill_guardian(card: CardData, game_state: GameState) -> bool:
	if card.card_type != CardData.CardType.CREATURE or Abilities.RUSH not in card.abilities:
		return false
	for g in game_state.player.get_guardian_minions():
		if card.attack >= g.current_health:
			return true
	return false

func _handle_on_play_effects(new_minion: Minion, game_state: GameState, board: Board) -> void:
	for ability in new_minion.abilities:
		if Abilities.is_on_play_damage(ability):
			var damage = Abilities.get_on_play_damage_value(ability)
			var target = _pick_best_removal_target(game_state.player.board, damage)
			if target != null:
				board.log_action("Opponent's %s dealt %d damage to your %s" % [new_minion.data.card_name, damage, target.data.card_name])
				game_state.apply_on_play_damage(target, damage, new_minion.owner_id)
				var _ai_died: bool = target not in game_state.player.board and target not in game_state.opponent.board
				if _ai_died:
					var _ai_src: Card = board.find_card_node(new_minion.instance_id)
					var _ai_tgt: Card = board.find_card_node(target.instance_id)
					if _ai_src != null and _ai_tgt != null:
						await board.animate_laser_kill(_ai_src.get_parent().get_global_rect().get_center(), _ai_tgt)
			else:
				board.log_action("Opponent's %s dealt %d damage to your hero" % [new_minion.data.card_name, damage])
				game_state.player.hero_health -= damage
				game_state._check_win_condition()
			board.refresh()
			break

	if new_minion.has_ability(Abilities.CHALLENGE) and not game_state.player.board.is_empty():
		var target = _pick_challenge_target(game_state.player.board, new_minion)
		if target != null:
			board.log_action("Opponent's %s challenged your %s" % [new_minion.data.card_name, target.data.card_name])
			game_state.apply_challenge(new_minion, target)
			await board.animate_creature_challenge(new_minion.instance_id, game_state.opponent.player_id, target.instance_id)
			board.refresh()
	if new_minion.has_ability(Abilities.CHALLENGE_ALL) and not game_state.player.board.is_empty():
		var enemies := game_state.player.board.duplicate()
		for enemy in enemies:
			if new_minion.is_dead() or new_minion not in game_state.opponent.board:
				break
			if enemy not in game_state.player.board or enemy.has_ability(Abilities.AMBUSH):
				continue
			board.log_action("Opponent's %s challenged your %s" % [new_minion.data.card_name, enemy.data.card_name])
			game_state.apply_challenge(new_minion, enemy)
			await board.animate_creature_challenge(new_minion.instance_id, game_state.opponent.player_id, enemy.instance_id)
			board.refresh()
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				return

	if new_minion.has_ability(Abilities.ON_PLAY_CHALLENGE_WIN_BUFF) and not game_state.player.board.is_empty():
		var target = _pick_challenge_target(game_state.player.board, new_minion)
		if target != null:
			board.log_action("Opponent's %s challenged your %s" % [new_minion.data.card_name, target.data.card_name])
			game_state.apply_challenge(new_minion, target)
			await board.animate_creature_challenge(new_minion.instance_id, game_state.opponent.player_id, target.instance_id)
			board.refresh()
		if target != null and new_minion in game_state.opponent.board and target not in game_state.player.board:
			new_minion.current_attack += 1
			new_minion.current_health += 1
			new_minion.max_health += 1
			board.log_action("Opponent's %s won and gained +1/+1!" % new_minion.data.card_name)
			board.refresh()

	if new_minion.has_ability(Abilities.ON_PLAY_YETI_CHALLENGE) and not game_state.player.board.is_empty():
		var friendly_yeti: Minion = null
		for m in game_state.opponent.board:
			if m != new_minion and m.has_ability(Abilities.YETI):
				friendly_yeti = m
				break
		if friendly_yeti != null:
			var target = _pick_challenge_target(game_state.player.board, friendly_yeti)
			if target != null:
				board.log_action("Opponent's %s challenged your %s" % [friendly_yeti.data.card_name, target.data.card_name])
				game_state.apply_challenge(friendly_yeti, target)
				await board.animate_creature_challenge(friendly_yeti.instance_id, game_state.opponent.player_id, target.instance_id)
				board.refresh()

	if new_minion.has_ability(Abilities.ON_PLAY_TRANSFORM_CHOICE) and not new_minion.data.transform_choices.is_empty():
		var best_id: String = new_minion.data.transform_choices[0]
		var best_score := -1
		for cid in new_minion.data.transform_choices:
			var cd: CardData = CardDatabase.get_card(cid)
			if cd != null:
				var score = cd.attack + cd.health
				if score > best_score:
					best_score = score
					best_id = cid
		await get_tree().create_timer(THINK_DELAY).timeout
		board.log_action("Opponent's %s transformed" % new_minion.data.card_name)
		game_state.apply_transform_choice(new_minion, best_id)
		board.refresh()

	for ability in new_minion.abilities:
		if Abilities.is_pilot(ability):
			var mechs: Array[Minion] = []
			for m in game_state.opponent.board:
				if m != new_minion and m.has_ability(Abilities.MECH) and not m.is_piloted:
					mechs.append(m)
			if not mechs.is_empty():
				var mech_target = _pick_best_pilot_target(mechs, new_minion)
				await get_tree().create_timer(THINK_DELAY).timeout
				board.log_action("Opponent's %s piloted %s" % [new_minion.data.card_name, mech_target.data.card_name])
				game_state.apply_pilot(new_minion, mech_target, game_state.opponent)
				board.refresh()
			break

	if new_minion.has_ability(Abilities.ON_PLAY_DEVOUR_FRIENDLY):
		var candidates: Array[Minion] = []
		for m in game_state.opponent.board:
			if m != new_minion:
				candidates.append(m)
		if not candidates.is_empty():
			# sacrifice least-valuable minion (lowest attack+health)
			var target: Minion = candidates[0]
			for m in candidates:
				if m.current_attack + m.current_health < target.current_attack + target.current_health:
					target = m
			await get_tree().create_timer(THINK_DELAY).timeout
			board.log_action("Opponent's %s devoured %s" % [new_minion.data.card_name, target.data.card_name])
			game_state.apply_devour_friendly(new_minion, target, game_state.opponent)
			board.refresh()

	if new_minion.has_ability(Abilities.ON_PLAY_SWAP_FRIENDLY_HEALTH):
		var candidates: Array[Minion] = []
		for m in game_state.opponent.board:
			if m != new_minion:
				candidates.append(m)
		if candidates.size() >= 2:
			# give health to most valuable (highest attack) damaged minion from least valuable
			candidates.sort_custom(func(a, b): return a.current_attack > b.current_attack)
			var recipient: Minion = candidates[0]
			var donor: Minion = candidates[candidates.size() - 1]
			if donor.current_health > recipient.current_health:
				await get_tree().create_timer(THINK_DELAY).timeout
				board.log_action("Opponent swapped health of %s and %s" % [recipient.data.card_name, donor.data.card_name])
				game_state.apply_swap_friendly_health(recipient, donor)
				board.refresh()

func _pick_stratagem_targets(card: CardData, game_state: GameState) -> Dictionary:
	var result = {"ready": false, "minion": null, "player_id": ""}
	var player_targetable: Array[Minion] = []
	for m in game_state.player.board:
		if not m.has_ability(Abilities.CLOAKED) and not m.has_ability(Abilities.AMBUSH):
			player_targetable.append(m)
	var opponent_targetable: Array[Minion] = []
	for m in game_state.opponent.board:
		opponent_targetable.append(m)
	match card.effect:
		"deal_damage":
			var no_guardians = game_state.player.get_guardian_minions().is_empty()
			if no_guardians and card.effect_value >= game_state.player.hero_health:
				result["player_id"] = game_state.player.player_id
				result["ready"] = true
			elif not player_targetable.is_empty():
				result["minion"] = _pick_best_removal_target(player_targetable, card.effect_value)
				result["ready"] = true
			elif no_guardians:
				result["player_id"] = game_state.player.player_id
				result["ready"] = true
		"buff_creature":
			if not opponent_targetable.is_empty():
				result["minion"] = _pick_strongest(opponent_targetable)
				result["ready"] = true
		"buff_health":
			if not opponent_targetable.is_empty():
				result["minion"] = _pick_lowest_health(opponent_targetable)
				result["ready"] = true
		"give_ability":
			if not opponent_targetable.is_empty():
				result["minion"] = _pick_strongest(opponent_targetable)
				result["ready"] = true
		"destroy_all_creatures":
			var player_power := 0
			for m in game_state.player.board:
				player_power += m.current_attack + m.current_health
			var opp_power := 0
			for m in game_state.opponent.board:
				opp_power += m.current_attack + m.current_health
			result["ready"] = not game_state.player.board.is_empty() and player_power >= opp_power
		"deal_damage_all_creatures":
			result["ready"] = not game_state.player.board.is_empty()
		"deal_damage_all_enemy":
			result["ready"] = not game_state.player.board.is_empty()
		"buff_all_friendly_attack":
			result["ready"] = not game_state.opponent.board.is_empty()
		"blood_transfusion":
			if not player_targetable.is_empty():
				result["minion"] = _pick_best_removal_target(player_targetable, 2)
				result["ready"] = true
		"sanguine":
			var sources: Array[Minion] = []
			for m in opponent_targetable:
				if m.current_health > 2:
					sources.append(m)
			if sources.size() >= 2 or (sources.size() == 1 and opponent_targetable.size() >= 2):
				result["minion"] = _pick_strongest(sources)
				result["ready"] = true
		"force_challenge":
			for m in game_state.opponent.board:
				if m.has_ability(Abilities.YETI) and not game_state.player.board.is_empty():
					result["minion"] = m
					result["ready"] = true
					break
		"poke_bear":
			for m in game_state.opponent.board:
				if m.has_ability(Abilities.YETI) and not game_state.player.board.is_empty():
					result["minion"] = m
					result["ready"] = true
					break
		"heal":
			var damaged: Array[Minion] = []
			for m in opponent_targetable:
				if m.current_health < m.max_health:
					damaged.append(m)
			if not damaged.is_empty():
				result["minion"] = _pick_lowest_health(damaged)
				result["ready"] = true
		"eject_pilot":
			var piloted: Array[Minion] = []
			for m in opponent_targetable:
				if m.is_piloted:
					piloted.append(m)
			if not piloted.is_empty():
				result["minion"] = _pick_strongest(piloted)
				result["ready"] = true
		"give_mech_shielded_temp":
			var mechs: Array[Minion] = []
			for m in opponent_targetable:
				if m.has_ability(Abilities.MECH):
					mechs.append(m)
			if not mechs.is_empty():
				result["minion"] = _pick_strongest(mechs)
				result["ready"] = true
	return result

# --- Attack phase ---

func _attack_phase(game_state: GameState, board: Board) -> void:
	if _check_lethal(game_state):
		await _attack_all_face(game_state, board)
		return
	await _attack_with_all(game_state, board)

func _check_lethal(game_state: GameState) -> bool:
	if not game_state.player.get_guardian_minions().is_empty():
		return false
	var total = 0
	for m in game_state.opponent.board:
		if m.can_attack():
			total += m.current_attack
	return total >= game_state.player.hero_health

func _attack_all_face(game_state: GameState, board: Board) -> void:
	for m in game_state.opponent.board.duplicate():
		if m.can_attack():
			await get_tree().create_timer(THINK_DELAY).timeout
			board.log_action("Opponent's %s attacked your hero" % m.data.card_name)
			game_state.attack(m, null, game_state.player.player_id)
			board.refresh()

func _attack_with_all(game_state: GameState, board: Board) -> void:
	var made_attack := true
	while made_attack:
		made_attack = false
		var attackers: Array[Minion] = []
		for m in game_state.opponent.board:
			if m.can_attack():
				attackers.append(m)
		if attackers.is_empty():
			break

		var guardians = game_state.player.get_guardian_minions()
		var forced = not guardians.is_empty()
		var raw_candidates: Array[Minion] = guardians if forced else game_state.player.board.duplicate()

		# Filter out Ethereal and Ambush targets
		var candidates: Array[Minion] = []
		for m in raw_candidates:
			if not m.has_ability(Abilities.COMBAT_IMMUNE) and not m.has_ability(Abilities.AMBUSH):
				candidates.append(m)

		# If nothing to trade into, go face — or stall if blocked by ethereal guardians
		if candidates.is_empty():
			if forced:
				break
			for attacker in attackers:
				await get_tree().create_timer(THINK_DELAY).timeout
				board.log_action("Opponent's %s attacked your hero" % attacker.data.card_name)
				game_state.attack(attacker, null, game_state.player.player_id)
				board.refresh()
			return

		var best_score := -999
		var best_attacker: Minion = null
		var best_target: Minion = null  # null = go face

		for attacker in attackers:
			for target in candidates:
				var score = _score_trade(attacker, target)
				if score > best_score:
					best_score = score
					best_attacker = attacker
					best_target = target
			if not forced:
				# Face pressure weighted by attacker's damage output
				var face_score = _face_pressure_score(game_state) + attacker.current_attack / 2
				if face_score > best_score:
					best_score = face_score
					best_attacker = attacker
					best_target = null

		# Don't make losing plays when not forced
		if best_score <= 0 and not forced:
			break
		if best_attacker == null:
			break

		await get_tree().create_timer(THINK_DELAY).timeout
		if best_target != null:
			board.log_action("Opponent's %s attacked your %s" % [best_attacker.data.card_name, best_target.data.card_name])
			game_state.attack(best_attacker, best_target)
			await board.animate_creature_attack(best_attacker.instance_id, game_state.opponent.player_id, best_target.instance_id)
		else:
			board.log_action("Opponent's %s attacked your hero" % best_attacker.data.card_name)
			game_state.attack(best_attacker, null, game_state.player.player_id)
		board.refresh()
		made_attack = true

# Score a trade: positive = worth doing, negative = avoid
func _score_trade(attacker: Minion, target: Minion) -> int:
	if target.has_ability(Abilities.COMBAT_IMMUNE):
		return -999

	var target_shield := 0
	for ab in target.abilities:
		if Abilities.is_shielded(ab):
			target_shield = Abilities.get_shield_value(ab)
			break
	var attacker_shield := 0
	for ab in attacker.abilities:
		if Abilities.is_shielded(ab):
			attacker_shield = Abilities.get_shield_value(ab)
			break

	var hits := 2 if attacker.has_ability(Abilities.DUAL_STRIKE) else 1
	var damage_to_target := maxi(0, attacker.current_attack - target_shield) * hits

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

# How urgently should we hit face right now?
func _face_pressure_score(game_state: GameState) -> int:
	var hp := game_state.player.hero_health
	var score: int
	if hp <= 8:
		score = 30
	elif hp <= 12:
		score = 18
	elif hp <= 16:
		score = 8
	elif hp <= 20:
		score = 3
	else:
		score = 0
	# Extra pressure when ahead on board
	if game_state.opponent.board.size() > game_state.player.board.size() + 1:
		score += 6
	return score

# --- Target selection helpers ---

func _pick_best_removal_target(minions: Array[Minion], damage: int) -> Minion:
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

func _pick_challenge_target(minions: Array[Minion], challenger: Minion) -> Minion:
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

func _pick_best_pilot_target(mechs: Array[Minion], pilot: Minion = null) -> Minion:
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

func _is_pilot_without_target(card: CardData, game_state: GameState) -> bool:
	if card.card_type != CardData.CardType.CREATURE:
		return false
	for ab in card.abilities:
		if Abilities.is_pilot(ab):
			for m in game_state.opponent.board:
				if m.has_ability(Abilities.MECH) and not m.is_piloted:
					return false
			return true
	return false

func _pick_strongest(minions: Array[Minion]) -> Minion:
	return minions.reduce(func(a, b): return a if a.current_attack > b.current_attack else b)

func _pick_lowest_health(minions: Array[Minion]) -> Minion:
	return minions.reduce(func(a, b): return a if a.current_health < b.current_health else b)
