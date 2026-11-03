extends Node

const BoardScene = preload("res://scenes/game/Board.tscn")
var failures: Array[String] = []

class TestBoard extends Board:
	var mulligan_sizes: Array[int] = []
	func show_coinflip_result(_first: bool) -> void:
		pass
	func show_mulligan_screen(hand: Array[CardData], swaps: Callable = Callable()) -> Array[CardData]:
		mulligan_sizes.append(hand.size())
		return await super.show_mulligan_screen(hand, swaps)

class TestClient extends RemoteMatchClient:
	var server: GameState
	var sent: Array[Dictionary] = []
	var number: int = 0
	func publish(my_id: String) -> void:
		_on_net_message({"type": "match_view", "seq": number, "you": my_id,
			"seat": "a" if my_id == "host" else "b", "view": server.to_net_dict(my_id), "events": []})
	func _send_command(cmd: Dictionary) -> bool:
		sent.append(cmd.duplicate(true))
		var command := cmd.duplicate(true)
		command["actor"] = _my_id
		var result := server.execute(command)
		if not result["ok"]:
			return false
		number += 1
		_on_net_message({"type": "match_ack"})
		publish(_my_id)
		return true

func _ready() -> void:
	Net.set_process(false)
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
		push_error(label)

func deck() -> Array[CardData]:
	var cards: Array[CardData] = []
	for _i in 20: cards.append(CardDatabase.get_card("gen_013"))
	return cards

func frames(count: int = 4) -> void:
	for _i in count: await get_tree().process_frame

func key(code: Key) -> void:
	var pressed := InputEventKey.new()
	pressed.keycode = code
	pressed.pressed = true
	Input.parse_input_event(pressed)
	await frames(2)
	var released := InputEventKey.new()
	released.keycode = code
	Input.parse_input_event(released)
	await frames(2)

func remote_case(my_id: String, timeout: bool) -> void:
	var gs := GameState.new("host", "guest", deck(), deck(), 77)
	gs.start_game("host")
	gs.begin_mulligan(true)
	var board = BoardScene.instantiate()
	board.set_script(TestBoard)
	board.is_online = true
	board.auto_confirm_mulligan = true
	add_child(board)
	var client := TestClient.new()
	client.board = board
	client.server = gs
	add_child(client)
	client._build_status_overlay()
	client.publish(my_id)
	await frames()
	check(board.mulligan_sizes.is_empty(), "neither seat mulligans before choice")
	check(board.end_turn_button.disabled, "opening blocks the turn button")
	if my_id == "guest":
		check(board.opening_picker_visible(), "second player sees the real bonus picker")
		check(get_viewport().gui_get_focus_owner() is Button, "opening options receive keyboard focus")
		if timeout:
			gs.apply_timeout("guest")
			client.number += 1
			client.publish(my_id)
		else:
			await key(KEY_DOWN)
			await key(KEY_ENTER)
		await frames(12)
		check(not board.opening_picker_visible(), "selection or timeout dismisses picker")
		check(board.mulligan_sizes == [5 if timeout else 4], "real remote mulligan receives selected deck hand count")
		check(gs.opening_bonus["selection"] == ("five_cards" if timeout else "coin"), "keyboard selects Coin, timeout selects five")
		check(client.sent.filter(func(cmd): return cmd["type"] == "answer_choice").size() == (0 if timeout else 1), "timeout sends no stale answer; keyboard sends once")
	else:
		check(not board.opening_picker_visible(), "first player cannot answer opponent's bonus")
		check("opening bonus" in client._status_label.text, "first player gets waiting status")
		gs.execute({"type": "answer_choice", "actor": "guest", "choice_id": "choice-1", "selection": "token"})
		client.number += 1
		client.publish(my_id)
		await frames(12)
		check(board.mulligan_sizes == [3], "waiting first player starts their three-card mulligan afterward")
	# A duplicate/reconnect view must not reopen the completed mulligan.
	client.publish(my_id)
	await frames()
	check(board.mulligan_sizes.size() == 1, "rejoined view cannot reopen mulligan")
	client.queue_free()
	board.queue_free()
	await frames()

