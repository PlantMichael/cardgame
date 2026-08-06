extends Node

var game_state: GameState
var board: Board
var ai_controller: AIController
var is_ranked: bool = false

const LOCAL_PLAYER_ID = "player_1"
const OPPONENT_PLAYER_ID = "player_2"

func _ready() -> void:
	ai_controller = AIController.new()
	add_child(ai_controller)

func start_local_game(board_node: Board, player_deck: Array[CardData], opponent_deck: Array[CardData],
					   ai_level: int = 5, ranked: bool = false) -> void:
	board = board_node
	board.is_online = false
	ai_controller.ai_level = ai_level
	is_ranked = ranked
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
		await _process_pending_tank_specialist_buffs()
		await _process_pending_on_reinforce_damages()
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
		await _process_pending_tank_specialist_buffs()
		await _process_pending_on_reinforce_damages()
		await _process_pending_overwatch_challenges()
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			_handle_game_over()
			return
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
		await _process_pending_tank_specialist_buffs()
		await _process_pending_on_reinforce_damages()
		await _process_pending_overwatch_challenges()
		await _run_player_on_play(minion)
		await _announce_pending_draws()
		board.refresh()

func _run_player_on_play(minion: Minion) -> void:
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
			board.start_on_play_damage_targeting()
			var result = await board.on_play_damage_target_selected
			var dmg_target: Minion = result[0]
			var dmg_player_id: String = result[1]
			if dmg_target != null:
				board.log_action("Your %s dealt %d damage to %s" % [minion.data.card_name, damage, dmg_target.data.card_name])
				game_state.apply_on_play_damage(dmg_target, damage, minion.owner_id)
				var _opd_died: bool = dmg_target not in game_state.player.board and dmg_target not in game_state.opponent.board
				if _opd_died:
					var _opd_src: Card = board.find_card_node(minion.instance_id)
					var _opd_tgt: Card = board.find_card_node(dmg_target.instance_id)
					if _opd_src != null and _opd_tgt != null:
						await board.animate_laser_kill(_opd_src.get_parent().get_global_rect().get_center(), _opd_tgt)
				board.refresh()
			elif dmg_player_id != "":
				var target_name := "your hero" if dmg_player_id == LOCAL_PLAYER_ID else "opponent's hero"
				board.log_action("Your %s dealt %d damage to the %s" % [minion.data.card_name, damage, target_name])
				game_state._get_player_by_id(dmg_player_id).hero_health -= damage
				game_state._check_win_condition()
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
			await board.animate_creature_challenge(minion.instance_id, LOCAL_PLAYER_ID, target.instance_id)
			board.refresh()
			await _announce_pending_draws()
			await _process_pending_tank_shots()
			await _process_pending_rummages()
			await _process_pending_nulls()
			await _process_pending_buff_friendly_health()
			await _process_pending_tank_specialist_buffs()
			await _process_pending_on_reinforce_damages()
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
					await board.animate_creature_challenge(chosen.instance_id, LOCAL_PLAYER_ID, target.instance_id)
					board.refresh()
					await _announce_pending_draws()
					await _process_pending_on_reinforce_damages()
					await _process_pending_overwatch_challenges()
					if game_state.current_phase == GameState.Phase.GAME_OVER:
						_handle_game_over()
	if minion.has_ability(Abilities.CHALLENGE_ALL) and not game_state.opponent.board.is_empty():
		var enemies := game_state.opponent.board.duplicate()
		for enemy in enemies:
			if minion.is_dead() or minion not in game_state.player.board:
				break
			if enemy not in game_state.opponent.board:
				continue
			board.log_action("Your %s challenged opponent's %s" % [minion.data.card_name, enemy.data.card_name])
			game_state.apply_challenge(minion, enemy)
			await board.animate_creature_challenge(minion.instance_id, LOCAL_PLAYER_ID, enemy.instance_id)
			board.refresh()
			await _announce_pending_draws()
			await _process_pending_tank_shots()
			await _process_pending_rummages()
			await _process_pending_nulls()
			await _process_pending_buff_friendly_health()
			await _process_pending_tank_specialist_buffs()
			await _process_pending_on_reinforce_damages()
			await _process_pending_overwatch_challenges()
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				_handle_game_over()
				return
	if minion.has_ability(Abilities.ON_PLAY_PILOT_MECH):
		var has_target = game_state.player.board.any(func(m): return m != minion and m.has_ability(Abilities.MECH) and not m.is_piloted)
		if has_target:
			board.start_on_play_pilot_targeting(minion)
			var target: Minion = await board.on_play_pilot_target_selected
			if target != null:
				board.log_action("Your %s piloted %s" % [minion.data.card_name, target.data.card_name])
				game_state.apply_pilot(minion, target, game_state.player)
				board.refresh()
	if minion.has_ability(Abilities.ON_PLAY_CHALLENGE_WIN_BUFF) and not game_state.opponent.board.is_empty():
		board.start_challenge_targeting(minion)
		var target: Minion = await board.challenge_target_selected
		if target != null:
			board.log_action("Your %s challenged opponent's %s" % [minion.data.card_name, target.data.card_name])
			game_state.apply_challenge(minion, target)
			await board.animate_creature_challenge(minion.instance_id, LOCAL_PLAYER_ID, target.instance_id)
			board.refresh()
			if minion in game_state.player.board and target not in game_state.opponent.board:
				minion.current_attack += 1
				minion.current_health += 1
				minion.max_health += 1
				game_state._try_apothecary_bonus(LOCAL_PLAYER_ID, minion)
				board.log_action("Your %s won and gained +1/+1!" % minion.data.card_name)
				board.refresh()
			await _announce_pending_draws()
			await _process_pending_tank_shots()
			await _process_pending_rummages()
			await _process_pending_nulls()
			await _process_pending_buff_friendly_health()
			await _process_pending_tank_specialist_buffs()
			await _process_pending_on_reinforce_damages()
			await _process_pending_overwatch_challenges()
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				_handle_game_over()
	if minion.has_ability(Abilities.ON_PLAY_SWAP_FRIENDLY_HEALTH):
		var others := game_state.player.board.filter(func(m): return m != minion)
		if others.size() >= 2:
			board.log_action("Choose first minion to swap health")
			board.start_buff_friendly_targeting(minion)
			var first: Minion = await board.buff_friendly_target_selected
			if first != null:
				board.log_action("Choose second minion to swap health")
				board.start_buff_friendly_targeting(first)
				var second: Minion = await board.buff_friendly_target_selected
				if second != null:
					board.log_action("Swapped health of %s and %s" % [first.data.card_name, second.data.card_name])
					game_state.apply_swap_friendly_health(first, second)
					board.refresh()
	if minion.has_ability(Abilities.ON_PLAY_DEVOUR_FRIENDLY) and minion in game_state.player.board:
		var others := game_state.player.board.filter(func(m): return m != minion)
		if not others.is_empty():
			board.log_action("Choose a friendly minion to devour")
			board.start_buff_friendly_targeting(minion)
			var target: Minion = await board.buff_friendly_target_selected
			if target != null:
				board.log_action("Your %s devoured %s and gained +%d health" % [
					minion.data.card_name, target.data.card_name,
					target.current_health * 2])
				game_state.apply_devour_friendly(minion, target, game_state.player)
				board.refresh()

