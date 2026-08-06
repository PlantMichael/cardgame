class_name DeckBuilderScreen
extends Control

signal back_pressed

const CardScene := preload("res://scenes/cards/Card.tscn")

const COLL_CARD_SCALE := 0.5
const COLL_W := 110
const COLL_H := 160
const STACK_OFFSET := 6
const DECK_W := 72
const DECK_H := 100
const DECK_BG  := Color(0.09, 0.07, 0.05)
const SEARCH_BG := Color(0.11, 0.09, 0.07)
const COLL_BG  := Color(0.07, 0.05, 0.04)
const TOOLBAR_BG := Color(0.08, 0.06, 0.05)
const PREVIEW_SCALE := 1.155
const KEYWORD_W := 238.0

# ── State ──────────────────────────────────────────────────────────────────
var _faction_idx: int = -1
var _deck_ids: Array[String] = []
var _deck_name: String = "My Deck"
var _original_deck_name: String = ""
var _search_text: String = ""
var _color_filter: int = 0  # 0 = all, 1 = faction only, 2 = generic only
var _filter_btns: Array[Button] = []
var _filter_box: HBoxContainer = null
var _delete_btn: Button = null
var _keywords: Dictionary = {}
var _preview_card_node: Card = null
var _hide_preview_scheduled: bool = false

# ── Hub page ───────────────────────────────────────────────────────────────
@onready var _hub_page: Control = $HubPage
@onready var _hub_deck_flow: HFlowContainer = $HubPage/DeckScrollArea/DeckMargin/DeckFlow

# ── Faction picker page ────────────────────────────────────────────────────
@onready var _faction_page: Control = $FactionPage
@onready var _faction_hbox: HBoxContainer = $FactionPage/Center/VBox/FactionHBox

# ── Editor page ────────────────────────────────────────────────────────────
@onready var _editor_page: Control = $EditorPage
@onready var _faction_label: Label = $EditorPage/TopSection/EditorToolbar/HBoxContainer/FactionLabel
@onready var _name_edit: LineEdit = $EditorPage/TopSection/EditorToolbar/HBoxContainer/NameEdit
@onready var _count_lbl: Label = $EditorPage/TopSection/EditorToolbar/HBoxContainer/CountLabel
@onready var _search_faction_lbl: Label = $EditorPage/TopSection/SearchStrip/HBoxContainer/FactionLabel
@onready var _search_bar: LineEdit = $EditorPage/TopSection/SearchStrip/HBoxContainer/SearchBar
@onready var _deck_content: HBoxContainer = $EditorPage/TopSection/DeckPanel/DeckScroll/DeckContent
@onready var _coll_content: VBoxContainer = $EditorPage/CollectionPanel/CollHBox/CollScroll/CollContent
@onready var _preview_card_holder: Control = $EditorPage/CollectionPanel/CollHBox/PreviewSection/PreviewCardHolder
@onready var _preview_keyword_vbox: VBoxContainer = $EditorPage/CollectionPanel/CollHBox/PreviewSection/PreviewKeywordScroll/PreviewKeywordVBox

# ── Setup ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_apply_styles()
	_build_faction_buttons()
	_setup_filter_box()
	_setup_delete_button()
	_load_keywords()
	_setup_preview_card()

	$HubPage/Toolbar/HBoxContainer/BackButton.pressed.connect(func(): back_pressed.emit())
	$HubPage/Toolbar/HBoxContainer/NewDeckButton.pressed.connect(_show_faction_page)
	$FactionPage/Toolbar/HBoxContainer/BackButton.pressed.connect(_show_hub_page)
	$EditorPage/TopSection/EditorToolbar/HBoxContainer/BackButton.pressed.connect(_show_hub_page)
	$EditorPage/TopSection/EditorToolbar/HBoxContainer/SaveButton.pressed.connect(_do_save)
	$EditorPage/TopSection/EditorToolbar/HBoxContainer/ClearButton.pressed.connect(func():
		_deck_ids.clear()
		_refresh_deck()
		_refresh_coll()
	)
	_name_edit.text_changed.connect(func(t: String): _deck_name = t)
	_search_bar.text_changed.connect(func(t: String):
		_search_text = t.to_lower()
		_refresh_coll()
	)

	_show_hub_page()

