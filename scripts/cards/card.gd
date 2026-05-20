class_name Card
extends Area2D

@onready var card_visual: PanelContainer = $CardVisual
@onready var name_label: Label = $CardVisual/CardLayout/TopRow/NameLabel
@onready var cost_badge: Panel = $CardVisual/CardLayout/TopRow/CostBadge
@onready var cost_label: Label = $CardVisual/CardLayout/TopRow/CostBadge/CostLabel
@onready var description_label: Label = $CardVisual/CardLayout/DescriptionLabel
@onready var attack_label: Label = $CardVisual/CardLayout/StatsRow/AttackBadge/AttackLabel
@onready var health_label: Label = $CardVisual/CardLayout/StatsRow/HealthBadge/HealthLabel
@onready var art_texture: TextureRect = $CardVisual/CardLayout/ArtTexture
@onready var stats_row: HBoxContainer = $CardVisual/CardLayout/StatsRow

var data: CardData = null
var minion: Minion = null
var is_in_hand: bool = false
var _is_selected: bool = false
var _dragging: bool = false
var _drag_start_pos: Vector2
var _original_parent: Node
var _original_index: int
var _is_highlighted_as_target: bool = false

signal clicked(card: Card)
signal dropped(card: Card)

const CARD_COLORS = {
	CardData.CardColor.GREEN:  Color(0.18, 0.38, 0.18),
	CardData.CardColor.CRIMSON:    Color(0.38, 0.18, 0.18),
	CardData.CardColor.BLACK:  Color(0.14, 0.14, 0.14),
	CardData.CardColor.ORANGE: Color(0.38, 0.28, 0.12),
	CardData.CardColor.TEAL:   Color(0.15, 0.35, 0.35),
}
const CARD_BORDER_COLORS = {
	CardData.CardColor.GREEN:  Color(0.35, 0.72, 0.35),
	CardData.CardColor.CRIMSON:    Color(0.72, 0.35, 0.35),
	CardData.CardColor.BLACK:  Color(0.42, 0.42, 0.42),
	CardData.CardColor.ORANGE: Color(0.72, 0.58, 0.30),
	CardData.CardColor.TEAL:   Color(0.30, 0.72, 0.72),
}

func _ready() -> void:
	pass

func setup(card_data: CardData) -> void:
	data = card_data
	name_label.text = card_data.card_name
	cost_label.text = str(card_data.effective_cost())
	_apply_cost_style(card_data.cost_modifier)
	description_label.text = card_data.description
	var is_creature = card_data.card_type == CardData.CardType.CREATURE
	stats_row.visible = is_creature
	if is_creature:
		attack_label.text = str(card_data.attack)
		health_label.text = str(card_data.health)
		attack_label.remove_theme_color_override("font_color")
		health_label.remove_theme_color_override("font_color")
	if card_data.art:
		art_texture.texture = card_data.art
	_apply_color_theme(card_data.color)
	_update_tribe_tag(card_data.abilities)

func set_targeted(value: bool) -> void:
	_is_highlighted_as_target = value
	if value:
		var s = StyleBoxFlat.new()
		s.bg_color = Color(0.4, 0.1, 0.4, 0.8)
		s.border_color = Color(0.9, 0.3, 0.9, 1.0)
		s.set_border_width_all(3)
		s.set_corner_radius_all(6)
		card_visual.add_theme_stylebox_override("panel", s)
	else:
		# Restore appropriate state
		if minion and minion.can_attack():
			set_can_attack(true)
		else:
			_apply_color_theme(data.color)

func setup_as_minion(m: Minion) -> void:
	minion = m
	setup(m.data)
	cost_label.text = str(m.data.cost)
	_apply_cost_style(0)
	attack_label.text = str(m.current_attack)
	health_label.text = str(m.current_health)
	_apply_stat_colors(m)
	if m.is_nulled:
		description_label.text = "Silenced."
		_apply_silenced_style()
	update_piloted_token(m.is_piloted)
	_update_tribe_tag(m.abilities)