func _process_pending_tank_shots() -> void:
	while not game_state.pending_tank_shots.is_empty():
		var owner_id: String = game_state.pending_tank_shots.pop_front()
		var source := "Your Tank" if owner_id == LOCAL_PLAYER_ID else "Opponent's Tank"
		if owner_id == LOCAL_PLAYER_ID:
			board.start_tank_shot_targeting()
			var result = await board.tank_shot_resolved
			var target_minion: Minion = result[0]
			var target_player_id: String = result[1]
			if target_minion != null:
				board.log_action("%s dealt 1 damage to %s" % [source, target_minion.data.card_name])
				game_state.apply_on_play_damage(target_minion, 1)
				var _ts_died: bool = target_minion not in game_state.player.board and target_minion not in game_state.opponent.board
				if _ts_died:
					var _ts_tgt: Card = board.find_card_node(target_minion.instance_id)
					var _ts_src: Card = null
					for _m in game_state.player.board:
						if _m.has_ability(Abilities.TANK):
							_ts_src = board.find_card_node(_m.instance_id)
							break
					if _ts_tgt != null:
						var _ts_from: Vector2 = _ts_src.get_parent().get_global_rect().get_center() if _ts_src != null else _ts_tgt.get_parent().get_global_rect().get_center() + Vector2(0, -600)
						await board.animate_laser_kill(_ts_from, _ts_tgt)
			elif target_player_id != "":
				var target_name := "your hero" if target_player_id == LOCAL_PLAYER_ID else "opponent's hero"
				board.log_action("%s dealt 1 damage to the %s" % [source, target_name])
				game_state._get_player_by_id(target_player_id).hero_health -= 1
				game_state._check_win_condition()
		else:
			var target = ai_controller._pick_best_removal_target(game_state.player.board.duplicate(), 1)
			if target != null:
				board.log_action("%s dealt 1 damage to your %s" % [source, target.data.card_name])
				game_state.apply_on_play_damage(target, 1)
				var _ots_died: bool = target not in game_state.player.board and target not in game_state.opponent.board
				if _ots_died:
					var _ots_tgt: Card = board.find_card_node(target.instance_id)
					var _ots_src: Card = null
					for _m in game_state.opponent.board:
						if _m.has_ability(Abilities.TANK):
							_ots_src = board.find_card_node(_m.instance_id)
							break
					if _ots_tgt != null:
						var _ots_from: Vector2 = _ots_src.get_parent().get_global_rect().get_center() if _ots_src != null else _ots_tgt.get_parent().get_global_rect().get_center() + Vector2(0, -600)
						await board.animate_laser_kill(_ots_from, _ots_tgt)
			else:
				board.log_action("%s dealt 1 damage to your hero" % source)
				game_state.player.hero_health -= 1
				game_state._check_win_condition()
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
					await board.animate_creature_challenge(chosen.instance_id, LOCAL_PLAYER_ID, target.instance_id)
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
				await board.animate_creature_challenge(best_yeti.instance_id, OPPONENT_PLAYER_ID, target.instance_id)
				board.refresh()
				if game_state.current_phase == GameState.Phase.GAME_OVER:
					_handle_game_over()
					return

