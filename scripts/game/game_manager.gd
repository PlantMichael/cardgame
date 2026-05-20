extends Node

var game_state: GameState
var board: Board
var ai_controller: AIController

const LOCAL_PLAYER_ID = "player_1"
const OPPONENT_PLAYER_ID = "player_2"

func _ready() -> void:
	ai_controller = AIController.new()
	add_child(ai_controller)

func start_local_game(board_node: Board, player_color: int = CardData.CardColor.GREEN, opponent_color: int = CardData.CardColor.TEAL) -> void:
	board = board_node
	var player_deck = _build_deck_for_color(player_color as CardData.CardColor)
	var opponent_deck = _build_deck_for_color(opponent_color as CardData.CardColor)
	game_state = GameState.new(LOCAL_PLAYER_ID, OPPONENT_PLAYER_ID, player_deck, opponent_deck)
	board.action_play_card.connect(_on_play_card)
	board.action_play_stratagem.connect(_on_play_stratagem)
	board.action_attack.connect(_on_attack)
	board.action_pilot.connect(_on_pilot)
	board.end_turn_pressed.connect(_on_end_turn)
	board.opponent_hero.player_id = OPPONENT_PLAYER_ID
	board.player_hero.player_id = LOCAL_PLAYER_ID
	var first_player_id = LOCAL_PLAYER_ID if randf() < 0.5 else OPPONENT_PLAYER_ID
	game_state.start_game(first_player_id)
	board.setup(game_state)
	await board.show_coinflip_result(first_player_id == LOCAL_PLAYER_ID)
	if not game_state.is_local_player_turn():
		board.log_action("--- Opponent Turn %d ---" % game_state.turn_number)
		await ai_controller.take_turn(game_state, board)
		await _announce_pending_draws()
		await _process_pending_tank_shots()
		await _process_pending_rummages()
		await _process_pending_nulls()
		await _process_pending_buff_friendly_health()
		await _process_pending_overwatch_challenges()
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			_handle_game_over()
			return
		game_state.end_turn()
		board.refresh()
		await _announce_pending_draws()
		await _process_pending_tank_shots()
		await _process_pending_rummages()
		await _process_pending_nulls()
		await _process_pending_buff_friendly_health()
		await _process_pending_overwatch_challenges()
		board.log_action("--- Your Turn %d ---" % game_state.turn_number)

func _on_play_card(card_data: CardData) -> void:
	if not game_state.is_local_player_turn():
		return
	var minion = game_state.play_creature(LOCAL_PLAYER_ID, card_data)
	if minion:
		board.log_action("You played %s" % card_data.card_name)
		await get_tree().process_frame
		await get_tree().process_frame
		board.refresh()
		await _process_pending_tank_shots()
		await _process_pending_rummages()
		await _process_pending_nulls()
		await _process_pending_buff_friendly_health()
		await _process_pending_overwatch_challenges()
		if minion.has_ability(Abilities.ON_PLAY_TRANSFORM_CHOICE) and not minion.data.transform_choices.is_empty():
			var options: Array[CardData] = []
			for cid in minion.data.transform_choices:
				var cd = CardDatabase.get_card(cid)
				if cd != null:
					options.append(cd)
			if not options.is_empty():
				var chosen: CardData = await board.show_transform_picker(options)
				if chosen != null:
					board.log_action("Your %s transformed into %s" % [minion.data.card_name, chosen.card_name])
					game_state.apply_transform_choice(minion, chosen.id)
					board.refresh()
		for ability in minion.abilities:
			if Abilities.is_on_play_damage(ability):
				var damage = Abilities.get_on_play_damage_value(ability)
				if game_state.player.board.size() + game_state.opponent.board.size() > 0:
					board.start_on_play_damage_targeting()
					var target: Minion = await board.on_play_damage_target_selected
					if target != null:
						board.log_action("Your %s dealt %d damage to %s" % [minion.data.card_name, damage, target.data.card_name])
						game_state.apply_on_play_damage(target, damage)
						board.refresh()
				if game_state.current_phase == GameState.Phase.GAME_OVER:
					_handle_game_over()
					return
				break
		if minion.has_ability(Abilities.CHALLENGE) and not game_state.opponent.board.is_empty():
			board.start_challenge_targeting(minion)
			var target: Minion = await board.challenge_target_selected
			if target != null:
				board.log_action("Your %s challenged opponent's %s" % [minion.data.card_name, target.data.card_name])
				game_state.apply_challenge(minion, target)
				board.refresh()
				await _announce_pending_draws()
				await _process_pending_tank_shots()
				await _process_pending_rummages()
				await _process_pending_nulls()
				await _process_pending_buff_friendly_health()
				await _process_pending_overwatch_challenges()
				if game_state.current_phase == GameState.Phase.GAME_OVER:
					_handle_game_over()
		if minion.has_ability(Abilities.ON_PLAY_YETI_CHALLENGE) and not game_state.opponent.board.is_empty():
			var friendly_yeti: Minion = null
			for m in game_state.player.board:
				if m != minion and m.has_ability(Abilities.YETI):
					friendly_yeti = m
					break
			if friendly_yeti != null:
				board.start_yeti_selection()
				var chosen: Minion = await board.yeti_selected
				if chosen != null:
					board.start_challenge_targeting(chosen)
					var target: Minion = await board.challenge_target_selected
					if target != null:
						board.log_action("Your %s challenged opponent's %s" % [chosen.data.card_name, target.data.card_name])
						game_state.apply_challenge(chosen, target)
						board.refresh()
						await _announce_pending_draws()
						await _process_pending_overwatch_challenges()
						if game_state.current_phase == GameState.Phase.GAME_OVER:
							_handle_game_over()