func _load_keywords() -> void:
	var file := FileAccess.open("res://data/keywords.json", FileAccess.READ)
	if not file:
		return
	var result = JSON.parse_string(file.get_as_text())
	file.close()
	if result is Dictionary:
		_keywords = result

func _setup_preview_card() -> void:
	_preview_card_node = CardScene.instantiate()
	_preview_card_node.scale = Vector2(PREVIEW_SCALE, PREVIEW_SCALE)
	_preview_card_node.position = Vector2(0, 0)
	_preview_card_node.input_pickable = false
	_preview_card_node.set_process_input(false)
	_preview_card_holder.add_child(_preview_card_node)
	_ignore_control_input(_preview_card_node)
	_preview_card_node.modulate = Color(1, 1, 1, 0)

func _setup_delete_button() -> void:
	var hbox := $EditorPage/TopSection/EditorToolbar/HBoxContainer
	_delete_btn = Button.new()
	_delete_btn.text = "Delete"
	_delete_btn.add_theme_color_override("font_color", Color(1.0, 0.40, 0.40))
	_delete_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.60, 0.60))
	var ns := StyleBoxFlat.new()
	ns.bg_color = Color(0.32, 0.08, 0.08); ns.set_corner_radius_all(4)
	_delete_btn.add_theme_stylebox_override("normal", ns)
	var hs := StyleBoxFlat.new()
	hs.bg_color = Color(0.48, 0.12, 0.12); hs.set_corner_radius_all(4)
	_delete_btn.add_theme_stylebox_override("hover", hs)
	_delete_btn.hide()
	_delete_btn.pressed.connect(_do_delete)
	hbox.add_child(_delete_btn)

func _apply_styles() -> void:
	var mk := func(c: Color) -> StyleBoxFlat:
		var s := StyleBoxFlat.new(); s.bg_color = c; return s

	$HubPage/Toolbar.add_theme_stylebox_override("panel", mk.call(TOOLBAR_BG))
	$FactionPage/Toolbar.add_theme_stylebox_override("panel", mk.call(TOOLBAR_BG))
	$EditorPage/TopSection/EditorToolbar.add_theme_stylebox_override("panel", mk.call(TOOLBAR_BG))
	$EditorPage/TopSection/SearchStrip.add_theme_stylebox_override("panel", mk.call(SEARCH_BG))

	var deck_s := StyleBoxFlat.new()
	deck_s.bg_color = DECK_BG
	deck_s.content_margin_left = 10; deck_s.content_margin_right = 10
	deck_s.content_margin_top = 8;   deck_s.content_margin_bottom = 8
	$EditorPage/TopSection/DeckPanel.add_theme_stylebox_override("panel", deck_s)

	var coll_s := StyleBoxFlat.new()
	coll_s.bg_color = COLL_BG
	coll_s.content_margin_left = 12; coll_s.content_margin_right = 12
	coll_s.content_margin_top = 10;  coll_s.content_margin_bottom = 10
	$EditorPage/CollectionPanel.add_theme_stylebox_override("panel", coll_s)

func _setup_filter_box() -> void:
	_filter_box = HBoxContainer.new()
	_filter_box.add_theme_constant_override("separation", 4)
	var strip_hbox := $EditorPage/TopSection/SearchStrip/HBoxContainer
	strip_hbox.add_child(_filter_box)
	strip_hbox.move_child(_filter_box, 1)

func _build_faction_buttons() -> void:
	for i in DeckManager.FACTION_NAMES.size():
		var sw: Color = DeckManager.FACTION_SWATCHES[i]
		var btn := Button.new()
		btn.text = DeckManager.FACTION_NAMES[i]
		btn.custom_minimum_size = Vector2(0, 80)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 18)

		var bns := StyleBoxFlat.new()
		bns.bg_color = sw.darkened(0.3); bns.set_corner_radius_all(10)
		bns.border_width_bottom = 4; bns.border_color = sw.darkened(0.15)
		btn.add_theme_stylebox_override("normal", bns)
		var bhs := StyleBoxFlat.new()
		bhs.bg_color = sw.lightened(0.1); bhs.set_corner_radius_all(10)
		bhs.border_width_bottom = 4; bhs.border_color = sw
		btn.add_theme_stylebox_override("hover", bhs)
		var bps := StyleBoxFlat.new()
		bps.bg_color = sw.darkened(0.2); bps.set_corner_radius_all(10)
		btn.add_theme_stylebox_override("pressed", bps)

		_faction_hbox.add_child(btn)
		var idx := i
		btn.pressed.connect(func(): _show_editor_page(idx, "My Deck", []))

