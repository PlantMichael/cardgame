class_name Card
extends Area2D

@onready var card_visual: Panel = $CardVisual
@onready var name_label: Label = $NameLabel
@onready var mana_dots_panel: Panel = $maxmana
@onready var image_size_panel: Panel = $imagesize
@onready var description_label: RichTextLabel = $DescriptionLabel
@onready var attack_label: Label = $AttackLabel
@onready var health_label: Label = $HealthLabel
@onready var art_texture: TextureRect = $ArtTexture
@onready var background: TextureRect = $Background
@onready var stats_row: HBoxContainer = $StatsRow

const CARD_TEMPLATES = {
	CardData.CardColor.GREEN: preload("res://assets/greencard.png"),
	CardData.CardColor.BLACK: preload("res://assets/blackcard.png"),
	CardData.CardColor.CRIMSON: preload("res://assets/crimsoncard.png"),
	CardData.CardColor.TEAL: preload("res://assets/tealcard.png"),
}

const CARD_FONT := preload("res://assets/fonts/Orbitron.ttf")

const HAND_SCALE := Vector2(0.75, 0.75)
const HAND_DRAG_OFFSET := Vector2(82.5, 120.0)
const TOKEN_GAP := 6.0

var data: CardData = null
var minion: Minion = null
var is_in_hand: bool = false
var _is_selected: bool = false
var _dragging: bool = false
var _drag_start_pos: Vector2
var _original_parent: Node
var _original_index: int
var _is_highlighted_as_target: bool = false
var _pilot_token: Panel = null
var _reinforce_token: Panel = null
var _mana_dots_end_x: float = 0.0
var _description_plain_text: String = ""
var _keyword_regex: RegEx = null
var _keyword_colors: Dictionary = {}

signal clicked(card: Card)
signal dropped(card: Card)
signal drag_started(card: Card)

const CARD_COLORS = {
	CardData.CardColor.GREEN:    Color(0.18, 0.38, 0.18),
	CardData.CardColor.CRIMSON:  Color(0.38, 0.18, 0.18),
	CardData.CardColor.BLACK:    Color(0.14, 0.14, 0.14),
	CardData.CardColor.ORANGE:   Color(0.38, 0.28, 0.12),
	CardData.CardColor.TEAL:     Color(0.15, 0.35, 0.35),
	CardData.CardColor.GENERIC:  Color(0.22, 0.22, 0.26),
}
const CARD_BORDER_COLORS = {
	CardData.CardColor.GREEN:    Color(0.35, 0.72, 0.35),
	CardData.CardColor.CRIMSON:  Color(0.72, 0.35, 0.35),
	CardData.CardColor.BLACK:    Color(0.42, 0.42, 0.42),
	CardData.CardColor.ORANGE:   Color(0.72, 0.58, 0.30),
	CardData.CardColor.TEAL:     Color(0.30, 0.72, 0.72),
	CardData.CardColor.GENERIC:  Color(0.55, 0.55, 0.62),
}

func _ready() -> void:
	mana_dots_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	image_size_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())

## Wraps any keyword (Guardian, Rush, Rummage, ...) found in a card's
## description with the same color used for that keyword's ability badge.
func _highlight_keywords(description: String) -> String:
	_ensure_keyword_data()
	if _keyword_regex == null:
		return description
	var matches := _keyword_regex.search_all(description)
	if matches.is_empty():
		return description
	var result := ""
	var last_end := 0
	for m in matches:
		var start: int = m.get_start()
		var end: int = m.get_end()
		var word: String = m.get_string()
		var color: Color = _keyword_colors.get(word.to_lower(), Color.WHITE)
		result += description.substr(last_end, start - last_end)
		result += "[color=#%s]%s[/color]" % [color.to_html(false), word]
		last_end = end
	result += description.substr(last_end)
	return result

