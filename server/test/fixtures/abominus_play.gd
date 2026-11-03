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

func _run() -> void:
	for case in [{"fatal": false, "opponent": false}, {"fatal": true, "opponent": false}, {"fatal": true, "opponent": true}]:
		var fatal: bool = case["fatal"]
		var opponent_play: bool = case["opponent"]
		var gs := GameState.new("player_1", "player_2", [], [])
		var owner := gs.opponent if opponent_play else gs.player
		var defender := gs.player if opponent_play else gs.opponent
		gs.active_player_id = owner.player_id
		gs.current_phase = GameState.Phase.OPPONENT_TURN if opponent_play else GameState.Phase.PLAYER_TURN
		owner.max_mana = 10
		gs.set_events_enabled(true)
		var abominus := CardDatabase.get_card("t_013").new_instance(owner.mint_card_uid())
		owner.hand.append(abominus)
		var foes: Array[Minion] = []
		for i in 2:
			var data := CardDatabase.get_card("b_009").new_instance(defender.mint_card_uid())
			var foe := Minion.new(data, defender.player_id, defender.mint_minion_id(data.id))
			# A lethal first opponent stops Rampage before the second creature.
			foe.current_attack = 8 if fatal else 1
			foes.append(foe)
			defender.place_minion(foe)
		var board: Board = BoardScene.instantiate()
		add_child(board)
		board.setup(gs)
		GameManagerAutoload.game_state = gs
		GameManagerAutoload.board = board
		board.action_play_card.connect(GameManagerAutoload._on_play_card)
		await get_tree().create_timer(0.6).timeout
		var ghost: Card = null
		if opponent_play:
			await GameManagerAutoload.ai_controller._play_creature_action({"type": "play_creature", "actor": owner.player_id, "card_uid": abominus.uid}, abominus, gs, board)
		else:
			ghost = board._get_card_child(board.player_hand_zone.get_child(0))
			# Same reparenting as a dragged card, then the real drop/manager chain.
			ghost._original_parent = ghost.get_parent()
			ghost.reparent(get_viewport())
			board._play_card_with_slam(ghost, abominus, 0)
		await get_tree().create_timer(1.4).timeout
		check(owner.hand.is_empty(), "Abominus play committed")
		check(foes[0] not in defender.board, "Abominus challenged the first enemy")
		if fatal:
			check(owner.board.is_empty() and owner.graveyard.any(func(c): return c.uid == abominus.uid), "fatal challenge puts Abominus in the graveyard")
			check(foes[1] in defender.board, "challenges stop when Abominus dies")
		else:
			check(defender.board.is_empty() and owner.board[0].current_health == 6, "surviving Abominus challenges both enemies")
		check(not board._card_animation_playing, "play releases input: fatal=" + str(fatal))
		check(not is_instance_valid(ghost), "played card leaves no frozen ghost: fatal=" + str(fatal))
		check(board._pending_slam_ghost_by_zone.is_empty(), "no unclaimed landing remains")
		var logs := board.combat_log_vbox.get_children().filter(func(label): return label.text.contains("challenged"))
		check(logs.size() == (1 if fatal else 2), "every resolved challenge reaches the combat log")
		board.queue_free()
		await get_tree().process_frame
	print("ABOMINUS_PLAY_RESULT ", JSON.stringify({"failures": failures}))
	get_tree().quit(failures.size())
