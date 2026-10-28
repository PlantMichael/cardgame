class_name Board
extends Node2D

@onready var background: TextureRect = $Background
@onready var opponent_hand_zone: HBoxContainer = $OpponentHandZone
@onready var opponent_board_zone: HBoxContainer = $OpponentBoardZone
@onready var player_board_zone: HBoxContainer = $PlayerBoardZone
@onready var player_hand_zone: HBoxContainer = $PlayerHandZone
@onready var center_bar: Control = $CenterBar
@onready var end_turn_button: Button = $CenterBar/EndTurnButton
@onready var coinflip_label: Label = $CenterBar/CoinflipLabel
@onready var turn_label: Label = $CenterBar/TurnLabel
@onready var mana_label: RichTextLabel = $CenterBar/ManaLabel
var _mana_dots: Array[Control] = []
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

## Shared sizing for every "look at a row of cards and pick/view one" screen
## (rummage retrieval, graveyard viewer, transform choice; the mulligan lays
## its own hand out).
##
## Bigger than the MEDIUM preset the hand uses: these overlays own the whole
## screen and are the moment the player is reading card text rather than
## glancing at it. Eight of these still fit across a row with room to spare
## (8 x 196 against the 1920 the canvas always lays out at), and the picker
## cards carry their own hover preview on top - see _make_picker_preview().
const PICKER_CARD_SCALE := Vector2(0.84, 0.84)
const PICKER_WRAPPER_SIZE := Card.CARD_SIZE * PICKER_CARD_SCALE.x + Vector2(11, 16)

const BATTLEFIELD_TEXTURES: Array[Texture2D] = [
	preload("res://assets/battlefield.png"),
	preload("res://assets/battlefield2.png"),
	preload("res://assets/battlefield3.png"),
]

## The fixed local position every board Card sits at within its wrapper (see
## _reconcile_board_zone()) - _settle_shifted_cards() animates away from and
## back to this exact constant rather than whatever the card's current
## position happens to be, since "current" can be mid-flight from a still-
## running slide tween (rapid consecutive plays, e.g. the AI playing two
## creatures back to back, don't leave 0.22s of breathing room between board
## refreshes) - reading it as if it were a settled baseline in that case
## would lock in a stale offset as the new "rest" position, which compounds
## across plays into a card visibly drifting off to one side over a turn.
const BOARD_CARD_REST_POSITION := Vector2(2, 2)

## Both board rows show cards at the one SMALL preset (they used to run at
## slightly different scales), so they share a wrapper size too.
const _BOARD_WRAPPER_SIZE := Card.PIXELS_BOARD + Vector2(4, 4)

const CURSOR_DEFAULT = preload("res://assets/01.png")
const CURSOR_TARGET = preload("res://assets/15.png")
var _cursor_target_friendly: Texture2D = null
var _using_target_cursor: bool = false
var _using_friendly_cursor: bool = false

var game_state: GameState
var selected_attacker: Card = null
var _dragging_stratagem: bool = false
var _dragging_card: bool = false
## True from the moment a dropped creature card starts its slam-onto-board
## flight (see _play_card_with_slam()) until it lands - blocks starting a new
## drag mid-flight, since the flying card is still a live Card node sitting
## on top of the viewport and isn't ready to be re-grabbed.
var _card_animation_playing: bool = false
## The player's own in-flight ghost card, if any - lets _slam_ghost_onto_
## card() know when to clear _card_animation_playing (opponent-triggered
## ghosts share the same landing code but must never touch that flag, since
## it gates the *local* player's own input).
var _active_player_ghost: Card = null
## HBoxContainer (player_board_zone/opponent_board_zone) -> the one ghost
## Card queued to fly onto the next brand-new board card _reconcile_board_
## zone() creates in that zone - see _play_card_with_slam() and
## play_opponent_card_with_slam().
##
## Keyed by zone rather than by the played CardData (an earlier version of
## this matched by CardData identity, keyed off Minion.instance_id not
## existing yet at registration time): an on-play transform ability
## (ON_PLAY_TRANSFORM - see abilities.gd's fire_on_play(), which runs
## synchronously inside game_state.play_creature(), well before the first
## board.refresh() ever reconciles anything) reassigns the just-played
## Minion's .data to a different CardData, which broke that identity match
## and left the ghost permanently unclaimed: a whole live Card node, hidden
## but never freed. Each transform-on-play card played compounded another
## one of these, which is exactly what made the game measurably laggier as a
## match went on.
##
## A single pending slot per zone sidesteps the whole class of mismatch: at
## most one ghost is ever in flight per side at a time (the player can't
## start a new drag mid-flight - see _card_animation_playing; the AI/host
## process one action at a time), and no on-play ability creates additional
## minions synchronously (only on-death ones do, per abilities.gd), so the
## first brand-new card _reconcile_board_zone() builds in a zone with a
## pending ghost is always the one that ghost belongs to.
var _pending_slam_ghost_by_zone: Dictionary = {}
## HBoxContainer -> true while a slam-landing animation (see
## _run_slam_landing()) is actively playing in that zone - covers the whole
## flight+impact/legendary-landing sequence, not just the ghost's flight.
## Blocks all board interaction (see _input()) and lets await_slam_landed()
## tell a play's on-play-effect processing (a rummage picker, etc.) to hold
## off until the animation is actually done, instead of racing it.
var _slam_animating_zones: Dictionary = {}
## True once the player has clicked End Turn a first time while actions were
## still available (see _player_has_actions_left()) - the button is armed to
## end the turn on the *next* click instead of doing it immediately, so a
## turn with an unplayed card or an unattacked minion still standing always
## needs a deliberate confirm. Reset on every refresh() (see
## _update_end_turn_button()) rather than just on end-turn/opponent-turn, so
## a stale confirm from before doesn't survive the player doing something
## else (playing one more card, an on-play effect changing the board) that
## may have changed what "actions left" even means.
var _end_turn_armed: bool = false
const _END_TURN_COLOR_ACTIONS_LEFT := Color(1.0, 0.82, 0.25)
const _END_TURN_COLOR_READY := Color(0.4, 0.85, 0.45)
var _hide_scheduled: bool = false
## True while a full-screen modal (graveyard viewer, rummage/transform
## picker) is open - see _open_modal_overlay(). A modal already fills the
## screen with cards to look at, so the hover preview would only ever land
## on top of them as clutter: it stays hidden for as long as a modal owns
## the screen.
var _modal_open: bool = false
var _hover_card: Card = null
## Bumped on every hover change so a delayed show for a card the mouse has
## already left (or left and re-entered) can tell it is stale.
var _hover_serial: int = 0
var _preview_tween: Tween = null
var _preview_base_pos: Vector2 = Vector2.INF
var _lifted_hand_card: Card = null
const HOVER_PREVIEW_DELAY_SEC := 0.25
var _challenge_mode: bool = false
var _challenging_minion: Minion = null
var _on_play_damage_mode: bool = false
var _pilot_mode: bool = false
var _piloting_minion: Minion = null
var _yeti_select_mode: bool = false
var _tank_shot_mode: bool = false
var _null_mode: bool = false
var _buff_friendly_mode: bool = false
var _choice_mode: bool = false
var _choice_option_ids: Array = []
var _buff_friendly_exclude: Minion = null
var _buff_friendly_tribe_filter: String = ""
var _on_play_pilot_mode: bool = false
var _player_deck_icon: Node2D
var _deck_count_label: Label

var is_online: bool = false
## True only in a server-run ranked match (see remote_match_client.gd).
var concede_enabled: bool = false
var _pause_overlay: CanvasLayer = null
var _game_over: bool = false
var _opponent_name_label: Label = null
var _node_modifier_label: Label = null

var _keywords: Dictionary = {}
var _keyword_vbox: VBoxContainer = null
var _keyword_show_pending: bool = false
var _keyword_pending_data: CardData = null
var _keyword_current_card: CardData = null
var _keyword_source_rect: Rect2 = Rect2()
const _KEYWORD_W := 220.0
const _KEYWORD_GAP := 10.0

## at_index: where in player_board_zone the dropped card lands - see
## _board_insert_index_for_x() - so the row can grow left/right of the
## center card instead of only ever appending at the end.
signal action_play_card(card_data: CardData, at_index: int)
signal action_attack(attacker_instance_id: String, target_type: String, target_id: String)
signal action_play_stratagem(card_data: CardData, target_minion: Minion, target_player_id: String)
signal action_pilot(pilot_instance_id: String, target_instance_id: String)
signal end_turn_pressed
signal decline_pressed
signal restart_requested
signal ranked_requeue_requested
## A server-run ranked match: the pause menu offers Concede instead of Quit.
signal concede_requested
signal campaign_continue_requested
signal challenge_target_selected(target: Minion)
signal on_play_damage_target_selected(target_minion: Minion, target_player_id: String)
signal rummage_card_selected(card: CardData)
signal transform_choice_selected(card: CardData)
signal yeti_selected(minion: Minion)
signal tank_shot_resolved(target_minion: Minion, target_player_id: String)
signal null_target_selected(target: Minion)
signal buff_friendly_target_selected(target: Minion)
## One generic targeting mode for GameState pending choices. The rules core
## supplies the legal option ids, so this never re-derives legality - unlike
## the older per-effect modes above, each of which re-implements its own
## filter and can drift from the rules.
signal choice_target_selected(target: Minion)
## The answer to a rules-core choice: a minion instance id, "hero:<player_id>", or "" to decline.
signal choice_selected(option_id: String)
signal on_play_pilot_target_selected(target: Minion)

func _ready() -> void:
	background.texture = BATTLEFIELD_TEXTURES.pick_random()
	mana_label.hide()
	var dot_container := HBoxContainer.new()
	dot_container.add_theme_constant_override("separation", 2)
	dot_container.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mana_label.get_parent().add_child(dot_container)
	for i in 10:
		var dot := _make_mana_crystal()
		dot_container.add_child(dot)
		_mana_dots.append(dot)
	end_turn_button.pressed.connect(_on_end_turn_pressed)
	_style_end_turn_button()
	_style_center_bar()
	_style_combat_log_panel()
	_create_decline_button()
	set_process_input(true)
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	# Board.tscn still carries an older hand-set scale (1.5); the placement math
	# below assumes the LARGE preset, so apply it rather than trust the scene.
	preview_card.apply_size(Card.Size.LARGE)
	preview_card.modulate = Color(1, 1, 1, 0)
	preview_card.visible = false
	card_preview_zone.set_anchors_preset(Control.PRESET_TOP_LEFT)
	card_preview_zone.size = Vector2(_PREVIEW_W, _PREVIEW_H)
	_ignore_control_input(card_preview_zone)
	_add_board_zone_backgrounds()
	_create_player_deck_icon()
	card_preview_zone.z_index = 1
	_load_keywords()
	_keyword_vbox = VBoxContainer.new()
	_keyword_vbox.add_theme_constant_override("separation", 6)
	_keyword_vbox.z_index = 2
	_keyword_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_keyword_vbox)

## Hearthstone-style faceted diamond gem instead of a plain dot - drawn
## directly rather than built from StyleBoxFlat panels since a diamond needs
## a rotated/skewed shape a rectangular stylebox can't produce. "filled" vs.
## "empty" (available vs. spent mana this turn - see _refresh_ui()) is stored
## as metadata read back by _draw_mana_crystal() rather than two swappable
## styleboxes, since queue_redraw() replaces the old add_theme_stylebox_
## override() toggle.
func _make_mana_crystal() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(20, 24)
	c.set_meta("filled", true)
	c.draw.connect(_draw_mana_crystal.bind(c))
	return c

func _draw_mana_crystal(c: Control) -> void:
	var filled: bool = c.get_meta("filled", true)
	var w := c.size.x
	var h := c.size.y
	# The gain "pop" (see _pop_new_mana_crystals()) is baked into the drawn
	# geometry rather than applied as a `scale` on the Control, because a
	# Container resets its children's scale and rotation every time it
	# re-sorts - and the sort caused by this very crystal becoming visible
	# is what wiped the pop before it ever drew a frame.
	var pop: float = c.get_meta("pop", 1.0)
	var mid := Vector2(w * 0.5, h * 0.5)
	var top := mid.lerp(Vector2(w * 0.5, 0), pop)
	var right := mid.lerp(Vector2(w, h * 0.5), pop)
	var bottom := mid.lerp(Vector2(w * 0.5, h), pop)
	var left := mid.lerp(Vector2(0, h * 0.5), pop)
	if filled:
		var light := Color(0.62, 0.84, 1.0)
		var dark := Color(0.08, 0.32, 0.72)
		c.draw_colored_polygon([left, bottom, right, mid], dark)
		c.draw_colored_polygon([left, top, right, mid], light)
		c.draw_polyline([top, right, bottom, left, top], Color(0.85, 0.93, 1.0, 0.9), 1.5)
	else:
		c.draw_colored_polygon([top, right, bottom, left], Color(0.10, 0.12, 0.16, 0.6))
		c.draw_polyline([top, right, bottom, left, top], Color(0.35, 0.40, 0.48, 0.9), 1.5)

## Rounded gem-badge look for the End Turn button instead of the engine's
## default rectangular Button - self_modulate (see _update_end_turn_button())
## keeps doing the green/yellow/white state tinting on top of this, so the
## base fill stays a light neutral parchment tone rather than the button's
## eventual on-screen color.
func _style_end_turn_button() -> void:
	var base := StyleBoxFlat.new()
	base.bg_color = Color(0.86, 0.83, 0.76)
	base.border_color = Color(0.45, 0.34, 0.14)
	base.set_border_width_all(3)
	base.set_corner_radius_all(20)
	base.content_margin_left = 22
	base.content_margin_right = 22
	base.content_margin_top = 10
	base.content_margin_bottom = 10
	var hover := base.duplicate()
	hover.bg_color = base.bg_color.lightened(0.08)
	var pressed := base.duplicate()
	pressed.bg_color = base.bg_color.darkened(0.1)
	var disabled := base.duplicate()
	disabled.bg_color = Color(0.4, 0.4, 0.4)
	disabled.border_color = Color(0.25, 0.25, 0.25)
	end_turn_button.add_theme_stylebox_override("normal", base)
	end_turn_button.add_theme_stylebox_override("hover", hover)
	end_turn_button.add_theme_stylebox_override("pressed", pressed)
	end_turn_button.add_theme_stylebox_override("disabled", disabled)
	end_turn_button.add_theme_color_override("font_color", Color(0.18, 0.13, 0.05))
	end_turn_button.add_theme_color_override("font_disabled_color", Color(0.7, 0.7, 0.7))
	end_turn_button.add_theme_font_size_override("font_size", 18)

## Backing ribbon behind the turn label/mana crystals/End Turn row so it
## doesn't float directly on the battlefield art - matches the board zone
## mat's dark-felt-with-gold-trim look (see _add_board_zone_backgrounds()).
func _style_center_bar() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.06, 0.30)
	style.border_color = Color(0.72, 0.58, 0.25, 0.60)
	style.set_border_width_all(2)
	style.set_corner_radius_all(18)
	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.position = center_bar.position - Vector2(24, 6)
	panel.size = center_bar.size + Vector2(48, 12)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	move_child(panel, 1)
	turn_label.add_theme_color_override("font_color", Color(0.92, 0.87, 0.75))
	turn_label.add_theme_constant_override("outline_size", 3)
	turn_label.add_theme_color_override("font_outline_color", Color.BLACK)

