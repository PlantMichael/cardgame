extends Node

const BoardScene = preload("res://scenes/game/Board.tscn")
const DeckBuilderScene = preload("res://scenes/ui/DeckBuilderScreen.tscn")

var _canvas: CanvasLayer
var _player_deck_ids: Array[String] = []

func _ready() -> void:
	_canvas = CanvasLayer.new()
	add_child(_canvas)

	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.12)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(bg)

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

	var play_btn := _menu_btn("PLAY")
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

	# Header bar
	var bar := Panel.new()
	bar.custom_minimum_size = Vector2(0, 64)
	var bar_style := StyleBoxFlat.new()
	bar_style.bg_color = Color(0.10, 0.11, 0.16)
	bar.add_theme_stylebox_override("panel", bar_style)
	root.add_child(bar)

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

	# Deck grid
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
