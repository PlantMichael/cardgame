class_name HeroPanel
extends Panel

@onready var hp_label: Label = $HPLabel

var player_id: String = ""
var _last_health: int = 30

signal hero_clicked(player_id: String)

func _ready() -> void:
	gui_input.connect(_on_gui_input)
	_apply_style()

func set_health(value: int) -> void:
	var took_damage = value < _last_health
	_last_health = value
	hp_label.text = str(value)
	if took_damage:
		var tween = create_tween()
		tween.tween_property(self, "modulate", Color(1, 0.3, 0.3), 0.1)
		tween.tween_property(self, "modulate", Color.WHITE, 0.3)

func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		hero_clicked.emit(player_id)

func _apply_style() -> void:
	var s = StyleBoxFlat.new()
	s.bg_color = Color(0.16, 0.22, 0.14)
	s.border_color = Color(0.4, 0.6, 0.3)
	s.set_border_width_all(2)
	s.set_corner_radius_all(8)
	add_theme_stylebox_override("panel", s)
