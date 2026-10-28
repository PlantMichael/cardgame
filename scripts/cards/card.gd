class_name Card
extends Area2D

@onready var card_visual: Panel = $CardVisual
@onready var name_label: Label = $NameLabel
@onready var description_label: RichTextLabel = $DescriptionLabel
@onready var name_backdrop: ColorRect = $NameBackdrop
@onready var description_backdrop: ColorRect = $DescriptionBackdrop
@onready var attack_label: Label = $AttackLabel
@onready var health_label: Label = $HealthLabel
@onready var art_texture: TextureRect = $ArtTexture
@onready var background: TextureRect = $Background
@onready var mana_orb: TextureRect = $ManaOrb
@onready var mana_label: Label = $ManaOrb/ManaLabel
@onready var rarity_gem: TextureRect = $RarityGem
@onready var tribe_icons: HBoxContainer = $TribeIcons
@onready var pilot_icon: TextureRect = $PilotIcon
@onready var reinforce_icon: TextureRect = $ReinforceIcon

const CARD_FONT := preload("res://assets/fonts/Orbitron.ttf")

## The design space every node rect in Card.tscn is laid out in. Nothing is
## ever drawn at this size directly - instances pick one of the three Size
## presets below, which is applied as a uniform `scale` on the whole node.
## Matches the 1042x1510 frame art's aspect to within half a percent.
const CARD_SIZE := Vector2(220, 320)

## The only three sizes a card is ever shown at. Every screen picks one
## instead of inventing its own scale, so text/art/frame proportions stay
## identical everywhere and only the overall card changes size.
##   SMALL  - on the battlefield
##   MEDIUM - in hand, and in the graveyard/mulligan/rummage pickers
##   LARGE  - the hover preview panels
##   BOARD  - the battlefield rows (SMALL stays for the deck builder's collection grid)
enum Size { SMALL, MEDIUM, LARGE, BOARD }

## Spelled out as plain constants rather than derived from CARD_SIZE through a
## helper, so callers can use them in their own `const` declarations (a
## wrapper's custom_minimum_size, say) - GDScript won't run a function in a
## constant expression.
const SCALE_SMALL := Vector2(0.46, 0.46)
const SCALE_MEDIUM := Vector2(0.62, 0.62)
const SCALE_LARGE := Vector2(1.20, 1.20)
const SCALE_BOARD := Vector2(0.64, 0.64)
## On-screen pixel size at each preset - CARD_SIZE times the scale above.
## What a container wrapper around a card at that preset should reserve.
const PIXELS_SMALL := Vector2(101, 147)
const PIXELS_MEDIUM := Vector2(136, 198)
const PIXELS_LARGE := Vector2(264, 384)
const PIXELS_BOARD := Vector2(141, 205)

const SIZE_SCALES := {
	Size.SMALL: SCALE_SMALL,
	Size.MEDIUM: SCALE_MEDIUM,
	Size.LARGE: SCALE_LARGE,
	Size.BOARD: SCALE_BOARD,
}
const SIZE_PIXELS := {
	Size.SMALL: PIXELS_SMALL,
	Size.MEDIUM: PIXELS_MEDIUM,
	Size.LARGE: PIXELS_LARGE,
	Size.BOARD: PIXELS_BOARD,
}

## Kept as the hand's drag/return scale so the many call sites that reference
## it don't each have to spell out the Size lookup.
const HAND_SCALE := SCALE_MEDIUM
const HAND_DRAG_OFFSET := Vector2(88.0, 128.0)

static func scale_for(size: Size) -> Vector2:
	return SIZE_SCALES[size]

static func pixels_for(size: Size) -> Vector2:
	return SIZE_PIXELS[size]

func apply_size(size: Size) -> void:
	scale = SIZE_SCALES[size]