func _ensure_keyword_data() -> void:
	if _keyword_regex != null:
		return
	var words: Array[String] = []
	for ability in Abilities.KEYWORD_TOOLTIPS:
		var w: String = Abilities.get_display(ability)
		if w.is_empty():
			continue
		var key := w.to_lower()
		if not _keyword_colors.has(key):
			_keyword_colors[key] = Abilities.get_color(ability)
			words.append(w)
	if words.is_empty():
		return
	# Longest phrase first so e.g. "Challenge All" matches whole, not as
	# "Challenge" + leftover "All".
	words.sort_custom(func(a, b): return a.length() > b.length())
	var escaped: Array[String] = []
	for w in words:
		escaped.append(_escape_regex(w))
	var re := RegEx.new()
	var err := re.compile("(?i)\\b(" + "|".join(escaped) + ")\\b")
	if err == OK:
		_keyword_regex = re

func _escape_regex(text: String) -> String:
	var special := ["\\", ".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "^", "$"]
	var result := text
	for ch in special:
		result = result.replace(ch, "\\" + ch)
	return result

func _fit_label_to_width(label: Label, max_font: int) -> void:
	var font := label.get_theme_font("font")
	for size in range(max_font, 7, -1):
		label.add_theme_font_size_override("font_size", size)
		if font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= label.size.x:
			return

## description_label holds BBCode (color tags around keywords), so sizing must
## be measured against the plain text, not the tagged text.
func _fit_description_to_height(plain_text: String, max_font: int) -> void:
	var font := description_label.get_theme_font("normal_font")
	var line_spacing := description_label.get_theme_constant("line_separation")
	for size in range(max_font, 6, -1):
		description_label.add_theme_font_size_override("normal_font_size", size)
		var sz := font.get_multiline_string_size(plain_text, HORIZONTAL_ALIGNMENT_LEFT, description_label.size.x, size)
		var fh := font.get_height(size)
		var line_count := ceili(sz.y / fh) if fh > 0 else 1
		if sz.y + line_spacing * maxi(0, line_count - 1) <= description_label.size.y:
			return

func _fit_text() -> void:
	_fit_label_to_width(name_label, 18)
	_fit_description_to_height(_description_plain_text, 16)

func setup(card_data: CardData) -> void:
	data = card_data
	name_label.text = card_data.card_name
	_update_mana_dots(card_data.effective_cost())
	_description_plain_text = card_data.description
	description_label.text = "[center]" + _highlight_keywords(card_data.description) + "[/center]"
	var is_creature = card_data.card_type == CardData.CardType.CREATURE
	attack_label.visible = is_creature
	health_label.visible = is_creature
	stats_row.visible = is_creature
	name_label.add_theme_color_override("font_color", Color.WHITE)
	description_label.add_theme_color_override("default_color", Color.WHITE)
	if is_creature:
		attack_label.text = str(card_data.attack)
		health_label.text = str(card_data.health)
		attack_label.add_theme_color_override("font_color", Color.WHITE)
		health_label.add_theme_color_override("font_color", Color.WHITE)
	update_piloted_token(false)
	art_texture.texture = card_data.art
	_apply_color_theme(card_data.color)
	call_deferred("_fit_text")

func set_targeted(value: bool) -> void:
	_is_highlighted_as_target = value
	if value:
		card_visual.add_theme_stylebox_override("panel", _make_stylebox(Color(0.4, 0.1, 0.4, 0.55), Color(0.9, 0.3, 0.9, 1.0), 3))
	else:
		# Restore appropriate state
		if minion and minion.can_attack():
			set_can_attack(true)
		else:
			_apply_color_theme(data.color)

func setup_as_minion(m: Minion) -> void:
	minion = m
	setup(m.data)
	_update_mana_dots(m.data.cost)
	attack_label.text = str(m.current_attack)
	health_label.text = str(m.current_health)
	_apply_stat_colors(m)
	if m.is_nulled:
		_description_plain_text = "Nulled."
		description_label.text = "[center]Nulled.[/center]"
		_apply_silenced_style()
	update_piloted_token(m.is_piloted)
	update_reinforce_token(m.has_ability(Abilities.REINFORCE))
	call_deferred("_fit_text")

func _apply_stat_colors(m: Minion) -> void:
	const BLUE := Color(0.45, 0.75, 1.0)
	const RED  := Color(1.0, 0.35, 0.35)
	if m.current_attack > m.data.attack:
		attack_label.add_theme_color_override("font_color", BLUE)
	elif m.current_attack < m.data.attack:
		attack_label.add_theme_color_override("font_color", RED)
	else:
		attack_label.add_theme_color_override("font_color", Color.WHITE)
	if m.current_health < m.max_health:
		health_label.add_theme_color_override("font_color", RED)
	elif m.max_health > m.data.health:
		health_label.add_theme_color_override("font_color", BLUE)
	else:
		health_label.add_theme_color_override("font_color", Color.WHITE)

func set_playable(value: bool) -> void:
	modulate = Color.WHITE if value else Color(0.5, 0.5, 0.5, 0.8)

func set_summoning_sick(value: bool) -> void:
	if value:
		var border = CARD_BORDER_COLORS[data.color]
		card_visual.add_theme_stylebox_override("panel", _make_stylebox(Color(0.18, 0.05, 0.28, 0.75), border, 2))

func set_can_attack(value: bool) -> void:
	if value:
		var s = _make_stylebox(Color(0, 0, 0, 0), Color(1.0, 0.85, 0.2), 3)
		card_visual.add_theme_stylebox_override("panel", s)
	else:
		_apply_color_theme(data.color)

func set_selected(value: bool) -> void:
	_is_selected = value
	position.y = -24 if value else 0

func damage_flash() -> void:
	var tween = create_tween()
	tween.tween_property(self, "modulate", Color(1, 0.2, 0.2), 0.1)
	tween.tween_property(self, "modulate", Color.WHITE, 0.2)

func animate_transform() -> void:
	# Brief red flash + scale punch on the card itself
	var base_scale := scale
	var flash := create_tween().set_parallel(true)
	flash.tween_property(self, "modulate", Color(1.6, 0.15, 0.15), 0.12)
	flash.tween_property(self, "modulate", Color.WHITE, 0.45).set_delay(0.12)
	flash.tween_property(self, "scale", base_scale * 1.18, 0.12)
	flash.tween_property(self, "scale", base_scale, 0.22).set_delay(0.12)

	# Ring of red orbs that spiral inward by rotating + shrinking their container
	var swirl := Node2D.new()
	swirl.position = Vector2(110, 160)
	add_child(swirl)

	const NUM_ORBS := 8
	const RADIUS := 108.0
	const ORB_SIZE := Vector2(16, 16)
	for i in NUM_ORBS:
		var orb := Panel.new()
		orb.size = ORB_SIZE
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.75 + 0.25 * (float(i) / NUM_ORBS), 0.04, 0.04, 0.90)
		style.set_corner_radius_all(4)
		orb.add_theme_stylebox_override("panel", style)
		var angle := TAU * i / NUM_ORBS
		orb.position = Vector2(cos(angle), sin(angle)) * RADIUS - ORB_SIZE * 0.5
		swirl.add_child(orb)

	# Rotating while scaling to zero traces a natural inward spiral per orb
	var st := swirl.create_tween().set_parallel(true)
	st.tween_property(swirl, "rotation", TAU * 1.4, 0.65).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	st.tween_property(swirl, "scale", Vector2.ZERO, 0.65).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await st.finished
	swirl.queue_free()

