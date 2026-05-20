extends Node

const BoardScene = preload("res://scenes/game/board.tscn")

const COLOR_NAMES = ["SAPIENS", "MOONLIGHT COVEN", "JUNKLINGS", "GUNDARI", "INYUITES"]
const COLOR_SWATCHES = [
	Color(0.20, 0.65, 0.20),
	Color(0.80, 0.20, 0.20),
	Color(0.25, 0.25, 0.25),
	Color(0.90, 0.50, 0.10),
	Color(0.10, 0.60, 0.70),
]
const RANDOM_SWATCH = Color(0.42, 0.42, 0.48)

var _canvas: CanvasLayer
var _player_color_idx: int = -1

func _ready() -> void:
	_canvas = CanvasLayer.new()
	add_child(_canvas)

	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.12)
	bg.size = Vector2(1280, 720)
	_canvas.add_child(bg)

	_show_player_color_select()

func _clear_screen() -> void:
	var children = _canvas.get_children()
	for i in range(1, children.size()):
		children[i].queue_free()

func _build_screen(title_text: String, subtitle_text: String) -> VBoxContainer:
	var center := CenterContainer.new()
	center.size = Vector2(1280, 720)
	_canvas.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 16)
	center.add_child(vbox)

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = subtitle_text
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 24)
	vbox.add_child(spacer)

	return vbox

func _make_color_button(label: String, swatch: Color) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(140, 80)
	btn.add_theme_font_size_override("font_size", 20)

	var normal := StyleBoxFlat.new()
	normal.bg_color = swatch
	normal.set_corner_radius_all(10)
	normal.border_width_bottom = 3
	normal.border_color = swatch.darkened(0.3)
	btn.add_theme_stylebox_override("normal", normal)

	var hover := StyleBoxFlat.new()
	hover.bg_color = swatch.lightened(0.2)
	hover.set_corner_radius_all(10)
	hover.border_width_bottom = 3
	hover.border_color = swatch
	btn.add_theme_stylebox_override("hover", hover)

	var pressed_style := StyleBoxFlat.new()
	pressed_style.bg_color = swatch.darkened(0.15)
	pressed_style.set_corner_radius_all(10)
	btn.add_theme_stylebox_override("pressed", pressed_style)

	return btn

func _show_player_color_select() -> void:
	var vbox = _build_screen("Choose Your Faction", "Your deck will be filled with cards of the chosen color.")

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 20)
	vbox.add_child(hbox)

	for i in COLOR_NAMES.size():
		var btn = _make_color_button(COLOR_NAMES[i], COLOR_SWATCHES[i])
		hbox.add_child(btn)
		btn.pressed.connect(_on_player_color_selected.bind(i))

func _on_player_color_selected(player_color_idx: int) -> void:
	_player_color_idx = player_color_idx
	_clear_screen()
	_show_opponent_color_select()

func _show_opponent_color_select() -> void:
	var player_name = COLOR_NAMES[_player_color_idx]
	var vbox = _build_screen("Choose Opponent Faction", "You are playing as %s. Choose the opponent's faction." % player_name)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 20)
	vbox.add_child(hbox)

	for i in COLOR_NAMES.size():
		if i == _player_color_idx:
			continue
		var btn = _make_color_button(COLOR_NAMES[i], COLOR_SWATCHES[i])
		hbox.add_child(btn)
		btn.pressed.connect(_on_opponent_color_selected.bind(i))

	var random_btn = _make_color_button("RANDOM", RANDOM_SWATCH)
	random_btn.custom_minimum_size = Vector2(160, 80)
	hbox.add_child(random_btn)
	random_btn.pressed.connect(_on_opponent_random_selected)

func _on_opponent_color_selected(opponent_color_idx: int) -> void:
	_canvas.queue_free()
	_start_game(_player_color_idx, opponent_color_idx)

func _on_opponent_random_selected() -> void:
	var pool := range(COLOR_NAMES.size())
	pool.erase(_player_color_idx)
	var opponent_color_idx: int = pool[randi() % pool.size()]
	_canvas.queue_free()
	_start_game(_player_color_idx, opponent_color_idx)

func _start_game(player_color_idx: int, opponent_color_idx: int) -> void:
	var board := BoardScene.instantiate()
	add_child(board)
	GameManagerAutoload.start_local_game(board, player_color_idx, opponent_color_idx)
