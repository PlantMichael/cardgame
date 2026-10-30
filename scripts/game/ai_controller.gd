class_name AIController
extends Node

const THINK_DELAY = 0.6
## Increment when AI policy/search changes, independently of card/rules versions.
const POLICY_VERSION := 1

## How long the AI sits on a turn it cannot do anything with (no affordable
## card, nothing able to attack) before passing it back. Every other turn is
## paced by the THINK_DELAY in front of each action it takes; a turn with no
## actions in it had no pacing at all, so it ended in the same frame it began
## and the board's "OPPONENT'S TURN" banner was still on screen when
## "YOUR TURN" slid in over it. Longer than one banner's whole life
## (Board._show_turn_banner: ~1.25s in, hold and out).
const EMPTY_TURN_PAUSE = 1.5

## 1 (weakest) - 10 (strongest). Read once per decision in take_turn(); see
## MCTSEngine.AI_LEVEL_CONFIG for what each level actually changes.
var ai_level: int = 5

## Set by GameManager: answers every open rules-core choice (the human's by
## asking them, the AI's by policy). The AI never answers a choice itself.
var drive_choices: Callable

## Repeatedly asks MCTSEngine for the single best next atomic action against
## the real game_state, applies it (with the same logging/animation glue the
## old one-ply AI used), and stops when the search recommends ending the turn.
## One MCTSEngine is built for the whole turn (not per action) so its search
## tree carries forward action-to-action via advance_after_real_action() —
## rebuilding a full search from scratch for every single action in a turn is
## what used to make a multi-action AI turn take several stacked full
## searches in a row, long enough to read as the game hanging.
func take_turn(game_state: GameState, board: Board) -> void:
	var engine := MCTSEngine.new(game_state.opponent.player_id, ai_level)
	var acted := false
	for _i in 60:  # safety cap; a real turn never needs anywhere near this many actions
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			return
		var action: Dictionary = await engine.choose_action(game_state)
		# Quitting (or restarting a match) while this coroutine is suspended
		# on any await below frees `board` out from under it - every await
		# in this file is checked the same way immediately after resuming,
		# rather than relying on a single guard here, since a single action
		# (e.g. _attack_action) can itself suspend multiple times before
		# touching `board` again.
		if not is_instance_valid(board):
			return
		if action["type"] == "end_turn":
			if not acted and game_state.current_phase != GameState.Phase.GAME_OVER:
				await get_tree().create_timer(EMPTY_TURN_PAUSE).timeout
			return
		await _apply_action(action, game_state, board)
		if not is_instance_valid(board):
			return
		acted = true
		# A targeted on-play effect opens a choice that blocks every further
		# command until it is answered - by whoever owns it.
		if drive_choices.is_valid():
			await drive_choices.call()
			if not is_instance_valid(board):
				return
		board.refresh()
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			return
		engine.advance_after_real_action(game_state)

## The engine returns actions as plain values naming entities by uid /
## instance_id (see GameState.validate). They are resolved against the real
## state here so the presentation helpers below can keep working with
## objects. A resolution miss means the action went stale between being
## chosen and being applied - drop it rather than dereferencing null.
func _apply_action(action: Dictionary, game_state: GameState, board: Board) -> void:
	var ai: PlayerState = game_state.opponent
	match action["type"]:
		"pilot":
			await get_tree().create_timer(THINK_DELAY).timeout
			if not is_instance_valid(board):
				return
			var result := game_state.execute(action)
			if result["ok"]:
				board.refresh()
				await EventPresenter.present(result["events"], board, game_state.player.player_id)
		"play_creature":
			var card := ai.find_card_in_hand(str(action.get("card_uid", "")))
			if card == null:
				return
			await _play_creature_action(action, card, game_state, board)
		"play_stratagem":
			var card := ai.find_card_in_hand(str(action.get("card_uid", "")))
			if card == null:
				return
			var target := game_state.find_minion(str(action.get("target_instance_id", "")))
			await _play_stratagem_action(action, card, target, str(action.get("target_player_id", "")), game_state, board)
		"attack":
			var attacker := game_state.find_minion(str(action.get("attacker_instance_id", "")))
			if attacker == null:
				return
			var target := game_state.find_minion(str(action.get("target_instance_id", "")))
			await _attack_action(action, attacker, target, str(action.get("target_player_id", "")), game_state, board)

