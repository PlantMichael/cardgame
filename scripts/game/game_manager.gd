extends Node

var game_state: GameState
var board: Board
var ai_controller: AIController
var is_ranked: bool = false
var is_campaign: bool = false
## Guards _on_end_turn() against overlapping runs (e.g. End Turn getting
## pressed again before the previous press's await chain finishes) - without
## this, a second run reassigns turn/phase mid-flight and can double up draws
## or skip them, draining a hand over the course of several turns.
var _end_turn_in_progress: bool = false
## AI results and summaries are client-reported, so they move no matchmaking
## Elo. The identity still makes settlement and recording idempotent.
var _ranked_match_id: String = ""
var _ranked_ai_match: Dictionary = {}

const LOCAL_PLAYER_ID = "player_1"
const OPPONENT_PLAYER_ID = "player_2"

func _ready() -> void:
	ai_controller = AIController.new()
	add_child(ai_controller)
	# The AI answers (and the human is asked) through the same driver, so a
	# decision opened by one player's action is always answered by its owner.
	ai_controller.drive_choices = _drive_choices

## node_modifier_ability/grant_catchup_mana are Campaign-mode-only (see
## campaign_state.gd / main.gd's _start_campaign_match): a battlefield-wide
## ability granted to every creature played this match, and a one-time extra
## starting mana crystal for the local player when they're down 2+ node wins.
func start_local_game(board_node: Board, player_deck: Array[CardData], opponent_deck: Array[CardData],
					   ai_level: int = 5, ranked: bool = false, campaign: bool = false,
					   node_modifier_ability: String = "", grant_catchup_mana: bool = false) -> void:
	board = board_node
	board.is_online = false
	ai_controller.ai_level = ai_level
	is_ranked = ranked
	is_campaign = campaign
	# GameManagerAutoload is a singleton that outlives any one match - reset
	# per-match guards explicitly rather than assuming the previous match's
	# _on_end_turn() coroutine always reached one of its own reset points
	# (e.g. quitting to the menu mid-AI-turn frees `board` and abandons it
	# there instead), or a rematch into this same singleton would find the
	# guard already stuck true and End Turn would silently do nothing.
	_end_turn_in_progress = false
	_ranked_match_id = "ai_%d_%d" % [Time.get_unix_time_from_system(), randi()]
	# Snapshot the starting lists before draws, transforms or deck depletion.
	_ranked_ai_match = {}
	if ranked:
		_ranked_ai_match = {
			"player_deck": player_deck.map(func(card: CardData): return card.id),
			"opponent_deck": opponent_deck.map(func(card: CardData): return card.id),
			"ai_level": ai_level,
			"rules_version": RulesVersion.RULES_VERSION,
		}
	game_state = GameState.new(LOCAL_PLAYER_ID, OPPONENT_PLAYER_ID, player_deck, opponent_deck)
	game_state.node_modifier_ability = node_modifier_ability
	game_state.set_events_enabled(true)
	board.action_play_card.connect(_on_play_card)
	board.action_play_stratagem.connect(_on_play_stratagem)
	board.action_attack.connect(_on_attack)
	board.action_pilot.connect(_on_pilot)
	board.end_turn_pressed.connect(_on_end_turn)
	board.opponent_hero.player_id = OPPONENT_PLAYER_ID
	board.player_hero.player_id = LOCAL_PLAYER_ID
	var first_player_id = LOCAL_PLAYER_ID if randf() < 0.5 else OPPONENT_PLAYER_ID
	game_state.start_game(first_player_id)
	if grant_catchup_mana:
		game_state.player.max_mana += 1
		if game_state.is_local_player_turn():
			game_state.player.current_mana += 1
	board.setup(game_state)
	await board.show_coinflip_result(first_player_id == LOCAL_PLAYER_ID)
	game_state.mulligan_swap(OPPONENT_PLAYER_ID, AIHeuristics.pick_mulligan_swaps(game_state.opponent.hand))
	# The screen applies the swap itself (through this callback) so it can deal
	# each replacement into the slot it replaced before closing.
	await board.show_mulligan_screen(game_state.player.hand.duplicate(),
		func(swaps: Array[CardData]) -> Array[CardData]:
			return game_state.mulligan_swap(LOCAL_PLAYER_ID, swaps))
	board.refresh()
	if not game_state.is_local_player_turn():
		board.log_action("--- Opponent Turn %d ---" % game_state.turn_number)
		await ai_controller.take_turn(game_state, board)
		await _announce_pending_draws()
		await _resolve_all_pending()
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			_handle_game_over()
			return
		await _end_turn_for(game_state.active_player_id)
		board.refresh()
		await _announce_pending_draws()
		await _resolve_all_pending()
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			_handle_game_over()
			return
		board.log_action("--- Your Turn %d ---" % game_state.turn_number)