var data: CardData = null
var minion: Minion = null
var is_in_hand: bool = false
var _is_selected: bool = false
var _dragging: bool = false
var _drag_start_pos: Vector2
var _original_parent: Node
var _original_index: int
var _is_highlighted_as_target: bool = false
var _description_plain_text: String = ""
var _keyword_regex: RegEx = null
var _keyword_colors: Dictionary = {}

signal clicked(card: Card)
signal dropped(card: Card)
signal drag_started(card: Card)

const CARD_BORDER_COLORS = {
	CardData.CardColor.GREEN:    Color(0.35, 0.72, 0.35),
	CardData.CardColor.CRIMSON:  Color(0.72, 0.35, 0.35),
	CardData.CardColor.BLACK:    Color(0.42, 0.42, 0.42),
	CardData.CardColor.ORANGE:   Color(0.72, 0.58, 0.30),
	CardData.CardColor.TEAL:     Color(0.30, 0.72, 0.72),
	CardData.CardColor.GENERIC:  Color(0.55, 0.55, 0.62),
}

## One frame per color, all 1042x1510 and all sharing the same slot layout -
## which is the whole point of the set, and why every Card instance can use
## the one node layout in Card.tscn regardless of color.
const CARD_FRAMES = {
	CardData.CardColor.GREEN:    preload("res://assets/card_assets/card-green.png"),
	CardData.CardColor.CRIMSON:  preload("res://assets/card_assets/card-crimson.png"),
	CardData.CardColor.BLACK:    preload("res://assets/card_assets/card-black.png"),
	CardData.CardColor.ORANGE:   preload("res://assets/card_assets/card-orange.png"),
	CardData.CardColor.TEAL:     preload("res://assets/card_assets/card-teal.png"),
	CardData.CardColor.GENERIC:  preload("res://assets/card_assets/card-generic-grey.png"),
}

## Stratagem frames - same 1042x1510 canvas and the same slots as CARD_FRAMES
## from the top down to the description panel, but with no attack/health
## boxes: the panel runs on down through where they would be. So everything
## in Card.tscn lines up unchanged except the description box, which swaps to
## DESCRIPTION_BOX_STRATAGEM.
const STRATAGEM_FRAMES = {
	CardData.CardColor.GREEN:    preload("res://assets/cardgame/Strategems/stratagem-green.png"),
	CardData.CardColor.CRIMSON:  preload("res://assets/cardgame/Strategems/stratagem-crimson.png"),
	CardData.CardColor.BLACK:    preload("res://assets/cardgame/Strategems/stratagem-black.png"),
	CardData.CardColor.ORANGE:   preload("res://assets/cardgame/Strategems/stratagem-orange.png"),
	CardData.CardColor.TEAL:     preload("res://assets/cardgame/Strategems/stratagem-teal.png"),
	CardData.CardColor.GENERIC:  preload("res://assets/cardgame/Strategems/stratagem-generic-grey.png"),
}

## Description box rects in CARD_SIZE design space, each inset 4px from its
## frame's measured text panel (see _description_box for why).
## DEFAULT must match DescriptionLabel's rect in Card.tscn. The stratagem
## panel shares its top and sides; only its bottom bevel sits lower - 1421px
## vs 1199px in the 1510px-tall art (averaged over all the stratagem / card
## frames), which is +47 in design space.
const DESCRIPTION_BOX_DEFAULT := Rect2(36, 191, 148, 60)
const DESCRIPTION_BOX_STRATAGEM := Rect2(36, 191, 148, 107)

## Mana orbs - one per color, every one its own art now (GREEN and GENERIC
## used to be the white orb under a tint, for want of their own).
const _WHITE_ORB := preload("res://assets/card_assets/whitemana.png")
const MANA_ORBS = {
	CardData.CardColor.GREEN:    preload("res://assets/card_assets/greenmana.png"),
	CardData.CardColor.CRIMSON:  preload("res://assets/card_assets/crimsonmana.png"),
	CardData.CardColor.BLACK:    preload("res://assets/card_assets/blackmana.png"),
	CardData.CardColor.ORANGE:   preload("res://assets/card_assets/orangemana.png"),
	CardData.CardColor.TEAL:     preload("res://assets/card_assets/tealmana.png"),
	CardData.CardColor.GENERIC:  preload("res://assets/card_assets/genericmana.png"),
}

