class_name MpGameManager
extends Node

const HOST_ID = "host"
const GUEST_ID = "guest"

var game_state: GameState
var board: Board
var _my_id: String
var _opp_id: String
var _is_host: bool

# ── Entry points ──────────────────────────────────────────────────────────

func start_as_host(board_node: Board, player_deck: Array[CardData], opp_deck: Array[CardData]) -> void:
	board = board_node
	_my_id = HOST_ID
	_opp_id = GUEST_ID
	_is_host = true

	board.player_hero.player_id = HOST_ID
	board.opponent_hero.player_id = GUEST_ID

	board.action_play_card.connect(_host_on_play_card)
	board.action_play_stratagem.connect(_host_on_play_stratagem)
	board.action_attack.connect(_host_on_attack)
	board.action_pilot.connect(_host_on_pilot)
	board.end_turn_pressed.connect(_host_on_end_turn)

	game_state = GameState.new(HOST_ID, GUEST_ID, player_deck, opp_deck)

	var first := HOST_ID if randi() % 2 == 0 else GUEST_ID
	game_state.start_game(first)
	board.setup(game_state)

	Net.relay({"type": "coinflip", "first": first})
	_send_state()

	await board.show_coinflip_result(first == HOST_ID)
	board.refresh()
	await _host_announce_pending_draws()

	if first == HOST_ID:
		board.log_action("--- Your Turn %d ---" % game_state.turn_number)
	else:
		board.log_action("--- Opponent Turn %d ---" % game_state.turn_number)
		await _host_run_guest_turn()

func start_as_guest(board_node: Board) -> void:
	board = board_node
	_my_id = GUEST_ID
	_opp_id = HOST_ID
	_is_host = false

	board.player_hero.player_id = GUEST_ID
	board.opponent_hero.player_id = HOST_ID

	board.action_play_card.connect(_guest_send_play_card)
	board.action_play_stratagem.connect(_guest_send_play_stratagem)
	board.action_attack.connect(_guest_send_attack)
	board.action_pilot.connect(_guest_send_pilot)
	board.end_turn_pressed.connect(_guest_send_end_turn)

	# Wait for initial state + coinflip
	var state_msg: Dictionary = await Net.await_relay_of_type("state_update")
	_apply_state(state_msg["state"])

	var cf_msg: Dictionary = await Net.await_relay_of_type("coinflip")
	var first: String = str(cf_msg["first"])
	await board.show_coinflip_result(first == GUEST_ID)
	board.refresh()
	await _guest_announce_pending_draws()

	if first == GUEST_ID:
		board.log_action("--- Your Turn %d ---" % game_state.turn_number)
	else:
		board.log_action("--- Opponent Turn %d ---" % game_state.turn_number)

	# Run the persistent guest message loop.
	_run_guest_loop()

# ── Shared helpers ─────────────────────────────────────────────────────────

func _send_state() -> void:
	Net.relay({"type": "state_update", "state": game_state.to_net_dict()})

func _apply_state(d: Dictionary) -> void:
	game_state = GameState.from_net_dict(d, GUEST_ID)
	if board.game_state == null:
		board.setup(game_state)
	else:
		board.game_state = game_state
		board.refresh()

func _find_minion(player_id: String, instance_id: String) -> Minion:
	var p := game_state.player if player_id == _my_id else game_state.opponent
	for m in p.board:
		if m.instance_id == instance_id:
			return m
	return null

# ── Host: action handlers ─────────────────────────────────────────────────

func _host_on_play_card(card_data: CardData) -> void:
	if not game_state.is_local_player_turn():
		return
	var minion := game_state.play_creature(HOST_ID, card_data)
	if minion == null:
		return
	board.log_action("You played %s" % card_data.card_name)
	await get_tree().process_frame
	await get_tree().process_frame
	board.refresh()
	_send_state()
	await _host_process_pending()
	await _host_run_on_play(minion)

