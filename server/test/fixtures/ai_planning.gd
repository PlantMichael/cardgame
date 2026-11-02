extends Node
const P := "player_1"
const A := "player_2"
const BoardScene = preload("res://scenes/game/Board.tscn")
const Manager = preload("res://scripts/game/game_manager.gd")
var failures: Array[String] = []
var timings: Array[int] = []
func _ready() -> void:
	Net.set_process(false)
	_run.call_deferred()
func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)
func state(mana: int = 4) -> GameState:
	var deck: Array[CardData] = []
	for i in 20:
		deck.append(CardDatabase.get_card("b_009"))
	var gs := GameState.new(P,A,deck,deck,42)
	gs.active_player_id = A
	gs.current_phase = GameState.Phase.OPPONENT_TURN
	gs.opponent.max_mana = mana
	gs.opponent.current_mana = 0 # Mana tracks spent crystals.
	return gs
func hand(gs: GameState, id: String) -> CardData:
	var c := CardDatabase.get_card(id).new_instance(gs.opponent.mint_card_uid())
	gs.opponent.hand.append(c)
	return c
func minion(gs: GameState, who: PlayerState, id: String) -> Minion:
	var c := CardDatabase.get_card(id).new_instance(who.mint_card_uid())
	var m := Minion.new(c,who.player_id,who.mint_minion_id(id))
	who.place_minion(m)
	m.is_exhausted = false
	return m
func combo() -> GameState:
	var gs := state()
	gs.player.hero_health = 2
	var threat := minion(gs,gs.player,"b_009")
	threat.current_attack = 30
	threat.current_health = 4
	threat.max_health = 4
	minion(gs,gs.opponent,"b_008")
	hand(gs,"b_001")
	return gs
func play(gs: GameState, seed_value: int) -> Array:
	var engine := MCTSEngine.new(A,10)
	engine._search_rng.seed = seed_value
	var actions: Array = []
	for step in 20:
		if gs.current_phase == GameState.Phase.GAME_OVER:
			break
		var before := MCTSEngine._fingerprint(gs)
		var start := Time.get_ticks_msec()
		print("AI_SEARCH_BEGIN")
		var action := await engine.choose_action(gs)
		print("AI_SEARCH_END")
		timings.append(Time.get_ticks_msec()-start)
		check(before == MCTSEngine._fingerprint(gs), "search leaves original zones, choices, definitions and RNG unchanged")
		actions.append(action)
		check(HeadlessTurn.apply_action(gs,action,false), "searched command executes through the actual core")
		engine.advance_after_real_action(gs)
		if action["type"] == "end_turn":
			break
	return actions
func live(gs: GameState, reactive: bool = false) -> void:
	var board := BoardScene.instantiate()
	add_child(board)
	board.setup(gs)
	var manager := Manager.new()
	add_child(manager)
	manager.game_state = gs
	manager.board = board
	manager.ai_controller.ai_level = 10
	gs.set_events_enabled(true)
	var initial_hand: Array = gs.opponent.hand.map(func(c):return c.id)
	if reactive:
		await manager._drive_choices()
	else:
		await manager.ai_controller.take_turn(gs,board)
	check(gs.winner_id == A, "live sequence %s: winner=%s hero=%d hand=%s choice=%s" % [initial_hand,gs.winner_id,gs.player.hero_health,gs.opponent.hand.map(func(c):return c.id),gs.pending_choice])
	manager.queue_free()
	board.queue_free()
	await get_tree().process_frame
func restart_during_choice(during_search: bool) -> void:
	var old_state := state()
	old_state.request_choice(A,GameState.CHOICE_DAMAGE_TARGET,1,null)
	var old_board := BoardScene.instantiate()
	add_child(old_board)
	old_board.setup(old_state)
	var replacement := state()
	replacement.active_player_id = P
	replacement.current_phase = GameState.Phase.PLAYER_TURN
	replacement.request_choice(P,GameState.CHOICE_DAMAGE_TARGET,1,null)
	var new_board := BoardScene.instantiate()
	add_child(new_board)
	new_board.setup(replacement)
	var manager := Manager.new()
	add_child(manager)
	manager.game_state = old_state
	manager.board = old_board
	manager.ai_controller.ai_level = 10
	var engine := MCTSEngine.new(A,10)
	var finished := {"value":false}
	var drive := func():
		await manager._drive_choices(engine)
		finished["value"] = true
	drive.call_deferred()
	await get_tree().process_frame
	if during_search:
		while engine.last_search_iterations == 0 and not finished["value"]:
			await get_tree().process_frame
		check(not finished["value"], "replacement test reaches an actual yielded search")
	else:
		check(engine.last_search_iterations==0 and not finished["value"], "replacement test reaches the pacing wait")
	manager.game_state = replacement
	manager.board = new_board
	old_board.queue_free()
	var before := replacement.state_hash()
	while not finished["value"]:
		await get_tree().process_frame
	check(replacement.state_hash()==before and replacement.has_pending_choice(), "old driver preserves a new match's human choice during search=%s" % during_search)
	manager.queue_free()
	new_board.queue_free()
	await get_tree().process_frame
