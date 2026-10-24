class_name MpGameManager
extends Node

const HOST_ID = "host"
const GUEST_ID = "guest"

var game_state: GameState
var board: Board
var _my_id: String
var _opp_id: String
var _is_host: bool

## Set when this match came from ranked matchmaking (see main.gd's ranked
## flow / Net.ranked_match_found) rather than a casual friend lobby — drives
## whether game-over reports a ladder result and moves matchmaking Elo.
var is_ranked: bool = false
var _opponent_rating: int = -1
## The server's id for this match (the ranked lobby id). Sent with the result
## so settlement can be made idempotent and tied to a real match.
var match_id: String = ""
## Set when this match is one node of a PvP Campaign run (see main.gd's
## _start_campaign_pvp_match) — drives whether game-over shows the
## "Continue" (campaign_continue_requested) button instead of "Play Again".
var is_campaign: bool = false

# ── Entry points ──────────────────────────────────────────────────────────

## node_modifier_ability/grant_bonus_self/grant_bonus_opponent are Campaign-
## PvP-only (see main.gd's _start_campaign_pvp_match / campaign_state.gd): a
## battlefield-wide ability granted to every creature played this match, and
## a one-time extra starting mana crystal for whichever side is down 2+ node
## wins (mirrors game_manager.gd's local-game grant_catchup_mana). Only the
## host's game_state actually drives gameplay (the guest's copy is a mirror
## refreshed via _apply_state), so these only need to be set here.
func start_as_host(board_node: Board, player_deck: Array[CardData], opp_deck: Array[CardData],
					opponent_name: String = "", ranked: bool = false, opponent_rating: int = -1,
					node_modifier_ability: String = "", grant_bonus_self: bool = false,
					grant_bonus_opponent: bool = false, campaign: bool = false) -> void:
	board = board_node
	board.is_online = true
	is_ranked = ranked
	is_campaign = campaign
	_opponent_rating = opponent_rating
	if not opponent_name.is_empty():
		board.set_opponent_name(opponent_name)
	_my_id = HOST_ID
	_opp_id = GUEST_ID
	_is_host = true

	board.player_hero.player_id = HOST_ID
	board.opponent_hero.player_id = GUEST_ID

	board.action_play_card.connect(_host_on_play_card)
	board.action_play_stratagem.connect(_host_on_play_stratagem)
	board.action_attack.connect(_host_on_attack)
	board.action_pilot.connect(_host_on_pilot)
	board.end_turn_pressed.connect(_host_on_end_turn)

	game_state = GameState.new(HOST_ID, GUEST_ID, player_deck, opp_deck)
	game_state.node_modifier_ability = node_modifier_ability
	game_state.set_events_enabled(true)

	var first := HOST_ID if randi() % 2 == 0 else GUEST_ID
	game_state.start_game(first)
	if grant_bonus_self:
		game_state.player.max_mana += 1
		if first == HOST_ID:
			game_state.player.current_mana += 1
	if grant_bonus_opponent:
		game_state.opponent.max_mana += 1
		if first == GUEST_ID:
			game_state.opponent.current_mana += 1
	board.setup(game_state)

	Net.relay({"type": "coinflip", "first": first})
	_send_state()

	await board.show_coinflip_result(first == HOST_ID)
	board.refresh()
	await _run_host_mulligan()
	await _host_announce_pending_draws()

	if first == HOST_ID:
		board.log_action("--- Your Turn %d ---" % game_state.turn_number)
	else:
		board.log_action("--- Opponent Turn %d ---" % game_state.turn_number)
		await _host_run_guest_turn()