## The board hands up the CardData the player dragged; it is turned into a
## value command here so the human path goes through exactly the same
## validation the AI and multiplayer paths do (see GameState.validate).
func _on_play_card(card_data: CardData, at_index: int) -> void:
	if card_data == null:
		return
	var played := game_state.execute({
		"type": GameState.CMD_PLAY_CREATURE, "actor": LOCAL_PLAYER_ID,
		"card_uid": card_data.uid, "at_index": at_index,
	})
	var minion: Minion = played.get("minion")
	if minion:
		board.log_action("You played %s" % card_data.card_name)
		await get_tree().process_frame
		await get_tree().process_frame
		board.refresh()
		# Waits out the just-played card's own slam-landing animation (see
		# board.gd's await_slam_landed()) before any on-play prompt below can
		# open - otherwise the two race, and a card with a heavier/longer
		# landing (e.g. a legendary - see legendary_animations.gd) could have
		# its own prompt pop up mid-animation.
		await board.await_slam_landed(board.player_board_zone)
		await _present(played["events"])
		await _resolve_all_pending()
		board.refresh()
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			_handle_game_over()

## Log lines and animations for the events an action produced.
func _present(events: Array) -> void:
	await EventPresenter.present(events, board, LOCAL_PLAYER_ID)

## Answers every decision the rules core has open, one at a time: the local
## player's by asking them, the opponent's by the AI policy. The rules decide
## what is legal and what happens; this only supplies the answers.
##
## Replaces the per-effect prompt code that used to live in this file
## (_run_player_on_play and the _process_pending_* family) - those decided
## outcomes here instead of in GameState.
func _drive_choices() -> void:
	for _i in 64:
		if not is_instance_valid(board) or game_state.current_phase == GameState.Phase.GAME_OVER:
			return
		game_state.resolve_to_quiescence()
		if not game_state.has_pending_choice():
			return
		var choice: Dictionary = game_state.pending_choice.duplicate(true)
		var owner_id := str(choice["player_id"])
		var selection: String
		if owner_id == LOCAL_PLAYER_ID:
			selection = await board.prompt_choice(choice)
		else:
			await get_tree().create_timer(ai_controller.THINK_DELAY * 0.5).timeout
			selection = AIHeuristics.pick_choice_answer(game_state, choice)
		if not is_instance_valid(board):
			return
		var result := game_state.execute({
			"type": GameState.CMD_ANSWER_CHOICE, "actor": owner_id,
			"choice_id": str(choice["id"]), "selection": selection,
		})
		if not result["ok"]:
			# Never leave the match waiting: fall back to the choice's default.
			result = game_state.execute({
				"type": GameState.CMD_ANSWER_CHOICE, "actor": owner_id,
				"choice_id": str(choice["id"]), "selection": str(choice["default"]),
			})
			if not result["ok"]:
				game_state.cancel_pending_choice()
				return
		await _present(result["events"])
		board.refresh()
		await _announce_pending_draws()

## Works off whatever the last action left open. The rules core queues effects
## and turns the ones needing a decision into choices; there is nothing else
## for a controller to loop over.
func _resolve_all_pending() -> void:
	await _announce_pending_draws()
	await _drive_choices()
	await _announce_pending_draws()

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
	var result := game_state.execute({
		"type": GameState.CMD_PILOT, "actor": LOCAL_PLAYER_ID,
		"pilot_instance_id": pilot_instance_id, "target_instance_id": target_instance_id,
	})
	if result["ok"]:
		await _present(result["events"])
	board.refresh()
	await _resolve_all_pending()

