class_name DeckBuilderScreen
extends Control

signal back_pressed

const CARD_W := 72
const CARD_H := 100
const STACK_OFFSET := 6
const COLL_W := 110
const COLL_H := 170
const DECK_BG  := Color(0.09, 0.07, 0.05)
const SEARCH_BG := Color(0.11, 0.09, 0.07)
const COLL_BG  := Color(0.07, 0.05, 0.04)
const TOOLBAR_BG := Color(0.08, 0.06, 0.05)

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
@onready var _coll_content: VBoxContainer = $EditorPage/CollectionPanel/CollScroll/CollContent

# ── Setup ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_apply_styles()
	_build_faction_buttons()
	_setup_filter_box()
	_setup_delete_button()

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

		var ns := StyleBoxFlat.new()
		ns.bg_color = sw.darkened(0.3); ns.set_corner_radius_all(10)
		ns.border_width_bottom = 4; ns.border_color = sw.darkened(0.15)
		btn.add_theme_stylebox_override("normal", ns)
		var hs := StyleBoxFlat.new()
		hs.bg_color = sw.lightened(0.1); hs.set_corner_radius_all(10)
		hs.border_width_bottom = 4; hs.border_color = sw
		btn.add_theme_stylebox_override("hover", hs)
		var ps := StyleBoxFlat.new()
		ps.bg_color = sw.darkened(0.2); ps.set_corner_radius_all(10)
		btn.add_theme_stylebox_override("pressed", ps)

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
	btn.custom_minimum_size = Vector2(CARD_W + STACK_OFFSET, CARD_H + STACK_OFFSET)

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
	panel.size = Vector2(CARD_W, CARD_H)
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
		flow.add_child(_coll_card(card, counts.get(card.id, 0), deck_full))

func _coll_card(card: CardData, in_deck: int, deck_full: bool) -> Button:
	var sw: Color = DeckManager.FACTION_SWATCHES[int(card.color)]
	var max_copies := DeckManager.max_copies_for(card)
	var maxed := in_deck >= max_copies or deck_full

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(COLL_W, COLL_H)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.disabled = maxed
	btn.tooltip_text = card.card_name

	var ns := StyleBoxFlat.new()
	ns.bg_color = sw.darkened(0.5 if maxed else 0.3); ns.set_corner_radius_all(6)
	ns.border_width_top = 2; ns.border_color = sw.darkened(0.3) if maxed else sw
	btn.add_theme_stylebox_override("normal", ns)
	var hs := StyleBoxFlat.new()
	hs.bg_color = sw.darkened(0.1); hs.set_corner_radius_all(6)
	hs.border_width_top = 2; hs.border_color = sw.lightened(0.2)
	btn.add_theme_stylebox_override("hover", hs)
	var ds := StyleBoxFlat.new()
	ds.bg_color = sw.darkened(0.65); ds.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("disabled", ds)

	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.add_theme_constant_override("separation", 2)
	btn.add_child(vb)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 2)
	vb.add_child(top)

	var cost_lbl := Label.new()
	cost_lbl.text = str(card.cost)
	cost_lbl.add_theme_font_size_override("font_size", 16)
	cost_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(cost_lbl)

	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(sp)

	var badge := Label.new()
	badge.text = "%d/%d" % [in_deck, max_copies]
	badge.add_theme_font_size_override("font_size", 10)
	badge.add_theme_color_override("font_color",
		Color(0.95, 0.85, 0.3) if in_deck > 0 else Color(0.45, 0.45, 0.45))
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(badge)

	var name_lbl := Label.new()
	name_lbl.text = card.card_name
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(name_lbl)

	var type_lbl := Label.new()
	type_lbl.text = "Creature" if card.card_type == CardData.CardType.CREATURE else "Stratagem"
	type_lbl.add_theme_font_size_override("font_size", 9)
	type_lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	type_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	type_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(type_lbl)

	if not card.description.is_empty():
		var desc_lbl := Label.new()
		desc_lbl.text = card.description
		desc_lbl.add_theme_font_size_override("font_size", 9)
		desc_lbl.add_theme_color_override("font_color", Color(0.85, 0.80, 0.60))
		desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
		desc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(desc_lbl)

	if card.card_type == CardData.CardType.CREATURE:
		var stats := Label.new()
		stats.text = "%d / %d" % [card.attack, card.health]
		stats.add_theme_font_size_override("font_size", 12)
		stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(stats)

	btn.pressed.connect(func():
		if _deck_ids.size() < DeckManager.MAX_DECK_SIZE and _deck_ids.count(card.id) < DeckManager.max_copies_for(card):
			_deck_ids.append(card.id)
			_refresh_deck()
			_refresh_coll()
	)
	return btn

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
