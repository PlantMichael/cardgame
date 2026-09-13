class_name FactionPieChart
extends Control

## Faction picker, drawn as a pie chart instead of a row of buttons - purely
## a visual swap for DeckBuilderScreen's faction page, same click-to-select
## behavior as the old buttons (see _build_faction_buttons()).

signal slice_selected(idx: int)

const RING_INSET := 10.0
const LABEL_RADIUS_FRAC := 0.62
const HOVER_LIGHTEN := 0.18
const BORDER_COLOR := Color(0.05, 0.05, 0.05)
const BORDER_WIDTH := 3.0

var names: Array[String] = []
var colors: Array[Color] = []

var _hovered_idx: int = -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_exited.connect(_on_mouse_exited)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var idx := _slice_at(event.position)
		if idx != _hovered_idx:
			_hovered_idx = idx
			queue_redraw()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var idx := _slice_at(event.position)
		if idx >= 0:
			slice_selected.emit(idx)

func _on_mouse_exited() -> void:
	if _hovered_idx != -1:
		_hovered_idx = -1
		queue_redraw()

## -1 if the point is outside the circle or there are no slices.
func _slice_at(local_pos: Vector2) -> int:
	if names.is_empty():
		return -1
	var center := size / 2.0
	var radius := minf(size.x, size.y) / 2.0 - RING_INSET
	var offset := local_pos - center
	if offset.length() > radius:
		return -1
	var slice_angle := TAU / names.size()
	var angle := fposmod(offset.angle() - _start_angle(), TAU)
	return int(angle / slice_angle)

func _start_angle() -> float:
	return -PI / 2.0

func _draw() -> void:
	if names.is_empty():
		return
	var center := size / 2.0
	var radius := minf(size.x, size.y) / 2.0 - RING_INSET
	var slice_angle := TAU / names.size()
	var font := get_theme_default_font()
	var font_size := 15

	for i in names.size():
		var start := _start_angle() + i * slice_angle
		var fill: Color = colors[i] if i < colors.size() else Color(0.5, 0.5, 0.5)
		if i == _hovered_idx:
			fill = fill.lightened(HOVER_LIGHTEN)

		var points := PackedVector2Array([center])
		var point_count := maxi(2, int(slice_angle / deg_to_rad(4.0)))
		for p in point_count + 1:
			var a := start + slice_angle * p / float(point_count)
			points.append(center + Vector2(cos(a), sin(a)) * radius)
		draw_colored_polygon(points, fill)
		draw_polyline(points + PackedVector2Array([center]), BORDER_COLOR, BORDER_WIDTH, true)

		var mid := start + slice_angle / 2.0
		var label_pos := center + Vector2(cos(mid), sin(mid)) * radius * LABEL_RADIUS_FRAC
		# Multi-word faction names ("MOONLIGHT COVEN") wrap one word per line
		# instead of drawing as one long line, which would bleed into the
		# neighboring slices at this label radius.
		var lines := names[i].split(" ")
		var line_height := font.get_height(font_size)
		var block_top := label_pos.y - line_height * lines.size() / 2.0
		for l in lines.size():
			var text_size := font.get_string_size(lines[l], HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
			var line_pos := Vector2(label_pos.x - text_size.x / 2.0, block_top + line_height * (l + 1))
			draw_string(font, line_pos, lines[l], HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE)