func _process_pending_on_reinforce_damages() -> void:
	while not game_state.pending_on_reinforce_damages.is_empty():
		var entry: Dictionary = game_state.pending_on_reinforce_damages.pop_front()
		var owner_id: String = entry["player_id"]
		var damage: int = entry["damage"]
		var source: String = entry["source"]
		if owner_id == LOCAL_PLAYER_ID:
			board.start_on_play_damage_targeting()
			var result = await board.on_play_damage_target_selected
			var dmg_target: Minion = result[0]
			var dmg_player_id: String = result[1]
			if dmg_target != null:
				board.log_action("Your reinforced %s dealt %d damage to %s" % [source, damage, dmg_target.data.card_name])
				game_state.apply_on_play_damage(dmg_target, damage, LOCAL_PLAYER_ID)
				var _rd_died: bool = dmg_target not in game_state.player.board and dmg_target not in game_state.opponent.board
				if _rd_died:
					var _rd_tgt: Card = board.find_card_node(dmg_target.instance_id)
					var _rd_src: Card = null
					for _m in game_state.player.board:
						if _m.data.card_name == source:
							_rd_src = board.find_card_node(_m.instance_id)
							break
					if _rd_tgt != null:
						var _rd_from: Vector2 = _rd_src.get_parent().get_global_rect().get_center() if _rd_src != null else _rd_tgt.get_parent().get_global_rect().get_center() + Vector2(0, -600)
						await board.animate_laser_kill(_rd_from, _rd_tgt)
				board.refresh()
			elif dmg_player_id != "":
				var target_name := "your hero" if dmg_player_id == LOCAL_PLAYER_ID else "opponent's hero"
				board.log_action("Your reinforced %s dealt %d damage to the %s" % [source, damage, target_name])
				game_state._get_player_by_id(dmg_player_id).hero_health -= damage
				game_state._check_win_condition()
				board.refresh()
		else:
			var target = ai_controller._pick_best_removal_target(game_state.player.board.duplicate(), damage)
			if target != null:
				board.log_action("Opponent's reinforced %s dealt %d damage to your %s" % [source, damage, target.data.card_name])
				game_state.apply_on_play_damage(target, damage, OPPONENT_PLAYER_ID)
				var _ard_died: bool = target not in game_state.player.board and target not in game_state.opponent.board
				if _ard_died:
					var _ard_tgt: Card = board.find_card_node(target.instance_id)
					var _ard_src: Card = null
					for _m in game_state.opponent.board:
						if _m.data.card_name == source:
							_ard_src = board.find_card_node(_m.instance_id)
							break
					if _ard_tgt != null:
						var _ard_from: Vector2 = _ard_src.get_parent().get_global_rect().get_center() if _ard_src != null else _ard_tgt.get_parent().get_global_rect().get_center() + Vector2(0, -600)
						await board.animate_laser_kill(_ard_from, _ard_tgt)
			else:
				board.log_action("Opponent's reinforced %s dealt %d damage to your hero" % [source, damage])
				game_state.player.hero_health -= damage
				game_state._check_win_condition()
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
			var best: Minion = ai_controller._pick_health_buff_target(p.board.duplicate())
			board.log_action("Opponent's Moonchild gave %s +1 max health" % best.data.card_name)
			game_state.apply_buff_friendly_health(best)
			board.refresh()