# ── Page switching ─────────────────────────────────────────────────────────

func _show_hub_page() -> void:
	_hub_page.visible = true
	_faction_page.visible = false
	_editor_page.visible = false
	_faction_idx = -1
	_deck_ids.clear()
	_search_text = ""
	_rebuild_hub_list()

func _show_faction_page() -> void:
	_hub_page.visible = false
	_faction_page.visible = true
	_editor_page.visible = false

func _show_editor_page(faction_idx: int, deck_name: String, initial_ids: Array[String], is_saved: bool = false) -> void:
	_faction_idx = faction_idx
	_deck_name = deck_name
	_original_deck_name = deck_name if is_saved else ""
	_deck_ids = initial_ids.duplicate()
	_search_text = ""
	_color_filter = 0

	_hub_page.visible = false
	_faction_page.visible = false
	_editor_page.visible = true

	var sw: Color = DeckManager.FACTION_SWATCHES[faction_idx]
	_faction_label.text = DeckManager.FACTION_NAMES[faction_idx]
	_faction_label.add_theme_color_override("font_color", sw.lightened(0.4))
	_search_faction_lbl.text = DeckManager.FACTION_NAMES[faction_idx]
	_search_faction_lbl.add_theme_color_override("font_color", sw.lightened(0.3))
	_name_edit.text = deck_name
	_search_bar.text = ""

	if _delete_btn:
		_delete_btn.visible = is_saved

	_rebuild_filter_buttons()
	_refresh_deck()
	_refresh_coll()

# ── Filter buttons ─────────────────────────────────────────────────────────

func _rebuild_filter_buttons() -> void:
	for c in _filter_box.get_children():
		c.queue_free()
	_filter_btns.clear()

	var labels := ["All", DeckManager.FACTION_NAMES[_faction_idx], "Generic"]
	for i in labels.size():
		var btn := Button.new()
		btn.text = labels[i]
		btn.custom_minimum_size = Vector2(74, 28)
		btn.add_theme_font_size_override("font_size", 11)
		_filter_box.add_child(btn)
		_filter_btns.append(btn)
		var filter_val := i
		btn.pressed.connect(func():
			_color_filter = filter_val
			_update_filter_btns()
			_refresh_coll()
		)
	_update_filter_btns()

func _update_filter_btns() -> void:
	var generic_sw: Color = DeckManager.FACTION_SWATCHES[int(CardData.CardColor.GENERIC)]
	var faction_sw: Color = DeckManager.FACTION_SWATCHES[_faction_idx]
	var border_colors := [Color(0.55, 0.55, 0.65), faction_sw, generic_sw]

	for i in _filter_btns.size():
		var btn := _filter_btns[i]
		var active := i == _color_filter

		var ns := StyleBoxFlat.new()
		ns.set_corner_radius_all(4)
		ns.border_width_bottom = 2
		ns.bg_color = Color(0.22, 0.20, 0.18) if active else Color(0.14, 0.12, 0.10)
		ns.border_color = border_colors[i] if active else Color(0.20, 0.18, 0.16)
		btn.add_theme_stylebox_override("normal", ns)
		btn.add_theme_stylebox_override("pressed", ns)

		var hs := StyleBoxFlat.new()
		hs.set_corner_radius_all(4)
		hs.border_width_bottom = 2
		hs.bg_color = ns.bg_color.lightened(0.08)
		hs.border_color = ns.border_color
		btn.add_theme_stylebox_override("hover", hs)

		var font_color := Color(1.0, 1.0, 1.0) if active else Color(0.55, 0.55, 0.55)
		btn.add_theme_color_override("font_color", font_color)
		btn.add_theme_color_override("font_hover_color", Color(0.9, 0.9, 0.9))
		btn.add_theme_color_override("font_pressed_color", font_color)

