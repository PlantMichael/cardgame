class_name MCTSEngine
extends RefCounted

## Heuristic-guided MCTS: UCT selection/expansion/backpropagation over the
## *current turn's* atomic action sequence (via HeadlessTurn), with rollouts
## cut short and scored by AIHeuristics.evaluate_state instead of playing to
## game-over. This is the real combinatorial space worth searching in a
## turn-based game — sequencing this turn's plays/attacks — while the
## opponent's response (and any further look-ahead turns) is predicted with
## the fast greedy policy rather than also being tree-searched.
##
## Difficulty levels 1-10 differ only by search budget (iterations), how many
## additional full turns get simulated forward before scoring a leaf
## (depth_plies), and a chance to discard the search's pick for a random
## legal action instead (mistake_rate) — one engine, no forked "easy" logic.

## Tuned against measured wall-clock cost (~8ms/iteration in practice; see
## .docs/ai.md's MCTSBenchmark/timing notes) so level 10 stays around ~1-1.5s
## per decision instead of the multi-second stalls the naive iteration counts
## produced — a few of these per turn on top of THINK_DELAY is already a
## noticeable "thinking" pause; more than that reads as the game hanging.
const AI_LEVEL_CONFIG := {
	1:  {"iterations": 8,   "depth_plies": 1, "mistake_rate": 0.35},
	2:  {"iterations": 14,  "depth_plies": 1, "mistake_rate": 0.28},
	3:  {"iterations": 22,  "depth_plies": 1, "mistake_rate": 0.20},
	4:  {"iterations": 30,  "depth_plies": 2, "mistake_rate": 0.14},
	5:  {"iterations": 45,  "depth_plies": 2, "mistake_rate": 0.08},
	6:  {"iterations": 65,  "depth_plies": 2, "mistake_rate": 0.05},
	7:  {"iterations": 90,  "depth_plies": 2, "mistake_rate": 0.03},
	8:  {"iterations": 100, "depth_plies": 3, "mistake_rate": 0.02},
	9:  {"iterations": 120, "depth_plies": 3, "mistake_rate": 0.01},
	10: {"iterations": 140, "depth_plies": 3, "mistake_rate": 0.0},
}

## AIHeuristics.evaluate_state deltas between two realistic mid-game boards
## typically land in the tens (occasionally low hundreds for terminal wins,
## which dwarf everything on purpose). UCT's classic exploration constant of
## ~1.4 assumes rewards in [0,1], so it's scaled up here to stay meaningful
## against that range instead of the search collapsing to pure greedy pick.
const UCT_C := 35.0

## choose_action() yields to the engine every this-many iterations so a
## single search never blocks rendering/input for its full ~1-1.5s (level
## 10) in one uninterrupted stretch — each chunk instead costs roughly
## ITERATIONS_PER_YIELD * ~8ms (~65ms at 8). This matters most when both
## sides of a match are searching back-to-back (e.g. SimRunner's balance
## sims), where long unyielded stretches otherwise read as the game hanging.
const ITERATIONS_PER_YIELD := 8

## Iteration budget for a choose_action() call that continues an already-
## reused tree (see _root/advance_after_real_action below) instead of
## starting fresh — a turn with several actions no longer pays the full
## per-level iteration cost on every single one of them, since the reused
## subtree already carries visit/value stats from the turn's opening search.
const TOPUP_ITERATIONS := 24

var ai_player_id: String
var ai_level: int

## Persists across choose_action() calls within the same AIController.take_
## turn() loop so a turn's search tree is built once and walked forward one
## atomic action at a time instead of rebuilt from scratch per action (that
## rebuild-per-action pattern is what made a multi-action AI turn take
## several stacked full searches — enough to read as the game hanging; see
## [[project_mcts_ai_ranked]]-adjacent debugging). AIController must call
## advance_after_real_action() after actually applying each returned action.
var _root: _MCTSNode = null
## The child chosen by the most recent choose_action() call — advance_after_
## real_action() reuses it as the next _root if its predicted post-action
## state matches what the real game_state turned into (see _fingerprint);
## otherwise the tree is discarded and rebuilt fresh next call, so a
## mismatch only costs speed, never correctness.
var _pending_child: _MCTSNode = null

