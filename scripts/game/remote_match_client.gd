class_name RemoteMatchClient
extends Node

## The thin client for a server-run ranked match (specs/003-authoritative-ranked-server).
##
## The rules do not run here. This node turns board interactions into value
## commands, sends them to the relay, and draws whatever the server says is
## the state: every `match_view` is rebuilt with GameState.from_net_dict and
## shown through the same Board the other modes use. It never executes a
## command, never shuffles, never decides a winner, and holds no hidden card of
## the opponent - the server never sends one. Controllers hold no rules (a core
## test checks this file for GameState mutation calls).

const SEND_TIMEOUT_SEC := 8.0
const RECONNECT_RETRY_SEC := 2.0
const CLOCK_WARN_SEC := 15

var board: Board
var game_state: GameState
var match_id: String = ""
var opponent_name: String = ""
var opponent_rating: int = -1

var _my_id: String = ""
var _my_seat: String = ""
var _refused: bool = false
var _opp_id: String = ""
var _seq: int = 0
var _client_seq: int = 0
var _awaiting_ack: bool = false
var _ack_token: int = 0
var _inbox: Array[Dictionary] = []
var _pumping: bool = false
var _have_view: bool = false
var _answering_choice_id: String = ""
var _game_over_shown: bool = false
var _reconnecting: bool = false
var _opp_disconnect_s: int = -1
var _clock: Dictionary = {}
var _last_turn: int = -1
var _last_active: String = ""
var _status_label: Label
var _status_layer: CanvasLayer

## Emitted after every applied view and every refusal, so a screen waiting on
## "what the server said next" (the mulligan) can continue.
signal _settled

# ── Entry ─────────────────────────────────────────────────────────────────

func start(board_node: Board, found_match_id: String, opp_name: String, opp_rating: int) -> void:
	board = board_node
	match_id = found_match_id
	opponent_name = opp_name
	opponent_rating = opp_rating
	board.is_online = true
	board.concede_enabled = true
	if not opponent_name.is_empty():
		board.set_opponent_name(opponent_name)

	board.action_play_card.connect(_on_play_card)
	board.action_play_stratagem.connect(_on_play_stratagem)
	board.action_attack.connect(_on_attack)
	board.action_pilot.connect(_on_pilot)
	board.end_turn_pressed.connect(_on_end_turn)
	board.concede_requested.connect(_on_concede)

	Net.match_message_received.connect(_on_net_message)
	Net.disconnected_from_server.connect(_on_socket_lost)
	Net.connected_to_server.connect(_on_socket_back)

	_build_status_overlay()
	_set_status("Joining match...")
	_send_join()

func _exit_tree() -> void:
	if Net.match_message_received.is_connected(_on_net_message):
		Net.match_message_received.disconnect(_on_net_message)
	if Net.disconnected_from_server.is_connected(_on_socket_lost):
		Net.disconnected_from_server.disconnect(_on_socket_lost)
	if Net.connected_to_server.is_connected(_on_socket_back):
		Net.connected_to_server.disconnect(_on_socket_back)

# ── Sending ───────────────────────────────────────────────────────────────

func _send_join() -> void:
	Net.send_match({"type": "match_join", "match_id": match_id, "since_n": _seq})

## One command in flight at a time: the board waits for the server's answer
## instead of guessing the outcome, so what is on screen is always what the
## server has accepted.
func _send_command(cmd: Dictionary) -> void:
	if _awaiting_ack or _game_over_shown or _reconnecting:
		return
	_client_seq += 1
	_awaiting_ack = true
	_ack_token += 1
	var token := _ack_token
	Net.send_match({"type": "match_command", "match_id": match_id, "client_seq": _client_seq, "cmd": cmd})
	get_tree().create_timer(SEND_TIMEOUT_SEC).timeout.connect(func():
		# Never leave the board locked if an answer is lost in transit.
		if _ack_token == token and _awaiting_ack:
			_awaiting_ack = false
			if is_instance_valid(board):
				board.refresh()
	)