## Mulligan phase: runs the host's own mulligan screen, then waits for the
## guest's picks (relayed as "action_mulligan" once the guest finishes its
## own screen - the guest is doing this concurrently on its own client, not
## waiting for the host first). Applies both sides to the authoritative
## game_state before turn 1 is allowed to start. card_ids are matched
## against a shrinking local pool rather than re-searching the full hand
## each time, so two copies of the same card in the guest's hand can both be
## swapped instead of the first match being found twice.
func _run_host_mulligan() -> void:
	await board.show_mulligan_screen(game_state.player.hand.duplicate(),
		func(swaps: Array[CardData]) -> Array[CardData]:
			return game_state.mulligan_swap(HOST_ID, swaps))

	var msg: Dictionary = await Net.await_relay_of_type("action_mulligan")
	var guest_hand_pool: Array[CardData] = game_state.opponent.hand.duplicate()
	var guest_swaps: Array[CardData] = []
	for cid in msg.get("card_ids", []):
		for c in guest_hand_pool:
			if c.id == str(cid):
				guest_swaps.append(c)
				guest_hand_pool.erase(c)
				break
	game_state.mulligan_swap(GUEST_ID, guest_swaps)

	board.refresh()
	_send_state()

func start_as_guest(board_node: Board, opponent_name: String = "", ranked: bool = false,
					 opponent_rating: int = -1, campaign: bool = false) -> void:
	board = board_node
	board.is_online = true
	is_ranked = ranked
	is_campaign = campaign
	_opponent_rating = opponent_rating
	if not opponent_name.is_empty():
		board.set_opponent_name(opponent_name)
	_my_id = GUEST_ID
	_opp_id = HOST_ID
	_is_host = false

	board.player_hero.player_id = GUEST_ID
	board.opponent_hero.player_id = HOST_ID

	board.action_play_card.connect(_guest_send_play_card)
	board.action_play_stratagem.connect(_guest_send_play_stratagem)
	board.action_attack.connect(_guest_send_attack)
	board.action_pilot.connect(_guest_send_pilot)
	board.end_turn_pressed.connect(_guest_send_end_turn)

	# Wait for initial state + coinflip
	var state_msg: Dictionary = await Net.await_relay_of_type("state_update")
	_apply_state(state_msg["state"])

	var cf_msg: Dictionary = await Net.await_relay_of_type("coinflip")
	var first: String = str(cf_msg["first"])
	await board.show_coinflip_result(first == GUEST_ID)
	board.refresh()

	# The host decides the replacements, so the screen waits on its reply and
	# deals the cards that arrived (appended to the end of the hand).
	await board.show_mulligan_screen(game_state.player.hand.duplicate(),
		func(swaps: Array[CardData]) -> Array[CardData]:
			Net.relay({"type": "action_mulligan", "card_ids": swaps.map(func(c): return c.id)})
			var post_mulligan_msg: Dictionary = await Net.await_relay_of_type("state_update")
			_apply_state(post_mulligan_msg["state"])
			var hand: Array[CardData] = game_state.player.hand
			var incoming: Array[CardData] = []
			for i in range(maxi(0, hand.size() - swaps.size()), hand.size()):
				incoming.append(hand[i])
			return incoming)

	await _guest_announce_pending_draws()

	if first == GUEST_ID:
		board.log_action("--- Your Turn %d ---" % game_state.turn_number)
	else:
		board.log_action("--- Opponent Turn %d ---" % game_state.turn_number)

	# Run the persistent guest message loop.
	_run_guest_loop()

# ── Shared helpers ─────────────────────────────────────────────────────────

func _send_state() -> void:
	# Built FOR THE GUEST: the host's hand is reduced to a count, so the
	# guest's client never receives the identities of cards it must not see.
	Net.relay({"type": "state_update", "state": game_state.to_net_dict(GUEST_ID)})

func _apply_state(d: Dictionary) -> void:
	game_state = GameState.from_net_dict(d, GUEST_ID)
	if board.game_state == null:
		board.setup(game_state)
	else:
		board.game_state = game_state
		board.refresh()

func _find_minion(player_id: String, instance_id: String) -> Minion:
	var p := game_state.player if player_id == _my_id else game_state.opponent
	for m in p.board:
		if m.instance_id == instance_id:
			return m
	return null

