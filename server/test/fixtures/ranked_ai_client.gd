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
	Auth._apply_profile({"token": OS.get_environment("AI_TEST_TOKEN"), "username": "ai_tester"})
	for ranked in [true, false]:
		var board := load("res://scenes/game/Board.tscn").instantiate() as Board
		add_child(board)
		board.auto_confirm_mulligan = true
		var human: Array[CardData] = []
		var bot: Array[CardData] = []
		var starters := DeckManager.get_starter_decks()
		var human_ids: Array[String] = []
		var bot_ids: Array[String] = []
		human_ids.assign(starters[0]["card_ids"])
		bot_ids.assign(starters[1]["card_ids"])
		human = DeckManager.build_deck_from_ids(human_ids)
		bot = DeckManager.build_deck_from_ids(bot_ids)
		var coinflip := {}
		get_tree().process_frame.connect(func():
			coinflip["first"] = "player" if board.coinflip_label.text == "Going First" else "opponent",
			CONNECT_ONE_SHOT)
		await GameManagerAutoload.start_local_game(board, human, bot, 1, ranked)
		if ranked:
			print("AI_PRODUCER_FIRST ", coinflip["first"])
		var gs := GameManagerAutoload.game_state
		gs.player.max_mana = 10
		gs.player.current_mana = 0
		# Real accepted plays, including a copy generated into hand, reach telemetry.
		var creature := CardDatabase.get_card("g_001").new_instance(gs.player.mint_card_uid())
		gs.player.hand.append(creature)
		var play := gs.execute({"type": "play_creature", "actor": "player_1", "card_uid": creature.uid})
		if not play["ok"]:
			get_tree().quit(1)
			return
		var buff := CardDatabase.get_card("g_str_001").new_instance(gs.player.mint_card_uid())
		gs.player.hand.append(buff)
		if not gs.execute({"type": "play_stratagem", "actor": "player_1", "card_uid": buff.uid, "target_instance_id": play["minion"].instance_id})["ok"]:
			get_tree().quit(1)
			return
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