func _my_turn() -> bool:
	return game_state != null and game_state.active_player_id == _my_id and game_state.mulligan_pending.is_empty()

func _on_play_card(card_data: CardData, at_index: int) -> void:
	if card_data == null or not _my_turn():
		board.refresh()
		return
	_send_command({"type": "play_creature", "card_uid": card_data.uid, "at_index": at_index})

func _on_play_stratagem(card_data: CardData, target_minion: Minion, target_player_id: String) -> void:
	if card_data == null or not _my_turn():
		board.refresh()
		return
	var cmd := {"type": "play_stratagem", "card_uid": card_data.uid}
	if target_minion != null:
		cmd["target_instance_id"] = target_minion.instance_id
	if not target_player_id.is_empty():
		cmd["target_player_id"] = target_player_id
	_send_command(cmd)

func _on_attack(attacker_id: String, target_type: String, target_id: String) -> void:
	if not _my_turn():
		return
	var cmd := {"type": "attack", "attacker_instance_id": attacker_id}
	if target_type == "minion":
		cmd["target_instance_id"] = target_id
	else:
		cmd["target_player_id"] = target_id
	_send_command(cmd)

func _on_pilot(pilot_id: String, target_id: String) -> void:
	if not _my_turn():
		return
	_send_command({"type": "pilot", "pilot_instance_id": pilot_id, "target_instance_id": target_id})

func _on_end_turn() -> void:
	if not _my_turn():
		return
	_send_command({"type": "end_turn"})

func _on_concede() -> void:
	if _game_over_shown:
		return
	Net.send_match({"type": "match_concede", "match_id": match_id})

# ── Receiving ─────────────────────────────────────────────────────────────

func _on_net_message(msg: Dictionary) -> void:
	# Another match's traffic (a stale one) is ignored.
	if str(msg.get("match_id", match_id)) != match_id:
		return
	_inbox.append(msg)
	if not _pumping:
		_pump()

## Messages are handled strictly in arrival order, each finished (animations
## included) before the next, so views and their events never interleave.
func _pump() -> void:
	_pumping = true
	while not _inbox.is_empty():
		var msg: Dictionary = _inbox.pop_front()
		if not is_instance_valid(board):
			break
		match str(msg.get("type", "")):
			"match_view":
				await _on_view(msg)
			"match_ack":
				_awaiting_ack = false
			"match_error":
				_on_error(msg)
			"match_clock":
				_clock = msg.get("clock", {})
				_refresh_status()
			"opponent_disconnected":
				_opp_disconnect_s = int(msg.get("remaining_s", 60))
				_refresh_status()
				_tick_disconnect_countdown()
			"opponent_reconnected":
				_opp_disconnect_s = -1
				_refresh_status()
			"match_over":
				await _on_match_over(msg)
			"match_voided":
				_on_voided()
	_pumping = false

func _on_error(msg: Dictionary) -> void:
	_awaiting_ack = false
	_refused = true
	# The server's reasons are deliberately coarse. Whatever it was, put the board
	# back to what the server last said rather than what was attempted.
	if str(msg.get("reason", "")) == "unknown_match":
		_set_status("This match is no longer available.")
	board.refresh()
	_settled.emit()

func _on_view(msg: Dictionary) -> void:
	var seq := int(msg.get("seq", 0))
	var first := not _have_view
	# A view that is not newer than what is shown is a duplicate (a rejoin echoes
	# the current one): apply it only when it is the first we have.
	if not first and seq < _seq:
		return
	_seq = seq
	_clock = msg.get("clock", {})
	var events: Array = msg.get("events", [])

	if first:
		_my_id = str(msg.get("you", "host"))
		_my_seat = str(msg.get("seat", ""))
		_opp_id = "guest" if _my_id == "host" else "host"
		board.player_hero.player_id = _my_id
		board.opponent_hero.player_id = _opp_id

	# Attack/challenge animations need the creatures where they stood BEFORE
	# the action resolved, so they play against the old board.
	if not first:
		for e in events:
			if str(e.get("type", "")) == "attack":
				await _present_attack(e)

	var was_my_turn := game_state != null and _my_turn()
	game_state = GameState.from_net_dict(msg["view"], _my_id)
	if board.game_state == null:
		board.setup(game_state)
	else:
		board.game_state = game_state
		board.refresh()

	if first:
		_have_view = true
		_last_turn = game_state.turn_number
		_last_active = game_state.active_player_id
		if not game_state.mulligan_pending.is_empty() and game_state.mulligan_pending.has(_my_id):
			_begin_mulligan()
	else:
		await _present_events(events)
		_announce_turn_change(was_my_turn)

	_refresh_status()
	if game_state.current_phase == GameState.Phase.GAME_OVER:
		_awaiting_ack = false
		_settled.emit()
		return
	_maybe_prompt_choice()
	_settled.emit()