## The board is laid out in a fixed 1920x1080 design space. In the browser the
## project runs with the "expand" stretch aspect (see Main), so a window wider
## or taller than 16:9 gets MORE canvas instead of black bars - this centers
## the 1920x1080 layout inside it and lets the background cover the extra. With
## the default "keep" aspect (desktop/editor) the canvas is exactly 1920x1080
## and the offset is zero, so nothing changes there.
const DESIGN_SIZE := Vector2(1920, 1080)
func _fit_to_viewport() -> void:
	var vp := get_viewport_rect().size
	position = ((vp - DESIGN_SIZE) * 0.5).max(Vector2.ZERO).floor()
	var bg := get_node_or_null("Background") as Control
	if bg != null:
		# Placed explicitly (top-left anchored) rather than anchored full-rect:
		# a Control under a Node2D does not re-resolve its anchors when the
		# viewport grows, which left a strip of bare window on the far side.
		bg.set_anchors_preset(Control.PRESET_TOP_LEFT)
		bg.offset_left = -position.x
		bg.offset_top = -position.y
		bg.offset_right = -position.x + vp.x
		bg.offset_bottom = -position.y + vp.y

func _style_combat_log_panel() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.06, 0.55)
	style.border_color = Color(0.72, 0.58, 0.25, 0.85)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	$CombatLogPanel.add_theme_stylebox_override("panel", style)

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
	for wrapper in opponent_board_zone.get_children():
		var card = _get_card_child(wrapper)
		if card and not card.minion.has_ability(Abilities.AMBUSH):
			card.set_targeted(true)
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

## Highlights exactly the minions the rules core listed as legal for the open
## choice, on either board. `option_ids` comes straight from
## GameState.pending_choice["options"].
func start_choice_targeting(option_ids: Array, decline_text: String = "Skip", friendly_choice: bool = false) -> void:
	_choice_mode = true
	_choice_option_ids = option_ids.duplicate()
	for zone in [player_board_zone, opponent_board_zone]:
		for wrapper in zone.get_children():
			var card = _get_card_child(wrapper)
			if card and card.minion and card.minion.instance_id in _choice_option_ids:
				card.set_targeted(true, friendly_choice and card.minion.owner_id == game_state.player.player_id)
	if GameState.hero_option(player_hero.player_id) in _choice_option_ids:
		_highlight_hero(player_hero, true)
	if GameState.hero_option(opponent_hero.player_id) in _choice_option_ids:
		_highlight_hero(opponent_hero, true)
	show_decline_button(decline_text)

func _end_choice_mode(option_id: String) -> void:
	_choice_mode = false
	_choice_option_ids = []
	_highlight_board_minions(player_board_zone, false)
	_highlight_board_minions(opponent_board_zone, false)
	_highlight_hero(player_hero, false)
	_highlight_hero(opponent_hero, false)
	hide_decline_button()
	choice_selected.emit(option_id)

## What the Decline button says for each kind of choice.
const CHOICE_DECLINE_TEXT := {
	"challenge": "Decline", "damage_target": "Decline", "pick_challenger": "Cancel",
	"pilot_target": "Cancel", "swap_health": "Cancel", "devour": "Skip",
	"rummage": "Skip", "null_target": "Cancel", "buff_health_target": "Skip",
	"tank_buff_target": "Skip", "heal_buff_target": "Skip",
}

## Choices that help the creature picked, so friendly options show the green
## target outline instead of the red hostile one.
const CHOICE_HELPFUL_EFFECTS := [
	"restore_health", "buff_other_friendly", "pilot_target", "swap_health",
	"buff_health_target", "tank_buff_target", "heal_buff_target", "pick_challenger",
]

## One line telling the player what they are being asked, shown in the log.
const CHOICE_PROMPT_TEXT := {
	"damage_target": "Choose a target to damage",
	"challenge": "Choose a creature to challenge",
	"pick_challenger": "Choose a Yeti to challenge with",
	"pilot_target": "Choose a Mech to pilot",
	"devour": "Choose a friendly creature to devour",
	"null_target": "Choose a creature to silence",
	"buff_health_target": "Choose a creature to give +1 max health",
	"tank_buff_target": "Choose a Tank to buff",
	"heal_buff_target": "Choose a creature to give +2 health",
}

## Asks the local player to answer the rules core's open `choice` and returns
## their selection ("" declines). Legality is the core's: only the listed
## options can be clicked; the UI never decides what is allowed.
func prompt_choice(choice: Dictionary) -> String:
	var effect := str(choice["effect"])
	var options: Array = choice["options"]
	if str(choice["kind"]) == GameState.CHOICE_KIND_PICK_CARD_ID:
		var cards: Array[CardData] = []
		for cid in options:
			var cd := CardDatabase.get_card(str(cid))
			if cd != null:
				cards.append(cd)
		if cards.is_empty():
			return str(choice["default"])
		var picked: CardData
		if effect == GameState.CHOICE_TRANSFORM:
			picked = await show_transform_picker(cards)
		else:
			picked = await show_graveyard_picker(cards)
		if picked == null:
			return str(choice["default"])
		return picked.id
	var prompt := str(CHOICE_PROMPT_TEXT.get(effect, ""))
	if effect == GameState.CHOICE_SWAP_HEALTH:
		prompt = "Choose the first creature to swap health" if int(choice["step"]) <= 1 else "Choose the second creature to swap health"
	if not prompt.is_empty():
		log_action(prompt)
	if _choice_mode:
		_end_choice_mode("")
	start_choice_targeting(options, str(CHOICE_DECLINE_TEXT.get(effect, "Skip")), effect in CHOICE_HELPFUL_EFFECTS)
	var selection: String = await choice_selected
	return selection

func start_buff_friendly_targeting(exclude: Minion = null, tribe_filter: String = "") -> void:
	_buff_friendly_mode = true
	_buff_friendly_exclude = exclude
	_buff_friendly_tribe_filter = tribe_filter
	for wrapper in player_board_zone.get_children():
		var card = _get_card_child(wrapper)
		if card and card.minion != exclude:
			var tribe_ok: bool = tribe_filter.is_empty() or card.minion.data.tribe == tribe_filter
			if tribe_ok:
				card.set_targeted(true, true)
	show_decline_button("Skip")

func _end_buff_friendly_mode(target: Minion) -> void:
	_buff_friendly_mode = false
	_buff_friendly_exclude = null
	_buff_friendly_tribe_filter = ""
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
			card.set_targeted(value, true)

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
			card.set_targeted(value, true)

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
	elif _choice_mode:
		_end_choice_mode("")
	elif selected_attacker != null:
		# A plain attacker selection (declaring who to attack with, not one
		# of the special targeting modes above) shows this same Cancel
		# button - see _on_player_minion_clicked()'s show_decline_button()
		# call - but had no matching branch here, so pressing it never
		# called _clear_selections(): selected_attacker stayed set and the
		# enemy board's purple/red "valid target" highlight
		# (_highlight_attack_targets(true)) never got turned back off,
		# leaving it stuck lit for the rest of the turn.
		_clear_selections()

## Dark felt mat with a bronze/gold trim (a lighter inner bevel line sits just
## inside the outer border) instead of a plain thin-gray-bordered rect, to
## match the rest of the ornate reskin (see _style_center_bar(), hero.gd).
func _add_board_zone_backgrounds() -> void:
	var outer_style = StyleBoxFlat.new()
	outer_style.bg_color = Color(0.03, 0.05, 0.03, 0.16)
	outer_style.border_color = Color(0.60, 0.47, 0.20, 0.55)
	outer_style.set_border_width_all(3)
	outer_style.set_corner_radius_all(16)
	var inner_style = StyleBoxFlat.new()
	inner_style.draw_center = false
	inner_style.border_color = Color(0.85, 0.74, 0.45, 0.22)
	inner_style.set_border_width_all(1)
	inner_style.set_corner_radius_all(13)
	for zone in [opponent_board_zone, player_board_zone]:
		var panel = Panel.new()
		panel.add_theme_stylebox_override("panel", outer_style)
		panel.position = zone.position - Vector2(12, 8)
		panel.size = zone.size + Vector2(24, 16)
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(panel)
		move_child(panel, 1)
		var inner = Panel.new()
		inner.add_theme_stylebox_override("panel", inner_style)
		inner.position = Vector2(3, 3)
		inner.size = panel.size - Vector2(6, 6)
		inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(inner)

func _create_player_deck_icon() -> void:
	_player_deck_icon = CardBackScene.instantiate()
	_player_deck_icon.scale = Vector2(0.75, 0.75)
	_player_deck_icon.position = Vector2(1690, 725)
	add_child(_player_deck_icon)

	_deck_count_label = Label.new()
	_deck_count_label.add_theme_font_size_override("font_size", 14)
	_deck_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_deck_count_label.custom_minimum_size = Vector2(80, 0)
	_deck_count_label.position = Vector2(1690, 845)
	add_child(_deck_count_label)

	var graveyard_btn := Button.new()
	graveyard_btn.text = "Graveyard"
	graveyard_btn.custom_minimum_size = Vector2(100, 32)
	graveyard_btn.position = Vector2(1690, 880)
	graveyard_btn.add_theme_font_size_override("font_size", 13)
	graveyard_btn.pressed.connect(_open_graveyard_viewer)
	add_child(graveyard_btn)

func setup(state: GameState) -> void:
	game_state = state
	player_hero.set_faction(_infer_faction_color(state.player))
	opponent_hero.set_faction(_infer_faction_color(state.opponent))
	refresh()

## PlayerState has no persistent "hero faction" field - deck-building only
## ever hands Board a finished deck of CardData, not the faction_color it was
## built from - so the hero badge's color/emblem (see hero.gd) is inferred
## from whichever non-generic CardData.CardColor is most common across the
## player's deck/hand/graveyard/board at game start.
func _infer_faction_color(p: PlayerState) -> int:
	var counts: Dictionary = {}
	for pool in [p.deck, p.hand, p.graveyard]:
		for card_data in pool:
			if card_data.color != CardData.CardColor.GENERIC:
				counts[card_data.color] = counts.get(card_data.color, 0) + 1
	for minion in p.board:
		if minion.data.color != CardData.CardColor.GENERIC:
			counts[minion.data.color] = counts.get(minion.data.color, 0) + 1
	var best_color: int = CardData.CardColor.GENERIC
	var best_count := -1
	for color in counts:
		if counts[color] > best_count:
			best_count = counts[color]
			best_color = color
	return best_color

## Blocks input for its full 4s duration via the same modal-overlay mechanism
## as the mulligan screen/other pickers (see _open_modal_overlay()) - without
## it, board.setup() has already made everything (End Turn, hand cards, ...)
## interactive well before this or the mulligan screen that follows it has
## actually appeared, so a fast click could end the turn or play a card
## before the player has even seen their hand. The blocker itself is
## transparent (no bg) since the "Going First"/"Going Second" label lives on
## the base board underneath and has to stay visible through this.
func show_coinflip_result(going_first: bool) -> void:
	var overlay := _open_modal_overlay()
	var blocker := Control.new()
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(blocker)

	coinflip_label.text = "Going First" if going_first else "Going Second"
	await get_tree().create_timer(4.0).timeout
	coinflip_label.text = ""
	_close_modal_overlay(overlay)

func refresh() -> void:
	selected_attacker = null
	_refresh_hand()
	_refresh_boards()
	_refresh_heroes()
	_refresh_ui()

# --- Input ---

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		if not _game_over:
			if _pause_overlay != null:
				_close_pause_menu()
			else:
				_show_pause_menu()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		_update_hover(event.position)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _card_animation_playing or _modal_open or not _slam_animating_zones.is_empty():
				return
			# Check hand cards first - not while a prompt is open, or a card
			# gets picked up mid-prompt and can never be legally dropped.
			for wrapper in ([] if _has_pending_target_prompt() else player_hand_zone.get_children()):
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
									elif _stratagem_needs_friendly_mech(card.data):
										_highlight_friendly_mech_targets(true)
									elif _stratagem_needs_friendly_creature_only(card.data):
										_highlight_stratagem_minions(player_board_zone, true, card.data.effect in ["sanguine", "heal", "give_ability", "return_friendly_to_hand"])
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
						if _choice_mode:
							if card.minion.instance_id in _choice_option_ids:
								_end_choice_mode(card.minion.instance_id)
							return
						if _buff_friendly_mode:
							var tribe_ok: bool = _buff_friendly_tribe_filter.is_empty() or card.minion.data.tribe == _buff_friendly_tribe_filter
							if card.minion != _buff_friendly_exclude and tribe_ok:
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
							if not card.minion.has_ability(Abilities.AMBUSH):
								_end_challenge_mode(card.minion)
							return
						if _on_play_damage_mode:
							_end_on_play_damage_mode(card.minion, "")
							return
						if _tank_shot_mode:
							_end_tank_shot_mode(card.minion, "")
							return
						if _choice_mode:
							if card.minion.instance_id in _choice_option_ids:
								_end_choice_mode(card.minion.instance_id)
							return
						if _null_mode:
							_end_null_mode(card.minion)
							return
						_on_enemy_minion_clicked(card)
						return

			# Check player hero
			if player_hero.get_global_rect().grow(4).has_point(event.position):
				if _choice_mode:
					if GameState.hero_option(player_hero.player_id) in _choice_option_ids:
						_end_choice_mode(GameState.hero_option(player_hero.player_id))
					return
				if _tank_shot_mode:
					_end_tank_shot_mode(null, game_state.player.player_id)
					return
				if _on_play_damage_mode:
					_end_on_play_damage_mode(null, game_state.player.player_id)
					return

			# Check opponent hero
			if opponent_hero.get_global_rect().grow(4).has_point(event.position):
				if _choice_mode:
					if GameState.hero_option(opponent_hero.player_id) in _choice_option_ids:
						_end_choice_mode(GameState.hero_option(opponent_hero.player_id))
					return
				if _tank_shot_mode:
					_end_tank_shot_mode(null, game_state.opponent.player_id)
					return
				if _on_play_damage_mode:
					_end_on_play_damage_mode(null, game_state.opponent.player_id)
					return
				_on_enemy_hero_clicked()
				return

			# Clicked empty space — deselect (but never while a prompt is open:
			# that would hide its Decline button and strand the match).
			if not _has_pending_target_prompt():
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

## Swaps in the crosshair cursor (15.png) while hovering a card currently
## marked as a valid target (attack, challenge, stratagem, or any other
## on-play targeting mode - they all flow through Card.set_targeted()),
## and back to the default cursor (01.png) otherwise.
## The red reticle with red and green swapped, built once on first use.
func _get_friendly_cursor() -> Texture2D:
	if _cursor_target_friendly == null:
		var img := CURSOR_TARGET.get_image()
		img.convert(Image.FORMAT_RGBA8)
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				img.set_pixel(x, y, Color(c.g, c.r, c.b, c.a))
		_cursor_target_friendly = ImageTexture.create_from_image(img)
	return _cursor_target_friendly