func _host_on_attack(attacker_id: String, target_type: String, target_id: String) -> void:
	var attacker := _find_minion(HOST_ID, attacker_id)
	if not attacker:
		return
	if target_type == "minion":
		var target := _find_minion(GUEST_ID, target_id)
		if target:
			board.log_action("Your %s attacked opponent's %s" % [attacker.data.card_name, target.data.card_name])
			game_state.attack(attacker, target)
			await board.animate_creature_attack(attacker_id, HOST_ID, target_id)
	elif target_type == "hero":
		board.log_action("Your %s attacked the opponent's hero" % attacker.data.card_name)
		game_state.attack(attacker, null, target_id)
	board.refresh()
	_send_state()
	await _host_process_pending()
	if game_state.current_phase == GameState.Phase.GAME_OVER:
		_handle_game_over()

func _host_on_play_stratagem(card_data: CardData, target_minion: Minion, target_player_id: String) -> void:
	if not game_state.is_local_player_turn():
		return
	if not game_state.play_stratagem(HOST_ID, card_data, target_minion, target_player_id):
		board.refresh()
		return
	board.log_action("You played %s" % card_data.card_name)
	await get_tree().process_frame
	await get_tree().process_frame
	board.refresh()
	_send_state()
	await _host_stratagem_followup(card_data, target_minion)
	await _host_process_pending()
	if game_state.current_phase == GameState.Phase.GAME_OVER:
		_handle_game_over()

func _host_on_pilot(pilot_id: String, target_id: String) -> void:
	var pilot := _find_minion(HOST_ID, pilot_id)
	var target := _find_minion(HOST_ID, target_id)
	if not pilot or not target:
		return
	var atk_bonus := 0
	var hp_bonus := 0
	for ability in pilot.abilities:
		if Abilities.is_pilot(ability):
			atk_bonus = Abilities.get_pilot_attack(ability)
			hp_bonus = Abilities.get_pilot_health(ability)
			break
	board.log_action("Your %s piloted %s (+%d/+%d)" % [pilot.data.card_name, target.data.card_name, atk_bonus, hp_bonus])
	game_state.apply_pilot(pilot, target, game_state.player)
	board.refresh()
	_send_state()

func _host_on_end_turn() -> void:
	game_state.end_turn()
	board.refresh()
	_send_state()
	board.log_action("--- Opponent Turn %d ---" % game_state.turn_number)
	await _host_run_guest_turn()

# ── Host: guest turn proxy ─────────────────────────────────────────────────

func _host_run_guest_turn() -> void:
	# Process any pending effects that fire at turn start (drawn cards)
	await _host_process_pending()

	while true:
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			_handle_game_over()
			return

		var action: Dictionary = await Net.await_relay_action()
		var t: String = action.get("type", "")

		if t == "action_end_turn":
			game_state.end_turn()
			board.refresh()
			_send_state()
			await _host_process_pending()
			board.log_action("--- Your Turn %d ---" % game_state.turn_number)
			return

		elif t == "action_play_card":
			var card = _find_card_in_hand(GUEST_ID, str(action.get("card_id", "")))
			if card == null:
				continue
			var minion := game_state.play_creature(GUEST_ID, card)
			if minion:
				board.log_action("Opponent played %s" % card.card_name)
				board.refresh()
				_send_state()
				await _host_process_pending()
				await _host_run_guest_on_play(minion)

		elif t == "action_attack":
			var attacker := _find_minion(GUEST_ID, str(action.get("attacker_id", "")))
			if not attacker:
				continue
			var target_type: String = str(action.get("target_type", ""))
			var target_id: String = str(action.get("target_id", ""))
			if target_type == "minion":
				var target := _find_minion(HOST_ID, target_id)
				if target:
					board.log_action("Opponent's %s attacked your %s" % [attacker.data.card_name, target.data.card_name])
					game_state.attack(attacker, target)
					await board.animate_creature_attack(attacker.instance_id, GUEST_ID, target_id)
			elif target_type == "hero":
				board.log_action("Opponent's %s attacked your hero" % attacker.data.card_name)
				game_state.attack(attacker, null, target_id)
			board.refresh()
			_send_state()
			await _host_process_pending()
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				_handle_game_over()
				return

		elif t == "action_play_stratagem":
			var card := _find_card_in_hand(GUEST_ID, str(action.get("card_id", "")))
			if card == null:
				continue
			var target_minion: Minion = null
			var tmid := str(action.get("target_minion_id", ""))
			if tmid != "":
				target_minion = _find_minion_anywhere(tmid)
			var target_player_id: String = str(action.get("target_player_id", ""))
			if not game_state.play_stratagem(GUEST_ID, card, target_minion, target_player_id):
				continue
			board.log_action("Opponent played %s" % card.card_name)
			board.refresh()
			_send_state()
			await _host_stratagem_followup_for_guest(card, target_minion, action)
			await _host_process_pending()
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				_handle_game_over()
				return

		elif t == "action_pilot":
			var pilot := _find_minion(GUEST_ID, str(action.get("pilot_id", "")))
			var target := _find_minion(GUEST_ID, str(action.get("target_id", "")))
			if pilot and target:
				game_state.apply_pilot(pilot, target, game_state.opponent)
				board.refresh()
				_send_state()

