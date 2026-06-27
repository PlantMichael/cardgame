class_name Board
extends Node2D

@onready var opponent_hand_zone: HBoxContainer = $OpponentHandZone
@onready var opponent_board_zone: HBoxContainer = $OpponentBoardZone
@onready var player_board_zone: HBoxContainer = $PlayerBoardZone
@onready var player_hand_zone: HBoxContainer = $PlayerHandZone
@onready var end_turn_button: Button = $CenterBar/EndTurnButton
@onready var coinflip_label: Label = $CenterBar/CoinflipLabel
@onready var turn_label: Label = $CenterBar/TurnLabel
@onready var mana_label: RichTextLabel = $CenterBar/ManaLabel
var _mana_dots: Array[Panel] = []
var _drag_tween: Tween = null
var _flash_cost: int = 0
var _flash_start: int = 0
@onready var player_hero: Panel = $PlayerHero
@onready var opponent_hero: Panel = $OpponentHero
@onready var card_preview_zone: Control = $CardPreviewZone
@onready var preview_card: Card = $CardPreviewZone/PreviewCard
@onready var combat_log_scroll: ScrollContainer = $CombatLogPanel/CombatLogScroll
@onready var combat_log_vbox: VBoxContainer = $CombatLogPanel/CombatLogScroll/CombatLogVBox
var decline_button: Button

const CardScene = preload("res://scenes/cards/Card.tscn")
const CardBackScene = preload("res://scenes/cards/CardBack.tscn")

var game_state: GameState
var selected_attacker: Card = null
var _dragging_stratagem: bool = false
var _hide_scheduled: bool = false
var _challenge_mode: bool = false
var _challenging_minion: Minion = null
var _on_play_damage_mode: bool = false
var _pilot_mode: bool = false
var _piloting_minion: Minion = null
var _yeti_select_mode: bool = false
var _tank_shot_mode: bool = false
var _null_mode: bool = false
var _buff_friendly_mode: bool = false
var _on_play_pilot_mode: bool = false
var _player_deck_icon: Node2D
var _deck_count_label: Label

signal action_play_card(card_data: CardData)
signal action_attack(attacker_instance_id: String, target_type: String, target_id: String)
signal action_play_stratagem(card_data: CardData, target_minion: Minion, target_player_id: String)
signal action_pilot(pilot_instance_id: String, target_instance_id: String)
signal end_turn_pressed
signal decline_pressed
signal challenge_target_selected(target: Minion)
signal on_play_damage_target_selected(target_minion: Minion, target_player_id: String)
signal rummage_card_selected(card: CardData)
signal transform_choice_selected(card: CardData)
signal yeti_selected(minion: Minion)
signal tank_shot_resolved(target_minion: Minion, target_player_id: String)
signal null_target_selected(target: Minion)
signal buff_friendly_target_selected(target: Minion)
signal on_play_pilot_target_selected(target: Minion)

func _ready() -> void:
	mana_label.hide()
	var dot_container := HBoxContainer.new()
	dot_container.add_theme_constant_override("separation", 3)
	dot_container.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mana_label.get_parent().add_child(dot_container)
	var _dot_style_filled := StyleBoxFlat.new()
	_dot_style_filled.bg_color = Color.WHITE
	_dot_style_filled.set_corner_radius_all(6)
	for i in 10:
		var dot := Panel.new()
		dot.custom_minimum_size = Vector2(12, 12)
		dot.add_theme_stylebox_override("panel", _dot_style_filled)
		dot_container.add_child(dot)
		_mana_dots.append(dot)
	end_turn_button.pressed.connect(_on_end_turn_pressed)
	_create_decline_button()
	set_process_input(true)
	preview_card.modulate = Color(1, 1, 1, 0)
	_add_board_zone_backgrounds()
	_create_player_deck_icon()
	card_preview_zone.z_index = 1

func _create_decline_button() -> void:
	decline_button = Button.new()
	decline_button.text = "Decline"
	decline_button.hide()
	decline_button.pressed.connect(_on_decline_pressed)
	$CenterBar.add_child(decline_button)

func show_decline_button(label: String = "Decline") -> void:
	decline_button.text = label
	decline_button.show()

func hide_decline_button() -> void:
	decline_button.hide()

func start_challenge_targeting(challenger: Minion) -> void:
	_challenge_mode = true
	_challenging_minion = challenger
	_highlight_board_minions(opponent_board_zone, true)
	show_decline_button("Decline")

func _end_challenge_mode(target: Minion) -> void:
	_challenge_mode = false
	_challenging_minion = null
	_highlight_board_minions(opponent_board_zone, false)
	hide_decline_button()
	challenge_target_selected.emit(target)

func start_on_play_damage_targeting() -> void:
	_on_play_damage_mode = true
	_highlight_board_minions(player_board_zone, true)
	_highlight_board_minions(opponent_board_zone, true)
	_highlight_hero(player_hero, true)
	_highlight_hero(opponent_hero, true)
	show_decline_button("Decline")

func _end_on_play_damage_mode(target_minion: Minion, target_player_id: String) -> void:
	_on_play_damage_mode = false
	_highlight_board_minions(player_board_zone, false)
	_highlight_board_minions(opponent_board_zone, false)
	_highlight_hero(player_hero, false)
	_highlight_hero(opponent_hero, false)
	hide_decline_button()
	on_play_damage_target_selected.emit(target_minion, target_player_id)