func _process_pending_tank_specialist_buffs() -> void:
	while not game_state.pending_tank_specialist_buffs.is_empty():
		var player_id: String = game_state.pending_tank_specialist_buffs.pop_front()
		var p = game_state.player if player_id == LOCAL_PLAYER_ID else game_state.opponent
		var tanks: Array[Minion] = []
		for m in p.board:
			if m.data.tribe == "tank":
				tanks.append(m)
		if tanks.is_empty():
			continue
		if player_id == LOCAL_PLAYER_ID:
			board.start_buff_friendly_targeting(null, "tank")
			var target: Minion = await board.buff_friendly_target_selected
			if target != null and target in game_state.player.board and target.data.tribe == "tank":
				board.log_action("Tank Specialist buffed %s (+1/+2)" % target.data.card_name)
				game_state.apply_tank_specialist_buff(target)
				board.refresh()
		else:
			var best := tanks[0]
			for m in tanks:
				if m.current_attack + m.current_health > best.current_attack + best.current_health:
					best = m
			board.log_action("Opponent's Tank Specialist buffed %s (+1/+2)" % best.data.card_name)
			game_state.apply_tank_specialist_buff(best)
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
		var play_it: bool = entry.get("play_it", false)
		var discount: bool = entry.get("discount", true)
		var p_state = game_state.player if player_id == LOCAL_PLAYER_ID else game_state.opponent
		var allow_equal: bool = p_state.board.any(func(m): return m.has_ability(Abilities.RUMMAGE_EQUAL_COST))
		var options = game_state.get_rummage_options(player_id, max_cost, type_filter, allow_equal)
		if options.is_empty():
			continue
		var chosen: CardData
		if player_id == LOCAL_PLAYER_ID:
			chosen = await board.show_graveyard_picker(options)
		else:
			options.sort_custom(func(a, b): return a.cost > b.cost)
			chosen = options[0]
		if chosen:
			var placed: Minion = game_state.complete_rummage(player_id, chosen, play_it, discount)
			board.refresh()
			if placed != null:
				if player_id == LOCAL_PLAYER_ID:
					await _run_player_on_play(placed)
					await _announce_pending_draws()
					await _process_pending_tank_shots()
					await _process_pending_nulls()
					await _process_pending_buff_friendly_health()
					await _process_pending_tank_specialist_buffs()
					await _process_pending_on_reinforce_damages()
					await _process_pending_overwatch_challenges()
					if game_state.current_phase == GameState.Phase.GAME_OVER:
						_handle_game_over()
						return
				else:
					await ai_controller._handle_on_play_effects(placed, game_state, board)

## Also announces fatigue damage (from GameState._begin_turn()'s draw step
## finding an empty deck) so every existing call site gets it for free.
func _announce_pending_draws() -> void:
	for card_data in game_state.pending_drawn_cards:
		board.log_action("Drew %s" % card_data.card_name)
		await board.animate_draw()
	game_state.pending_drawn_cards.clear()
	for player_id in game_state.pending_fatigue_damage:
		var p := game_state._get_player_by_id(player_id)
		var whose := "You" if player_id == LOCAL_PLAYER_ID else "Opponent"
		board.log_action("%s took %d fatigue damage!" % [whose, p.fatigue_damage])
		board.refresh()
	game_state.pending_fatigue_damage.clear()
	# Deliberately not calling _handle_game_over() here even if fatigue just
	# ended the game (GameState._begin_turn() -> _check_win_condition()
	# already flips current_phase to GAME_OVER) — every call site of this
	# function already does its own "if GAME_OVER: _handle_game_over()"
	# check afterward, and calling it here too would fire it twice (e.g.
	# double-reporting a ranked result).

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
	var had_dual_strike := attacker.has_ability(Abilities.DUAL_STRIKE)
	if target_type == "minion":
		var target = _find_minion(OPPONENT_PLAYER_ID, target_id)
		if target:
			board.log_action("Your %s attacked opponent's %s" % [attacker.data.card_name, target.data.card_name])
			game_state.attack(attacker, target)
			await board.animate_creature_attack(attacker_id, LOCAL_PLAYER_ID, target_id)
			if had_dual_strike and attacker in game_state.player.board:
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
	await _process_pending_on_reinforce_damages()
	await _process_pending_overwatch_challenges()
	if game_state.current_phase == GameState.Phase.GAME_OVER:
		_handle_game_over()