func _update_target_cursor(hovered_card: Card) -> void:
	var should_target := hovered_card != null and is_instance_valid(hovered_card) and hovered_card.is_target_highlighted()
	var friendly := should_target and hovered_card.is_target_friendly()
	if should_target == _using_target_cursor and friendly == _using_friendly_cursor:
		return
	_using_target_cursor = should_target
	_using_friendly_cursor = friendly
	if should_target:
		# 15.png is a symmetric reticle - center its hotspot so it aims from
		# its middle instead of its top-left corner.
		Input.set_custom_mouse_cursor(_get_friendly_cursor() if friendly else CURSOR_TARGET, Input.CURSOR_ARROW, Vector2(16, 16))
	else:
		Input.set_custom_mouse_cursor(CURSOR_DEFAULT, Input.CURSOR_ARROW, Vector2.ZERO)

func _update_hover(mouse_pos: Vector2) -> void:
	if _modal_open:
		_hover_card = null
		_lift_hand_card(null)
		_hide_card_preview()
		return

	if _dragging_card:
		_hover_card = null
		_lift_hand_card(null)
		_hide_card_preview()
		return

	if center_bar.get_global_rect().has_point(mouse_pos):
		_hover_card = null
		_lift_hand_card(null)
		_hide_card_preview()
		return

	var found_card: Card = null
	var found_data: CardData = null
	var found_minion: Minion = null
	var found_rect: Rect2 = Rect2()
	var found_in_hand: bool = false

	for wrapper in player_hand_zone.get_children():
		var card = _get_card_child(wrapper)
		if card and wrapper.get_global_rect().has_point(mouse_pos):
			found_card = card
			found_data = card.data
			found_rect = wrapper.get_global_rect()
			found_in_hand = true
			break

	if found_card == null:
		for zone in [player_board_zone, opponent_board_zone]:
			for wrapper in zone.get_children():
				var card = _get_card_child(wrapper)
				if card and wrapper.get_global_rect().has_point(mouse_pos):
					found_card = card
					found_data = card.minion.data
					found_minion = card.minion
					found_rect = wrapper.get_global_rect()
					break
			if found_card != null:
				break

	_update_target_cursor(found_card)

	if found_card == _hover_card:
		return # still hovering the same card (or the same empty space) — don't restart the timer

	_hover_card = found_card
	_hover_serial += 1
	var serial := _hover_serial
	_lift_hand_card(found_card if found_in_hand else null)
	if found_card == null:
		_hide_card_preview()
		return

	# Hand cards show at once; moving straight from one card to another also
	# swaps at once - only a fresh hover on the board waits out the delay.
	if found_in_hand or preview_card.visible:
		_show_card_preview(found_data, found_minion, found_rect, found_in_hand)
		return

	# Field cards: only show the preview if this same card is still hovered after
	# the delay. found_card/found_minion are captured across that delay, and the
	# minion can die (or the board can refresh) before the timer fires — most
	# commonly during an AI turn's attacks while the mouse just happens to be
	# resting on the board — so both must be revalidated before touching them;
	# invoking this callable with a freed capture crashes the web export outright
	# rather than just erroring like a native/debug run would.
	get_tree().create_timer(HOVER_PREVIEW_DELAY_SEC).timeout.connect(func():
		if serial == _hover_serial and is_instance_valid(found_card) and is_instance_valid(found_minion) and _hover_card == found_card:
			_show_card_preview(found_data, found_minion, found_rect)
	)

func _get_card_child(wrapper: Node) -> Card:
	if wrapper.get_child_count() == 0:
		return null
	var child = wrapper.get_child(0)
	return child if child is Card else null

# --- Drop handler ---

## The hover preview shows a card at the LARGE preset; the zone is that size
## plus the 40px top offset PreviewCard sits at inside it (see Board.tscn).
const _PREVIEW_W := Card.PIXELS_LARGE.x
const _PREVIEW_H := Card.PIXELS_LARGE.y + 40.0
const _PREVIEW_PAD := 14.0
## Keep this much clear below the preview: browser windows and taskbars routinely
## crop the bottom of the canvas, and a card cut off there is unreadable.
const _PREVIEW_BOTTOM_MARGIN := 80.0

func _show_card_preview(data: CardData, minion: Minion = null, source_rect: Rect2 = Rect2(), from_hand: bool = false) -> void:
	_hide_scheduled = false
	if data != _keyword_current_card:
		_keyword_show_pending = false
		_clear_keyword_blocks()
		_keyword_current_card = data
		_keyword_source_rect = source_rect
		_schedule_keyword_blocks(data)
	if minion != null:
		preview_card.setup_as_minion(minion)
	else:
		preview_card.setup(data)
	if source_rect.size != Vector2.ZERO:
		var vp: Vector2 = get_viewport_rect().size
		var px: float
		var py: float
		if from_hand:
			# Rises out of the hand: centred over the card, bottom edge just
			# above it, instead of off to one side.
			px = clampf(source_rect.get_center().x - _PREVIEW_W * 0.5, _PREVIEW_PAD, vp.x - _PREVIEW_W - _PREVIEW_PAD)
			py = clampf(source_rect.position.y - _PREVIEW_H + HAND_PREVIEW_OVERLAP, 0.0, vp.y - _PREVIEW_H - _PREVIEW_BOTTOM_MARGIN)
		else:
			px = source_rect.position.x + source_rect.size.x + _PREVIEW_PAD
			if px + _PREVIEW_W > vp.x:
				px = source_rect.position.x - _PREVIEW_W - _PREVIEW_PAD
			py = source_rect.get_center().y - _PREVIEW_H * 0.5
			py = clampf(py, 0.0, vp.y - _PREVIEW_H - _PREVIEW_BOTTOM_MARGIN)
		card_preview_zone.global_position = Vector2(px, py)
	if not preview_card.visible or preview_card.modulate.a < 0.99:
		_fade_in_preview()

const HAND_PREVIEW_OVERLAP := 70.0
const PREVIEW_FADE_SEC := 0.09
const PREVIEW_SLIDE_PX := 10.0
const HAND_LIFT_PX := 26.0
const HAND_LIFT_SEC := 0.1

## Quick fade-and-rise so the preview eases in instead of popping.
func _fade_in_preview() -> void:
	if _preview_base_pos == Vector2.INF:
		_preview_base_pos = preview_card.position
	if _preview_tween != null and _preview_tween.is_valid():
		_preview_tween.kill()
	preview_card.visible = true
	preview_card.modulate = Color(1, 1, 1, 0)
	preview_card.position = _preview_base_pos + Vector2(0, PREVIEW_SLIDE_PX)
	_preview_tween = create_tween().set_parallel(true)
	_preview_tween.tween_property(preview_card, "modulate:a", 1.0, PREVIEW_FADE_SEC)
	_preview_tween.tween_property(preview_card, "position", _preview_base_pos, PREVIEW_FADE_SEC).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

## Raises the hovered hand card a little (and drops the previous one).
func _lift_hand_card(card: Card) -> void:
	if card == _lifted_hand_card:
		return
	if is_instance_valid(_lifted_hand_card):
		_tween_hand_card_y(_lifted_hand_card, 0.0)
	_lifted_hand_card = card
	if is_instance_valid(card):
		_tween_hand_card_y(card, -HAND_LIFT_PX)

func _tween_hand_card_y(card: Card, y: float) -> void:
	if card.has_meta(&"_lift_tween"):
		var prev: Tween = card.get_meta(&"_lift_tween")
		if is_instance_valid(prev):
			prev.kill()
	var t := create_tween()
	card.set_meta(&"_lift_tween", t)
	t.tween_property(card, "position:y", y, HAND_LIFT_SEC).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _hide_card_preview() -> void:
	if _preview_tween != null and _preview_tween.is_valid():
		_preview_tween.kill()
	if _preview_base_pos != Vector2.INF:
		preview_card.position = _preview_base_pos
	_keyword_show_pending = false
	_keyword_current_card = null
	_clear_keyword_blocks()
	preview_card.modulate = Color(1, 1, 1, 0)
	preview_card.visible = false
	_hide_scheduled = false

## Shared setup for every full-screen modal overlay (graveyard viewer,
## rummage/transform picker) - besides the common CanvasLayer(10) plumbing,
## this immediately hides the hover-preview and blocks it from reappearing
## (via _modal_open) until the overlay leaves the tree, however it closes
## (queue_free() from a button press, or the caller's own cleanup after an
## awaited selection).
func _open_modal_overlay() -> CanvasLayer:
	var overlay := CanvasLayer.new()
	overlay.layer = 10
	add_child(overlay)
	_modal_open = true
	_hover_card = null
	_hide_scheduled = false
	preview_card.modulate = Color(1, 1, 1, 0)
	preview_card.visible = false
	overlay.tree_exiting.connect(func(): _modal_open = false)
	return overlay

## Frees `overlay` (a modal picker from _open_modal_overlay() - rummage,
## graveyard, transform) and the Card nodes nested inside it. The cards are
## queued directly rather than left to the overlay's own recursive free so
## each one's is_queued_for_deletion() is set before deletion happens, which
## is what any Card teardown that cares about a deliberate free (rather than
## a reparent) keys off.
func _close_modal_overlay(overlay: CanvasLayer) -> void:
	_release_cards_in(overlay)
	overlay.queue_free()

func _release_cards_in(root: Node) -> void:
	for child in root.get_children():
		if child is Card:
			child.queue_free()
		else:
			_release_cards_in(child)

## A hover preview that works INSIDE a modal picker. The board's own preview
## (card_preview_zone) cannot serve here twice over: _open_modal_overlay()
## deliberately suppresses it, and it is a child of the board, so it would
## draw underneath the overlay's CanvasLayer anyway. So the overlay carries
## its own - one card node, filled in and moved as the pointer crosses the
## grid. Returns it; pass it to _hook_picker_hover() for each entry.
func _make_picker_preview(overlay: CanvasLayer) -> Card:
	var preview: Card = CardScene.instantiate()
	preview.scale = Card.SCALE_LARGE
	preview.visible = false
	preview.z_index = 200
	overlay.add_child(preview)
	preview.input_pickable = false
	preview.set_process_input(false)
	_ignore_control_input(preview)
	return preview

## Shows `preview` beside `wrapper` while the pointer is over it. Placed to
## the right of the entry when there is room and to its left when there is
## not, the same way the board's hover preview picks a side, so a card in
## the last column does not push its preview off screen.
func _hook_picker_hover(wrapper: Control, data: CardData, preview: Card) -> void:
	wrapper.mouse_entered.connect(func():
		if not is_instance_valid(preview):
			return
		preview.setup(data)
		# setup() rebuilds the card's own children, so the filters have to be
		# put back: a preview that answered the mouse would sit over the
		# neighbouring entries and flicker as it stole their hover.
		_ignore_control_input(preview)
		var vp: Vector2 = get_viewport_rect().size
		var rect: Rect2 = wrapper.get_global_rect()
		var size: Vector2 = Card.PIXELS_LARGE
		var px: float = rect.position.x + rect.size.x + _PREVIEW_PAD
		if px + size.x > vp.x:
			px = rect.position.x - size.x - _PREVIEW_PAD
		var py: float = rect.get_center().y - size.y * 0.5
		preview.global_position = Vector2(
			clampf(px, _PREVIEW_PAD, vp.x - size.x - _PREVIEW_PAD),
			clampf(py, _PREVIEW_PAD, vp.y - size.y - _PREVIEW_PAD))
		preview.visible = true)
	wrapper.mouse_exited.connect(func():
		if is_instance_valid(preview):
			preview.visible = false)

func _load_keywords() -> void:
	var file = FileAccess.open("res://data/keywords.json", FileAccess.READ)
	if not file:
		return
	var result = JSON.parse_string(file.get_as_text())
	file.close()
	if result is Dictionary:
		_keywords = result

func _schedule_keyword_blocks(data: CardData) -> void:
	_keyword_pending_data = data
	_keyword_show_pending = true
	await get_tree().create_timer(0.1).timeout
	if not _keyword_show_pending:
		return
	_keyword_show_pending = false
	_build_keyword_blocks()

func _build_keyword_blocks() -> void:
	_clear_keyword_blocks()
	if _keyword_pending_data == null or _keywords.is_empty():
		return
	var seen: Array[String] = []
	var entries: Array[Dictionary] = []
	for ability in _keyword_pending_data.abilities:
		if not Abilities.is_keyword_tooltip(ability):
			continue
		var lookup_key = Abilities.get_tooltip_key(ability)
		if lookup_key in seen:
			continue
		if not _keywords.has(lookup_key) or (_keywords[lookup_key] as String).is_empty():
			continue
		seen.append(lookup_key)
		entries.append({"key": lookup_key, "desc": _keywords[lookup_key], "color": Abilities.get_color(ability)})
	var scan_queue: Array[String] = [_keyword_pending_data.description]
	for entry in entries:
		scan_queue.append(entry["desc"])
	var i := 0
	while i < scan_queue.size():
		var text_lower = scan_queue[i].to_lower()
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
		_keyword_vbox.add_child(_make_keyword_block(entry["key"], entry["desc"], entry["color"]))
	if _keyword_vbox.get_child_count() == 0:
		return
	var vp = get_viewport_rect().size
	var zone_pos := card_preview_zone.global_position
	var bx = zone_pos.x + _PREVIEW_W + _KEYWORD_GAP
	if bx + _KEYWORD_W > vp.x:
		bx = zone_pos.x - _KEYWORD_W - _KEYWORD_GAP
	var by = lerp(zone_pos.y, _keyword_source_rect.position.y, 0.5) if _keyword_source_rect.size != Vector2.ZERO else zone_pos.y
	_keyword_vbox.global_position = Vector2(bx, by)

func _clear_keyword_blocks() -> void:
	for child in _keyword_vbox.get_children():
		_keyword_vbox.remove_child(child)
		child.queue_free()

func _make_keyword_block(kw_name: String, desc: String, accent: Color) -> PanelContainer:
	var pc = PanelContainer.new()
	pc.custom_minimum_size = Vector2(_KEYWORD_W, 0)
	var s = StyleBoxFlat.new()
	s.bg_color = Color(0.10, 0.10, 0.14, 0.95)
	s.border_color = accent
	s.set_border_width_all(2)
	s.set_corner_radius_all(6)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	pc.add_theme_stylebox_override("panel", s)
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	var title = Label.new()
	title.text = kw_name
	title.add_theme_color_override("font_color", accent.lightened(0.3))
	var body = Label.new()
	body.text = desc
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 13)
	body.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	vbox.add_child(title)
	vbox.add_child(body)
	pc.add_child(vbox)
	return pc

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

