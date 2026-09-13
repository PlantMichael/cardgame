class_name CampaignMapScreen
extends Control

## Cinematic campaign trail shown before the first node and again after every
## subsequent one (see main.gd's _show_campaign_map_screen): the run's map
## art with each CampaignState node laid out as a circle along a procedural
## path (positions come from campaign_state.node_positions - generated once
## per run, and for a PvP run shared from host to guest via
## CampaignState.to_layout_dict()/apply_layout() so both sides see the same
## trail). On entry this screen runs a fixed sequence: toast the just-played
## node's result (if any) → resolve/wait-for the next flagged node's
## modifier choice if one is needed → fake-camera-zoom (Tween on a wrapper
## Control, this screen has no real Camera2D) to the next node → show its
## name/modifier → NODE_COUNTDOWN_SEC countdown → proceed_pressed. Pure
## display plus the interactive modifier-choice UI - all the actual
## campaign bookkeeping (scores, modifier resolution) lives in CampaignState;
## this screen only reads and, for a local pick, writes it.

signal proceed_pressed
## Emitted only when the local player interactively picks a modifier (i.e.
## they lost the last node) - main.gd relays this to the opponent for a PvP
## run. Never emitted for the AI-picks or waiting-for-opponent branches.
signal modifier_chosen(modifier: Dictionary)

const NODE_SIZE := 64.0
const NODE_COUNTDOWN_SEC := 10
const RESULT_TOAST_SEC := 2.0
const OPPONENT_PICK_TOAST_SEC := 2.5
const ZOOM_LEVEL := 1.8
const ZOOM_DURATION := 1.1

const MAP_TEXTURES := [
	preload("res://assets/maps/nomansland.png"),
	preload("res://assets/maps/thedunes.png"),
	preload("res://assets/maps/tungstenislands.png"),
]
const MAP_NAMES := ["No Man's Land", "The Dunes", "Tungsten Islands"]

const COLOR_CURRENT := Color(0.85, 0.70, 0.20)
const COLOR_FUTURE := Color(0.25, 0.25, 0.30)
const COLOR_MODIFIED_BORDER := Color(0.90, 0.50, 0.15)
const COLOR_LINE := Color(0.9, 0.9, 0.85, 0.55)

## Set by the caller (main.gd) before this node enters the tree.
var campaign_state: CampaignState
var opponent_name: String = ""
## null on the very first map view of a run (nothing was just played yet);
## true/false on every later view - did the local player win the node that
## was just played.
var last_result = null
## PvP-only: true when the OPPONENT (not this client) is the one picking the
## next flagged node's modifier, so this screen should show a waiting state
## and rely on main.gd calling on_modifier_resolved() once the pick arrives
## over the network, instead of resolving it locally. Always false for a
## local/AI campaign - the AI's pick always resolves immediately.
var awaiting_opponent_modifier: bool = false

signal _external_modifier_resolved

var _world: Control
var _timer_label: Label
var _info_label: Label
var _modifier_wait_lbl: Label
var _proceeded: bool = false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_run_sequence()

# ── UI construction ────────────────────────────────────────────────────────

func _build_ui() -> void:
	_world = Control.new()
	_world.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_world.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_world)

	var bg := TextureRect.new()
	bg.texture = MAP_TEXTURES[campaign_state.map_index]
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_world.add_child(bg)
	_size_background(bg)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.3)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_world.add_child(dim)

	_build_path()

	var header := Label.new()
	header.text = MAP_NAMES[campaign_state.map_index]
	header.add_theme_font_size_override("font_size", 30)
	header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	header.offset_top = 18
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_constant_override("outline_size", 4)
	header.add_theme_color_override("font_outline_color", Color.BLACK)
	add_child(header)

	var sub := Label.new()
	sub.text = "vs %s  ·  Score %s  ·  Best of %d" % [opponent_name, campaign_state.score_string(), campaign_state.best_of]
	sub.add_theme_font_size_override("font_size", 15)
	sub.set_anchors_preset(Control.PRESET_TOP_WIDE)
	sub.offset_top = 56
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_constant_override("outline_size", 3)
	sub.add_theme_color_override("font_outline_color", Color.BLACK)
	add_child(sub)

	_timer_label = Label.new()
	_timer_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_timer_label.offset_top = 84
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_timer_label.add_theme_font_size_override("font_size", 16)
	_timer_label.add_theme_constant_override("outline_size", 3)
	_timer_label.add_theme_color_override("font_outline_color", Color.BLACK)
	add_child(_timer_label)

	_build_info_panel()
	_build_legend()

## _zoom_camera_to pans/scales _world (up to ZOOM_LEVEL) to center whichever
## node comes next, including ones clamped near the map's edge - a
## viewport-sized bg would get panned past the screen edge on that side,
## exposing whatever sits behind this screen. Oversizing it by the zoom's
## worst-case pan distance keeps it covering the full screen at any node.
func _size_background(bg: TextureRect) -> void:
	var vp := get_viewport_rect().size
	var margin := vp / (2.0 * ZOOM_LEVEL) * 1.05
	bg.position = -margin
	bg.size = vp + margin * 2.0