func start_on_play_pilot_targeting(pilot: Minion) -> void:
	_on_play_pilot_mode = true
	_piloting_minion = pilot
	_highlight_mech_targets(true)
	show_decline_button("Cancel")

func _end_on_play_pilot_mode(target: Minion) -> void:
	_highlight_mech_targets(false)
	_on_play_pilot_mode = false
	_piloting_minion = null
	hide_decline_button()
	on_play_pilot_target_selected.emit(target)

func _end_pilot_mode(target: Minion) -> void:
	var pilot_id = _piloting_minion.instance_id if _piloting_minion else ""
	_highlight_mech_targets(false)
	_pilot_mode = false
	_piloting_minion = null
	if is_instance_valid(selected_attacker):
		selected_attacker.set_selected(false)
	selected_attacker = null
	hide_decline_button()
	if target and pilot_id != "":
		action_pilot.emit(pilot_id, target.instance_id)

func start_tank_shot_targeting() -> void:
	_tank_shot_mode = true
	_highlight_board_minions(player_board_zone, true)
	_highlight_board_minions(opponent_board_zone, true)
	_highlight_hero(player_hero, true)
	_highlight_hero(opponent_hero, true)
	show_decline_button("Skip")

func _end_tank_shot_mode(target_minion: Minion, target_player_id: String) -> void:
	_tank_shot_mode = false
	_highlight_board_minions(player_board_zone, false)
	_highlight_board_minions(opponent_board_zone, false)
	_highlight_hero(player_hero, false)
	_highlight_hero(opponent_hero, false)
	hide_decline_button()
	tank_shot_resolved.emit(target_minion, target_player_id)

func start_null_targeting() -> void:
	_null_mode = true
	_highlight_board_minions(player_board_zone, true)
	_highlight_board_minions(opponent_board_zone, true)
	show_decline_button("Cancel")

func _end_null_mode(target: Minion) -> void:
	_null_mode = false
	_highlight_board_minions(player_board_zone, false)
	_highlight_board_minions(opponent_board_zone, false)
	hide_decline_button()
	null_target_selected.emit(target)

func start_buff_friendly_targeting() -> void:
	_buff_friendly_mode = true
	_highlight_board_minions(player_board_zone, true)
	show_decline_button("Skip")

func _end_buff_friendly_mode(target: Minion) -> void:
	_buff_friendly_mode = false
	_highlight_board_minions(player_board_zone, false)
	hide_decline_button()
	buff_friendly_target_selected.emit(target)

func start_yeti_selection() -> void:
	_yeti_select_mode = true
	_highlight_yeti_targets(true)
	show_decline_button("Cancel")

func _end_yeti_select_mode(target: Minion) -> void:
	_yeti_select_mode = false
	_highlight_yeti_targets(false)
	hide_decline_button()
	yeti_selected.emit(target)

func _highlight_yeti_targets(value: bool) -> void:
	for wrapper in player_board_zone.get_children():
		if wrapper.get_child_count() == 0:
			continue
		var card = wrapper.get_child(0)
		if card is Card and card.minion.has_ability(Abilities.YETI):
			card.set_targeted(value)

func _has_pilot_ability(minion: Minion) -> bool:
	for ability in minion.abilities:
		if Abilities.is_pilot(ability):
			return true
	return false

func _has_mech_target(excluding: Minion) -> bool:
	for wrapper in player_board_zone.get_children():
		if wrapper.get_child_count() == 0:
			continue
		var card = wrapper.get_child(0)
		if card is Card and card.minion != excluding and card.minion.has_ability(Abilities.MECH) and not card.minion.is_piloted:
			return true
	return false

func _highlight_mech_targets(value: bool) -> void:
	for wrapper in player_board_zone.get_children():
		if wrapper.get_child_count() == 0:
			continue
		var card = wrapper.get_child(0)
		if card is Card and card.minion != _piloting_minion and card.minion.has_ability(Abilities.MECH) and not card.minion.is_piloted:
			card.set_targeted(value)

func _on_decline_pressed() -> void:
	decline_pressed.emit()
	if _challenge_mode:
		_end_challenge_mode(null)
	elif _on_play_damage_mode:
		_end_on_play_damage_mode(null, "")
	elif _pilot_mode:
		_end_pilot_mode(null)
	elif _yeti_select_mode:
		_end_yeti_select_mode(null)
	elif _tank_shot_mode:
		_end_tank_shot_mode(null, "")
	elif _on_play_pilot_mode:
		_end_on_play_pilot_mode(null)
	elif _null_mode:
		_end_null_mode(null)
	elif _buff_friendly_mode:
		_end_buff_friendly_mode(null)

