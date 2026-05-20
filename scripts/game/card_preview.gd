extends Panel

@onready var card_name_label: Label = $VBoxContainer/CardName
@onready var cost_label: Label = $VBoxContainer/CostRow/CostLabel
@onready var art_texture: TextureRect = $VBoxContainer/ArtTexture
@onready var description_label: Label = $VBoxContainer/Description
@onready var attack_label: Label = $VBoxContainer/StatsRow/AttackLabel
@onready var health_label: Label = $VBoxContainer/StatsRow/HealthLabel
@onready var keywords_label: Label = $VBoxContainer/Keywords
@onready var stats_row: HBoxContainer = $VBoxContainer/StatsRow

const CARD_COLORS = {
	CardData.CardColor.GREEN:  Color(0.18, 0.38, 0.18),
	CardData.CardColor.CRIMSON:    Color(0.38, 0.18, 0.18),
	CardData.CardColor.BLACK:  Color(0.14, 0.14, 0.14),
	CardData.CardColor.ORANGE: Color(0.38, 0.28, 0.12),
	CardData.CardColor.TEAL:   Color(0.15, 0.35, 0.35),
}
const CARD_BORDER_COLORS = {
	CardData.CardColor.GREEN:  Color(0.35, 0.72, 0.35),
	CardData.CardColor.CRIMSON:    Color(0.72, 0.35, 0.35),
	CardData.CardColor.BLACK:  Color(0.42, 0.42, 0.42),
	CardData.CardColor.ORANGE: Color(0.72, 0.58, 0.30),
	CardData.CardColor.TEAL:   Color(0.30, 0.72, 0.72),
}

func _ready() -> void:
	hide()

func show_card(data: CardData) -> void:
	card_name_label.text = data.card_name
	cost_label.text = str(data.cost) + " mana"
	description_label.text = data.description

	var is_creature = data.card_type == CardData.CardType.CREATURE
	stats_row.visible = is_creature
	if is_creature:
		attack_label.text = "⚔ " + str(data.attack)
		health_label.text = "♥ " + str(data.health)

	# Keywords
	var keywords = []
	if data.has_taunt:
		keywords.append("Taunt")
	if data.has_charge:
		keywords.append("Charge")
	keywords_label.text = " • ".join(keywords)
	keywords_label.visible = not keywords.is_empty()

	if data.art:
		art_texture.texture = data.art

	# Color theme
	var s = StyleBoxFlat.new()
	s.bg_color = CARD_COLORS[data.color]
	s.border_color = CARD_BORDER_COLORS[data.color]
	s.set_border_width_all(3)
	s.set_corner_radius_all(8)
	add_theme_stylebox_override("panel", s)

	show()

func hide_card() -> void:
	hide()