func start_drag() -> void:
	if not is_in_hand:
		clicked.emit(self)
		return
	_drag_start_pos = global_position
	_original_parent = get_parent()
	_original_index = get_index()
	_dragging = true
	drag_started.emit(self)
	var viewport = get_viewport()
	_original_parent.remove_child(self)
	viewport.add_child(self)
	global_position = get_viewport().get_mouse_position() - HAND_DRAG_OFFSET


func return_to_hand() -> void:
	if not is_instance_valid(_original_parent):
		return
	if _original_parent.is_queued_for_deletion():
		return
	if get_parent() == get_viewport():
		get_viewport().remove_child(self)
	if not is_inside_tree():
		_original_parent.add_child(self)
		_original_parent.move_child(self, min(_original_index, _original_parent.get_child_count()))
	position = Vector2.ZERO
	scale = HAND_SCALE
	_dragging = false

func _input(event: InputEvent) -> void:
	if not _dragging:
		return
	if event is InputEventMouseMotion:
		global_position = get_viewport().get_mouse_position() - HAND_DRAG_OFFSET
	elif event is InputEventMouseButton and not event.pressed:
		_dragging = false
		dropped.emit(self)

func _apply_silenced_style() -> void:
	card_visual.add_theme_stylebox_override("panel", _make_stylebox(Color(0.22, 0.22, 0.25, 0.55), Color(0.45, 0.45, 0.50), 2))
	name_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	description_label.add_theme_color_override("default_color", Color(0.55, 0.55, 0.55))

