extends Node

const BoardScene = preload("res://scenes/game/Board.tscn")
var failures: Array[String] = []

func _ready() -> void:
	Net.set_process(false)
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)

func hand(gs: GameState, id: String) -> CardData:
	var card := CardDatabase.get_card(id).new_instance(gs.player.mint_card_uid())
	gs.player.hand.append(card)
	return card

func show_picker(board: Board, choice: Dictionary, answer: Dictionary) -> void:
	answer["selection"] = await board.prompt_choice(choice)

func _run() -> void:
	check(Net._ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, "fixture must not connect to a relay")
	var gs := GameState.new("host", "guest", [], [])
	gs.active_player_id = "host"
	gs.current_phase = GameState.Phase.PLAYER_TURN
	gs.player.max_mana = 10
	for i in 11:
		gs.player.graveyard.append(CardDatabase.get_card("b_009").new_instance(gs.player.mint_card_uid()))
	var runt := hand(gs, "b_028")
	var played := gs.execute({"type": "play_creature", "actor": "host", "card_uid": runt.uid})
	check(played["ok"], "Runt play accepted")
	var body: Minion = played["minion"]
	var strike := hand(gs, "gen_str_001")
	check(gs.execute({"type": "play_stratagem", "actor": "host", "card_uid": strike.uid, "target_instance_id": body.instance_id})["ok"], "Runt killed by an actual stratagem")
	var scummer := hand(gs, "b_004")
	check(gs.execute({"type": "play_creature", "actor": "host", "card_uid": scummer.uid})["ok"], "Rummage source played")
	check(gs.has_pending_choice() and "b_028" in gs.pending_choice["options"], "Runt can be Rummaged")
	for network in [false, true]:
		var view := GameState.from_net_dict(gs.to_net_dict("host"), "host") if network else gs
		var board: Board = BoardScene.instantiate()
		add_child(board)
		board.setup(view)
		var answer := {}
		show_picker.call_deferred(board, view.pending_choice, answer)
		await get_tree().process_frame
		await get_tree().process_frame
		var displayed: Card = null
		for node in board.find_children("*", "", true, false):
			if node is Card and node.data != null and node.data.id == "b_028":
				displayed = node
				break
		check(displayed != null, "actual Rummage picker contains Runt")
		if displayed != null:
			check(displayed.health_label.text == "2" and displayed.data.uid == runt.uid,
				"Rummage picker shows the physical 1/2 Runt: " + ("network" if network else "local"))
			var button: Button = displayed.get_parent()
			button.pressed.emit()
			await get_tree().process_frame
			check(answer.get("selection") == "b_028", "picker returns the original ID-based answer")
		else:
			board.rummage_card_selected.emit(null)
			await get_tree().process_frame
		board._keyword_pending_data = CardDatabase.get_card("g_030")
		board._build_keyword_blocks()
		var labels := board._keyword_vbox.find_children("*", "Label", true, false)
		check(labels.any(func(label): return label.text == "Headshot"), "Beam renders the Headshot keyword tooltip")
		board.queue_free()
		await get_tree().process_frame
	print("HEADSHOT_CARDS_RESULT ", JSON.stringify({"failures": failures}))
	get_tree().quit(failures.size())
