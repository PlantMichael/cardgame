class_name HeroPanel
extends Panel

## Hearthstone-style circular hero badge, built entirely from nested Panels
## and a hand-drawn faction emblem (no portrait art exists in the project and
## none can be generated in-session - see set_faction()) rather than a
## painted portrait: a bronze rim + bevel ring around a faction-colored
## portrait disc, with a red health gem overlapping its bottom-right edge.

@onready var hp_label: Label = $HPLabel

var player_id: String = ""
var faction_color: int = CardData.CardColor.GENERIC
var _last_health: int = 30

var _health_gem: Panel
var _emblem: Control

signal hero_clicked(player_id: String)

const RING_RIM := Color(0.30, 0.22, 0.09)
const RING_BEVEL := Color(0.82, 0.68, 0.36)
const GEM_RIM := Color(0.30, 0.22, 0.09)
const GEM_BEVEL := Color(0.62, 0.10, 0.10)
const GEM_FILL := Color(0.82, 0.16, 0.14)
const EMBLEM_COLOR := Color(0.95, 0.90, 0.74)
const RING_INSET := 6.0
const PORTRAIT_INSET := 13.0

func _ready() -> void:
	gui_input.connect(_on_gui_input)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_build_visuals()

## Called once by Board.setup() after inferring which faction's cards make up
## this player's deck (there is no persistent "hero faction" field on
## PlayerState) - determines the portrait disc color and emblem glyph.
func set_faction(color: int) -> void:
	faction_color = color
	if is_instance_valid(_emblem):
		_emblem.queue_redraw()

func set_health(value: int) -> void:
	var took_damage = value < _last_health
	_last_health = value
	hp_label.text = str(value)
	if took_damage and is_instance_valid(_health_gem):
		var tween = create_tween()
		tween.tween_property(_health_gem, "modulate", Color(1.8, 1.0, 1.0), 0.1)
		tween.tween_property(_health_gem, "modulate", Color.WHITE, 0.3)

func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		hero_clicked.emit(player_id)

# ── Visual construction ─────────────────────────────────────────────────────

func _build_visuals() -> void:
	remove_theme_stylebox_override("panel")
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	var dia: float = minf(size.x, size.y)
	var origin: Vector2 = (size - Vector2(dia, dia)) * 0.5

	var rim := _make_circle(dia, RING_RIM)
	rim.position = origin
	add_child(rim)
	move_child(rim, 0)

	var bevel_dia := dia - RING_INSET
	var bevel := _make_circle(bevel_dia, RING_BEVEL)
	bevel.position = origin + Vector2(RING_INSET, RING_INSET) * 0.5
	add_child(bevel)

	var portrait_dia := dia - PORTRAIT_INSET
	var portrait := _make_circle(portrait_dia, _portrait_fill_color())
	portrait.position = origin + Vector2(PORTRAIT_INSET, PORTRAIT_INSET) * 0.5
	add_child(portrait)

	_emblem = Control.new()
	_emblem.size = Vector2(portrait_dia, portrait_dia) * 0.62
	_emblem.position = portrait.position + (portrait.size - _emblem.size) * 0.5
	_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_emblem.draw.connect(_draw_emblem.bind(_emblem))
	add_child(_emblem)

	var gem_dia := dia * 0.46
	var gem_origin := origin + Vector2(dia, dia) - Vector2(gem_dia, gem_dia) * 0.62
	var gem_rim := _make_circle(gem_dia, GEM_RIM)
	gem_rim.position = gem_origin
	add_child(gem_rim)

	_health_gem = _make_circle(gem_dia - 5.0, GEM_BEVEL)
	_health_gem.position = gem_origin + Vector2(2.5, 2.5)
	add_child(_health_gem)

	var gem_fill := _make_circle(gem_dia - 9.0, GEM_FILL)
	gem_fill.position = _health_gem.position + Vector2(2.0, 2.0)
	_health_gem.add_child(gem_fill)

	var shine := Control.new()
	shine.size = gem_fill.size
	shine.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shine.draw.connect(func():
		var r := shine.size.x * 0.28
		shine.draw_circle(Vector2(shine.size.x * 0.35, shine.size.y * 0.32), r, Color(1, 1, 1, 0.30))
	)
	gem_fill.add_child(shine)

	hp_label.get_parent().remove_child(hp_label)
	_health_gem.add_child(hp_label)
	hp_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_label.add_theme_font_size_override("font_size", int(gem_dia * 0.42))
	hp_label.add_theme_color_override("font_color", Color.WHITE)
	hp_label.add_theme_constant_override("outline_size", 3)
	hp_label.add_theme_color_override("font_outline_color", Color(0.15, 0.02, 0.02))