func _relay_log(text: String) -> void:
	Net.relay({"type": "log", "text": text})

func _relay_animate_attack(attacker_id: String, attacker_player_id: String, target_id: String) -> void:
	Net.relay({"type": "animate_attack", "attacker_id": attacker_id, "attacker_player_id": attacker_player_id, "target_id": target_id})

func _relay_animate_challenge(challenger_id: String, challenger_player_id: String, target_id: String) -> void:
	Net.relay({"type": "animate_challenge", "challenger_id": challenger_id, "challenger_player_id": challenger_player_id, "target_id": target_id})

func _relay_announce_card(card_id: String) -> void:
	Net.relay({"type": "announce_card", "card_id": card_id})

## Hearthstone-style pause: shows card_data big on this client's screen and
## relays the same announce to the other client, so both players see the
## card before it resolves - awaited by the host BEFORE the state-mutating
## play_creature/play_stratagem call so the pause lands ahead of resolution.
func _announce_both(card_data: CardData) -> void:
	_relay_announce_card(card_data.id)
	await board.announce_card(card_data)

# ── Host: events and choices ───────────────────────────────────────────────

## Presents events on the host's screen and relays them so the guest shows the
## same log lines and animations (the guest sees them with its own point of
## view - EventPresenter words each line from the viewer's side).
func _host_present(events: Array) -> void:
	if events.is_empty():
		return
	Net.relay({"type": "present_events", "events": GameState.filter_events_for(GUEST_ID, events)})
	await EventPresenter.present(events, board, HOST_ID)

## Answers every decision the rules core has open: the host's by asking the
## host, the guest's by asking the guest over the relay. The core validates
## every answer, so a modified guest can only pick among the legal options.
func _host_drive_choices() -> void:
	for _i in 64:
		if not is_instance_valid(board) or game_state.current_phase == GameState.Phase.GAME_OVER:
			return
		game_state.resolve_to_quiescence()
		if not game_state.has_pending_choice():
			return
		var choice: Dictionary = game_state.pending_choice.duplicate(true)
		var owner_id := str(choice["player_id"])
		var selection: String
		if owner_id == HOST_ID:
			selection = await board.prompt_choice(choice)
		else:
			Net.relay({"type": "prompt_choice", "choice": choice})
			_send_state()
			var resp: Dictionary = await Net.await_relay_of_type("response_choice")
			# An answer to some other choice (a stale or replayed message) is
			# treated as no answer: fall back to the choice's default.
			selection = str(resp.get("selection", "")) if str(resp.get("choice_id", "")) == str(choice["id"]) else str(choice["default"])
		if not is_instance_valid(board):
			return
		var result := game_state.execute({
			"type": GameState.CMD_ANSWER_CHOICE, "actor": owner_id,
			"choice_id": str(choice["id"]), "selection": selection,
		})
		if not result["ok"]:
			result = game_state.execute({
				"type": GameState.CMD_ANSWER_CHOICE, "actor": owner_id,
				"choice_id": str(choice["id"]), "selection": str(choice["default"]),
			})
			if not result["ok"]:
				game_state.cancel_pending_choice()
				return
		await _host_present(result["events"])
		board.refresh()
		_send_state()
		await _host_announce_pending_draws()

func _host_announce_pending_draws() -> void:
	if game_state.pending_drawn_cards.is_empty() and game_state.pending_fatigue_damage.is_empty():
		return
	for card_data in game_state.pending_drawn_cards:
		board.log_action("Drew %s" % card_data.card_name)
		await board.animate_draw()
	game_state.pending_drawn_cards.clear()
	for player_id in game_state.pending_fatigue_damage:
		var p := game_state._get_player_by_id(player_id)
		var whose := "You" if player_id == HOST_ID else "Opponent"
		board.log_action("%s took %d fatigue damage!" % [whose, p.fatigue_damage])
		board.refresh()
	game_state.pending_fatigue_damage.clear()
	_send_state()