func _highlight_stratagem_minions(zone: HBoxContainer, value: bool, friendly: bool = false) -> void:
	for wrapper in zone.get_children():
		if wrapper.get_child_count() == 0:
			continue
		var card = wrapper.get_child(0)
		if card is Card:
			if value and zone == opponent_board_zone and card.minion.has_ability(Abilities.CLOAKED):
				continue
			card.set_targeted(value, friendly)

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
	_dragging_card = true
	_lift_hand_card(null)
	if card.has_meta(&"_lift_tween"):
		var lt: Tween = card.get_meta(&"_lift_tween")
		if is_instance_valid(lt):
			lt.kill()
	card.position.y = 0.0
	_hide_card_preview()
	_stop_mana_flash()
	var available = game_state.player.max_mana - game_state.player.current_mana
	_flash_cost = mini(card.data.effective_cost(), available)
	_flash_start = available - _flash_cost
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
	_dragging_card = false
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

	# Handle creature/location drop (both land in a board slot)
	if card.data.occupies_board():
		var board_rect = player_board_zone.get_global_rect().grow(20)
		if board_rect.has_point(mouse_pos) and game_state.player.can_fit_card(card.data):
			var at_index := _board_insert_index_for_x(player_board_zone, mouse_pos.x)
			_play_card_with_slam(card, card.data, at_index)
			return
		card.return_to_hand()
		return

	# Handle stratagem drop — find target under mouse
	if card.data.card_type == CardData.CardType.STRATAGEM:
		if not _stratagem_needs_target(card.data):
			var card_data_to_play = card.data
			card.queue_free()
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
						if target_card.minion.has_ability(Abilities.CLOAKED) and zone == opponent_board_zone and not _stratagem_needs_friendly_piloted_mech(card.data) and not _stratagem_needs_friendly_mech(card.data):
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
						elif _stratagem_needs_friendly_mech(card.data):
							if zone != player_board_zone or not target_card.minion.has_ability(Abilities.MECH):
								continue
						elif _stratagem_needs_friendly_creature_only(card.data):
							if zone != player_board_zone:
								continue
							# A Location is on the board but is not a creature.
							if card.data.effect == GameState.EFFECT_RETURN_FRIENDLY and target_card.minion.is_location():
								continue
						var card_data_to_play = card.data
						var target_minion = target_card.minion
						card.queue_free()
						get_viewport().remove_child(card)
						call_deferred("_finish_play_stratagem", card, card_data_to_play, target_minion, "")
						return
		# Check heroes — only valid for stratagems that target heroes (e.g. deal_damage), not creature-only effects
		if not _stratagem_needs_creature_target(card.data):
			if player_hero.get_global_rect().grow(10).has_point(mouse_pos):
				var card_data_to_play = card.data
				card.queue_free()
				get_viewport().remove_child(card)
				call_deferred("_finish_play_stratagem", card, card_data_to_play, null, game_state.player.player_id)
				return
			if opponent_hero.get_global_rect().grow(10).has_point(mouse_pos):
				var card_data_to_play = card.data
				card.queue_free()
				get_viewport().remove_child(card)
				call_deferred("_finish_play_stratagem", card, card_data_to_play, null, game_state.opponent.player_id)
				return
		card.return_to_hand()

## Both board rows are center-aligned (see Board.tscn) so a lone card sits
## in the middle of the strip - this picks which gap a drop at `x` lands in,
## so dragging left/right of the existing cards extends the row that way
## instead of always appending on the right. Compares `x` against each
## existing wrapper's own center rather than the drop's raw position among
## fixed slots, so it stays correct regardless of how many cards are already
## down or how the container has squished/centered them.
func _board_insert_index_for_x(zone: HBoxContainer, x: float) -> int:
	var idx := 0
	for wrapper in zone.get_children():
		if x < wrapper.get_global_rect().get_center().x:
			return idx
		idx += 1
	return idx

## Queues the dropped card to fly onto its real board slot once one exists,
## instead of guessing a target position up front (that guess used to always
## land on the board's first slot - see _slam_ghost_onto_card() for why this
## is now driven by the real card instead). The hand slot collapses and the
## actual game-state play resolves immediately; the dropped card itself
## keeps flying in the background as a "ghost" until _reconcile_board_zone()
## picks it up. `at_index` (see _board_insert_index_for_x()) travels with it
## end to end - through action_play_card, the game_manager/mp_game_manager
## handler, and into game_state.play_creature() - so the ghost still lands
## exactly where it's flying to once the real card exists.
func _play_card_with_slam(card: Card, card_data_to_play: CardData, at_index: int) -> void:
	_card_animation_playing = true
	_active_player_ghost = card
	_pending_slam_ghost_by_zone[player_board_zone] = card
	call_deferred("_release_hand_slot_and_emit_play", card, card_data_to_play, at_index)

func _release_hand_slot_and_emit_play(card: Card, card_data_to_play: CardData, at_index: int) -> void:
	var wrapper = card._original_parent
	if is_instance_valid(wrapper):
		wrapper.queue_free()
	action_play_card.emit(card_data_to_play, at_index)

## Spawns a stand-in Card for an opponent's about-to-be-played creature and
## queues it to fly from their hand onto their board once it actually is -
## call this well before the game_state mutation that creates the Minion
## (game_state.play_creature() et al.), ideally before any announce/think
## pause the caller already has (see ai_controller.gd/mp_game_manager.gd's
## callers), not right before it: instantiating and setting up a Card isn't
## free, and paying that cost synchronously right when the flight is meant
## to start reads as a stutter. Calling it early instead lets that cost land
## during a pause the player already expects.
##
## The ghost starts zero-scaled at the opponent's hand position - the same
## way _reconcile_board_zone() hides the real card it'll fly onto (see
## there) - so it stays invisible
## until _slam_ghost_onto_card() tweens it up to full size mid-flight, and
## doesn't spoil the card before it's actually played. `card_data` is only
## used to make the ghost look like the right card (setup() below) -
## _reconcile_board_zone() matches it back up to the real Minion's Card by
## zone slot, not by CardData identity, so it's fine if the played creature's
## own .data later changes (an on-play transform) before that happens.
func play_opponent_card_with_slam(card_data: CardData) -> void:
	var ghost := CardScene.instantiate()
	add_child(ghost)
	ghost.setup(card_data)
	ghost.scale = Vector2.ZERO
	ghost.global_position = opponent_hand_zone.get_global_rect().get_center()
	_pending_slam_ghost_by_zone[opponent_board_zone] = ghost

## Flies `ghost` (see _play_card_with_slam()/play_opponent_card_with_slam())
## onto `real_card` - the actual board Card _reconcile_board_zone() just
## created and zero-scaled for it - then reveals real_card at `target_scale` with a quick
## squash-and-settle "impact" and frees the ghost. `wrapper`'s rect is read
## only once its container has actually finished resorting after the
## add_child()/move_child() that just happened - awaiting the container's own
## sort_children signal rather than guessing "one frame is enough", which
## sometimes wasn't (a slow/dropped frame could leave the rect still stale
## when read, landing the flight on top of a neighboring card instead of the
## minion's true final slot) - so the flight always lands correctly.
func _slam_ghost_onto_card(ghost: Card, real_card: Card, wrapper: Control, target_scale: Vector2) -> void:
	var zone: Container = wrapper.get_parent()
	# Set for the whole flight+impact/legendary-landing sequence below (not
	# just the flight) - see await_slam_landed() and _input()'s use of this,
	# which is what actually keeps the board uninteractable (hover-preview
	# excepted) until a card's landing, including any legendary's extended
	# one, has fully finished playing.
	if is_instance_valid(zone):
		_slam_animating_zones[zone] = true
	await _run_slam_landing(ghost, real_card, wrapper, target_scale, zone)
	if is_instance_valid(zone):
		_slam_animating_zones.erase(zone)

## Waits until any in-flight slam-landing animation for `zone` (see
## _slam_ghost_onto_card()) has fully finished, including a legendary's own
## extended landing beat (see legendary_animations.gd). Callers (game_
## manager.gd/mp_game_manager.gd/ai_controller.gd's on-play handlers) await
## this right after board.refresh() so a same-play prompt/picker (e.g.
## StinkPile's on-play Rummage) can't pop up mid-animation.
func await_slam_landed(zone: Container) -> void:
	while _slam_animating_zones.get(zone, false):
		await get_tree().process_frame