func _portrait_fill_color() -> Color:
	return DeckManager.FACTION_SWATCHES[faction_color].darkened(0.35)

func _make_circle(dia: float, color: Color) -> Panel:
	var p := Panel.new()
	p.size = Vector2(dia, dia)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(int(dia / 2.0))
	p.add_theme_stylebox_override("panel", style)
	return p

## Simple geometric glyph per faction (no portrait art available - see class
## comment) drawn straight into `ctrl`'s local rect, centered and scaled to
## its size so it reads clearly at hero-badge scale regardless of dia.
func _draw_emblem(ctrl: Control) -> void:
	var w := ctrl.size.x
	var h := ctrl.size.y
	var c := Vector2(w, h) * 0.5
	match faction_color:
		CardData.CardColor.GREEN: # Sapiens — military chevron/star
			var pts: PackedVector2Array = []
			var outer := w * 0.5
			var inner := w * 0.21
			for i in 10:
				var ang := -PI / 2.0 + i * PI / 5.0
				var r := outer if i % 2 == 0 else inner
				pts.append(c + Vector2(cos(ang), sin(ang)) * r)
			ctrl.draw_colored_polygon(pts, EMBLEM_COLOR)
		CardData.CardColor.CRIMSON: # Moonlight Coven — crescent moon
			ctrl.draw_circle(c, w * 0.46, EMBLEM_COLOR)
			ctrl.draw_circle(c + Vector2(w * 0.22, -h * 0.04), w * 0.40, _portrait_fill_color())
		CardData.CardColor.BLACK: # Junklings — scavenged gear
			var teeth := 8
			var outer := w * 0.5
			var inner := w * 0.36
			var pts: PackedVector2Array = []
			for i in teeth * 2:
				var ang := i * PI / teeth
				var r := outer if i % 2 == 0 else inner
				pts.append(c + Vector2(cos(ang), sin(ang)) * r)
			ctrl.draw_colored_polygon(pts, EMBLEM_COLOR)
			ctrl.draw_circle(c, w * 0.20, _portrait_fill_color())
		CardData.CardColor.ORANGE: # Gundari — mech/rocket
			var pts: PackedVector2Array = [
				Vector2(c.x, 0),
				Vector2(w * 0.78, h * 0.62),
				Vector2(w * 0.62, h * 0.62),
				Vector2(w * 0.62, h),
				Vector2(w * 0.38, h),
				Vector2(w * 0.38, h * 0.62),
				Vector2(w * 0.22, h * 0.62),
			]
			ctrl.draw_colored_polygon(pts, EMBLEM_COLOR)
		CardData.CardColor.TEAL: # Inyuites — snowflake
			for i in 3:
				var ang := i * PI / 3.0
				var dir := Vector2(cos(ang), sin(ang))
				ctrl.draw_line(c - dir * w * 0.5, c + dir * w * 0.5, EMBLEM_COLOR, w * 0.09)
			ctrl.draw_circle(c, w * 0.1, EMBLEM_COLOR)
		_: # Generic — plain diamond
			var pts: PackedVector2Array = [
				Vector2(c.x, 0), Vector2(w, c.y), Vector2(c.x, h), Vector2(0, c.y)
			]
			ctrl.draw_colored_polygon(pts, EMBLEM_COLOR)