## The gem art is named for a common/uncommon/rare/legendary ladder while the
## game's rarities are COMMON/RARE/EPIC/LEGENDARY, so these are matched by
## tier rather than by filename - EPIC sits above RARE and gets the gem one
## step up from it.
const RARITY_GEMS = {
	CardData.CardRarity.COMMON:    preload("res://assets/card_assets/common-grey.png"),
	CardData.CardRarity.RARE:      preload("res://assets/card_assets/uncommon-blue.png"),
	CardData.CardRarity.EPIC:      preload("res://assets/card_assets/rare-yellow.png"),
	CardData.CardRarity.LEGENDARY: preload("res://assets/card_assets/legendary-red.png"),
}

const TRIBE_ICONS = {
	"yeti": preload("res://assets/card_assets/tribe-yeti.png"),
	"mech": preload("res://assets/card_assets/tribe-mech.png"),
	"tank": preload("res://assets/card_assets/tribe-tank.png"),
	"monstrosity": preload("res://assets/card_assets/tribe-abomination.png"),
}
## Stand-ins for a card whose tribe has no icon of its own (sprite, bat,
## wolf, or no tribe at all) - the card type's own symbol fills the bar.
const CREATURE_ICON := preload("res://assets/card_assets/tribe-creature.png")
const STRATAGEM_ICON := preload("res://assets/card_assets/tribe-strategem.png")
const PILOTED_ICON := preload("res://assets/card_assets/tribe-piloted.png")
const REINFORCE_ICON := preload("res://assets/card_assets/tribe-reinforce.png")

func _ready() -> void:
	_apply_text_outlines()
	pilot_icon.texture = PILOTED_ICON
	reinforce_icon.texture = REINFORCE_ICON
	if get_tree().current_scene == self:
		_setup_standalone_preview()

## Lets Card.tscn be run directly with F6 - populates itself with a real card
## (one with a long multi-line description and a keyword to highlight, to
## stress-test wrapping/alignment) so nudging a label here and hitting F6
## again shows the result immediately, with no need to launch the full game
## and dig through menus to find a card to hover.
const _STANDALONE_PREVIEW_CARD_ID := "b_018" # Stinkherder (BLACK, 2-line desc, Rush keyword)
func _setup_standalone_preview() -> void:
	apply_size(Size.LARGE)
	var sample: CardData = CardDatabase.cards.get(_STANDALONE_PREVIEW_CARD_ID)
	if sample == null and not CardDatabase.cards.is_empty():
		sample = CardDatabase.cards.values()[0]
	if sample:
		setup(sample)

## Black outline behind every card text element so it stays legible over
## busy art or a keyword's own fill color (BBCode [color=] tags only touch
## fill, not the outline pass, so highlighted keywords get one too).
## Font size is untouched - outline_size is a separate stroke property.
const TEXT_OUTLINE_SIZE := 3
const TEXT_OUTLINE_COLOR := Color.BLACK

func _apply_text_outlines() -> void:
	for label in [name_label, description_label, attack_label, health_label, mana_label]:
		label.add_theme_constant_override("outline_size", TEXT_OUTLINE_SIZE)
		label.add_theme_color_override("font_outline_color", TEXT_OUTLINE_COLOR)
	description_label.add_theme_constant_override("outline_size", DESCRIPTION_OUTLINE_SIZE)

## Wraps any keyword (Guardian, Rush, Rummage, ...) found in a card's
## description with the same color used for that keyword's ability badge.
const KEYWORD_BRIGHTEN := 0.5
const DESCRIPTION_OUTLINE_SIZE := 5