func _run_slam_landing(ghost: Card, real_card: Card, wrapper: Control, target_scale: Vector2, zone: Container) -> void:
	if is_instance_valid(zone):
		await zone.sort_children
	else:
		await get_tree().process_frame
	if not is_instance_valid(ghost):
		return
	if not is_instance_valid(real_card) or not is_instance_valid(wrapper):
		ghost.queue_free()
		return

	var target_pos: Vector2 = wrapper.get_global_rect().position + real_card.position
	# Read once up front (real_card is confirmed valid above) so both the
	# flight and the post-flight landing checks below key off the same id -
	# a legendary can own either or both halves of the sequence (see
	# legendary_animations.gd).
	var card_id: String = real_card.data.id if real_card.data else ""
	if LegendaryAnimations.has_custom_flight(card_id):
		await LegendaryAnimations.play_flight(card_id, ghost, self, ghost.global_position, ghost.scale, target_pos, target_scale)
	else:
		var flight := create_tween()
		flight.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		flight.tween_property(ghost, "global_position", target_pos, 0.22)
		flight.parallel().tween_property(ghost, "scale", target_scale, 0.22)
		await flight.finished

	if ghost == _active_player_ghost:
		_active_player_ghost = null
		_card_animation_playing = false
	if not is_instance_valid(real_card) or not is_instance_valid(wrapper):
		ghost.queue_free()
		return

	ghost.queue_free()
	if is_instance_valid(ghost) and ghost.get_parent():
		ghost.get_parent().remove_child(ghost)

	# Some legendaries own their whole landing beat (see legendary_
	# animations.gd) instead of the default squash-and-settle impact below -
	# never both, so a legendary's landing reads as distinct rather than the
	# generic one playing underneath it. Awaited (not fire-and-forget) so
	# _slam_animating_zones - and thus await_slam_landed() - doesn't clear
	# until the legendary's own landing beat (not its lingering atmospheric
	# extras, like the tail of StinkPile's sludge splash - see that
	# function) is done.
	if LegendaryAnimations.has_landing_animation(card_id):
		real_card.scale = target_scale
		await LegendaryAnimations.play_landing(card_id, real_card, self, target_scale)
		return

	# Impact: reveal the real card already squashed from the "hit", then
	# settle it - reads as a slam instead of the ghost just stopping dead.
	real_card.scale = target_scale * Vector2(1.22, 0.75)
	var impact := create_tween()
	impact.tween_property(real_card, "scale", target_scale, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	await impact.finished

func _finish_play_stratagem(card: Card, card_data_to_play: CardData, target_minion: Minion, target_player_id: String) -> void:
	var wrapper = card._original_parent
	card.queue_free()
	if is_instance_valid(wrapper):
		wrapper.queue_free()
	action_play_stratagem.emit(card_data_to_play, target_minion, target_player_id)
# --- Refresh ---

## Reconciles player_hand_zone against game_state.player.hand instead of
## destroying and recreating every hand card on every refresh() - refresh()
## fires on nearly every action anywhere in a turn, including the AI's, so a
## full rebuild here meant the player's own hand (which the AI's turn never
## actually touches) tore down and rebuilt every hand card - a visible
## flash - on every single AI action. draw_card() duplicates each drawn
## CardData into its own unique Resource (see player_state.gd), so reference
## identity is a stable per-copy key across refreshes. Opponent's face-down
## hand backs are cheap single-panel sprites and stay a simple full rebuild
## below.
func _refresh_hand() -> void:
	var hand: Array[CardData] = game_state.player.hand

	# Hearthstone-style squish: cards keep comfortable spacing until the hand
	# would overflow the zone, then overlap progressively to keep fitting.
	var wrapper_size := Card.PIXELS_MEDIUM + Vector2(10, 4)
	var base_separation := 10.0
	var zone_width: float = player_hand_zone.size.x
	var separation := base_separation
	if hand.size() > 1:
		var natural_width: float = hand.size() * wrapper_size.x + (hand.size() - 1) * base_separation
		if natural_width > zone_width:
			# Floor scales with the card, so a full hand overlaps but never
			# collapses into an unreadable stack.
			separation = maxf((zone_width - hand.size() * wrapper_size.x) / (hand.size() - 1), -wrapper_size.x * 0.55)
	player_hand_zone.add_theme_constant_override("separation", int(round(separation)))

	var existing: Dictionary = {}
	for wrapper in player_hand_zone.get_children():
		var existing_card := _get_card_child(wrapper)
		if existing_card:
			existing[existing_card.data] = wrapper

	var kept: Dictionary = {}
	var newly_drawn: Array[Card] = []
	for i in hand.size():
		var card_data: CardData = hand[i]
		var wrapper = existing.get(card_data)
		var card: Card
		if wrapper:
			card = _get_card_child(wrapper)
		else:
			card = CardScene.instantiate()
			wrapper = Button.new()
			wrapper.custom_minimum_size = wrapper_size
			wrapper.flat = true
			player_hand_zone.add_child(wrapper)
			wrapper.add_child(card)
			card.scale = Card.HAND_SCALE
			card.is_in_hand = true
			card.dropped.connect(_on_card_dropped)
			card.drag_started.connect(_on_card_drag_started)
			wrapper.button_down.connect(func():
				if not _has_pending_target_prompt():
					card.start_drag())
			newly_drawn.append(card)
		player_hand_zone.move_child(wrapper, i)
		card.setup(card_data)
		card.set_playable(game_state.player.can_play_card(card_data))
		kept[card_data] = true

	for card_data in existing:
		if not kept.has(card_data):
			var wrapper = existing[card_data]
			wrapper.hide()
			wrapper.queue_free()
			player_hand_zone.remove_child(wrapper)

	if not newly_drawn.is_empty():
		_animate_hand_draws(newly_drawn)

	for c in opponent_hand_zone.get_children():
		c.hide()
		c.queue_free()
		opponent_hand_zone.remove_child(c)
	# get_hand_size(), not hand.size(): on the guest the opponent's hand is a
	# count with no cards behind it (see PlayerState.to_net_dict).
	for i in game_state.opponent.get_hand_size():
		var back = CardBackScene.instantiate()
		back.scale = Vector2(0.80, 0.80)
		var back_wrapper = Control.new()
		back_wrapper.custom_minimum_size = Vector2(88, 128)
		opponent_hand_zone.add_child(back_wrapper)
		back_wrapper.add_child(back)

## Fly-in-from-deck flourish for hand cards that just appeared - a fresh
## draw, the opening hand, or a mulligan replacement, anything _refresh_
## hand()'s reconciliation didn't find an existing wrapper for - instead of
## them silently popping into place mid-layout. Animates each new Card's own
## local position/scale (not its wrapper's, which the HBoxContainer
## overwrites every layout pass - see _reconcile_board_zone()'s ghost-card
## comment for the same reasoning applied to board plays) from an offset
## toward the deck icon back to its normal (0,0)/HAND_SCALE resting spot, so
## no fight with the container is needed. Awaits one sort pass first so
## `wrapper`'s rect (and thus the offset) reflects the hand's final post-draw
## layout, not a stale pre-resort one - same reasoning as _run_slam_landing().
func _animate_hand_draws(cards: Array[Card]) -> void:
	if not is_instance_valid(_player_deck_icon):
		return
	await player_hand_zone.sort_children
	for i in cards.size():
		var card := cards[i]
		if not is_instance_valid(card):
			continue
		var wrapper := card.get_parent()
		if wrapper == null or not (wrapper is Control):
			continue
		var deck_pos: Vector2 = _player_deck_icon.global_position
		card.position = deck_pos - (wrapper as Control).global_position
		card.scale = Card.HAND_SCALE * 0.4
		var target_modulate := card.modulate
		card.modulate = Color(target_modulate.r, target_modulate.g, target_modulate.b, 0.0)
		var delay := i * 0.08
		var tween := create_tween()
		tween.set_parallel(true)
		tween.tween_property(card, "position", Vector2.ZERO, 0.4).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_property(card, "scale", Card.HAND_SCALE, 0.4).set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_property(card, "modulate:a", target_modulate.a, 0.18).set_delay(delay)

## Reconciles `zone`'s existing wrapper/Card children against `minions` (in
## board order) the same way _refresh_hand() does for the hand - see its
## comment. Minion.instance_id is the stable per-copy key here. Cards that
## persist across the refresh get `configure` re-run on them (cheap - just
## refreshes labels/stats/highlights on the existing node) instead of being
## destroyed and recreated, so only minions that actually entered or left the
## board pay the create/destroy (and rebuild flash) cost.
func _reconcile_board_zone(zone: HBoxContainer, minions: Array, wrapper_size: Vector2, card_scale: Vector2, configure: Callable) -> void:
	var existing: Dictionary = {}
	for wrapper in zone.get_children():
		var existing_card := _get_card_child(wrapper)
		if existing_card and existing_card.minion:
			existing[existing_card.minion.instance_id] = wrapper

	var kept: Dictionary = {}
	## Card -> its wrapper's global position before this pass reorders
	## anything - see _settle_shifted_cards(). Only reused cards go in here;
	## brand-new ones have no "before" to slide from and are handled by their
	## own reveal path (either popping in, or _slam_ghost_onto_card() above).
	var shifted_from: Dictionary = {}
	for i in minions.size():
		var minion: Minion = minions[i]
		var wrapper = existing.get(minion.instance_id)
		var card: Card
		var incoming_ghost: Card = null
		if wrapper:
			card = _get_card_child(wrapper)
			shifted_from[card] = wrapper.get_global_rect().position
			# Interactive highlight/lift state never survives a refresh
			# (nothing re-establishes it afterward on a passive AI-triggered
			# refresh) - on a full rebuild this was implicitly cleared by the
			# node itself being new; a reused node has to be told explicitly.
			# data/minion are still set from this card's previous refresh, so
			# it's safe to call before configure below sets them for the
			# current one - unlike a freshly-created card, which has neither
			# yet.
			card.set_targeted(false)
			card.set_selected(false)
		else:
			card = CardScene.instantiate()
			wrapper = Control.new()
			zone.add_child(wrapper)
			wrapper.add_child(card)
			card.scale = card_scale
			card.position = BOARD_CARD_REST_POSITION
			# A ghost registered by _play_card_with_slam()/play_opponent_card_
			# with_slam() for this zone is waiting for exactly this moment -
			# this is the real board card it's flying toward (the first
			# brand-new card built in this zone while one's pending - see
			# _pending_slam_ghost_by_zone). Stay hidden until it lands (see
			# _slam_ghost_onto_card()). Zero-scale rather than
			# `.visible = false` so the card still participates in its
			# container's layout pass and lands in its true final slot -
			# _slam_ghost_onto_card() reads that wrapper's rect to aim the
			# flight at it.
			if _pending_slam_ghost_by_zone.has(zone):
				incoming_ghost = _pending_slam_ghost_by_zone[zone]
				_pending_slam_ghost_by_zone.erase(zone)
				card.scale = Vector2.ZERO
		# A Colossal minion occupies two board slots, so its cell is two slots
		# wide. Set every pass, not just on creation: a minion can gain or lose
		# the ability mid-life (Null strips it).
		wrapper.custom_minimum_size = Vector2(wrapper_size.x * PlayerState.slots_for(minion.abilities), wrapper_size.y)
		zone.move_child(wrapper, i)
		configure.call(card, minion)
		kept[minion.instance_id] = true
		if incoming_ghost:
			_slam_ghost_onto_card(incoming_ghost, card, wrapper, card_scale)

	if not shifted_from.is_empty():
		_settle_shifted_cards(zone, shifted_from)

	for instance_id in existing:
		if not kept.has(instance_id):
			var wrapper = existing[instance_id]
			# Lift the dying Card out of its wrapper before the wrapper goes,
			# so freeing the wrapper doesn't take the card with it mid-
			# dissolve. Reparented straight to `self` at the exact global
			# position it was already drawing at (the same trick
			# _slam_ghost_onto_card() uses for in-flight ghosts) - out of the
			# container, nothing re-sorts it, and its row closes the gap
			# behind it while it fades.
			var dying_card := _get_card_child(wrapper)
			if dying_card:
				var death_pos := dying_card.global_position
				wrapper.remove_child(dying_card)
				add_child(dying_card)
				dying_card.global_position = death_pos
				_play_death_animation(dying_card)
			wrapper.hide()
			wrapper.queue_free()
			zone.remove_child(wrapper)

## Dissolves a dying minion's Card and then frees it. Called (deliberately
## NOT awaited) by the removal loop above once that loop has detached the
## card from its wrapper - refresh() runs on nearly every action anywhere in
## a turn, including the AI's, so making it wait on a death fade would stall
## the whole board behind every trade.
func _play_death_animation(card: Card) -> void:
	await card.animate_death()
	if is_instance_valid(card):
		card.queue_free()

## Slides each already-on-board card in `old_positions` (Card -> its wrapper's
## global position before this reconcile pass moved anything - see
## _reconcile_board_zone()) from there to wherever it actually landed, instead
## of the container just snapping it there. Needed now that new creatures can
## insert into the middle of the row (see _board_insert_index_for_x()) and
## shove every card past the insertion point over by one - without this
## they'd hard-teleport sideways while the newly played card flies in
## smoothly next to them, which reads as broken. Offsets the Card node's own
## position within its wrapper (the same trick _slam_ghost_onto_card() and
## the rest of this file already use) rather than the wrapper's - the
## wrapper's position is container-owned and gets overwritten by the next
## sort, but the Card's own position inside it is free for us to animate.
## Reads positions only after `zone` itself confirms (via its own
## sort_children signal) it has actually resorted - see
## _slam_ghost_onto_card() for why that's more reliable than a fixed
## one-frame wait.
func _settle_shifted_cards(zone: Container, old_positions: Dictionary) -> void:
	await zone.sort_children
	# Untyped on purpose: a card whose minion died during the await above has
	# been freed, and assigning a freed instance to a typed `Card` loop
	# variable is itself an error ("Trying to assign invalid previously freed
	# instance") - it fires before any is_instance_valid() check can run.
	for key in old_positions:
		if not is_instance_valid(key):
			continue
		var card: Card = key
		var wrapper := card.get_parent()
		# A card whose minion died gets detached from its Control wrapper and
		# reparented straight to `self` (Node2D) for its own death animation
		# (see _reconcile_board_zone()'s removal loop) - if that happened to
		# this same card between when this slide was queued and now, there's
		# no wrapper rect left to slide toward; leave it to the death
		# animation instead of erroring on the type mismatch.
		if not is_instance_valid(wrapper) or not (wrapper is Control):
			continue
		var old_pos: Vector2 = old_positions[card]
		var new_pos: Vector2 = (wrapper as Control).get_global_rect().position
		var delta := old_pos - new_pos
		if delta.length() < 1.0:
			continue
		# A still-running slide tween from an earlier, rapid-fire reconcile
		# (see this function's doc comment) would otherwise keep animating
		# card.position at the same time this one starts, fighting over it -
		# kill it first so only one slide is ever driving this card.
		if card.has_meta(&"_slide_tween"):
			var prev_tween: Tween = card.get_meta(&"_slide_tween")
			if is_instance_valid(prev_tween):
				prev_tween.kill()
		card.position = BOARD_CARD_REST_POSITION + delta
		var tween := create_tween()
		card.set_meta(&"_slide_tween", tween)
		tween.tween_property(card, "position", BOARD_CARD_REST_POSITION, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _refresh_boards() -> void:
	var is_my_turn = game_state.is_local_player_turn()

	_reconcile_board_zone(player_board_zone, game_state.player.board, _BOARD_WRAPPER_SIZE, Card.SCALE_BOARD,
		func(card: Card, minion: Minion) -> void:
			card.setup_as_minion(minion)
			card.attack_outline_allowed = is_my_turn
			card.set_can_attack(is_my_turn and minion.can_attack())
			# Locations never attack, so the summoning-sick treatment would
			# just read as a permanent malfunction on them.
			card.set_summoning_sick(minion.is_exhausted and not minion.is_location())
			_note_minion_health(card, minion)
			if minion.is_newly_reinforced:
				minion.is_newly_reinforced = false
				_animate_reinforce_drop(card)
			if minion.is_newly_transformed:
				minion.is_newly_transformed = false
				card.animate_transform()
	)

	_reconcile_board_zone(opponent_board_zone, game_state.opponent.board, _BOARD_WRAPPER_SIZE, Card.SCALE_BOARD,
		func(card: Card, minion: Minion) -> void:
			card.setup_as_minion(minion)
			card.attack_outline_allowed = false
			card.set_can_attack(false)
			_note_minion_health(card, minion)
			if minion.is_newly_reinforced:
				minion.is_newly_reinforced = false
				_animate_reinforce_drop(card)
			if minion.is_newly_transformed:
				minion.is_newly_transformed = false
				card.animate_transform()
	)

	_prune_health_memory()

## ── Floating combat numbers ─────────────────────────────────────────────
## Purely a read of what changed between two refreshes: nothing in the rules
## core announces damage to the presentation layer, and nothing here feeds
## back into it. A minion's health moving down since the last refresh floats
## a red "-N" off its card, up floats a green "+N" - so a trade, a sweeper
## or a buff all say how much they did instead of only leaving a new number
## in the card's health box.
##
## Keyed on Minion.instance_id (stable per copy, the same key
## _reconcile_board_zone() reconciles on) rather than on the Card node,
## which survives some refreshes and is rebuilt on others.
var _last_minion_health: Dictionary = {}
var _last_hero_health: Dictionary = {}

const DAMAGE_NUMBER_COLOR := Color(1.0, 0.33, 0.28)
const HEAL_NUMBER_COLOR := Color(0.45, 0.92, 0.45)

func _note_minion_health(card: Card, minion: Minion) -> void:
	var key: String = minion.instance_id
	var now: int = minion.current_health
	# First sighting (a minion that just arrived, or the first refresh of the
	# match) has no "before" to compare against - record it and stay quiet,
	# so a creature doesn't float its own starting health as it lands.
	if not _last_minion_health.has(key):
		_last_minion_health[key] = now
		return
	var before: int = _last_minion_health[key]
	_last_minion_health[key] = now
	if now == before:
		return
	var at: Vector2 = card.global_position + Card.CARD_SIZE * card.scale * 0.5
	if now < before:
		_float_number(at, "-%d" % (before - now), DAMAGE_NUMBER_COLOR)
	else:
		_float_number(at, "+%d" % (now - before), HEAL_NUMBER_COLOR)

## Same idea for the two hero badges. Read here rather than inside
## HeroPanel.set_health() (which already does its own red gem flash) so every
## floating number in the match is spawned and styled in one place.
func _note_hero_health(hero: Panel, key: String, now: int) -> void:
	if not _last_hero_health.has(key):
		_last_hero_health[key] = now
		return
	var before: int = _last_hero_health[key]
	_last_hero_health[key] = now
	if now == before:
		return
	# Lifted off the badge's centre rather than starting on it: a hero badge
	# is a filled disc with an emblem drawn across the middle, and a number
	# spawning there spends its first beat unreadable on top of that emblem.
	var hero_rect: Rect2 = hero.get_global_rect()
	var at: Vector2 = hero_rect.get_center() - Vector2(0, hero_rect.size.y * 0.52)
	if now < before:
		_float_number(at, "-%d" % (before - now), DAMAGE_NUMBER_COLOR)
	else:
		_float_number(at, "+%d" % (now - before), HEAL_NUMBER_COLOR)

## Drops remembered health for minions that are no longer on either board, so
## a long match doesn't accumulate an entry per creature ever played. Safe to
## forget: instance_ids are unique per copy, so a minion that leaves and
## comes back (a bounce, a resurrect) is a different copy and correctly
## starts over with no "before".
func _prune_health_memory() -> void:
	if _last_minion_health.is_empty():
		return
	var live: Dictionary = {}
	for minion in game_state.player.board:
		live[minion.instance_id] = true
	for minion in game_state.opponent.board:
		live[minion.instance_id] = true
	for key in _last_minion_health.keys():
		if not live.has(key):
			_last_minion_health.erase(key)

## One floating number, parented to the board (not to the card it came off)
## so it outlives the refresh - and the death - that produced it. Rises,
## punches up to full size, then drifts and fades out.
const _FLOAT_NUMBER_BOX := Vector2(120, 56)
func _float_number(at: Vector2, text: String, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = _FLOAT_NUMBER_BOX
	label.size = _FLOAT_NUMBER_BOX
	label.pivot_offset = _FLOAT_NUMBER_BOX * 0.5
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("font", Card.CARD_FONT)
	label.add_theme_font_size_override("font_size", 40)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 7)
	label.add_theme_color_override("font_outline_color", Color(0.04, 0.02, 0.02))
	# Above every card and board zone - a number that reads as half-hidden
	# behind the card it belongs to is worse than none.
	label.z_as_relative = false
	label.z_index = 120
	add_child(label)
	label.global_position = at - _FLOAT_NUMBER_BOX * 0.5
	label.scale = Vector2(0.4, 0.4)
	label.modulate.a = 0.0

	var tween := label.create_tween().set_parallel(true)
	tween.tween_property(label, "scale", Vector2.ONE, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 1.0, 0.10)
	tween.tween_property(label, "position", label.position + Vector2(0, -46), 0.75).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, 0.30).set_delay(0.45)
	tween.chain().tween_callback(label.queue_free)

func _refresh_heroes() -> void:
	player_hero.set_health(game_state.player.hero_health)
	opponent_hero.set_health(game_state.opponent.hero_health)
	_note_hero_health(player_hero, "player", game_state.player.hero_health)
	_note_hero_health(opponent_hero, "opponent", game_state.opponent.hero_health)

func _refresh_ui() -> void:
	var is_my_turn = game_state.is_local_player_turn()
	end_turn_button.disabled = not is_my_turn
	_update_end_turn_button(is_my_turn)
	turn_label.text = "Turn %d" % game_state.turn_number
	var available_mana = game_state.player.max_mana - game_state.player.current_mana
	for i in _mana_dots.size():
		var dot = _mana_dots[i]
		if i < game_state.player.max_mana:
			dot.show()
			dot.modulate = Color.WHITE
			dot.set_meta("filled", i < available_mana)
			dot.queue_redraw()
		else:
			dot.hide()
	_pop_new_mana_crystals(game_state.player.max_mana)
	_deck_count_label.text = str(game_state.player.get_deck_size())
	_announce_turn_change(is_my_turn)

## Punches in each crystal the player gained since the last refresh, so the
## turn's new mana is something you see arrive rather than a row that is
## quietly one wider than it was.
##
## Animates the crystal's drawn size (the "pop" metadata
## _draw_mana_crystal() reads back - see there for why not the Control's own
## `scale`) and nothing else: _refresh_ui() above rewrites every dot's
## `modulate` on every refresh, and the drag-time affordability flash owns
## `modulate.a` outright (see _set_flash_alpha()), so a tween on colour here
## would be stomped or would fight that flash.
const MANA_POP_SCALE := 2.1
var _last_max_mana: int = -1
func _pop_new_mana_crystals(max_mana: int) -> void:
	# -1 is "first refresh of the match" - the opening crystals are part of
	# the board appearing, not something the player just gained.
	if _last_max_mana >= 0 and max_mana > _last_max_mana:
		for i in range(_last_max_mana, mini(max_mana, _mana_dots.size())):
			var dot: Control = _mana_dots[i]
			var tween := dot.create_tween()
			tween.tween_method(func(pop: float) -> void:
				dot.set_meta("pop", pop)
				dot.queue_redraw(),
				MANA_POP_SCALE, 1.0, 0.38).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_last_max_mana = max_mana

## ── Turn banner ─────────────────────────────────────────────────────────
## Sweeps "YOUR TURN" / "OPPONENT'S TURN" across the middle of the board
## whenever whose turn it is changes. Driven off what refresh() already
## knows rather than off a new signal out of the rules core, which stays
## unaware that any of this exists: the turn number plus whose turn it is
## is the whole state this needs, and comparing it against the last refresh
## is enough to fire exactly once per change.
var _last_turn_key: Array = []
## The banner currently on screen, if any. Two banners are never both up:
## a turn that passes back faster than one banner's life (the AI skipping a
## turn it can do nothing with, a concede) used to slide the new text across
## the old one. The new announcement is the true one, so it takes over.
var _live_turn_banner: Label = null
const _TURN_BANNER_HOLD := 0.55
func _announce_turn_change(is_my_turn: bool) -> void:
	var turn_key: Array = [game_state.turn_number, is_my_turn]
	if _last_turn_key.is_empty():
		# First refresh of the match: there is no change to announce yet, and
		# the mulligan is still on screen over the board anyway.
		_last_turn_key = turn_key
		return
	if turn_key == _last_turn_key:
		return
	_last_turn_key = turn_key
	if _game_over:
		return
	_show_turn_banner(is_my_turn)

func _show_turn_banner(is_my_turn: bool) -> void:
	if is_instance_valid(_live_turn_banner):
		_live_turn_banner.queue_free()
	var vp: Vector2 = get_viewport_rect().size
	var banner := Label.new()
	banner.text = "YOUR TURN" if is_my_turn else "OPPONENT'S TURN"
	banner.size = Vector2(vp.x, 70)
	banner.pivot_offset = banner.size * 0.5
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Never in the way of a click: this fires on the opponent's turn ending
	# too, which is the exact moment the player reaches for the board.
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.add_theme_font_override("font", Card.CARD_FONT)
	banner.add_theme_font_size_override("font_size", 44)
	banner.add_theme_color_override("font_color",
		Color(0.98, 0.93, 0.72) if is_my_turn else Color(0.92, 0.70, 0.66))
	banner.add_theme_constant_override("outline_size", 8)
	banner.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.02))
	banner.z_as_relative = false
	banner.z_index = 130
	add_child(banner)
	_live_turn_banner = banner
	# Sits above the centre bar, not across it: at the bar's own height the
	# banner reads on top of the turn counter and the End Turn button, which
	# is exactly what the player is looking at when a turn changes hands.
	banner.global_position = Vector2(0, vp.y * 0.30 - 35.0)
	banner.modulate.a = 0.0

	# Slides in from the side the turn is passing from - left for the
	# player's own turn, right for the opponent's - so the direction itself
	# says which way the turn just went.
	var from_x: float = -vp.x * 0.22 if is_my_turn else vp.x * 0.22
	var rest_x: float = banner.position.x
	banner.position.x = rest_x + from_x
	var tween := banner.create_tween()
	tween.set_parallel(true)
	tween.tween_property(banner, "position:x", rest_x, 0.26).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(banner, "modulate:a", 1.0, 0.18)
	tween.chain().tween_interval(_TURN_BANNER_HOLD)
	tween.chain().tween_property(banner, "modulate:a", 0.0, 0.25)
	tween.parallel().tween_property(banner, "position:x", rest_x - from_x, 0.25).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(banner.queue_free)