## After any action by either player: show what happened, answer what is open,
## announce draws, and sync both screens.
func _host_after_action(events: Array) -> void:
	board.refresh()
	_send_state()
	await _host_present(events)
	await _host_drive_choices()
	await _host_announce_pending_draws()
	board.refresh()
	_send_state()
	if game_state.current_phase == GameState.Phase.GAME_OVER:
		_handle_game_over()

# ── Host: action handlers ─────────────────────────────────────────────────

func _host_on_play_card(card_data: CardData, at_index: int) -> void:
	if not game_state.is_local_player_turn():
		return
	await _announce_both(card_data)
	if not is_instance_valid(board):
		return
	var played := game_state.execute({
		"type": GameState.CMD_PLAY_CREATURE, "actor": HOST_ID,
		"card_uid": card_data.uid, "at_index": at_index,
	})
	if not played["ok"]:
		return
	board.log_action("You played %s" % card_data.card_name)
	_relay_log("Opponent played %s" % card_data.card_name)
	await get_tree().process_frame
	await get_tree().process_frame
	board.refresh()
	# See game_manager.gd's identical wait on this same call chain for why:
	# an on-play prompt below shouldn't race the just-played card's own landing.
	await board.await_slam_landed(board.player_board_zone)
	if not is_instance_valid(board):
		return
	await _host_after_action(played["events"])

func _host_on_attack(attacker_id: String, target_type: String, target_id: String) -> void:
	var attacker := _find_minion(HOST_ID, attacker_id)
	if not attacker:
		return
	var cmd := {"type": GameState.CMD_ATTACK, "actor": HOST_ID, "attacker_instance_id": attacker_id}
	if target_type == "minion":
		var target := _find_minion(GUEST_ID, target_id)
		if not target:
			return
		cmd["target_instance_id"] = target_id
		var result := game_state.execute(cmd)
		if not result["ok"]:
			return
		board.log_action("Your %s attacked opponent's %s" % [attacker.data.card_name, target.data.card_name])
		_relay_log("Opponent's %s attacked your %s" % [attacker.data.card_name, target.data.card_name])
		await board.animate_creature_attack(attacker_id, HOST_ID, target_id)
		_relay_animate_attack(attacker_id, HOST_ID, target_id)
		await _host_after_action(result["events"])
	elif target_type == "hero":
		cmd["target_player_id"] = target_id
		var result := game_state.execute(cmd)
		if not result["ok"]:
			return
		board.log_action("Your %s attacked the opponent's hero" % attacker.data.card_name)
		_relay_log("Opponent's %s attacked your hero" % attacker.data.card_name)
		# Empty target_id on the wire means "went face" - see the guest's
		# animate_attack handler.
		await board.animate_creature_attack_face(attacker_id, HOST_ID)
		_relay_animate_attack(attacker_id, HOST_ID, "")
		await _host_after_action(result["events"])

func _host_on_play_stratagem(card_data: CardData, target_minion: Minion, target_player_id: String) -> void:
	if not game_state.is_local_player_turn():
		return
	await _announce_both(card_data)
	if not is_instance_valid(board):
		return
	var strat := game_state.execute({
		"type": GameState.CMD_PLAY_STRATAGEM, "actor": HOST_ID, "card_uid": card_data.uid,
		"target_instance_id": target_minion.instance_id if target_minion != null else "",
		"target_player_id": target_player_id,
	})
	if not strat["ok"]:
		board.refresh()
		return
	board.log_action("You played %s" % card_data.card_name)
	_relay_log("Opponent played %s" % card_data.card_name)
	await get_tree().process_frame
	await get_tree().process_frame
	await _host_after_action(strat["events"])