func _highlight_keywords(description: String) -> String:
	_ensure_keyword_data()
	if _keyword_regex == null:
		return description
	var matches := _keyword_regex.search_all(description)
	if matches.is_empty():
		return description
	var result := ""
	var last_end := 0
	for m in matches:
		var start: int = m.get_start()
		var end: int = m.get_end()
		var word: String = m.get_string()
		var color: Color = _keyword_colors.get(word.to_lower(), Color.WHITE)
		# The badge colors are dark mid-tones; lifted toward white they stay
		# recognisable but read clearly on the description panel.
		color = color.lerp(Color.WHITE, KEYWORD_BRIGHTEN)
		result += description.substr(last_end, start - last_end)
		result += "[color=#%s]%s[/color]" % [color.to_html(false), word]
		last_end = end
	result += description.substr(last_end)
	return result

func _ensure_keyword_data() -> void:
	if _keyword_regex != null:
		return
	var words: Array[String] = []
	for ability in Abilities.KEYWORD_TOOLTIPS:
		var w: String = Abilities.get_display(ability)
		if w.is_empty():
			continue
		var key := w.to_lower()
		if not _keyword_colors.has(key):
			_keyword_colors[key] = Abilities.get_color(ability)
			words.append(w)
	if words.is_empty():
		return
	# Longest phrase first so e.g. "Challenge All" matches whole, not as
	# "Challenge" + leftover "All".
	words.sort_custom(func(a, b): return a.length() > b.length())
	var escaped: Array[String] = []
	for w in words:
		escaped.append(_escape_regex(w))
	var re := RegEx.new()
	var err := re.compile("(?i)\\b(" + "|".join(escaped) + ")\\b")
	if err == OK:
		_keyword_regex = re

