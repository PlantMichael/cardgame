extends Node

const Bots = preload("res://scripts/game/moon_bots.gd")
const ACTION_PAUSE_MS := 600
const RESPONSE_TIMEOUT_MS := 10000
const DECK_NAME := "Moon Bot 1.0"

class BotConnection:
	var profile: Dictionary
	var token: String
	var ws: WebSocketPeer
	var stage := "disconnected"
	var due := 0
	var deadline := 0
	var match_id := ""
	var my_id := ""
	var seat := ""
	var clock := {}
	var seq := -1
	var client_seq := 0
	var epoch := 0
	var awaiting := false
	var thinking := false
	var view := {}
	var deck: Array[CardData] = []
	var faction := 0
	var failures := 0
	var next_ai := true
	var ai_match_id := ""
	var ai_level := 0
	var ai_state: GameState
	var ai_deck: Array[CardData] = []
	var ai_report := {}
	var ai_started := 0
	var ai_actions := 0
	var ai_first := ""
	var ai_check_due := 0

var _bots: Array[BotConnection] = []
var _url := ""

func _ready() -> void:
	_url = OS.get_environment("RANKED_BOT_URL")
	var sessions = JSON.parse_string(OS.get_environment("RANKED_BOT_SESSIONS"))
	var profiles := Bots.roster()
	if not sessions is Array or sessions.size() != 4 or not (_url.begins_with("ws://") or _url.begins_with("wss://")):
		_fail("Invalid ranked bot configuration")
		return
	var seen := {}
	for account in sessions:
		var id := str(account.get("id", ""))
		if id == "standard" or not profiles.has(id) or seen.has(id) or str(account.get("token", "")).length() != 64:
			_fail("Invalid ranked bot identity")
			return
		seen[id] = true
		var c := BotConnection.new()
		c.profile = profiles[id]
		c.token = str(account["token"])
		c.faction = _bots.size() % 5
		_bots.append(c)
	print("RANKED_BOTS_READY")

func _fail(message: String) -> void:
	push_error(message) # Never log session tokens or credentials.
	get_tree().quit(1)

func _send(c: BotConnection, message: Dictionary) -> void:
	message["token"] = c.token
	c.ws.send_text(JSON.stringify(message))

func _connect(c: BotConnection, now: int) -> void:
	c.epoch += 1
	c.ws = WebSocketPeer.new()
	c.awaiting = false
	c.stage = "connecting"
	c.deadline = now + RESPONSE_TIMEOUT_MS
	if c.ws.connect_to_url(_url) != OK:
		_disconnect(c, now)

func _disconnect(c: BotConnection, now: int) -> void:
	if c.ws != null:
		c.ws.close()
	c.epoch += 1
	c.stage = "disconnected"
	c.awaiting = false
	c.failures = mini(c.failures + 1, 4)
	c.due = now + mini(30000, 1000 * (1 << c.failures))

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for c in _bots:
		if c.stage == "disconnected":
			if now >= c.due:
				_connect(c, now)
			continue
		c.ws.poll()
		var state := c.ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			_disconnect(c, now)
			continue
		if state != WebSocketPeer.STATE_OPEN:
			if now > c.deadline:
				_disconnect(c, now)
			continue
		if c.stage == "connecting":
			c.stage = "authenticating"
			_send(c, {"type": "resume_session"})
			c.deadline = now + RESPONSE_TIMEOUT_MS
		while c.ws.get_available_packet_count() > 0:
			var message = JSON.parse_string(c.ws.get_packet().get_string_from_utf8())
			if message is Dictionary:
				_receive(c, message, now)
		if c.stage in ["authenticating", "saving", "joining", "ai_starting", "ai_reporting"] and now > c.deadline:
			_disconnect(c, now)
		elif c.stage == "pause" and now >= c.due:
			_draft(c, now)
		elif c.stage == "playing" and c.awaiting and now > c.deadline:
			_join(c, c.match_id, now) # Refresh before deciding again; never blindly resend a move.
		elif c.stage == "playing" and not c.awaiting and not c.thinking and now >= c.due:
			_think(c)
		elif c.stage == "ai_playing":
			if now > c.deadline:
				_disconnect(c, now)
				continue
			if now >= c.ai_check_due:
				_send(c, {"type": "ranked_bot_ai_start", "match_id": c.ai_match_id})
				c.ai_check_due = now + 5000
			if not c.thinking and now >= c.due:
				_ai_step(c)

