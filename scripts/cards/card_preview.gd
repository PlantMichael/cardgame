class_name CardPreview
extends Card

## Dedicated scene for the large single-card preview panels (board.gd's
## hover preview, the deck builder's and card list's preview sections) -
## split out from Card.tscn so its layout can be dragged around in the
## editor independently of the hand/board baked cards and the small
## collection-grid cards, which still share Card.tscn. Always flat (no 3D
## mesh/text-overlay path), so _ready() skips straight past that and the
## grid-tuned flat-offset shift Card applies to its own non-overlay mode -
## this scene's node positions are already final.
func _ready() -> void:
	mana_dots_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	image_size_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_apply_text_outlines()
	if get_tree().current_scene == self:
		_setup_standalone_preview()

## Lets this scene be run directly with F6 instead of only ever showing up as
## a child instantiated by board.gd/deck_builder_screen.gd/card_list_screen.gd
## - populates itself with a real card (one with a long multi-line
## description and a keyword to highlight, to stress-test wrapping/
## alignment) so dragging a label here and hitting F6 again shows the result
## immediately, no need to launch the full game or dig through menus to find
## a card to hover.
const _STANDALONE_PREVIEW_CARD_ID := "b_018" # Stinkherder (BLACK, 2-line desc, Rush keyword)
func _setup_standalone_preview() -> void:
	scale = Vector2(1.5, 1.5)
	var sample: CardData = CardDatabase.cards.get(_STANDALONE_PREVIEW_CARD_ID)
	if sample == null and not CardDatabase.cards.is_empty():
		sample = CardDatabase.cards.values()[0]
	if sample:
		setup(sample)
