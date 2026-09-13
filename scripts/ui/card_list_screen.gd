class_name CardListScreen
extends Control

## Read-only browser for every card in the game, replacing the old AI
## SIMULATION screen on the main menu - sorted/grouped by color like
## DeckBuilderScreen's collection panel, but with bigger cards (legible
## without hovering), a Hearthstone-style mana-cost filter row, and
## color/type filters instead of the deckbuilder's "in this deck" concerns.

signal back_pressed

const CardScene := preload("res://scenes/cards/Card.tscn")
const CardPreviewScene := preload("res://scenes/cards/CardPreview.tscn")

const CARD_W := 190
const PREVIEW_SCALE := 1.7
const PREVIEW_PANEL_WIDTH := 420.0
const PREVIEW_MARGIN := 14.0
const TOOLBAR_BG := Color(0.08, 0.06, 0.05)
const CONTENT_BG := Color(0.07, 0.05, 0.04)
const MAX_COST_BUCKET := 10  # "10+" bucket, matching PlayerState.MAX_MANA

const COLOR_ORDER: Array[CardData.CardColor] = [
	CardData.CardColor.GREEN, CardData.CardColor.CRIMSON, CardData.CardColor.BLACK,
	CardData.CardColor.ORANGE, CardData.CardColor.TEAL, CardData.CardColor.GENERIC,
]

# ── Filter state ─────────────────────────────────────────────────────────
var _search_text: String = ""
var _color_filter: int = -1               # -1 = all, else CardData.CardColor
var _type_filter: int = -1                # -1 = all, else CardData.CardType
var _cost_filters: Dictionary = {}        # int bucket -> true; empty = all

var _color_btns: Array[Button] = []
var _type_btns: Array[Button] = []
var _cost_btns: Dictionary = {}           # bucket -> Button

var _keywords: Dictionary = {}
var _content_vbox: VBoxContainer
var _preview_card_node: CardPreview
var _preview_keyword_vbox: VBoxContainer
var _hide_preview_scheduled: bool = false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_load_keywords()
	_build_ui()
	_refresh_list()

func _load_keywords() -> void:
	var file := FileAccess.open("res://data/keywords.json", FileAccess.READ)
	if not file:
		return
	var result = JSON.parse_string(file.get_as_text())
	file.close()
	if result is Dictionary:
		_keywords = result