func _run() -> void:
	await restart_during_choice(false)
	await restart_during_choice(true)
	# More friendly health must always help, and more enemy health must hurt.
	var health_state := state()
	for hp in range(1,30):
		health_state.opponent.hero_health = hp
		var weaker := AIHeuristics.evaluate_state(health_state,A)
		health_state.opponent.hero_health = hp+1
		check(AIHeuristics.evaluate_state(health_state,A)>weaker, "additional friendly health improves evaluation at %d HP" % hp)
		health_state.player.hero_health = hp
		var damaged_enemy := AIHeuristics.evaluate_state(health_state,A)
		health_state.player.hero_health = hp+1
		check(AIHeuristics.evaluate_state(health_state,A)<damaged_enemy, "additional enemy health worsens evaluation at %d HP" % hp)
	health_state.player.hero_health = 10
	health_state.opponent.hero_health = 5
	health_state.request_choice(A,GameState.CHOICE_DAMAGE_TARGET,2,null)
	var damage := await MCTSEngine.new(A,10).choose_action(health_state)
	check(damage.get("selection","") == GameState.hero_option(P), "general damage planning hurts the enemy rather than rewarding self-damage")
	# Rule-provided choices stay distinct and optional decline is searchable.
	var gs := state()
	minion(gs,gs.player,"b_009")
	gs.player.hero_health = 2
	gs.request_choice(A,GameState.CHOICE_DAMAGE_TARGET,2,null)
	var options := HeadlessTurn.list_legal_actions(gs,A)
	check(options.size() == gs.pending_choice["options"].size()+1, "every offered target and optional decline is searched")
	var first_choice := str(gs.pending_choice["id"])
	var old := gs.duplicate_for_sim()
	var answer := await MCTSEngine.new(A,10).choose_action(gs)
	check(answer.get("selection","") == GameState.hero_option(P), "search picks lethal over an available enemy creature")
	check(HeadlessTurn.apply_action(gs,answer,false) and gs.winner_id == A, "chosen immediate damage wins")
	# Stale answers cannot resolve a later choice or mutate its state.
	old.execute({"type":GameState.CMD_ANSWER_CHOICE,"actor":A,"choice_id":first_choice,"selection":""})
	old.request_choice(A,GameState.CHOICE_DAMAGE_TARGET,1,null)
	var before := old.state_hash()
	var rejected := old.execute({"type":GameState.CMD_ANSWER_CHOICE,"actor":A,"choice_id":first_choice,"selection":GameState.hero_option(P)})
	check(not rejected["ok"] and old.state_hash()==before, "stale choice rejected without mutation")
	var changed := old.duplicate_for_sim()
	changed.pending_choice["amount"] = 9
	check(MCTSEngine._fingerprint(changed) != MCTSEngine._fingerprint(old), "reuse distinguishes choice payloads of equal size")
	# Enemy reactive decisions follow that owner, not the searching player's interests.
	old.execute({"type":GameState.CMD_ANSWER_CHOICE,"actor":A,"choice_id":str(old.pending_choice["id"]),"selection":""})
	old.request_choice(P,GameState.CHOICE_DAMAGE_TARGET,1,null)
	options = HeadlessTurn.list_legal_actions(old,A)
	check(options.size()==1 and options[0]["actor"]==P, "opponent-owned choice is not maximized cooperatively")
	var controller := AIController.new()
	add_child(controller)
	before = old.state_hash()
	await controller._apply_action(options[0],old,null)
	check(old.state_hash()==before, "live AI adapter leaves a human-owned choice for the human")
	controller.queue_free()
	check(HeadlessTurn.apply_action(old,options[0],false), "opponent policy's answer is legal")
	# Multi-step choices remain atomic rather than silently completed in search.
	gs = state()
	var source := minion(gs,gs.opponent,"b_009")
	minion(gs,gs.opponent,"b_015")
	minion(gs,gs.opponent,"b_008")
	gs.request_choice(A,GameState.CHOICE_SWAP_HEALTH,0,source)
	options = HeadlessTurn.list_legal_actions(gs,A)
	check(HeadlessTurn.apply_action(gs,options[0],false) and gs.has_pending_choice() and gs.pending_choice["step"]==2, "first swap answer preserves the second searched decision")
	options = HeadlessTurn.list_legal_actions(gs,A)
	check(HeadlessTurn.apply_action(gs,options[0],false) and not gs.has_pending_choice(), "second swap answer resolves the chain")
	gs = state()
	var transform := hand(gs,"cr_018")
	gs.execute({"type":GameState.CMD_PLAY_CREATURE,"actor":A,"card_uid":transform.uid})
	options = HeadlessTurn.list_legal_actions(gs,A)
	check(options.size()==2 and options.all(func(a):return not str(a["selection"]).is_empty()), "mandatory transform exposes both actual forms and no decline")
	check(HeadlessTurn.apply_action(gs,options[0],false), "searched transformation executes")
	for seed_value in [0,10,42,123]:
		gs = combo()
		var actions := await play(gs,seed_value)
		check(gs.winner_id==A, "sacrifice/rummage/replay wins at seed %d" % seed_value)
		check(actions.any(func(a): return a.get("selection","")=="b_008"), "rummage is an explicit searched action")
		# Another faction/mechanic: buff the ready attacker, not the bigger exhausted body.
		gs = state()
		gs.player.hero_health = 3
		var ready := minion(gs,gs.opponent,"b_009")
		ready.current_attack = 1
		var asleep := minion(gs,gs.opponent,"g_001")
		asleep.current_attack = 8
		asleep.is_exhausted = true
		var buff := hand(gs,"g_str_001")
		options = HeadlessTurn.stratagem_actions(buff,gs,A)
		check(options.size()==2, "both friendly buff targets are available")
		await play(gs,seed_value)
		check(gs.winner_id==A, "search combines buff and ready attack at seed %d" % seed_value)
		# Without retrieval, sacrificing the small body loses value rather than earning a free graveyard bonus.
		gs = state()
		gs.player.hero_health = 5
		var blocker := minion(gs,gs.player,"b_009")
		blocker.current_attack = 2
		blocker.current_health = 4
		blocker.max_health = 4
		var body := minion(gs,gs.opponent,"b_008")
		before = gs.state_hash()
		var sacrifice := gs.duplicate_for_sim()
		sacrifice.execute({"type":"attack","actor":A,"attacker_instance_id":body.instance_id,"target_instance_id":blocker.instance_id})
		check(AIHeuristics.evaluate_state(sacrifice,A)<AIHeuristics.evaluate_state(gs,A), "unrecoverable sacrifice is not credited as free value")
		var actions_no_payoff := await play(gs,seed_value)
		check(not actions_no_payoff.any(func(a):return a.get("target_instance_id","")==blocker.instance_id), "without payoff AI does not throw away Launcher")
	# Retrieval must compare replay affordability, not just the highest printed cost.
	gs = state(5)
	gs.player.hero_health = 2
	minion(gs,gs.player,"b_009")
	for id in ["b_008","b_001"]:
		gs.opponent.graveyard.append(CardDatabase.get_card(id).new_instance(gs.opponent.mint_card_uid()))
	hand(gs,"b_004")
	var retrieval := await play(gs,10)
	check(gs.winner_id==A and retrieval.any(func(a):return a.get("selection","")=="b_008"), "rummage chooses the affordable winning replay over a more expensive card")
	# Healthy bounce is legal even though the old readiness policy refused it.
	gs = state()
	var friendly := minion(gs,gs.opponent,"b_008")
	minion(gs,gs.player,"b_009")
	var bounce := hand(gs,"gen_str_005")
	options = HeadlessTurn.stratagem_actions(bounce,gs,A)
	check(options.size()==1 and options[0]["target_instance_id"]==friendly.instance_id, "bounce can consider healthy friendly creatures, never enemies")
	check(HeadlessTurn.apply_action(gs,options[0],false), "enumerated healthy bounce executes")
	await live(combo())
	gs = state()
	gs.player.hero_health = 2
	minion(gs,gs.player,"b_009")
	hand(gs,"b_008")
	await live(gs)
	gs = state()
	gs.active_player_id = P
	gs.current_phase = GameState.Phase.PLAYER_TURN
	gs.player.hero_health = 2
	minion(gs,gs.player,"b_009")
	gs.request_choice(A,GameState.CHOICE_DAMAGE_TARGET,2,null)
	await live(gs,true)
	timings.sort()
	print("AI_PLANNING_RESULT ",JSON.stringify({"failures":failures,"decisions":timings.size(),"p95_ms":timings[int(timings.size()*0.95)],"max_ms":timings.back()}))
	get_tree().quit(failures.size())
