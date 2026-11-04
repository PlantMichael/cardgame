class_name DeckBuilderScreen
extends Control

signal back_pressed

const CardScene := preload("res://scenes/cards/Card.tscn")
const MenuFont := preload("res://assets/fonts/Orbitron.ttf")
const Wallpaper := preload("res://assets/wallapepr.png")
const PANEL := Color(0.05, 0.06, 0.09, 0.96)
const SURFACE := Color(0.08, 0.10, 0.15)
const BORDER := Color(0.22, 0.29, 0.39)
const TEXT := Color(0.92, 0.92, 0.96)
const MUTED := Color(0.66, 0.72, 0.82)
const CYAN := Color(0.45, 0.85, 1)
const GOLD := Color(1, 0.82, 0.35)
const KEYWORD_W := 220.0

var _faction_idx := -1
var _deck_ids: Array[String] = []
var _original_deck_name := ""
var _saved_deck_name := ""
var _saved_deck_ids: Array[String] = []
var _search_text := ""
var _color_filter := 0
var _type_filter := 0
var _cost_filter := -1
var _cells: Dictionary = {}
var _keywords: Dictionary = {}
var _hub_page: ScrollContainer
var _hub_deck_flow: HFlowContainer
var _faction_page: ScrollContainer
var _editor_page: HBoxContainer
var _title: Label
var _caption: Label
var _sidebar: PanelContainer
var _faction_label: Label
var _name_edit: LineEdit
var _count_lbl: Label
var _dirty_lbl: Label
var _status_lbl: Label
var _save_btn: Button
var _delete_btn: Button
var _search_bar: LineEdit
var _result_lbl: Label
var _reset_btn: Button
var _coll_scroll: ScrollContainer
var _coll_content: VBoxContainer
var _deck_content: VBoxContainer
var _source_buttons: Array[Button] = []
var _type_buttons: Array[Button] = []
var _cost_buttons: Array[Button] = []
var _curve: Array[ProgressBar] = []
var _curve_counts: Array[Label] = []
var _preview_panel: PanelContainer
var _preview_card_node: Card
var _preview_keyword_vbox: VBoxContainer
var _hide_timer: Timer
var _prompt: CanvasLayer
var _prompt_buttons: Array[Button] = []
var _return_focus: Control

func _ready() -> void:
	_load_keywords()
	_build_theme()
	_build_ui()
	_build_preview()
	resized.connect(_layout_for_size)
	_layout_for_size()
	_show_hub_page()

func _style(bg: Color, border: Color = BORDER, padding: int = 12) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(padding)
	return s

func _build_theme() -> void:
	theme = Theme.new()
	theme.default_font_size = 16
	for kind in ["Label", "Button", "LineEdit", "OptionButton"]:
		theme.set_color("font_color", kind, TEXT)
	for kind in ["Button", "OptionButton"]:
		theme.set_stylebox("normal", kind, _style(SURFACE))
		theme.set_stylebox("hover", kind, _style(Color(0.10, 0.17, 0.23), CYAN))
		theme.set_stylebox("pressed", kind, _style(Color(0.13, 0.16, 0.20), GOLD))
		theme.set_stylebox("disabled", kind, _style(SURFACE, BORDER))
		theme.set_stylebox("focus", kind, _style(Color(0, 0, 0, 0), CYAN, 0))
		theme.set_color("font_hover_color", kind, CYAN)
		theme.set_color("font_pressed_color", kind, GOLD)
		theme.set_color("font_disabled_color", kind, MUTED)
	theme.set_stylebox("normal", "LineEdit", _style(SURFACE))
	theme.set_stylebox("focus", "LineEdit", _style(SURFACE, CYAN))
	theme.set_color("font_placeholder_color", "LineEdit", MUTED)
	theme.set_stylebox("panel", "PanelContainer", _style(PANEL, BORDER, 16))