# ── Host: pending effects ──────────────────────────────────────────────────

func _host_process_pending() -> void:
	await _host_announce_pending_draws()
	await _host_process_tank_shots()
	await _host_process_rummages()
	await _host_process_nulls()
	await _host_process_buff_friendly()
	await _host_process_reinforce_damages()
	await _host_process_overwatch()

func _host_announce_pending_draws() -> void:
	if game_state.pending_drawn_cards.is_empty():
		return
	for card_data in game_state.pending_drawn_cards:
		board.log_action("Drew %s" % card_data.card_name)
		await board.animate_draw()
	game_state.pending_drawn_cards.clear()
	_send_state()

func _host_process_tank_shots() -> void:
	while not game_state.pending_tank_shots.is_empty():
		var owner_id: String = game_state.pending_tank_shots.pop_front()
		var source := "Your Tank" if owner_id == HOST_ID else "Opponent's Tank"
		if owner_id == HOST_ID:
			board.start_tank_shot_targeting()
			var result = await board.tank_shot_resolved
			var dmg_target: Minion = result[0]
			var dmg_player_id: String = result[1]
			if dmg_target != null:
				board.log_action("%s dealt 1 damage to %s" % [source, dmg_target.data.card_name])
				game_state.apply_on_play_damage(dmg_target, 1)
			elif dmg_player_id != "":
				game_state._get_player_by_id(dmg_player_id).hero_health -= 1
				game_state._check_win_condition()
		else:
			Net.relay({"type": "prompt_tank_shot"})
			_send_state()
			var resp: Dictionary = await Net.await_relay_of_type("response_tank_shot")
			var tmid := str(resp.get("target_minion_id", ""))
			var tpid := str(resp.get("target_player_id", ""))
			if tmid != "":
				var t := _find_minion_anywhere(tmid)
				if t:
					board.log_action("%s dealt 1 damage to %s" % [source, t.data.card_name])
					game_state.apply_on_play_damage(t, 1)
			elif tpid != "":
				game_state._get_player_by_id(tpid).hero_health -= 1
				game_state._check_win_condition()
		board.refresh()
		_send_state()
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			_handle_game_over()
			return

func _host_process_rummages() -> void:
	while not game_state.pending_rummages.is_empty():
		var entry = game_state.pending_rummages.pop_front()
		var player_id: String = entry["player_id"]
		var max_cost: int = entry["max_cost"]
		var type_filter: String = entry.get("type_filter", "")
		var play_it: bool = entry.get("play_it", false)
		var discount: bool = entry.get("discount", true)
		var options = game_state.get_rummage_options(player_id, max_cost, type_filter)
		if options.is_empty():
			continue
		var chosen: CardData
		if player_id == HOST_ID:
			chosen = await board.show_graveyard_picker(options)
		else:
			var opt_ids = options.map(func(c): return c.id)
			Net.relay({"type": "prompt_rummage", "options": opt_ids})
			_send_state()
			var resp: Dictionary = await Net.await_relay_of_type("response_rummage")
			var cid := str(resp.get("card_id", ""))
			chosen = null
			for o in options:
				if o.id == cid:
					chosen = o
					break
		if chosen != null:
			var placed: Minion = game_state.complete_rummage(player_id, chosen, play_it, discount)
			board.refresh()
			_send_state()
			if placed != null:
				if player_id == HOST_ID:
					await _host_run_on_play(placed)
				else:
					await _host_run_guest_on_play(placed)
				await _host_process_pending()

