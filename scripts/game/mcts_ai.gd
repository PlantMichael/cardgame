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

## Node ceilings combine with a level-scaled wall-clock ceiling below.
## Expensive individual simulations can exceed that ceiling; see .docs/ai.md.
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

## Search rewards are bounded in [-1, 1]. Mixing 100000-point rollout wins
## with ordinary board scores used to overwhelm exploration and could stop
## the tree from ever inspecting an immediate winning target.
const UCT_C := 0.35

## Yield after eight iterations or about 8ms of accumulated search work.
## An individual simulation is synchronous and cannot be preempted.
const ITERATIONS_PER_YIELD := 8
const YIELD_AFTER_USEC := 8000
const MAX_DECISION_MSEC := 1000

## Iteration budget for a choose_action() call that continues an already-
## reused tree (see _root/advance_after_real_action below) instead of
## starting fresh — a turn with several actions no longer pays the full
## per-level iteration cost on every single one of them, since the reused
## subtree already carries visit/value stats from the turn's opening search.
const TOPUP_ITERATIONS := 24

var ai_player_id: String
var ai_level: int
var last_search_iterations: int = 0
var last_search_msec: int = 0
var _turn_anchor: int = 0
var _rollout_winning_line: Array[Dictionary] = []
## Simulation personalities are opt-in; ordinary opponents keep the existing policy.
var style: String = ""

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
	# Children own their descendants; a strong backlink would retain every
	# discarded search branch (and its copied match state) forever.
	var parent: WeakRef = null
	var action = null
	var children: Array[_MCTSNode] = []
	var untried_actions: Array[Dictionary] = []
	var actions_ordered: bool = false
	var visits: int = 0
	var value_sum: float = 0.0
	var is_terminal: bool = false
	var winning_line: Array[Dictionary] = []

	func _init(p_state: GameState, p_parent: _MCTSNode, p_action, p_is_terminal: bool) -> void:
		state = p_state
		parent = weakref(p_parent) if p_parent != null else null
		action = p_action
		is_terminal = p_is_terminal

	func average_value() -> float:
		return value_sum / visits if visits > 0 else 0.0

## The search's OWN randomness - which action to expand next, whether to make
## a deliberate mistake. Deliberately separate from the match's generator
## (GameState.rng): how hard the AI thinks is not part of the game, so
## changing the search budget, or searching at all, must not change what the
## match itself rolls. Kept off the global stream for the same reason.
var _search_rng := RandomNumberGenerator.new()

func _init(p_ai_player_id: String, p_ai_level: int = 5, p_style: String = "") -> void:
	ai_player_id = p_ai_player_id
	ai_level = clampi(p_ai_level, 1, 10)
	style = p_style

