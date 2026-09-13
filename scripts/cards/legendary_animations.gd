class_name LegendaryAnimations
extends RefCounted

## One-off "spectacle" animations for specific legendary cards, kept out of
## card.gd (which only holds generic, apply-to-any-card animation methods -
## see its animate_transform()/animate_death()) so that file doesn't grow an
## ever-longer per-card-id switch as more legendaries get their own moment.
##
## Two independent entry points, each guarded by its own has_*() check, so a
## legendary can override either half of the sequence (or both) without
## touching the other:
##   - play_flight() - called by board.gd's _run_slam_landing() INSTEAD OF
##     the default straight-line ghost flight once has_custom_flight()
##     confirms this card owns its own flight path.
##   - play_landing() - called by the same function INSTEAD OF its default
##     squash-and-settle impact (never both; each legendary here fully owns
##     its own landing beat) once has_landing_animation() confirms one
##     exists for the card that just landed.

const STINKPILE_ID := "b_017"
const QUETZALCOATL_ID := "o_016"

static func has_landing_animation(card_id: String) -> bool:
	return card_id == STINKPILE_ID

static func has_custom_flight(card_id: String) -> bool:
	return card_id == QUETZALCOATL_ID

## `ghost` is the same in-flight stand-in board.gd's default flight would
## have animated - `start_pos`/`start_scale` are just its global_position/
## scale read at the moment this is called (board.gd passes them straight
## through rather than re-reading them mid-flight). `board` is only used to
## read the viewport's visible rect, so the swoop's height/width scale to
## whatever screen it's actually playing on instead of hardcoded pixels.
## Must leave `ghost` sitting exactly at target_pos/target_scale when it
## returns - board.gd frees it and reveals real_card there immediately
## after, with no reconciling tween of its own.
static func play_flight(card_id: String, ghost: Card, board: Node2D, start_pos: Vector2, start_scale: Vector2, target_pos: Vector2, target_scale: Vector2) -> void:
	match card_id:
		QUETZALCOATL_ID:
			await _quetzalcoatl_flight(ghost, board, start_pos, start_scale, target_pos, target_scale)

## Qu3tzalcoatl, the Serpent (6 mana, orange legendary) - instead of darting
## straight to its board slot like every other card, swoops in a wide loop
## up and around the board first (a "flying around" flourish fitting a
## flying serpent) before curling down into its spot. 0.9s here plus the
## default 0.12s post-flight squash-settle (has_landing_animation() above
## has no entry for this id, so that default still plays) comfortably clears
## the board.gd caller's own <2s budget for the whole sequence - the wider
## loop below covers a lot more ground in less time than the original pass,
## so it reads as noticeably quicker despite the longer path.
##
## Pure cubic-Bezier position/scale tween - no node rotation - card.gd's
## _update_mesh_transform() reads the node's full transform (including
## rotation) to size the 3D mesh rect, and a rotated bounding box there
## reads as a skewed/stretched card rather than a banked one, so this keeps
## the card upright and only moves position and scale. A single continuous
## Bezier eased with TRANS_QUART (see below) is what keeps a faster,
## farther loop with a real speed-up/slow-down feel still reading as smooth
## flight rather than a jerky cut between speeds.
const _QUETZALCOATL_FLIGHT_DURATION := 0.9
static func _quetzalcoatl_flight(ghost: Card, board: Node2D, start_pos: Vector2, start_scale: Vector2, target_pos: Vector2, target_scale: Vector2) -> void:
	var viewport_rect := board.get_viewport().get_visible_rect()
	# Apex sits above whichever of start/target is already higher on screen
	# (not a fixed viewport height) so the arc reads as "up and over" for
	# both the player's own plays (bottom of screen, flying up) and the
	# opponent's/AI's (nearer the top already) - then clamped so it can't
	# climb off the top edge.
	var top_y: float = minf(start_pos.y, target_pos.y)
	var apex_y: float = maxf(top_y - viewport_rect.size.y * 0.38, viewport_rect.position.y + 10.0)
	var span_x: float = target_pos.x - start_pos.x
	# Control points overshoot past BOTH ends horizontally (clamped to the
	# viewport so an edge-of-screen drop/landing can't send it flying off
	# screen) - that outward bow plus the shared apex height is what reads
	# as a loop up and around rather than a plain climb-and-dive. Wider than
	# the original pass (higher multiplier/base/cap) so the loop actually
	# carries it farther out across the board before it curls back in.
	var overshoot: float = clampf(absf(span_x) * 0.7 + 220.0, 0.0, viewport_rect.size.x * 0.5)
	var control_a := Vector2(clampf(start_pos.x - overshoot, viewport_rect.position.x, viewport_rect.end.x), apex_y)
	var control_b := Vector2(clampf(target_pos.x + overshoot, viewport_rect.position.x, viewport_rect.end.x), apex_y)

	var animate_step := func(t: float) -> void:
		ghost.global_position = _cubic_bezier(start_pos, control_a, control_b, target_pos, t)
		ghost.scale = start_scale.lerp(target_scale, t)

	var tween := ghost.create_tween()
	# QUART (not the previous, gentler SINE) for a much steeper speed curve -
	# near-stopped at both ends, sharply fast through the middle - so it
	# reads as a launch-cruise-flare flight instead of a constant-speed
	# glide, while staying one continuous eased curve (no discontinuities)
	# so it's still smooth, not jerky.
	tween.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN_OUT)
	tween.tween_method(animate_step, 0.0, 1.0, _QUETZALCOATL_FLIGHT_DURATION)
	await tween.finished
	# Land exactly on the target regardless of any float drift from the
	# method tween above - board.gd relies on this being exact.
	ghost.global_position = target_pos
	ghost.scale = target_scale