func _on_play_stratagem(card_data: CardData, target_minion: Minion, target_player_id: String) -> void:
	if not game_state.is_local_player_turn():
		return
	if not game_state.play_stratagem(LOCAL_PLAYER_ID, card_data, target_minion, target_player_id):
		board.refresh()
		return
	if target_minion != null:
		var _strat_died: bool = target_minion not in game_state.player.board and target_minion not in game_state.opponent.board
		if _strat_died:
			var _strat_tgt: Card = board.find_card_node(target_minion.instance_id)
			if _strat_tgt != null:
				var _strat_from: Vector2 = _strat_tgt.get_parent().get_global_rect().get_center() + Vector2(0, -600)
				await board.animate_laser_kill(_strat_from, _strat_tgt)
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
					await board.animate_creature_challenge(target_minion.instance_id, LOCAL_PLAYER_ID, target.instance_id)
					board.refresh()
					if card_data.effect_value > 0 and target.is_dead() and target_minion in game_state.player.board:
						var win_buff: int = card_data.effect_value
						target_minion.current_attack += win_buff
						target_minion.current_health += win_buff
						target_minion.max_health += win_buff
						game_state._try_apothecary_bonus(LOCAL_PLAYER_ID, target_minion)
						board.log_action("Your %s won and gained +%d/+%d!" % [target_minion.data.card_name, win_buff, win_buff])
						board.refresh()
	if card_data.effect == "poke_bear" and target_minion != null:
		if target_minion in game_state.player.board and target_minion.has_ability(Abilities.YETI):
			if not game_state.opponent.board.is_empty():
				board.start_challenge_targeting(target_minion)
				var target: Minion = await board.challenge_target_selected
				if target != null:
					board.log_action("Your %s challenged opponent's %s" % [target_minion.data.card_name, target.data.card_name])
					game_state.apply_challenge(target_minion, target)
					await board.animate_creature_challenge(target_minion.instance_id, LOCAL_PLAYER_ID, target.instance_id)
					board.refresh()
	if card_data.effect == "blood_transfusion" and target_minion != null:
		if not game_state.player.board.is_empty():
			board.start_buff_friendly_targeting()
			var recipient: Minion = await board.buff_friendly_target_selected
			if recipient != null and recipient in game_state.player.board:
				board.log_action("Blood Transfusion gave %s +2 health" % recipient.data.card_name)
				game_state.apply_heal_buff(recipient, 2)
				board.refresh()
	if card_data.effect == "sanguine" and not game_state.player.board.is_empty():
		board.start_buff_friendly_targeting()
		var recipient: Minion = await board.buff_friendly_target_selected
		if recipient != null and recipient in game_state.player.board:
			board.log_action("Sanguine gave %s +2 health" % recipient.data.card_name)
			game_state.apply_heal_buff(recipient, 2)
			board.refresh()
	await _announce_pending_draws()
	await _process_pending_tank_shots()
	await _process_pending_rummages()
	await _process_pending_nulls()
	await _process_pending_buff_friendly_health()
	await _process_pending_on_reinforce_damages()
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
		await _process_pending_tank_specialist_buffs()
		await _process_pending_on_reinforce_damages()
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
		await _process_pending_tank_specialist_buffs()
		await _process_pending_on_reinforce_damages()
		await _process_pending_overwatch_challenges()
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			_handle_game_over()
			return
		board.log_action("--- Your Turn %d ---" % game_state.turn_number)

func _find_minion(player_id: String, instance_id: String) -> Minion:
	var p = game_state.player if player_id == LOCAL_PLAYER_ID else game_state.opponent
	for minion in p.board:
		if minion.instance_id == instance_id:
			return minion
	return null

func _handle_game_over() -> void:
	var won := game_state.winner_id == LOCAL_PLAYER_ID
	if is_ranked:
		var old_bracket := Auth.rank_bracket
		var old_in_legend := Auth.rank_in_legend
		var old_legend_rating := Auth.rank_legend_rating
		Auth.report_ranked_result(won)
		board.show_game_over(won, true, old_bracket, old_in_legend, old_legend_rating)
	else:
		board.show_game_over(won)