func _host_process_nulls() -> void:
	while not game_state.pending_nulls.is_empty():
		var entry: Dictionary = game_state.pending_nulls.pop_front()
		var player_id: String = entry["player_id"]
		var source_name: String = entry["source"]
		var all_minions: Array[Minion] = game_state.player.board.duplicate()
		all_minions.append_array(game_state.opponent.board.duplicate())
		if all_minions.is_empty():
			continue
		if player_id == HOST_ID:
			board.start_null_targeting()
			var target: Minion = await board.null_target_selected
			if target != null and (target in game_state.player.board or target in game_state.opponent.board):
				board.log_action("Your %s silenced %s" % [source_name, target.data.card_name])
				game_state.apply_null(target)
		else:
			Net.relay({"type": "prompt_null"})
			_send_state()
			var resp: Dictionary = await Net.await_relay_of_type("response_null")
			var t := _find_minion_anywhere(str(resp.get("target_id", "")))
			if t:
				board.log_action("Opponent's %s silenced %s" % [source_name, t.data.card_name])
				game_state.apply_null(t)
		board.refresh()
		_send_state()

func _host_process_buff_friendly() -> void:
	while not game_state.pending_buff_friendly_health.is_empty():
		var player_id: String = game_state.pending_buff_friendly_health.pop_front()
		var p := game_state.player if player_id == HOST_ID else game_state.opponent
		if p.board.is_empty():
			continue
		if player_id == HOST_ID:
			board.start_buff_friendly_targeting()
			var target: Minion = await board.buff_friendly_target_selected
			if target != null and target in game_state.player.board:
				board.log_action("Your Moonchild gave %s +1 max health" % target.data.card_name)
				game_state.apply_buff_friendly_health(target)
		else:
			Net.relay({"type": "prompt_buff_friendly"})
			_send_state()
			var resp: Dictionary = await Net.await_relay_of_type("response_buff_friendly")
			var t := _find_minion_anywhere(str(resp.get("target_id", "")))
			if t and t in game_state.opponent.board:
				board.log_action("Opponent's Moonchild gave %s +1 max health" % t.data.card_name)
				game_state.apply_buff_friendly_health(t)
		board.refresh()
		_send_state()

func _host_process_reinforce_damages() -> void:
	while not game_state.pending_on_reinforce_damages.is_empty():
		var entry: Dictionary = game_state.pending_on_reinforce_damages.pop_front()
		var player_id: String = entry["player_id"]
		var damage: int = entry["damage"]
		var source: String = entry["source"]
		if player_id == HOST_ID:
			board.start_on_play_damage_targeting()
			var result = await board.on_play_damage_target_selected
			var dmg_target: Minion = result[0]
			var dmg_player_id: String = result[1]
			if dmg_target != null:
				board.log_action("Your reinforced %s dealt %d damage to %s" % [source, damage, dmg_target.data.card_name])
				game_state.apply_on_play_damage(dmg_target, damage)
			elif dmg_player_id != "":
				game_state._get_player_by_id(dmg_player_id).hero_health -= damage
				game_state._check_win_condition()
		else:
			Net.relay({"type": "prompt_on_play_damage", "damage": damage})
			_send_state()
			var resp: Dictionary = await Net.await_relay_of_type("response_on_play_damage")
			var tmid := str(resp.get("target_minion_id", ""))
			var tpid := str(resp.get("target_player_id", ""))
			if tmid != "":
				var t := _find_minion_anywhere(tmid)
				if t:
					game_state.apply_on_play_damage(t, damage)
			elif tpid != "":
				game_state._get_player_by_id(tpid).hero_health -= damage
				game_state._check_win_condition()
		board.refresh()
		_send_state()
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			_handle_game_over()
			return