func _apply_stat_colors(m: Minion) -> void:
	const BLUE := Color(0.45, 0.75, 1.0)
	const RED  := Color(1.0, 0.35, 0.35)
	if m.current_attack > m.data.attack:
		attack_label.add_theme_color_override("font_color", BLUE)
	elif m.current_attack < m.data.attack:
		attack_label.add_theme_color_override("font_color", RED)
	else:
		attack_label.remove_theme_color_override("font_color")
	if m.current_health < m.max_health:
		health_label.add_theme_color_override("font_color", RED)
	elif m.max_health > m.data.health:
		health_label.add_theme_color_override("font_color", BLUE)
	else:
		health_label.remove_theme_color_override("font_color")

func set_playable(value: bool) -> void:
	modulate = Color.WHITE if value else Color(0.5, 0.5, 0.5, 0.8)

func set_can_attack(value: bool) -> void:
	if value:
		var s = _make_stylebox(CARD_COLORS[data.color], Color(1.0, 0.85, 0.2), 3)
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
	swirl.position = Vector2(55, 80)
	add_child(swirl)

	const NUM_ORBS := 8
	const RADIUS := 54.0
	const ORB_SIZE := Vector2(8, 8)
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
	var viewport = get_viewport()
	_original_parent.remove_child(self)
	viewport.add_child(self)
	global_position = get_viewport().get_mouse_position() - Vector2(55, 80)


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
	scale = Vector2(0.7, 0.7)
	_dragging = false

func _input(event: InputEvent) -> void:
	if not _dragging:
		return
	if event is InputEventMouseMotion:
		global_position = get_viewport().get_mouse_position() - Vector2(55, 80)
	elif event is InputEventMouseButton and not event.pressed:
		_dragging = false
		dropped.emit(self)

func _apply_silenced_style() -> void:
	card_visual.add_theme_stylebox_override("panel", _make_stylebox(Color(0.22, 0.22, 0.25), Color(0.45, 0.45, 0.50), 2))
	name_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	description_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))

func _apply_cost_style(modifier: int) -> void:
	if modifier > 0:
		var s := StyleBoxFlat.new()
		s.bg_color = Color(0.75, 0.10, 0.10)
		s.set_corner_radius_all(4)
		cost_badge.add_theme_stylebox_override("panel", s)
	elif modifier < 0:
		var s := StyleBoxFlat.new()
		s.bg_color = Color(0.10, 0.35, 0.75)
		s.set_corner_radius_all(4)
		cost_badge.add_theme_stylebox_override("panel", s)
	else:
		cost_badge.remove_theme_stylebox_override("panel")

func _apply_color_theme(color: CardData.CardColor) -> void:
	var bg = CARD_COLORS[color]
	var border = CARD_BORDER_COLORS[color]
	card_visual.add_theme_stylebox_override("panel", _make_stylebox(bg, border, 2))

func _make_stylebox(bg: Color, border: Color, border_width: int) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_width)
	s.set_corner_radius_all(6)
	return s

func update_piloted_token(piloted: bool) -> void:
	var existing = get_node_or_null("PilotedToken")
	if existing:
		existing.queue_free()
	if not piloted:
		return
	var panel = Panel.new()
	panel.name = "PilotedToken"
	panel.size = Vector2(16, 16)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.85, 0.45, 0.05)
	style.set_corner_radius_all(8)
	style.border_color = Color(1.0, 0.85, 0.5)
	style.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", style)
	panel.position = Vector2(94, 20)
	var label = Label.new()
	label.text = "P"
	label.add_theme_font_size_override("font_size", 9)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(label)
	add_child(panel)

func _update_tribe_tag(abilities_list: Array[String]) -> void:
	for child in stats_row.get_children():
		if child.has_meta("is_tribe"):
			child.queue_free()

	var tribe_ability := ""
	for ability in abilities_list:
		if Abilities.is_tribe(ability):
			tribe_ability = ability
			break
	if tribe_ability.is_empty():
		return

	var spacer := Control.new()
	spacer.set_meta("is_tribe", true)
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_row.add_child(spacer)

	var label := Label.new()
	label.set_meta("is_tribe", true)
	label.text = Abilities.get_display(tribe_ability).to_upper()
	label.add_theme_font_size_override("font_size", 8)
	label.add_theme_color_override("font_color", Color.WHITE)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Abilities.get_color(tribe_ability)
	bg.set_corner_radius_all(3)
	bg.set_content_margin_all(2)
	label.add_theme_stylebox_override("normal", bg)
	stats_row.add_child(label)