func _process_pending_tank_shots() -> void:
	while not game_state.pending_tank_shots.is_empty():
		var owner_id: String = game_state.pending_tank_shots.pop_front()
		if owner_id == LOCAL_PLAYER_ID:
			board.start_tank_shot_targeting()
			var result = await board.tank_shot_resolved
			var target_minion: Minion = result[0]
			var target_player_id: String = result[1]
			if target_minion != null:
				board.log_action("Tank reinforcement dealt 1 damage to %s" % target_minion.data.card_name)
				game_state.apply_on_play_damage(target_minion, 1)
			elif target_player_id != "":
				board.log_action("Tank reinforcement dealt 1 damage to the opponent's hero")
				game_state.opponent.hero_health -= 1
				game_state._check_win_condition()
		else:
			game_state.player.hero_health -= 1
			board.log_action("Opponent tank reinforcement dealt 1 damage to your hero")
		board.refresh()

func _process_pending_overwatch_challenges() -> void:
	while not game_state.pending_overwatch_challenges.is_empty():
		var owner_id: String = game_state.pending_overwatch_challenges.pop_front()
		var owner_state = game_state.player if owner_id == LOCAL_PLAYER_ID else game_state.opponent
		var enemy_state = game_state.opponent if owner_id == LOCAL_PLAYER_ID else game_state.player
		var available_yetis: Array[Minion] = []
		for m in owner_state.board:
			if m.has_ability(Abilities.YETI):
				available_yetis.append(m)
		if available_yetis.is_empty() or enemy_state.board.is_empty():
			continue
		if owner_id == LOCAL_PLAYER_ID:
			board.start_yeti_selection()
			var chosen: Minion = await board.yeti_selected
			if chosen != null and not enemy_state.board.is_empty():
				board.start_challenge_targeting(chosen)
				var target: Minion = await board.challenge_target_selected
				if target != null:
					board.log_action("Overwatch: Your %s challenged opponent's %s" % [chosen.data.card_name, target.data.card_name])
					game_state.apply_challenge(chosen, target)
					board.refresh()
					if game_state.current_phase == GameState.Phase.GAME_OVER:
						_handle_game_over()
						return
		else:
			var best_yeti: Minion = available_yetis[0]
			for y in available_yetis:
				if y.current_attack > best_yeti.current_attack:
					best_yeti = y
			var target = ai_controller._pick_challenge_target(enemy_state.board.duplicate(), best_yeti)
			if target != null:
				board.log_action("Opponent Overwatch: %s challenged your %s" % [best_yeti.data.card_name, target.data.card_name])
				game_state.apply_challenge(best_yeti, target)
				board.refresh()
				if game_state.current_phase == GameState.Phase.GAME_OVER:
					_handle_game_over()
					return

