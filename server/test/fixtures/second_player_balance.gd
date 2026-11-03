extends Node
const Experiment = preload("res://server/test/fixtures/second_player_variant.gd")
const Bots = preload("res://scripts/game/moon_bots.gd")
const MAX_GAME_MS := 600000
var failures: Array[String] = []
var checks := 0

func _ready() -> void:
	Net.set_process(false)
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		print("FAIL ", message)

func end_turn(gs: GameState) -> void:
	check(bool(gs.execute({"type": "end_turn", "actor": gs.active_player_id})["ok"]), "turn command accepted")

func rule_checks() -> void:
	seed(73)
	var deck := DeckManager.build_archetype_deck(0, DeckManager.Archetype.MIDRANGE, Bots.published_ids())
	for first in ["host", "guest"]:
		var baseline := GameState.new("host", "guest", deck, deck, 73)
		var variant := Experiment.new("host", "guest", deck, deck, 73)
		var second := variant.opponent if first == "host" else variant.player
		var original_deck := second.deck.duplicate()
		var fourth := second.deck[second.deck.size() - 4]
		baseline.start_game(first)
		variant.start_game(first)
		var control_second := baseline.opponent if first == "host" else baseline.player
		check(control_second.hand.size() == 4 and baseline._get_active_player().hand.size() == 3, "control opening is 3/4")
		check(variant.player.hand.size() == 3 and variant.opponent.hand.size() == 3, "experiment opening is 3/3")
		check(second.deck.size() == 37 and second.deck.back() == fourth and second.deck.back().uid.is_empty(), "fourth definition remains atop deck")
		check(second.deck.map(func(c): return c.id) == original_deck.slice(0, 37).map(func(c): return c.id), "entire undrawn deck order is preserved")
		check(second._next_card_uid == 3 and baseline.rng.state == variant.rng.state, "undraw preserves UID allocator and gameplay RNG")
		var base_copy := baseline.duplicate_for_sim()
		check(base_copy.get_script() == baseline.get_script() and base_copy.state_hash() == baseline.state_hash(), "ordinary clone retains baseline state")
		end_turn(variant) # Second player's first turn.
		check(second.max_mana == 2 and second.hand.size() == 3, "second opens at 2 mana without a first-turn draw")
		var before := variant.state_hash()
		var copy = variant.duplicate_for_sim().duplicate_for_sim()
		check(copy.get_script() == variant.get_script() and copy.state_hash() == before, "nested search copies retain experiment state")
		end_turn(copy)
		end_turn(copy) # Second player's second turn.
		var copied_second: PlayerState = copy._get_player_by_id(second.player_id)
		check(copied_second.max_mana == 2 and copied_second.current_mana == 0, "search clone preserves skipped second crystal and refresh")
		check(copied_second.hand.back().id == fourth.id and copied_second.hand.back().uid == second.player_id + "-c4", "next ordinary draw uses the restored fourth card and UID")
		var three := CardDatabase.get_card("gen_009").new_instance(copied_second.mint_card_uid())
		copied_second.hand.append(three)
		check(not bool(copy.validate({"type": "play_creature", "actor": second.player_id, "card_uid": three.uid})["ok"]), "third mana is unavailable on second own turn")
		check(variant.state_hash() == before and second.hand.size() == 3, "simulation leaves real state unchanged")
		var curves := {"host": [], "guest": []}
		# A fresh position crosses real end-turn transitions for both curves.
		var curve := Experiment.new("host", "guest", deck, deck, 73)
		curve.start_game(first)
		for _turn in 8:
			curves[curve.active_player_id].append(curve._get_active_player().max_mana)
			end_turn(curve)
		check(curves[first] == [1, 2, 3, 4] and curves[second.player_id] == [2, 2, 3, 4], "actual own-turn mana curves are 1/2/3/4 and 2/2/3/4")
		variant.request_choice(second.player_id, GameState.CHOICE_DAMAGE_TARGET, 1, null)
		var choice_before := variant.state_hash()
		var choice_copy := variant.duplicate_for_sim()
		var answers := HeadlessTurn.list_legal_actions(choice_copy, second.player_id)
		check(not answers.is_empty() and HeadlessTurn.apply_action(choice_copy, answers[0], false) and not choice_copy.has_pending_choice(), "experimental search copy resolves a real pending choice")
		check(variant.has_pending_choice() and variant.state_hash() == choice_before, "choice resolution leaves original experiment unchanged")
		var buyer := choice_copy._get_player_by_id(second.player_id)
		var two := CardDatabase.get_card("gen_011").new_instance(buyer.mint_card_uid())
		buyer.hand.append(two)
		check(bool(choice_copy.execute({"type": "play_creature", "actor": second.player_id, "card_uid": two.uid})["ok"]) and buyer.current_mana == 2, "two-mana opening budget pays for a real two-cost creature")

