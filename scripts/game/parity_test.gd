class_name ParityTest
extends RefCounted

## Seeded AI-vs-AI matches, each replayed from nothing but (seed, decks, first
## player, ordered command log) and compared step by step (spec 003, SC-002).
##
## What it proves, headlessly and with no server: the rules are deterministic
## and fully described by their commands. That is exactly the property the
## authoritative server relies on - to resume a match after a restart, to audit
## one, and to be sure a replay of a live match reaches the same result.
##
##   godot --headless --path <checkout> -- --parity-test [--parity-matches=N]
##
## Exit code = number of matches that failed.

const DEFAULT_MATCHES := 1000
const TURN_CAP := 60

static func run(matches: int = DEFAULT_MATCHES) -> int:
	var failures := 0
	var total_commands := 0
	var finished := 0
	var colors := [CardData.CardColor.GREEN, CardData.CardColor.CRIMSON, CardData.CardColor.BLACK,
		CardData.CardColor.ORANGE, CardData.CardColor.TEAL]
	for i in matches:
		var deck_a: Array[CardData] = DeckManager.build_random_faction_deck(colors[i % colors.size()])
		var deck_b: Array[CardData] = DeckManager.build_random_faction_deck(colors[(i * 3 + 1) % colors.size()])
		var seed_value := 7000 + i
		var first := "a" if i % 2 == 0 else "b"

		var live := GameState.new("a", "b", deck_a, deck_b, seed_value)
		live.record_commands = true
		live.start_game(first)
		for _t in TURN_CAP * 2:
			if live.current_phase == GameState.Phase.GAME_OVER:
				break
			HeadlessTurn.play_full_turn_greedy(live, live.active_player_id)
		if live.current_phase == GameState.Phase.GAME_OVER:
			finished += 1
		total_commands += live.command_log.size()

		var problem := _replay_matches(live, deck_a, deck_b, seed_value, first)
		if not problem.is_empty():
			failures += 1
			print("  FAIL  match %d (seed %d): %s" % [i, seed_value, problem])
	print("PARITY: %d matches, %d finished, %d commands replayed, %d failed" % [matches, finished, total_commands, failures])
	print("RESULT: %s" % ("PASS" if failures == 0 else "FAIL"))
	return failures

## Returns "" when the replay reproduces the live match exactly, else why not.
static func _replay_matches(live: GameState, deck_a: Array[CardData], deck_b: Array[CardData], seed_value: int, first: String) -> String:
	var replay := GameState.new("a", "b", deck_a, deck_b, seed_value)
	replay.start_game(first)
	var step := 0
	for entry in live.command_log:
		step += 1
		var result := replay.execute(entry["cmd"])
		if not result["ok"]:
			return "step %d (%s) was refused on replay: %s" % [step, entry["cmd"].get("type", "?"), result.get("error", "")]
		if replay.state_hash() != entry["hash"]:
			return "step %d (%s) diverged: state hashes differ" % [step, entry["cmd"].get("type", "?")]
	if replay.winner_id != live.winner_id:
		return "winner differs (live '%s', replay '%s')" % [live.winner_id, replay.winner_id]
	if replay.state_hash() != live.state_hash():
		return "final state hash differs"
	return ""
