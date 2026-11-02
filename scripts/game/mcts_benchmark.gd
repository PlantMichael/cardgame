class_name MCTSBenchmark
extends RefCounted

## Headless AI-vs-AI benchmark, independent of Board/UI (same spirit as
## balance-testing games, pitting MCTSEngine configurations
## against each other or against the legacy greedy policy) so difficulty
## tuning can be verified by win rate instead of manual play.

enum PolicyKind { GREEDY, MCTS }

class Policy:
	extends RefCounted
	var kind: PolicyKind
	var level: int
	func _init(p_kind: PolicyKind, p_level: int = 5) -> void:
		kind = p_kind
		level = p_level

static func greedy() -> Policy:
	return Policy.new(PolicyKind.GREEDY)

static func mcts(level: int) -> Policy:
	return Policy.new(PolicyKind.MCTS, level)

const FACTION_COLORS := [
	CardData.CardColor.GREEN, CardData.CardColor.CRIMSON, CardData.CardColor.BLACK,
	CardData.CardColor.ORANGE, CardData.CardColor.TEAL,
]

## Runs `count` games with policy_a as "sim_a" and policy_b as "sim_b" (random
## decks each game, alternating who goes first). Returns
## {"a_wins": int, "b_wins": int, "draws": int}.
static func run(count: int, policy_a: Policy, policy_b: Policy) -> Dictionary:
	var results := {"a_wins": 0, "b_wins": 0, "draws": 0}
	for _i in count:
		var deck_a := DeckManager.build_random_faction_deck(FACTION_COLORS[randi() % FACTION_COLORS.size()])
		var deck_b := DeckManager.build_random_faction_deck(FACTION_COLORS[randi() % FACTION_COLORS.size()])
		if deck_a.is_empty() or deck_b.is_empty():
			continue

		var gs := GameState.new("sim_a", "sim_b", deck_a, deck_b)
		var first := "sim_a" if randi() % 2 == 0 else "sim_b"
		gs.start_game(first)
		HeadlessTurn._resolve_pending(gs)

		var turns_played := 0
		for _t in 200:
			if gs.current_phase == GameState.Phase.GAME_OVER:
				break
			var acting_id := gs.active_player_id
			await _play_turn(gs, acting_id, {"sim_a": policy_a, "sim_b": policy_b})
			turns_played += 1
		print("  game %d/%d done: winner=%s turns=%d" % [_i + 1, count, gs.winner_id, turns_played])

		if gs.winner_id == "sim_a":
			results["a_wins"] += 1
		elif gs.winner_id == "sim_b":
			results["b_wins"] += 1
		else:
			results["draws"] += 1
	return results

static func _play_turn(gs: GameState, acting_id: String, policies: Dictionary) -> void:
	var policy: Policy = policies[acting_id]
	var engine := MCTSEngine.new(acting_id, policy.level) if policy.kind == PolicyKind.MCTS else null
	for _i in 120:
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return
		if gs.has_pending_choice():
			var owner := str(gs.pending_choice["player_id"])
			var choice_policy: Policy = policies[owner]
			var command: Dictionary
			if choice_policy.kind == PolicyKind.MCTS:
				var chooser := engine if owner == acting_id and engine != null else MCTSEngine.new(owner, choice_policy.level)
				command = await chooser.choose_action(gs)
			else:
				command = {"type": GameState.CMD_ANSWER_CHOICE, "actor": owner,
					"choice_id": gs.pending_choice["id"], "selection": AIHeuristics.pick_choice_answer(gs, gs.pending_choice)}
			if not HeadlessTurn.apply_action(gs, command, false):
				push_error("Benchmark choice rejected: " + str(command))
				return
		elif gs.active_player_id != acting_id:
			return
		else:
			var action: Dictionary = await engine.choose_action(gs) if engine != null else HeadlessTurn.greedy_pick_action(gs, acting_id)
			if not HeadlessTurn.apply_action(gs, action, false):
				push_error("Benchmark action rejected: " + str(action))
				return
		if engine != null:
			engine.advance_after_real_action(gs)
