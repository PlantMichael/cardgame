extends Node

const BoardScene = preload("res://scenes/game/Board.tscn")
const DeckBuilderScene = preload("res://scenes/ui/DeckBuilderScreen.tscn")
const WallpaperTexture = preload("res://assets/wallapepr.png")

var _canvas: CanvasLayer
var _player_deck_ids: Array[String] = []
var _opponent_deck_ids: Array[String] = []

# Simulation state
var _sim_running: bool = false
var _sim_runner: SimRunner = null
var _sim_deck_mode: SimRunner.DeckMode = SimRunner.DeckMode.RANDOM
var _sim_ai_level: int = 5  # Medium by default — level 10 on both sides is much slower
var _sim_stat_labels: Dictionary = {}
var _sim_totals_lbl: Label = null
var _sim_status_lbl: Label = null
var _sim_game_start_ms: int = 0
var _sim_gps_count: int = 0
var _sim_gps_display: float = 0.0
var _sim_card_grid: GridContainer = null

# Multiplayer state
var _mp_name: String = ""
var _mp_lobby_id: String = ""
var _mp_is_host: bool = false
var _mp_player_deck_ids: Array[String] = []
var _mp_guest_deck_ids: Array[String] = []
var _mp_manager: MpGameManager = null

# Ranked matchmaking state
const RANKED_SEARCH_TIMEOUT_SEC := 10.0
const RANKED_MATCH_CONFIRM_SEC := 1.5
# Bumped on every begin/cancel/resolve so a stale timer or match-found signal
# left over from a cancelled or already-resolved search (e.g. Cancel then
# immediately Start again) can tell it's no longer current and no-op instead
# of hijacking whatever search is active now.
var _ranked_search_id: int = 0
var _ranked_match_found_callable: Callable = Callable()

func _ready() -> void:
	if "--mcts-timing" in OS.get_cmdline_user_args():
		_run_mcts_timing_cli()
		return
	if "--mcts-benchmark" in OS.get_cmdline_user_args():
		_run_mcts_benchmark_cli()
		return
	if "--fatigue-test" in OS.get_cmdline_user_args():
		_run_fatigue_test_cli()
		return
	if "--haven-test" in OS.get_cmdline_user_args():
		_run_haven_test_cli()
		return
	if "--sim-test" in OS.get_cmdline_user_args():
		_run_sim_test_cli()
		return

	_canvas = CanvasLayer.new()
	add_child(_canvas)

	var bg := TextureRect.new()
	bg.texture = WallpaperTexture
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(bg)

	Net.opponent_left.connect(_on_opponent_left)
	if OS.has_feature("editor"):
		# Skip the login gate when run from the Godot editor (playtesting) —
		# "editor" is only ever true for an editor-launched debug run, never
		# for an exported build (web or otherwise), so this can't ship live.
		_show_main_menu()
	else:
		_require_login_then(_show_main_menu, false)

func _clear_screen() -> void:
	for i in range(_canvas.get_child_count() - 1, 0, -1):
		_canvas.get_child(i).queue_free()

## Dev-only headless verification hook: run via
##   godot --headless --path <project> -- --mcts-benchmark
## Bypasses the UI entirely (skipped autoloads aren't available in bare
## --script mode, so this runs through the real project instead) and prints
## win rates so MCTSEngine level tuning can be checked without manual play.
## Dev-only timing probe: godot --headless --path <project> -- --mcts-timing
## Measures wall-clock ms per choose_action() call at each level on a
## realistic mid-game board, to catch a level being too slow before it's
## ever played against.
func _run_mcts_timing_cli() -> void:
	var deck_a := DeckManager.build_random_faction_deck(CardData.CardColor.CRIMSON)
	var deck_b := DeckManager.build_random_faction_deck(CardData.CardColor.TEAL)
	var gs := GameState.new("sim_a", "sim_b", deck_a, deck_b)
	gs.start_game("sim_a")
	HeadlessTurn._resolve_pending(gs)
	# Play a few greedy turns each side first so the board isn't the empty
	# opening state (a mid-game board has more legal actions to search).
	for _t in 6:
		HeadlessTurn.play_full_turn_greedy(gs, gs.active_player_id)
		if gs.current_phase == GameState.Phase.GAME_OVER:
			break

	for level in [1, 3, 5, 7, 10]:
		var engine := MCTSEngine.new("sim_a", level)
		var start_ms := Time.get_ticks_msec()
		var action := await engine.choose_action(gs)
		var elapsed := Time.get_ticks_msec() - start_ms
		print("Level %d: %d ms, chose %s" % [level, elapsed, action["type"]])
	get_tree().quit()

## Dev-only smoke test for SimRunner's MCTS-level-10-both-sides turn driver:
##   godot --headless --path <project> -- --sim-test
func _run_sim_test_cli() -> void:
	print("Running 1 SimRunner game per deck mode (both sides MCTS level 10)...")
	for mode in [SimRunner.DeckMode.RANDOM, SimRunner.DeckMode.ARCHETYPE]:
		var start_ms := Time.get_ticks_msec()
		var runner := SimRunner.new(mode)
		await runner.run_batch(1)
		var elapsed := Time.get_ticks_msec() - start_ms
		print("[%s] done in %d ms. total_games=%d stats=%s" % [
			SimRunner.DeckMode.keys()[mode], elapsed, runner.total_games, runner.stats])
	get_tree().quit()

## Dev-only one-shot check of the fatigue math (both players start with an
## empty deck, so every draw fatigues immediately): godot --headless --path
## <project> -- --fatigue-test
func _run_fatigue_test_cli() -> void:
	print("Testing fatigue with empty decks...")
	var gs := GameState.new("a", "b", [], [])
	gs.start_game("a")
	print("After opening hand: a.hp=%d a.fatigue=%d" % [gs.player.hero_health, gs.player.fatigue_damage])
	for i in 40:
		if gs.current_phase == GameState.Phase.GAME_OVER:
			print("GAME OVER after %d end_turns. winner=%s a.hp=%d b.hp=%d" % [
				i, gs.winner_id, gs.player.hero_health, gs.opponent.hero_health])
			break
		gs.end_turn()
		print("turn=%d active=%s a.hp=%d(fatigue=%d) b.hp=%d(fatigue=%d) phase=%d" % [
			gs.turn_number, gs.active_player_id, gs.player.hero_health, gs.player.fatigue_damage,
			gs.opponent.hero_health, gs.opponent.fatigue_damage, gs.current_phase])
	get_tree().quit()

