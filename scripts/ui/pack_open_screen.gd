class_name PackOpenScreen
extends Control

## Sequential Hearthstone-style pack reveal (User Story 3). Renders the
## `result.cards` list a purchase_pack_result already returned (see
## contracts/shop-protocol.md) — this screen never rolls anything itself,
## it only animates a server-confirmed result (Constitution Principle II:
## UI reflects authoritative state, it doesn't invent it).
##
## Built with Tween, the same tool board.gd's animate_creature_attack uses
## (research.md decision 4), rather than a hand-authored AnimationPlayer
## timeline, since pack contents are randomized at runtime.

signal finished

const CardScene := preload("res://scenes/cards/Card.tscn")
const CARD_DISPLAY_W := 240.0

var _cards: Array = []
var _dust_awarded: int = 0
var _reveal_index: int = 0
var _card_slot: Control
var _info_lbl: Label
var _skip_btn: Button
var _continue_btn: Button
var _active_tween: Tween

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()

## Called by whoever opens this screen (see main.gd's _on_shop_pressed)
## right after a successful purchase_pack_result.
func setup(cards: Array, dust_awarded: int) -> void:
	_cards = cards
	_dust_awarded = dust_awarded
	_reveal_index = 0
	_start_next_reveal()

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.03, 0.05, 0.92)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	center.add_child(vbox)

	_card_slot = Control.new()
	_card_slot.custom_minimum_size = Vector2(CARD_DISPLAY_W, CARD_DISPLAY_W * 1.4)
	vbox.add_child(_card_slot)

	_info_lbl = Label.new()
	_info_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info_lbl.add_theme_font_size_override("font_size", 20)
	vbox.add_child(_info_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 14)
	vbox.add_child(btn_row)

	_skip_btn = Button.new()
	_skip_btn.text = "Skip"
	_skip_btn.pressed.connect(_on_skip_pressed)
	btn_row.add_child(_skip_btn)

	_continue_btn = Button.new()
	_continue_btn.text = "Continue"
	_continue_btn.visible = false
	_continue_btn.pressed.connect(func(): finished.emit())
	btn_row.add_child(_continue_btn)

func _start_next_reveal() -> void:
	if _reveal_index >= _cards.size():
		_show_summary()
		return
	var entry: Dictionary = _cards[_reveal_index]
	_reveal_index += 1
	_animate_reveal(entry)

## Builds the Card.tscn node for one pull, at CARD_DISPLAY_W, not yet scaled
## to its final size (callers set `scale` themselves - animated or instant).
func _build_card_node(entry: Dictionary) -> Card:
	for child in _card_slot.get_children():
		child.queue_free()
	var data := CardDatabase.get_card(str(entry.get("card_id", "")))
	var card_node: Card = CardScene.instantiate()
	card_node.use_text_overlay = false
	card_node.input_pickable = false
	card_node.set_process_input(false)
	_card_slot.add_child(card_node)
	if data != null:
		card_node.call_deferred("setup", data)
	return card_node

func _animate_reveal(entry: Dictionary) -> void:
	var rarity := str(entry.get("rarity", "COMMON"))
	var was_new := bool(entry.get("was_new", true))
	var scale_factor := CARD_DISPLAY_W / Card.CARD_SIZE.x

	var card_node := _build_card_node(entry)
	card_node.scale = Vector2.ZERO
	_info_lbl.text = "" if was_new else "Already owned - converted to dust"

	var hold_time := 1.1 if rarity == "LEGENDARY" else 0.7
	_active_tween = create_tween()
	_active_tween.tween_property(card_node, "scale", Vector2(scale_factor, scale_factor), 0.28) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if rarity == "LEGENDARY" or rarity == "EPIC":
		# A brief golden flourish for the rarer pulls - a lightweight nod to
		# Hearthstone's escalating-rarity pacing without a new asset pipeline.
		_active_tween.tween_property(card_node, "modulate", Color(1.3, 1.15, 0.6), 0.2)
		_active_tween.tween_property(card_node, "modulate", Color(1, 1, 1), 0.2)
	_active_tween.tween_interval(hold_time)
	_active_tween.tween_callback(_start_next_reveal)

## Completes every remaining reveal immediately "without losing any card
## from the result" (FR-010) - shows the final pull at full size (so the
## player still sees what they got) then jumps straight to the summary,
## rather than silently discarding the skipped cards.
func _on_skip_pressed() -> void:
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	if not _cards.is_empty():
		var last_entry: Dictionary = _cards[_cards.size() - 1]
		var scale_factor := CARD_DISPLAY_W / Card.CARD_SIZE.x
		var card_node := _build_card_node(last_entry)
		card_node.scale = Vector2(scale_factor, scale_factor)
	_reveal_index = _cards.size()
	_show_summary()

func _show_summary() -> void:
	_skip_btn.visible = false
	_continue_btn.visible = true
	var new_count := 0
	for entry in _cards:
		if bool(entry.get("was_new", true)):
			new_count += 1
	var msg := "%d new card%s" % [new_count, "" if new_count == 1 else "s"]
	if _dust_awarded > 0:
		msg += "   +%d Glimmer" % _dust_awarded
	_info_lbl.text = msg
