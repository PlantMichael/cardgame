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

var _saved_token: String = ""

func _ready() -> void:
	Net.register_result.connect(_on_register_result)
	Net.login_result.connect(_on_login_result)
	_load_saved_session()

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
	is_logged_in = true
	_saved_token = token
	_save_session()

func _clear_session() -> void:
	token = ""
	username = ""
	wins = 0
	losses = 0
	rating = 0
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
