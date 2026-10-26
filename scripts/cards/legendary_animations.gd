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

## StinkPile's sludge splash, from assets/effects/sludge/. The timings and
## the frame the splash holds on are TIMING.txt's (shipped alongside the
## frames so the timing this plays to stays next to the art it belongs to),
## not invented here. The two geometry constants are measured off the frames
## themselves: the art is a ring of sludge around a card-shaped hole, and in
## frame 06 - the fully-spread hold frame - that hole runs x 124-193,
## y 115-223 inside the 314x314 frame. Its centre sits noticeably below the
## frame's own, which is why _spawn_sludge() cannot simply centre the sprite
## on the card.
const SLUDGE_FRAME_DIR := "res://assets/effects/sludge/"
const SLUDGE_FRAME_COUNT := 16
const SLUDGE_FRAME_SIZE := Vector2(314, 314)
const SLUDGE_HOLE_SIZE := Vector2(69, 108)
const SLUDGE_HOLE_CENTER := Vector2(158.5, 169.0)
## Pulls the ring in past a perfect fit so sludge laps over the card's edges
## instead of ringing it with a visible gap.
const SLUDGE_OVERLAP := 0.92
const SLUDGE_SPLASH_TIME := 0.35
const SLUDGE_HOLD_TIME := 0.8
const SLUDGE_RETRACT_TIME := 1.4
const SLUDGE_HOLD_FRAME := 6

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
## Pure cubic-Bezier position/scale tween - no node rotation. A card's frame
## art, stat boxes and text all read as upright plates, so banking one mid-
## flight reads as a skewed card rather than a turning one; this keeps it
## upright and only moves position and scale. A single continuous
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
## (the ~2s hold-and-retract tail of the sludge splash, the board shake) -
## those are environmental flourishes, not part of "is the card still
## landing", and holding a rummage picker open that long just to let sludge
## finish draining away would be its own kind of janky.
static func play_landing(card_id: String, card: Card, board: Node2D, target_scale: Vector2) -> void:
	match card_id:
		STINKPILE_ID:
			await _stinkpile_landing(card, board, target_scale)