func _host_on_pilot(pilot_id: String, target_id: String) -> void:
	var result := game_state.execute({
		"type": GameState.CMD_PILOT, "actor": HOST_ID,
		"pilot_instance_id": pilot_id, "target_instance_id": target_id,
	})
	if result["ok"]:
		await _host_after_action(result["events"])
	else:
		board.refresh()

func _host_on_end_turn() -> void:
	var ended := game_state.execute({"type": GameState.CMD_END_TURN, "actor": HOST_ID})
	if not ended["ok"]:
		return
	await _host_after_action(ended["events"])
	board.log_action("--- Opponent Turn %d ---" % game_state.turn_number)
	await _host_run_guest_turn()

# ── Host: guest turn proxy ─────────────────────────────────────────────────

## The guest's actions arrive as relay messages and are applied here through the
## same validated command boundary as everyone else's - a guest cannot do
## anything the rules would not allow the host.
func _host_run_guest_turn() -> void:
	# Effects that fire at turn start (drawn cards, queued decisions).
	await _host_after_action(game_state.drain_events())

	while true:
		if game_state.current_phase == GameState.Phase.GAME_OVER:
			_handle_game_over()
			return

		var action: Dictionary = await Net.await_relay_action()
		var t: String = action.get("type", "")

		if t == "action_end_turn":
			if game_state.has_pending_choice():
				continue
			var ended := game_state.execute({"type": GameState.CMD_END_TURN, "actor": GUEST_ID})
			if not ended["ok"]:
				continue
			await _host_after_action(ended["events"])
			board.log_action("--- Your Turn %d ---" % game_state.turn_number)
			return

		elif t == "action_play_card":
			var card = _find_card_in_hand(GUEST_ID, str(action.get("card_id", "")))
			if card == null:
				continue
			# Registered before the announce pause rather than right before
			# the play - see ai_controller.gd's identical comment on this same
			# call for why (avoids a stutter right at the slam).
			board.play_opponent_card_with_slam(card)
			await _announce_both(card)
			if not is_instance_valid(board):
				return
			var played := game_state.execute({
				"type": GameState.CMD_PLAY_CREATURE, "actor": GUEST_ID,
				"card_uid": card.uid, "at_index": int(action.get("at_index", -1)),
			})
			if not played["ok"]:
				board.refresh()
				continue
			board.log_action("Opponent played %s" % card.card_name)
			_relay_log("You played %s" % card.card_name)
			board.refresh()
			await board.await_slam_landed(board.opponent_board_zone)
			if not is_instance_valid(board):
				return
			await _host_after_action(played["events"])

		elif t == "action_attack":
			var attacker := _find_minion(GUEST_ID, str(action.get("attacker_id", "")))
			if not attacker:
				continue
			var target_type: String = str(action.get("target_type", ""))
			var target_id: String = str(action.get("target_id", ""))
			var cmd := {"type": GameState.CMD_ATTACK, "actor": GUEST_ID, "attacker_instance_id": attacker.instance_id}
			if target_type == "minion":
				var target := _find_minion(HOST_ID, target_id)
				if not target:
					continue
				cmd["target_instance_id"] = target_id
				var result := game_state.execute(cmd)
				if not result["ok"]:
					continue
				board.log_action("Opponent's %s attacked your %s" % [attacker.data.card_name, target.data.card_name])
				_relay_log("Your %s attacked opponent's %s" % [attacker.data.card_name, target.data.card_name])
				await board.animate_creature_attack(attacker.instance_id, GUEST_ID, target_id)
				_relay_animate_attack(attacker.instance_id, GUEST_ID, target_id)
				await _host_after_action(result["events"])
			elif target_type == "hero":
				cmd["target_player_id"] = target_id
				var attacker_id := attacker.instance_id
				var result := game_state.execute(cmd)
				if not result["ok"]:
					continue
				board.log_action("Opponent's %s attacked your hero" % attacker.data.card_name)
				_relay_log("Your %s attacked opponent's hero" % attacker.data.card_name)
				await board.animate_creature_attack_face(attacker_id, GUEST_ID)
				_relay_animate_attack(attacker_id, GUEST_ID, "")
				await _host_after_action(result["events"])
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				return

		elif t == "action_play_stratagem":
			var card := _find_card_in_hand(GUEST_ID, str(action.get("card_id", "")))
			if card == null:
				continue
			await _announce_both(card)
			if not is_instance_valid(board):
				return
			var strat := game_state.execute({
				"type": GameState.CMD_PLAY_STRATAGEM, "actor": GUEST_ID, "card_uid": card.uid,
				"target_instance_id": str(action.get("target_minion_id", "")),
				"target_player_id": str(action.get("target_player_id", "")),
			})
			if not strat["ok"]:
				continue
			board.log_action("Opponent played %s" % card.card_name)
			_relay_log("You played %s" % card.card_name)
			await _host_after_action(strat["events"])
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				return

		elif t == "action_pilot":
			var result := game_state.execute({
				"type": GameState.CMD_PILOT, "actor": GUEST_ID,
				"pilot_instance_id": str(action.get("pilot_id", "")),
				"target_instance_id": str(action.get("target_id", "")),
			})
			if result["ok"]:
				await _host_after_action(result["events"])