func _escape_regex(text: String) -> String:
	var special := ["\\", ".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "^", "$"]
	var result := text
	for ch in special:
		result = result.replace(ch, "\\" + ch)
	return result

func _fit_label_to_width(label: Label, max_font: int, min_font: int = 8) -> void:
	var font := label.get_theme_font("font")
	for size in range(max_font, min_font - 1, -1):
		label.add_theme_font_size_override("font_size", size)
		if font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= label.size.x:
			return

## The description box's rect as Card.tscn lays it out. _fit_description_to_
## height() shifts description_label up or down inside this box to center the
## text vertically, so the box it's measured against has to be remembered
## rather than read back off the label (which has already been moved by then).
##
## Note the rect is deliberately INSET from the frame art's printed text
## panel rather than matching it exactly. Sized to the panel, a long
## description fit by the arithmetic below but drew with no margin at all, so
## its 3px glyph outline overlapped the panel's bevel and read as text
## spilling out of the box. The inset is that missing margin.
var _description_box := Rect2()

## description_label holds BBCode (color tags around keywords), so sizing must
## be measured against the plain text, not the tagged text.
##
## A RichTextLabel always top-aligns its content, which left a one-line
## description (most cards) clinging to the top bevel of the frame's text box
## instead of sitting in the middle of it. So this also measures the laid-out
## text's height and offsets the label by half the leftover room - vertical
## centering a RichTextLabel has no property for.
func _fit_description_to_height(plain_text: String, max_font: int) -> void:
	if _description_box.size == Vector2.ZERO:
		_description_box = DESCRIPTION_BOX_DEFAULT
	description_label.position = _description_box.position
	description_label.size = _description_box.size
	var font := description_label.get_theme_font("normal_font")
	var line_spacing := description_label.get_theme_constant("line_separation")
	var text_height := _description_box.size.y
	for size in range(max_font, 7, -1):
		description_label.add_theme_font_size_override("normal_font_size", size)
		var sz := font.get_multiline_string_size(plain_text, HORIZONTAL_ALIGNMENT_LEFT, _description_box.size.x, size)
		var fh := font.get_height(size)
		var line_count := ceili(sz.y / fh) if fh > 0 else 1
		text_height = sz.y + line_spacing * maxi(0, line_count - 1)
		if text_height <= _description_box.size.y:
			break
	var slack := maxf(_description_box.size.y - text_height, 0.0)
	description_label.position.y = _description_box.position.y + slack * 0.5

func _fit_text() -> void:
	_fit_label_to_width(name_label, 14, 7)
	_fit_description_to_height(_description_plain_text, 14)

## Solid black stand-in for art_texture on cards with no `art` set - without
## this, an empty TextureRect draws nothing and the frame's own art window
## (a flat white rect baked into the frame PNG) shows through instead.
## Generated once and cached, not per-instance.
static var _blank_art_texture: ImageTexture = null
static func _get_blank_art_texture() -> ImageTexture:
	if _blank_art_texture == null:
		var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
		img.fill(Color.BLACK)
		_blank_art_texture = ImageTexture.create_from_image(img)
	return _blank_art_texture

func setup(card_data: CardData) -> void:
	data = card_data
	name_label.text = card_data.card_name
	_update_mana_orb(card_data)
	_update_type_row(card_data)
	_description_plain_text = card_data.effective_description()
	description_label.text = "[center]" + _highlight_keywords(card_data.effective_description()) + "[/center]"
	var is_creature = card_data.card_type == CardData.CardType.CREATURE
	# A location has health but no attack, so it shows the health side only
	# rather than printing a meaningless 0 in the attack box.
	var is_location = card_data.card_type == CardData.CardType.LOCATION
	attack_label.visible = is_creature
	health_label.visible = is_creature or is_location
	name_label.add_theme_color_override("font_color", Color.WHITE)
	description_label.add_theme_color_override("default_color", Color.WHITE)
	if is_creature or is_location:
		attack_label.text = str(card_data.attack)
		health_label.text = str(card_data.health)
		attack_label.add_theme_color_override("font_color", Color.WHITE)
		health_label.add_theme_color_override("font_color", Color.WHITE)
	update_piloted_token(false)
	update_reinforce_token(false)
	art_texture.texture = card_data.art if card_data.art != null else _get_blank_art_texture()
	_description_box = DESCRIPTION_BOX_STRATAGEM if is_stratagem() else DESCRIPTION_BOX_DEFAULT
	_apply_color_theme(card_data.color)
	call_deferred("_fit_text")

func is_target_highlighted() -> bool:
	return _is_highlighted_as_target

## Only a card on the local player's side of the board may show the gold
## "can attack" outline; the board turns it off for opposing cards so that
## clearing a target highlight never lights up enemy creatures.
var attack_outline_allowed: bool = true
var _target_is_friendly: bool = false

func is_target_friendly() -> bool:
	return _is_highlighted_as_target and _target_is_friendly

## `friendly` picks the green "helpful target" outline (piloting a mech,
## buffing or healing your own creature) over the red hostile one.
func set_targeted(value: bool, friendly: bool = false) -> void:
	_is_highlighted_as_target = value
	_target_is_friendly = value and friendly
	if value:
		var border := Color(0.2, 0.85, 0.3, 1.0) if friendly else Color(0.9, 0.15, 0.15, 1.0)
		card_visual.add_theme_stylebox_override("panel", _make_stylebox(Color(0, 0, 0, 0), border, 3))
	else:
		# Restore appropriate state
		if attack_outline_allowed and minion and minion.can_attack():
			set_can_attack(true)
		else:
			_apply_color_theme(data.color)

func setup_as_minion(m: Minion) -> void:
	minion = m
	setup(m.data)
	attack_label.text = str(m.current_attack)
	health_label.text = str(m.current_health)
	_apply_stat_colors(m)
	if m.is_nulled:
		_description_plain_text = "Nulled."
		description_label.text = "[center]Nulled.[/center]"
		_apply_silenced_style()
	update_piloted_token(m.is_piloted)
	update_reinforce_token(Abilities.reinforce_uses_of(m) > 0)
	call_deferred("_fit_text")

func _apply_stat_colors(m: Minion) -> void:
	const BLUE := Color(0.45, 0.75, 1.0)
	const RED  := Color(1.0, 0.35, 0.35)
	if m.current_attack > m.data.attack:
		attack_label.add_theme_color_override("font_color", BLUE)
	elif m.current_attack < m.data.attack:
		attack_label.add_theme_color_override("font_color", RED)
	else:
		attack_label.add_theme_color_override("font_color", Color.WHITE)
	if m.current_health < m.max_health:
		health_label.add_theme_color_override("font_color", RED)
	elif m.max_health > m.data.health:
		health_label.add_theme_color_override("font_color", BLUE)
	else:
		health_label.add_theme_color_override("font_color", Color.WHITE)

## Unplayable cards are dimmed, not hidden. 0.32 was dark enough that a card
## you cannot afford yet vanished into the battlefield art - you could not
## read what you were holding, which matters most on the turns you are
## planning ahead.
func set_playable(value: bool) -> void:
	modulate = Color.WHITE if value else Color(0.55, 0.55, 0.58, 0.92)

## Full-card washes, drawn by card_visual over the frame art. Kept light:
## the frame art is opaque and heavily colored, so anything near half alpha
## here flattens the card's own art and text into one murky block instead of
## reading as a status tint on top of it.
const SUMMONING_SICK_HIGHLIGHT := Color(0.18, 0.05, 0.28, 0.26)
const SILENCED_HIGHLIGHT := Color(0.22, 0.22, 0.25, 0.32)

func set_summoning_sick(value: bool) -> void:
	if value:
		var border = CARD_BORDER_COLORS[data.color]
		card_visual.add_theme_stylebox_override("panel", _make_stylebox(SUMMONING_SICK_HIGHLIGHT, border, 2))

func set_can_attack(value: bool) -> void:
	if value:
		card_visual.add_theme_stylebox_override("panel", _make_stylebox(Color(0, 0, 0, 0), Color(1.0, 0.85, 0.2), 3))
	else:
		_apply_color_theme(data.color)

func set_selected(value: bool) -> void:
	_is_selected = value
	position.y = -24 if value else 0

func damage_flash() -> void:
	var tween = create_tween()
	tween.tween_property(self, "modulate", Color(1, 0.2, 0.2), 0.1)
	tween.tween_property(self, "modulate", Color.WHITE, 0.2)

func animate_transform() -> void:
	# Brief red flash + scale punch on the card itself
	var base_scale := scale
	var flash := create_tween().set_parallel(true)
	flash.tween_property(self, "modulate", Color(1.6, 0.15, 0.15), 0.12)
	flash.tween_property(self, "modulate", Color.WHITE, 0.45).set_delay(0.12)
	flash.tween_property(self, "scale", base_scale * 1.18, 0.12)
	flash.tween_property(self, "scale", base_scale, 0.22).set_delay(0.12)

	# Ring of red orbs that spiral inward by rotating + shrinking their container
	var swirl := Node2D.new()
	swirl.position = CARD_SIZE * 0.5
	add_child(swirl)

	const NUM_ORBS := 8
	const RADIUS := 108.0
	const ORB_SIZE := Vector2(16, 16)
	for i in NUM_ORBS:
		var orb := Panel.new()
		orb.size = ORB_SIZE
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.75 + 0.25 * (float(i) / NUM_ORBS), 0.04, 0.04, 0.90)
		style.set_corner_radius_all(4)
		orb.add_theme_stylebox_override("panel", style)
		var angle := TAU * i / NUM_ORBS
		orb.position = Vector2(cos(angle), sin(angle)) * RADIUS - ORB_SIZE * 0.5
		swirl.add_child(orb)

	# Rotating while scaling to zero traces a natural inward spiral per orb
	var st := swirl.create_tween().set_parallel(true)
	st.tween_property(swirl, "rotation", TAU * 1.4, 0.65).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	st.tween_property(swirl, "scale", Vector2.ZERO, 0.65).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await st.finished
	swirl.queue_free()