func _process_pending_buff_friendly_health() -> void:
	while not game_state.pending_buff_friendly_health.is_empty():
		var player_id: String = game_state.pending_buff_friendly_health.pop_front()
		var p = game_state.player if player_id == LOCAL_PLAYER_ID else game_state.opponent
		if p.board.is_empty():
			continue
		if player_id == LOCAL_PLAYER_ID:
			board.start_buff_friendly_targeting()
			var target: Minion = await board.buff_friendly_target_selected
			if target != null and target in game_state.player.board:
				board.log_action("Your Moonchild gave %s +1 max health" % target.data.card_name)
				game_state.apply_buff_friendly_health(target)
				board.refresh()
		else:
			var best: Minion = p.board[0]
			for m in p.board:
				if m.current_health > best.current_health:
					best = m
			board.log_action("Opponent's Moonchild gave %s +1 max health" % best.data.card_name)
			game_state.apply_buff_friendly_health(best)
			board.refresh()

func _process_pending_nulls() -> void:
	while not game_state.pending_nulls.is_empty():
		var entry: Dictionary = game_state.pending_nulls.pop_front()
		var player_id: String = entry["player_id"]
		var source_name: String = entry["source"]
		var all_minions: Array[Minion] = game_state.player.board.duplicate()
		all_minions.append_array(game_state.opponent.board.duplicate())
		if all_minions.is_empty():
			continue
		if player_id == LOCAL_PLAYER_ID:
			board.start_null_targeting()
			var target: Minion = await board.null_target_selected
			var on_board = target != null and (target in game_state.player.board or target in game_state.opponent.board)
			if on_board:
				board.log_action("Your %s silenced %s" % [source_name, target.data.card_name])
				game_state.apply_null(target)
				board.refresh()
		else:
			var best: Minion = null
			for m in game_state.player.board:
				if best == null or m.abilities.size() > best.abilities.size():
					best = m
			if best != null:
				board.log_action("Opponent's %s silenced your %s" % [source_name, best.data.card_name])
				game_state.apply_null(best)
				board.refresh()

func _process_pending_rummages() -> void:
	while not game_state.pending_rummages.is_empty():
		var entry = game_state.pending_rummages.pop_front()
		var player_id: String = entry["player_id"]
		var max_cost: int = entry["max_cost"]
		var type_filter: String = entry.get("type_filter", "")
		var options = game_state.get_rummage_options(player_id, max_cost, type_filter)
		if options.is_empty():
			continue
		var chosen: CardData
		if player_id == LOCAL_PLAYER_ID:
			chosen = await board.show_graveyard_picker(options)
		else:
			options.sort_custom(func(a, b): return a.cost > b.cost)
			chosen = options[0]
		if chosen:
			game_state.complete_rummage(player_id, chosen)
			board.refresh()

func _announce_pending_draws() -> void:
	if game_state.pending_drawn_cards.is_empty():
		return
	for card_data in game_state.pending_drawn_cards:
		board.log_action("Drew %s" % card_data.card_name)
		await board.animate_draw()
	game_state.pending_drawn_cards.clear()

func _on_pilot(pilot_instance_id: String, target_instance_id: String) -> void:
	var pilot = _find_minion(LOCAL_PLAYER_ID, pilot_instance_id)
	var target = _find_minion(LOCAL_PLAYER_ID, target_instance_id)
	if not pilot or not target:
		return
	var atk_bonus = 0
	var hp_bonus = 0
	for ability in pilot.abilities:
		if Abilities.is_pilot(ability):
			atk_bonus = Abilities.get_pilot_attack(ability)
			hp_bonus = Abilities.get_pilot_health(ability)
			break
	board.log_action("Your %s piloted %s (+%d/+%d)" % [pilot.data.card_name, target.data.card_name, atk_bonus, hp_bonus])
	game_state.apply_pilot(pilot, target, game_state.player)
	board.refresh()