## Dev-only check that health-threshold transform (Haven Guard -> Haven
## Warden at 4+ max health) fires even when a single effect jumps straight
## past the threshold instead of landing on it exactly (e.g. devour, which
## used to skip the check entirely): godot --headless --path <project> --
## --haven-test
func _run_haven_test_cli() -> void:
	print("Testing Haven Guard transform via a jump that skips over exactly 4...")
	var card := CardDatabase.get_card("cr_003")
	var gs := GameState.new("a", "b", [], [])
	var m := Minion.new(card, "a")
	gs.player.board.append(m)
	print("Before: name=%s max_health=%d" % [m.data.card_name, m.max_health])
	var fodder := Minion.new(card, "a")
	fodder.current_health = 5  # devour gain = 5*2 = 10, so max_health jumps 3 -> 13, skipping 4 entirely
	gs.player.board.append(fodder)
	gs.apply_devour_friendly(m, fodder, gs.player)
	var transformed := m.data.id != card.id
	print("After devour (3 -> 13, skipping 4): name=%s max_health=%d transformed=%s" % [
		m.data.card_name, m.max_health, transformed])
	print("RESULT: %s" % ("PASS" if transformed else "FAIL"))
	get_tree().quit()

func _run_mcts_benchmark_cli() -> void:
	print("Running MCTS benchmark...")
	var r1 := await MCTSBenchmark.run(6, MCTSBenchmark.mcts(3), MCTSBenchmark.mcts(1))
	print("Level 3 MCTS vs Level 1 MCTS (6 games): ", r1)
	var r2 := await MCTSBenchmark.run(6, MCTSBenchmark.mcts(5), MCTSBenchmark.mcts(1))
	print("Level 5 MCTS vs Level 1 MCTS (6 games): ", r2)
	get_tree().quit()

# ── Main menu ──────────────────────────────────────────────────────────

func _show_main_menu() -> void:
	var account_bar := HBoxContainer.new()
	account_bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	account_bar.position = Vector2(-220, 16)
	account_bar.add_theme_constant_override("separation", 10)
	_canvas.add_child(account_bar)

	var account_lbl := Label.new()
	account_lbl.text = "Logged in as %s" % Auth.username if Auth.is_logged_in else "Offline (Editor)"
	account_lbl.add_theme_font_size_override("font_size", 14)
	account_bar.add_child(_bg_cell(account_lbl))

	if Auth.is_logged_in:
		var logout_btn := Button.new()
		logout_btn.text = "Log Out"
		logout_btn.add_theme_font_size_override("font_size", 14)
		logout_btn.pressed.connect(func():
			Auth.logout()
			_clear_screen()
			_require_login_then(_show_main_menu, false)
		)
		account_bar.add_child(logout_btn)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "CARDGAME"
	title.add_theme_font_size_override("font_size", 60)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 28)
	vbox.add_child(gap)

	var mp_btn := _menu_btn("MULTIPLAYER")
	mp_btn.pressed.connect(_on_multiplayer_pressed)
	vbox.add_child(mp_btn)

	var play_btn := _menu_btn("VS AI")
	play_btn.pressed.connect(_on_play_pressed)
	vbox.add_child(play_btn)

	var ranked_btn := _menu_btn("RANKED")
	ranked_btn.pressed.connect(_on_ranked_pressed)
	vbox.add_child(ranked_btn)

	var build_btn := _menu_btn("DECK BUILDER")
	build_btn.pressed.connect(_on_deck_builder_pressed)
	vbox.add_child(build_btn)

	var sim_btn := _menu_btn("SIMULATION")
	sim_btn.pressed.connect(_on_simulation_pressed)
	vbox.add_child(sim_btn)

## Wraps a label in a translucent dark panel so it stays legible over the background art.
func _bg_cell(label: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.10, 0.78)
	style.set_corner_radius_all(4)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 1
	style.content_margin_bottom = 1
	panel.add_theme_stylebox_override("panel", style)
	panel.add_child(label)
	return panel

