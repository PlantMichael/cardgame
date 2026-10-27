extends Node

## Drives the real local-game result producer into a localhost test relay.
## Main.tscn is not loaded, so no login or production connection is attempted.
func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var url := OS.get_environment("AI_TEST_URL")
	if not url.begins_with("ws://127.0.0.1:"):
		get_tree().quit(1)
		return
	Net._ws.connect_to_url(url)
	await Net.connected_to_server
	Auth.token = OS.get_environment("AI_TEST_TOKEN")
	for ranked in [true, false]:
		var board := load("res://scenes/game/Board.tscn").instantiate() as Board
		add_child(board)
		board.auto_confirm_mulligan = true
		var human: Array[CardData] = []
		var bot: Array[CardData] = []
		for i in 10:
			human.append(CardDatabase.get_card("g_001"))
			bot.append(CardDatabase.get_card("cr_002"))
		await GameManagerAutoload.start_local_game(board, human, bot, 1, ranked)
		var gs := GameManagerAutoload.game_state
		# Depletion must not replace the starting lists in the submitted report.
		gs.player.deck.clear()
		gs.opponent.deck.clear()
		gs.turn_number = 7
		gs.execute({"type": GameState.CMD_CONCEDE, "actor": "player_1"})
		GameManagerAutoload._handle_game_over()
		if ranked:
			var ack: Array = await Net.ranked_result_received
			if not ack[0]:
				get_tree().quit(1)
				return
		else:
			await get_tree().create_timer(0.2).timeout
		board.queue_free()
		await get_tree().process_frame
	Net.disconnect_from_relay()
	get_tree().quit(0)
