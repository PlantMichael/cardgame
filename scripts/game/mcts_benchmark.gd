class_name MCTSBenchmark
extends RefCounted

## Headless AI-vs-AI benchmark, independent of Board/UI (same spirit as
## SimRunner's balance-testing games, but pitting MCTSEngine configurations
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
			await _play_turn(gs, acting_id, policy_a if acting_id == "sim_a" else policy_b)
			turns_played += 1
		print("  game %d/%d done: winner=%s turns=%d" % [_i + 1, count, gs.winner_id, turns_played])

		if gs.winner_id == "sim_a":
			results["a_wins"] += 1
		elif gs.winner_id == "sim_b":
			results["b_wins"] += 1
		else:
			results["draws"] += 1
	return results

static func _play_turn(gs: GameState, acting_id: String, policy: Policy) -> void:
	if policy.kind == PolicyKind.GREEDY:
		HeadlessTurn.play_full_turn_greedy(gs, acting_id)
		return
	var engine := MCTSEngine.new(acting_id, policy.level)
	for _i in 60:
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return
		var action := await engine.choose_action(gs)
		HeadlessTurn.apply_action(gs, action)
		if action["type"] == "end_turn" or gs.current_phase == GameState.Phase.GAME_OVER:
			return
