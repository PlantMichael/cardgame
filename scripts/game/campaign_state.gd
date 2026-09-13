class_name CampaignState
extends RefCounted

## Pure-logic state for a Campaign run (see .docs/status.md): a sequence of
## best-of-N node matches, some of which carry a battlefield-wide modifier
## (see CampaignModifiers / GameState.node_modifier_ability). No Node/UI
## deps, same convention as GameState.

enum Size { SMALL, MEDIUM, LARGE }

const CONFIG := {
	Size.SMALL: {"best_of": 3, "modified_nodes": 1},
	Size.MEDIUM: {"best_of": 5, "modified_nodes": 2},
	Size.LARGE: {"best_of": 7, "modified_nodes": 4},
}

## A side falling this many node-wins behind gets a small catch-up bonus
## (see main.gd's _start_campaign_match / GameManagerAutoload's
## grant_catchup_mana) on the next node.
const CATCHUP_BEHIND_THRESHOLD := 2

var size: Size
var best_of: int
var total_nodes: int
var player_wins: int = 0
var opponent_wins: int = 0
var current_node_index: int = 0
## Per-node outcome for the map screen: "" (not played yet), "won", "lost".
var node_results: Array[String] = []

## Which of the campaign map screen's map images this run uses, and the
## procedural node-marker layout (normalized 0..1 viewport coordinates) -
## both decided once at creation (see _generate_layout) and, for a PvP
## campaign, shipped from the host to the guest via to_layout_dict()/
## apply_layout() so both clients render the same map instead of each
## picking their own independently (see main.gd's campaign PvP handshake).
var map_index: int = 0
var node_positions: Array[Vector2] = []

## The faction color (CardData.CardColor) each side is playing this run, set
## once via set_faction_colors() right after decks are chosen - drives
## node_result_color() so a won/lost node fills with the winner's actual
## faction color instead of a generic win/lose color.
var player_faction_color: CardData.CardColor = CardData.CardColor.GREEN
var opponent_faction_color: CardData.CardColor = CardData.CardColor.GREEN

## Which node indices carry a modifier at all (fixed at creation).
var _modified_node_flags: Array[bool] = []
## Resolved modifier per node ({} = none, or not yet chosen). Index 0 is
## resolved immediately since there's no "loser of the previous node" to
## make the pick yet; every other flagged node is resolved lazily via
## resolve_current_node_modifier() once its predecessor has a loser.
var _nodes: Array[Dictionary] = []

func _init(campaign_size: Size) -> void:
	size = campaign_size
	var cfg: Dictionary = CONFIG[size]
	best_of = cfg["best_of"]
	total_nodes = best_of

	_modified_node_flags.resize(total_nodes)
	for i in total_nodes:
		_modified_node_flags[i] = false
	var idxs := range(total_nodes)
	idxs.shuffle()
	for i in mini(int(cfg["modified_nodes"]), total_nodes):
		_modified_node_flags[idxs[i]] = true

	_nodes.resize(total_nodes)
	for i in total_nodes:
		_nodes[i] = {}
	if _modified_node_flags[0]:
		_nodes[0] = CampaignModifiers.random_one()

	node_results.resize(total_nodes)
	for i in total_nodes:
		node_results[i] = ""

	map_index = randi() % 3
	_generate_node_positions()

## Winding path of node marker positions (normalized 0..1), evenly spread
## left-to-right with an alternating up/down jitter so it reads as a trail
## rather than a flat row - see campaign_map_screen.gd for how these get
## scaled to actual viewport pixels.
func _generate_node_positions() -> void:
	node_positions.resize(total_nodes)
	for i in total_nodes:
		var t := 0.5 if total_nodes <= 1 else float(i) / float(total_nodes - 1)
		var x := lerpf(0.12, 0.88, t) + randf_range(-0.02, 0.02)
		var side := 1.0 if i % 2 == 1 else -1.0
		var y := 0.5 + side * randf_range(0.14, 0.28)
		node_positions[i] = Vector2(clampf(x, 0.06, 0.94), clampf(y, 0.22, 0.78))

func wins_needed() -> int:
	return int(best_of / 2) + 1

func current_node() -> Dictionary:
	return _nodes[current_node_index]

## Map-screen introspection (see campaign_map_screen.gd) for any node index,
## not just the current one — current_node()/current_node_needs_choice() only
## ever look at current_node_index.
func is_node_modified(index: int) -> bool:
	return _modified_node_flags[index]

## Resolved modifier for any node ({} if none, or not yet chosen — see
## _nodes' doc comment above).
func get_node_modifier(index: int) -> Dictionary:
	return _nodes[index]

## True once current_node_index has advanced onto a flagged node whose
## modifier hasn't been picked yet — the loser of the last node picks it
## (see get_modifier_choices/resolve_current_node_modifier).
func current_node_needs_choice() -> bool:
	return _modified_node_flags[current_node_index] and _nodes[current_node_index].is_empty()

func get_modifier_choices() -> Array[Dictionary]:
	return CampaignModifiers.random_two()

func resolve_current_node_modifier(chosen: Dictionary) -> void:
	_nodes[current_node_index] = chosen

func report_node_result(player_won: bool) -> void:
	node_results[current_node_index] = "won" if player_won else "lost"
	if player_won:
		player_wins += 1
	else:
		opponent_wins += 1
	current_node_index += 1

func is_over() -> bool:
	return player_wins >= wins_needed() or opponent_wins >= wins_needed()

func player_won_campaign() -> bool:
	return player_wins >= wins_needed()

func score_string() -> String:
	return "%d - %d" % [player_wins, opponent_wins]

func is_player_behind() -> bool:
	return opponent_wins - player_wins >= CATCHUP_BEHIND_THRESHOLD

func is_opponent_behind() -> bool:
	return player_wins - opponent_wins >= CATCHUP_BEHIND_THRESHOLD

func set_faction_colors(p: CardData.CardColor, o: CardData.CardColor) -> void:
	player_faction_color = p
	opponent_faction_color = o

## Map-screen node fill: the winning side's actual faction color, or fully
## transparent for a node that hasn't been played yet.
func node_result_color(index: int) -> Color:
	match node_results[index]:
		"won":
			return DeckManager.FACTION_SWATCHES[int(player_faction_color)]
		"lost":
			return DeckManager.FACTION_SWATCHES[int(opponent_faction_color)]
		_:
			return Color(0, 0, 0, 0)

## Snapshot of everything decided randomly at _init() time - PvP campaigns
## use this once, right after matchmaking, so the guest's independently-
## constructed CampaignState ends up with the same modifiers/map/node layout
## as the host's authoritative copy instead of each side rolling its own
## (see main.gd's campaign PvP handshake). Mutable per-match progress
## (node_results, wins, current_node_index) is deliberately excluded - each
## client advances that independently but identically, from its own local
## match outcomes.
func to_layout_dict() -> Dictionary:
	var positions: Array = []
	for p in node_positions:
		positions.append([p.x, p.y])
	return {
		"modified_node_flags": _modified_node_flags.duplicate(),
		"node0_modifier": _nodes[0].duplicate(),
		"map_index": map_index,
		"node_positions": positions,
	}

func apply_layout(d: Dictionary) -> void:
	_modified_node_flags.clear()
	for f in d.get("modified_node_flags", []):
		_modified_node_flags.append(bool(f))
	_nodes[0] = d.get("node0_modifier", {}).duplicate()
	map_index = int(d.get("map_index", 0))
	node_positions.clear()
	for arr in d.get("node_positions", []):
		node_positions.append(Vector2(float(arr[0]), float(arr[1])))