func _draft(c: BotConnection, now: int) -> void:
	seed(str(c.profile["id"]).hash() + str(c.profile["version"]).hash() + c.faction)
	c.deck = Bots.build_deck(c.profile, c.faction, Bots.published_ids())
	if c.deck.size() != 40:
		_fail("Ranked bot could not draft a public deck")
		return
	c.stage = "saving"
	c.deadline = now + RESPONSE_TIMEOUT_MS
	_send(c, {"type": "save_deck", "name": DECK_NAME, "faction_idx": c.faction, "card_ids": c.deck.map(func(card): return card.id)})

func _join(c: BotConnection, id: String, now: int) -> void:
	c.match_id = id
	c.view = {}
	c.seq = -1
	c.awaiting = false
	c.stage = "joining"
	c.deadline = now + RESPONSE_TIMEOUT_MS
	c.epoch += 1
	_send(c, {"type": "match_join", "match_id": id})

func _receive(c: BotConnection, msg: Dictionary, now: int) -> void:
	var type := str(msg.get("type", ""))
	if type.begins_with("match_") and msg.has("match_id") and str(msg["match_id"]) != c.match_id:
		return
	match type:
		"login_result":
			if not bool(msg.get("success", false)) or str(msg.get("username", "")) != str(c.profile["name"]) or msg.get("bot_profile", {}) != c.profile:
				_fail("Ranked bot session or profile was refused")
				return
			if not bool(msg.get("ranked_authoritative", false)) or int(msg.get("rules_version", 0)) != RulesVersion.RULES_VERSION:
				_fail("Ranked bots require matching authoritative-ranked service")
				return
			if not bool(msg.get("ranked_bot_ai", false)):
				_fail("Ranked bots require rank-matched AI support")
				return
			c.failures = 0
			c.next_ai = bool(msg.get("bot_next_ai", true))
			# Existing decks are returned on resume, so rejoining does not change our draft.
			for deck in msg.get("decks", []):
				if str(deck.get("name", "")) == DECK_NAME:
					c.deck.clear()
					for id in deck.get("card_ids", []):
						var card := CardDatabase.get_card(str(id))
						if card != null:
							c.deck.append(card)
					c.faction = int(deck.get("faction_idx", 0))
			if not c.match_id.is_empty():
				_join(c, c.match_id, now)
			elif not c.ai_match_id.is_empty():
				_start_ai(c, now)
			elif c.deck.is_empty():
				_draft(c, now)
			else:
				_next_opponent(c, now)
		"save_deck_result":
			if c.stage != "saving":
				return
			if not bool(msg.get("success", false)):
				_disconnect(c, now)
				return
			_next_opponent(c, now)
		"ranked_bot_ai_ready":
			if c.stage not in ["ai_starting", "ai_playing"] or str(msg.get("match_id", "")) != c.ai_match_id:
				return
			if not bool(msg.get("success", false)):
				if not str(msg.get("active_match_id", "")).is_empty():
					_clear_ai(c)
					_join(c, str(msg["active_match_id"]), now)
				else:
					_disconnect(c, now)
				return
			if not c.ai_report.is_empty():
				_report_ai(c, now)
				return
			var level := int(msg.get("ai_level", 0))
			if level < 3 or level > 10 or (c.ai_state != null and c.ai_level != level):
				_fail("Ranked AI difficulty changed during a game")
				return
			c.ai_level = level
			c.deadline = now + RESPONSE_TIMEOUT_MS
			if c.stage == "ai_playing":
				return # Liveness acknowledgment, not a second game or draft.
			if c.ai_state == null:
				c.ai_deck = DeckManager.build_archetype_deck(randi_range(0, 4), -1, Bots.published_ids())
				if c.ai_deck.size() != 40:
					_fail("Ranked AI could not draft a public deck")
					return
				c.ai_first = "host" if randf() < 0.5 else "guest"
				c.ai_state = GameState.new("host", "guest", c.deck, c.ai_deck, randi() & 0x7fffffff)
				c.ai_state.set_events_enabled(true)
				c.ai_state.start_game(c.ai_first)
				c.ai_state.begin_mulligan()
				c.ai_started = now
				print("RANKED_BOT_EVENT " + JSON.stringify({"event": "ai_started", "bot": c.profile["id"], "ai_level": level, "match_id": c.ai_match_id}))
			c.stage = "ai_playing"
			c.ai_check_due = now + 5000
			c.due = now + ACTION_PAUSE_MS
		"ranked_result_ack":
			if c.stage != "ai_reporting":
				return
			if not bool(msg.get("success", false)):
				if str(msg.get("message", "")) not in ["Session expired.", "Server error, try again."]:
					_fail("Ranked bot AI result was refused")
					return
				_disconnect(c, now)
				return
			print("RANKED_BOT_EVENT " + JSON.stringify({"event": "completed", "bot": c.profile["id"], "match_id": c.ai_match_id, "opponent": "ranked_ai", "ai_level": c.ai_level}))
			_clear_ai(c)
			c.next_ai = false
			_finished(c, now)
		"ranked_match_found":
			if not bool(msg.get("server_run", false)):
				_fail("Refused a non-authoritative bot match")
				return
			_join(c, str(msg["match_id"]), now)
		"ranked_refused":
			if str(msg.get("reason", "")) == "update_required":
				_fail("Ranked bot rules update required")
				return
			if str(msg.get("reason", "")) == "already_in_match" and not str(msg.get("match_id", "")).is_empty():
				_join(c, str(msg["match_id"]), now)
			else:
				c.stage = "pause"
				c.due = now + 3000
		"match_view":
			if int(msg.get("seq", -1)) < c.seq:
				return
			if c.stage == "joining":
				print("RANKED_BOT_EVENT " + JSON.stringify({"event": "joined", "bot": c.profile["id"], "match_id": c.match_id}))
			c.seq = int(msg["seq"])
			c.client_seq = maxi(c.client_seq, int(msg.get("client_seq", 0)))
			c.my_id = str(msg["you"])
			c.seat = str(msg["seat"])
			c.clock = msg.get("clock", {})
			c.view = msg["view"]
			c.stage = "playing"
			c.due = maxi(c.due, now + ACTION_PAUSE_MS)
		"match_clock":
			c.clock = msg.get("clock", {})
		"match_ack":
			if int(msg.get("client_seq", -1)) == c.client_seq:
				c.awaiting = false
		"match_error":
			c.awaiting = false
			if not msg.has("match_id"):
				_disconnect(c, now) # Authentication failed before match routing; refresh the session.
				return
			if str(msg.get("reason", "")) == "unknown_match":
				_finished(c, now)
			else:
				_join(c, c.match_id, now)
		"error":
			_disconnect(c, now)
		"match_over", "match_voided":
			if type == "match_over":
				print("RANKED_BOT_EVENT " + JSON.stringify({"event": "completed", "bot": c.profile["id"], "match_id": c.match_id}))
				c.next_ai = true
			_finished(c, now)

