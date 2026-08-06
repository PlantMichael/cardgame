class_name AIController
extends Node

const THINK_DELAY = 0.6

## 1 (weakest) - 10 (strongest). Read once per decision in take_turn(); see
## MCTSEngine.AI_LEVEL_CONFIG for what each level actually changes.
var ai_level: int = 5

## Repeatedly asks MCTSEngine for the single best next atomic action against
## the real game_state, applies it (with the same logging/animation glue the
## old one-ply AI used), and stops when the search recommends ending the turn.
func take_turn(game_state: GameState, board: Board) -> void:
	for _i in 60:  # safety cap; a real turn never needs anywhere near this many actions
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			return
		var engine := MCTSEngine.new(game_state.opponent.player_id, ai_level)
		var action: Dictionary = await engine.choose_action(game_state)
		if action["type"] == "end_turn":
			return
		await _apply_action(action, game_state, board)
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			return

func _apply_action(action: Dictionary, game_state: GameState, board: Board) -> void:
	match action["type"]:
		"play_creature":
			await _play_creature_action(action["card"], game_state, board)
		"play_stratagem":
			await _play_stratagem_action(action["card"], action.get("minion"), action.get("player_id", ""), game_state, board)
		"attack":
			await _attack_action(action["attacker"], action.get("target"), action.get("target_player_id", ""), game_state, board)

# --- Card playing ---

func _play_creature_action(card: CardData, game_state: GameState, board: Board) -> void:
	await get_tree().create_timer(THINK_DELAY).timeout
	var new_minion = game_state.play_creature(game_state.opponent.player_id, card)
	board.log_action("Opponent played %s" % card.card_name)
	board.refresh()
	if new_minion:
		await _handle_on_play_effects(new_minion, game_state, board)

func _play_stratagem_action(card: CardData, minion: Minion, target_player_id: String, game_state: GameState, board: Board) -> void:
	await get_tree().create_timer(THINK_DELAY).timeout
	if not game_state.play_stratagem(game_state.opponent.player_id, card, minion, target_player_id):
		return
	board.log_action("Opponent played %s" % card.card_name)
	if minion != null:
		var _died: bool = minion not in game_state.player.board and minion not in game_state.opponent.board
		if _died:
			var _tgt: Card = board.find_card_node(minion.instance_id)
			if _tgt != null:
				var _from: Vector2 = _tgt.get_parent().get_global_rect().get_center() + Vector2(0, -600)
				await board.animate_laser_kill(_from, _tgt)
	board.refresh()

	if card.effect in ["force_challenge", "poke_bear"] and minion != null:
		var yeti: Minion = minion
		if yeti in game_state.opponent.board and yeti.has_ability(Abilities.YETI) and not game_state.player.board.is_empty():
			var challenge_target = AIHeuristics.pick_challenge_target(game_state.player.board.duplicate(), yeti)
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
		var recipient = AIHeuristics.pick_health_buff_target(game_state.opponent.board.duplicate())
		board.log_action("Opponent's Blood Transfusion gave %s +2 health" % recipient.data.card_name)
		game_state.apply_heal_buff(recipient, 2)
		board.refresh()

	if card.effect == "sanguine" and not game_state.opponent.board.is_empty():
		var candidates: Array[Minion] = []
		for m in game_state.opponent.board:
			if m != minion:
				candidates.append(m)
		if not candidates.is_empty():
			var recipient = AIHeuristics.pick_health_buff_target(candidates)
			board.log_action("Opponent's Sanguine gave %s +2 health" % recipient.data.card_name)
			game_state.apply_heal_buff(recipient, 2)
			board.refresh()

func _handle_on_play_effects(new_minion: Minion, game_state: GameState, board: Board) -> void:
	for ability in new_minion.abilities:
		if Abilities.is_on_play_damage(ability):
			var damage = Abilities.get_on_play_damage_value(ability)
			var target = AIHeuristics.pick_best_removal_target(game_state.player.board, damage)
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
		var target = AIHeuristics.pick_challenge_target(game_state.player.board, new_minion)
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
		var target = AIHeuristics.pick_challenge_target(game_state.player.board, new_minion)
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
			var target = AIHeuristics.pick_challenge_target(game_state.player.board, friendly_yeti)
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
				var mech_target = AIHeuristics.pick_best_pilot_target(mechs, new_minion)
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

# --- Attack execution ---

func _attack_action(attacker: Minion, target: Minion, target_player_id: String, game_state: GameState, board: Board) -> void:
	await get_tree().create_timer(THINK_DELAY).timeout
	if target != null:
		board.log_action("Opponent's %s attacked your %s" % [attacker.data.card_name, target.data.card_name])
		game_state.attack(attacker, target)
		await board.animate_creature_attack(attacker.instance_id, game_state.opponent.player_id, target.instance_id)
	else:
		board.log_action("Opponent's %s attacked your hero" % attacker.data.card_name)
		game_state.attack(attacker, null, target_player_id)
	board.refresh()

# --- Backward-compatible delegates (called directly by game_manager.gd for
# non-AI-turn opponent decisions, e.g. reactive pending-queue resolution) ---

func _pick_best_removal_target(minions: Array[Minion], damage: int) -> Minion:
	return AIHeuristics.pick_best_removal_target(minions, damage)

func _pick_challenge_target(minions: Array[Minion], challenger: Minion) -> Minion:
	return AIHeuristics.pick_challenge_target(minions, challenger)

func _pick_health_buff_target(minions: Array[Minion]) -> Minion:
	return AIHeuristics.pick_health_buff_target(minions)