## Magic Arena-style dissolve for a minion that just died - the card fades
## and eases down to nothing instead of crumbling into debris. Caller
## (board.gd's _reconcile_board_zone() removal loop) awaits this before
## freeing the card - queue_free()ing it immediately, the way that loop used
## to, would cut the fade off before it ever played.
func animate_death() -> void:
	# Clear any active outline (attack-target red, can-attack gold,
	# summoning-sick purple, silenced grey, ...) before the dissolve starts.
	# Going through set_targeted(false)/set_can_attack(false) here instead
	# risks their own "restore appropriate state" logic re-adding one right
	# back (set_targeted(false) re-applies the can-attack outline if the
	# dying minion still structurally can_attack()) - _apply_color_theme()
	# is the same neutral reset those fall back to when nothing else
	# applies, called directly so nothing gets re-added.
	if data:
		_apply_color_theme(data.color)

	const DURATION := 0.4
	var fade := create_tween().set_parallel(true)
	fade.tween_property(self, "modulate:a", 0.0, DURATION).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	fade.tween_property(self, "scale", scale * 0.82, DURATION).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await fade.finished

func start_drag() -> void:
	if not is_in_hand:
		clicked.emit(self)
		return
	# board.gd's own _input() hit-tests hand cards and calls this directly,
	# then (since it never marks the event handled) the wrapper Button's own
	# button_down signal fires the same call again for the same click. A
	# second entry here would re-capture _original_parent as the viewport
	# (since that's this card's parent by then), corrupting return_to_hand()
	# into dropping the card at the screen's literal (0,0) origin.
	if _dragging:
		return
	_drag_start_pos = global_position
	_original_parent = get_parent()
	_original_index = get_index()
	_dragging = true
	drag_started.emit(self)
	var viewport = get_viewport()
	_original_parent.remove_child(self)
	viewport.add_child(self)
	global_position = get_viewport().get_mouse_position() - HAND_DRAG_OFFSET