## True if the player still has a card they could play or a minion that
## hasn't attacked yet - drives End Turn's yellow-vs-green color and whether
## it needs one click or two (see _update_end_turn_button()). Uses the same
## affordability check _refresh_hand() already uses for the dim/playable
## look on hand cards, and the same can_attack() the board already uses for
## the gold "can attack" card outline, so this always agrees with what the
## player can already see is playable/attackable on screen.
func _player_has_actions_left() -> bool:
	for card_data in game_state.player.hand:
		if game_state.player.can_play_card(card_data):
			return true
	for minion in game_state.player.board:
		if minion.can_attack():
			return true
	return false

## Yellow + a confirming second click while _player_has_actions_left() is
## true, green + a single click once it's false, grey/disabled (Godot's
## normal disabled Button look - self_modulate reset to white so nothing
## here tints it) on the opponent's turn. See _end_turn_armed for why the
## armed/confirm state always resets here rather than surviving refreshes.
func _update_end_turn_button(is_my_turn: bool) -> void:
	if not is_my_turn:
		_end_turn_armed = false
		end_turn_button.self_modulate = Color.WHITE
		end_turn_button.text = "END TURN"
		return
	var has_actions := _player_has_actions_left()
	if not has_actions:
		_end_turn_armed = false
	if _end_turn_armed:
		end_turn_button.self_modulate = _END_TURN_COLOR_ACTIONS_LEFT
		end_turn_button.text = "CONFIRM?"
	elif has_actions:
		end_turn_button.self_modulate = _END_TURN_COLOR_ACTIONS_LEFT
		end_turn_button.text = "END TURN"
	else:
		end_turn_button.self_modulate = _END_TURN_COLOR_READY
		end_turn_button.text = "END TURN"

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
	if card.minion.has_ability(Abilities.AMBUSH):
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
				# If taunt exists only highlight taunts; never highlight ambush
				if (taunts.is_empty() or card.minion in taunts) and not card.minion.has_ability(Abilities.AMBUSH):
					card.set_targeted(true)
			else:
				card.set_targeted(false)
	_highlight_hero(opponent_hero, value and taunts.is_empty())

## True while a targeting/decline prompt (challenge, devour, buff-friendly,
## etc.) is still waiting on the player - ending the turn here would abandon
## it, leaving its mode flag stuck true so the next unrelated click on a
## friendly minion (even next turn, e.g. declaring an attacker) gets silently
## consumed as that prompt's target instead. See _on_decline_pressed for the
## matching list of modes.
func _has_pending_target_prompt() -> bool:
	return _challenge_mode or _on_play_damage_mode or _pilot_mode \
		or _yeti_select_mode or _tank_shot_mode or _on_play_pilot_mode \
		or _null_mode or _buff_friendly_mode or _choice_mode

## The generic choice prompt outliving the choice it was opened for (answered
## elsewhere, or withdrawn by the rules core) would leave every click and End
## Turn refusing with "resolve the pending choice". If the core has nothing
## pending the mode is just stale: tear it down and release anything awaiting it.
func _drop_stale_choice_mode() -> void:
	if not _choice_mode or game_state.has_pending_choice():
		return
	_end_choice_mode("")

func _on_end_turn_pressed() -> void:
	if end_turn_button.disabled:
		return
	_drop_stale_choice_mode()
	if _has_pending_target_prompt():
		log_action("Resolve the pending choice before ending your turn.")
		if _choice_mode and not decline_button.visible:
			show_decline_button()
		return
	# Actions still available (yellow button) needs a confirming second
	# click - see _end_turn_armed - rather than ending the turn on this one.
	if _player_has_actions_left() and not _end_turn_armed:
		_end_turn_armed = true
		_update_end_turn_button(true)
		return
	# Disabled synchronously, before emit(), so a second press arriving
	# before the listener's own turn-state refresh runs can't queue up
	# another end_turn_pressed - see GameManagerAutoload's matching
	# _end_turn_in_progress guard for why overlapping end-turns are unsafe.
	end_turn_button.disabled = true
	_end_turn_armed = false
	_clear_selections()
	end_turn_pressed.emit()

func _clear_selections() -> void:
	if is_instance_valid(selected_attacker):
		selected_attacker.set_selected(false)
	selected_attacker = null
	# Targeting mode may be ending on the same click that resolves it, with
	# the mouse never moving off the target afterward - re-check right away
	# instead of waiting for the next InputEventMouseMotion to revert.
	_update_target_cursor(null)
	_highlight_attack_targets(false)
	_highlight_hero(opponent_hero, false)
	_highlight_mech_targets(false)
	_piloting_minion = null
	# Prompts this function does not itself end keep their Decline button;
	# hiding it left the prompt open with no way to answer it.
	if not (_choice_mode or _null_mode or _buff_friendly_mode or _on_play_pilot_mode or _challenge_mode):
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

const LOG_FONT_SIZE := 17
const LOG_MAX_ENTRIES := 400
const LOG_NAME_COLOR := "#ffd36a"
const LOG_TEXT_COLOR := Color(0.93, 0.93, 0.95)
const LOG_HEADER_COLOR := Color(0.72, 0.58, 0.25)

## Matches any catalog card name as a whole phrase, longest first so "Commander
## Maurice, Local Legend" wins over a shorter name inside it. Built once, on
## first use (the catalog autoload is ready by then).
var _log_name_regex: RegEx = null
var _log_name_to_id: Dictionary = {}

func _build_log_name_regex() -> void:
	_log_name_regex = RegEx.new()
	var names: Array[String] = []
	for card in CardDatabase.get_all_cards():
		if card.card_name.is_empty() or _log_name_to_id.has(card.card_name):
			continue
		_log_name_to_id[card.card_name] = card.id
		names.append(card.card_name)
	names.sort_custom(func(a: String, b: String): return a.length() > b.length())
	var escaped: Array[String] = []
	for n in names:
		var e := n
		for ch in ["\\", ".", "+", "*", "?", "(", ")", "[", "]", "{", "}", "|", "^", "$"]:
			e = e.replace(ch, "\\" + ch)
		escaped.append(e)
	if escaped.is_empty():
		_log_name_regex = null
		return
	_log_name_regex.compile("(?<![A-Za-z0-9])(?:" + "|".join(escaped) + ")(?![A-Za-z0-9])")

static func _bb_escape(text: String) -> String:
	return text.replace("[", "[lb]")

## BBCode for one log line: every known card name becomes a gold link whose
## meta is the card id (hovering it shows the card, see _on_log_meta_hover).
func _log_markup(text: String) -> String:
	if _log_name_regex == null and _log_name_to_id.is_empty():
		_build_log_name_regex()
	if _log_name_regex == null:
		return _bb_escape(text)
	var out := ""
	var last := 0
	for m in _log_name_regex.search_all(text):
		out += _bb_escape(text.substr(last, m.get_start() - last))
		var matched := m.get_string()
		out += "[url=%s][color=%s]%s[/color][/url]" % [_log_name_to_id.get(matched, ""), LOG_NAME_COLOR, _bb_escape(matched)]
		last = m.get_end()
	out += _bb_escape(text.substr(last))
	return out

func log_action(text: String) -> void:
	var is_header := text.begins_with("---")
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND
	label.add_theme_font_size_override("normal_font_size", LOG_FONT_SIZE)
	label.add_theme_color_override("default_color", LOG_HEADER_COLOR if is_header else LOG_TEXT_COLOR)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 3)
	if is_header:
		label.text = "[center]%s[/center]" % _bb_escape(text)
	else:
		label.text = _log_markup(text)
		label.meta_hover_started.connect(_on_log_meta_hover)
		label.meta_hover_ended.connect(_on_log_meta_hover_ended)
	combat_log_vbox.add_child(label)
	while combat_log_vbox.get_child_count() > LOG_MAX_ENTRIES:
		var oldest := combat_log_vbox.get_child(0)
		combat_log_vbox.remove_child(oldest)
		oldest.queue_free()
	# fit_content sizes the label a frame after it is added.
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(combat_log_scroll):
		combat_log_scroll.scroll_vertical = int(combat_log_scroll.get_v_scroll_bar().max_value)

## Hovering a card name in the log shows that card beside the log, with its
## keyword tooltips, exactly like hovering it on the board.
func _on_log_meta_hover(meta: Variant) -> void:
	var card_data: CardData = CardDatabase.get_card(str(meta))
	if card_data == null:
		return
	var panel_rect: Rect2 = $CombatLogPanel.get_global_rect()
	var mouse_y := get_viewport().get_mouse_position().y
	_hover_card = null
	_show_card_preview(card_data, null, Rect2(panel_rect.position.x, mouse_y - 1.0, panel_rect.size.x, 2.0))

func _on_log_meta_hover_ended(_meta: Variant) -> void:
	_hide_card_preview()

func _blink_card_green(card: Card) -> void:
	var tween = card.create_tween().set_loops(3)
	tween.tween_property(card, "modulate", Color(0.3, 1.0, 0.3), 0.15)
	tween.tween_property(card, "modulate", Color(1.0, 1.0, 1.0), 0.15)

