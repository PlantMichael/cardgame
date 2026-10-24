class_name MatchHost
extends Node

## The headless rules host for server-run matches (spec 003).
##
##   godot --headless --path <project> -- --match-host --port=<n>
##
## It listens on 127.0.0.1 only, speaks newline-delimited JSON, and holds many
## GameState instances keyed by match id. It performs no network or database
## access beyond this one socket and reads no wall-clock time inside rules: the
## relay (Node) owns accounts, sessions, clocks and persistence; this process
## only decides what the rules allow. See specs/003-authoritative-ranked-server/
## contracts/match-host-ipc.md.
##
## Identity is the relay's job: this process never sees usernames or tokens,
## only the two seats "a" and "b". Internally the two players are the existing
## "host"/"guest" ids so GameState.to_net_dict() can build per-seat views.

const HOST_ID := "host"
const GUEST_ID := "guest"
const MAX_MATCHES := 1000
const MAX_FRAME_BYTES := 262144

## Commands a seat may submit. Anything else is refused before it reaches the rules.
const ALLOWED_COMMANDS := [
	GameState.CMD_PLAY_CREATURE, GameState.CMD_PLAY_STRATAGEM, GameState.CMD_ATTACK,
	GameState.CMD_PILOT, GameState.CMD_END_TURN, GameState.CMD_ANSWER_CHOICE,
	GameState.CMD_CONCEDE, GameState.CMD_MULLIGAN,
]

class Client:
	var peer: StreamPeerTCP
	var buffer: String = ""
	var authed: bool = false

var _server := TCPServer.new()
var _clients: Array[Client] = []
var _matches: Dictionary = {}
var _secret: String = ""
var _started_msec: int = 0
var _last_error: String = ""

func start(port: int, secret: String) -> bool:
	_secret = secret
	_started_msec = Time.get_ticks_msec()
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		push_error("match host could not listen on %d (error %d)" % [port, err])
		return false
	print("MATCH_HOST_READY port=%d" % port)
	return true

func _process(_delta: float) -> void:
	while _server.is_connection_available():
		var c := Client.new()
		c.peer = _server.take_connection()
		_clients.append(c)
	for c in _clients.duplicate():
		c.peer.poll()
		if c.peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_clients.erase(c)
			continue
		var available: int = c.peer.get_available_bytes()
		if available > 0:
			c.buffer += c.peer.get_utf8_string(available)
		if c.buffer.length() > MAX_FRAME_BYTES and c.buffer.find("\n") < 0:
			_drop_client(c)
			continue
		var newline: int = c.buffer.find("\n")
		while newline >= 0:
			var line: String = c.buffer.substr(0, newline)
			c.buffer = c.buffer.substr(newline + 1)
			if not line.strip_edges().is_empty():
				_handle_frame(c, line)
			if c not in _clients:
				break
			newline = c.buffer.find("\n")

func _drop_client(c: Client) -> void:
	c.peer.disconnect_from_host()
	_clients.erase(c)

func _reply(c: Client, rid, body: Dictionary) -> void:
	body["rid"] = rid
	c.peer.put_data((JSON.stringify(body) + "\n").to_utf8_buffer())

func _handle_frame(c: Client, line: String) -> void:
	var msg = JSON.parse_string(line)
	if typeof(msg) != TYPE_DICTIONARY:
		_drop_client(c)
		return
	var rid = msg.get("rid", 0)
	var op := str(msg.get("op", ""))
	if not c.authed:
		# The only thing an unauthenticated connection may do is say hello.
		if op != "hello" or str(msg.get("secret", "")) != _secret or _secret.is_empty():
			_drop_client(c)
			return
		c.authed = true
		_reply(c, rid, {"ok": true, "rules_version": RulesVersion.RULES_VERSION, "capacity": MAX_MATCHES})
		return
	match op:
		"hello":
			_reply(c, rid, {"ok": true, "rules_version": RulesVersion.RULES_VERSION, "capacity": MAX_MATCHES})
		"create":
			_reply(c, rid, _op_create(msg))
		"command":
			_reply(c, rid, _op_command(msg))
		"timeout":
			_reply(c, rid, _op_timeout(msg))
		"view":
			_reply(c, rid, _op_view(msg))
		"replay":
			_reply(c, rid, _op_replay(msg))
		"drop":
			_matches.erase(str(msg.get("match_id", "")))
			_reply(c, rid, {"ok": true})
		"stats":
			_reply(c, rid, {"ok": true, "live_matches": _matches.size(),
				"uptime_s": (Time.get_ticks_msec() - _started_msec) / 1000, "last_error": _last_error})
		_:
			_reply(c, rid, {"ok": false, "error": "unknown_op"})