# ── Hub deck list ──────────────────────────────────────────────────────────

func _rebuild_hub_list() -> void:
	for c in _hub_deck_flow.get_children():
		c.queue_free()

	var custom := DeckManager.get_custom_decks()
	print("[deck debug] rebuilding hub list, custom=%s" % [custom])
	if custom.is_empty():
		var hint := Label.new()
		hint.text = "No saved decks yet. Click '+ New Deck' to get started."
		hint.add_theme_font_size_override("font_size", 18)
		hint.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_hub_deck_flow.add_child(hint)
	else:
		for deck in custom:
			_hub_deck_flow.add_child(_hub_deck_card(deck))

func _hub_deck_card(deck: Dictionary) -> Control:
	var fi: int = int(deck.get("faction_idx", 0))
	var sw: Color = DeckManager.FACTION_SWATCHES[fi]
	var dname: String = str(deck.get("name", "Unknown"))
	var count: int = (deck.get("card_ids", []) as Array).size()

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(240, 140)
	btn.clip_contents = true

	var ns := StyleBoxFlat.new()
	ns.bg_color = sw.darkened(0.4); ns.set_corner_radius_all(10)
	ns.border_width_left = 4; ns.border_color = sw
	btn.add_theme_stylebox_override("normal", ns)
	var hs := StyleBoxFlat.new()
	hs.bg_color = sw.darkened(0.2); hs.set_corner_radius_all(10)
	hs.border_width_left = 4; hs.border_color = sw.lightened(0.2)
	btn.add_theme_stylebox_override("hover", hs)
	var ps := StyleBoxFlat.new()
	ps.bg_color = sw.darkened(0.5); ps.set_corner_radius_all(10)
	btn.add_theme_stylebox_override("pressed", ps)

	var inner := VBoxContainer.new()
	inner.set_anchors_preset(Control.PRESET_FULL_RECT)
	inner.alignment = BoxContainer.ALIGNMENT_CENTER
	inner.add_theme_constant_override("separation", 5)
	btn.add_child(inner)

	var name_lbl := Label.new()
	name_lbl.text = dname
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(name_lbl)

	var info := Label.new()
	info.text = "%s  •  %d cards" % [DeckManager.FACTION_NAMES[fi], count]
	info.add_theme_font_size_override("font_size", 12)
	info.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(info)

	btn.pressed.connect(func():
		var ids: Array[String] = []
		for id in deck.get("card_ids", []):
			ids.append(str(id))
		_show_editor_page(fi, dname, ids, true)
	)
	return btn

# ── Deck view refresh ──────────────────────────────────────────────────────

func _refresh_deck() -> void:
	for c in _deck_content.get_children():
		c.queue_free()
	_count_lbl.text = "%d / %d" % [_deck_ids.size(), DeckManager.MAX_DECK_SIZE]

	var counts: Dictionary = {}
	for id in _deck_ids:
		counts[id] = counts.get(id, 0) + 1

	var uniq: Array = counts.keys()
	uniq.sort_custom(func(a, b) -> bool:
		var ca: CardData = CardDatabase.get_card(a)
		var cb: CardData = CardDatabase.get_card(b)
		if ca == null or cb == null: return false
		return ca.cost < cb.cost if ca.cost != cb.cost else ca.card_name < cb.card_name
	)

	var by_bucket: Dictionary = {}
	for id in uniq:
		var card: CardData = CardDatabase.get_card(id)
		if card == null: continue
		var bucket := mini(card.cost, 8)
		if not by_bucket.has(bucket): by_bucket[bucket] = []
		by_bucket[bucket].append(id)

	for col in range(1, 9):
		var vcol := VBoxContainer.new()
		vcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vcol.add_theme_constant_override("separation", 4)
		_deck_content.add_child(vcol)

		var hdr := Label.new()
		hdr.text = str(col) if col < 8 else "8+"
		hdr.add_theme_font_size_override("font_size", 12)
		hdr.add_theme_color_override("font_color", Color(0.50, 0.50, 0.50))
		hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vcol.add_child(hdr)

		var sep := HSeparator.new()
		sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vcol.add_child(sep)

		for id in by_bucket.get(col, []):
			var card: CardData = CardDatabase.get_card(id)
			var stack := _deck_stack(card, counts[id])
			stack.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			vcol.add_child(stack)

		var fill := Control.new()
		fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vcol.add_child(fill)

