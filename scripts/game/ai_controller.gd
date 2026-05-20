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
		hand.sort_custom(func(a, b): return a.cost > b.cost)
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
				board.refresh()
				if card.effect in ["force_challenge", "poke_bear"] and pick["minion"] != null:
					var yeti: Minion = pick["minion"]
					if yeti in game_state.opponent.board and yeti.has_ability(Abilities.YETI) and not game_state.player.board.is_empty():
						var challenge_target = _pick_challenge_target(game_state.player.board.duplicate(), yeti)
						if challenge_target != null:
							await get_tree().create_timer(THINK_DELAY).timeout
							board.log_action("Opponent's %s challenged your %s" % [yeti.data.card_name, challenge_target.data.card_name])
							game_state.apply_challenge(yeti, challenge_target)
							board.refresh()
				played = true
				break

func _handle_on_play_effects(new_minion: Minion, game_state: GameState, board: Board) -> void:
	for ability in new_minion.abilities:
		if Abilities.is_on_play_damage(ability):
			var damage = Abilities.get_on_play_damage_value(ability)
			var all_minions: Array[Minion] = game_state.player.board.duplicate()
			all_minions.append_array(game_state.opponent.board.duplicate())
			all_minions.erase(new_minion)
			if not all_minions.is_empty():
				var target = _pick_best_removal_target(game_state.player.board, damage)
				if target == null:
					target = _pick_best_removal_target(all_minions, damage)
				if target != null:
					board.log_action("Opponent's %s dealt %d damage to your %s" % [new_minion.data.card_name, damage, target.data.card_name])
					game_state.apply_on_play_damage(target, damage)
					board.refresh()
			break

	if new_minion.has_ability(Abilities.CHALLENGE) and not game_state.player.board.is_empty():
		var target = _pick_challenge_target(game_state.player.board, new_minion)
		board.log_action("Opponent's %s challenged your %s" % [new_minion.data.card_name, target.data.card_name])
		game_state.apply_challenge(new_minion, target)
		board.refresh()

	if new_minion.has_ability(Abilities.ON_PLAY_YETI_CHALLENGE) and not game_state.player.board.is_empty():
		var friendly_yeti: Minion = null
		for m in game_state.opponent.board:
			if m != new_minion and m.has_ability(Abilities.YETI):
				friendly_yeti = m
				break
		if friendly_yeti != null:
			var target = _pick_challenge_target(game_state.player.board, friendly_yeti)
			board.log_action("Opponent's %s challenged your %s" % [friendly_yeti.data.card_name, target.data.card_name])
			game_state.apply_challenge(friendly_yeti, target)
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
				var mech_target = _pick_strongest(mechs)
				await get_tree().create_timer(THINK_DELAY).timeout
				board.log_action("Opponent's %s piloted %s" % [new_minion.data.card_name, mech_target.data.card_name])
				game_state.apply_pilot(new_minion, mech_target, game_state.opponent)
				board.refresh()
			break

func _pick_stratagem_targets(card: CardData, game_state: GameState) -> Dictionary:
	var result = {"ready": false, "minion": null, "player_id": ""}
	var player_targetable: Array[Minion] = []
	for m in game_state.player.board:
		if not m.has_ability(Abilities.SAFEGUARD):
			player_targetable.append(m)
	var opponent_targetable: Array[Minion] = []
	for m in game_state.opponent.board:
		if not m.has_ability(Abilities.SAFEGUARD):
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
		"deal_damage_all_creatures":
			result["ready"] = not game_state.player.board.is_empty()
		"buff_all_friendly_attack":
			result["ready"] = not game_state.opponent.board.is_empty()
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
	for attacker in game_state.opponent.board.duplicate():
		if not attacker.can_attack():
			continue
		var target = _pick_best_attack_target(game_state, attacker)
		await get_tree().create_timer(THINK_DELAY).timeout
		if target != null:
			board.log_action("Opponent's %s attacked your %s" % [attacker.data.card_name, target.data.card_name])
			game_state.attack(attacker, target)
			await board.animate_creature_attack(attacker.instance_id, game_state.opponent.player_id, target.instance_id)
		else:
			board.log_action("Opponent's %s attacked your hero" % attacker.data.card_name)
			game_state.attack(attacker, null, game_state.player.player_id)
		board.refresh()

# Returns the best minion to attack, or null to go face.
func _pick_best_attack_target(game_state: GameState, attacker: Minion) -> Minion:
	var taunts = game_state.player.get_guardian_minions()
	var forced = not taunts.is_empty()
	var candidates: Array[Minion] = taunts if forced else game_state.player.board.duplicate()
	if candidates.is_empty():
		return null

	var best_favorable: Minion = null  # we kill target and survive
	var best_trade_up: Minion = null   # we die too, but target has equal or higher attack
	var highest_attack: Minion = null  # fallback: remove biggest threat

	for target in candidates:
		var we_kill = attacker.current_attack >= target.current_health
		var we_survive = attacker.current_health > target.current_attack

		if we_kill and we_survive:
			if best_favorable == null or target.current_attack > best_favorable.current_attack:
				best_favorable = target
		elif we_kill and target.current_attack >= attacker.current_attack:
			if best_trade_up == null or target.current_attack > best_trade_up.current_attack:
				best_trade_up = target

		if highest_attack == null or target.current_attack > highest_attack.current_attack:
			highest_attack = target

	if best_favorable != null:
		return best_favorable
	if best_trade_up != null:
		return best_trade_up
	# Must attack a guardian even if the trade is bad
	if forced:
		return highest_attack
	# Otherwise prefer going face over a bad trade
	return null

# --- Target selection helpers ---

# Returns best minion target for damage: prefers killing the highest-attack minion.
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
	var best_favorable: Minion = null  # kill target, survive
	var best_kill: Minion = null       # kill target, we die
	var highest_attack: Minion = null  # can't kill anything
	for m in minions:
		var we_kill = challenger.current_attack >= m.current_health
		var we_survive = challenger.current_health > m.current_attack
		if we_kill and we_survive:
			if best_favorable == null or m.current_attack > best_favorable.current_attack:
				best_favorable = m
		elif we_kill:
			if best_kill == null or m.current_attack > best_kill.current_attack:
				best_kill = m
		if highest_attack == null or m.current_attack > highest_attack.current_attack:
			highest_attack = m
	if best_favorable != null:
		return best_favorable
	if best_kill != null:
		return best_kill
	return highest_attack

func _pick_strongest(minions: Array[Minion]) -> Minion:
	return minions.reduce(func(a, b): return a if a.current_attack > b.current_attack else b)

func _pick_lowest_health(minions: Array[Minion]) -> Minion:
	return minions.reduce(func(a, b): return a if a.current_health < b.current_health else b)