# ── UI construction ────────────────────────────────────────────────────────

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	root.add_child(_build_toolbar())

	var hbox := HBoxContainer.new()
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_theme_constant_override("separation", 0)
	root.add_child(hbox)

	var content_panel := PanelContainer.new()
	var content_style := StyleBoxFlat.new()
	content_style.bg_color = CONTENT_BG
	content_style.content_margin_left = 16; content_style.content_margin_right = 16
	content_style.content_margin_top = 12; content_style.content_margin_bottom = 12
	content_panel.add_theme_stylebox_override("panel", content_style)
	content_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(content_panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content_panel.add_child(scroll)

	_content_vbox = VBoxContainer.new()
	_content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_vbox.add_theme_constant_override("separation", 18)
	scroll.add_child(_content_vbox)

	hbox.add_child(_build_preview_panel())

func _build_toolbar() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _flat(TOOLBAR_BG))

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	margin.add_child(outer)
	panel.add_child(margin)

	# ── Row 1: back / title / color+type filters ──
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 14)
	outer.add_child(row1)

	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(90, 38)
	back_btn.pressed.connect(func(): back_pressed.emit())
	row1.add_child(back_btn)

	var title := Label.new()
	title.text = "CARD LIST"
	title.add_theme_font_size_override("font_size", 22)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row1.add_child(title)

	row1.add_child(VSeparator.new())

	var all_color_btn := _filter_toggle_btn("All Colors")
	all_color_btn.pressed.connect(func(): _set_color_filter(-1))
	_color_btns.append(all_color_btn)
	row1.add_child(all_color_btn)

	for i in COLOR_ORDER.size():
		var color: CardData.CardColor = COLOR_ORDER[i]
		var sw: Color = DeckManager.FACTION_SWATCHES[int(color)]
		var color_name: String = "GENERIC" if color == CardData.CardColor.GENERIC else DeckManager.FACTION_NAMES[int(color)]
		var btn := _filter_toggle_btn(color_name)
		btn.add_theme_color_override("font_color", sw.lightened(0.35))
		var c := color
		btn.pressed.connect(func(): _set_color_filter(int(c)))
		_color_btns.append(btn)
		row1.add_child(btn)

	row1.add_child(VSeparator.new())

	var all_type_btn := _filter_toggle_btn("All Types")
	all_type_btn.pressed.connect(func(): _set_type_filter(-1))
	_type_btns.append(all_type_btn)
	row1.add_child(all_type_btn)

	var creature_btn := _filter_toggle_btn("Creatures")
	creature_btn.pressed.connect(func(): _set_type_filter(int(CardData.CardType.CREATURE)))
	_type_btns.append(creature_btn)
	row1.add_child(creature_btn)

	var strat_btn := _filter_toggle_btn("Stratagems")
	strat_btn.pressed.connect(func(): _set_type_filter(int(CardData.CardType.STRATAGEM)))
	_type_btns.append(strat_btn)
	row1.add_child(strat_btn)

	# ── Row 2: mana curve pips / search ──
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	outer.add_child(row2)

	var cost_lbl := Label.new()
	cost_lbl.text = "Cost:"
	cost_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row2.add_child(cost_lbl)

	for bucket in range(0, MAX_COST_BUCKET + 1):
		var pip := Button.new()
		pip.text = str(bucket) if bucket < MAX_COST_BUCKET else "10+"
		pip.custom_minimum_size = Vector2(34, 34)
		pip.toggle_mode = true
		pip.add_theme_font_size_override("font_size", 13)
		var b := bucket
		pip.toggled.connect(func(_pressed: bool): _toggle_cost_filter(b))
		_cost_btns[bucket] = pip
		row2.add_child(pip)

	var search_gap := Control.new()
	search_gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(search_gap)

	var search_bar := LineEdit.new()
	search_bar.placeholder_text = "Search cards..."
	search_bar.custom_minimum_size = Vector2(240, 34)
	search_bar.text_changed.connect(func(t: String):
		_search_text = t.to_lower()
		_refresh_list()
	)
	row2.add_child(search_bar)

	_update_filter_btn_styles()
	return panel

func _build_preview_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(PREVIEW_PANEL_WIDTH, 0)
	panel.add_theme_stylebox_override("panel", _flat(Color(0.09, 0.07, 0.06)))

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, PREVIEW_MARGIN)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var holder := Control.new()
	holder.custom_minimum_size = Vector2(0, Card.CARD_SIZE.y * PREVIEW_SCALE + 20.0)
	vbox.add_child(holder)

	_preview_card_node = CardPreviewScene.instantiate()
	_preview_card_node.scale = Vector2(PREVIEW_SCALE, PREVIEW_SCALE)
	_preview_card_node.input_pickable = false
	_preview_card_node.set_process_input(false)
	holder.add_child(_preview_card_node)
	# Card's own children are laid out top-left-anchored within its 220x320
	# local rect (not centered on its origin) - same convention
	# DeckBuilderScreen's collection/deck cards use. Centered horizontally in
	# the panel's inner (margin-adjusted) width.
	var inner_width := PREVIEW_PANEL_WIDTH - PREVIEW_MARGIN * 2.0
	var scaled_card_width := Card.CARD_SIZE.x * PREVIEW_SCALE
	_preview_card_node.position = Vector2(maxf(0.0, (inner_width - scaled_card_width) / 2.0), 10.0)
	_ignore_control_input(_preview_card_node)
	_preview_card_node.modulate = Color(1, 1, 1, 0)
	_preview_card_node.visible = false

	var keyword_scroll := ScrollContainer.new()
	keyword_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(keyword_scroll)

	_preview_keyword_vbox = VBoxContainer.new()
	_preview_keyword_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_keyword_vbox.add_theme_constant_override("separation", 8)
	keyword_scroll.add_child(_preview_keyword_vbox)

	return panel