func return_to_hand() -> void:
	if not is_instance_valid(_original_parent):
		return
	if _original_parent.is_queued_for_deletion():
		return
	if get_parent() == get_viewport():
		get_viewport().remove_child(self)
	if not is_inside_tree():
		_original_parent.add_child(self)
		_original_parent.move_child(self, min(_original_index, _original_parent.get_child_count()))
	position = Vector2.ZERO
	scale = HAND_SCALE
	_dragging = false

func _input(event: InputEvent) -> void:
	if not _dragging:
		return
	if event is InputEventMouseMotion:
		global_position = get_viewport().get_mouse_position() - HAND_DRAG_OFFSET
	elif event is InputEventMouseButton and not event.pressed:
		_dragging = false
		dropped.emit(self)

func _apply_silenced_style() -> void:
	card_visual.add_theme_stylebox_override("panel", _make_stylebox(SILENCED_HIGHLIGHT, Color(0.45, 0.45, 0.50), 2))
	name_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	description_label.add_theme_color_override("default_color", Color(0.55, 0.55, 0.55))

## The cost orb that sits over the card's top-left corner - the frame art has
## no cost slot of its own, so this is the one element drawn on top of the
## frame rather than into a window cut for it. It overlaps the left end of
## the name plate, which is why NameLabel starts past the orb rather than
## spanning the whole plate (a long name centered over the full plate ran
## its first couple of letters underneath the orb).
func _update_mana_orb(card_data: CardData) -> void:
	mana_orb.texture = MANA_ORBS.get(card_data.color, _WHITE_ORB)
	mana_label.text = str(card_data.effective_cost())

const TRIBE_ICON_SIZE := Vector2(18, 18)