## Runs a search rooted at (a clone of) `game_state` — or continues the tree
## left behind by the previous call if advance_after_real_action() reused it
## — and returns the single atomic action recommended for `ai_player_id` to
## take next — entities are addressed by value. Callers driving a whole turn must invoke
## advance_after_real_action() with the resulting real `game_state` right
## after actually applying the returned action, or the tree is silently
## rebuilt from scratch next call (correct, just back to the pre-reuse cost).
func choose_action(game_state: GameState) -> Dictionary:
	var started := Time.get_ticks_msec()
	last_search_iterations = 0
	last_search_msec = 0
	var config: Dictionary = AI_LEVEL_CONFIG.get(ai_level, AI_LEVEL_CONFIG[5])
	var budget: int

	if _root != null and _fingerprint(_root.state) != _fingerprint(game_state):
		_root = null
		_pending_child = null
	if _root == null:
		_turn_anchor = game_state.turn_number * 2 + int(game_state.active_player_id == game_state.opponent.player_id)
		var root_state := game_state.duplicate_for_sim()
		var root_actions := HeadlessTurn.list_legal_actions(root_state, ai_player_id)
		if root_actions.is_empty():
			return {"type": "end_turn", "actor": ai_player_id}
		if root_actions.size() == 1:
			_pending_child = null
			return root_actions[0]
		_root = _MCTSNode.new(root_state, null, null, false)
		_root.untried_actions = root_actions.duplicate()
		budget = int(config["iterations"])
	else:
		budget = mini(int(config["iterations"]), TOPUP_ITERATIONS)
	# Keep a winning continuation already executed in a clone, rather than
	# forgetting it when the next atomic choice gets only a small top-up.
	if _witness_child() != null:
		budget = 0

	var last_yield := Time.get_ticks_usec()
	var time_limit := MAX_DECISION_MSEC * ai_level / 10
	for i in budget:
		# Node limits remain deterministic ceilings; the clock also bounds
		# expensive branching positions and slower Web devices.
		if i > 0 and Time.get_ticks_msec() - started >= time_limit:
			break
		if i > 0 and (i % ITERATIONS_PER_YIELD == 0 or Time.get_ticks_usec() - last_yield >= YIELD_AFTER_USEC):
			await Engine.get_main_loop().process_frame
			last_yield = Time.get_ticks_usec()
		last_search_iterations += 1
		var node := _root

		# Selection: descend fully-expanded, non-terminal nodes via UCT.
		while node.untried_actions.is_empty() and not node.children.is_empty() and not node.is_terminal:
			node = _uct_select(node)

		# Expansion: try one new action from this node.
		if not node.is_terminal and not node.untried_actions.is_empty():
			_order_actions(node)
			var action: Dictionary = node.untried_actions.pop_front()

			# The action was enumerated against node.state but is applied to a
			# fresh copy. That is only sound because actions are plain values
			# resolved against the state receiving them (see
			# GameState.validate) - applying a parent's Minion/CardData object
			# here used to mutate the parent instead of the child.
			var child_state: GameState = node.state.duplicate_for_sim()
			var applied := HeadlessTurn.apply_action(child_state, action, false)
			var terminal: bool = (not applied) or action["type"] == "end_turn" or child_state.current_phase == GameState.Phase.GAME_OVER
			if child_state.active_player_id != ai_player_id and not child_state.has_pending_choice():
				terminal = true

			var child := _MCTSNode.new(child_state, node, action, terminal)
			if not terminal:
				child.untried_actions = HeadlessTurn.list_legal_actions(child_state, ai_player_id)
			node.children.append(child)
			node = child

		# Simulation: finish forward via the fast greedy policy, then score.
		var value := _simulate(node.state.duplicate_for_sim(), int(config["depth_plies"]))
		if not _rollout_winning_line.is_empty():
			node.winning_line.assign(_rollout_winning_line)

		# Backpropagation.
		var cursor := node
		while cursor != null:
			cursor.visits += 1
			cursor.value_sum += value
			cursor = cursor.parent.get_ref() if cursor.parent != null else null
		if node.state.winner_id == ai_player_id or not node.winning_line.is_empty():
			break

	var best: _MCTSNode = null
	last_search_msec = Time.get_ticks_msec() - started
	for child in _root.children:
		if best == null or child.visits > best.visits:
			best = child
	# A terminal win reached by searched actions outranks a merely popular line.
	var winning := _winning_child(_root)
	if winning != null:
		best = winning
	var chosen_action: Dictionary
	if best != null:
		chosen_action = best.action
	elif not _root.untried_actions.is_empty():
		chosen_action = _root.untried_actions[0]
	else:
		chosen_action = {"type": "end_turn", "actor": ai_player_id}
	_pending_child = best

	var mistake_rate: float = config["mistake_rate"]
	if mistake_rate > 0.0 and _search_rng.randf() < mistake_rate:
		var all_actions: Array[Dictionary] = _root.untried_actions.duplicate()
		for child in _root.children:
			all_actions.append(child.action)
		chosen_action = all_actions[_search_rng.randi_range(0, all_actions.size() - 1)]
		_pending_child = null
		for child in _root.children:
			if child.action == chosen_action:
				_pending_child = child
				break
	# Returned as-is: the action names entities by uid/instance_id, which the
	# real state resolves itself. No translation step is needed (or possible
	# to get subtly wrong) any more.
	return chosen_action

## Called by AIController right after it actually applies the action
## choose_action() returned to the real `game_state`. If the child the search
## predicted for that action matches what really happened (verified via
## _fingerprint), that child becomes the new root and its accumulated
## visit/value stats carry into the next choose_action() call instead of
## starting cold. A mismatch (e.g. a mid-turn pending-queue ability rolled a
## different random target than the search's own rollout did) just discards
## the tree - costs the next call full search time again, never correctness.
func advance_after_real_action(real_state_after: GameState) -> void:
	if _pending_child != null and _fingerprint(_pending_child.state) == _fingerprint(real_state_after):
		_pending_child.parent = null
		_root = _pending_child
	else:
		_root = null
	_pending_child = null

