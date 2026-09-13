extends Node

# Paste your deployed relay URL here before playing multiplayer.
const RELAY_URL = "wss://cardgame-relay-production.up.railway.app"

var _ws := WebSocketPeer.new()
var _connected := false
var _relay_queue: Array[Dictionary] = []

signal connected_to_server
signal disconnected_from_server
signal lobby_list_received(lobbies: Array)
signal lobby_created(lobby_id: String)
signal joined_lobby(lobby_id: String, host_name: String)
signal player_joined(guest_name: String)
signal opponent_left
signal error_received(message: String)
signal register_result(success: bool, message: String, profile: Dictionary)
signal login_result(success: bool, message: String, profile: Dictionary)
signal logged_out
signal ranked_result_received(success: bool, profile: Dictionary)
signal ranked_match_found(lobby_id: String, role: String, opponent_name: String, opponent_rating: int)
signal campaign_match_found(lobby_id: String, role: String, opponent_name: String, size: int)
signal save_deck_result(success: bool, message: String, deck_name: String)
signal delete_deck_result(success: bool, message: String, deck_name: String)
signal set_pfp_result(success: bool, message: String, pfp_id: String)
signal economy_state_result(success: bool, currency: int, dust: int, owned_cards: Dictionary)
signal purchase_pack_result(success: bool, message: String, currency: int, dust: int, pack_id: String, cards: Array, dust_awarded: int)
signal craft_card_result(success: bool, message: String, dust: int, card_id: String, dust_needed: int)
signal claim_earn_reward_result(success: bool, message: String, currency: int, dust: int, amount_awarded: int, reason: String)
signal _queue_updated

func connect_to_relay() -> void:
	_ws.connect_to_url(RELAY_URL)

func disconnect_from_relay() -> void:
	_ws.close()
	_connected = false

func _process(_delta: float) -> void:
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
			connected_to_server.emit()
		while _ws.get_available_packet_count() > 0:
			var raw := _ws.get_packet().get_string_from_utf8()
			var msg = JSON.parse_string(raw)
			if msg == null:
				continue
			_handle_incoming(msg)
	elif state == WebSocketPeer.STATE_CLOSED and _connected:
		_connected = false
		disconnected_from_server.emit()

func _handle_incoming(msg: Dictionary) -> void:
	match msg.get("type", ""):
		"lobby_list":
			lobby_list_received.emit(msg.get("lobbies", []))
		"lobby_created":
			lobby_created.emit(str(msg.get("lobby_id", "")))
		"joined_lobby":
			joined_lobby.emit(str(msg.get("lobby_id", "")), str(msg.get("host_name", "")))
		"player_joined":
			player_joined.emit(str(msg.get("guest_name", "")))
		"opponent_left":
			opponent_left.emit()
		"error":
			error_received.emit(str(msg.get("message", "")))
		"register_result":
			var success := bool(msg.get("success", false))
			register_result.emit(success, str(msg.get("message", "")), _profile_from(msg) if success else {})
		"login_result":
			var success := bool(msg.get("success", false))
			login_result.emit(success, str(msg.get("message", "")), _profile_from(msg) if success else {})
		"logged_out":
			logged_out.emit()
		"ranked_result_ack":
			var success := bool(msg.get("success", false))
			ranked_result_received.emit(success, _rank_fields_from(msg) if success else {})
		"save_deck_result":
			save_deck_result.emit(bool(msg.get("success", false)), str(msg.get("message", "")), str(msg.get("name", "")))
		"delete_deck_result":
			delete_deck_result.emit(bool(msg.get("success", false)), str(msg.get("message", "")), str(msg.get("name", "")))
		"set_pfp_result":
			set_pfp_result.emit(bool(msg.get("success", false)), str(msg.get("message", "")), str(msg.get("pfp_id", "")))
		"economy_state_result":
			var success := bool(msg.get("success", false))
			economy_state_result.emit(
				success,
				int(msg.get("currency", 0)),
				int(msg.get("dust", 0)),
				_owned_cards_from(msg.get("owned_cards", []))
			)
		"purchase_pack_result":
			var success := bool(msg.get("success", false))
			var result: Dictionary = msg.get("result", {})
			purchase_pack_result.emit(
				success,
				str(msg.get("message", "")),
				int(msg.get("currency", 0)),
				int(msg.get("dust", 0)),
				str(result.get("pack_id", "")),
				result.get("cards", []),
				int(result.get("dust_awarded", 0))
			)
		"craft_card_result":
			craft_card_result.emit(
				bool(msg.get("success", false)),
				str(msg.get("message", "")),
				int(msg.get("dust", 0)),
				str(msg.get("card_id", "")),
				int(msg.get("dust_needed", 0))
			)
		"claim_earn_reward_result":
			claim_earn_reward_result.emit(
				bool(msg.get("success", false)),
				str(msg.get("message", "")),
				int(msg.get("currency", 0)),
				int(msg.get("dust", 0)),
				int(msg.get("amount_awarded", 0)),
				str(msg.get("reason", ""))
			)
		"ranked_match_found":
			ranked_match_found.emit(
				str(msg.get("lobby_id", "")),
				str(msg.get("role", "")),
				str(msg.get("opponent_name", "")),
				int(msg.get("opponent_rating", 1000))
			)
		"campaign_match_found":
			campaign_match_found.emit(
				str(msg.get("lobby_id", "")),
				str(msg.get("role", "")),
				str(msg.get("opponent_name", "")),
				int(msg.get("size", 0))
			)
		"relay":
			var payload = msg.get("payload", {})
			var from_role = str(msg.get("from_role", ""))
			payload["_from_role"] = from_role
			_relay_queue.append(payload)
			_queue_updated.emit()