func _deck_stack(card: CardData, count: int) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(DECK_W + STACK_OFFSET, DECK_H + STACK_OFFSET)

	var trans := StyleBoxFlat.new(); trans.bg_color = Color(0, 0, 0, 0)
	var hover_s := StyleBoxFlat.new()
	hover_s.bg_color = Color(1, 1, 1, 0.12); hover_s.set_corner_radius_all(5)
	for state in ["normal", "pressed", "disabled", "focus"]:
		btn.add_theme_stylebox_override(state, trans)
	btn.add_theme_stylebox_override("hover", hover_s)

	if count >= 2:
		var back := _mini_card(card, true)
		back.position = Vector2(STACK_OFFSET, STACK_OFFSET)
		btn.add_child(back)

	var front := _mini_card(card, false)
	front.position = Vector2(0, 0)
	btn.add_child(front)

	btn.tooltip_text = "%s (%dx) — click to remove" % [card.card_name, count]
	btn.pressed.connect(func():
		_deck_ids.erase(card.id)
		_refresh_deck()
		_refresh_coll()
	)
	return btn

func _mini_card(card: CardData, is_back: bool) -> Panel:
	var sw: Color = DeckManager.FACTION_SWATCHES[int(card.color)]
	var panel := Panel.new()
	panel.size = Vector2(DECK_W, DECK_H)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var s := StyleBoxFlat.new()
	s.bg_color = sw.darkened(0.5 if is_back else 0.3)
	s.set_corner_radius_all(5); s.border_width_top = 1; s.border_color = sw.darkened(0.2)
	panel.add_theme_stylebox_override("panel", s)

	if not is_back:
		var vb := VBoxContainer.new()
		vb.set_anchors_preset(Control.PRESET_FULL_RECT)
		vb.add_theme_constant_override("separation", 2)
		vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(vb)

		var cost_lbl := Label.new()
		cost_lbl.text = str(card.cost)
		cost_lbl.add_theme_font_size_override("font_size", 13)
		cost_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(cost_lbl)

		var name_lbl := Label.new()
		name_lbl.text = card.card_name
		name_lbl.add_theme_font_size_override("font_size", 9)
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(name_lbl)

		if not card.description.is_empty():
			var desc := Label.new()
			desc.text = card.description
			desc.add_theme_font_size_override("font_size", 7)
			desc.add_theme_color_override("font_color", Color(0.85, 0.80, 0.60))
			desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
			desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
			vb.add_child(desc)

		var stats := Label.new()
		stats.text = "%d/%d" % [card.attack, card.health] if card.card_type == CardData.CardType.CREATURE else "STRAT"
		stats.add_theme_font_size_override("font_size", 9)
		stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(stats)

	return panel

# ── Collection refresh ─────────────────────────────────────────────────────

func _refresh_coll() -> void:
	for c in _coll_content.get_children():
		c.queue_free()

	var counts: Dictionary = {}
	for id in _deck_ids:
		counts[id] = counts.get(id, 0) + 1

	var generic_idx := int(CardData.CardColor.GENERIC)
	var deck_full := _deck_ids.size() >= DeckManager.MAX_DECK_SIZE
	var all_cards := CardDatabase.get_all_cards()

	var sort_fn := func(a: CardData, b: CardData) -> bool:
		return a.cost < b.cost if a.cost != b.cost else a.card_name < b.card_name

	var matches_search := func(c: CardData) -> bool:
		return _search_text == "" \
			or c.card_name.to_lower().contains(_search_text) \
			or c.description.to_lower().contains(_search_text)

	if _color_filter != 2:
		var faction_cards: Array[CardData] = all_cards.filter(func(c: CardData) -> bool:
			return not c.is_token and int(c.color) == _faction_idx and matches_search.call(c)
		)
		faction_cards.sort_custom(sort_fn)
		if not faction_cards.is_empty():
			_add_coll_section(DeckManager.FACTION_NAMES[_faction_idx], faction_cards, counts, deck_full)

	if _color_filter != 1:
		var generic_cards: Array[CardData] = all_cards.filter(func(c: CardData) -> bool:
			return not c.is_token and int(c.color) == generic_idx and matches_search.call(c)
		)
		generic_cards.sort_custom(sort_fn)
		if not generic_cards.is_empty():
			_add_coll_section("GENERIC", generic_cards, counts, deck_full)