func _on_attack(attacker_id: String, target_type: String, target_id: String) -> void:
	var attacker = _find_minion(LOCAL_PLAYER_ID, attacker_id)
	if not attacker:
		return
	if target_type == "minion":
		var target = _find_minion(OPPONENT_PLAYER_ID, target_id)
		if target:
			board.log_action("Your %s attacked opponent's %s" % [attacker.data.card_name, target.data.card_name])
			game_state.attack(attacker, target)
			await board.animate_creature_attack(attacker_id, LOCAL_PLAYER_ID, target_id)
	elif target_type == "hero":
		board.log_action("Your %s attacked the opponent's hero" % attacker.data.card_name)
		game_state.attack(attacker, null, target_id)
	board.refresh()
	await _announce_pending_draws()
	await _process_pending_tank_shots()
	await _process_pending_rummages()
	await _process_pending_nulls()
	await _process_pending_buff_friendly_health()
	await _process_pending_overwatch_challenges()
	if game_state.current_phase == GameState.Phase.GAME_OVER:
		_handle_game_over()

func _on_play_stratagem(card_data: CardData, target_minion: Minion, target_player_id: String) -> void:
	if not game_state.is_local_player_turn():
		return
	if not game_state.play_stratagem(LOCAL_PLAYER_ID, card_data, target_minion, target_player_id):
		board.refresh()
		return
	board.log_action("You played %s" % card_data.card_name)
	await get_tree().process_frame
	await get_tree().process_frame
	board.refresh()
	if card_data.effect == "force_challenge" and target_minion != null:
		if target_minion.owner_id == LOCAL_PLAYER_ID and target_minion.has_ability(Abilities.YETI):
			if not game_state.opponent.board.is_empty():
				board.start_challenge_targeting(target_minion)
				var target: Minion = await board.challenge_target_selected
				if target != null:
					board.log_action("Your %s challenged opponent's %s" % [target_minion.data.card_name, target.data.card_name])
					game_state.apply_challenge(target_minion, target)
					board.refresh()
	if card_data.effect == "poke_bear" and target_minion != null:
		if target_minion in game_state.player.board and target_minion.has_ability(Abilities.YETI):
			if not game_state.opponent.board.is_empty():
				board.start_challenge_targeting(target_minion)
				var target: Minion = await board.challenge_target_selected
				if target != null:
					board.log_action("Your %s challenged opponent's %s" % [target_minion.data.card_name, target.data.card_name])
					game_state.apply_challenge(target_minion, target)
					board.refresh()
	await _announce_pending_draws()
	await _process_pending_tank_shots()
	await _process_pending_rummages()
	await _process_pending_nulls()
	await _process_pending_buff_friendly_health()
	await _process_pending_overwatch_challenges()
	if game_state.current_phase == GameState.Phase.GAME_OVER:
		_handle_game_over()

func _on_end_turn() -> void:
	game_state.end_turn()
	board.refresh()
	board.log_action("--- Opponent Turn %d ---" % game_state.turn_number)
	if not game_state.is_local_player_turn():
		await ai_controller.take_turn(game_state, board)
		await _announce_pending_draws()
		await _process_pending_tank_shots()
		await _process_pending_rummages()
		await _process_pending_nulls()
		await _process_pending_buff_friendly_health()
		await _process_pending_overwatch_challenges()
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			_handle_game_over()
			return
		game_state.end_turn()
		board.refresh()
		await _announce_pending_draws()
		await _process_pending_tank_shots()
		await _process_pending_rummages()
		await _process_pending_nulls()
		await _process_pending_buff_friendly_health()
		await _process_pending_overwatch_challenges()
		board.log_action("--- Your Turn %d ---" % game_state.turn_number)

func _find_minion(player_id: String, instance_id: String) -> Minion:
	var p = game_state.player if player_id == LOCAL_PLAYER_ID else game_state.opponent
	for minion in p.board:
		if minion.instance_id == instance_id:
			return minion
	return null

func _handle_game_over() -> void:
	board.show_game_over(game_state.winner_id == LOCAL_PLAYER_ID)

func _build_deck_for_color(color: CardData.CardColor) -> Array[CardData]:
	const TARGET = 40
	var color_cards: Array[CardData] = []
	for card in CardDatabase.get_all_cards():
		if card.color == color and not card.is_token:
			color_cards.append(card)
	var deck: Array[CardData] = []
	for card in color_cards:
		deck.append(card)
		deck.append(card)
	if deck.size() < TARGET:
		var sorted = color_cards.duplicate()
		sorted.sort_custom(func(a, b): return a.cost < b.cost)
		var fill_idx = 0
		while deck.size() < TARGET:
			deck.append(sorted[fill_idx % sorted.size()])
			fill_idx += 1
	return deck