func _label(text: String, font_size: int = 16, color: Color = TEXT, heading: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	if heading: l.add_theme_font_override("font", MenuFont)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _button(text: String, action: Callable, accessible: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.accessibility_name = accessible if not accessible.is_empty() else text
	b.custom_minimum_size.y = 36
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.pressed.connect(action)
	return b

func _vbox(parent: Node, separation: int = 12) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", separation)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(v)
	return v

func _scroll(parent: Node) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.follow_focus = true
	parent.add_child(s)
	return s

func _build_ui() -> void:
	var wallpaper := TextureRect.new()
	wallpaper.texture = Wallpaper
	wallpaper.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wallpaper.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	wallpaper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wallpaper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(wallpaper)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.07, 0.78)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)
	var root := _vbox(margin, 16)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 24)
	root.add_child(header)
	header.add_child(_button("← Back", _go_back, "Back"))
	_title = _label("YOUR DECKS", 26, TEXT, true)
	header.add_child(_title)
	_caption = _label("Build your next contender.", 16, MUTED)
	_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(_caption)
	_hub_page = _scroll(root)
	_hub_deck_flow = HFlowContainer.new()
	_hub_deck_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hub_deck_flow.add_theme_constant_override("h_separation", 16)
	_hub_deck_flow.add_theme_constant_override("v_separation", 16)
	_hub_page.add_child(_hub_deck_flow)
	_build_faction_page(root)
	_build_editor(root)

func _build_faction_page(root: Node) -> void:
	_faction_page = _scroll(root)
	var v := _vbox(_faction_page, 20)
	var heading := _label("CHOOSE YOUR FACTION", 24, TEXT, true)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(heading)
	var pie := FactionPieChart.new()
	pie.custom_minimum_size = Vector2(360, 360)
	pie.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	for i in DeckManager.FACTION_NAMES.size():
		pie.names.append(DeckManager.FACTION_NAMES[i])
		pie.colors.append(DeckManager.FACTION_SWATCHES[i])
	pie.slice_selected.connect(func(idx: int): _show_editor_page(idx, "My Deck", []))
	v.add_child(pie)
	var choices := HFlowContainer.new()
	choices.alignment = FlowContainer.ALIGNMENT_CENTER
	choices.add_theme_constant_override("h_separation", 10)
	choices.add_theme_constant_override("v_separation", 10)
	v.add_child(choices)
	for i in DeckManager.FACTION_NAMES.size():
		var b := _button(DeckManager.FACTION_NAMES[i], func(): _show_editor_page(i, "My Deck", []))
		b.add_theme_color_override("font_color", DeckManager.FACTION_SWATCHES[i].lightened(0.45))
		choices.add_child(b)

func _build_editor(root: Node) -> void:
	_editor_page = HBoxContainer.new()
	_editor_page.add_theme_constant_override("separation", 16)
	_editor_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_editor_page)
	var collection := PanelContainer.new()
	collection.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_editor_page.add_child(collection)
	var v := _vbox(collection)
	var search_row := HBoxContainer.new()
	search_row.add_theme_constant_override("separation", 10)
	v.add_child(search_row)
	_search_bar = LineEdit.new()
	_search_bar.placeholder_text = "Search cards or abilities…"
	_search_bar.accessibility_name = "Search cards"
	_search_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_bar.text_changed.connect(func(t: String):
		_search_text = t.to_lower().strip_edges()
		_refresh_coll(true)
	)
	search_row.add_child(_search_bar)
	_reset_btn = _button("Reset", _reset_filters)
	search_row.add_child(_reset_btn)
	var filters := HFlowContainer.new()
	filters.add_theme_constant_override("h_separation", 12)
	filters.add_theme_constant_override("v_separation", 8)
	v.add_child(filters)
	_filter_group(filters, ["All cards", "Faction", "Generics"], _source_buttons, func(idx: int):
		_color_filter = idx
		_refresh_coll(true)
	)
	_filter_group(filters, ["All types", "Creatures", "Stratagems"], _type_buttons, func(idx: int):
		_type_filter = idx
		_refresh_coll(true)
	)
	var costs := HFlowContainer.new()
	costs.add_theme_constant_override("h_separation", 6)
	costs.add_theme_constant_override("v_separation", 6)
	v.add_child(costs)
	costs.add_child(_label("MANA", 12, MUTED, true))
	var costs_names := ["Any", "0", "1", "2", "3", "4", "5", "6", "7+"]
	for idx in costs_names.size():
		var b := _button(costs_names[idx], func():
			_cost_filter = idx - 1
			_refresh_coll(true)
		, "Mana " + costs_names[idx])
		b.custom_minimum_size = Vector2(36, 32)
		b.toggle_mode = true
		costs.add_child(b)
		_cost_buttons.append(b)
	_result_lbl = _label("", 14, MUTED)
	_result_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(_result_lbl)
	_coll_scroll = _scroll(v)
	_coll_content = _vbox(_coll_scroll, 14)
	_build_sidebar()