class _MCTSNode:
	extends RefCounted
	var state: GameState
	var parent: _MCTSNode = null
	var action = null
	var children: Array[_MCTSNode] = []
	var untried_actions: Array[Dictionary] = []
	var visits: int = 0
	var value_sum: float = 0.0
	var is_terminal: bool = false

	func _init(p_state: GameState, p_parent: _MCTSNode, p_action, p_is_terminal: bool) -> void:
		state = p_state
		parent = p_parent
		action = p_action
		is_terminal = p_is_terminal

	func average_value() -> float:
		return value_sum / visits if visits > 0 else 0.0

func _init(p_ai_player_id: String, p_ai_level: int = 5) -> void:
	ai_player_id = p_ai_player_id
	ai_level = clampi(p_ai_level, 1, 10)

## Runs a search rooted at (a clone of) `game_state` — or continues the tree
## left behind by the previous call if advance_after_real_action() reused it
## — and returns the single atomic action recommended for `ai_player_id` to
## take next — safe to apply directly to `game_state` itself (see
## _translate_to_real). Callers driving a whole turn must invoke
## advance_after_real_action() with the resulting real `game_state` right
## after actually applying the returned action, or the tree is silently
## rebuilt from scratch next call (correct, just back to the pre-reuse cost).
func choose_action(game_state: GameState) -> Dictionary:
	var config: Dictionary = AI_LEVEL_CONFIG.get(ai_level, AI_LEVEL_CONFIG[5])
	var budget: int

	if _root == null:
		var root_state := game_state.duplicate_for_sim()
		var root_actions := HeadlessTurn.list_legal_actions(root_state, ai_player_id)
		if root_actions.is_empty():
			return {"type": "end_turn"}
		if root_actions.size() == 1:
			_pending_child = null
			return _translate_to_real(root_actions[0], game_state)
		_root = _MCTSNode.new(root_state, null, null, false)
		_root.untried_actions = root_actions.duplicate()
		budget = int(config["iterations"])
	else:
		budget = mini(int(config["iterations"]), TOPUP_ITERATIONS)

	for i in budget:
		if i > 0 and i % ITERATIONS_PER_YIELD == 0:
			await Engine.get_main_loop().process_frame
		var node := _root

		# Selection: descend fully-expanded, non-terminal nodes via UCT.
		while node.untried_actions.is_empty() and not node.children.is_empty() and not node.is_terminal:
			node = _uct_select(node)

		# Expansion: try one new action from this node.
		if not node.is_terminal and not node.untried_actions.is_empty():
			var idx := randi() % node.untried_actions.size()
			var action: Dictionary = node.untried_actions[idx]
			node.untried_actions.remove_at(idx)

			var child_state: GameState = node.state.duplicate_for_sim()
			HeadlessTurn.apply_action(child_state, action)
			var terminal: bool = action["type"] == "end_turn" or child_state.current_phase == GameState.Phase.GAME_OVER

			var child := _MCTSNode.new(child_state, node, action, terminal)
			if not terminal:
				child.untried_actions = HeadlessTurn.list_legal_actions(child_state, ai_player_id)
			node.children.append(child)
			node = child

		# Simulation: finish forward via the fast greedy policy, then score.
		var value := _simulate(node.state.duplicate_for_sim(), int(config["depth_plies"]))

		# Backpropagation.
		var cursor := node
		while cursor != null:
			cursor.visits += 1
			cursor.value_sum += value
			cursor = cursor.parent

	var best: _MCTSNode = null
	for child in _root.children:
		if best == null or child.visits > best.visits:
			best = child
	var chosen_action: Dictionary
	if best != null:
		chosen_action = best.action
	elif not _root.untried_actions.is_empty():
		chosen_action = _root.untried_actions[0]
	else:
		chosen_action = {"type": "end_turn"}
	_pending_child = best

	var mistake_rate: float = config["mistake_rate"]
	if mistake_rate > 0.0 and randf() < mistake_rate:
		var all_actions: Array[Dictionary] = _root.untried_actions.duplicate()
		for child in _root.children:
			all_actions.append(child.action)
		chosen_action = all_actions[randi() % all_actions.size()]
		_pending_child = null
		for child in _root.children:
			if child.action == chosen_action:
				_pending_child = child
				break
	return _translate_to_real(chosen_action, game_state)