# ── Guest: send actions ────────────────────────────────────────────────────

func _guest_send_play_card(card_data: CardData, at_index: int) -> void:
	if not game_state.is_local_player_turn():
		return
	Net.relay({"type": "action_play_card", "card_id": card_data.id, "at_index": at_index})

func _guest_send_attack(attacker_id: String, target_type: String, target_id: String) -> void:
	Net.relay({"type": "action_attack", "attacker_id": attacker_id, "target_type": target_type, "target_id": target_id})

func _guest_send_play_stratagem(card_data: CardData, target_minion: Minion, target_player_id: String) -> void:
	if not game_state.is_local_player_turn():
		return
	Net.relay({
		"type": "action_play_stratagem",
		"card_id": card_data.id,
		"target_minion_id": target_minion.instance_id if target_minion != null else "",
		"target_player_id": target_player_id,
	})

func _guest_send_pilot(pilot_id: String, target_id: String) -> void:
	Net.relay({"type": "action_pilot", "pilot_id": pilot_id, "target_id": target_id})

func _guest_send_end_turn() -> void:
	Net.relay({"type": "action_end_turn"})

# ── Guest: receive state / prompts ─────────────────────────────────────────

func _run_guest_loop() -> void:
	while true:
		if not await _guest_drain_queue():
			return
		if Net._relay_queue.is_empty():
			await Net._queue_updated

# Drains all pending relay messages in order: prompts → log → animation → state.
# Returns false when the game is over so the outer loop can exit.
func _guest_drain_queue() -> bool:
	while true:
		var prompt = _peek_prompt()
		if prompt != null:
			Net._relay_queue.erase(prompt)
			await _guest_respond_to_prompt(prompt)
			continue

		var announce = Net.pop_of_type("announce_card")
		if announce != null:
			var announced_card := CardDatabase.get_card(str(announce.get("card_id", "")))
			if announced_card != null:
				await board.announce_card(announced_card)
			continue

		var present_msg = Net.pop_of_type("present_events")
		if present_msg != null:
			await EventPresenter.present(present_msg.get("events", []), board, GUEST_ID)
			continue

		var log_msg = Net.pop_of_type("log")
		if log_msg != null:
			board.log_action(str(log_msg.get("text", "")))
			continue

		var anim = Net.pop_of_type("animate_attack")
		if anim != null:
			# An empty target id means the attacker went face.
			var anim_target := str(anim.get("target_id", ""))
			if anim_target.is_empty():
				await board.animate_creature_attack_face(
					str(anim.get("attacker_id", "")),
					str(anim.get("attacker_player_id", ""))
				)
			else:
				await board.animate_creature_attack(
					str(anim.get("attacker_id", "")),
					str(anim.get("attacker_player_id", "")),
					anim_target
				)
			continue

		var ch_anim = Net.pop_of_type("animate_challenge")
		if ch_anim != null:
			await board.animate_creature_challenge(
				str(ch_anim.get("challenger_id", "")),
				str(ch_anim.get("challenger_player_id", "")),
				str(ch_anim.get("target_id", ""))
			)
			continue

		var state_msg = Net.pop_of_type("state_update")
		if state_msg != null:
			var was_my_turn := game_state != null and game_state.is_local_player_turn()
			_apply_state(state_msg["state"])
			if game_state.current_phase == GameState.Phase.GAME_OVER:
				_report_and_show_game_over(game_state.winner_id == GUEST_ID)
				return false
			var is_my_turn_now := game_state.is_local_player_turn()
			if not was_my_turn and is_my_turn_now:
				await _guest_announce_pending_draws()
				board.log_action("--- Your Turn %d ---" % game_state.turn_number)
			elif was_my_turn and not is_my_turn_now:
				board.log_action("--- Opponent Turn %d ---" % game_state.turn_number)
			continue

		break
	return true