func _next_opponent(c: BotConnection, now: int) -> void:
	if c.next_ai:
		_start_ai(c, now)
	else:
		_queue(c)

func _start_ai(c: BotConnection, now: int) -> void:
	if c.ai_match_id.is_empty():
		c.ai_match_id = "ai_%d_%d" % [Time.get_unix_time_from_system(), absi((str(c.profile["id"]) + str(Time.get_ticks_usec()) + str(randi())).hash())]
	c.stage = "ai_starting"
	c.deadline = now + RESPONSE_TIMEOUT_MS
	_send(c, {"type": "ranked_bot_ai_start", "match_id": c.ai_match_id})

func _report_ai(c: BotConnection, now: int) -> void:
	c.stage = "ai_reporting"
	c.deadline = now + RESPONSE_TIMEOUT_MS
	_send(c, {"type": "report_ranked_result", "match_id": c.ai_match_id,
		"won": c.ai_report["won"], "ai_match": c.ai_report["summary"]})

func _clear_ai(c: BotConnection) -> void:
	c.epoch += 1
	c.ai_state = null
	c.ai_match_id = ""
	c.ai_report = {}
	c.ai_deck.clear()
	c.ai_actions = 0

func _ai_step(c: BotConnection) -> void:
	var gs := c.ai_state
	if gs == null:
		return
	if gs.current_phase == GameState.Phase.GAME_OVER:
		if gs.winner_id not in ["host", "guest"]:
			_ai_failed(c)
			return
		c.ai_report = {"won": gs.winner_id == "host", "summary": {
			"player_deck": c.deck.map(func(card): return card.id), "opponent_deck": c.ai_deck.map(func(card): return card.id),
			"ai_level": c.ai_level, "ai_version": AIController.POLICY_VERSION, "rules_version": RulesVersion.RULES_VERSION,
			"turns": gs.turn_number, "first_player": "player" if c.ai_first == "host" else "opponent",
			"card_plays": {"player": gs.card_play_counts("host"), "opponent": gs.card_play_counts("guest")}}}
		_report_ai(c, Time.get_ticks_msec())
		return
	if Time.get_ticks_msec() - c.ai_started > 600000 or gs.turn_number > 240 or c.ai_actions >= 1000:
		_ai_failed(c)
		return
	var actor := gs.active_player_id
	if not gs.mulligan_pending.is_empty():
		actor = str(gs.mulligan_pending.keys()[0])
	elif gs.has_pending_choice():
		actor = str(gs.pending_choice["player_id"])
	var profile := c.profile if actor == "host" else {"id": "standard", "level": c.ai_level, "style": ""}
	var deck := c.deck if actor == "host" else c.ai_deck
	var epoch := c.epoch
	c.thinking = true
	var command := await Bots.choose_view_action(gs.to_net_dict(actor), actor, deck, profile)
	c.thinking = false
	if c.epoch != epoch or c.stage != "ai_playing":
		return
	command["actor"] = actor
	if command.size() == 1 or not gs.execute(command)["ok"]:
		_ai_failed(c)
		return
	gs.drain_events()
	c.ai_actions += 1
	c.due = Time.get_ticks_msec() + ACTION_PAUSE_MS