func local_case(seed_value: int) -> String:
	var board = BoardScene.instantiate()
	board.set_script(TestBoard)
	board.auto_confirm_mulligan = true
	add_child(board)
	var manager = load("res://scripts/game/game_manager.gd").new()
	add_child(manager)
	var done := {"ready": false}
	seed(seed_value)
	var start := func():
		await manager.start_local_game(board, deck(), deck(), 4, true)
		done["ready"] = true
	start.call()
	for _i in 600:
		if done["ready"]: break
		if board.opening_picker_visible(): await key(KEY_ENTER)
		await frames(1)
	check(done["ready"], "real ranked-AI fallback finishes its opening")
	check(not manager.game_state.opening_choice_pending() and manager.game_state.mulligan_pending.is_empty(), "ranked-AI fallback resolves choice before both mulligans")
	check(board.mulligan_sizes.size() == 1, "local fallback shows one human mulligan")
	var second := str(manager.game_state.opening_bonus.get("player_id", ""))
	check(not second.is_empty(), "local ranked enables opening experiment")
	manager.queue_free()
	board.queue_free()
	await frames()
	return second

func coin_drag_case() -> void:
	var gs := GameState.new("host", "guest", deck(), deck(), 77)
	gs.start_game("guest")
	gs.begin_mulligan(true)
	gs.execute({"type": "answer_choice", "actor": "host", "choice_id": "choice-1", "selection": "coin"})
	for who in ["host", "guest"]: gs.execute({"type": "mulligan", "actor": who, "card_uids": []})
	gs.execute({"type": "end_turn", "actor": "guest"})
	gs.player.max_mana = 10
	var board := BoardScene.instantiate() as Board
	add_child(board)
	board.setup(gs)
	await frames()
	var plays := {"count": 0}
	board.action_play_stratagem.connect(func(card: CardData, target: Minion, player_id: String):
		check(target == null and player_id.is_empty(), "human Coin needs no target")
		var result := gs.execute({"type": "play_stratagem", "actor": "host", "card_uid": card.uid})
		check(result["ok"], "human Coin drop reaches real rules")
		plays["count"] += 1)
	var coin_node: Card = null
	for wrapper in board.player_hand_zone.get_children():
		var candidate := board._get_card_child(wrapper)
		if candidate.data.id == GameState.OPENING_COIN_ID: coin_node = candidate
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2.ZERO # empty space, outside either hero/board
	Input.parse_input_event(motion)
	coin_node.start_drag()
	board._on_card_dropped(coin_node)
	await frames()
	check(plays["count"] == 1 and gs.player.max_mana - gs.player.current_mana == 11, "empty-space drop consumes Coin and grants eleven usable mana at cap")
	board.refresh()
	await frames()
	var paid := board._get_card_child(board.player_hand_zone.get_child(0))
	board._on_card_drag_started(paid)
	board._set_flash_alpha(0.5)
	check(board.mana_label.visible and board.mana_label.text == "11 mana", "overflow mana stays readable while dragging a paid card")
	board._stop_mana_flash()
	board.queue_free()
	await frames()

func _run() -> void:
	await remote_case("guest", false)
	await remote_case("guest", true)
	await remote_case("host", false)
	var local_seats := {}
	for seed_value in range(6):
		local_seats[await local_case(seed_value)] = true
		if local_seats.size() == 2: break
	check(local_seats.size() == 2, "human and AI can each receive the local ranked choice")
	await coin_drag_case()
	# Ordinary AI can choose and actually use the zero-cost Coin through search.
	var rush_deck: Array[CardData] = []
	for _i in 20: rush_deck.append(CardDatabase.get_card("cr_016"))
	var gs := GameState.new("host", "guest", deck(), rush_deck, 22)
	gs.start_game("host")
	gs.begin_mulligan(true)
	check(AIHeuristics.pick_choice_answer(gs, gs.pending_choice) in gs.pending_choice["options"], "fallback AI selects a legal bonus")
	gs.execute({"type": "answer_choice", "actor": "guest", "choice_id": "choice-1", "selection": "coin"})
	for who in ["host", "guest"]: gs.execute({"type": "mulligan", "actor": who, "card_uids": []})
	gs.execute({"type": "end_turn", "actor": "host"})
	gs.player.hero_health = 3
	# Coin unlocks a two-cost Rush creature and lethal now, so holding it is wrong.
	var engine := MCTSEngine.new("guest", 10)
	engine._search_rng.seed = 991
	var chosen := await engine.choose_action(gs)
	check(chosen.get("type") == "play_stratagem", "AI plans to play Coin for its extra mana")
	check(gs.execute(chosen)["ok"], "planned Coin command is valid")
	engine.advance_after_real_action(gs)
	var follow := await engine.choose_action(gs)
	check(follow.get("type") == "play_creature" and gs.execute(follow)["ok"], "AI spends temporary mana on a creature")
	engine.advance_after_real_action(gs)
	check(gs.execute(await engine.choose_action(gs))["ok"] and gs.winner_id == "guest", "AI completes Coin into Rush lethal")
	print("OPENING_CHOICE_RESULT ", JSON.stringify({"failures": failures}))
	get_tree().quit(failures.size())