## Positions are stored normalized (0..1) on CampaignState so they stay
## fixed for the whole run regardless of how many times this screen is
## rebuilt between nodes - see CampaignState._generate_node_positions.
func _node_position(index: int) -> Vector2:
	var viewport_size := get_viewport_rect().size
	var n := campaign_state.node_positions[index]
	return Vector2(n.x * viewport_size.x, n.y * viewport_size.y)

func _build_path() -> void:
	for i in campaign_state.total_nodes - 1:
		var line := Line2D.new()
		line.width = 4.0
		line.default_color = COLOR_LINE
		line.add_point(_node_position(i))
		line.add_point(_node_position(i + 1))
		_world.add_child(line)

	for i in campaign_state.total_nodes:
		_world.add_child(_build_node_marker(i))

func _build_node_marker(index: int) -> Control:
	var marker := Panel.new()
	marker.size = Vector2(NODE_SIZE, NODE_SIZE)
	marker.position = _node_position(index) - Vector2(NODE_SIZE, NODE_SIZE) * 0.5
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var fill := COLOR_FUTURE
	if not campaign_state.node_results[index].is_empty():
		fill = campaign_state.node_result_color(index)
	elif index == campaign_state.current_node_index:
		fill = COLOR_CURRENT

	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.set_corner_radius_all(int(NODE_SIZE / 2))
	if campaign_state.is_node_modified(index):
		style.set_border_width_all(4)
		style.border_color = COLOR_MODIFIED_BORDER
	marker.add_theme_stylebox_override("panel", style)

	var lbl := Label.new()
	lbl.text = str(index + 1)
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.add_child(lbl)

	return marker

func _build_info_panel() -> void:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.10, 0.88)
	style.set_corner_radius_all(8)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_top = -100
	panel.offset_bottom = -20
	panel.offset_left = 40
	panel.offset_right = -300
	add_child(panel)

	_info_label = Label.new()
	_info_label.add_theme_font_size_override("font_size", 16)
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_info_label)

func _build_legend() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	box.offset_left = -230
	box.offset_top = 20
	box.offset_right = -20
	add_child(box)

	var entries := [
		["You — %s" % DeckManager.FACTION_NAMES[int(campaign_state.player_faction_color)], DeckManager.FACTION_SWATCHES[int(campaign_state.player_faction_color)]],
		["Opponent — %s" % DeckManager.FACTION_NAMES[int(campaign_state.opponent_faction_color)], DeckManager.FACTION_SWATCHES[int(campaign_state.opponent_faction_color)]],
		["Current", COLOR_CURRENT],
		["Upcoming", COLOR_FUTURE],
		["Modified (border)", COLOR_MODIFIED_BORDER],
	]
	for entry in entries:
		var item := HBoxContainer.new()
		item.add_theme_constant_override("separation", 6)
		box.add_child(item)

		var swatch := ColorRect.new()
		swatch.color = entry[1]
		swatch.custom_minimum_size = Vector2(14, 14)
		item.add_child(swatch)

		var lbl := Label.new()
		lbl.text = entry[0]
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.add_theme_constant_override("outline_size", 2)
		lbl.add_theme_color_override("font_outline_color", Color.BLACK)
		item.add_child(lbl)

func _show_node_info(index: int) -> void:
	var lines: Array[String] = []
	lines.append("Node %d of %d" % [index + 1, campaign_state.total_nodes])
	if campaign_state.is_node_modified(index):
		var modifier := campaign_state.get_node_modifier(index)
		lines.append(("Modifier: %s — %s" % [modifier["name"], modifier["description"]]) if not modifier.is_empty() else "Modifier: none")
	else:
		lines.append("Modifier: none")
	_info_label.text = "\n".join(lines)

# ── Scripted sequence ──────────────────────────────────────────────────────

func _run_sequence() -> void:
	if last_result != null:
		var finished_index := campaign_state.current_node_index - 1
		if finished_index >= 0:
			_zoom_camera_to(finished_index, false)
			await _show_result_toast(last_result)
			if not is_instance_valid(self):
				return

	if campaign_state.current_node_needs_choice():
		await _run_modifier_choice()
		if not is_instance_valid(self):
			return

	await _zoom_camera_to(campaign_state.current_node_index, true)
	if not is_instance_valid(self):
		return
	_show_node_info(campaign_state.current_node_index)
	_run_countdown()

func _show_result_toast(won: bool) -> void:
	var toast := Label.new()
	toast.text = "Node Won!" if won else "Node Lost"
	toast.add_theme_font_size_override("font_size", 40)
	toast.add_theme_constant_override("outline_size", 4)
	toast.add_theme_color_override("font_outline_color", Color.BLACK)
	toast.add_theme_color_override("font_color", Color(0.45, 0.9, 0.45) if won else Color(0.9, 0.45, 0.45))
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toast.size = Vector2(320, 60)
	toast.position = get_viewport_rect().size / 2.0 - toast.size / 2.0
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast)
	await get_tree().create_timer(RESULT_TOAST_SEC).timeout
	if is_instance_valid(toast):
		toast.queue_free()

