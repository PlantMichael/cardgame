extends Node

const SAVE_DIR := "user://"
const SESSION_FILE := "session.json"
const LS_KEY := "cardgame_session"

signal login_result(success: bool, message: String)
signal register_result(success: bool, message: String)
signal logged_out

var token: String = ""
var username: String = ""
var wins: int = 0
var losses: int = 0
var rating: int = 0
var is_logged_in: bool = false

## Ranked ladder state, tied to the account and authoritative on the server
## (see RankedProgress for the display/AI-level math over these). Moved by
## both AI and matchmade PvP ranked results alike — `rating` above is the
## separate, invisible Elo matchmaking uses to pair PvP opponents.
var rank_bracket: int = 0
var rank_in_legend: bool = false
var rank_legend_rating: int = 0
var rank_lp: int = 0
var ranked_win_streak: int = 0
var ranked_wins: int = 0
var ranked_losses: int = 0

var _saved_token: String = ""

func _ready() -> void:
	Net.register_result.connect(_on_register_result)
	Net.login_result.connect(_on_login_result)
	Net.ranked_result_received.connect(_on_ranked_result_received)
	_load_saved_session()

## `opponent_rating` should only be passed for a matchmade PvP result (the
## opponent's rating at match-found time, from Net.ranked_match_found) so the
## server can move this player's matchmaking Elo; omit it for AI matches.
func report_ranked_result(won: bool, opponent_rating: int = -1) -> void:
	Net.report_ranked_result(token, won, opponent_rating)

func queue_ranked() -> void:
	Net.queue_ranked(token)

func cancel_ranked_queue() -> void:
	Net.cancel_ranked_queue(token)

func _on_ranked_result_received(success: bool, profile: Dictionary) -> void:
	if not success:
		return
	rating = int(profile.get("rating", rating))
	rank_bracket = int(profile.get("rank_bracket", rank_bracket))
	rank_in_legend = bool(profile.get("rank_in_legend", rank_in_legend))
	rank_legend_rating = int(profile.get("rank_legend_rating", rank_legend_rating))
	rank_lp = int(profile.get("rank_lp", rank_lp))
	ranked_win_streak = int(profile.get("ranked_win_streak", ranked_win_streak))
	ranked_wins = int(profile.get("ranked_wins", ranked_wins))
	ranked_losses = int(profile.get("ranked_losses", ranked_losses))

func has_saved_session() -> bool:
	return not _saved_token.is_empty()

func register(uname: String, password: String) -> void:
	Net.register(uname, password)

func login(uname: String, password: String) -> void:
	Net.login(uname, password)

func try_resume_session() -> void:
	Net.resume_session(_saved_token)

func logout() -> void:
	Net.logout(token)
	_clear_session()
	logged_out.emit()

func _on_register_result(success: bool, message: String, profile: Dictionary) -> void:
	if success:
		_apply_profile(profile)
	register_result.emit(success, message)

func _on_login_result(success: bool, message: String, profile: Dictionary) -> void:
	if success:
		_apply_profile(profile)
	login_result.emit(success, message)

func _apply_profile(profile: Dictionary) -> void:
	token = str(profile.get("token", ""))
	username = str(profile.get("username", ""))
	wins = int(profile.get("wins", 0))
	losses = int(profile.get("losses", 0))
	rating = int(profile.get("rating", 0))
	rank_bracket = int(profile.get("rank_bracket", 0))
	rank_in_legend = bool(profile.get("rank_in_legend", false))
	rank_legend_rating = int(profile.get("rank_legend_rating", 0))
	rank_lp = int(profile.get("rank_lp", 0))
	ranked_win_streak = int(profile.get("ranked_win_streak", 0))
	ranked_wins = int(profile.get("ranked_wins", 0))
	ranked_losses = int(profile.get("ranked_losses", 0))
	is_logged_in = true
	_saved_token = token
	_save_session()

func _clear_session() -> void:
	token = ""
	username = ""
	wins = 0
	losses = 0
	rating = 0
	rank_bracket = 0
	rank_in_legend = false
	rank_legend_rating = 0
	rank_lp = 0
	ranked_win_streak = 0
	ranked_wins = 0
	ranked_losses = 0
	is_logged_in = false
	_saved_token = ""
	if OS.has_feature("web"):
		JavaScriptBridge.eval("localStorage.removeItem(%s)" % JSON.stringify(LS_KEY))
	else:
		if FileAccess.file_exists(SAVE_DIR + SESSION_FILE):
			DirAccess.remove_absolute(SAVE_DIR + SESSION_FILE)

func _save_session() -> void:
	var data := {"token": token, "username": username}
	var json_str := JSON.stringify(data)
	if OS.has_feature("web"):
		var key := JSON.stringify(LS_KEY)
		var val := JSON.stringify(json_str)
		JavaScriptBridge.eval("localStorage.setItem(%s, %s)" % [key, val])
	else:
		var file := FileAccess.open(SAVE_DIR + SESSION_FILE, FileAccess.WRITE)
		if file:
			file.store_string(json_str)
			file.close()

func _load_saved_session() -> void:
	var json_str := ""
	if OS.has_feature("web"):
		var result = JavaScriptBridge.eval("localStorage.getItem(%s)" % JSON.stringify(LS_KEY))
		if result == null:
			return
		json_str = str(result)
	else:
		if not FileAccess.file_exists(SAVE_DIR + SESSION_FILE):
			return
		var file := FileAccess.open(SAVE_DIR + SESSION_FILE, FileAccess.READ)
		if not file:
			return
		json_str = file.get_as_text()
		file.close()
	var parsed = JSON.parse_string(json_str)
	if parsed is Dictionary:
		_saved_token = str(parsed.get("token", ""))
