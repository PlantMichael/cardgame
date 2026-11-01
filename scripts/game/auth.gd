extends Node

const SAVE_DIR := "user://"
const SESSION_FILE := "session.json"
const LS_KEY := "cardgame_session"
const PENDING_FILE := "pending_ranked.json"
const PENDING_LS_KEY := "cardgame_pending_ranked"
## How long a sent ranked report may go unanswered before it is sent again.
const REPORT_RETRY_MSEC := 6000

signal login_result(success: bool, message: String)
signal register_result(success: bool, message: String)
signal logged_out
## The website page handed this embedded game a session token to resume as.
signal site_session_received

## The browser build inside the website: the page owns sign-in, the session and
## the profile, so this build neither reads nor writes the saved session.
const SiteBridgeScript := preload("res://scripts/game/site_bridge.gd")
var _site_bridge: Node

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

## Custom decks tied to this account (see DeckManager, which is the actual
## read/write API callers use — this array is just where it stores the
## logged-in-user's copy). Each entry: {name, faction_idx, card_ids,
## is_starter}. Populated on login/register/resume, kept in sync locally by
## DeckManager.save_deck/delete_deck (optimistic — the server call happens
## in the background via save_deck()/delete_deck() below).
var custom_decks: Array[Dictionary] = []

## Filename (not a full path) of the chosen profile picture under
## res://assets/pfps/, e.g. "warrior.png" - empty means no selection yet
## (main.gd falls back to a generated placeholder). Synced to the account
## server-side the same way custom_decks is: optimistic local update here,
## background Net call, diagnostic-only result handling below.
var selected_pfp: String = ""

var _saved_token: String = ""

## Ranked results the server has not acknowledged yet, oldest first. A report
## sent while the socket was down (a relay redeploy, a dropped connection) used
## to be lost, which both left the game-over screen on "Updating rank..." and
## never moved the ladder. They are kept - on disk too - and re-sent until the
## server answers; the server settles each match id once, so a repeat is safe.
var _pending_ranked: Array = []
var _report_sent_at_msec: int = -1
var _retry_timer: Timer

func _ready() -> void:
	Net.register_result.connect(_on_register_result)
	Net.login_result.connect(_on_login_result)
	Net.ranked_result_received.connect(_on_ranked_result_received)
	_site_bridge = SiteBridgeScript.new()
	add_child(_site_bridge)
	_site_bridge.session_received.connect(_on_site_session)
	_site_bridge.account_changed.connect(func(pfp_id: String) -> void: selected_pfp = pfp_id)
	Net.ranked_report_acked.connect(_on_ranked_report_acked)
	Net.ranked_report_failed.connect(_on_ranked_report_failed)
	Net.connected_to_server.connect(_flush_pending_ranked)
	_retry_timer = Timer.new()
	_retry_timer.wait_time = 2.0
	_retry_timer.timeout.connect(_flush_pending_ranked)
	add_child(_retry_timer)
	_retry_timer.start()
	_load_pending_ranked()
	Net.save_deck_result.connect(_on_deck_sync_result.bind("save"))
	Net.delete_deck_result.connect(_on_deck_sync_result.bind("delete"))
	Net.set_pfp_result.connect(_on_pfp_sync_result)
	_load_saved_session()

func save_deck(deck_name: String, faction_idx: int, card_ids: Array) -> void:
	Net.save_deck(token, deck_name, faction_idx, card_ids)

func delete_deck(deck_name: String) -> void:
	Net.delete_deck(token, deck_name)

func set_pfp(pfp_id: String) -> void:
	selected_pfp = pfp_id
	Net.set_pfp(token, pfp_id)

## DeckManager already applies save/delete to custom_decks optimistically,
## so this is just a diagnostic backstop for when the server-side write
## actually failed (e.g. session expired) — the local cache and account can
## silently diverge until the next login/resume re-syncs it from the server.
func _on_deck_sync_result(success: bool, message: String, deck_name: String, action: String) -> void:
	if not success:
		push_warning("Deck %s failed to sync for '%s': %s" % [action, deck_name, message])

func _on_pfp_sync_result(success: bool, message: String, _pfp_id: String) -> void:
	if not success:
		push_warning("Profile picture failed to sync: %s" % message)

## `opponent_rating` should only be passed for a matchmade PvP result (the
## opponent's rating at match-found time, from Net.ranked_match_found) so the
## server can move this player's matchmaking Elo; omit it for AI matches.
func report_ranked_result(won: bool, opponent_rating: int = -1, match_id: String = "",
						  ai_match: Dictionary = {}) -> void:
	_pending_ranked.append({
		"username": username, "won": won, "opponent_rating": opponent_rating,
		"match_id": match_id, "ai_match": ai_match,
	})
	_save_pending_ranked()
	_flush_pending_ranked()

## Sends the oldest unacknowledged report for the signed-in account, and sends
## it again if the server has been silent for REPORT_RETRY_MSEC.
func _flush_pending_ranked() -> void:
	if _pending_ranked.is_empty() or not is_logged_in or token.is_empty() or not Net.is_open():
		return
	var report: Dictionary = _pending_ranked[0]
	if str(report.get("username", "")) != username:
		return
	var now := Time.get_ticks_msec()
	if _report_sent_at_msec >= 0 and now - _report_sent_at_msec < REPORT_RETRY_MSEC:
		return
	if Net.report_ranked_result(token, bool(report["won"]), int(report["opponent_rating"]),
			str(report["match_id"]), report["ai_match"]):
		_report_sent_at_msec = now