## StinkPile, Lord of Garbage (9 mana, black legendary) - a much heavier
## slam than the default (bigger squash overshoot, slower settle, a brief
## board shake for weight), plus the authored sludge splash erupting around
## him as he lands and draining away over the next couple of seconds (see
## _spawn_sludge()).
static func _stinkpile_landing(card: Card, board: Node2D, target_scale: Vector2) -> void:
	card.scale = target_scale * Vector2(1.55, 0.5)
	var impact := card.create_tween()
	impact.tween_property(card, "scale", target_scale * Vector2(0.92, 1.08), 0.10).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	impact.tween_property(card, "scale", target_scale, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	_shake_board(board)
	_spawn_sludge(card, board, target_scale)

	await impact.finished
	# Hold past the squash so the splash's outward burst is actually on
	# screen before this returns and board.gd lets StinkPile's own on-play
	# Rummage 3 picker open over it. The remaining ~2s of hold-and-retract
	# keeps playing underneath on its own - see _spawn_sludge() on why that
	# tail is deliberately not awaited.
	await card.get_tree().create_timer(SLUDGE_SPLASH_TIME + 0.2).timeout

## Brief, small positional shake on the whole board - sells the extra weight
## of a 7/5 slamming down instead of just a bigger squash on the card alone.
static func _shake_board(board: Node2D) -> void:
	var base_pos := board.position
	var shake := board.create_tween()
	const OFFSETS := [Vector2(6, 3), Vector2(-5, -2), Vector2(4, -3), Vector2(-3, 2), Vector2(0, 0)]
	for offset in OFFSETS:
		shake.tween_property(board, "position", base_pos + offset, 0.035)
	shake.tween_callback(func(): board.position = base_pos)

## StinkPile's black sludge splash - the authored 16-frame sequence from
## assets/effects/sludge/, centred on where `card` landed. Each frame is a
## ring of sludge around a card-shaped hole, so the effect is positioned and
## scaled to WRAP the landed card rather than pool underneath it: it bursts
## outward, holds fully spread, then slowly retracts. Replaces the handful
## of procedural dark blobs this used to draw, which never read as more than
## a grey smudge mostly hidden behind the card's own opaque frame.
##
## Slotted in right after Board's own full-screen Background rather than
## just appended last: it shares that Background's z_index, so draw order
## between same-z_index siblings falls back to tree order - appending last
## put the sludge on top of every board zone (and so on top of the card
## itself), while sitting right after Background puts it above the
## battlefield but under the cards, which is where TIMING.txt asks for it.
##
## Fire-and-forget: spawns a self-freeing node tree and returns immediately.
## Only the splash is awaited by the caller (see _stinkpile_landing()); the
## hold and the long retract are atmospheric tail, not part of "is the card
## still landing", and holding a rummage picker shut for the full 2.55s just
## to let sludge drain away would be its own kind of janky.
static func _spawn_sludge(card: Card, board: Node2D, target_scale: Vector2) -> void:
	var frames := _sludge_frames()
	if frames.is_empty():
		return

	var sludge := Node2D.new()
	sludge.modulate.a = 0.0
	board.add_child(sludge)
	var background := board.get_node_or_null(^"Background")
	if background:
		board.move_child(sludge, background.get_index() + 1)

	# Scale the frame so its inner hole wraps the card at the size it
	# actually landed at. Driven off the card's height rather than its
	# width: the hole is a little narrower in aspect than a card, so fitting
	# the width would leave the card's top and bottom edges uncovered.
	var card_size: Vector2 = Card.CARD_SIZE * target_scale
	var zoom: float = (card_size.y / SLUDGE_HOLE_SIZE.y) * SLUDGE_OVERLAP
	sludge.scale = Vector2(zoom, zoom)
	# Both sprites below are centred, so their origin is the frame's centre -
	# offset by however far the hole's centre sits from it, so it is the HOLE
	# (not the frame) that ends up centred on the card.
	var frame_center: Vector2 = SLUDGE_FRAME_SIZE * 0.5
	sludge.global_position = card.global_position + card_size * 0.5 - (SLUDGE_HOLE_CENTER - frame_center) * zoom

	# Two stacked sprites rather than one: TIMING.txt asks for adjacent
	# frames to be blended, so `far` holds the frame just passed at full
	# alpha and `near` fades the next one in over it across the gap between
	# them. Sixteen frames over 2.55s cut hard would read as a strobe; this
	# keeps the sludge moving continuously.
	var far := Sprite2D.new()
	var near := Sprite2D.new()
	for sprite in [far, near]:
		sprite.centered = true
		sprite.texture = frames[0]
		sludge.add_child(sprite)
	near.modulate.a = 0.0

	var show_frame := func(f: float) -> void:
		var i: int = clampi(int(floor(f)), 0, frames.size() - 1)
		far.texture = frames[i]
		near.texture = frames[mini(i + 1, frames.size() - 1)]
		near.modulate.a = f - float(i)

	var tween := sludge.create_tween()
	tween.tween_property(sludge, "modulate:a", 1.0, 0.06)
	# Splash: a fast, even burst outward from nothing to fully spread.
	tween.tween_method(show_frame, 0.0, float(SLUDGE_HOLD_FRAME), SLUDGE_SPLASH_TIME).set_trans(Tween.TRANS_LINEAR)
	tween.tween_interval(SLUDGE_HOLD_TIME)
	# Retract: eased at both ends, so the sludge peels away reluctantly and
	# settles rather than snapping back.
	tween.tween_method(show_frame, float(SLUDGE_HOLD_FRAME), float(frames.size() - 1), SLUDGE_RETRACT_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_callback(sludge.queue_free)

## Loaded on first use and cached for the rest of the run rather than
## preloaded: these are sixteen 314x314 textures that only matter when one
## specific 9-mana legendary hits the board, and preloading would pay for
## them in every headless run (--core-tests, --parity-test) and every
## session that never draws him.
static var _sludge_frames_cache: Array[Texture2D] = []

static func _sludge_frames() -> Array[Texture2D]:
	if not _sludge_frames_cache.is_empty():
		return _sludge_frames_cache
	var loaded: Array[Texture2D] = []
	for i in SLUDGE_FRAME_COUNT:
		var tex := load(SLUDGE_FRAME_DIR + "sludge-%02d.png" % i) as Texture2D
		if tex == null:
			# A missing frame desyncs every index after it, so drop the
			# effect entirely rather than play a partial one - the card
			# still gets its heavier slam and board shake either way.
			push_warning("StinkPile sludge frame %d missing - skipping sludge effect" % i)
			return []
		loaded.append(tex)
	_sludge_frames_cache = loaded
	return _sludge_frames_cache