func _ai_failed(c: BotConnection) -> void:
	_send(c, {"type": "ranked_bot_ai_cancel", "match_id": c.ai_match_id})
	print("RANKED_BOT_EVENT " + JSON.stringify({"event": "ai_failed", "bot": c.profile["id"]}))
	_clear_ai(c)
	_finished(c, Time.get_ticks_msec())

func _queue(c: BotConnection) -> void:
	c.stage = "queued"
	_send(c, {"type": "queue_ranked", "deck_name": DECK_NAME, "rules_version": RulesVersion.RULES_VERSION})
	print("RANKED_BOT_EVENT " + JSON.stringify({"event": "queued", "bot": c.profile["id"]}))

func _finished(c: BotConnection, now: int) -> void:
	c.match_id = ""
	c.epoch += 1
	c.client_seq = 0
	c.awaiting = false
	c.view = {}
	c.faction = (c.faction + 1) % 5
	c.stage = "pause"
	c.due = now + 5000

func _think(c: BotConnection) -> void:
	if c.view.is_empty() or int(c.view.get("phase", 0)) == GameState.Phase.GAME_OVER:
		return
	var mulligan: Dictionary = c.view.get("mulligan_pending", {})
	if not mulligan.has(c.my_id):
		if not mulligan.is_empty() or str(c.clock.get("responsible", c.seat)) != c.seat:
			return
		var choice: Dictionary = c.view.get("pending_choice", {})
		if choice.is_empty() and str(c.view.get("active_player_id", "")) != c.my_id:
			return
	var epoch := c.epoch
	var seq := c.seq
	c.thinking = true
	var command := await Bots.choose_view_action(c.view, c.my_id, c.deck, c.profile)
	c.thinking = false
	if c.epoch != epoch or c.seq != seq or c.stage != "playing" or c.awaiting:
		return
	if command.is_empty():
		return
	c.client_seq += 1
	c.awaiting = true
	c.deadline = Time.get_ticks_msec() + RESPONSE_TIMEOUT_MS
	c.due = Time.get_ticks_msec() + ACTION_PAUSE_MS
	_send(c, {"type": "match_command", "match_id": c.match_id, "client_seq": c.client_seq, "cmd": command})