func play_game(decks: Array, game_seed: int, first: String, experimental: bool, level: int, max_actions: int) -> Dictionary:
	var gs: GameState = Experiment.new("host", "guest", decks[0], decks[1], game_seed) if experimental else GameState.new("host", "guest", decks[0], decks[1], game_seed)
	gs.start_game(first)
	var hands := {"first": gs._get_active_player().hand.size(), "second": gs._get_player_by_id("guest" if first == "host" else "host").hand.size()}
	for p in [gs.player, gs.opponent]:
		gs.mulligan_swap(p.player_id, AIHeuristics.pick_mulligan_swaps(p.hand))
	var engines := {"host": MCTSEngine.new("host", level), "guest": MCTSEngine.new("guest", level)}
	engines["host"]._search_rng.seed = game_seed + 101
	engines["guest"]._search_rng.seed = game_seed + 202
	var actions := 0
	var started := Time.get_ticks_msec()
	while gs.current_phase != GameState.Phase.GAME_OVER:
		if actions >= max_actions or gs.turn_number > 240 or Time.get_ticks_msec() - started > MAX_GAME_MS:
			return {"completed": false, "failure": "game_cap", "actions": actions, "turns": gs.turn_number, "openingHands": hands}
		var actor := str(gs.pending_choice["player_id"]) if gs.has_pending_choice() else gs.active_player_id
		var engine: MCTSEngine = engines[actor]
		var command := await engine.choose_action(gs)
		if not HeadlessTurn.apply_action(gs, command, false):
			return {"completed": false, "failure": "rejected_command", "actions": actions, "turns": gs.turn_number, "openingHands": hands}
		engine.advance_after_real_action(gs)
		actions += 1
	return {"completed": true, "winner": gs.winner_id, "firstWon": gs.winner_id == first,
		"draw": gs.winner_id.is_empty(), "actions": actions, "turns": gs.turn_number, "elapsedMs": Time.get_ticks_msec() - started, "openingHands": hands}

func _run() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--balance-"):
			var pair := arg.substr(10).split("=", true, 1)
			args[pair[0]] = pair[1] if pair.size() == 2 else "1"
	var output := str(args.get("output", ""))
	if output.is_empty():
		get_tree().quit(1)
		return
	var pairs := int(args.get("pairs", 25))
	var level := int(args.get("level", 5))
	var initial_seed := int(args.get("seed", 42))
	var only_checks := args.has("checks-only")
	rule_checks()
	var report := {"schemaVersion": 1, "experiment": "second_player_2_mana_3_cards", "rulesVersion": RulesVersion.RULES_VERSION,
		"aiVersion": AIController.POLICY_VERSION, "policy": "equal_level_full_state_mcts", "level": level, "seed": initial_seed,
		"requestedGames": 0 if only_checks else pairs * 4, "checks": checks, "failures": failures, "games": [], "blocks": [], "summary": {}}
	for name in ["baseline", "experiment"]:
		report["summary"][name] = {"completed": 0, "firstWins": 0, "secondWins": 0, "draws": 0}
	if failures.is_empty() and not only_checks:
		var allowed := Bots.published_ids()
		for block in pairs:
			var fa := block % 5
			var fb := (fa + int(block / 5)) % 5
			var game_seed := (initial_seed + block * 7919) % 2147483000
			seed(game_seed + 11)
			var a := DeckManager.build_archetype_deck(fa, -1, allowed)
			seed(game_seed + 22)
			var b := DeckManager.build_archetype_deck(fb, -1, allowed)
			if a.size() != 40 or b.size() != 40:
				failures.append("draft failed")
				break
			var score := {"block": block, "baselineFirstWins": 0, "experimentFirstWins": 0}
			var conditions := ["baseline", "experiment"] if block % 2 == 0 else ["experiment", "baseline"]
			for condition in conditions:
				for first in ["host", "guest"]:
					var result := await play_game([a, b], game_seed, first, condition == "experiment", level, int(args.get("max-actions", 1000)))
					result.merge({"block": block, "condition": condition, "first": first, "seed": game_seed, "factionA": fa, "factionB": fb,
						"deckA": a.map(func(c): return c.id), "deckB": b.map(func(c): return c.id)})
					report["games"].append(result)
					print("BALANCE_PROGRESS %d/%d %s first=%s completed=%s" % [report["games"].size(), pairs * 4, condition, first, result["completed"]])
					if not result["completed"]:
						failures.append(str(result["failure"]))
						break
					var tally: Dictionary = report["summary"][condition]
					tally["completed"] += 1
					if result["draw"]:
						tally["draws"] += 1
					elif result["firstWon"]:
						tally["firstWins"] += 1
						score[condition + "FirstWins"] += 1
					else:
						tally["secondWins"] += 1
				if not failures.is_empty():
					break
			if not failures.is_empty():
				break
			score["firstWinDelta"] = score["experimentFirstWins"] - score["baselineFirstWins"]
			report["blocks"].append(score)
	for tally in report["summary"].values():
		var decisive := int(tally["firstWins"]) + int(tally["secondWins"])
		tally["firstWinRate"] = float(tally["firstWins"]) / decisive if decisive > 0 else null
	report["checks"] = checks
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		get_tree().quit(1)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("BALANCE_RESULT ", JSON.stringify(report["summary"]))
	get_tree().quit(0 if failures.is_empty() else 1)