## A canonical encoding of everything that can change how the rest of the
## match plays out. Two states sharing a fingerprint must be interchangeable,
## because a match licenses reusing a search tree built against the other.
##
## It therefore has to be complete, not merely indicative. The earlier version
## sorted each board and recorded only instance_id/attack/health, which threw
## away three things that change legal play:
##
##  - Board ORDER. Feast Attendant picks its targets by adjacency, so two
##    boards holding the same creatures in a different order are different
##    positions. Sorting made them compare equal.
##  - Readiness and abilities. A creature that has already attacked, is
##    exhausted, silenced, shielded or piloted offers different moves than
##    one that is not.
##  - Card-level state. Two hands holding the same card ids differ when one
##    copy is discounted or carries rummage history, and the pending queues
##    carry effects that have not resolved yet.
##
## Anything added to the rules later that affects play must be added here too,
## or tree reuse silently starts certifying states that are not equivalent.
static func _fingerprint(state: GameState) -> String:
	# Reuse the rules' complete choice/zone/RNG digest, plus runtime definition
	# stats omitted by the replay digest (e.g. permanently buffed rummage cards).
	var extra: Array = []
	for p in [state.player, state.opponent]:
		extra.append(p._next_minion_seq)
		for zone in [p.hand, p.deck, p.graveyard]:
			for c in zone:
				extra.append([c.attack, c.health, c.cost, c.effect_value, c.transform_into, c.transform_choices])
		for m in p.board:
			extra.append([m.data.id, m.data.attack, m.data.health, m.data.cost, m.divine_shield,
				m.is_piloted, m.pilot_atk_bonus, m.pilot_hp_bonus, m.data.rummage_count])
	extra.append(state._first_turn_taken)
	return state.state_hash() + JSON.stringify(extra)

func _winning_child(node: _MCTSNode) -> _MCTSNode:
	for child in node.children:
		if child.state.winner_id == ai_player_id or not child.winning_line.is_empty() or _winning_child(child) != null:
			return child
	return null

## Spend the bounded budget on promising outcomes first. This is an ordering
## prior, not a target whitelist: every alternative remains in the tree.
## Resolve real cloned effects, rather than adding card-specific priorities.
func _order_actions(node: _MCTSNode) -> void:
	if node.actions_ordered or node.untried_actions.size() < 2:
		return
	var scored: Array = []
	for action in node.untried_actions:
		var after := node.state.duplicate_for_sim()
		var value := -INF
		if HeadlessTurn.apply_action(after, action):
			value = AIHeuristics.evaluate_state(after, ai_player_id, style)
		scored.append({"action": action, "value": value, "tie": _search_rng.randf()})
	scored.sort_custom(func(a, b): return a["value"] > b["value"] if a["value"] != b["value"] else a["tie"] > b["tie"])
	node.untried_actions.clear()
	for item in scored:
		node.untried_actions.append(item["action"])
	node.actions_ordered = true

func _witness_child() -> _MCTSNode:
	if _root.winning_line.is_empty():
		return null
	var action: Dictionary = _root.winning_line[0]
	var after := _root.state.duplicate_for_sim()
	if not HeadlessTurn.apply_action(after, action, false):
		_root.winning_line.clear()
		return null
	for child in _root.children:
		if child.action == action and _fingerprint(child.state) == _fingerprint(after):
			child.winning_line.assign(_root.winning_line.slice(1))
			return child
	var child := _MCTSNode.new(after, _root, action, after.current_phase == GameState.Phase.GAME_OVER)
	child.winning_line.assign(_root.winning_line.slice(1))
	if not child.is_terminal:
		child.untried_actions = HeadlessTurn.list_legal_actions(after, ai_player_id)
	_root.children.append(child)
	return child

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
	_rollout_winning_line.clear()
	if state.current_phase == GameState.Phase.GAME_OVER:
		return 1.0 if state.winner_id == ai_player_id else -1.0
	# Preserve personality pressure at the current position as well as the rollout.
	var immediate := AIHeuristics.evaluate_state(state, ai_player_id, style) if not style.is_empty() else 0.0
	if state.active_player_id == ai_player_id:
		var trace: Array = []
		var complete := HeadlessTurn.play_full_turn_greedy(state, ai_player_id, true, trace)
		if complete and state.winner_id == ai_player_id:
			_rollout_winning_line.assign(trace)
			return 1.0
	HeadlessTurn._resolve_pending(state)
	# Compare siblings at the same horizon: end_turn already consumed one
	# ply, so it must not receive an extra opponent turn of forecast results.
	var plies_done := maxi(0, state.turn_number * 2 + int(state.active_player_id == state.opponent.player_id) - _turn_anchor)
	while plies_done < depth_plies and state.current_phase != GameState.Phase.GAME_OVER:
		HeadlessTurn.play_full_turn_greedy(state, state.active_player_id)
		plies_done += 1
	var value := AIHeuristics.evaluate_state(state, ai_player_id, style)
	# A rollout is a prediction, not an executed winning line. Prefer earlier
	# wins and keep a forecast win below a win actually reached by the tree;
	# otherwise end_turn can monopolize visits on a cooperative future rollout.
	if state.current_phase == GameState.Phase.GAME_OVER:
		return (0.9 if value > 0 else -0.9) / (1.0 + plies_done * 0.1)
	if not style.is_empty():
		# Neutral rollouts can postpone setup and erase the personality's
		# preference for building its combo or pressure on this turn.
		value = value * 0.35 + immediate * 0.65
	return value / (absf(value) + 100.0)