func _add_board_zone_backgrounds() -> void:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.18)
	style.border_color = Color(0.7, 0.7, 0.7, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(14)
	for zone in [opponent_board_zone, player_board_zone]:
		var panel = Panel.new()
		panel.add_theme_stylebox_override("panel", style)
		panel.position = zone.position - Vector2(12, 8)
		panel.size = zone.size + Vector2(24, 16)
		add_child(panel)
		move_child(panel, 1)

func _create_player_deck_icon() -> void:
	_player_deck_icon = CardBackScene.instantiate()
	_player_deck_icon.scale = Vector2(0.75, 0.75)
	_player_deck_icon.position = Vector2(1632, 910)
	add_child(_player_deck_icon)

	_deck_count_label = Label.new()
	_deck_count_label.add_theme_font_size_override("font_size", 14)
	_deck_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_deck_count_label.custom_minimum_size = Vector2(80, 0)
	_deck_count_label.position = Vector2(1632, 1035)
	add_child(_deck_count_label)

	var graveyard_btn := Button.new()
	graveyard_btn.text = "Graveyard"
	graveyard_btn.custom_minimum_size = Vector2(100, 32)
	graveyard_btn.position = Vector2(1630, 1050)
	graveyard_btn.add_theme_font_size_override("font_size", 13)
	graveyard_btn.pressed.connect(_open_graveyard_viewer)
	add_child(graveyard_btn)

func setup(state: GameState) -> void:
	game_state = state
	refresh()

func show_coinflip_result(going_first: bool) -> void:
	coinflip_label.text = "Going First" if going_first else "Going Second"
	await get_tree().create_timer(4.0).timeout
	coinflip_label.text = ""

func refresh() -> void:
	selected_attacker = null
	_refresh_hand()
	_refresh_boards()
	_refresh_heroes()
	_refresh_ui()

# --- Input ---

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover(event.position)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# Check hand cards first
			for wrapper in player_hand_zone.get_children():
				if wrapper.get_child_count() == 0:
					continue
				var card = wrapper.get_child(0)
				if card is Card:
					var rect = wrapper.get_global_rect().grow(4)
					if rect.has_point(event.position):
						if card.data.card_type == CardData.CardType.STRATAGEM:
							_dragging_stratagem = true
							if _stratagem_needs_target(card.data):
								if _stratagem_needs_creature_target(card.data):
									if _stratagem_needs_friendly_yeti(card.data):
										_highlight_yeti_targets(true)
									elif _stratagem_needs_enemy_creature_only(card.data):
										_highlight_stratagem_minions(opponent_board_zone, true)
									elif _stratagem_needs_friendly_piloted_mech(card.data):
										_highlight_piloted_mech_targets(true)
									elif _stratagem_needs_friendly_creature_only(card.data):
										_highlight_stratagem_minions(player_board_zone, true)
									else:
										_highlight_stratagem_minions(player_board_zone, true)
										_highlight_stratagem_minions(opponent_board_zone, true)
								else:
									_highlight_stratagem_minions(player_board_zone, true)
									_highlight_stratagem_minions(opponent_board_zone, true)
									_highlight_hero(player_hero, true)
									_highlight_hero(opponent_hero, true)
						elif game_state.player.can_play_card(card.data):
							_highlight_board_zone(true)
						card.start_drag()
						return

			# Check player board minions
			for wrapper in player_board_zone.get_children():
				if wrapper.get_child_count() == 0:
					continue
				var card = wrapper.get_child(0)
				if card is Card:
					var rect = wrapper.get_global_rect().grow(4)
					if rect.has_point(event.position):
						if _tank_shot_mode:
							_end_tank_shot_mode(card.minion, "")
							return
						if _on_play_damage_mode:
							_end_on_play_damage_mode(card.minion, "")
							return
						if _buff_friendly_mode:
							_end_buff_friendly_mode(card.minion)
							return
						_on_player_minion_clicked(card)
						return

			# Check opponent board minions
			for wrapper in opponent_board_zone.get_children():
				if wrapper.get_child_count() == 0:
					continue
				var card = wrapper.get_child(0)
				if card is Card:
					var rect = wrapper.get_global_rect().grow(4)
					if rect.has_point(event.position):
						if _challenge_mode:
							_end_challenge_mode(card.minion)
							return
						if _on_play_damage_mode:
							_end_on_play_damage_mode(card.minion, "")
							return
						if _tank_shot_mode:
							_end_tank_shot_mode(card.minion, "")
							return
						if _null_mode:
							_end_null_mode(card.minion)
							return
						_on_enemy_minion_clicked(card)
						return

			# Check player hero
			if player_hero.get_global_rect().grow(4).has_point(event.position):
				if _tank_shot_mode:
					_end_tank_shot_mode(null, game_state.player.player_id)
					return
				if _on_play_damage_mode:
					_end_on_play_damage_mode(null, game_state.player.player_id)
					return

			# Check opponent hero
			if opponent_hero.get_global_rect().grow(4).has_point(event.position):
				if _tank_shot_mode:
					_end_tank_shot_mode(null, game_state.opponent.player_id)
					return
				if _on_play_damage_mode:
					_end_on_play_damage_mode(null, game_state.opponent.player_id)
					return
				_on_enemy_hero_clicked()
				return

			# Clicked empty space — deselect
			_clear_selections()

		else:
			_highlight_board_zone(false)
			if _dragging_stratagem:
				_dragging_stratagem = false
				_highlight_all_targets(false)

func _highlight_board_zone(value: bool) -> void:
	if value:
		var s = StyleBoxFlat.new()
		s.bg_color = Color(0.2, 0.6, 0.2, 0.3)
		s.border_color = Color(0.3, 0.9, 0.3, 0.8)
		s.set_border_width_all(3)
		s.set_corner_radius_all(8)
		player_board_zone.add_theme_stylebox_override("panel", s)
	else:
		player_board_zone.remove_theme_stylebox_override("panel")

# --- Hover preview ---

func _update_hover(mouse_pos: Vector2) -> void:
	for wrapper in player_hand_zone.get_children():
		var card = _get_card_child(wrapper)
		if card and wrapper.get_global_rect().has_point(mouse_pos):
			_show_card_preview(card.data)
			return
	for zone in [player_board_zone, opponent_board_zone]:
		for wrapper in zone.get_children():
			var card = _get_card_child(wrapper)
			if card and wrapper.get_global_rect().has_point(mouse_pos):
				_show_card_preview(card.minion.data, card.minion)
				return
	_hide_card_preview()

func _get_card_child(wrapper: Node) -> Card:
	if wrapper.get_child_count() == 0:
		return null
	var child = wrapper.get_child(0)
	return child if child is Card else null

# --- Drop handler ---

func _show_card_preview(data: CardData, minion: Minion = null) -> void:
	_hide_scheduled = false
	if minion != null:
		preview_card.setup_as_minion(minion)
	else:
		preview_card.setup(data)
	preview_card.modulate = Color(1, 1, 1, 1)

func _hide_card_preview() -> void:
	_hide_scheduled = true
	await get_tree().create_timer(0.08).timeout
	if _hide_scheduled:
		preview_card.modulate = Color(1, 1, 1, 0)
		_hide_scheduled = false

func _highlight_all_targets(value: bool) -> void:
	_highlight_board_minions(player_board_zone, value)
	_highlight_board_minions(opponent_board_zone, value)
	_highlight_hero(player_hero, value)
	_highlight_hero(opponent_hero, value)

func _highlight_board_minions(zone: HBoxContainer, value: bool) -> void:
	for wrapper in zone.get_children():
		if wrapper.get_child_count() == 0:
			continue
		var card = wrapper.get_child(0)
		if card is Card:
			card.set_targeted(value)

func _highlight_stratagem_minions(zone: HBoxContainer, value: bool) -> void:
	for wrapper in zone.get_children():
		if wrapper.get_child_count() == 0:
			continue
		var card = wrapper.get_child(0)
		if card is Card:
			if value and card.minion.has_ability(Abilities.SAFEGUARD):
				continue
			card.set_targeted(value)

func _highlight_hero(hero: Panel, value: bool) -> void:
	if value:
		var s = StyleBoxFlat.new()
		s.bg_color = Color(0.6, 0.2, 0.2, 0.3)
		s.border_color = Color(0.9, 0.3, 0.3, 0.8)
		s.set_border_width_all(3)
		s.set_corner_radius_all(8)
		hero.add_theme_stylebox_override("panel", s)
	else:
		hero.remove_theme_stylebox_override("panel")

func _on_card_drag_started(card: Card) -> void:
	_stop_mana_flash()
	_flash_start = game_state.player.current_mana
	_flash_cost = mini(card.data.effective_cost(), _mana_dots.size() - _flash_start)
	if _flash_cost <= 0:
		return
	_drag_tween = create_tween().set_loops()
	_drag_tween.tween_method(_set_flash_alpha, 1.0, 0.15, 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_drag_tween.tween_method(_set_flash_alpha, 0.15, 1.0, 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

func _set_flash_alpha(alpha: float) -> void:
	for i in _flash_cost:
		_mana_dots[_flash_start + i].modulate.a = alpha

func _stop_mana_flash() -> void:
	if _drag_tween and _drag_tween.is_valid():
		_drag_tween.kill()
	_drag_tween = null
	_flash_cost = 0
	_flash_start = 0
	for dot in _mana_dots:
		dot.modulate.a = 1.0

func _on_card_dropped(card: Card) -> void:
	_stop_mana_flash()
	_highlight_board_zone(false)
	_highlight_all_targets(false)
	_dragging_stratagem = false
	var mouse_pos = get_viewport().get_mouse_position()

	if not game_state.is_local_player_turn():
		card.return_to_hand()
		return

	if not game_state.player.can_play_card(card.data):
		card.return_to_hand()
		return

	# Handle creature drop
	if card.data.card_type == CardData.CardType.CREATURE:
		var board_rect = player_board_zone.get_global_rect().grow(20)
		if board_rect.has_point(mouse_pos) and game_state.player.board.size() < PlayerState.MAX_BOARD_SIZE:
			var card_data_to_play = card.data
			get_viewport().remove_child(card)
			call_deferred("_finish_play_card", card, card_data_to_play)
			return
		card.return_to_hand()
		return

	# Handle stratagem drop — find target under mouse
	if card.data.card_type == CardData.CardType.STRATAGEM:
		if not _stratagem_needs_target(card.data):
			var card_data_to_play = card.data
			get_viewport().remove_child(card)
			call_deferred("_finish_play_stratagem", card, card_data_to_play, null, "")
			return
		# Check board minions
		for zone in [player_board_zone, opponent_board_zone]:
			for wrapper in zone.get_children():
				if wrapper.get_child_count() == 0:
					continue
				var target_card = wrapper.get_child(0)
				if target_card is Card:
					var rect = wrapper.get_global_rect().grow(10)
					if rect.has_point(mouse_pos):
						if target_card.minion.has_ability(Abilities.SAFEGUARD) and not _stratagem_needs_friendly_piloted_mech(card.data):
							continue
						if _stratagem_needs_friendly_yeti(card.data):
							if zone != player_board_zone or not target_card.minion.has_ability(Abilities.YETI):
								continue
						elif _stratagem_needs_enemy_creature_only(card.data):
							if zone != opponent_board_zone:
								continue
						elif _stratagem_needs_friendly_piloted_mech(card.data):
							if zone != player_board_zone or not target_card.minion.is_piloted:
								continue
						elif _stratagem_needs_friendly_creature_only(card.data):
							if zone != player_board_zone:
								continue
						var card_data_to_play = card.data
						var target_minion = target_card.minion
						get_viewport().remove_child(card)
						call_deferred("_finish_play_stratagem", card, card_data_to_play, target_minion, "")
						return
		# Check heroes — only valid for stratagems that target heroes (e.g. deal_damage), not creature-only effects
		if not _stratagem_needs_creature_target(card.data):
			if player_hero.get_global_rect().grow(10).has_point(mouse_pos):
				var card_data_to_play = card.data
				get_viewport().remove_child(card)
				call_deferred("_finish_play_stratagem", card, card_data_to_play, null, game_state.player.player_id)
				return
			if opponent_hero.get_global_rect().grow(10).has_point(mouse_pos):
				var card_data_to_play = card.data
				get_viewport().remove_child(card)
				call_deferred("_finish_play_stratagem", card, card_data_to_play, null, game_state.opponent.player_id)
				return
		card.return_to_hand()

func _finish_play_card(card: Card, card_data_to_play: CardData) -> void:
	var wrapper = card._original_parent
	card.queue_free()
	if is_instance_valid(wrapper):
		wrapper.queue_free()
	action_play_card.emit(card_data_to_play)

func _finish_play_stratagem(card: Card, card_data_to_play: CardData, target_minion: Minion, target_player_id: String) -> void:
	var wrapper = card._original_parent
	card.queue_free()
	if is_instance_valid(wrapper):
		wrapper.queue_free()
	action_play_stratagem.emit(card_data_to_play, target_minion, target_player_id)
# --- Refresh ---

func _refresh_hand() -> void:
	for c in player_hand_zone.get_children():
		c.hide()
		c.queue_free()
	for c in opponent_hand_zone.get_children():
		c.hide()
		c.queue_free()

	for card_data in game_state.player.hand:
		var card = CardScene.instantiate()
		var wrapper = Button.new()
		wrapper.custom_minimum_size = Vector2(112, 162)
		wrapper.flat = true
		player_hand_zone.add_child(wrapper)
		wrapper.add_child(card)
		card.scale = Vector2(0.5, 0.5)
		card.is_in_hand = true
		card.dropped.connect(_on_card_dropped)
		card.drag_started.connect(_on_card_drag_started)
		card.setup(card_data)
		card.set_playable(game_state.player.can_play_card(card_data))
		wrapper.button_down.connect(card.start_drag)

	for i in game_state.opponent.hand.size():
		var back = CardBackScene.instantiate()
		back.scale = Vector2(0.62, 0.62)
		var wrapper = Control.new()
		wrapper.custom_minimum_size = Vector2(68, 98)
		opponent_hand_zone.add_child(wrapper)
		wrapper.add_child(back)

func _refresh_boards() -> void:
	for c in player_board_zone.get_children():
		c.hide()
		c.queue_free()
	for c in opponent_board_zone.get_children():
		c.hide()
		c.queue_free()

	var is_my_turn = game_state.is_local_player_turn()

	for minion in game_state.player.board:
		var card = CardScene.instantiate()
		var wrapper = Control.new()
		wrapper.custom_minimum_size = Vector2(127, 184)
		player_board_zone.add_child(wrapper)
		wrapper.add_child(card)
		card.scale = Vector2(0.57, 0.57)
		card.position = Vector2(2, 2)
		card.setup_as_minion(minion)
		card.set_can_attack(is_my_turn and minion.can_attack())
		card.set_summoning_sick(minion.is_exhausted)
		if minion.is_newly_reinforced:
			minion.is_newly_reinforced = false
			_blink_card_green(card)
		if minion.is_newly_transformed:
			minion.is_newly_transformed = false
			card.animate_transform()

	for minion in game_state.opponent.board:
		var card = CardScene.instantiate()
		var wrapper = Control.new()
		wrapper.custom_minimum_size = Vector2(137, 198)
		opponent_board_zone.add_child(wrapper)
		wrapper.add_child(card)
		card.scale = Vector2(0.6125, 0.6125)
		card.position = Vector2(2, 2)
		card.setup_as_minion(minion)
		card.set_can_attack(false)
		if minion.is_newly_reinforced:
			minion.is_newly_reinforced = false
			_blink_card_green(card)
		if minion.is_newly_transformed:
			minion.is_newly_transformed = false
			card.animate_transform()

func _refresh_heroes() -> void:
	player_hero.set_health(game_state.player.hero_health)
	opponent_hero.set_health(game_state.opponent.hero_health)

func _refresh_ui() -> void:
	var is_my_turn = game_state.is_local_player_turn()
	end_turn_button.disabled = not is_my_turn
	turn_label.text = "Turn %d" % game_state.turn_number
	for i in _mana_dots.size():
		var dot = _mana_dots[i]
		if i < game_state.player.max_mana:
			dot.show()
			dot.modulate = Color.WHITE if i < game_state.player.current_mana else Color(0.25, 0.25, 0.25)
		else:
			dot.hide()
	_deck_count_label.text = str(game_state.player.get_deck_size())

# --- Board minion click (for attacking) ---

func _on_player_minion_clicked(card: Card) -> void:
	if not game_state.is_local_player_turn():
		return
	if _null_mode:
		_end_null_mode(card.minion)
		return
	if _yeti_select_mode:
		if card.minion.has_ability(Abilities.YETI):
			_end_yeti_select_mode(card.minion)
		return
	if _on_play_pilot_mode:
		if card.minion.has_ability(Abilities.MECH) and not card.minion.is_piloted and card.minion != _piloting_minion:
			_end_on_play_pilot_mode(card.minion)
		return
	if _pilot_mode:
		if card.minion.has_ability(Abilities.MECH) and not card.minion.is_piloted and card.minion != _piloting_minion:
			_end_pilot_mode(card.minion)
		return
	if selected_attacker == card:
		_clear_selections()
		return
	# If a pilot is already selected and we click a valid friendly mech → pilot it
	if selected_attacker != null and _has_pilot_ability(selected_attacker.minion):
		if card.minion.has_ability(Abilities.MECH) and not card.minion.is_piloted and card.minion != selected_attacker.minion:
			var pilot_card = selected_attacker
			_clear_selections()
			action_pilot.emit(pilot_card.minion.instance_id, card.minion.instance_id)
			return
	_clear_selections()
	var is_pilot = _has_pilot_ability(card.minion)
	var has_mech = _has_mech_target(card.minion)
	var can_atk = card.minion.can_attack()
	if not is_pilot and not can_atk:
		return
	selected_attacker = card
	card.set_selected(true)
	if can_atk:
		_highlight_attack_targets(true)
	if is_pilot and has_mech:
		_piloting_minion = card.minion
		_highlight_mech_targets(true)
	if is_pilot or can_atk:
		show_decline_button("Cancel")

func _on_enemy_minion_clicked(card: Card) -> void:
	if not selected_attacker or _on_play_pilot_mode:
		return
	# Taunt check
	var taunts = game_state.opponent.get_guardian_minions()
	if not taunts.is_empty() and card.minion not in taunts:
		print("must attack taunt!")
		return
	action_attack.emit(
		selected_attacker.minion.instance_id,
		"minion",
		card.minion.instance_id
	)
	_clear_selections()

func _on_enemy_hero_clicked() -> void:
	if not selected_attacker or _on_play_pilot_mode:
		return
	var taunts = game_state.opponent.get_guardian_minions()
	if not taunts.is_empty():
		print("must attack taunt!")
		return
	action_attack.emit(
		selected_attacker.minion.instance_id,
		"hero",
		game_state.opponent.player_id
	)
	_clear_selections()

func _highlight_attack_targets(value: bool) -> void:
	# Highlight enemy minions and hero as valid targets
	var taunts = game_state.opponent.get_guardian_minions()
	for wrapper in opponent_board_zone.get_children():
		if wrapper.get_child_count() == 0:
			continue
		var card = wrapper.get_child(0)
		if card is Card:
			if value:
				# If taunt exists only highlight taunts
				if taunts.is_empty() or card.minion in taunts:
					card.set_targeted(true)
			else:
				card.set_targeted(false)
	_highlight_hero(opponent_hero, value and taunts.is_empty())

func _on_end_turn_pressed() -> void:
	_clear_selections()
	end_turn_pressed.emit()

func _clear_selections() -> void:
	if is_instance_valid(selected_attacker):
		selected_attacker.set_selected(false)
	selected_attacker = null
	_highlight_attack_targets(false)
	_highlight_hero(opponent_hero, false)
	_highlight_mech_targets(false)
	_piloting_minion = null
	hide_decline_button()
	if _pilot_mode:
		_pilot_mode = false
	if _yeti_select_mode:
		_yeti_select_mode = false
		hide_decline_button()
		yeti_selected.emit(null)
	if _on_play_damage_mode:
		_on_play_damage_mode = false
		_highlight_board_minions(player_board_zone, false)
		_highlight_board_minions(opponent_board_zone, false)
		_highlight_hero(player_hero, false)
		_highlight_hero(opponent_hero, false)
		hide_decline_button()
		on_play_damage_target_selected.emit(null, "")
	if _tank_shot_mode:
		_tank_shot_mode = false
		hide_decline_button()
		tank_shot_resolved.emit(null, "")

func log_action(text: String) -> void:
	var label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND
	combat_log_vbox.add_child(label)
	await get_tree().process_frame
	combat_log_scroll.scroll_vertical = combat_log_scroll.get_v_scroll_bar().max_value

func _blink_card_green(card: Card) -> void:
	var tween = card.create_tween().set_loops(3)
	tween.tween_property(card, "modulate", Color(0.3, 1.0, 0.3), 0.15)
	tween.tween_property(card, "modulate", Color(1.0, 1.0, 1.0), 0.15)

func announce_card(card_data: CardData) -> void:
	_show_card_preview(card_data)
	await get_tree().create_timer(1.0).timeout
	preview_card.modulate = Color(1, 1, 1, 0)

func animate_creature_attack(attacker_instance_id: String, attacker_player_id: String, target_instance_id: String) -> void:
	var is_local_attacker = (attacker_player_id == game_state.player.player_id)
	var attacker_zone: HBoxContainer = player_board_zone if is_local_attacker else opponent_board_zone
	var target_zone: HBoxContainer = opponent_board_zone if is_local_attacker else player_board_zone

	var attacker_card: Card = null
	var target_card: Card = null

	for wrapper in attacker_zone.get_children():
		var card = _get_card_child(wrapper)
		if card and card.minion and card.minion.instance_id == attacker_instance_id:
			attacker_card = card
			break

	for wrapper in target_zone.get_children():
		var card = _get_card_child(wrapper)
		if card and card.minion and card.minion.instance_id == target_instance_id:
			target_card = card
			break

	if not attacker_card or not target_card:
		return

	# Use Control.get_global_rect() on the wrappers for true screen-space centers,
	# then apply the delta as a local-space offset (wrappers have no rotation/scale).
	var attacker_center: Vector2 = attacker_card.get_parent().get_global_rect().get_center()
	var target_center: Vector2 = target_card.get_parent().get_global_rect().get_center()
	var delta: Vector2 = target_center - attacker_center

	var base_pos := attacker_card.position
	var attack_pos := base_pos + delta

	# Render on top of all other cards during the animation.
	attacker_card.z_as_relative = false
	attacker_card.z_index = 100

	var tween := create_tween()
	tween.tween_property(attacker_card, "position", attack_pos, 0.20).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_callback(target_card.damage_flash)
	tween.tween_property(attacker_card, "position", base_pos, 0.13).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await tween.finished

	attacker_card.z_as_relative = true
	attacker_card.z_index = 0
	attacker_card.position = base_pos

func animate_creature_challenge(challenger_instance_id: String, challenger_player_id: String, target_instance_id: String) -> void:
	var is_local_attacker = (challenger_player_id == game_state.player.player_id)
	var attacker_zone: HBoxContainer = player_board_zone if is_local_attacker else opponent_board_zone
	var target_zone: HBoxContainer = opponent_board_zone if is_local_attacker else player_board_zone

	var attacker_card: Card = null
	var target_card: Card = null

	for wrapper in attacker_zone.get_children():
		var card = _get_card_child(wrapper)
		if card and card.minion and card.minion.instance_id == challenger_instance_id:
			attacker_card = card
			break

	for wrapper in target_zone.get_children():
		var card = _get_card_child(wrapper)
		if card and card.minion and card.minion.instance_id == target_instance_id:
			target_card = card
			break

	if not attacker_card or not target_card:
		return

	var attacker_center: Vector2 = attacker_card.get_parent().get_global_rect().get_center()
	var target_center: Vector2 = target_card.get_parent().get_global_rect().get_center()
	var delta: Vector2 = target_center - attacker_center

	var base_pos := attacker_card.position
	var attack_pos := base_pos + delta

	attacker_card.z_as_relative = false
	attacker_card.z_index = 100

	var tween := create_tween()
	tween.tween_property(attacker_card, "position", attack_pos, 0.20).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_callback(target_card.damage_flash)
	tween.tween_property(attacker_card, "position", base_pos, 0.13).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await tween.finished

	attacker_card.z_as_relative = true
	attacker_card.z_index = 0
	attacker_card.position = base_pos

func animate_draw() -> void:
	var flying = CardBackScene.instantiate()
	flying.scale = _player_deck_icon.scale
	flying.position = _player_deck_icon.position
	add_child(flying)

	# Aim for the right portion of the player hand zone
	var target = Vector2(
		player_hand_zone.position.x + player_hand_zone.size.x * 0.75,
		player_hand_zone.position.y + player_hand_zone.size.y * 0.4
	)

	var tween = create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(flying, "position", target, 0.35)
	await tween.finished
	flying.queue_free()

func show_graveyard_picker(options: Array[CardData]) -> CardData:
	var overlay = CanvasLayer.new()
	overlay.layer = 10
	add_child(overlay)

	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.78)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(bg)

	var panel = VBoxContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.add_theme_constant_override("separation", 14)
	overlay.add_child(panel)

	var title = Label.new()
	title.text = "Rummage — choose a card to retrieve"
	title.add_theme_font_size_override("font_size", 17)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title)

	var cards_container = VBoxContainer.new()
	cards_container.add_theme_constant_override("separation", 8)
	panel.add_child(cards_container)

	var _selection_made := false
	var current_row: HBoxContainer = null
	var cards_in_row := 0
	const MAX_PER_ROW := 10

	for card_data in options:
		if current_row == null or cards_in_row >= MAX_PER_ROW:
			current_row = HBoxContainer.new()
			current_row.add_theme_constant_override("separation", 10)
			current_row.alignment = BoxContainer.ALIGNMENT_CENTER
			cards_container.add_child(current_row)
			cards_in_row = 0
		var wrapper = Button.new()
		wrapper.custom_minimum_size = Vector2(100, 148)
		wrapper.flat = true
		current_row.add_child(wrapper)
		var card = CardScene.instantiate()
		card.scale = Vector2(0.45, 0.45)
		card.position = Vector2(4, 4)
		wrapper.add_child(card)
		card.setup(card_data)
		card.input_pickable = false
		card.set_process_input(false)
		_ignore_control_input(card)
		var captured := card_data
		wrapper.pressed.connect(func():
			if _selection_made: return
			_selection_made = true
			rummage_card_selected.emit(captured)
		)
		cards_in_row += 1

	var skip = Button.new()
	skip.text = "Skip"
	skip.custom_minimum_size = Vector2(100, 34)
	skip.pressed.connect(func():
		if _selection_made: return
		_selection_made = true
		rummage_card_selected.emit(null)
	)
	panel.add_child(skip)

	var chosen: CardData = await rummage_card_selected
	overlay.queue_free()
	return chosen

func _open_graveyard_viewer() -> void:
	if game_state == null or game_state.player == null:
		return
	var graveyard := game_state.player.graveyard
	var overlay := CanvasLayer.new()
	overlay.layer = 10
	add_child(overlay)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.78)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(bg)

	var panel := VBoxContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.add_theme_constant_override("separation", 14)
	overlay.add_child(panel)

	var title := Label.new()
	title.text = "Graveyard (%d)" % graveyard.size()
	title.add_theme_font_size_override("font_size", 17)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title)

	if graveyard.is_empty():
		var empty_label := Label.new()
		empty_label.text = "Your graveyard is empty."
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		panel.add_child(empty_label)
	else:
		var cards_container := VBoxContainer.new()
		cards_container.add_theme_constant_override("separation", 8)
		panel.add_child(cards_container)

		const MAX_PER_ROW := 10
		var current_row: HBoxContainer = null
		var cards_in_row := 0
		for card_data in graveyard:
			if current_row == null or cards_in_row >= MAX_PER_ROW:
				current_row = HBoxContainer.new()
				current_row.add_theme_constant_override("separation", 10)
				current_row.alignment = BoxContainer.ALIGNMENT_CENTER
				cards_container.add_child(current_row)
				cards_in_row = 0
			var wrapper := Control.new()
			wrapper.custom_minimum_size = Vector2(100, 148)
			current_row.add_child(wrapper)
			var card := CardScene.instantiate()
			card.scale = Vector2(0.45, 0.45)
			card.position = Vector2(4, 4)
			wrapper.add_child(card)
			card.setup(card_data)
			_ignore_control_input(card)
			cards_in_row += 1

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(100, 34)
	close_btn.pressed.connect(overlay.queue_free)
	panel.add_child(close_btn)

