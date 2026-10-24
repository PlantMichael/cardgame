class_name EventPresenter
extends RefCounted

## Turns the rules core's advisory events (see GameState.events) into what the
## player sees: log lines and the challenge / laser animations. It never changes
## game state - the board is rebuilt from the state itself afterwards - so a
## missing or late event can only cost an animation, never desync a match.
##
## Used by every controller that renders a match (local play, the AI, and the
## thin ranked client), so an effect looks the same wherever it was decided.

## Who a log line is about, from the viewer's side.
static func _owner_word(owner_id: String, local_id: String) -> String:
	return "Your" if owner_id == local_id else "Opponent's"

## "your Y" / "opponent's Y" / "the opponent's hero" for an effect's target.
static func _target_phrase(e: Dictionary, local_id: String) -> String:
	var name := str(e.get("target_name", ""))
	if name.is_empty():
		return ""
	var target_owner := str(e.get("target_owner", ""))
	if name == "hero":
		return "your hero" if target_owner == local_id else "the opponent's hero"
	if target_owner.is_empty():
		return name
	return ("your " if target_owner == local_id else "opponent's ") + name

static func present(events: Array, board: Board, local_id: String) -> void:
	for e in events:
		if not is_instance_valid(board):
			return
		match str(e.get("type", "")):
			"effect":
				await _present_effect(e, board, local_id)
			"challenge":
				await _present_challenge(e, board, local_id)

static func _present_effect(e: Dictionary, board: Board, local_id: String) -> void:
	var owner_id := str(e.get("owner", ""))
	var source_name := str(e.get("source_name", ""))
	var parts: PackedStringArray = []
	parts.append(_owner_word(owner_id, local_id) + (" " + source_name if not source_name.is_empty() else ""))
	parts.append(str(e.get("verb", "")))
	var target := _target_phrase(e, local_id)
	if not target.is_empty():
		parts.append(target)
	board.log_action(" ".join(parts))
	# A creature killed by a ranged effect gets the laser.
	if str(e.get("style", "")) == "damage" and bool(e.get("killed", false)) and str(e.get("target", "")) != "":
		var target_card: Card = board.find_card_node(str(e["target"]))
		if target_card != null:
			var source_card: Card = board.find_card_node(str(e.get("source", ""))) if str(e.get("source", "")) != "" else null
			var from: Vector2
			if source_card != null and is_instance_valid(source_card.get_parent()):
				from = source_card.get_parent().get_global_rect().get_center()
			else:
				from = target_card.get_parent().get_global_rect().get_center() + Vector2(0, -600)
			await board.animate_laser_kill(from, target_card)

static func _present_challenge(e: Dictionary, board: Board, local_id: String) -> void:
	var owner_id := str(e.get("owner", ""))
	board.log_action("%s %s challenged %s" % [
		_owner_word(owner_id, local_id), str(e.get("challenger_name", "")),
		_target_phrase({"target_name": e.get("target_name", ""), "target_owner": e.get("target_owner", "")}, local_id)])
	await board.animate_creature_challenge(str(e.get("challenger", "")), owner_id, str(e.get("target", "")))