# --- seat helpers -------------------------------------------------------------

static func _internal(seat: String) -> String:
	return HOST_ID if seat == "a" else GUEST_ID

static func _seat_of(internal_id: String) -> String:
	return "a" if internal_id == HOST_ID else "b"

static func _deck_from_ids(ids: Array) -> Array[CardData]:
	var out: Array[CardData] = []
	for cid in ids:
		var card := CardDatabase.get_card(str(cid))
		if card == null or card.is_token:
			return [] as Array[CardData]
		out.append(card)
	return out

# --- ops ---------------------------------------------------------------------

func _build_match(msg: Dictionary) -> Dictionary:
	if int(msg.get("rules_version", -1)) != RulesVersion.RULES_VERSION:
		return {"ok": false, "error": "rules_version_mismatch"}
	var deck_a := _deck_from_ids(msg.get("deck_a", []))
	var deck_b := _deck_from_ids(msg.get("deck_b", []))
	if deck_a.is_empty() or deck_b.is_empty():
		return {"ok": false, "error": "invalid_deck"}
	var first := str(msg.get("first_seat", ""))
	if first != "a" and first != "b":
		return {"ok": false, "error": "invalid_first_seat"}
	var gs := GameState.new(HOST_ID, GUEST_ID, deck_a, deck_b, int(msg.get("seed", 0)))
	gs.set_events_enabled(true)
	gs.start_game(_internal(first))
	gs.begin_mulligan()
	gs.drain_events()  # the opening deal is shown through each seat's view
	return {"ok": true, "gs": gs}

func _op_create(msg: Dictionary) -> Dictionary:
	var match_id := str(msg.get("match_id", ""))
	if match_id.is_empty() or _matches.has(match_id):
		return {"ok": false, "error": "invalid_match_id"}
	if _matches.size() >= MAX_MATCHES:
		return {"ok": false, "error": "at_capacity"}
	var built := _build_match(msg)
	if not built["ok"]:
		return built
	var gs: GameState = built["gs"]
	_matches[match_id] = {"gs": gs, "seq": 0}
	return _snapshot(match_id, "create", [])

func _op_view(msg: Dictionary) -> Dictionary:
	var match_id := str(msg.get("match_id", ""))
	if not _matches.has(match_id):
		return {"ok": false, "error": "unknown_match"}
	var seat := str(msg.get("seat", ""))
	if seat != "a" and seat != "b":
		return {"ok": false, "error": "invalid_seat"}
	var m: Dictionary = _matches[match_id]
	var gs: GameState = m["gs"]
	return {"ok": true, "seq": m["seq"], "state_hash": gs.state_hash(),
		"view": gs.to_net_dict(_internal(seat))}

func _op_command(msg: Dictionary) -> Dictionary:
	var match_id := str(msg.get("match_id", ""))
	if not _matches.has(match_id):
		return {"ok": false, "error": "unknown_match"}
	var seat := str(msg.get("seat", ""))
	if seat != "a" and seat != "b":
		return {"ok": false, "error": "invalid_seat"}
	var m: Dictionary = _matches[match_id]
	if msg.has("expect_seq") and int(msg["expect_seq"]) != int(m["seq"]):
		return {"ok": false, "error": "stale_seq"}
	var raw = msg.get("cmd", {})
	if typeof(raw) != TYPE_DICTIONARY or str(raw.get("type", "")) not in ALLOWED_COMMANDS:
		return {"ok": false, "error": "unknown_command"}
	# The seat is the relay's word, never the command's: whatever "actor" the
	# command claims is replaced by the seat that submitted it.
	var cmd: Dictionary = (raw as Dictionary).duplicate(true)
	cmd["actor"] = _internal(seat)
	var gs: GameState = m["gs"]
	var result := gs.execute(cmd)
	if not result["ok"]:
		return {"ok": false, "error": str(result.get("error", "refused"))}
	m["seq"] = int(m["seq"]) + 1
	return _snapshot(match_id, "command", result["events"])