func _host_process_overwatch() -> void:
	while not game_state.pending_overwatch_challenges.is_empty():
		var owner_id: String = game_state.pending_overwatch_challenges.pop_front()
		var owner_state := game_state.player if owner_id == HOST_ID else game_state.opponent
		var enemy_state := game_state.opponent if owner_id == HOST_ID else game_state.player
		var available_yetis: Array[Minion] = []
		for m in owner_state.board:
			if m.has_ability(Abilities.YETI):
				available_yetis.append(m)
		if available_yetis.is_empty() or enemy_state.board.is_empty():
			continue
		var chosen_yeti: Minion = null
		var target: Minion = null
		if owner_id == HOST_ID:
			board.start_yeti_selection()
			chosen_yeti = await board.yeti_selected
			if chosen_yeti != null and not enemy_state.board.is_empty():
				board.start_challenge_targeting(chosen_yeti)
				target = await board.challenge_target_selected
		else:
			Net.relay({"type": "prompt_overwatch"})
			_send_state()
			var resp: Dictionary = await Net.await_relay_of_type("response_overwatch")
			var yid := str(resp.get("yeti_id", ""))
			var tid := str(resp.get("target_id", ""))
			chosen_yeti = _find_minion(GUEST_ID, yid) if yid != "" else null
			target = _find_minion_anywhere(tid) if tid != "" else null
		if chosen_yeti != null and target != null:
			board.log_action("Overwatch: %s's %s challenged %s" % [owner_id, chosen_yeti.data.card_name, target.data.card_name])
			game_state.apply_challenge(chosen_yeti, target)
			var owner_player_id = HOST_ID if owner_id == HOST_ID else GUEST_ID
			await board.animate_creature_challenge(chosen_yeti.instance_id, owner_player_id, target.instance_id)
			board.refresh()
			_send_state()
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				_handle_game_over()
				return

# ── Host: on-play handlers ─────────────────────────────────────────────────

func _host_run_on_play(minion: Minion) -> void:
	if minion.has_ability(Abilities.ON_PLAY_TRANSFORM_CHOICE) and not minion.data.transform_choices.is_empty():
		var options: Array[CardData] = []
		for cid in minion.data.transform_choices:
			var cd = CardDatabase.get_card(cid)
			if cd != null:
				options.append(cd)
		if not options.is_empty():
			var chosen: CardData = await board.show_transform_picker(options)
			if chosen != null:
				game_state.apply_transform_choice(minion, chosen.id)
				board.refresh()
				_send_state()
	for ability in minion.abilities.duplicate():
		if Abilities.is_on_play_damage(ability):
			var damage := Abilities.get_on_play_damage_value(ability)
			board.start_on_play_damage_targeting()
			var result = await board.on_play_damage_target_selected
			var dmg_target: Minion = result[0]
			var dmg_player_id: String = result[1]
			if dmg_target != null:
				game_state.apply_on_play_damage(dmg_target, damage)
			elif dmg_player_id != "":
				game_state._get_player_by_id(dmg_player_id).hero_health -= damage
				game_state._check_win_condition()
			board.refresh()
			_send_state()
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
			await board.animate_creature_challenge(minion.instance_id, HOST_ID, target.instance_id)
			board.refresh()
			_send_state()
			await _host_process_pending()
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				_handle_game_over()
	if minion.has_ability(Abilities.CHALLENGE_ALL) and not game_state.opponent.board.is_empty():
		var enemies := game_state.opponent.board.duplicate()
		for enemy in enemies:
			if minion.is_dead() or minion not in game_state.player.board:
				break
			if enemy not in game_state.opponent.board:
				continue
			game_state.apply_challenge(minion, enemy)
			await board.animate_creature_challenge(minion.instance_id, HOST_ID, enemy.instance_id)
			board.refresh()
			_send_state()
			await _host_process_pending()
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				_handle_game_over()
				return
	if minion.has_ability(Abilities.ON_PLAY_CHALLENGE_WIN_BUFF) and not game_state.opponent.board.is_empty():
		board.start_challenge_targeting(minion)
		var target: Minion = await board.challenge_target_selected
		if target != null:
			game_state.apply_challenge(minion, target)
			await board.animate_creature_challenge(minion.instance_id, HOST_ID, target.instance_id)
			board.refresh()
			_send_state()
			if minion in game_state.player.board and target not in game_state.opponent.board:
				minion.current_attack += 1
				minion.current_health += 1
				minion.max_health += 1
				game_state._try_apothecary_bonus(HOST_ID, minion)
				board.refresh()
				_send_state()
			await _host_process_pending()
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				_handle_game_over()