static func _cubic_bezier(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return p0 * (u * u * u) + p1 * (3.0 * u * u * t) + p2 * (3.0 * u * t * t) + p3 * (t * t * t)

## `card` is the real board Card that just arrived at `target_scale` (see
## _slam_ghost_onto_card()). `board` is the Board node itself - needed to
## parent transient effects (a landing decal, screen shake) that have to
## outlive/exist independently of `card`.
## Awaited by board.gd's _run_slam_landing() - callers further up (game_
## manager.gd/mp_game_manager.gd/ai_controller.gd, via Board.await_slam_
## landed()) rely on this only resolving once the card itself is done
## landing, so a same-play prompt (StinkPile's on-play Rummage) can't open
## mid-animation. Deliberately does NOT wait on lingering atmospheric extras
## (the sludge puddle's ~2s fade, the board shake) - those are environmental
## flourishes, not part of "is the card still landing", and holding a
## rummage picker open that long just to let a puddle finish fading would be
## its own kind of janky.
static func play_landing(card_id: String, card: Card, board: Node2D, target_scale: Vector2) -> void:
	match card_id:
		STINKPILE_ID:
			await _stinkpile_landing(card, board, target_scale)

## StinkPile, Lord of Garbage (9 mana, black legendary) - a much heavier
## slam than the default (bigger squash overshoot, slower settle, a brief
## board shake for weight), plus a puddle of black sludge left behind at his
## landing spot for a couple seconds.
static func _stinkpile_landing(card: Card, board: Node2D, target_scale: Vector2) -> void:
	card.scale = target_scale * Vector2(1.55, 0.5)
	var impact := card.create_tween()
	impact.tween_property(card, "scale", target_scale * Vector2(0.92, 1.08), 0.10).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	impact.tween_property(card, "scale", target_scale, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	_shake_board(board)
	_spawn_sludge(card, board, target_scale)

	await impact.finished

## Brief, small positional shake on the whole board - sells the extra weight
## of a 7/5 slamming down instead of just a bigger squash on the card alone.
static func _shake_board(board: Node2D) -> void:
	var base_pos := board.position
	var shake := board.create_tween()
	const OFFSETS := [Vector2(6, 3), Vector2(-5, -2), Vector2(4, -3), Vector2(-3, 2), Vector2(0, 0)]
	for offset in OFFSETS:
		shake.tween_property(board, "position", base_pos + offset, 0.035)
	shake.tween_callback(func(): board.position = base_pos)

## A rough puddle of black sludge (a handful of overlapping dark blobs, not
## a single perfect circle) centered on where `card` landed - holds briefly
## then dissolves quickly. Inserted right before Card3DLayer in Board's
## child list (found via its "card_3d_layer" group - see card.gd's _ready())
## rather than just appended last: same z_index as Board's own full-screen
## Background, so draw order between same-z_index siblings falls back to
## tree order - appending last put it after (on top of) Card3DLayer, but
## slotting it in right before instead puts it after Background yet still
## under the card's own 3D mesh, where a landing puddle actually belongs.
static func _spawn_sludge(card: Card, board: Node2D, target_scale: Vector2) -> void:
	var card_size: Vector2 = Card.CARD_SIZE * target_scale
	var center: Vector2 = card.global_position + card_size * 0.5
	var puddle := Node2D.new()
	puddle.modulate.a = 0.0
	board.add_child(puddle)
	var card_layer := board.get_tree().get_first_node_in_group("card_3d_layer")
	if card_layer and card_layer.get_parent() == board:
		board.move_child(puddle, card_layer.get_index())
	puddle.global_position = center

	# Spread scaled off the card's own on-screen size, wide enough that
	# blobs land past its edges (roughly its half-width/half-height, biased
	# a bit further down than up - sludge pooling at the base of impact)
	# instead of sitting entirely underneath it, fully hidden by its opaque
	# mesh - see this function's earlier note on why it draws behind the
	# card in the first place.
	const NUM_BLOBS := 8
	for i in NUM_BLOBS:
		var blob := Panel.new()
		var blob_size := Vector2.ONE * randf_range(46.0, 88.0)
		blob.size = blob_size
		var offset := Vector2(
			randf_range(-card_size.x * 0.85, card_size.x * 0.85),
			randf_range(-card_size.y * 0.35, card_size.y * 0.55)
		)
		blob.position = offset - blob_size * 0.5
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.05, 0.05, 0.03, 0.88)
		style.set_corner_radius_all(int(blob_size.x * 0.5))
		blob.add_theme_stylebox_override("panel", style)
		puddle.add_child(blob)

	var tween := puddle.create_tween()
	tween.tween_property(puddle, "modulate:a", 1.0, 0.12)
	tween.tween_interval(1.0)
	tween.tween_property(puddle, "modulate:a", 0.0, 0.15)
	tween.tween_callback(puddle.queue_free)