# --- Card playing ---

func _play_creature_action(action: Dictionary, card: CardData, game_state: GameState, board: Board) -> void:
	# Registered here (well before the slam itself starts) rather than right
	# before game_state.play_creature() below - instantiating and setting up
	# a Card is not free, and paying that cost synchronously at
	# the exact moment the flight animation is meant to start read as a stutter
	# right at kickoff. Doing it now lets that cost land during the THINK_DELAY/
	# announce_card pause below instead, which the player already reads as a
	# beat, not a hitch.
	board.play_opponent_card_with_slam(card)
	await get_tree().create_timer(THINK_DELAY).timeout
	if not is_instance_valid(board):
		return
	await board.announce_card(card)
	if not is_instance_valid(board):
		return
	# Through the shared validated boundary, same as the human player's own
	# plays - the AI gets no privileged path into the rules.
	var played := game_state.execute(action)
	if not played["ok"]:
		return
	board.log_action("Opponent played %s" % card.card_name)
	board.refresh()
	# See game_manager.gd's identical wait on this same call chain (there,
	# for the player's own play) for why: an on-play effect below (a laser-
	# kill animation, etc.) shouldn't race the just-played card's own
	# landing animation.
	await board.await_slam_landed(board.opponent_board_zone)
	if not is_instance_valid(board):
		return
	await EventPresenter.present(played["events"], board, game_state.player.player_id)
	# Any decision its on-play effects opened is answered by the shared driver
	# (take_turn calls it after every action).

func _play_stratagem_action(action: Dictionary, card: CardData, minion: Minion, target_player_id: String, game_state: GameState, board: Board) -> void:
	await get_tree().create_timer(THINK_DELAY).timeout
	if not is_instance_valid(board):
		return
	await board.announce_card(card)
	if not is_instance_valid(board):
		return
	var result := game_state.execute(action)
	if not result["ok"]:
		return
	board.log_action("Opponent played %s" % card.card_name)
	if minion != null:
		var _died: bool = minion not in game_state.player.board and minion not in game_state.opponent.board
		if _died:
			var _tgt: Card = board.find_card_node(minion.instance_id)
			if _tgt != null:
				var _from: Vector2 = _tgt.get_parent().get_global_rect().get_center() + Vector2(0, -600)
				await board.animate_laser_kill(_from, _tgt)
				if not is_instance_valid(board):
					return
	board.refresh()

	await EventPresenter.present(result["events"], board, game_state.player.player_id)

# --- Attack execution ---

func _attack_action(action: Dictionary, attacker: Minion, target: Minion, target_player_id: String, game_state: GameState, board: Board) -> void:
	await get_tree().create_timer(THINK_DELAY).timeout
	if not is_instance_valid(board):
		return
	var attacker_name: String = attacker.data.card_name
	var target_iid: String = target.instance_id if target != null else ""
	var target_name: String = target.data.card_name if target != null else ""
	var attack_result := game_state.execute(action)
	if not attack_result["ok"]:
		return
	if target != null:
		board.log_action("Opponent's %s attacked your %s" % [attacker_name, target_name])
		await board.animate_creature_attack(attacker.instance_id, game_state.opponent.player_id, target_iid)
		if not is_instance_valid(board):
			return
	else:
		board.log_action("Opponent's %s attacked your hero" % attacker_name)
		await board.animate_creature_attack_face(attacker.instance_id, game_state.opponent.player_id)
		if not is_instance_valid(board):
			return
	board.refresh()
	await EventPresenter.present(attack_result["events"], board, game_state.player.player_id)

# --- Backward-compatible delegates (called directly by game_manager.gd for
# non-AI-turn opponent decisions, e.g. reactive pending-queue resolution) ---

func _pick_best_removal_target(minions: Array[Minion], damage: int) -> Minion:
	return AIHeuristics.pick_best_removal_target(minions, damage)

func _pick_challenge_target(minions: Array[Minion], challenger: Minion) -> Minion:
	return AIHeuristics.pick_challenge_target(minions, challenger)

func _pick_health_buff_target(minions: Array[Minion]) -> Minion:
	return AIHeuristics.pick_health_buff_target(minions)