func _host_run_guest_on_play(minion: Minion) -> void:
	for ability in minion.abilities.duplicate():
		if Abilities.is_on_play_damage(ability):
			var damage := Abilities.get_on_play_damage_value(ability)
			Net.relay({"type": "prompt_on_play_damage", "damage": damage})
			_send_state()
			var resp: Dictionary = await Net.await_relay_of_type("response_on_play_damage")
			var tmid := str(resp.get("target_minion_id", ""))
			var tpid := str(resp.get("target_player_id", ""))
			if tmid != "":
				var t := _find_minion_anywhere(tmid)
				if t:
					game_state.apply_on_play_damage(t, damage)
			elif tpid != "":
				game_state._get_player_by_id(tpid).hero_health -= damage
				game_state._check_win_condition()
			board.refresh()
			_send_state()
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				_handle_game_over()
				return
			break
	if minion.has_ability(Abilities.CHALLENGE) and not game_state.player.board.is_empty():
		Net.relay({"type": "prompt_challenge", "challenger_id": minion.instance_id})
		_send_state()
		var resp: Dictionary = await Net.await_relay_of_type("response_challenge")
		var target := _find_minion(HOST_ID, str(resp.get("target_id", "")))
		if target != null:
			game_state.apply_challenge(minion, target)
			await board.animate_creature_challenge(minion.instance_id, GUEST_ID, target.instance_id)
			board.refresh()
			_send_state()
			await _host_process_pending()
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				_handle_game_over()

func _host_stratagem_followup(card_data: CardData, target_minion: Minion) -> void:
	if card_data.effect == "force_challenge" and target_minion != null:
		if target_minion.owner_id == HOST_ID and target_minion.has_ability(Abilities.YETI) and not game_state.opponent.board.is_empty():
			board.start_challenge_targeting(target_minion)
			var target: Minion = await board.challenge_target_selected
			if target != null:
				game_state.apply_challenge(target_minion, target)
				await board.animate_creature_challenge(target_minion.instance_id, HOST_ID, target.instance_id)
				if card_data.effect_value > 0 and target.is_dead() and target_minion in game_state.player.board:
					target_minion.current_attack += card_data.effect_value
					target_minion.current_health += card_data.effect_value
					target_minion.max_health += card_data.effect_value
					game_state._try_apothecary_bonus(HOST_ID, target_minion)
				board.refresh()
				_send_state()
	if card_data.effect == "poke_bear" and target_minion != null:
		if target_minion in game_state.player.board and target_minion.has_ability(Abilities.YETI) and not game_state.opponent.board.is_empty():
			board.start_challenge_targeting(target_minion)
			var target: Minion = await board.challenge_target_selected
			if target != null:
				game_state.apply_challenge(target_minion, target)
				await board.animate_creature_challenge(target_minion.instance_id, HOST_ID, target.instance_id)
				board.refresh()
				_send_state()
	if card_data.effect == "blood_transfusion" and target_minion != null and not game_state.player.board.is_empty():
		board.start_buff_friendly_targeting()
		var recipient: Minion = await board.buff_friendly_target_selected
		if recipient != null and recipient in game_state.player.board:
			game_state.apply_heal_buff(recipient, 2)
			board.refresh()
			_send_state()
	if card_data.effect == "sanguine" and not game_state.player.board.is_empty():
		board.start_buff_friendly_targeting()
		var recipient: Minion = await board.buff_friendly_target_selected
		if recipient != null and recipient in game_state.player.board:
			game_state.apply_heal_buff(recipient, 2)
			board.refresh()
			_send_state()