func _filter_group(parent: Node, names: Array, buttons: Array[Button], action: Callable) -> void:
	var group := HBoxContainer.new()
	group.add_theme_constant_override("separation", 4)
	parent.add_child(group)
	for idx in names.size():
		var b := _button(names[idx], action.bind(idx))
		b.toggle_mode = true
		b.add_theme_font_size_override("font_size", 14)
		group.add_child(b)
		buttons.append(b)

func _build_sidebar() -> void:
	_sidebar = PanelContainer.new()
	_editor_page.add_child(_sidebar)
	var v := _vbox(_sidebar, 10)
	_faction_label = _label("", 16, CYAN, true)
	_faction_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(_faction_label)
	_name_edit = LineEdit.new()
	_name_edit.accessibility_name = "Deck name"
	_name_edit.placeholder_text = "Name your deck"
	_name_edit.text_changed.connect(func(_t: String):
		_status_lbl.text = ""
		_update_save_state()
	)
	v.add_child(_name_edit)
	var count_row := HBoxContainer.new()
	v.add_child(count_row)
	_count_lbl = _label("", 20)
	_count_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	count_row.add_child(_count_lbl)
	count_row.add_child(_button("Clear", func():
		_deck_ids.clear()
		_refresh_deck()
		_update_cells()
	))
	_dirty_lbl = _label("", 13, MUTED)
	v.add_child(_dirty_lbl)
	var chart := HBoxContainer.new()
	chart.add_theme_constant_override("separation", 8)
	v.add_child(chart)
	for i in 8:
		var bucket := _vbox(chart, 3)
		var count := _label("0", 12, MUTED)
		count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		bucket.add_child(count)
		_curve_counts.append(count)
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(16, 48)
		bar.fill_mode = ProgressBar.FILL_BOTTOM_TO_TOP
		bar.show_percentage = false
		bar.add_theme_stylebox_override("background", _style(SURFACE, SURFACE, 0))
		bar.add_theme_stylebox_override("fill", _style(CYAN, CYAN, 0))
		bar.accessibility_name = "Mana " + (str(i) if i < 7 else "7+")
		bucket.add_child(bar)
		_curve.append(bar)
		var caption := _label(str(i) if i < 7 else "7+", 12, MUTED)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		bucket.add_child(caption)
	v.add_child(_label("YOUR DECK · CLICK TO REMOVE", 11, MUTED, true))
	_deck_content = _vbox(_scroll(v), 5)
	_status_lbl = _label("", 13, GOLD)
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status_lbl)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	v.add_child(actions)
	_save_btn = _button("Save deck", _do_save)
	_save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_btn.add_theme_color_override("font_color", CYAN)
	actions.add_child(_save_btn)
	_delete_btn = _button("Delete", _do_delete)
	_delete_btn.add_theme_color_override("font_color", Color(1, 0.55, 0.55))
	actions.add_child(_delete_btn)

func _layout_for_size() -> void:
	_sidebar.custom_minimum_size.x = 320 if size.x < 1300 else 360
	_caption.visible = size.x >= 1100
	_hide_preview_now()

func _page(hub: bool, faction: bool) -> void:
	_hide_preview_now()
	_hub_page.visible = hub
	_faction_page.visible = faction
	_editor_page.visible = not hub and not faction
	_title.text = "YOUR DECKS" if hub else ("NEW DECK" if faction else "DECK BUILDER")

func _show_hub_page() -> void:
	_page(true, false)
	_faction_idx = -1
	_deck_ids.clear()
	_clear_children(_hub_deck_flow)
	var create := _button("+\n\nCREATE A DECK", _show_faction_page, "Create a deck")
	create.custom_minimum_size = Vector2(260, 238)
	create.add_theme_font_override("font", MenuFont)
	create.add_theme_color_override("font_color", CYAN)
	_hub_deck_flow.add_child(create)
	var decks := DeckManager.get_custom_decks()
	for deck in decks:
		_hub_deck_flow.add_child(_hub_deck_card(deck))
	if decks.is_empty():
		var hint := _label("Your next deck starts here.\nChoose a faction, then find your cards.", 18, MUTED)
		hint.custom_minimum_size = Vector2(300, 238)
		hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_hub_deck_flow.add_child(hint)