func _present_attack(e: Dictionary) -> void:
	var attacker_id := str(e.get("attacker", ""))
	var owner_id := str(e.get("owner", ""))
	var target_id := str(e.get("target", ""))
	if target_id.is_empty():
		await board.animate_creature_attack_face(attacker_id, owner_id)
	else:
		await board.animate_creature_attack(attacker_id, owner_id, target_id)

## Log lines and card announcements for what the server reports happened.
## Everything shown comes from the (already seat-filtered) event feed.
func _present_events(events: Array) -> void:
	for e in events:
		if not is_instance_valid(board):
			return
		match str(e.get("type", "")):
			"play":
				var card := CardDatabase.get_card(str(e.get("card_id", "")))
				if card != null:
					var mine := str(e.get("owner", "")) == _my_id
					board.log_action(("You played %s" if mine else "Opponent played %s") % card.card_name)
					if not mine:
						await board.announce_card(card)
			"attack":
				var mine := str(e.get("owner", "")) == _my_id
				var target_name := str(e.get("target_name", ""))
				if target_name.is_empty():
					target_name = "the hero"
				board.log_action("%s %s attacked %s" % [
					"Your" if mine else "Opponent's", str(e.get("attacker_name", "creature")), target_name])
			"draw":
				if str(e.get("owner", "")) == _my_id and str(e.get("card_id", "")) != "":
					var drawn := CardDatabase.get_card(str(e["card_id"]))
					if drawn != null:
						board.log_action("Drew %s" % drawn.card_name)
					await board.animate_draw()
	await EventPresenter.present(events, board, _my_id)

func _announce_turn_change(was_my_turn: bool) -> void:
	if game_state.turn_number == _last_turn and game_state.active_player_id == _last_active:
		return
	_last_turn = game_state.turn_number
	_last_active = game_state.active_player_id
	if game_state.active_player_id == _my_id:
		board.log_action("--- Your Turn %d ---" % game_state.turn_number)
	elif was_my_turn:
		board.log_action("--- Opponent Turn %d ---" % game_state.turn_number)

# ── Choices (rendered exactly as the server lists them) ────────────────────

func _maybe_prompt_choice() -> void:
	var choice: Dictionary = game_state.pending_choice
	if choice.is_empty() or str(choice.get("player_id", "")) != _my_id:
		_answering_choice_id = ""
		return
	var id := str(choice.get("id", ""))
	if id == _answering_choice_id:
		return
	_answering_choice_id = id
	_answer_choice(choice.duplicate(true))

func _answer_choice(choice: Dictionary) -> void:
	var selection: String = await board.prompt_choice(choice)
	if not is_instance_valid(board) or _game_over_shown:
		return
	# Answered while a send was still in flight: wait our turn to speak.
	while _awaiting_ack and is_instance_valid(board):
		await get_tree().process_frame
	_send_command({"type": "answer_choice", "choice_id": str(choice.get("id", "")), "selection": selection})

# ── Mulligan ──────────────────────────────────────────────────────────────