func show_transform_picker(options: Array[CardData]) -> CardData:
	var overlay = CanvasLayer.new()
	overlay.layer = 10
	add_child(overlay)

	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.78)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(bg)

	var panel = VBoxContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.add_theme_constant_override("separation", 14)
	overlay.add_child(panel)

	var title = Label.new()
	title.text = "Choose a form to transform into"
	title.add_theme_font_size_override("font_size", 17)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title)

	var cards_row = HBoxContainer.new()
	cards_row.add_theme_constant_override("separation", 10)
	cards_row.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(cards_row)

	var _selection_made := false

	for card_data in options:
		var wrapper = Button.new()
		wrapper.custom_minimum_size = Vector2(100, 148)
		wrapper.flat = true
		cards_row.add_child(wrapper)
		var card = CardScene.instantiate()
		card.scale = Vector2(0.45, 0.45)
		card.position = Vector2(4, 4)
		wrapper.add_child(card)
		card.setup(card_data)
		card.input_pickable = false
		card.set_process_input(false)
		_ignore_control_input(card)
		var captured := card_data
		wrapper.pressed.connect(func():
			if _selection_made: return
			_selection_made = true
			transform_choice_selected.emit(captured)
		)

	var chosen: CardData = await transform_choice_selected
	overlay.queue_free()
	return chosen

