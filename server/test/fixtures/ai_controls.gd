extends "res://scripts/game/main.gd"

var _failures: Array[String] = []
var _started_level := -1

func _ready() -> void:
	_run.call_deferred()

func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		push_error(message)

func _press(label: String) -> void:
	for button in _canvas.find_children("*", "Button", true, false):
		if button.text == label:
			button.pressed.emit()
			return
	_check(false, "missing button: " + label)

# Observe the actual menu callback arguments without starting matchmaking.
func _start_game(_player_ids: Array[String], _opp_ids: Array[String], ai_level: int = 5, _ranked: bool = false, _opponent_name: String = "") -> void:
	_started_level = ai_level

func _begin_campaign_search(_size: CampaignState.Size, ai_level: int) -> void:
	_started_level = ai_level

func _show_match_found_popup(_opponent_name: String, _opponent_rating: int, on_complete: Callable) -> void:
	on_complete.call()

func _run() -> void:
	_check(Net._ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, "fixture must not have a live relay")
	Net.set_process(false)
	for campaign in [false, true]:
		_canvas = CanvasLayer.new()
		add_child(_canvas)
		if campaign:
			_show_campaign_setup()
		else:
			_show_opponent_select()
		# Exercise all transitions on the same screen, including switching back.
		for selection in [["HARD", 10], ["EASY", 1], ["MEDIUM", 5]]:
			_press(selection[0])
			_press("SMALL" if campaign else "Random Gundari")
			_check(_started_level == selection[1], "%s %s starts level %d, got %d" % [
				"campaign" if campaign else "VS AI", selection[0], selection[1], _started_level])
		_canvas.free()
		_canvas = null

	var saved_rank := [Auth.rank_bracket, Auth.rank_in_legend]
	_canvas = CanvasLayer.new()
	add_child(_canvas)
	for rank in [[0, false], [10, false], [20, false], [20, true]]:
		Auth.rank_bracket = rank[0]
		Auth.rank_in_legend = rank[1]
		_on_ranked_search_timeout(_ranked_search_id)
		_check(_started_level == 10, "ranked fallback uses level 10 at rank %s" % [rank])
	Auth.rank_bracket = saved_rank[0]
	Auth.rank_in_legend = saved_rank[1]
	await get_tree().process_frame
	_canvas.free()
	_canvas = null

	# The live adapter must execute a selected Pilot command, not silently skip it.
	var gs := GameState.new("a", "b", [], [])
	gs.active_player_id = "b"
	gs.current_phase = GameState.Phase.OPPONENT_TURN
	gs.player.hero_health = 9
	var threat := Minion.new(CardDatabase.get_card("o_025"), "a")
	threat.current_attack = 30
	gs.player.place_minion(threat)
	var mech := Minion.new(CardDatabase.get_card("o_016"), "b")
	var pilot := Minion.new(CardDatabase.get_card("o_003"), "b")
	gs.opponent.place_minion(mech)
	gs.opponent.place_minion(pilot)
	var board := BoardScene.instantiate()
	add_child(board)
	board.setup(gs)
	var controller := AIController.new()
	add_child(controller)
	# Piloting grants Rush and 9 attack. Passing instead loses to the threat.
	var engine := MCTSEngine.new("b", RankedProgress.get_ai_level(0, false))
	engine._search_rng.seed = 10
	var action := await engine.choose_action(gs)
	_check(action["type"] == "pilot", "ranked search finds the Pilot move that enables lethal")
	await controller._apply_action(action, gs, board)
	_check(mech.is_piloted and mech.current_attack == 9 and mech.current_health == 9
		and mech.can_attack() and pilot not in gs.opponent.board,
		"live AI adapter merges Pilot, applies bonuses, and enables Rush")
	engine.advance_after_real_action(gs)
	var finish := await engine.choose_action(gs)
	await controller._apply_action(finish, gs, board)
	_check(gs.winner_id == "b", "ranked search and live adapter finish the Pilot lethal")
	var tree_ref: WeakRef = weakref(engine._root)
	engine = null
	_check(tree_ref.get_ref() == null, "discarded search trees release their match copies")
	board.queue_free()
	controller.queue_free()
	await get_tree().process_frame
	print("AI_CONTROLS_RESULT ", JSON.stringify({"failures": _failures}))
	get_tree().quit(_failures.size())