func _begin_mulligan() -> void:
	var first_player_id := game_state.active_player_id
	await board.show_coinflip_result(first_player_id == _my_id)
	var hand_before: Array[CardData] = game_state.player.hand.duplicate()
	await board.show_mulligan_screen(hand_before,
		func(swaps: Array[CardData]) -> Array[CardData]:
			var old_uids := {}
			for c in game_state.player.hand:
				old_uids[c.uid] = true
			var uids: Array = []
			for c in swaps:
				uids.append(c.uid)
			_awaiting_ack = false
			_refused = false
			_send_command({"type": "mulligan", "card_uids": uids})
			# The server decides the replacements; wait for the view that has them.
			for _i in 40:
				await _settled
				if _refused or not game_state.mulligan_pending.has(_my_id):
					break
			var incoming: Array[CardData] = []
			for c in game_state.player.hand:
				if not old_uids.has(c.uid):
					incoming.append(c)
			return incoming)
	board.refresh()
	_refresh_status()

# ── Game over ─────────────────────────────────────────────────────────────

func _on_match_over(msg: Dictionary) -> void:
	if _game_over_shown:
		return
	_game_over_shown = true
	_awaiting_ack = false
	_set_status("")
	var won := bool(msg.get("winner_is_me", false))
	var outcome = msg.get("ranked_outcome", null)
	var old_bracket := Auth.rank_bracket
	var old_in_legend := Auth.rank_in_legend
	var old_legend_rating := Auth.rank_legend_rating
	board.show_game_over(won, true, old_bracket, old_in_legend, old_legend_rating)
	if outcome is Dictionary and bool(outcome.get("success", false)):
		# The server already settled it; this just feeds the same display the
		# other modes use. The client never reports a ranked result itself.
		Net.publish_settled_outcome(outcome)
	else:
		Net.publish_settled_outcome({})

func _on_voided() -> void:
	if _game_over_shown:
		return
	_game_over_shown = true
	_set_status("")
	board.show_notice("This match could not continue. No rank change.")

# ── Connection loss and rejoin ────────────────────────────────────────────

func _on_socket_lost() -> void:
	if _game_over_shown:
		return
	_reconnecting = true
	_awaiting_ack = false
	_refresh_status()
	_retry_connect()

func _retry_connect() -> void:
	while _reconnecting and is_instance_valid(self) and not _game_over_shown:
		Net.connect_to_relay()
		await get_tree().create_timer(RECONNECT_RETRY_SEC).timeout

func _on_socket_back() -> void:
	if not _reconnecting:
		return
	_reconnecting = false
	_send_join() # the server answers with the current view, from which we rebuild
	_refresh_status()

func _tick_disconnect_countdown() -> void:
	while _opp_disconnect_s > 0 and is_instance_valid(self) and not _game_over_shown:
		await get_tree().create_timer(1.0).timeout
		if _opp_disconnect_s > 0:
			_opp_disconnect_s -= 1
		_refresh_status()

# ── Status line (clock / waiting / reconnecting) ───────────────────────────

func _build_status_overlay() -> void:
	_status_layer = CanvasLayer.new()
	_status_layer.layer = 5
	add_child(_status_layer)
	_status_label = Label.new()
	_status_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_status_label.position = Vector2(-220, 8)
	_status_label.custom_minimum_size = Vector2(440, 0)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 18)
	_status_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	_status_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_status_label.add_theme_constant_override("outline_size", 6)
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_layer.add_child(_status_label)

func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text

func _refresh_status() -> void:
	if _game_over_shown:
		_set_status("")
	elif _reconnecting:
		_set_status("Connection lost - reconnecting...")
	elif _opp_disconnect_s >= 0:
		_set_status("Opponent disconnected - they forfeit in %ds" % _opp_disconnect_s)
	elif game_state != null and not game_state.mulligan_pending.is_empty() and not game_state.mulligan_pending.has(_my_id):
		_set_status("Waiting for opponent's mulligan...")
	elif _clock.has("turn_remaining_s") and int(_clock["turn_remaining_s"]) <= CLOCK_WARN_SEC \
			and str(_clock.get("responsible", "")) == _my_seat:
		_set_status("Time left: %ds" % int(_clock["turn_remaining_s"]))
	else:
		_set_status("")