func _update_mana_dots(cost: int) -> void:
	for child in mana_dots_panel.get_children():
		mana_dots_panel.remove_child(child)
		child.queue_free()
	var n := clampi(cost, 0, 10)
	const PANEL_W := 134.0
	const PANEL_H := 18.0
	const DOT_SIZE := 10.0
	const DOT_GAP := 2.0
	var total_w := 0.0 if n == 0 else n * DOT_SIZE + (n - 1) * DOT_GAP
	var start_x := (PANEL_W - total_w) / 2.0
	var dot_y := (PANEL_H - DOT_SIZE) / 2.0
	_mana_dots_end_x = mana_dots_panel.position.x + start_x + total_w
	for i in n:
		var dot := Panel.new()
		dot.size = Vector2(DOT_SIZE, DOT_SIZE)
		dot.position = Vector2(start_x + i * (DOT_SIZE + DOT_GAP), dot_y)
		var style := StyleBoxFlat.new()
		style.bg_color = Color.WHITE
		style.set_corner_radius_all(5)
		dot.add_theme_stylebox_override("panel", style)
		mana_dots_panel.add_child(dot)

func _apply_color_theme(color: CardData.CardColor) -> void:
	var border = CARD_BORDER_COLORS[color]
	card_visual.add_theme_stylebox_override("panel", _make_stylebox(Color(0, 0, 0, 0), border, 2))
	background.texture = CARD_TEMPLATES.get(color, preload("res://assets/card_template.png"))

func _get_corner_radius() -> int:
	return 6

func _make_stylebox(bg: Color, border: Color, border_width: int) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_width)
	s.set_corner_radius_all(_get_corner_radius())
	return s

func update_piloted_token(piloted: bool) -> void:
	if is_instance_valid(_pilot_token):
		remove_child(_pilot_token)
		_pilot_token.queue_free()
	_pilot_token = null
	if not piloted:
		return
	var panel := Panel.new()
	panel.name = "PilotedToken"
	panel.size = Vector2(16, 16)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.85, 0.45, 0.05)
	style.set_corner_radius_all(8)
	style.border_color = Color(1.0, 0.85, 0.5)
	style.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", style)
	panel.position = Vector2(_mana_dots_end_x + TOKEN_GAP, 14)
	var label := Label.new()
	label.text = "P"
	label.add_theme_font_override("font", CARD_FONT)
	label.add_theme_font_size_override("font_size", 9)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(label)
	add_child(panel)
	_pilot_token = panel

func update_reinforce_token(reinforced: bool) -> void:
	if is_instance_valid(_reinforce_token):
		remove_child(_reinforce_token)
		_reinforce_token.queue_free()
	_reinforce_token = null
	if not reinforced:
		return
	var panel := Panel.new()
	panel.name = "ReinforceToken"
	panel.size = Vector2(16, 16)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.55, 0.25)
	style.set_corner_radius_all(8)
	style.border_color = Color(0.5, 1.0, 0.6)
	style.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", style)
	panel.position = Vector2(_mana_dots_end_x + TOKEN_GAP, 32)
	var label := Label.new()
	label.text = "R"
	label.add_theme_font_override("font", CARD_FONT)
	label.add_theme_font_size_override("font_size", 9)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(label)
	add_child(panel)
	_reinforce_token = panel