func _menu_btn(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(300, 72)
	btn.add_theme_font_size_override("font_size", 24)
	return btn

# ── Multiplayer ────────────────────────────────────────────────────────

func _on_multiplayer_pressed() -> void:
	_clear_screen()
	_require_login_then(func():
		_mp_name = Auth.username
		_with_connection(_show_lobby_browser)
	)

## Runs on_ready once Auth.is_logged_in is true, logging in first (silently
## resuming a saved session, or showing the login/register screen) if it
## isn't yet. allow_back controls whether the login screen offers a way back
## to the main menu — false at game startup, since it doesn't exist yet.
func _require_login_then(on_ready: Callable, allow_back: bool = true) -> void:
	if Auth.is_logged_in:
		on_ready.call()
		return
	if Auth.has_saved_session():
		_show_reconnecting_screen(on_ready, allow_back)
		return
	_show_auth_screen(false, on_ready, allow_back)

# Ensures the relay connection is open before running on_ready, connecting first if needed.
# If the connection doesn't open within CONNECT_TIMEOUT_SEC, on_timeout runs instead (if given).
const CONNECT_TIMEOUT_SEC := 8.0

func _with_connection(on_ready: Callable, on_timeout: Callable = Callable()) -> void:
	if Net._connected:
		on_ready.call()
		return
	var fired := false
	Net.connected_to_server.connect(func():
		fired = true
		on_ready.call()
	, CONNECT_ONE_SHOT)
	Net.connect_to_relay()
	if on_timeout.is_valid():
		get_tree().create_timer(CONNECT_TIMEOUT_SEC).timeout.connect(func():
			if not fired:
				on_timeout.call()
		)

func _show_reconnecting_screen(on_success: Callable, allow_back: bool = true) -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	center.add_child(vbox)

	var lbl := Label.new()
	lbl.text = "Reconnecting..."
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

	_with_connection(func():
		Auth.login_result.connect(func(success: bool, message: String):
			_on_resume_session_result(success, message, on_success, allow_back)
		, CONNECT_ONE_SHOT)
		Auth.try_resume_session()
	, func():
		lbl.text = "Couldn't reach the server. Check your connection and try again."
		var retry_btn := _menu_btn("RETRY")
		retry_btn.pressed.connect(func():
			_clear_screen()
			_show_reconnecting_screen(on_success, allow_back)
		)
		vbox.add_child(retry_btn)
	)

func _on_resume_session_result(success: bool, _message: String, on_success: Callable, allow_back: bool) -> void:
	_clear_screen()
	if success:
		_mp_name = Auth.username
		on_success.call()
	else:
		_show_auth_screen(false, on_success, allow_back)

func _show_auth_screen(is_register: bool, on_success: Callable, allow_back: bool = true) -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Create Account" if is_register else "Log In"
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var username_edit := LineEdit.new()
	username_edit.custom_minimum_size = Vector2(300, 48)
	username_edit.add_theme_font_size_override("font_size", 20)
	username_edit.placeholder_text = "Username"
	username_edit.text = _mp_name
	vbox.add_child(username_edit)

	var password_edit := LineEdit.new()
	password_edit.custom_minimum_size = Vector2(300, 48)
	password_edit.add_theme_font_size_override("font_size", 20)
	password_edit.placeholder_text = "Password"
	password_edit.secret = true
	vbox.add_child(password_edit)

	var status_lbl := Label.new()
	status_lbl.add_theme_font_size_override("font_size", 14)
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_lbl.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
	vbox.add_child(status_lbl)

	var submit_btn := _menu_btn("REGISTER" if is_register else "LOG IN")
	submit_btn.custom_minimum_size = Vector2(300, 56)
	vbox.add_child(submit_btn)

	var toggle_btn := Button.new()
	toggle_btn.text = "Already have an account? Log in" if is_register else "New here? Create an account"
	toggle_btn.add_theme_font_size_override("font_size", 14)
	vbox.add_child(toggle_btn)

	if allow_back:
		var back_btn := Button.new()
		back_btn.text = "Back"
		back_btn.custom_minimum_size = Vector2(300, 48)
		back_btn.add_theme_font_size_override("font_size", 18)
		vbox.add_child(back_btn)
		back_btn.pressed.connect(func():
			_clear_screen()
			_show_main_menu()
		)

	toggle_btn.pressed.connect(func():
		_mp_name = username_edit.text
		_clear_screen()
		_show_auth_screen(not is_register, on_success, allow_back)
	)

	submit_btn.pressed.connect(func():
		var uname := username_edit.text.strip_edges()
		var pw := password_edit.text
		if uname.is_empty() or pw.is_empty():
			status_lbl.text = "Enter a username and password."
			return
		submit_btn.disabled = true
		status_lbl.text = "Connecting..."
		_with_connection(func():
			status_lbl.text = "Registering..." if is_register else "Logging in..."
			var handler := func(success: bool, message: String):
				if success:
					_clear_screen()
					_mp_name = Auth.username
					on_success.call()
				else:
					submit_btn.disabled = false
					status_lbl.text = message
			if is_register:
				Auth.register_result.connect(handler, CONNECT_ONE_SHOT)
				Auth.register(uname, pw)
			else:
				Auth.login_result.connect(handler, CONNECT_ONE_SHOT)
				Auth.login(uname, pw)
		, func():
			submit_btn.disabled = false
			status_lbl.text = "Couldn't reach the server. Check your connection and try again."
		)
	)

func _show_lobby_browser() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	# Header
	var bar := _make_header_bar("Multiplayer Lobbies  —  " + Auth.username, func():
		_clear_screen()
		_show_main_menu()
	)
	root.add_child(bar)

	# Lobby list area
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	var lobby_vbox := VBoxContainer.new()
	lobby_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lobby_vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(lobby_vbox)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 20)
	lobby_vbox.add_child(margin)

	var list_container := VBoxContainer.new()
	list_container.add_theme_constant_override("separation", 10)
	margin.add_child(list_container)

	var status_lbl := Label.new()
	status_lbl.text = "Loading lobbies..."
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	list_container.add_child(status_lbl)

	# Bottom bar
	var bottom := HBoxContainer.new()
	bottom.custom_minimum_size = Vector2(0, 60)
	bottom.add_theme_constant_override("separation", 12)
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(bottom)

	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.custom_minimum_size = Vector2(160, 44)
	refresh_btn.add_theme_font_size_override("font_size", 18)
	bottom.add_child(refresh_btn)

	var host_btn := Button.new()
	host_btn.text = "Host Lobby"
	host_btn.custom_minimum_size = Vector2(180, 44)
	host_btn.add_theme_font_size_override("font_size", 18)
	bottom.add_child(host_btn)

	var logout_btn := Button.new()
	logout_btn.text = "Log Out"
	logout_btn.custom_minimum_size = Vector2(140, 44)
	logout_btn.add_theme_font_size_override("font_size", 18)
	bottom.add_child(logout_btn)
	logout_btn.pressed.connect(func():
		Auth.logout()
		_clear_screen()
		_show_main_menu()
	)

	var _populate_list = func(lobbies_data: Array):
		for c in list_container.get_children():
			c.queue_free()
		if lobbies_data.is_empty():
			var lbl := Label.new()
			lbl.text = "No open lobbies. Host one!"
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			list_container.add_child(lbl)
			return
		for lobby_info in lobbies_data:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 12)
			list_container.add_child(row)
			var name_lbl := Label.new()
			name_lbl.text = str(lobby_info.get("name", "Lobby"))
			name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			name_lbl.add_theme_font_size_override("font_size", 16)
			row.add_child(name_lbl)
			var host_lbl := Label.new()
			host_lbl.text = "Host: " + str(lobby_info.get("host_name", "?"))
			host_lbl.add_theme_font_size_override("font_size", 14)
			row.add_child(host_lbl)
			var join_btn := Button.new()
			join_btn.text = "Join"
			join_btn.custom_minimum_size = Vector2(80, 36)
			var lid: String = str(lobby_info.get("id", ""))
			join_btn.pressed.connect(func():
				Net.join_lobby(lid, _mp_name)
			)
			row.add_child(join_btn)

	var _lobby_list_conn = Net.lobby_list_received.connect(func(data: Array):
		_populate_list.call(data)
	)

	refresh_btn.pressed.connect(func(): Net.list_lobbies())

	Net.joined_lobby.connect(func(lobby_id: String, host_name: String):
		_mp_lobby_id = lobby_id
		_mp_is_host = false
		_clear_screen()
		_show_guest_lobby(host_name)
	, CONNECT_ONE_SHOT)

	host_btn.pressed.connect(func():
		Net.create_lobby(_mp_name)
	)

	Net.lobby_created.connect(func(lobby_id: String):
		_mp_lobby_id = lobby_id
		_mp_is_host = true
		_clear_screen()
		_show_host_lobby()
	, CONNECT_ONE_SHOT)

	Net.list_lobbies()

func _show_host_lobby() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	root.add_child(_make_header_bar("Your Lobby — Waiting for opponent", func():
		Net.send({"type": "leave_lobby"})
		_clear_screen()
		_show_lobby_browser()
	))

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	center.add_child(vbox)

	var status_lbl := Label.new()
	status_lbl.text = "Waiting for a player to join..."
	status_lbl.add_theme_font_size_override("font_size", 22)
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(status_lbl)

	var id_lbl := Label.new()
	id_lbl.text = "Lobby ID: " + _mp_lobby_id
	id_lbl.add_theme_font_size_override("font_size", 16)
	id_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(id_lbl)

	Net.player_joined.connect(func(guest_name: String):
		status_lbl.text = guest_name + " joined! Select your deck."
		_clear_screen()
		_show_deck_select(
			"Choose Your Deck",
			DeckManager.get_all_decks(),
			func(): Net.send({"type": "leave_lobby"}); _clear_screen(); _show_main_menu(),
			func(deck: Dictionary):
				_mp_player_deck_ids.clear()
				for id in deck["card_ids"]:
					_mp_player_deck_ids.append(str(id))
				_show_host_waiting_for_guest_deck(guest_name)
		)
	, CONNECT_ONE_SHOT)

func _show_host_waiting_for_guest_deck(guest_name: String) -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(center)

	var lbl := Label.new()
	lbl.text = "Waiting for %s to select a deck..." % guest_name
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.add_child(lbl)

	_await_guest_deck_and_start()

func _await_guest_deck_and_start() -> void:
	var msg: Dictionary = await Net.await_relay_of_type("deck_selected")
	_mp_guest_deck_ids.clear()
	for id in msg.get("deck_ids", []):
		_mp_guest_deck_ids.append(str(id))
	_start_mp_game_as_host()