## Fake-camera: Tweens _world's scale/position so node `index`'s point lands
## centered and magnified in the viewport (this screen is a Control, not a
## Node2D, so there's no real Camera2D to zoom). `animate = false` snaps
## instantly, used to "already be" on the just-finished node before the
## result toast rather than visibly zooming to it.
func _zoom_camera_to(index: int, animate: bool) -> void:
	var target := _node_position(index)
	var viewport_center := get_viewport_rect().size / 2.0
	var target_scale := Vector2(ZOOM_LEVEL, ZOOM_LEVEL)
	var target_pos := viewport_center - target * ZOOM_LEVEL
	if not animate:
		_world.scale = target_scale
		_world.position = target_pos
		return
	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_world, "scale", target_scale, ZOOM_DURATION)
	tween.tween_property(_world, "position", target_pos, ZOOM_DURATION)
	await tween.finished

# ── Modifier choice ────────────────────────────────────────────────────────

func _run_modifier_choice() -> void:
	var choices := campaign_state.get_modifier_choices()
	if choices.is_empty():
		campaign_state.resolve_current_node_modifier({})
		return
	if last_result == false:
		await _show_modifier_picker(choices)
	elif awaiting_opponent_modifier:
		await _show_waiting_for_opponent()
	else:
		var chosen: Dictionary = choices[randi() % choices.size()]
		campaign_state.resolve_current_node_modifier(chosen)
		await _show_opponent_picked_toast(chosen)

func _show_modifier_picker(choices: Array[Dictionary]) -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.10, 0.92)
	style.set_corner_radius_all(8)
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 18
	style.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var pick_lbl := Label.new()
	pick_lbl.text = "Choose the next node's modifier:"
	pick_lbl.add_theme_font_size_override("font_size", 18)
	pick_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(pick_lbl)

	var picked := false
	for choice in choices:
		var cbtn := Button.new()
		cbtn.text = "%s — %s" % [choice["name"], choice["description"]]
		cbtn.custom_minimum_size = Vector2(380, 56)
		vbox.add_child(cbtn)
		cbtn.pressed.connect(func():
			if picked:
				return
			picked = true
			campaign_state.resolve_current_node_modifier(choice)
			modifier_chosen.emit(choice)
			center.queue_free()
			_external_modifier_resolved.emit()
		)

	await _external_modifier_resolved

func _show_waiting_for_opponent() -> void:
	_modifier_wait_lbl = Label.new()
	_modifier_wait_lbl.text = "Opponent is choosing the next node's modifier..."
	_modifier_wait_lbl.add_theme_font_size_override("font_size", 18)
	_modifier_wait_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_modifier_wait_lbl.add_theme_constant_override("outline_size", 3)
	_modifier_wait_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	_modifier_wait_lbl.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_modifier_wait_lbl.offset_top = 130
	_modifier_wait_lbl.offset_left = -220
	_modifier_wait_lbl.offset_right = 220
	add_child(_modifier_wait_lbl)

	await _external_modifier_resolved
	await get_tree().create_timer(1.5).timeout
	if is_instance_valid(_modifier_wait_lbl):
		_modifier_wait_lbl.queue_free()
	_modifier_wait_lbl = null

## Called by main.gd once the opponent's pick arrives over the network
## (relay message "campaign_modifier_chosen") - only meaningful while
## _show_waiting_for_opponent() is active (awaiting_opponent_modifier).
func on_modifier_resolved(chosen: Dictionary) -> void:
	campaign_state.resolve_current_node_modifier(chosen)
	if is_instance_valid(_modifier_wait_lbl):
		_modifier_wait_lbl.text = "Opponent chose: %s — %s" % [chosen.get("name", ""), chosen.get("description", "")]
	_external_modifier_resolved.emit()

func _show_opponent_picked_toast(chosen: Dictionary) -> void:
	var lbl := Label.new()
	lbl.text = "Opponent chose the next node's modifier: %s — %s" % [chosen["name"], chosen["description"]]
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.set_anchors_preset(Control.PRESET_CENTER_TOP)
	lbl.offset_top = 130
	lbl.offset_left = -260
	lbl.offset_right = 260
	add_child(lbl)
	await get_tree().create_timer(OPPONENT_PICK_TOAST_SEC).timeout
	if is_instance_valid(lbl):
		lbl.queue_free()

# ── Countdown ──────────────────────────────────────────────────────────────

func _run_countdown() -> void:
	var remaining := NODE_COUNTDOWN_SEC
	_update_timer_label(remaining)
	while remaining > 0 and not _proceeded:
		await get_tree().create_timer(1.0).timeout
		if not is_instance_valid(self) or _proceeded:
			return
		remaining -= 1
		_update_timer_label(remaining)
	_proceed()

func _update_timer_label(remaining: int) -> void:
	_timer_label.text = "Match begins in %ds" % remaining

func _proceed() -> void:
	if _proceeded:
		return
	_proceeded = true
	proceed_pressed.emit()