func send(obj: Dictionary) -> void:
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(obj))

func create_lobby(host_name: String, lobby_name: String = "") -> void:
	send({"type": "create_lobby", "host_name": host_name, "name": lobby_name if lobby_name != "" else host_name + "'s Lobby"})

func list_lobbies() -> void:
	send({"type": "list_lobbies"})

func join_lobby(lobby_id: String, guest_name: String) -> void:
	send({"type": "join_lobby", "lobby_id": lobby_id, "guest_name": guest_name})

func relay(payload: Dictionary) -> void:
	send({"type": "relay", "payload": payload})

func register(username: String, password: String) -> void:
	send({"type": "register", "username": username, "password": password})

func login(username: String, password: String) -> void:
	send({"type": "login", "username": username, "password": password})

func resume_session(token: String) -> void:
	send({"type": "resume_session", "token": token})

func logout(token: String) -> void:
	send({"type": "logout", "token": token})

func report_ranked_result(token: String, won: bool, opponent_rating: int = -1) -> void:
	var msg := {"type": "report_ranked_result", "token": token, "won": won}
	if opponent_rating >= 0:
		msg["opponent_rating"] = opponent_rating
	send(msg)

func queue_ranked(token: String) -> void:
	send({"type": "queue_ranked", "token": token})

func cancel_ranked_queue(token: String) -> void:
	send({"type": "cancel_ranked_queue", "token": token})

func queue_campaign(token: String, size: int) -> void:
	send({"type": "queue_campaign", "token": token, "size": size})

func cancel_campaign_queue(token: String) -> void:
	send({"type": "cancel_campaign_queue", "token": token})

func save_deck(token: String, deck_name: String, faction_idx: int, card_ids: Array) -> void:
	send({"type": "save_deck", "token": token, "name": deck_name, "faction_idx": faction_idx, "card_ids": card_ids})

func delete_deck(token: String, deck_name: String) -> void:
	send({"type": "delete_deck", "token": token, "name": deck_name})

func set_pfp(token: String, pfp_id: String) -> void:
	send({"type": "set_pfp", "token": token, "pfp_id": pfp_id})

func get_economy_state(token: String) -> void:
	send({"type": "get_economy_state", "token": token})

func purchase_pack(token: String, pack_id: String) -> void:
	send({"type": "purchase_pack", "token": token, "pack_id": pack_id})

func craft_card(token: String, card_id: String) -> void:
	send({"type": "craft_card", "token": token, "card_id": card_id})

func claim_earn_reward(token: String, reason: String) -> void:
	send({"type": "claim_earn_reward", "token": token, "reason": reason})

func _profile_from(msg: Dictionary) -> Dictionary:
	var d := {
		"token": str(msg.get("token", "")),
		"username": str(msg.get("username", "")),
		"wins": int(msg.get("wins", 0)),
		"losses": int(msg.get("losses", 0)),
		"rating": int(msg.get("rating", 0)),
		"pfp_id": str(msg.get("pfp_id", "")),
		"decks": _decks_from(msg),
	}
	d.merge(_rank_fields_from(msg))
	return d

func _decks_from(msg: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in msg.get("decks", []):
		if not entry is Dictionary:
			continue
		var card_ids: Array[String] = []
		for id in entry.get("card_ids", []):
			card_ids.append(str(id))
		out.append({
			"name": str(entry.get("name", "")),
			"faction_idx": int(entry.get("faction_idx", 0)),
			"card_ids": card_ids,
			"is_starter": false,
		})
	return out

## Server sends owned_cards as an array of {card_id, quantity}; the client
## uses a card_id -> quantity Dictionary instead since every lookup site
## (collection checks, deck builder) wants "how many of this card" directly.
func _owned_cards_from(raw: Array) -> Dictionary:
	var out := {}
	for entry in raw:
		if entry is Dictionary:
			out[str(entry.get("card_id", ""))] = int(entry.get("quantity", 0))
	return out

func _rank_fields_from(msg: Dictionary) -> Dictionary:
	return {
		"rating": int(msg.get("rating", 1000)),
		"rank_bracket": int(msg.get("rank_bracket", 0)),
		"rank_in_legend": bool(msg.get("rank_in_legend", false)),
		"rank_legend_rating": int(msg.get("rank_legend_rating", 0)),
		"rank_lp": int(msg.get("rank_lp", 0)),
		"ranked_win_streak": int(msg.get("ranked_win_streak", 0)),
		"ranked_wins": int(msg.get("ranked_wins", 0)),
		"ranked_losses": int(msg.get("ranked_losses", 0)),
	}

# Pops first message of a given type from the queue, or null if not found.
func pop_of_type(t: String) -> Variant:
	for i in _relay_queue.size():
		if _relay_queue[i].get("type", "") == t:
			return _relay_queue.pop_at(i)
	return null

# Awaits a relay message of a given type, checking the queue first.
func await_relay_of_type(t: String) -> Dictionary:
	var found = pop_of_type(t)
	if found != null:
		return found
	while true:
		await _queue_updated
		found = pop_of_type(t)
		if found != null:
			return found
	return {}

# Awaits any action_* relay message.
func await_relay_action() -> Dictionary:
	while true:
		for i in _relay_queue.size():
			if _relay_queue[i].get("type", "").begins_with("action_"):
				return _relay_queue.pop_at(i)
		await _queue_updated
	return {}

# Awaits any response_* relay message.
func await_relay_response() -> Dictionary:
	while true:
		for i in _relay_queue.size():
			if _relay_queue[i].get("type", "").begins_with("response_"):
				return _relay_queue.pop_at(i)
		await _queue_updated
	return {}