func _hub_deck_card(deck: Dictionary) -> Button:
	var fi: int = int(deck.get("faction_idx", 0))
	var deck_name: String = str(deck.get("name", "Unknown"))
	var ids: Array[String] = []
	for id in deck.get("card_ids", []): ids.append(str(id))
	var b := _button("", func(): _show_editor_page(fi, deck_name, ids, true), "Open deck " + deck_name)
	b.custom_minimum_size = Vector2(260, 238)
	b.clip_contents = true
	b.tooltip_text = deck_name
	var v := VBoxContainer.new()
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 16
	v.offset_top = 16
	v.offset_right = -16
	v.offset_bottom = -16
	v.add_theme_constant_override("separation", 8)
	b.add_child(v)
	var art := TextureRect.new()
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.custom_minimum_size.y = 100
	for id in ids:
		var card := CardDatabase.get_card(id)
		if card != null and card.art != null:
			art.texture = card.art
			break
	v.add_child(art)
	var title := _label(deck_name, 18)
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(title)
	v.add_child(_label(DeckManager.FACTION_NAMES[fi], 12, DeckManager.FACTION_SWATCHES[fi].lightened(0.45), true))
	v.add_child(_label("%d / 40 · %s" % [ids.size(), "Ready" if ids.size() == 40 else "Incomplete"], 14, MUTED))
	_ignore_control_input(v)
	return b

func _show_faction_page() -> void:
	_page(false, true)

func _show_editor_page(fi: int, deck_name: String, ids: Array[String], is_saved: bool = false) -> void:
	_faction_idx = fi
	_deck_ids = ids.duplicate()
	_original_deck_name = deck_name if is_saved else ""
	_saved_deck_name = deck_name
	_saved_deck_ids = ids.duplicate()
	_page(false, false)
	_faction_label.text = DeckManager.FACTION_NAMES[fi]
	_faction_label.add_theme_color_override("font_color", DeckManager.FACTION_SWATCHES[fi].lightened(0.45))
	_name_edit.text = deck_name
	_status_lbl.text = ""
	_reset_filters()
	_refresh_deck()

func _reset_filters() -> void:
	_search_text = ""
	_search_bar.text = ""
	_color_filter = 0
	_type_filter = 0
	_cost_filter = -1
	_refresh_coll(true)

func _refresh_coll(reset_scroll: bool = false) -> void:
	_hide_preview_now()
	_clear_children(_coll_content)
	_cells.clear()
	var found := 0
	for color_idx in [_faction_idx, int(CardData.CardColor.GENERIC)]:
		if (_color_filter == 1 and color_idx != _faction_idx) or (_color_filter == 2 and color_idx == _faction_idx): continue
		var cards: Array[CardData] = []
		for c in CardDatabase.get_all_cards():
			if c.is_token or int(c.color) != color_idx: continue
			if _type_filter > 0 and int(c.card_type) != _type_filter - 1: continue
			if _cost_filter >= 0 and mini(c.cost, 7) != _cost_filter: continue
			if not _search_text.is_empty() and not (c.card_name.to_lower().contains(_search_text) or c.description.to_lower().contains(_search_text)): continue
			cards.append(c)
		cards.sort_custom(func(a: CardData, b: CardData): return a.cost < b.cost if a.cost != b.cost else a.card_name < b.card_name)
		if cards.is_empty(): continue
		found += cards.size()
		_coll_content.add_child(_label(DeckManager.FACTION_NAMES[color_idx] if color_idx == _faction_idx else "GENERICS", 14, MUTED, true))
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 10)
		flow.add_theme_constant_override("v_separation", 12)
		_coll_content.add_child(flow)
		for data in cards: _add_cell(flow, data)
	_result_lbl.text = "%d cards · Click to add. Preview to inspect." % found
	if found == 0:
		var empty := _label("No cards found.\nTry another search or reset your filters.", 18, MUTED)
		empty.custom_minimum_size.y = 120
		_coll_content.add_child(empty)
	for i in _source_buttons.size(): _source_buttons[i].set_pressed_no_signal(i == _color_filter)
	for i in _type_buttons.size(): _type_buttons[i].set_pressed_no_signal(i == _type_filter)
	for i in _cost_buttons.size(): _cost_buttons[i].set_pressed_no_signal(i - 1 == _cost_filter)
	_reset_btn.disabled = _search_text.is_empty() and _color_filter == 0 and _type_filter == 0 and _cost_filter == -1
	_update_cells()
	if reset_scroll: _coll_scroll.scroll_vertical = 0

