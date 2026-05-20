class_name DropZone
extends Control

var is_highlighted: bool = false

signal card_dropped(card: Card)

func _ready() -> void:
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	mouse_filter = Control.MOUSE_FILTER_STOP

func highlight(value: bool) -> void:
	is_highlighted = value
	if value:
		var s = StyleBoxFlat.new()
		s.bg_color = Color(0.2, 0.6, 0.2, 0.3)
		s.border_color = Color(0.3, 0.9, 0.3, 0.8)
		s.set_border_width_all(3)
		s.set_corner_radius_all(8)
		add_theme_stylebox_override("panel", s)
	else:
		remove_theme_stylebox_override("panel")

func _on_mouse_entered() -> void:
	if is_highlighted:
		highlight(true)

func _on_mouse_exited() -> void:
	if is_highlighted:
		highlight(false)

func can_accept(card: Card) -> bool:
	return card.is_in_hand and card.data.card_type == CardData.CardType.CREATURE

func accept_drop(card: Card) -> void:
	card_dropped.emit(card)