func _stratagem_needs_target(data: CardData) -> bool:
	return data.effect not in ["destroy_all_creatures", "deal_damage_all_creatures", "deal_damage_all_enemy", "buff_all_friendly_attack", "eject_all_pilots"]

func _stratagem_needs_creature_target(data: CardData) -> bool:
	return data.effect in ["give_ability", "buff_creature", "buff_health", "force_challenge", "poke_bear", "blood_transfusion", "sanguine", "heal", "eject_pilot"]

func _stratagem_needs_friendly_yeti(data: CardData) -> bool:
	return data.effect in ["force_challenge", "poke_bear"]

func _stratagem_needs_enemy_creature_only(data: CardData) -> bool:
	return data.effect in ["blood_transfusion"]

func _stratagem_needs_friendly_creature_only(data: CardData) -> bool:
	return data.effect in ["sanguine", "heal", "give_ability"]

func _stratagem_needs_friendly_piloted_mech(data: CardData) -> bool:
	return data.effect == "eject_pilot"

func _highlight_piloted_mech_targets(value: bool) -> void:
	for wrapper in player_board_zone.get_children():
		if wrapper.get_child_count() == 0:
			continue
		var card = wrapper.get_child(0)
		if card is Card and card.minion.is_piloted:
			card.set_targeted(value)

func _ignore_control_input(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_control_input(child)

func show_game_over(won: bool) -> void:
	var layer = CanvasLayer.new()
	add_child(layer)

	var root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(root)

	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.75)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vbox.grow_vertical = Control.GROW_DIRECTION_BOTH
	root.add_child(vbox)

	var label = Label.new()
	label.text = "You Win!" if won else "You Lose!"
	label.add_theme_font_size_override("font_size", 64)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(label)

	var btn = Button.new()
	btn.text = "Play Again"
	btn.custom_minimum_size = Vector2(160, 48)
	btn.pressed.connect(func(): get_tree().reload_current_scene())
	vbox.add_child(btn)