func _add_cell(parent: Node, data: CardData) -> void:
	var cell := _vbox(parent, 4)
	cell.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var add := _button("", _add_card.bind(data), "Add " + data.card_name)
	add.custom_minimum_size = Card.PIXELS_MEDIUM + Vector2(12, 12)
	add.tooltip_text = data.card_name + " · Click to add"
	cell.add_child(add)
	var card: Card = CardScene.instantiate()
	add.add_child(card)
	card.apply_size(Card.Size.MEDIUM)
	card.position = Vector2(6, 6)
	card.input_pickable = false
	card.set_process_input(false)
	card.setup(data)
	_ignore_control_input(card)
	var footer := HBoxContainer.new()
	cell.add_child(footer)
	var copies := _label("", 13, MUTED)
	copies.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(copies)
	var preview := _button("Preview", _show_db_preview.bind(data, add), "Preview " + data.card_name)
	preview.add_theme_font_size_override("font_size", 12)
	preview.custom_minimum_size.y = 28
	footer.add_child(preview)
	preview.mouse_entered.connect(_show_db_preview.bind(data, preview))
	preview.mouse_exited.connect(_schedule_hide_preview)
	preview.focus_entered.connect(_show_db_preview.bind(data, preview))
	preview.focus_exited.connect(_schedule_hide_preview)
	_cells[data.id] = {"add": add, "copies": copies, "preview": preview}

func _add_card(data: CardData) -> void:
	if _deck_ids.size() >= DeckManager.MAX_DECK_SIZE or _deck_ids.count(data.id) >= DeckManager.max_copies_for(data): return
	_deck_ids.append(data.id)
	_refresh_deck()
	_update_cells()

func _update_cells() -> void:
	for id in _cells:
		var data := CardDatabase.get_card(id)
		var count := _deck_ids.count(id)
		var maximum := DeckManager.max_copies_for(data)
		_cells[id].add.disabled = count >= maximum or _deck_ids.size() >= DeckManager.MAX_DECK_SIZE
		_cells[id].copies.text = "%d / %d" % [count, maximum]

func _refresh_deck() -> void:
	_clear_children(_deck_content)
	_count_lbl.text = "%d / 40 · %s" % [_deck_ids.size(), "Ready" if _deck_ids.size() == 40 else "Incomplete"]
	var counts: Dictionary = {}
	var buckets: Array[int] = [0, 0, 0, 0, 0, 0, 0, 0]
	for id in _deck_ids:
		counts[id] = counts.get(id, 0) + 1
		var c := CardDatabase.get_card(id)
		if c != null: buckets[mini(c.cost, 7)] += 1
	var ids: Array = counts.keys()
	ids.sort_custom(func(a, b):
		var ca := CardDatabase.get_card(a)
		var cb := CardDatabase.get_card(b)
		return ca.cost < cb.cost if ca.cost != cb.cost else ca.card_name < cb.card_name
	)
	for id in ids:
		var data := CardDatabase.get_card(id)
		var row := _button("", _remove_card.bind(id), "Remove one " + data.card_name)
		row.tooltip_text = data.card_name + " · Remove one copy"
		_deck_content.add_child(row)
		var content := HBoxContainer.new()
		content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		content.offset_left = 10
		content.offset_right = -10
		content.add_theme_constant_override("separation", 10)
		row.add_child(content)
		content.add_child(_label(str(data.cost), 16, CYAN))
		var title := _label(data.card_name, 14)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		content.add_child(title)
		content.add_child(_label("×%d  −" % counts[id], 14, MUTED))
		row.mouse_entered.connect(_show_db_preview.bind(data, row))
		row.mouse_exited.connect(_schedule_hide_preview)
		row.focus_entered.connect(_show_db_preview.bind(data, row))
		row.focus_exited.connect(_schedule_hide_preview)
		_ignore_control_input(content)
	if ids.is_empty():
		var empty := _label("Your deck is empty.\nAdd cards from the collection.", 16, MUTED)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_deck_content.add_child(empty)
	for i in 8:
		_curve[i].max_value = maxi(1, buckets.max())
		_curve[i].value = buckets[i]
		_curve_counts[i].text = str(buckets[i])
		_curve[i].accessibility_description = "%d cards" % buckets[i]
	_update_save_state()