## Drops a just-reinforced green minion's Card in from directly above its
## board slot instead of it just appearing in place - REINFORCE (green-only,
## see abilities.gd/data/cards/green.json) replaces a dead minion with a
## fresh copy in the same slot, and _reconcile_board_zone() builds that
## replacement as a brand-new Card already sitting at its correct rest
## position/scale by the time this runs (configure() below fires right after
## creation) - so unlike the play-from-hand "slam" (see
## _slam_ghost_onto_card()) there's no separate ghost/target-matching needed,
## just offsetting this card's own position upward from its already-correct
## spot (same trick _settle_shifted_cards() uses) and falling it back down.
func _animate_reinforce_drop(card: Card) -> void:
	const DROP_HEIGHT := 500.0
	var rest_scale: Vector2 = card.scale
	card.position = BOARD_CARD_REST_POSITION - Vector2(0, DROP_HEIGHT)
	var fall := create_tween()
	fall.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	fall.tween_property(card, "position", BOARD_CARD_REST_POSITION, 0.35)
	await fall.finished
	if not is_instance_valid(card):
		return
	# Impact: land already squashed from the "thud", then settle - same
	# beat _slam_ghost_onto_card()'s impact uses - plus the original green
	# blink so a reinforced minion still reads as buffed/refreshed, not just
	# freshly dropped.
	card.scale = rest_scale * Vector2(1.25, 0.72)
	var impact := create_tween()
	impact.tween_property(card, "scale", rest_scale, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_blink_card_green(card)

## Hearthstone-style "announce": flashes card_data big on the right side of
## the screen and holds for hold_time before hiding again. Callers await this
## BEFORE mutating game_state so the pause happens ahead of resolution, not
## after - the whole point is giving the opponent a beat to read the card
## before its effect (or its arrival on the battlefield) lands.
func announce_card(card_data: CardData, hold_time: float = 0.8) -> void:
	var vp: Vector2 = get_viewport_rect().size
	card_preview_zone.global_position = Vector2(vp.x - _PREVIEW_W - _PREVIEW_PAD, (vp.y - _PREVIEW_H - _PREVIEW_BOTTOM_MARGIN) * 0.5)
	_show_card_preview(card_data)
	await get_tree().create_timer(hold_time).timeout
	preview_card.modulate = Color(1, 1, 1, 0)
	preview_card.visible = false

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

## Lunge at the enemy hero. The going-face counterpart to
## animate_creature_attack(): same lunge-and-return shape so the two read as
## the same action, but the target is a hero badge rather than a card, so the
## impact lands on the portrait and the hero recoils instead of a card taking
## a damage flash.
##
## Attacking face used to have no animation at all - the hero's number simply
## dropped - which made the game's most decisive action its least legible.
func animate_creature_attack_face(attacker_instance_id: String, attacker_player_id: String) -> void:
	if game_state == null:
		return
	var is_local_attacker: bool = attacker_player_id == game_state.player.player_id
	var attacker_zone: HBoxContainer = player_board_zone if is_local_attacker else opponent_board_zone
	var target_hero: Panel = opponent_hero if is_local_attacker else player_hero

	var attacker_card: Card = null
	for wrapper in attacker_zone.get_children():
		var card := _get_card_child(wrapper)
		if card and card.minion and card.minion.instance_id == attacker_instance_id:
			attacker_card = card
			break
	if attacker_card == null or not is_instance_valid(target_hero):
		return

	var attacker_center: Vector2 = attacker_card.get_parent().get_global_rect().get_center()
	var target_center: Vector2 = target_hero.get_global_rect().get_center()
	var delta: Vector2 = target_center - attacker_center
	# Stop short of the portrait: landing on top of it would hide the very
	# thing the hit is about, and the recoil below sells the contact.
	var reach := delta.length()
	if reach > 1.0:
		delta *= maxf(reach - 78.0, 0.0) / reach

	var base_pos := attacker_card.position
	attacker_card.z_as_relative = false
	attacker_card.z_index = 100

	var tween := create_tween()
	tween.tween_property(attacker_card, "position", base_pos + delta, 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_callback(func(): _hero_impact(target_hero))
	tween.tween_property(attacker_card, "position", base_pos, 0.17) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await tween.finished

	# The board can refresh (and free this card) while the tween runs.
	if not is_instance_valid(attacker_card):
		return
	attacker_card.z_as_relative = true
	attacker_card.z_index = 0
	attacker_card.position = base_pos

## Red flash and a shove away from the attacker on a hero badge taking a hit.
##
## The resting position is cached in a meta the first time rather than read
## live: two hits in quick succession (Dual Strike, several attackers) would
## otherwise start the second tween from a mid-recoil position and leave the
## badge permanently drifted off its slot.
func _hero_impact(hero: Panel) -> void:
	if not is_instance_valid(hero):
		return
	if not hero.has_meta(&"_rest_position"):
		hero.set_meta(&"_rest_position", hero.position)
	var home: Vector2 = hero.get_meta(&"_rest_position")
	if hero.has_meta(&"_impact_tween"):
		var prev: Tween = hero.get_meta(&"_impact_tween")
		if is_instance_valid(prev):
			prev.kill()
	hero.position = home
	hero.modulate = Color.WHITE

	# Shoved away from whoever hit it: the player's hero is struck from above.
	var shove := Vector2(0, 12.0 if hero == player_hero else -12.0)
	var t := hero.create_tween()
	hero.set_meta(&"_impact_tween", t)
	t.set_parallel(true)
	t.tween_property(hero, "modulate", Color(1.8, 0.7, 0.7), 0.07)
	t.tween_property(hero, "position", home + shove, 0.07).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.chain().set_parallel(true)
	t.tween_property(hero, "modulate", Color.WHITE, 0.24)
	t.tween_property(hero, "position", home, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

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
	var overlay := _open_modal_overlay()

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

	var cards_scroll = ScrollContainer.new()
	cards_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cards_scroll.custom_minimum_size = Vector2(0, minf(PICKER_WRAPPER_SIZE.y * 2 + 8, 640))
	panel.add_child(cards_scroll)

	var cards_container = VBoxContainer.new()
	cards_container.add_theme_constant_override("separation", 8)
	cards_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards_scroll.add_child(cards_container)

	var preview := _make_picker_preview(overlay)
	var _selection_made := false
	var current_row: HBoxContainer = null
	var cards_in_row := 0
	const MAX_PER_ROW := 8

	for card_data in options:
		if current_row == null or cards_in_row >= MAX_PER_ROW:
			current_row = HBoxContainer.new()
			current_row.add_theme_constant_override("separation", 10)
			current_row.alignment = BoxContainer.ALIGNMENT_CENTER
			current_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cards_container.add_child(current_row)
			cards_in_row = 0
		var wrapper = Button.new()
		wrapper.custom_minimum_size = PICKER_WRAPPER_SIZE
		wrapper.flat = true
		current_row.add_child(wrapper)
		var card = CardScene.instantiate()
		card.scale = PICKER_CARD_SCALE
		card.position = Vector2(0, 0)
		wrapper.add_child(card)
		card.setup(card_data)
		card.input_pickable = false
		card.set_process_input(false)
		_ignore_control_input(card)
		var captured := card_data
		_hook_picker_hover(wrapper, captured, preview)
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
	_close_modal_overlay(overlay)
	return chosen

func _open_graveyard_viewer() -> void:
	if game_state == null or game_state.player == null:
		return
	var graveyard := game_state.player.graveyard
	var overlay := _open_modal_overlay()

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
		var cards_scroll := ScrollContainer.new()
		cards_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		cards_scroll.custom_minimum_size = Vector2(0, minf(PICKER_WRAPPER_SIZE.y * 2 + 8, 640))
		panel.add_child(cards_scroll)

		var cards_container := VBoxContainer.new()
		cards_container.add_theme_constant_override("separation", 8)
		cards_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cards_scroll.add_child(cards_container)

		const MAX_PER_ROW := 8
		var preview := _make_picker_preview(overlay)
		var current_row: HBoxContainer = null
		var cards_in_row := 0
		for card_data in graveyard:
			if current_row == null or cards_in_row >= MAX_PER_ROW:
				current_row = HBoxContainer.new()
				current_row.add_theme_constant_override("separation", 10)
				current_row.alignment = BoxContainer.ALIGNMENT_CENTER
				current_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				cards_container.add_child(current_row)
				cards_in_row = 0
			var wrapper := Control.new()
			wrapper.custom_minimum_size = PICKER_WRAPPER_SIZE
			current_row.add_child(wrapper)
			var card := CardScene.instantiate()
			card.scale = PICKER_CARD_SCALE
			card.position = Vector2(0, 0)
			wrapper.add_child(card)
			card.setup(card_data)
			_ignore_control_input(card)
			_hook_picker_hover(wrapper, card_data, preview)
			cards_in_row += 1

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(100, 34)
	close_btn.pressed.connect(_close_modal_overlay.bind(overlay))
	panel.add_child(close_btn)

func show_transform_picker(options: Array[CardData]) -> CardData:
	var overlay := _open_modal_overlay()

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
		wrapper.custom_minimum_size = PICKER_WRAPPER_SIZE
		wrapper.flat = true
		cards_row.add_child(wrapper)
		var card = CardScene.instantiate()
		card.scale = PICKER_CARD_SCALE
		card.position = Vector2(0, 0)
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
	_close_modal_overlay(overlay)
	return chosen

## Opening-hand mulligan: shows every card in `hand` face up, click one to
## mark it with an X (click again to unmark), then Start confirms - returns
## the CardData instances that were marked when Start was pressed. Doesn't
## touch game_state itself; the caller applies the swap (see
## GameState.mulligan_swap()) so this stays a pure "ask the player" step,
## reusable for both the local player's own hand and (in multiplayer) purely
## as a picker whose result gets relayed instead of applied locally.
## Set by headless test harnesses before start_local_game(). The mulligan
## blocks on `await start_button.pressed`, and a headless harness has no way
## to press it, so the match sits in the mulligan forever - which from the
## outside is indistinguishable from the AI hanging. With this set the
## opening hand is kept and play continues immediately.
var auto_confirm_mulligan: bool = false

## The mulligan shows the opening hand at the LARGE card size (it is the one
## screen where reading every card matters most), shrunk only if a hand is ever
## too wide for the screen.
const MULLIGAN_MAX_ROW_WIDTH := 1700.0
const MULLIGAN_CARD_GAP := 28.0
const MULLIGAN_DEAL_TIME := 0.5
const MULLIGAN_DEAL_GAP := 0.14
const MULLIGAN_DIM_TIME := 0.7
const MULLIGAN_READ_TIME := 1.4  # replacements stay up this long before the screen closes
const MULLIGAN_START_DIAMETER := 132.0

## A green, round confirm button - same look at rest, hover and press.
static func _make_round_start_button(diameter: float) -> Button:
	var button := Button.new()
	button.text = "START"
	button.custom_minimum_size = Vector2(diameter, diameter)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 24)
	button.add_theme_color_override("font_color", Color.WHITE)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color(0.9, 1.0, 0.9))
	button.add_theme_color_override("font_disabled_color", Color(0.8, 0.9, 0.8, 0.7))
	button.add_theme_color_override("font_outline_color", Color(0.0, 0.25, 0.05))
	button.add_theme_constant_override("outline_size", 5)
	var states := {
		"normal": Color(0.16, 0.68, 0.28),
		"hover": Color(0.24, 0.80, 0.37),
		"pressed": Color(0.10, 0.50, 0.20),
		"disabled": Color(0.25, 0.45, 0.30),
	}
	for state in states:
		var box := StyleBoxFlat.new()
		box.bg_color = states[state]
		box.set_corner_radius_all(int(diameter / 2.0))
		box.border_color = Color(0.78, 1.0, 0.80)
		box.set_border_width_all(5)
		box.shadow_color = Color(0, 0, 0, 0.45)
		box.shadow_size = 10
		button.add_theme_stylebox_override(state, box)
	return button

## Flies one mulligan card from the deck into its slot (a wrapper in the cards
## row) and waits for it to land, plus a short beat so deals read one by one.
func _mulligan_deal_card(card: Card, wrapper: Control, deck_center: Vector2, rest_scale: Vector2, card_pixels: Vector2) -> void:
	card.scale = rest_scale * 0.3
	card.position = deck_center - wrapper.global_position - card_pixels * 0.15
	card.modulate.a = 0.0
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "position", Vector2.ZERO, MULLIGAN_DEAL_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", rest_scale, MULLIGAN_DEAL_TIME).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "modulate:a", 1.0, MULLIGAN_DEAL_TIME * 0.4)
	await tween.finished
	await get_tree().create_timer(MULLIGAN_DEAL_GAP).timeout

## `apply_swaps(swaps) -> Array[CardData]` (optional) is how the replacements
## get on screen: after the marked cards fly back to the deck the screen calls
## it - the caller applies the swap to the match (even for an empty `swaps`, so
## a multiplayer guest still reports "no changes") and returns the cards that
## came in. Each one is then dealt from the deck into the slot it replaces and
## held there to be read, Hearthstone-style, before the screen closes. Without
## it the screen only reports what was marked and the caller swaps afterwards.
func show_mulligan_screen(hand: Array[CardData], apply_swaps: Callable = Callable()) -> Array[CardData]:
	if auto_confirm_mulligan:
		if apply_swaps.is_valid():
			await apply_swaps.call([] as Array[CardData])
		return [] as Array[CardData]
	var overlay := _open_modal_overlay()

	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.82)
	# The table dims away from the (still empty) battlefield as the game
	# starts, instead of the screen snapping to black.
	bg.modulate.a = 0.0
	create_tween().tween_property(bg, "modulate:a", 1.0, MULLIGAN_DIM_TIME)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(bg)

	var panel = VBoxContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.add_theme_constant_override("separation", 30)
	panel.modulate.a = 0.0
	create_tween().tween_property(panel, "modulate:a", 1.0, MULLIGAN_DIM_TIME)
	overlay.add_child(panel)

	var title = Label.new()
	title.text = "Mulligan - click a card to replace it"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_outline_color", Color.BLACK)
	title.add_theme_constant_override("outline_size", 6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title)

	# LARGE unless the row would not fit.
	var card_scale: Vector2 = Card.SCALE_LARGE
	var card_pixels: Vector2 = Card.PIXELS_LARGE
	var row_width := hand.size() * (card_pixels.x + 14.0) + maxi(0, hand.size() - 1) * MULLIGAN_CARD_GAP
	if row_width > MULLIGAN_MAX_ROW_WIDTH and hand.size() > 0:
		var fit := MULLIGAN_MAX_ROW_WIDTH / row_width
		card_scale *= fit
		card_pixels *= fit
	var wrapper_size := card_pixels + Vector2(14, 18)

	var cards_row = HBoxContainer.new()
	cards_row.add_theme_constant_override("separation", int(MULLIGAN_CARD_GAP))
	cards_row.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(cards_row)

	# Keyed by CardData instance (reference identity) rather than card id, so
	# two copies of the same card in hand can be marked independently.
	var marked: Dictionary = {}
	# card_data -> its Card node, so the Start handler below can pull marked
	# cards out of cards_row and fly them to the deck.
	var card_nodes: Dictionary = {}
	var wrappers: Array[Button] = []

	for card_data in hand:
		var wrapper = Button.new()
		wrapper.custom_minimum_size = wrapper_size
		wrapper.flat = true
		wrapper.disabled = true  # until the deal finishes
		cards_row.add_child(wrapper)
		wrappers.append(wrapper)
		var card = CardScene.instantiate()
		card.scale = card_scale
		card.position = Vector2(0, 0)
		wrapper.add_child(card)
		card.setup(card_data)
		card.input_pickable = false
		card.set_process_input(false)
		_ignore_control_input(card)
		card.visible = false  # revealed by the deal below
		card_nodes[card_data] = card

		var x_label = Label.new()
		x_label.text = "X"
		x_label.add_theme_font_size_override("font_size", 150)
		x_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2, 0.92))
		x_label.add_theme_color_override("font_outline_color", Color.BLACK)
		x_label.add_theme_constant_override("outline_size", 8)
		x_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		x_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		x_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		x_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		x_label.visible = false
		wrapper.add_child(x_label)

		marked[card_data] = false
		var captured := card_data
		wrapper.pressed.connect(func():
			var now_marked: bool = not marked[captured]
			marked[captured] = now_marked
			x_label.visible = now_marked
			card.set_playable(not now_marked)
		)

	var start_button := _make_round_start_button(MULLIGAN_START_DIAMETER)
	start_button.disabled = true
	start_button.modulate.a = 0.0
	panel.add_child(start_button)

	# --- Deal the opening hand from the deck, one card at a time ---
	# The container lays the row out on the next frames; flight paths are
	# measured from the real slots, so wait for them.
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(MULLIGAN_DIM_TIME * 0.6).timeout
	var deck_center := Vector2(1690, 725) + Vector2(41, 60)
	if is_instance_valid(_player_deck_icon):
		deck_center = _player_deck_icon.global_position + Vector2(41, 60)
	var deck_visual: Node2D = CardBackScene.instantiate()
	deck_visual.scale = Vector2(0.75, 0.75)
	deck_visual.position = deck_center - Vector2(41, 60)
	overlay.add_child(deck_visual)
	for i in hand.size():
		if not is_instance_valid(overlay):
			return [] as Array[CardData]
		var card: Card = card_nodes[hand[i]]
		card.visible = true
		await _mulligan_deal_card(card, wrappers[i], deck_center, card_scale, card_pixels)
	if is_instance_valid(deck_visual):
		deck_visual.queue_free()
	for wrapper in wrappers:
		wrapper.disabled = false
	start_button.disabled = false
	create_tween().tween_property(start_button, "modulate:a", 1.0, 0.25)

	await start_button.pressed
	start_button.disabled = true

	var swaps: Array[CardData] = []
	for card_data in hand:
		if marked[card_data]:
			swaps.append(card_data)

	# Marked cards slide/shrink into the deck icon before the screen closes,
	# instead of just vanishing with the rest of the overlay - reparented out
	# of cards_row (an HBoxContainer, which would otherwise fight any attempt
	# to tween a child's own position every layout pass) directly onto the
	# overlay so they're free to animate. _close_modal_overlay() below still
	# finds and frees them via its own recursive Card sweep even after the
	# reparent.
	if not swaps.is_empty() and is_instance_valid(_player_deck_icon):
		var last_tween: Tween = null
		for card_data in swaps:
			var card: Card = card_nodes.get(card_data)
			if not is_instance_valid(card):
				continue
			var start_global: Vector2 = card.global_position
			card.get_parent().remove_child(card)
			overlay.add_child(card)
			card.global_position = start_global
			var tween := create_tween()
			tween.set_parallel(true)
			tween.tween_property(card, "global_position", _player_deck_icon.global_position, 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
			tween.tween_property(card, "scale", card.scale * 0.3, 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
			tween.tween_property(card, "modulate:a", 0.0, 0.4)
			last_tween = tween
		if last_tween:
			await last_tween.finished

	if apply_swaps.is_valid():
		var incoming: Array[CardData] = []
		for c in await apply_swaps.call(swaps):
			incoming.append(c)
		# Each replacement lands in the slot of the card it replaces.
		var deck_back: Node2D = CardBackScene.instantiate()
		deck_back.scale = Vector2(0.75, 0.75)
		deck_back.position = deck_center - Vector2(41, 60)
		overlay.add_child(deck_back)
		for i in mini(incoming.size(), swaps.size()):
			if not is_instance_valid(overlay):
				return swaps
			var slot: Control = wrappers[hand.find(swaps[i])]
			var fresh: Card = CardScene.instantiate()
			fresh.scale = card_scale
			slot.add_child(fresh)
			fresh.setup(incoming[i])
			fresh.input_pickable = false
			fresh.set_process_input(false)
			_ignore_control_input(fresh)
			await _mulligan_deal_card(fresh, slot, deck_center, card_scale, card_pixels)
		deck_back.queue_free()
		if not incoming.is_empty():
			# Time to actually read what you drew before it joins your hand.
			await get_tree().create_timer(MULLIGAN_READ_TIME).timeout
		if is_instance_valid(bg):
			var fade := create_tween().set_parallel(true)
			fade.tween_property(bg, "modulate:a", 0.0, 0.3)
			fade.tween_property(panel, "modulate:a", 0.0, 0.3)
			await fade.finished

	_close_modal_overlay(overlay)
	return swaps

func _stratagem_needs_target(data: CardData) -> bool:
	return data.effect not in ["destroy_all_creatures", "deal_damage_all_creatures", "deal_damage_all_enemy", "deal_damage_all_enemy_draw_yeti", "buff_all_friendly_attack", "buff_all_friendly_health", "eject_all_pilots", "sludge_spray"]

func _stratagem_needs_creature_target(data: CardData) -> bool:
	return data.effect in ["give_ability", "buff_creature", "buff_health", "force_challenge", "poke_bear", "blood_transfusion", "sanguine", "heal", "eject_pilot", "give_mech_shielded_temp", "tainted_blood", "exsanguinate", "blood_boil", "return_friendly_to_hand"]

func _stratagem_needs_friendly_yeti(data: CardData) -> bool:
	return data.effect in ["force_challenge", "poke_bear"]

func _stratagem_needs_enemy_creature_only(data: CardData) -> bool:
	return data.effect in ["blood_transfusion", "exsanguinate"]

func _stratagem_needs_friendly_creature_only(data: CardData) -> bool:
	return data.effect in ["sanguine", "heal", "give_ability", "tainted_blood", "blood_boil", "return_friendly_to_hand"]

func _stratagem_needs_friendly_piloted_mech(data: CardData) -> bool:
	return data.effect == "eject_pilot"

func _stratagem_needs_friendly_mech(data: CardData) -> bool:
	return data.effect == "give_mech_shielded_temp"

func _highlight_friendly_mech_targets(value: bool) -> void:
	for wrapper in player_board_zone.get_children():
		if wrapper.get_child_count() == 0:
			continue
		var card = wrapper.get_child(0)
		if card is Card and card.minion.has_ability(Abilities.MECH):
			card.set_targeted(value, true)

func _highlight_piloted_mech_targets(value: bool) -> void:
	for wrapper in player_board_zone.get_children():
		if wrapper.get_child_count() == 0:
			continue
		var card = wrapper.get_child(0)
		if card is Card and card.minion.is_piloted:
			card.set_targeted(value, true)

func _ignore_control_input(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_control_input(child)

func find_card_node(instance_id: String) -> Card:
	for zone in [player_board_zone, opponent_board_zone]:
		for wrapper in zone.get_children():
			var card = _get_card_child(wrapper)
			if card and card.minion and card.minion.instance_id == instance_id:
				return card
	return null

func animate_laser_kill(from_global: Vector2, target_card: Card) -> void:
	if not is_instance_valid(target_card):
		return
	var target_center: Vector2 = target_card.get_parent().get_global_rect().get_center()
	var line := Line2D.new()
	line.default_color = Color(1.0, 0.12, 0.12, 1.0)
	line.width = 4.0
	line.z_index = 200
	line.add_point(to_local(from_global))
	line.add_point(to_local(target_center))
	add_child(line)
	target_card.damage_flash()
	var tween := create_tween()
	tween.tween_interval(0.12)
	tween.tween_property(line, "modulate:a", 0.0, 0.20)
	await tween.finished
	line.queue_free()

func _show_pause_menu() -> void:
	_pause_overlay = CanvasLayer.new()
	_pause_overlay.layer = 20
	add_child(_pause_overlay)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.72)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_pause_overlay.add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vbox.grow_vertical = Control.GROW_DIRECTION_BOTH
	vbox.add_theme_constant_override("separation", 18)
	_pause_overlay.add_child(vbox)

	var title := Label.new()
	title.text = "PAUSED"
	title.add_theme_font_size_override("font_size", 52)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var resume_btn := _pause_btn("Resume")
	resume_btn.pressed.connect(_close_pause_menu)
	vbox.add_child(resume_btn)

	if not is_online:
		var restart_btn := _pause_btn("Restart Battle")
		restart_btn.pressed.connect(func():
			_close_pause_menu()
			restart_requested.emit()
		)
		vbox.add_child(restart_btn)

	if concede_enabled:
		# Leaving a server-run match is conceding it: the server settles it.
		var concede_btn := _pause_btn("Concede")
		concede_btn.pressed.connect(func():
			_close_pause_menu()
			concede_requested.emit()
		)
		vbox.add_child(concede_btn)
	else:
		var quit_btn := _pause_btn("Quit to Menu")
		quit_btn.pressed.connect(func(): get_tree().reload_current_scene())
		vbox.add_child(quit_btn)

func _close_pause_menu() -> void:
	if _pause_overlay != null:
		_pause_overlay.queue_free()
		_pause_overlay = null

func _pause_btn(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(240, 58)
	btn.add_theme_font_size_override("font_size", 22)
	return btn

## Nameplate for the current opponent (real username for a matched PvP
## opponent, a fake bot name for AI matches) — top-right of the screen,
## regardless of where the opponent hero portrait itself sits on the board.
func set_opponent_name(display_name: String) -> void:
	if _opponent_name_label == null:
		var layer := CanvasLayer.new()
		add_child(layer)
		_opponent_name_label = Label.new()
		_opponent_name_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		_opponent_name_label.offset_left = -280
		_opponent_name_label.offset_top = 12
		_opponent_name_label.offset_right = -16
		_opponent_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_opponent_name_label.add_theme_font_size_override("font_size", 18)
		layer.add_child(_opponent_name_label)
	_opponent_name_label.text = display_name

## Campaign mode only: persistent top-left reminder of the current node's
## modifier (e.g. "Dunes: All creatures have Ambush"), mirrors
## set_opponent_name's lazy-create pattern. Callers just skip calling this
## for an unmodified node.
func set_node_modifier_label(text: String) -> void:
	if _node_modifier_label == null:
		var layer := CanvasLayer.new()
		add_child(layer)
		_node_modifier_label = Label.new()
		_node_modifier_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_node_modifier_label.offset_left = 16
		_node_modifier_label.offset_top = 12
		_node_modifier_label.offset_right = 420
		_node_modifier_label.add_theme_font_size_override("font_size", 16)
		layer.add_child(_node_modifier_label)
	_node_modifier_label.text = text

## A blocking message with one button back to the menu (a match that ended
## without a result, such as a voided ranked match).
func show_notice(text: String) -> void:
	_game_over = true
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(root)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.75)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vbox.grow_vertical = Control.GROW_DIRECTION_BOTH
	root.add_child(vbox)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 28)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(label)
	var btn := Button.new()
	btn.text = "Back to Menu"
	btn.custom_minimum_size = Vector2(180, 48)
	btn.pressed.connect(func(): get_tree().reload_current_scene())
	vbox.add_child(btn)

func show_game_over(won: bool, is_ranked: bool = false, old_bracket: int = 0,
					 old_in_legend: bool = false, old_legend_rating: int = 0,
					 is_campaign: bool = false) -> void:
	_game_over = true
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

	if is_ranked:
		# Old -> new rank icons flank the text once the server acks (filled in
		# by _connect_ranked_result_display); hidden until then.
		var rank_icons := HBoxContainer.new()
		rank_icons.alignment = BoxContainer.ALIGNMENT_CENTER
		rank_icons.add_theme_constant_override("separation", 14)
		rank_icons.visible = false
		vbox.add_child(rank_icons)

		var rank_lbl := Label.new()
		rank_lbl.text = "Updating rank..."
		rank_lbl.add_theme_font_size_override("font_size", 22)
		rank_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(rank_lbl)
		_connect_ranked_result_display(rank_lbl, won, old_bracket, old_in_legend, old_legend_rating, rank_icons)

		var btn_row := HBoxContainer.new()
		btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
		btn_row.add_theme_constant_override("separation", 16)
		vbox.add_child(btn_row)

		var queue_btn := Button.new()
		queue_btn.text = "Queue"
		queue_btn.custom_minimum_size = Vector2(160, 48)
		queue_btn.pressed.connect(func(): ranked_requeue_requested.emit())
		btn_row.add_child(queue_btn)

		var quit_btn := Button.new()
		quit_btn.text = "Quit"
		quit_btn.custom_minimum_size = Vector2(160, 48)
		quit_btn.pressed.connect(func(): get_tree().reload_current_scene())
		btn_row.add_child(quit_btn)
	elif is_campaign:
		var btn := Button.new()
		btn.text = "Continue"
		btn.custom_minimum_size = Vector2(160, 48)
		btn.pressed.connect(func(): campaign_continue_requested.emit())
		vbox.add_child(btn)
	else:
		var btn = Button.new()
		btn.text = "Play Again"
		btn.custom_minimum_size = Vector2(160, 48)
		btn.pressed.connect(func():
			if is_online:
				get_tree().reload_current_scene()
			else:
				restart_requested.emit()
		)
		vbox.add_child(btn)

## Fills in `rank_lbl` once the server acks the ranked result Auth already
## sent in _handle_game_over — shows the old -> new tier/rating so a rank
## up/down is visible on the game-over screen instead of only on the next
## visit to the Ranked menu.
func _connect_ranked_result_display(rank_lbl: Label, won: bool, old_bracket: int,
								   old_in_legend: bool, old_legend_rating: int,
								   rank_icons: HBoxContainer = null) -> void:
	# Auth keeps re-sending the result until the server answers; say so rather
	# than leaving "Updating rank..." up as if nothing were happening.
	get_tree().create_timer(8.0).timeout.connect(func():
		if is_instance_valid(rank_lbl) and rank_lbl.text == "Updating rank...":
			rank_lbl.text = "Still syncing your rank - retrying..."
	)
	Net.ranked_result_received.connect(func(success: bool, _profile: Dictionary):
		if not is_instance_valid(rank_lbl):
			return
		if not success:
			rank_lbl.text = "Rank sync failed"
			return
		var old_str := RankedProgress.get_display_string(old_bracket, old_in_legend, old_legend_rating)
		var new_str := RankedProgress.get_display_string(Auth.rank_bracket, Auth.rank_in_legend, Auth.rank_legend_rating)
		if rank_icons != null and is_instance_valid(rank_icons):
			for child in rank_icons.get_children():
				child.queue_free()
			rank_icons.visible = true
			if old_str != new_str:
				rank_icons.add_child(RankedProgress.make_icon_rect(old_bracket, old_in_legend, old_legend_rating, 72))
				var arrow := Label.new()
				arrow.text = "->"
				arrow.add_theme_font_size_override("font_size", 28)
				arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				rank_icons.add_child(arrow)
			rank_icons.add_child(RankedProgress.make_icon_rect(
				Auth.rank_bracket, Auth.rank_in_legend, Auth.rank_legend_rating, 72))
		var tier_str := new_str if old_str == new_str else "%s -> %s" % [old_str, new_str]
		# A tier change only ever happens on a win under the current ladder
		# rules (brackets/Legend rating only go up on a win; a loss can only
		# demote out of Legend, never change tier upward) - guarding on `won`
		# keeps a Legend demotion from also granting a reward.
		if won and old_str != new_str:
			Economy.claim_earn_reward("ranked_milestone")
		# LP delta is only meaningful for the bracketed ladder (Legend uses a
		# continuous rating instead) — skip it if either side of this result
		# was in Legend, since the tier_str transition already covers that.
		if not old_in_legend and not Auth.rank_in_legend:
			var lp_delta: int
			if won:
				lp_delta = RankedProgress.LP_WIN_STREAK if Auth.ranked_win_streak >= RankedProgress.LP_WIN_STREAK_THRESHOLD else RankedProgress.LP_WIN_BASE
			else:
				lp_delta = -RankedProgress.LP_LOSS
			rank_lbl.text = "%s  (%s%d LP)" % [tier_str, "+" if lp_delta >= 0 else "", lp_delta]
		else:
			rank_lbl.text = tier_str
		rank_lbl.modulate = Color(0.4, 0.9, 0.4) if won else Color(0.9, 0.4, 0.4)
	, CONNECT_ONE_SHOT)