func _on_ranked_report_acked() -> void:
	_finish_head_report()

## A refusal that retrying cannot fix is dropped so it cannot block the queue;
## an expired session or a server hiccup is kept and retried.
func _on_ranked_report_failed(message: String) -> void:
	if Net.RETRYABLE_REPORT_FAILURES.has(message):
		_report_sent_at_msec = -1
		return
	push_warning("Ranked result was refused and dropped: %s" % message)
	_finish_head_report()

func _finish_head_report() -> void:
	if _pending_ranked.is_empty():
		return
	_pending_ranked.remove_at(0)
	_report_sent_at_msec = -1
	_save_pending_ranked()
	_flush_pending_ranked()

func _save_pending_ranked() -> void:
	var json_str := JSON.stringify(_pending_ranked)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("localStorage.setItem(%s, %s)" % [JSON.stringify(PENDING_LS_KEY), JSON.stringify(json_str)])
	else:
		var file := FileAccess.open(SAVE_DIR + PENDING_FILE, FileAccess.WRITE)
		if file:
			file.store_string(json_str)
			file.close()

func _load_pending_ranked() -> void:
	var json_str := ""
	if OS.has_feature("web"):
		var result = JavaScriptBridge.eval("localStorage.getItem(%s)" % JSON.stringify(PENDING_LS_KEY))
		if result == null:
			return
		json_str = str(result)
	elif FileAccess.file_exists(SAVE_DIR + PENDING_FILE):
		var file := FileAccess.open(SAVE_DIR + PENDING_FILE, FileAccess.READ)
		if file:
			json_str = file.get_as_text()
			file.close()
	if json_str.strip_edges().is_empty():
		return
	var parsed = JSON.parse_string(json_str)
	if parsed is Array:
		for entry in parsed:
			if entry is Dictionary and entry.has("won") and entry.has("match_id"):
				_pending_ranked.append(entry)

func queue_ranked(deck_name: String = "") -> void:
	Net.queue_ranked(token, deck_name, RulesVersion.RULES_VERSION)

func cancel_ranked_queue() -> void:
	Net.cancel_ranked_queue(token)

func queue_campaign(size: int) -> void:
	Net.queue_campaign(token, size)

func cancel_campaign_queue() -> void:
	Net.cancel_campaign_queue(token)

func _on_ranked_result_received(success: bool, profile: Dictionary) -> void:
	if not success:
		return
	notify_site_account_dirty()
	rating = int(profile.get("rating", rating))
	rank_bracket = int(profile.get("rank_bracket", rank_bracket))
	rank_in_legend = bool(profile.get("rank_in_legend", rank_in_legend))
	rank_legend_rating = int(profile.get("rank_legend_rating", rank_legend_rating))
	rank_lp = int(profile.get("rank_lp", rank_lp))
	ranked_win_streak = int(profile.get("ranked_win_streak", ranked_win_streak))
	ranked_wins = int(profile.get("ranked_wins", ranked_wins))
	ranked_losses = int(profile.get("ranked_losses", ranked_losses))

func is_embedded() -> bool:
	return _site_bridge != null and _site_bridge.embedded

## Asks the website page for the session again (after a missed first request).
func request_site_session() -> void:
	if _site_bridge != null:
		_site_bridge.announce_ready()

## Tells the page its token no longer works so it can show its own sign-in.
func report_site_session_invalid() -> void:
	if _site_bridge != null:
		_site_bridge.notify_session_invalid()

## Balances or rank changed in the game: the page re-reads them from the server.
## A hint only; the page never takes values from the game.
func notify_site_account_dirty() -> void:
	if _site_bridge != null:
		_site_bridge.notify_account_dirty()

func _on_site_session(site_token: String) -> void:
	if site_token.is_empty():
		return
	# A different account arriving mid-session is the page's job to handle by
	# replacing this whole game; never swap identity under a running match.
	if is_logged_in and site_token != token:
		return
	_saved_token = site_token
	site_session_received.emit()

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
	selected_pfp = str(profile.get("pfp_id", ""))
	custom_decks.clear()
	for d in profile.get("decks", []):
		custom_decks.append(d)
	is_logged_in = true
	_saved_token = token
	_save_session()

func _clear_session() -> void:
	if is_embedded():
		# The page owns the stored session; the game only forgets its own copy.
		token = ""
		username = ""
		is_logged_in = false
		_saved_token = ""
		custom_decks.clear()
		return
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
	selected_pfp = ""
	custom_decks.clear()
	is_logged_in = false
	_saved_token = ""
	if OS.has_feature("web"):
		JavaScriptBridge.eval("localStorage.removeItem(%s)" % JSON.stringify(LS_KEY))
	else:
		if FileAccess.file_exists(SAVE_DIR + SESSION_FILE):
			DirAccess.remove_absolute(SAVE_DIR + SESSION_FILE)

func _save_session() -> void:
	if is_embedded():
		return
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
	if is_embedded():
		return
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