func _remove_card(id: String) -> void:
	var owner := get_viewport().gui_get_focus_owner()
	var restore := owner != null and owner.get_parent() == _deck_content
	var idx := owner.get_index() if restore else 0
	_deck_ids.erase(id)
	_hide_preview_now()
	_refresh_deck()
	_update_cells()
	if restore:
		if not _deck_ids.is_empty(): _deck_content.get_child(mini(idx, _deck_content.get_child_count() - 1)).grab_focus()
		else: _search_bar.grab_focus()

func _update_save_state() -> void:
	var renamed := not _original_deck_name.is_empty() and _name_edit.text.strip_edges() != _original_deck_name
	_save_btn.text = "Save as new deck" if renamed else "Save deck"
	_save_btn.accessibility_name = _save_btn.text
	_delete_btn.visible = not _original_deck_name.is_empty()
	_dirty_lbl.text = "Unsaved changes" if _has_unsaved_changes() else "No unsaved edits"

func _do_save() -> bool:
	var deck_name := _name_edit.text.strip_edges()
	if deck_name.is_empty() or deck_name.length() > 40:
		_status_lbl.text = "Use a deck name with 1–40 characters."
		_name_edit.grab_focus()
		return false
	DeckManager.save_deck(deck_name, _faction_idx, _deck_ids)
	_original_deck_name = deck_name
	_saved_deck_name = deck_name
	_saved_deck_ids = _deck_ids.duplicate()
	_name_edit.text = deck_name
	_status_lbl.text = ""
	_update_save_state()
	return true

func _has_unsaved_changes() -> bool:
	if _name_edit.text.strip_edges() != _saved_deck_name: return true
	var current: Dictionary = {}
	var saved: Dictionary = {}
	for id in _deck_ids: current[id] = current.get(id, 0) + 1
	for id in _saved_deck_ids: saved[id] = saved.get(id, 0) + 1
	return current != saved

func _do_delete() -> void:
	if _original_deck_name.is_empty(): return
	DeckManager.delete_deck(_original_deck_name)
	_show_hub_page()

func _go_back() -> void:
	if _editor_page.visible: _on_editor_back_pressed()
	elif _faction_page.visible: _show_hub_page()
	else: back_pressed.emit()

func _on_editor_back_pressed() -> void:
	_hide_preview_now()
	if _has_unsaved_changes(): _show_unsaved_changes_dialog()
	else: _show_hub_page()

func _show_unsaved_changes_dialog() -> void:
	if is_instance_valid(_prompt): return
	_return_focus = get_viewport().gui_get_focus_owner()
	_prompt = CanvasLayer.new()
	_prompt.layer = 20
	add_child(_prompt)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.8)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_prompt.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_prompt.add_child(center)
	var panel := PanelContainer.new()
	panel.theme = theme
	center.add_child(panel)
	var v := _vbox(panel, 20)
	v.add_child(_label("SAVE BEFORE EXITING?", 22, TEXT, true))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	v.add_child(actions)
	var save := _button("Save", func():
		_close_prompt(false)
		if _do_save(): _show_hub_page()
	, "Save and exit")
	var discard := _button("Discard", func():
		_close_prompt(false)
		_show_hub_page()
	, "Discard and exit")
	var cancel := _button("Cancel", _close_prompt, "Cancel exit")
	_prompt_buttons = [save, discard, cancel]
	for b in _prompt_buttons:
		b.custom_minimum_size.x = 110
		actions.add_child(b)
	for i in 3:
		var b := _prompt_buttons[i]
		b.focus_next = b.get_path_to(_prompt_buttons[(i + 1) % 3])
		b.focus_previous = b.get_path_to(_prompt_buttons[(i + 2) % 3])
		b.focus_neighbor_left = b.focus_previous
		b.focus_neighbor_right = b.focus_next
		b.focus_neighbor_top = NodePath(".")
		b.focus_neighbor_bottom = NodePath(".")
	cancel.grab_focus()

