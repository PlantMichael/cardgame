class_name ShopScreen
extends Control

## Shop UI (User Stories 2 & 4): lists purchasable packs and lets the player
## craft a specific card with dust. Pure presentation - all balance/roll
## decisions come back from Economy (which only ever reflects server-
## confirmed results), per Constitution Principle I.

signal back_pressed
## Emitted once a purchase succeeds, so main.gd can hand the result off to
## PackOpenScreen (this screen doesn't animate the reveal itself).
signal pack_opened_ready(cards: Array, dust_awarded: int)

const TOOLBAR_BG := Color(0.08, 0.06, 0.05)
const CONTENT_BG := Color(0.07, 0.05, 0.04)
const CRAFT_PANEL_BG := Color(0.10, 0.08, 0.07)

## Display-only mirror of relay.js's CRAFT_COST_BY_RARITY - the server is
## the sole authority on the actual charge; this just lets the button show a
## cost before the player commits.
const CRAFT_COST_BY_RARITY := {
	CardData.CardRarity.COMMON: 40,
	CardData.CardRarity.RARE: 100,
	CardData.CardRarity.EPIC: 400,
	CardData.CardRarity.LEGENDARY: 1600,
}

var _packs: Array = []
var _status_lbl: Label
var _balance_lbl: Label
var _buy_buttons: Dictionary = {}  # pack_id -> Button
var _craft_option: OptionButton
var _craft_btn: Button
var _craft_status_lbl: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_load_packs()
	_build_ui()
	Economy.balance_changed.connect(_update_balance_lbl)
	Economy.pack_purchase_failed.connect(_on_purchase_failed)
	Economy.pack_opened.connect(_on_pack_opened)
	Economy.craft_failed.connect(_on_craft_failed)
	Economy.card_crafted.connect(_on_card_crafted)
	Economy.request_state()

func _load_packs() -> void:
	var file := FileAccess.open("res://data/shop_packs.json", FileAccess.READ)
	if not file:
		push_error("Could not open res://data/shop_packs.json")
		return
	var result = JSON.parse_string(file.get_as_text())
	file.close()
	if result is Array:
		_packs = result

# ── UI construction ────────────────────────────────────────────────────────

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	root.add_child(_build_toolbar())

	_status_lbl = Label.new()
	_status_lbl.add_theme_color_override("font_color", Color(0.95, 0.4, 0.4))
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_lbl.visible = false
	root.add_child(_status_lbl)

	var content_panel := PanelContainer.new()
	content_panel.add_theme_stylebox_override("panel", _flat(CONTENT_BG))
	content_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(content_panel)

	var content_vbox := VBoxContainer.new()
	content_vbox.add_theme_constant_override("separation", 24)
	content_panel.add_child(content_vbox)

	var packs_flow := HFlowContainer.new()
	packs_flow.add_theme_constant_override("h_separation", 20)
	packs_flow.add_theme_constant_override("v_separation", 20)
	content_vbox.add_child(packs_flow)
	for pack in _packs:
		packs_flow.add_child(_pack_card(pack))

	content_vbox.add_child(HSeparator.new())
	content_vbox.add_child(_build_craft_panel())

func _build_toolbar() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _flat(TOOLBAR_BG))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	panel.add_child(row)

	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(90, 38)
	back_btn.pressed.connect(func(): back_pressed.emit())
	row.add_child(back_btn)

	var title := Label.new()
	title.text = "SHOP"
	title.add_theme_font_size_override("font_size", 22)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(title)

	_balance_lbl = Label.new()
	_balance_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_balance_lbl)
	_update_balance_lbl()

	return panel

func _update_balance_lbl() -> void:
	if is_instance_valid(_balance_lbl):
		_balance_lbl.text = "   Cyllats: %d   Glimmer: %d" % [Economy.currency, Economy.dust]

func _pack_card(pack: Dictionary) -> Control:
	var pack_id := str(pack.get("pack_id", ""))
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(220, 160)
	panel.add_theme_stylebox_override("panel", _flat(Color(0.12, 0.10, 0.08)))

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var name_lbl := Label.new()
	name_lbl.text = str(pack.get("display_name", "Pack"))
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(name_lbl)

	var count_lbl := Label.new()
	count_lbl.text = "%d cards" % int(pack.get("card_count", 5))
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(count_lbl)

	var buy_btn := Button.new()
	buy_btn.text = "Buy - %d Cyllats" % int(pack.get("price", 0))
	buy_btn.pressed.connect(_on_buy_pressed.bind(pack_id))
	vbox.add_child(buy_btn)
	_buy_buttons[pack_id] = buy_btn

	return panel

# ── Crafting panel (User Story 4) ──────────────────────────────────────────

func _build_craft_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _flat(CRAFT_PANEL_BG))

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "CRAFT A CARD"
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vbox.add_child(row)

	_craft_option = OptionButton.new()
	_craft_option.custom_minimum_size = Vector2(280, 0)
	var cards := CardDatabase.get_all_cards()
	cards.sort_custom(func(a, b): return a.card_name < b.card_name)
	for card in cards:
		if card.is_token:
			continue
		_craft_option.add_item(card.card_name)
		_craft_option.set_item_metadata(_craft_option.item_count - 1, card.id)
	_craft_option.item_selected.connect(func(_i): _update_craft_button())
	row.add_child(_craft_option)

	_craft_btn = Button.new()
	_craft_btn.pressed.connect(_on_craft_pressed)
	row.add_child(_craft_btn)
	_update_craft_button()

	_craft_status_lbl = Label.new()
	_craft_status_lbl.add_theme_color_override("font_color", Color(0.95, 0.4, 0.4))
	_craft_status_lbl.visible = false
	vbox.add_child(_craft_status_lbl)

	return panel

func _selected_card_id() -> String:
	if _craft_option.item_count == 0:
		return ""
	return str(_craft_option.get_item_metadata(_craft_option.selected))

func _craft_cost_for(card_id: String) -> int:
	var data := CardDatabase.get_card(card_id)
	if data == null:
		return 0
	return int(CRAFT_COST_BY_RARITY.get(data.rarity, 0))

func _update_craft_button() -> void:
	var cost := _craft_cost_for(_selected_card_id())
	_craft_btn.text = "Craft (%d Glimmer)" % cost

func _on_craft_pressed() -> void:
	var card_id := _selected_card_id()
	if card_id.is_empty():
		return
	_craft_status_lbl.visible = false
	_craft_btn.disabled = true
	Economy.craft_card(card_id)

func _on_craft_failed(message: String, dust_needed: int) -> void:
	_craft_btn.disabled = false
	_craft_status_lbl.text = "%s (need %d more Glimmer)" % [message, dust_needed] if dust_needed > 0 else message
	_craft_status_lbl.visible = true

func _on_card_crafted(_card_id: String) -> void:
	_craft_btn.disabled = false
	_craft_status_lbl.visible = false

# ── Pack purchase ───────────────────────────────────────────────────────────

func _on_buy_pressed(pack_id: String) -> void:
	_status_lbl.visible = false
	if _buy_buttons.has(pack_id):
		_buy_buttons[pack_id].disabled = true
	Economy.purchase_pack(pack_id)

func _on_purchase_failed(message: String) -> void:
	_status_lbl.text = message
	_status_lbl.visible = true
	for btn in _buy_buttons.values():
		btn.disabled = false

func _on_pack_opened(_pack_id: String, cards: Array, dust_awarded: int) -> void:
	for btn in _buy_buttons.values():
		btn.disabled = false
	pack_opened_ready.emit(cards, dust_awarded)

func _flat(c: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	return s