func _show_guest_lobby(host_name: String) -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	root.add_child(_make_header_bar("Joined " + host_name + "'s Lobby", func():
		Net.send({"type": "leave_lobby"})
		_clear_screen()
		_show_lobby_browser()
	))

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	center.add_child(vbox)

	var lbl := Label.new()
	lbl.text = "Select your deck to ready up."
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

	var ready_btn := _menu_btn("SELECT DECK")
	ready_btn.pressed.connect(func():
		_clear_screen()
		_show_deck_select(
			"Choose Your Deck",
			DeckManager.get_all_decks(),
			func(): _clear_screen(); _show_guest_lobby(host_name),
			func(deck: Dictionary):
				_mp_player_deck_ids.clear()
				for id in deck["card_ids"]:
					_mp_player_deck_ids.append(str(id))
				Net.relay({"type": "deck_selected", "deck_ids": _mp_player_deck_ids})
				_start_mp_game_as_guest()
		)
	)
	vbox.add_child(ready_btn)

func _start_mp_game_as_host() -> void:
	var pd := DeckManager.build_deck_from_ids(_mp_player_deck_ids)
	var od := DeckManager.build_deck_from_ids(_mp_guest_deck_ids)
	_canvas.queue_free()
	var board := BoardScene.instantiate()
	add_child(board)
	_mp_manager = MpGameManager.new()
	board.add_child(_mp_manager)
	_mp_manager.start_as_host(board, pd, od)

func _start_mp_game_as_guest() -> void:
	_canvas.queue_free()
	var board := BoardScene.instantiate()
	add_child(board)
	_mp_manager = MpGameManager.new()
	board.add_child(_mp_manager)
	_mp_manager.start_as_guest(board)

func _on_opponent_left() -> void:
	if _mp_manager != null:
		_mp_manager.queue_free()
		_mp_manager = null
	for child in get_children():
		if child is Board:
			child.queue_free()
	_canvas = CanvasLayer.new()
	add_child(_canvas)
	var bg := TextureRect.new()
	bg.texture = WallpaperTexture
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(bg)
	_show_main_menu()

# ── Deck select ────────────────────────────────────────────────────────

func _on_play_pressed() -> void:
	_clear_screen()
	_show_deck_select(
		"Choose Your Deck",
		DeckManager.get_all_decks(),
		func(): _clear_screen(); _show_main_menu(),
		func(deck: Dictionary):
			_player_deck_ids.clear()
			for id in deck["card_ids"]:
				_player_deck_ids.append(str(id))
			_clear_screen()
			_show_opponent_select()
	)

func _on_ranked_pressed() -> void:
	_clear_screen()
	_show_deck_select(
		"Choose Your Deck",
		DeckManager.get_all_decks(),
		func(): _clear_screen(); _show_main_menu(),
		func(deck: Dictionary):
			_player_deck_ids.clear()
			for id in deck["card_ids"]:
				_player_deck_ids.append(str(id))
			_clear_screen()
			_show_ranked_start()
	)

func _show_ranked_start() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	root.add_child(_make_header_bar("Ranked", func():
		_clear_screen()
		_on_ranked_pressed()
	))

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	center.add_child(vbox)

	var level_lbl := Label.new()
	level_lbl.text = RankedProgress.get_display_string(Auth.rank_bracket, Auth.rank_in_legend, Auth.rank_legend_rating)
	level_lbl.add_theme_font_size_override("font_size", 32)
	level_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(level_lbl)

	var record_lbl := Label.new()
	record_lbl.text = "%d W - %d L" % [Auth.ranked_wins, Auth.ranked_losses]
	record_lbl.add_theme_font_size_override("font_size", 18)
	record_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(record_lbl)

	var floor_str := RankedProgress.get_floor_display_string(Auth.rank_floor)
	if not floor_str.is_empty():
		var floor_lbl := Label.new()
		floor_lbl.text = "Floor: %s" % floor_str
		floor_lbl.add_theme_font_size_override("font_size", 14)
		floor_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		floor_lbl.modulate = Color(0.7, 0.7, 0.7)
		vbox.add_child(floor_lbl)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(gap)

	var start_btn := _menu_btn("START MATCH")
	start_btn.pressed.connect(_begin_ranked_search)
	vbox.add_child(start_btn)

# ── Ranked matchmaking ──────────────────────────────────────────────────
#
# START MATCH queues for a same-skill human opponent for up to
# RANKED_SEARCH_TIMEOUT_SEC; if nobody's found in time, falls back to the
# existing AI match (with a fake bot name in the opponent nameplate) so
# Ranked always produces a match. A found human match gets a brief
# confirmation screen (opponent name + rating) before the game starts.
# `_ranked_search_id` guards against the match-found signal and the timeout
# racing each other, and against a stale timer/signal from an earlier
# cancelled search firing into a later one — whichever resolution is current
# wins, anything bound to an older id is a no-op.

func _begin_ranked_search() -> void:
	_ranked_search_id += 1
	var search_id := _ranked_search_id
	_clear_screen()
	_show_ranked_searching()
	Auth.queue_ranked()
	_ranked_match_found_callable = _on_ranked_match_found.bind(search_id)
	Net.ranked_match_found.connect(_ranked_match_found_callable, CONNECT_ONE_SHOT)
	get_tree().create_timer(RANKED_SEARCH_TIMEOUT_SEC).timeout.connect(_on_ranked_search_timeout.bind(search_id))

func _disconnect_ranked_match_found() -> void:
	if _ranked_match_found_callable.is_valid() and Net.ranked_match_found.is_connected(_ranked_match_found_callable):
		Net.ranked_match_found.disconnect(_ranked_match_found_callable)

func _show_ranked_searching() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	root.add_child(_make_header_bar("Ranked", _cancel_ranked_search))

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	center.add_child(vbox)

	var status_lbl := Label.new()
	status_lbl.text = "Searching for opponent..."
	status_lbl.add_theme_font_size_override("font_size", 24)
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(status_lbl)

	var cancel_btn := _menu_btn("CANCEL")
	cancel_btn.pressed.connect(_cancel_ranked_search)
	vbox.add_child(cancel_btn)

func _cancel_ranked_search() -> void:
	_ranked_search_id += 1
	_disconnect_ranked_match_found()
	Auth.cancel_ranked_queue()
	_clear_screen()
	_show_ranked_start()

func _on_ranked_search_timeout(search_id: int) -> void:
	if search_id != _ranked_search_id:
		return
	_ranked_search_id += 1
	_disconnect_ranked_match_found()
	Auth.cancel_ranked_queue()
	var ai_level := RankedProgress.get_ai_level(Auth.rank_bracket, Auth.rank_in_legend)
	_clear_screen()
	_start_game(_player_deck_ids, _random_ranked_opponent_ids(), ai_level, true, RankedProgress.random_bot_name())

func _on_ranked_match_found(lobby_id: String, role: String, opponent_name: String, opponent_rating: int,
							 search_id: int) -> void:
	if search_id != _ranked_search_id:
		return
	_ranked_search_id += 1
	_show_ranked_match_confirmation(role, opponent_name, opponent_rating)