## The symbols shown along the tribe bar, left to right: the card type's own
## symbol first, then one per tribe the card belongs to - so a Yeti creature
## reads "creature, yeti" rather than just "yeti".
##
## LOCATION has no symbol in card_assets, so a location shows the gem alone.
## So do the tribes with no art of their own (sprite, bat, wolf) - those
## creatures just show the creature symbol until icons exist for them.
func _tribe_symbols(card_data: CardData) -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	match card_data.card_type:
		CardData.CardType.CREATURE: out.append(CREATURE_ICON)
		CardData.CardType.STRATAGEM: out.append(STRATAGEM_ICON)
	for tribe_name in _tribe_names(card_data):
		var icon: Texture2D = TRIBE_ICONS.get(tribe_name, null)
		if icon != null and not out.has(icon):
			out.append(icon)
	return out

## Every tribe a card belongs to. `tribe` holds a single name today, but it's
## read as a comma-separated list, and the ability list is swept too (that's
## where card_database.gd mirrors the tribe, and where a second one would
## most likely land), so a multi-tribe card gets a symbol per tribe without
## needing the schema changed first.
func _tribe_names(card_data: CardData) -> Array[String]:
	var names: Array[String] = []
	for raw in card_data.tribe.split(",", false):
		var one := raw.strip_edges().to_lower()
		if not one.is_empty() and not names.has(one):
			names.append(one)
	for ability in card_data.abilities:
		var one := str(ability).to_lower()
		if TRIBE_ICONS.has(one) and not names.has(one):
			names.append(one)
	return names

## Fills the frame's middle row: the rarity gem in its hexagon, then the
## symbol row along the bar beside it. Symbols only - the bar carries no text.
func _update_type_row(card_data: CardData) -> void:
	rarity_gem.texture = RARITY_GEMS.get(card_data.rarity, RARITY_GEMS[CardData.CardRarity.COMMON])
	var symbols := _tribe_symbols(card_data)
	# Grow the row to fit, then show only as many slots as this card needs.
	# Reused rather than rebuilt each time: setup() runs for every card on
	# every board refresh, and refresh() fires on nearly every action.
	while tribe_icons.get_child_count() < symbols.size():
		var slot := TextureRect.new()
		slot.custom_minimum_size = TRIBE_ICON_SIZE
		slot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		slot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tribe_icons.add_child(slot)
	for i in tribe_icons.get_child_count():
		var slot: TextureRect = tribe_icons.get_child(i)
		slot.visible = i < symbols.size()
		if slot.visible:
			slot.texture = symbols[i]

func _apply_color_theme(color: CardData.CardColor) -> void:
	var border = CARD_BORDER_COLORS[color]
	card_visual.add_theme_stylebox_override("panel", _make_stylebox(Color(0, 0, 0, 0), border, 2))
	var frames: Dictionary = STRATAGEM_FRAMES if is_stratagem() else CARD_FRAMES
	background.texture = frames.get(color, frames[CardData.CardColor.GENERIC])
	# Bright teal texture washes out thin lettering, especially on small cards.
	var is_teal := color == CardData.CardColor.TEAL
	name_backdrop.visible = is_teal
	description_backdrop.visible = is_teal
	description_backdrop.position = _description_box.position
	description_backdrop.size = _description_box.size
	if is_teal:
		description_label.add_theme_font_override("normal_font", ThemeDB.fallback_font)
	else:
		description_label.add_theme_font_override("normal_font", CARD_FONT)

func is_stratagem() -> bool:
	return data != null and data.card_type == CardData.CardType.STRATAGEM

func _get_corner_radius() -> int:
	return 6

func _make_stylebox(bg: Color, border: Color, border_width: int) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_width)
	s.set_corner_radius_all(_get_corner_radius())
	return s

func update_piloted_token(piloted: bool) -> void:
	pilot_icon.visible = piloted

## Shown for any remaining Reinforce, however many returns are left -
## Abilities.reinforce_uses_of() rather than a bare has_ability() check, which
## would miss a counted "reinforce_4".
func update_reinforce_token(reinforced: bool) -> void:
	reinforce_icon.visible = reinforced