func _peek_prompt() -> Variant:
	for msg in Net._relay_queue:
		var t: String = msg.get("type", "")
		if t.begins_with("prompt_"):
			return msg
	return null

func _guest_respond_to_prompt(prompt: Dictionary) -> void:
	# One generic prompt: the host's rules core opened a choice for this player.
	if str(prompt.get("type", "")) != "prompt_choice":
		return
	var choice: Dictionary = prompt.get("choice", {})
	var selection: String = await board.prompt_choice(choice)
	Net.relay({"type": "response_choice", "choice_id": str(choice.get("id", "")), "selection": selection})

func _guest_announce_pending_draws() -> void:
	if game_state.pending_drawn_cards.is_empty() and game_state.pending_fatigue_damage.is_empty():
		return
	for card_data in game_state.pending_drawn_cards:
		board.log_action("Drew %s" % card_data.card_name)
		await board.animate_draw()
	game_state.pending_drawn_cards.clear()
	for player_id in game_state.pending_fatigue_damage:
		var p := game_state._get_player_by_id(player_id)
		var whose := "You" if player_id == GUEST_ID else "Opponent"
		board.log_action("%s took %d fatigue damage!" % [whose, p.fatigue_damage])
		board.refresh()
	game_state.pending_fatigue_damage.clear()

# ── Shared utilities ───────────────────────────────────────────────────────

func _find_minion_anywhere(instance_id: String) -> Minion:
	for m in game_state.player.board:
		if m.instance_id == instance_id:
			return m
	for m in game_state.opponent.board:
		if m.instance_id == instance_id:
			return m
	return null

func _find_card_in_hand(player_id: String, card_id: String) -> CardData:
	var p := game_state.player if player_id == _my_id else game_state.opponent
	for c in p.hand:
		if c.id == card_id:
			return c
	return null

func _handle_game_over() -> void:
	if _is_host:
		Net.relay({"type": "game_over", "winner_id": game_state.winner_id})
		_send_state()
	_report_and_show_game_over(game_state.winner_id == _my_id)

## Shared by the host's own game-over detection and the guest's (see the
## state_update branch in the guest message loop) so both sides report their
## own ranked result and Elo independently — each side only ever mutates its
## own account row, so there's no cross-client transaction to coordinate.
func _report_and_show_game_over(won: bool) -> void:
	if is_ranked:
		var old_bracket := Auth.rank_bracket
		var old_in_legend := Auth.rank_in_legend
		var old_legend_rating := Auth.rank_legend_rating
		Auth.report_ranked_result(won, _opponent_rating, match_id)
		board.show_game_over(won, true, old_bracket, old_in_legend, old_legend_rating)
	elif is_campaign:
		board.show_game_over(won, false, 0, false, 0, true)
	else:
		board.show_game_over(won)