func _op_timeout(msg: Dictionary) -> Dictionary:
	var match_id := str(msg.get("match_id", ""))
	if not _matches.has(match_id):
		return {"ok": false, "error": "unknown_match"}
	var seat := str(msg.get("seat", ""))
	if seat != "a" and seat != "b":
		return {"ok": false, "error": "invalid_seat"}
	var m: Dictionary = _matches[match_id]
	var gs: GameState = m["gs"]
	var internal := _internal(seat)
	var events: Array = []
	if gs.mulligan_pending.get(internal, false):
		# A player who never mulligans simply keeps their hand.
		var r := gs.execute({"type": GameState.CMD_MULLIGAN, "actor": internal, "card_uids": []})
		events = r.get("events", [])
	else:
		var r := gs.apply_timeout(internal)
		if not r["ok"]:
			return {"ok": false, "error": str(r.get("error", "refused"))}
		events = r["events"]
	m["seq"] = int(m["seq"]) + 1
	var snap := _snapshot(match_id, "timeout_default", events)
	return snap

func _op_replay(msg: Dictionary) -> Dictionary:
	var match_id := str(msg.get("match_id", ""))
	if match_id.is_empty():
		return {"ok": false, "error": "invalid_match_id"}
	var built := _build_match(msg)
	if not built["ok"]:
		return built
	var gs: GameState = built["gs"]
	var hashes: Array = []
	var index := 0
	for action in msg.get("actions", []):
		var seat := str(action.get("seat", ""))
		var kind := str(action.get("kind", "command"))
		var internal := _internal(seat)
		if kind == "timeout_default":
			if gs.mulligan_pending.get(internal, false):
				gs.execute({"type": GameState.CMD_MULLIGAN, "actor": internal, "card_uids": []})
			else:
				gs.apply_timeout(internal)
		else:
			var cmd: Dictionary = (action.get("cmd", {}) as Dictionary).duplicate(true)
			cmd["actor"] = internal
			var r := gs.execute(cmd)
			if not r["ok"]:
				return {"ok": false, "error": "replay_refused", "at": index, "detail": str(r.get("error", ""))}
		index += 1
		if bool(msg.get("step_hashes", false)):
			hashes.append(gs.state_hash())
	_matches[match_id] = {"gs": gs, "seq": index}
	var out := {"ok": true, "seq": index, "state_hash": gs.state_hash(), "step_hashes": hashes}
	if gs.current_phase == GameState.Phase.GAME_OVER:
		out["over"] = _over_block(gs)
	return out

# --- replies -----------------------------------------------------------------

static func _over_block(gs: GameState) -> Dictionary:
	return {"winner": _seat_of(gs.winner_id) if not gs.winner_id.is_empty() else "",
		"reason": gs.end_reason if not gs.end_reason.is_empty() else "completed"}

## The reply shape shared by create / command / timeout: a view and a filtered
## event list per seat, the new sequence number and the state hash.
func _snapshot(match_id: String, kind: String, events: Array) -> Dictionary:
	var m: Dictionary = _matches[match_id]
	var gs: GameState = m["gs"]
	# Draws announced to the local player's UI are an in-process convenience;
	# nothing here displays them, and they must not accumulate.
	gs.pending_drawn_cards.clear()
	var out := {
		"ok": true, "kind": kind, "seq": m["seq"], "state_hash": gs.state_hash(),
		"views": {"a": gs.to_net_dict(HOST_ID), "b": gs.to_net_dict(GUEST_ID)},
		"events": {"a": GameState.filter_events_for(HOST_ID, events), "b": GameState.filter_events_for(GUEST_ID, events)},
	}
	if gs.current_phase == GameState.Phase.GAME_OVER:
		out["over"] = _over_block(gs)
	return out