func _show_ranked_match_confirmation(role: String, opponent_name: String, opponent_rating: int) -> void:
	_clear_screen()
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 12)
	center.add_child(vbox)

	var found_lbl := Label.new()
	found_lbl.text = "Match Found!"
	found_lbl.add_theme_font_size_override("font_size", 36)
	found_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(found_lbl)

	var vs_lbl := Label.new()
	vs_lbl.text = "vs %s (~%d)" % [opponent_name, opponent_rating]
	vs_lbl.add_theme_font_size_override("font_size", 20)
	vs_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(vs_lbl)

	await get_tree().create_timer(RANKED_MATCH_CONFIRM_SEC).timeout
	_start_ranked_pvp_match(role, opponent_name, opponent_rating)

func _start_ranked_pvp_match(role: String, opponent_name: String, opponent_rating: int) -> void:
	if role == "host":
		_await_ranked_guest_deck_and_start(opponent_name, opponent_rating)
	else:
		Net.relay({"type": "deck_selected", "deck_ids": _player_deck_ids})
		_canvas.queue_free()
		var board := BoardScene.instantiate()
		add_child(board)
		_mp_manager = MpGameManager.new()
		board.add_child(_mp_manager)
		_mp_manager.start_as_guest(board, opponent_name, true, opponent_rating)

func _await_ranked_guest_deck_and_start(opponent_name: String, opponent_rating: int) -> void:
	var msg: Dictionary = await Net.await_relay_of_type("deck_selected")
	var guest_deck_ids: Array[String] = []
	for id in msg.get("deck_ids", []):
		guest_deck_ids.append(str(id))
	var pd := DeckManager.build_deck_from_ids(_player_deck_ids)
	var od := DeckManager.build_deck_from_ids(guest_deck_ids)
	_canvas.queue_free()
	var board := BoardScene.instantiate()
	add_child(board)
	_mp_manager = MpGameManager.new()
	board.add_child(_mp_manager)
	_mp_manager.start_as_host(board, pd, od, opponent_name, true, opponent_rating)

const RANKED_FACTIONS := [
	CardData.CardColor.GREEN, CardData.CardColor.CRIMSON, CardData.CardColor.BLACK,
	CardData.CardColor.ORANGE, CardData.CardColor.TEAL,
]

func _random_ranked_opponent_ids() -> Array[String]:
	var faction_color: CardData.CardColor = RANKED_FACTIONS[randi() % RANKED_FACTIONS.size()]
	var opp_deck := DeckManager.build_random_faction_deck(faction_color)
	var opp_ids: Array[String] = []
	for c in opp_deck:
		opp_ids.append(c.id)
	return opp_ids

const AI_DIFFICULTIES := [
	{"label": "EASY",   "level": 1,  "color": Color(0.30, 0.80, 0.30)},
	{"label": "MEDIUM", "level": 5,  "color": Color(0.90, 0.70, 0.20)},
	{"label": "HARD",   "level": 10, "color": Color(0.85, 0.25, 0.25)},
]

## Shared Easy/Medium/Hard (AI level 1/5/10) toggle row, used by both the VS
## AI opponent-select screen and the Simulation screen. on_change(level) is
## called immediately when a different option is picked.
func _add_difficulty_row(vbox: Control, default_level: int, on_change: Callable) -> void:
	var diff_label := Label.new()
	diff_label.text = "Difficulty"
	diff_label.add_theme_font_size_override("font_size", 16)
	diff_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(diff_label)

	var diff_row := HBoxContainer.new()
	diff_row.alignment = BoxContainer.ALIGNMENT_CENTER
	diff_row.add_theme_constant_override("separation", 10)
	vbox.add_child(diff_row)

	var diff_group := ButtonGroup.new()
	for entry in AI_DIFFICULTIES:
		var level: int = entry["level"]
		var swatch: Color = entry["color"]

		var dbtn := Button.new()
		dbtn.text = entry["label"]
		dbtn.custom_minimum_size = Vector2(110, 48)
		dbtn.add_theme_font_size_override("font_size", 16)
		dbtn.toggle_mode = true
		dbtn.button_group = diff_group
		dbtn.button_pressed = (level == default_level)

		var ns := StyleBoxFlat.new()
		ns.bg_color = Color(0.14, 0.14, 0.17)
		ns.set_corner_radius_all(6)
		ns.border_width_left = 3
		ns.border_color = swatch.darkened(0.3)
		dbtn.add_theme_stylebox_override("normal", ns)
		var pressed_s := StyleBoxFlat.new()
		pressed_s.bg_color = swatch.darkened(0.55)
		pressed_s.set_corner_radius_all(6)
		pressed_s.border_width_left = 3
		pressed_s.border_color = swatch
		dbtn.add_theme_stylebox_override("pressed", pressed_s)

		dbtn.pressed.connect(func(): on_change.call(level))
		diff_row.add_child(dbtn)

func _show_opponent_select() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	root.add_child(_make_header_bar("Choose Opponent Faction", func():
		_clear_screen()
		_on_play_pressed()
	))

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	center.add_child(vbox)

	var selected_ai_level := 5  # Medium by default
	_add_difficulty_row(vbox, selected_ai_level, func(level: int): selected_ai_level = level)

	var diff_gap := Control.new()
	diff_gap.custom_minimum_size = Vector2(0, 10)
	vbox.add_child(diff_gap)

	var FACTIONS := [
		{"label": "Random Sapiens",        "color": CardData.CardColor.GREEN,   "swatch": Color(0.20, 0.65, 0.20)},
		{"label": "Random Moonlight Coven", "color": CardData.CardColor.CRIMSON, "swatch": Color(0.80, 0.20, 0.20)},
		{"label": "Random Junklings",       "color": CardData.CardColor.BLACK,   "swatch": Color(0.45, 0.45, 0.50)},
		{"label": "Random Gundari",         "color": CardData.CardColor.ORANGE,  "swatch": Color(0.90, 0.50, 0.10)},
		{"label": "Random Inyuites",        "color": CardData.CardColor.TEAL,    "swatch": Color(0.10, 0.60, 0.70)},
	]

	for entry in FACTIONS:
		var faction_color: CardData.CardColor = entry["color"]
		var swatch: Color = entry["swatch"]
		var label: String = entry["label"]

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(340, 68)
		btn.add_theme_font_size_override("font_size", 22)

		var ns := StyleBoxFlat.new()
		ns.bg_color = swatch.darkened(0.45)
		ns.set_corner_radius_all(8)
		ns.border_width_left = 5
		ns.border_color = swatch
		btn.add_theme_stylebox_override("normal", ns)
		var hs := StyleBoxFlat.new()
		hs.bg_color = swatch.darkened(0.25)
		hs.set_corner_radius_all(8)
		hs.border_width_left = 5
		hs.border_color = swatch.lightened(0.2)
		btn.add_theme_stylebox_override("hover", hs)
		var ps := StyleBoxFlat.new()
		ps.bg_color = swatch.darkened(0.55)
		ps.set_corner_radius_all(8)
		btn.add_theme_stylebox_override("pressed", ps)

		btn.text = label
		btn.pressed.connect(func():
			var opp_deck := DeckManager.build_archetype_deck(faction_color)
			var opp_ids: Array[String] = []
			for c in opp_deck:
				opp_ids.append(c.id)
			_start_game(_player_deck_ids, opp_ids, selected_ai_level)
		)
		vbox.add_child(btn)