func _filter_toggle_btn(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.toggle_mode = true
	btn.custom_minimum_size = Vector2(0, 32)
	btn.add_theme_font_size_override("font_size", 12)
	return btn

func _flat(c: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	return s

# ── Filter handling ──────────────────────────────────────────────────────

func _set_color_filter(color: int) -> void:
	_color_filter = color
	_update_filter_btn_styles()
	_refresh_list()

func _set_type_filter(t: int) -> void:
	_type_filter = t
	_update_filter_btn_styles()
	_refresh_list()

func _toggle_cost_filter(bucket: int) -> void:
	if _cost_btns[bucket].button_pressed:
		_cost_filters[bucket] = true
	else:
		_cost_filters.erase(bucket)
	_refresh_list()

func _update_filter_btn_styles() -> void:
	for i in _color_btns.size():
		var active := (i == 0 and _color_filter == -1) or (i > 0 and _color_filter == int(COLOR_ORDER[i - 1]))
		_color_btns[i].button_pressed = active
	for i in _type_btns.size():
		var val := -1 if i == 0 else i - 1
		_type_btns[i].button_pressed = _type_filter == val

func _matches_cost(cost: int) -> bool:
	if _cost_filters.is_empty():
		return true
	var bucket := mini(cost, MAX_COST_BUCKET)
	return _cost_filters.has(bucket)

# ── Card list ────────────────────────────────────────────────────────────

func _refresh_list() -> void:
	for c in _content_vbox.get_children():
		_content_vbox.remove_child(c)
		c.queue_free()

	var all_cards := CardDatabase.get_all_cards()
	var sort_fn := func(a: CardData, b: CardData) -> bool:
		return a.cost < b.cost if a.cost != b.cost else a.card_name < b.card_name

	for color in COLOR_ORDER:
		if _color_filter != -1 and int(color) != _color_filter:
			continue
		var group: Array[CardData] = all_cards.filter(func(c: CardData) -> bool:
			if c.is_token or c.color != color:
				return false
			if _type_filter != -1 and int(c.card_type) != _type_filter:
				return false
			if not _matches_cost(c.cost):
				return false
			if _search_text != "" and not (c.card_name.to_lower().contains(_search_text)
					or c.description.to_lower().contains(_search_text)):
				return false
			return true
		)
		if group.is_empty():
			continue
		group.sort_custom(sort_fn)
		_add_color_section(color, group)

	if _content_vbox.get_child_count() == 0:
		var empty := Label.new()
		empty.text = "No cards match these filters."
		empty.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_content_vbox.add_child(empty)

func _add_color_section(color: CardData.CardColor, cards: Array[CardData]) -> void:
	var sw: Color = DeckManager.FACTION_SWATCHES[int(color)]
	var color_name: String = "GENERIC" if color == CardData.CardColor.GENERIC else DeckManager.FACTION_NAMES[int(color)]

	var lbl := Label.new()
	lbl.text = "%s  (%d)" % [color_name, cards.size()]
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", sw.lightened(0.35))
	_content_vbox.add_child(lbl)
	_content_vbox.add_child(HSeparator.new())

	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 14)
	flow.add_theme_constant_override("v_separation", 14)
	_content_vbox.add_child(flow)

	for card in cards:
		flow.add_child(_big_card(card))

func _big_card(card: CardData) -> Control:
	var scale_factor := CARD_W / Card.CARD_SIZE.x
	var card_h := Card.CARD_SIZE.y * scale_factor

	var wrapper := Control.new()
	wrapper.custom_minimum_size = Vector2(CARD_W, card_h)
	wrapper.mouse_filter = Control.MOUSE_FILTER_STOP

	var card_node: Card = CardScene.instantiate()
	card_node.use_text_overlay = false
	card_node.scale = Vector2(scale_factor, scale_factor)
	card_node.position = Vector2.ZERO
	card_node.input_pickable = false
	card_node.set_process_input(false)
	wrapper.add_child(card_node)
	card_node.call_deferred("setup", card)
	_ignore_control_input(card_node)

	wrapper.mouse_entered.connect(func(): _show_preview(card))
	wrapper.mouse_exited.connect(func(): _hide_preview())

	return wrapper

# ── Preview panel ──────────────────────────────────────────────────────────

func _show_preview(data: CardData) -> void:
	_hide_preview_scheduled = false
	_preview_card_node.setup(data)
	_preview_card_node.visible = true
	_preview_card_node.modulate = Color(1, 1, 1, 1)
	_build_preview_keyword_blocks(data)

func _hide_preview() -> void:
	_hide_preview_scheduled = true
	await get_tree().create_timer(0.06).timeout
	if _hide_preview_scheduled:
		_preview_card_node.modulate = Color(1, 1, 1, 0)
		_preview_card_node.visible = false
		_clear_preview_keyword_blocks()
		_hide_preview_scheduled = false

func _build_preview_keyword_blocks(data: CardData) -> void:
	_clear_preview_keyword_blocks()
	if _keywords.is_empty():
		return
	var seen: Array[String] = []
	var entries: Array[Dictionary] = []
	for ability in data.abilities:
		if not Abilities.is_keyword_tooltip(ability):
			continue
		var lookup_key := Abilities.get_tooltip_key(ability)
		if lookup_key in seen:
			continue
		if not _keywords.has(lookup_key) or (_keywords[lookup_key] as String).is_empty():
			continue
		seen.append(lookup_key)
		entries.append({"key": lookup_key, "desc": _keywords[lookup_key], "color": Abilities.get_color(ability)})
	var scan_queue: Array[String] = [data.description]
	for entry in entries:
		scan_queue.append(entry["desc"])
	var i := 0
	while i < scan_queue.size():
		var text_lower := scan_queue[i].to_lower()
		for kw_name in _keywords.keys():
			if kw_name in seen:
				continue
			if (_keywords[kw_name] as String).is_empty():
				continue
			if kw_name.to_lower() in text_lower:
				seen.append(kw_name)
				scan_queue.append(_keywords[kw_name])
				entries.append({"key": kw_name, "desc": _keywords[kw_name], "color": Abilities.get_color_for_display(kw_name)})
		i += 1
	for entry in entries:
		_preview_keyword_vbox.add_child(_make_keyword_block(entry["key"], entry["desc"], entry["color"]))

func _clear_preview_keyword_blocks() -> void:
	for child in _preview_keyword_vbox.get_children():
		_preview_keyword_vbox.remove_child(child)
		child.queue_free()

func _make_keyword_block(kw_name: String, desc: String, accent: Color) -> PanelContainer:
	var pc := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.10, 0.10, 0.14, 0.95)
	s.border_color = accent
	s.set_border_width_all(2)
	s.set_corner_radius_all(6)
	s.content_margin_left = 8; s.content_margin_right = 8
	s.content_margin_top = 6; s.content_margin_bottom = 6
	pc.add_theme_stylebox_override("panel", s)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	var title := Label.new()
	title.text = kw_name
	title.add_theme_color_override("font_color", accent.lightened(0.3))
	var body := Label.new()
	body.text = desc
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 13)
	body.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	vbox.add_child(title)
	vbox.add_child(body)
	pc.add_child(vbox)
	return pc

func _ignore_control_input(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_control_input(child)