func _host_stratagem_followup_for_guest(card_data: CardData, target_minion: Minion, _action: Dictionary) -> void:
	if card_data.effect == "force_challenge" and target_minion != null:
		if target_minion.owner_id == GUEST_ID and target_minion.has_ability(Abilities.YETI) and not game_state.player.board.is_empty():
			Net.relay({"type": "prompt_challenge", "challenger_id": target_minion.instance_id})
			_send_state()
			var resp: Dictionary = await Net.await_relay_of_type("response_challenge")
			var t := _find_minion(HOST_ID, str(resp.get("target_id", "")))
			if t != null:
				game_state.apply_challenge(target_minion, t)
				if card_data.effect_value > 0 and t.is_dead() and target_minion in game_state.opponent.board:
					target_minion.current_attack += card_data.effect_value
					target_minion.current_health += card_data.effect_value
					target_minion.max_health += card_data.effect_value
				board.refresh()
				_send_state()
	if card_data.effect == "blood_transfusion" and target_minion != null and not game_state.opponent.board.is_empty():
		Net.relay({"type": "prompt_buff_friendly"})
		_send_state()
		var resp: Dictionary = await Net.await_relay_of_type("response_buff_friendly")
		var t := _find_minion(GUEST_ID, str(resp.get("target_id", "")))
		if t != null and t in game_state.opponent.board:
			game_state.apply_heal_buff(t, 2)
			board.refresh()
			_send_state()
	if card_data.effect == "sanguine" and not game_state.opponent.board.is_empty():
		Net.relay({"type": "prompt_buff_friendly"})
		_send_state()
		var resp: Dictionary = await Net.await_relay_of_type("response_buff_friendly")
		var t := _find_minion(GUEST_ID, str(resp.get("target_id", "")))
		if t != null and t in game_state.opponent.board:
			game_state.apply_heal_buff(t, 2)
			board.refresh()
			_send_state()

# ── Guest: send actions ────────────────────────────────────────────────────

func _guest_send_play_card(card_data: CardData) -> void:
	if not game_state.is_local_player_turn():
		return
	Net.relay({"type": "action_play_card", "card_id": card_data.id})

func _guest_send_attack(attacker_id: String, target_type: String, target_id: String) -> void:
	Net.relay({"type": "action_attack", "attacker_id": attacker_id, "target_type": target_type, "target_id": target_id})

func _guest_send_play_stratagem(card_data: CardData, target_minion: Minion, target_player_id: String) -> void:
	if not game_state.is_local_player_turn():
		return
	Net.relay({
		"type": "action_play_stratagem",
		"card_id": card_data.id,
		"target_minion_id": target_minion.instance_id if target_minion != null else "",
		"target_player_id": target_player_id,
	})

func _guest_send_pilot(pilot_id: String, target_id: String) -> void:
	Net.relay({"type": "action_pilot", "pilot_id": pilot_id, "target_id": target_id})

func _guest_send_end_turn() -> void:
	Net.relay({"type": "action_end_turn"})

# ── Guest: receive state / prompts ─────────────────────────────────────────

func _run_guest_loop() -> void:
	while true:
		# Drain any queued prompts first.
		await _guest_handle_prompts()

		# Wait for any incoming relay message.
		await Net._queue_updated
		await _guest_handle_prompts()

		# Check for state_update — apply and log turn change.
		var state_msg = Net.pop_of_type("state_update")
		if state_msg != null:
			var was_my_turn := game_state != null and game_state.is_local_player_turn()
			_apply_state(state_msg["state"])
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				board.show_game_over(game_state.winner_id == GUEST_ID)
				return
			var is_my_turn_now := game_state.is_local_player_turn()
			if not was_my_turn and is_my_turn_now:
				await _guest_announce_pending_draws()
				board.log_action("--- Your Turn %d ---" % game_state.turn_number)
			elif was_my_turn and not is_my_turn_now:
				board.log_action("--- Opponent Turn %d ---" % game_state.turn_number)