func _on_attack(attacker_id: String, target_type: String, target_id: String) -> void:
	var attacker = _find_minion(LOCAL_PLAYER_ID, attacker_id)
	if not attacker:
		return
	var had_dual_strike := attacker.has_ability(Abilities.DUAL_STRIKE)
	if target_type == "minion":
		var target = _find_minion(OPPONENT_PLAYER_ID, target_id)
		if target:
			var target_name: String = target.data.card_name
			var attack_result := game_state.execute({
				"type": GameState.CMD_ATTACK, "actor": LOCAL_PLAYER_ID,
				"attacker_instance_id": attacker_id, "target_instance_id": target_id,
			})
			var ok: bool = attack_result["ok"]
			if ok:
				board.log_action("Your %s attacked opponent's %s" % [attacker.data.card_name, target_name])
				await board.animate_creature_attack(attacker_id, LOCAL_PLAYER_ID, target_id)
				if had_dual_strike and attacker in game_state.player.board:
					await board.animate_creature_attack(attacker_id, LOCAL_PLAYER_ID, target_id)
	elif target_type == "hero":
		var attack_result := game_state.execute({
			"type": GameState.CMD_ATTACK, "actor": LOCAL_PLAYER_ID,
			"attacker_instance_id": attacker_id, "target_instance_id": "",
			"target_player_id": target_id,
		})
		var ok: bool = attack_result["ok"]
		if ok:
			board.log_action("Your %s attacked the opponent's hero" % attacker.data.card_name)
			await board.animate_creature_attack_face(attacker_id, LOCAL_PLAYER_ID)
			if had_dual_strike and attacker in game_state.player.board:
				await board.animate_creature_attack_face(attacker_id, LOCAL_PLAYER_ID)
	board.refresh()
	await _resolve_all_pending()
	if game_state.current_phase == GameState.Phase.GAME_OVER:
		_handle_game_over()

func _on_play_stratagem(card_data: CardData, target_minion: Minion, target_player_id: String) -> void:
	if not game_state.is_local_player_turn():
		return
	if card_data == null:
		return
	var strat := game_state.execute({
		"type": GameState.CMD_PLAY_STRATAGEM, "actor": LOCAL_PLAYER_ID,
		"card_uid": card_data.uid,
		"target_instance_id": target_minion.instance_id if target_minion != null else "",
		"target_player_id": target_player_id,
	})
	if not strat["ok"]:
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
	await _present(strat["events"])
	await _resolve_all_pending()
	if game_state.current_phase == GameState.Phase.GAME_OVER:
		_handle_game_over()

## Ends `player_id`'s turn through the validated command boundary and shows
## whatever that produced.
func _end_turn_for(player_id: String) -> void:
	var result := game_state.execute({"type": GameState.CMD_END_TURN, "actor": player_id})
	if result["ok"]:
		await _present(result["events"])

func _on_end_turn() -> void:
	if _end_turn_in_progress:
		return
	_end_turn_in_progress = true
	await _end_turn_for(LOCAL_PLAYER_ID)
	board.refresh()
	board.log_action("--- Opponent Turn %d ---" % game_state.turn_number)
	if not game_state.is_local_player_turn():
		await ai_controller.take_turn(game_state, board)
		# Quitting to the main menu mid-AI-turn reloads the scene and frees
		# `board` out from under this suspended coroutine (see the same check
		# in ai_controller.gd's take_turn) - bail instead of touching it, and
		# make sure the guard above doesn't get stuck true for whatever game
		# starts next.
		if not is_instance_valid(board):
			_end_turn_in_progress = false
			return
		await _announce_pending_draws()
		await _resolve_all_pending()
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			_handle_game_over()
			_end_turn_in_progress = false
			return
		await _end_turn_for(game_state.active_player_id)
		board.refresh()
		await _announce_pending_draws()
		await _resolve_all_pending()
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			_handle_game_over()
			_end_turn_in_progress = false
			return
		board.log_action("--- Your Turn %d ---" % game_state.turn_number)
	_end_turn_in_progress = false

func _find_minion(player_id: String, instance_id: String) -> Minion:
	var p = game_state.player if player_id == LOCAL_PLAYER_ID else game_state.opponent
	for minion in p.board:
		if minion.instance_id == instance_id:
			return minion
	return null

func _handle_game_over() -> void:
	var won := game_state.winner_id == LOCAL_PLAYER_ID
	if won:
		# Server dedups this to once per calendar day regardless of how many
		# wins are reported after the first (see relay.js's claim_earn_reward
		# handler) - safe to call unconditionally on every winning match.
		Economy.claim_earn_reward("daily_first_win")
	if is_ranked:
		var old_bracket := Auth.rank_bracket
		var old_in_legend := Auth.rank_in_legend
		var old_legend_rating := Auth.rank_legend_rating
		var ai_match := _ranked_ai_match.duplicate(true)
		ai_match["turns"] = game_state.turn_number
		Auth.report_ranked_result(won, -1, _ranked_match_id, ai_match)
		board.show_game_over(won, true, old_bracket, old_in_legend, old_legend_rating)
	elif is_campaign:
		board.show_game_over(won, false, 0, false, 0, true)
	else:
		board.show_game_over(won)
