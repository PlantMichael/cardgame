extends Node

const BoardScene = preload("res://scenes/game/Board.tscn")
const DeckBuilderScene = preload("res://scenes/ui/DeckBuilderScreen.tscn")

var _canvas: CanvasLayer
var _player_deck_ids: Array[String] = []

# Multiplayer state
var _mp_name: String = ""
var _mp_lobby_id: String = ""
var _mp_is_host: bool = false
var _mp_player_deck_ids: Array[String] = []
var _mp_guest_deck_ids: Array[String] = []
var _mp_manager: MpGameManager = null

func _ready() -> void:
	_canvas = CanvasLayer.new()
	add_child(_canvas)

	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.12)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(bg)

	Net.opponent_left.connect(_on_opponent_left)
	_show_main_menu()

func _clear_screen() -> void:
	for i in range(_canvas.get_child_count() - 1, 0, -1):
		_canvas.get_child(i).queue_free()

# ── Main menu ──────────────────────────────────────────────────────────

func _show_main_menu() -> void:
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

	var build_btn := _menu_btn("DECK BUILDER")
	build_btn.pressed.connect(_on_deck_builder_pressed)
	vbox.add_child(build_btn)

func _menu_btn(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(300, 72)
	btn.add_theme_font_size_override("font_size", 24)
	return btn

# ── Multiplayer ────────────────────────────────────────────────────────

func _on_multiplayer_pressed() -> void:
	_clear_screen()
	_show_name_entry()

func _show_name_entry() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 16)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Enter Your Name"
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var name_edit := LineEdit.new()
	name_edit.custom_minimum_size = Vector2(300, 48)
	name_edit.add_theme_font_size_override("font_size", 20)
	name_edit.placeholder_text = "Your name..."
	name_edit.text = _mp_name
	vbox.add_child(name_edit)

	var status_lbl := Label.new()
	status_lbl.add_theme_font_size_override("font_size", 14)
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(status_lbl)

	var confirm_btn := _menu_btn("CONNECT")
	confirm_btn.custom_minimum_size = Vector2(300, 56)
	vbox.add_child(confirm_btn)

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.custom_minimum_size = Vector2(300, 48)
	back_btn.add_theme_font_size_override("font_size", 18)
	vbox.add_child(back_btn)

	back_btn.pressed.connect(func():
		_clear_screen()
		_show_main_menu()
	)

	confirm_btn.pressed.connect(func():
		var n := name_edit.text.strip_edges()
		if n.is_empty():
			status_lbl.text = "Please enter a name."
			return
		_mp_name = n
		status_lbl.text = "Connecting..."
		confirm_btn.disabled = true
		if Net._connected:
			_clear_screen()
			_show_lobby_browser()
		else:
			Net.connected_to_server.connect(func():
				_clear_screen()
				_show_lobby_browser()
			, CONNECT_ONE_SHOT)
			Net.error_received.connect(func(msg: String):
				status_lbl.text = "Error: " + msg
				confirm_btn.disabled = false
			, CONNECT_ONE_SHOT)
			Net.connect_to_relay()
	)

func _show_lobby_browser() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	# Header
	var bar := _make_header_bar("Multiplayer Lobbies", func():
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
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.12)
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

func _show_opponent_select() -> void:
	_show_deck_select(
		"Choose Opponent Deck",
		DeckManager.get_starter_decks(),
		func(): _clear_screen(); _on_play_pressed(),
		func(deck: Dictionary):
			var opp_ids: Array[String] = []
			for id in deck["card_ids"]:
				opp_ids.append(str(id))
			_start_game(_player_deck_ids, opp_ids)
	)

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

func _start_game(player_ids: Array[String], opp_ids: Array[String]) -> void:
	var pd := DeckManager.build_deck_from_ids(player_ids)
	var od := DeckManager.build_deck_from_ids(opp_ids)
	_canvas.queue_free()
	var board := BoardScene.instantiate()
	add_child(board)
	GameManagerAutoload.start_local_game(board, pd, od)