func _guest_handle_prompts() -> void:
	# Check for any outstanding prompts queued before this function ran
	while true:
		var prompt = _peek_prompt()
		if prompt == null:
			return
		Net._relay_queue.erase(prompt)
		await _guest_respond_to_prompt(prompt)

func _peek_prompt() -> Variant:
	for msg in Net._relay_queue:
		var t: String = msg.get("type", "")
		if t.begins_with("prompt_"):
			return msg
	return null

func _guest_respond_to_prompt(prompt: Dictionary) -> void:
	var t: String = prompt.get("type", "")
	match t:
		"prompt_tank_shot":
			board.start_tank_shot_targeting()
			var result = await board.tank_shot_resolved
			Net.relay({
				"type": "response_tank_shot",
				"target_minion_id": result[0].instance_id if result[0] != null else "",
				"target_player_id": result[1] if result[0] == null else "",
			})
		"prompt_rummage":
			var opt_ids: Array = prompt.get("options", [])
			var options: Array[CardData] = []
			for oid in opt_ids:
				var c = CardDatabase.get_card(str(oid))
				if c != null:
					options.append(c)
			var chosen: CardData = await board.show_graveyard_picker(options)
			Net.relay({"type": "response_rummage", "card_id": chosen.id if chosen != null else ""})
		"prompt_null":
			board.start_null_targeting()
			var target: Minion = await board.null_target_selected
			Net.relay({"type": "response_null", "target_id": target.instance_id if target != null else ""})
		"prompt_buff_friendly":
			board.start_buff_friendly_targeting()
			var target: Minion = await board.buff_friendly_target_selected
			Net.relay({"type": "response_buff_friendly", "target_id": target.instance_id if target != null else ""})
		"prompt_on_play_damage":
			board.start_on_play_damage_targeting()
			var result = await board.on_play_damage_target_selected
			Net.relay({
				"type": "response_on_play_damage",
				"target_minion_id": result[0].instance_id if result[0] != null else "",
				"target_player_id": result[1] if result[0] == null else "",
			})
		"prompt_challenge":
			var challenger := _find_minion(GUEST_ID, str(prompt.get("challenger_id", "")))
			if challenger != null and not game_state.opponent.board.is_empty():
				board.start_challenge_targeting(challenger)
				var target: Minion = await board.challenge_target_selected
				Net.relay({"type": "response_challenge", "target_id": target.instance_id if target != null else ""})
			else:
				Net.relay({"type": "response_challenge", "target_id": ""})
		"prompt_overwatch":
			board.start_yeti_selection()
			var yeti: Minion = await board.yeti_selected
			if yeti != null and not game_state.opponent.board.is_empty():
				board.start_challenge_targeting(yeti)
				var target: Minion = await board.challenge_target_selected
				Net.relay({
					"type": "response_overwatch",
					"yeti_id": yeti.instance_id,
					"target_id": target.instance_id if target != null else "",
				})
			else:
				Net.relay({"type": "response_overwatch", "yeti_id": "", "target_id": ""})

func _guest_announce_pending_draws() -> void:
	if game_state.pending_drawn_cards.is_empty():
		return
	for card_data in game_state.pending_drawn_cards:
		board.log_action("Drew %s" % card_data.card_name)
		await board.animate_draw()
	game_state.pending_drawn_cards.clear()

# ── Shared utilities ───────────────────────────────────────────────────────

func _find_minion_anywhere(instance_id: String) -> Minion:
	for m in game_state.player.board:
		if m.instance_id == instance_id:
			return m
	for m in game_state.opponent.board:
		if m.instance_id == instance_id:
			return m
	return null

func _find_card_in_hand(player_id: String, card_id: String) -> CardData:
	var p := game_state.player if player_id == _my_id else game_state.opponent
	for c in p.hand:
		if c.id == card_id:
			return c
	return null

func _handle_game_over() -> void:
	if _is_host:
		Net.relay({"type": "game_over", "winner_id": game_state.winner_id})
		_send_state()
	board.show_game_over(game_state.winner_id == _my_id)