func _add_coll_section(title: String, cards: Array[CardData], counts: Dictionary, deck_full: bool) -> void:
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.60))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_coll_content.add_child(lbl)

	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 8)
	flow.add_theme_constant_override("v_separation", 8)
	_coll_content.add_child(flow)

	for card in cards:
		var result := _coll_card(card, counts.get(card.id, 0), deck_full)
		var btn: Button = result["btn"]
		var card_node: Card = result["card_node"]
		flow.add_child(btn)
		# btn is now in the scene tree — add card_node here so _ready() fires
		btn.add_child(card_node)
		card_node.setup(card)
		_ignore_control_input(card_node)
		if result["maxed"]:
			card_node.modulate = Color(0.45, 0.45, 0.45, 0.85)

func _coll_card(card: CardData, in_deck: int, deck_full: bool) -> Dictionary:
	var max_copies := DeckManager.max_copies_for(card)
	var maxed := in_deck >= max_copies or deck_full

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(COLL_W, COLL_H)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.clip_contents = true

	var trans := StyleBoxFlat.new(); trans.bg_color = Color(0, 0, 0, 0)
	var hover_s := StyleBoxFlat.new()
	hover_s.bg_color = Color(1, 1, 1, 0.18); hover_s.set_corner_radius_all(4)
	for state in ["normal", "pressed", "disabled", "focus"]:
		btn.add_theme_stylebox_override(state, trans)
	btn.add_theme_stylebox_override("hover", hover_s)

	var card_node: Card = CardScene.instantiate()
	card_node.scale = Vector2(COLL_CARD_SCALE, COLL_CARD_SCALE)
	card_node.position = Vector2(0, 0)
	card_node.input_pickable = false
	card_node.set_process_input(false)
	# card_node is NOT added to btn here — _add_coll_section does it after
	# flow.add_child(btn) so that btn is live in the tree first.

	var badge := Label.new()
	badge.text = "%d/%d" % [in_deck, max_copies]
	badge.add_theme_font_size_override("font_size", 11)
	badge.add_theme_color_override("font_color",
		Color(0.95, 0.85, 0.3) if in_deck > 0 else Color(0.4, 0.4, 0.4))
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	badge.position = Vector2(COLL_W - 38, COLL_H - 18)
	badge.size = Vector2(34, 16)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(badge)

	btn.mouse_entered.connect(func(): _show_db_preview(card))
	btn.mouse_exited.connect(func(): _hide_db_preview())

	btn.pressed.connect(func():
		if not maxed:
			_deck_ids.append(card.id)
			_refresh_deck()
			_refresh_coll()
	)
	return {"btn": btn, "card_node": card_node, "maxed": maxed}

# ── Card preview panel ─────────────────────────────────────────────────────

func _show_db_preview(data: CardData) -> void:
	_hide_preview_scheduled = false
	if _preview_card_node:
		_preview_card_node.setup(data)
		_preview_card_node.modulate = Color(1, 1, 1, 1)
	_build_preview_keyword_blocks(data)

func _hide_db_preview() -> void:
	_hide_preview_scheduled = true
	await get_tree().create_timer(0.06).timeout
	if _hide_preview_scheduled:
		if _preview_card_node:
			_preview_card_node.modulate = Color(1, 1, 1, 0)
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

# ── Save / Delete ──────────────────────────────────────────────────────────

func _do_save() -> void:
	var name := _name_edit.text.strip_edges()
	if name.is_empty(): return
	_deck_name = name
	DeckManager.save_deck(_deck_name, _faction_idx, _deck_ids)

func _do_delete() -> void:
	if _original_deck_name.is_empty():
		return
	DeckManager.delete_deck(_original_deck_name)
	_show_hub_page()