func _show_deck_select(title: String, decks: Array[Dictionary], on_back: Callable, on_select: Callable) -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	root.add_child(_make_header_bar(title, on_back))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	var outer := MarginContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		outer.add_theme_constant_override(side, 30)
	scroll.add_child(outer)

	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 20)
	flow.add_theme_constant_override("v_separation", 20)
	outer.add_child(flow)

	for deck in decks:
		flow.add_child(_deck_card_btn(deck, on_select))

func _make_header_bar(title: String, on_back: Callable) -> Panel:
	var bar := Panel.new()
	bar.custom_minimum_size = Vector2(0, 64)
	var bar_style := StyleBoxFlat.new()
	bar_style.bg_color = Color(0.10, 0.11, 0.16)
	bar.add_theme_stylebox_override("panel", bar_style)

	var bar_m := MarginContainer.new()
	bar_m.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		bar_m.add_theme_constant_override(side, 10)
	bar.add_child(bar_m)

	var bar_hbox := HBoxContainer.new()
	bar_hbox.add_theme_constant_override("separation", 14)
	bar_m.add_child(bar_hbox)

	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(100, 42)
	back_btn.add_theme_font_size_override("font_size", 16)
	bar_hbox.add_child(back_btn)
	back_btn.pressed.connect(on_back)

	var title_lbl := Label.new()
	title_lbl.text = title
	title_lbl.add_theme_font_size_override("font_size", 28)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar_hbox.add_child(title_lbl)

	return bar

func _deck_card_btn(deck: Dictionary, on_select: Callable) -> Button:
	var faction_idx: int = int(deck.get("faction_idx", 0))
	var sw: Color = DeckManager.FACTION_SWATCHES[faction_idx]
	var deck_name: String = str(deck.get("name", "Unknown"))
	var is_starter: bool = bool(deck.get("is_starter", false))
	var count: int = (deck.get("card_ids", []) as Array).size()

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(260, 148)
	btn.clip_contents = true

	var ns := StyleBoxFlat.new()
	ns.bg_color = sw.darkened(0.4)
	ns.set_corner_radius_all(10)
	ns.border_width_left = 4
	ns.border_color = sw
	btn.add_theme_stylebox_override("normal", ns)
	var hs := StyleBoxFlat.new()
	hs.bg_color = sw.darkened(0.2)
	hs.set_corner_radius_all(10)
	hs.border_width_left = 4
	hs.border_color = sw.lightened(0.2)
	btn.add_theme_stylebox_override("hover", hs)
	var ps := StyleBoxFlat.new()
	ps.bg_color = sw.darkened(0.5)
	ps.set_corner_radius_all(10)
	btn.add_theme_stylebox_override("pressed", ps)

	var inner := VBoxContainer.new()
	inner.set_anchors_preset(Control.PRESET_FULL_RECT)
	inner.alignment = BoxContainer.ALIGNMENT_CENTER
	inner.add_theme_constant_override("separation", 5)
	btn.add_child(inner)

	if is_starter:
		var badge := Label.new()
		badge.text = "STARTER"
		badge.add_theme_font_size_override("font_size", 10)
		badge.add_theme_color_override("font_color", sw.lightened(0.5))
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.add_child(badge)

	var name_lbl := Label.new()
	name_lbl.text = deck_name
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(name_lbl)

	var info := Label.new()
	info.text = "%s  •  %d cards" % [DeckManager.FACTION_NAMES[faction_idx], count]
	info.add_theme_font_size_override("font_size", 12)
	info.add_theme_color_override("font_color", Color(0.70, 0.70, 0.70))
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(info)

	btn.pressed.connect(func(): on_select.call(deck))
	return btn

# ── Simulation ─────────────────────────────────────────────────────────

## Drives the simulation as an async loop instead of a _process() poll.
## SimRunner now yields once per atomic AI decision (see
## SimRunner._sim_play_turn), so `await run_batch(1)` here doesn't block
## rendering/input for a whole game — the engine keeps pumping frames
## between each MCTS decision, and STOP takes effect within about one
## decision instead of within a whole game (previously) or a whole batch of
## 20 games (before that, back when both were near-instant).
## `runner`/`last_gps_ms` are captured locally, and the loop bails out the
## moment `_sim_runner` no longer matches — either STOP was pressed, or the
## deck-mode toggle rebuilt the screen with a brand new SimRunner instance.
func _process(_delta: float) -> void:
	if not is_instance_valid(_sim_status_lbl):
		return
	if not _sim_running:
		_sim_status_lbl.text = ""
		return
	var elapsed_s := (Time.get_ticks_msec() - _sim_game_start_ms) / 1000.0
	_sim_status_lbl.text = "Simulating... %.0fs" % elapsed_s

func _run_simulation_loop() -> void:
	var runner := _sim_runner
	var last_gps_ms := Time.get_ticks_msec()
	while _sim_running and _sim_runner == runner:
		var before := runner.total_games
		_sim_game_start_ms = Time.get_ticks_msec()
		await runner.run_batch(1)
		if not _sim_running or _sim_runner != runner:
			return
		var ran := runner.total_games - before
		_sim_gps_count += ran
		var now_ms := Time.get_ticks_msec()
		var elapsed_sec := (now_ms - last_gps_ms) / 1000.0
		if elapsed_sec >= 0.75:
			_sim_gps_display = (_sim_gps_count / elapsed_sec) if elapsed_sec > 0.0 else 0.0
			_sim_gps_count = 0
			last_gps_ms = now_ms
			_rebuild_card_list()
		_update_sim_labels()

func _update_sim_labels() -> void:
	for key in _sim_stat_labels:
		if not is_instance_valid(_sim_stat_labels[key]["wins"]):
			_sim_stat_labels = {}
			return
		var w: int = _sim_runner.stats[key]["wins"]
		var l: int = _sim_runner.stats[key]["losses"]
		var total := w + l
		_sim_stat_labels[key]["wins"].text = str(w)
		_sim_stat_labels[key]["losses"].text = str(l)
		_sim_stat_labels[key]["pct"].text = "%.1f%%" % (100.0 * w / total) if total > 0 else "-"
	if is_instance_valid(_sim_totals_lbl):
		_sim_totals_lbl.text = "Total: %d games   •   %.0f games/sec" % [
			_sim_runner.total_games, _sim_gps_display]

func _on_simulation_pressed() -> void:
	_clear_screen()
	_show_simulation_screen()