## Called by AIController right after it actually applies the action
## choose_action() returned to the real `game_state`. If the child the search
## predicted for that action matches what really happened (verified via a
## cheap structural fingerprint — instance_ids are preserved verbatim by
## duplicate_for_sim() so a clone's and the real state's minions line up),
## that child becomes the new root and its accumulated visit/value stats
## carry into the next choose_action() call instead of starting cold. A
## mismatch (e.g. a mid-turn pending-queue ability rolled a different random
## target than the search's own rollout did) just discards the tree —
## costs the next call full search time again, never correctness.
func advance_after_real_action(real_state_after: GameState) -> void:
	if _pending_child != null and _fingerprint(_pending_child.state) == _fingerprint(real_state_after):
		_pending_child.parent = null
		_root = _pending_child
	else:
		_root = null
	_pending_child = null

static func _fingerprint(state: GameState) -> String:
	var parts: Array[String] = []
	for p in [state.player, state.opponent]:
		parts.append("%d|%d" % [p.hero_health, p.current_mana])
		var hand_ids: Array[String] = []
		for c in p.hand:
			hand_ids.append(c.id)
		hand_ids.sort()
		parts.append(",".join(hand_ids))
		var board_sig: Array[String] = []
		for m in p.board:
			board_sig.append("%s:%d:%d" % [m.instance_id, m.current_attack, m.current_health])
		board_sig.sort()
		parts.append(",".join(board_sig))
	return "|".join(parts)

## Root-level actions (the only ones ever returned) reference CardData/Minion
## objects from the internal duplicate_for_sim() clone the search ran
## against, not `game_state` itself. Applying those clone objects directly to
## the real state would silently no-op (Array.erase()/identity checks fail
## against a different instance) instead of raising an error, so every
## chosen action must be re-resolved to its equivalent real object before the
## caller applies it: cards by matching `.id` in the real hand (any physical
## copy of the same card plays identically), minions by matching
## `instance_id` (preserved verbatim by duplicate_for_sim) on the real board.
func _translate_to_real(action: Dictionary, game_state: GameState) -> Dictionary:
	var out := action.duplicate()
	if out.get("card") != null:
		var acting: PlayerState = game_state._get_player_by_id(ai_player_id)
		for c in acting.hand:
			if c.id == out["card"].id:
				out["card"] = c
				break
	for key in ["attacker", "target", "minion"]:
		if out.get(key) != null:
			out[key] = _find_real_minion(game_state, out[key].instance_id)
	return out

func _find_real_minion(game_state: GameState, instance_id: String) -> Minion:
	for m in game_state.player.board:
		if m.instance_id == instance_id:
			return m
	for m in game_state.opponent.board:
		if m.instance_id == instance_id:
			return m
	return null

func _uct_select(node: _MCTSNode) -> _MCTSNode:
	var best: _MCTSNode = null
	var best_score := -INF
	var parent_visits: int = maxi(1, node.visits)
	for child in node.children:
		var score: float
		if child.visits == 0:
			score = INF
		else:
			score = child.average_value() + UCT_C * sqrt(log(float(parent_visits)) / float(child.visits))
		if score > best_score:
			best_score = score
			best = child
	return best

## Drives `state` forward one full turn at a time (whoever is currently
## active — this correctly picks up mid-AI-turn if the searched action
## didn't end the turn, or on the opponent's turn if it did) for
## `depth_plies` turns, then scores the resulting position for `ai_player_id`.
func _simulate(state: GameState, depth_plies: int) -> float:
	var plies_done := 0
	while plies_done < depth_plies and state.current_phase != GameState.Phase.GAME_OVER:
		HeadlessTurn.play_full_turn_greedy(state, state.active_player_id)
		plies_done += 1
	return AIHeuristics.evaluate_state(state, ai_player_id)