func _close_prompt(restore: bool = true) -> void:
	if is_instance_valid(_prompt):
		remove_child(_prompt)
		_prompt.queue_free()
	_prompt = null
	_prompt_buttons.clear()
	if restore and is_instance_valid(_return_focus) and _return_focus.is_visible_in_tree(): _return_focus.grab_focus()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.keycode == KEY_ESCAPE:
		if is_instance_valid(_prompt): _close_prompt()
		elif _preview_panel.visible: _hide_preview_now()
		else: _go_back()
		get_viewport().set_input_as_handled()
	elif not is_instance_valid(_prompt) and _editor_page.visible and event.ctrl_pressed:
		if event.keycode == KEY_S:
			_do_save()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F:
			_search_bar.grab_focus()
			get_viewport().set_input_as_handled()

func _build_preview() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_preview_panel = PanelContainer.new()
	_preview_panel.theme = theme
	layer.add_child(_preview_panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_preview_panel.add_child(row)
	var holder := Control.new()
	holder.custom_minimum_size = Card.PIXELS_LARGE
	row.add_child(holder)
	_preview_card_node = CardScene.instantiate()
	holder.add_child(_preview_card_node)
	_preview_card_node.apply_size(Card.Size.LARGE)
	_preview_card_node.input_pickable = false
	_preview_card_node.set_process_input(false)
	_ignore_control_input(_preview_card_node)
	var scroll := _scroll(row)
	scroll.custom_minimum_size = Vector2(KEYWORD_W, Card.PIXELS_LARGE.y)
	_preview_keyword_vbox = _vbox(scroll, 8)
	_preview_panel.mouse_entered.connect(func(): _hide_timer.stop())
	_preview_panel.mouse_exited.connect(_schedule_hide_preview)
	_hide_timer = Timer.new()
	_hide_timer.one_shot = true
	_hide_timer.wait_time = 0.12
	_hide_timer.timeout.connect(_hide_preview_now)
	add_child(_hide_timer)
	_preview_panel.hide()

func _show_db_preview(data: CardData, anchor: Control) -> void:
	if is_instance_valid(_prompt): return
	_hide_timer.stop()
	_preview_card_node.setup(data)
	_build_preview_keyword_blocks(data)
	_preview_panel.reset_size()
	var psize := _preview_panel.get_combined_minimum_size()
	var bounds := get_viewport_rect().size
	var pos := anchor.get_global_rect().end + Vector2(12, 0)
	if pos.x + psize.x > bounds.x - 12: pos.x = anchor.global_position.x - psize.x - 12
	_preview_panel.position = Vector2(clampf(pos.x, 12, maxf(12, bounds.x - psize.x - 12)), clampf(anchor.global_position.y, 12, maxf(12, bounds.y - psize.y - 12)))
	_preview_panel.show()

func _schedule_hide_preview() -> void:
	# Focus exits also fire while the screen's children leave the tree.
	if _hide_timer.is_inside_tree(): _hide_timer.start()

func _hide_preview_now() -> void:
	if is_instance_valid(_hide_timer): _hide_timer.stop()
	if is_instance_valid(_preview_panel): _preview_panel.hide()

func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()
func _load_keywords() -> void:
	var file := FileAccess.open("res://data/keywords.json", FileAccess.READ)
	if not file:
		return
	var result = JSON.parse_string(file.get_as_text())
	file.close()
	if result is Dictionary:
		_keywords = result


func _build_preview_keyword_blocks(data: CardData) -> void:
	_clear_preview_keyword_blocks()
	var heading := _label(data.card_name, 18)
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_keyword_vbox.add_child(heading)
	_preview_keyword_vbox.add_child(_label("%d mana · %s" % [data.cost, "Creature" if data.card_type == CardData.CardType.CREATURE else "Stratagem"], 14, MUTED))
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
	pc.custom_minimum_size = Vector2(KEYWORD_W, 0)
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.10, 0.10, 0.14, 0.95)
	s.border_color = accent
	s.set_border_width_all(2)
	s.set_corner_radius_all(6)
	s.content_margin_left = 8; s.content_margin_right = 8
	s.content_margin_top = 6;  s.content_margin_bottom = 6
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