func _show_simulation_screen() -> void:
	_sim_running = false
	_sim_runner = SimRunner.new(_sim_deck_mode, _sim_ai_level)
	_sim_stat_labels = {}
	_sim_card_grid = null
	_sim_gps_count = 0
	_sim_gps_display = 0.0

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	root.add_child(_make_header_bar("AI SIMULATION", func():
		_sim_running = false
		_sim_stat_labels = {}
		_sim_totals_lbl = null
		_sim_status_lbl = null
		_sim_card_grid = null
		_clear_screen()
		_show_main_menu()
	))

	# ── Two-column layout ──────────────────────────────────────
	var hbox := HBoxContainer.new()
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_theme_constant_override("separation", 0)
	root.add_child(hbox)

	# ── LEFT: faction stats ────────────────────────────────────
	var left_center := CenterContainer.new()
	left_center.custom_minimum_size = Vector2(440, 0)
	left_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(left_center)

	var left_vbox := VBoxContainer.new()
	left_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	left_vbox.add_theme_constant_override("separation", 14)
	left_center.add_child(left_vbox)

	var desc := Label.new()
	desc.text = ("AIs play archetype-built decks from\ndifferent factions each game."
		if _sim_deck_mode == SimRunner.DeckMode.ARCHETYPE
		else "AIs play random decks from\ndifferent factions each game.")
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left_vbox.add_child(desc)

	var mode_btn := _menu_btn(
		"Deck mode: ARCHETYPE (tap for RANDOM)"
		if _sim_deck_mode == SimRunner.DeckMode.ARCHETYPE
		else "Deck mode: RANDOM (tap for ARCHETYPE)")
	mode_btn.custom_minimum_size = Vector2(360, 44)
	mode_btn.add_theme_font_size_override("font_size", 13)
	mode_btn.pressed.connect(func():
		_sim_deck_mode = (SimRunner.DeckMode.RANDOM
			if _sim_deck_mode == SimRunner.DeckMode.ARCHETYPE
			else SimRunner.DeckMode.ARCHETYPE)
		_clear_screen()
		_show_simulation_screen()
	)
	left_vbox.add_child(mode_btn)

	## Higher = stronger/more realistic balance data but proportionally
	## slower (level 10 on both sides can push a single game past a minute).
	## Changing this rebuilds the screen with a fresh SimRunner, same as the
	## deck-mode toggle, so accumulated stats never mix data from two levels.
	_add_difficulty_row(left_vbox, _sim_ai_level, func(level: int):
		_sim_ai_level = level
		_clear_screen()
		_show_simulation_screen()
	)

	var sim_diff_gap := Control.new()
	sim_diff_gap.custom_minimum_size = Vector2(0, 4)
	left_vbox.add_child(sim_diff_gap)

	var table := GridContainer.new()
	table.columns = 4
	table.add_theme_constant_override("h_separation", 36)
	table.add_theme_constant_override("v_separation", 10)
	left_vbox.add_child(table)

	const FACTION_HEADERS := ["Faction", "W", "L", "Win%"]
	for h in FACTION_HEADERS:
		var lbl := Label.new()
		lbl.text = h
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.65))
		if h != "Faction":
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		table.add_child(_bg_cell(lbl))

	const FACTIONS := [
		["Sapiens",         "GREEN",   Color(0.20, 0.70, 0.20)],
		["Moonlight Coven", "CRIMSON", Color(0.90, 0.25, 0.25)],
		["Junklings",       "BLACK",   Color(0.65, 0.65, 0.70)],
		["Gundari",         "ORANGE",  Color(0.95, 0.55, 0.10)],
		["Inyuites",        "TEAL",    Color(0.15, 0.70, 0.80)],
	]

	for entry in FACTIONS:
		var fname: String = entry[0]
		var key: String   = entry[1]
		var clr: Color    = entry[2]

		var name_lbl := Label.new()
		name_lbl.text = fname
		name_lbl.add_theme_font_size_override("font_size", 19)
		name_lbl.add_theme_color_override("font_color", clr)
		table.add_child(_bg_cell(name_lbl))

		var wins_lbl := Label.new()
		wins_lbl.text = "0"
		wins_lbl.add_theme_font_size_override("font_size", 19)
		wins_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		wins_lbl.add_theme_color_override("font_color", Color.WHITE)
		table.add_child(_bg_cell(wins_lbl))

		var losses_lbl := Label.new()
		losses_lbl.text = "0"
		losses_lbl.add_theme_font_size_override("font_size", 19)
		losses_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		losses_lbl.add_theme_color_override("font_color", Color.WHITE)
		table.add_child(_bg_cell(losses_lbl))

		var pct_lbl := Label.new()
		pct_lbl.text = "-"
		pct_lbl.add_theme_font_size_override("font_size", 19)
		pct_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		pct_lbl.add_theme_color_override("font_color", Color.WHITE)
		table.add_child(_bg_cell(pct_lbl))

		_sim_stat_labels[key] = {"wins": wins_lbl, "losses": losses_lbl, "pct": pct_lbl}

	left_vbox.add_child(HSeparator.new())

	_sim_totals_lbl = Label.new()
	_sim_totals_lbl.text = "Total: 0 games"
	_sim_totals_lbl.add_theme_font_size_override("font_size", 13)
	_sim_totals_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	_sim_totals_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left_vbox.add_child(_sim_totals_lbl)

	## Both sides now search at MCTS level 10, so a single game can take from
	## several seconds to well over a minute — without this, the screen gives
	## zero feedback between clicking START and the first game finishing,
	## which reads as "nothing happened" even though it's working correctly.
	_sim_status_lbl = Label.new()
	_sim_status_lbl.text = ""
	_sim_status_lbl.add_theme_font_size_override("font_size", 13)
	_sim_status_lbl.add_theme_color_override("font_color", Color(0.9, 0.8, 0.3))
	_sim_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left_vbox.add_child(_sim_status_lbl)

	var start_btn := _menu_btn("START")
	start_btn.custom_minimum_size = Vector2(240, 56)
	start_btn.pressed.connect(func():
		_sim_running = not _sim_running
		start_btn.text = "STOP" if _sim_running else "START"
		if _sim_running:
			_run_simulation_loop()
	)
	left_vbox.add_child(start_btn)

	# ── Vertical divider ───────────────────────────────────────
	var vsep := VSeparator.new()
	vsep.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(vsep)

	# ── RIGHT: card win rates ──────────────────────────────────
	var right_vbox := VBoxContainer.new()
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vbox.add_theme_constant_override("separation", 6)
	hbox.add_child(right_vbox)

	var right_margin := MarginContainer.new()
	right_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		right_margin.add_theme_constant_override(side, 16)
	right_vbox.add_child(right_margin)

	var right_inner := VBoxContainer.new()
	right_inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_inner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_inner.add_theme_constant_override("separation", 8)
	right_margin.add_child(right_inner)

	var card_title := Label.new()
	card_title.text = "CARD WIN RATES"
	card_title.add_theme_font_size_override("font_size", 15)
	card_title.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	right_inner.add_child(card_title)

	var card_sub := Label.new()
	card_sub.text = "Sorted by win% in winning decks (min 30 appearances)"
	card_sub.add_theme_font_size_override("font_size", 11)
	card_sub.add_theme_color_override("font_color", Color(0.45, 0.45, 0.55))
	right_inner.add_child(card_sub)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_inner.add_child(scroll)

	_sim_card_grid = GridContainer.new()
	_sim_card_grid.columns = 5
	_sim_card_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sim_card_grid.add_theme_constant_override("h_separation", 20)
	_sim_card_grid.add_theme_constant_override("v_separation", 5)
	scroll.add_child(_sim_card_grid)

	# Column headers
	const CARD_HEADERS := ["Card", "Plays", "Win%", "K/P", "D/P"]
	for h in CARD_HEADERS:
		var lbl := Label.new()
		lbl.text = h
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color(0.45, 0.45, 0.55))
		if h == "Card":
			lbl.custom_minimum_size = Vector2(220, 0)
			_sim_card_grid.add_child(_bg_cell(lbl))
		elif h == "Win%":
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			_sim_card_grid.add_child(_bg_cell(lbl))
		else:
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			_sim_card_grid.add_child(lbl)

func _rebuild_card_list() -> void:
	if not is_instance_valid(_sim_card_grid) or _sim_runner == null:
		return

	# Clear existing rows (keep header row = first 5 children)
	while _sim_card_grid.get_child_count() > 5:
		var child := _sim_card_grid.get_child(_sim_card_grid.get_child_count() - 1)
		_sim_card_grid.remove_child(child)
		child.free()

	const MIN_GAMES := 0
	const FACTION_COLOR_MAP := {
		CardData.CardColor.GREEN:   Color(0.20, 0.70, 0.20),
		CardData.CardColor.CRIMSON: Color(0.90, 0.25, 0.25),
		CardData.CardColor.BLACK:   Color(0.65, 0.65, 0.70),
		CardData.CardColor.ORANGE:  Color(0.95, 0.55, 0.10),
		CardData.CardColor.TEAL:    Color(0.15, 0.70, 0.80),
		CardData.CardColor.GENERIC: Color(0.55, 0.55, 0.62),
	}

	# Build sortable list
	var rows: Array = []
	for id in _sim_runner.card_games:
		var games: int = _sim_runner.card_games[id]
		var plays: int = _sim_runner.card_plays.get(id, 0)
		var wins: int  = _sim_runner.card_wins.get(id, 0)
		var kills: int = _sim_runner.card_kills.get(id, 0)
		var dmg: int   = _sim_runner.card_damage.get(id, 0)
		var pct: float = 100.0 * wins / games if games > 0 else 0.0
		rows.append({"id": id, "games": games, "plays": plays, "wins": wins, "pct": pct, "kills": kills, "dmg": dmg})

	# Sort: cards with enough data by win% desc, then low-data cards by games desc
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ag: int = a["games"]
		var bg: int = b["games"]
		var a_ok: bool = ag >= MIN_GAMES
		var b_ok: bool = bg >= MIN_GAMES
		if a_ok and b_ok:
			var ap: float = a["pct"]
			var bp: float = b["pct"]
			return ap > bp
		if a_ok:
			return true
		if b_ok:
			return false
		return ag > bg
	)

	for row in rows:
		var card_data := CardDatabase.get_card(row["id"])
		if card_data == null:
			continue
		var clr: Color = FACTION_COLOR_MAP.get(card_data.color, Color(0.6, 0.6, 0.7))

		var name_lbl := Label.new()
		name_lbl.text = card_data.card_name
		name_lbl.add_theme_font_size_override("font_size", 13)
		name_lbl.add_theme_color_override("font_color", clr)
		name_lbl.custom_minimum_size = Vector2(220, 0)
		_sim_card_grid.add_child(_bg_cell(name_lbl))

		var plays_i: int = row["plays"]
		var plays_lbl := Label.new()
		plays_lbl.text = str(plays_i)
		plays_lbl.add_theme_font_size_override("font_size", 13)
		plays_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
		plays_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_sim_card_grid.add_child(plays_lbl)

		var games_i: int = row["games"]

		var pct_lbl := Label.new()
		if games_i >= MIN_GAMES:
			var pct_val: float = row["pct"]
			pct_lbl.text = "%.1f%%" % pct_val
			if pct_val >= 55.0:
				pct_lbl.add_theme_color_override("font_color", Color(0.30, 0.90, 0.30))
			elif pct_val <= 45.0:
				pct_lbl.add_theme_color_override("font_color", Color(0.90, 0.35, 0.35))
			else:
				pct_lbl.add_theme_color_override("font_color", Color.WHITE)
		else:
			pct_lbl.text = "—"
			pct_lbl.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
		pct_lbl.add_theme_font_size_override("font_size", 13)
		pct_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_sim_card_grid.add_child(_bg_cell(pct_lbl))

		var kills_i: int = row["kills"]
		var kills_lbl := Label.new()
		kills_lbl.text = "%.2f" % (float(kills_i) / plays_i) if plays_i > 0 else "—"
		kills_lbl.add_theme_font_size_override("font_size", 13)
		kills_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.85))
		kills_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_sim_card_grid.add_child(kills_lbl)

		var damage_i: int = row["dmg"]
		var dmg_lbl := Label.new()
		dmg_lbl.text = "%.1f" % (float(damage_i) / plays_i) if plays_i > 0 else "—"
		dmg_lbl.add_theme_font_size_override("font_size", 13)
		dmg_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.85))
		dmg_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_sim_card_grid.add_child(dmg_lbl)

# ── Deck builder ───────────────────────────────────────────────────────

func _on_deck_builder_pressed() -> void:
	_clear_screen()
	var builder := DeckBuilderScene.instantiate()
	_canvas.add_child(builder)
	builder.back_pressed.connect(func():
		_clear_screen()
		_show_main_menu()
	)

# ── Game start ─────────────────────────────────────────────────────────

func _start_game(player_ids: Array[String], opp_ids: Array[String], ai_level: int = 5, ranked: bool = false,
				  opponent_name: String = "") -> void:
	_player_deck_ids = player_ids.duplicate()
	_opponent_deck_ids = opp_ids.duplicate()
	var pd := DeckManager.build_deck_from_ids(player_ids)
	var od := DeckManager.build_deck_from_ids(opp_ids)
	if is_instance_valid(_canvas):
		_canvas.queue_free()
	var board := BoardScene.instantiate()
	add_child(board)
	if not opponent_name.is_empty():
		board.set_opponent_name(opponent_name)
	board.restart_requested.connect(func():
		board.queue_free()
		if ranked:
			# Re-roll the opponent and re-fetch the current AI level rather than
			# reusing what was captured at match start — a ranked win/loss just
			# moved the ladder, and Play Again should reflect that, not replay
			# the exact same matchup.
			var next_ai_level := RankedProgress.get_ai_level(Auth.rank_bracket, Auth.rank_in_legend)
			_start_game(_player_deck_ids, _random_ranked_opponent_ids(), next_ai_level, true,
						RankedProgress.random_bot_name())
		else:
			_start_game(_player_deck_ids, _opponent_deck_ids, ai_level, ranked)
	, CONNECT_ONE_SHOT)
	GameManagerAutoload.start_local_game(board, pd, od, ai_level, ranked)
