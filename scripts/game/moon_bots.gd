class_name MoonBots
extends RefCounted

static func roster() -> Dictionary:
	var profiles := {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://data/bot_profiles.json"))
	if not parsed is Array:
		return profiles
	for profile in parsed:
		profiles[str(profile["id"])] = profile
	profiles["standard"] = {"id": "standard", "name": "Standard AI", "version": str(AIController.POLICY_VERSION), "level": 10, "style": ""}
	return profiles

static func published_ids() -> Dictionary:
	var ids := {}
	var release = JSON.parse_string(FileAccess.get_file_as_string("res://catalog/public/data/cards.json"))
	if not release is Dictionary:
		return ids
	for card in release.get("cards", []):
		if card.get("collectible", false) and not card.get("isToken", true):
			ids[str(card["id"])] = true
	return ids

static func build_deck(profile: Dictionary, faction: int, allowed: Dictionary) -> Array[CardData]:
	if allowed.is_empty():
		return [] # Never let an unavailable publication filter become unrestricted.
	match str(profile["style"]):
		"random":
			return DeckManager.build_random_faction_deck(faction, allowed)
		"tempo":
			return DeckManager.build_archetype_deck(faction, DeckManager.Archetype.MIDRANGE, allowed)
		"aggro":
			return DeckManager.build_archetype_deck(faction, DeckManager.Archetype.AGGRO, allowed)
		"combo":
			var pool := DeckManager._faction_pool(faction, false, allowed)
			var tribal := DeckManager._archetype_support(pool, DeckManager.Archetype.TRIBAL)
			var value := DeckManager._archetype_support(pool, DeckManager.Archetype.VALUE)
			var archetype: int = DeckManager.Archetype.TRIBAL if tribal >= value else DeckManager.Archetype.VALUE
			return DeckManager.build_archetype_deck(faction, archetype, allowed)
	return DeckManager.build_archetype_deck(faction, -1, allowed)

static func choose_action(gs: GameState, engine: MCTSEngine, profile: Dictionary, policy_rng: RandomNumberGenerator) -> Dictionary:
	if str(profile["id"]) == "standard":
		return await engine.choose_action(gs)
	var actions := HeadlessTurn.list_legal_actions(gs, gs.active_player_id)
	if str(profile["style"]) == "random":
		# Ganymede sometimes throws away a whole turn, even with good plays available.
		if policy_rng.randf() < 0.35:
			return {"type": "end_turn", "actor": gs.active_player_id}
		return actions[policy_rng.randi_range(0, actions.size() - 1)]
	# Style cannot trump an immediate win. Use the same rules to prove the win.
	for action in actions:
		if action["type"] == "end_turn":
			continue
		var after := gs.duplicate_for_sim()
		if HeadlessTurn.apply_action(after, action) and after.current_phase == GameState.Phase.GAME_OVER and after.winner_id == gs.active_player_id:
			return action
	return await engine.choose_action(gs)

static func play(a: Dictionary, b: Dictionary, faction_a: int, faction_b: int, first: String, game_seed: int) -> Dictionary:
	var allowed := published_ids()
	# One draft per profile/faction/release makes exact-deck samples accumulate.
	# Gameplay/search seeds still change on every match.
	seed(str(a["id"]).hash() + str(a["version"]).hash() + faction_a)
	var deck_a := build_deck(a, faction_a, allowed)
	seed(str(b["id"]).hash() + str(b["version"]).hash() + faction_b)
	var deck_b := build_deck(b, faction_b, allowed)
	if deck_a.size() != DeckManager.MAX_DECK_SIZE or deck_b.size() != DeckManager.MAX_DECK_SIZE:
		return {}
	var result := {"a": a.duplicate(true), "b": b.duplicate(true), "factionA": faction_a, "factionB": faction_b,
		"deckA": deck_a.map(func(c): return c.id), "deckB": deck_b.map(func(c): return c.id),
		"first": first, "seed": game_seed, "rulesVersion": RulesVersion.RULES_VERSION, "engineVersion": AIController.POLICY_VERSION}
	var gs := GameState.new("a", "b", deck_a, deck_b, game_seed)
	gs.start_game(first)
	for p in [gs.player, gs.opponent]:
		gs.mulligan_swap(p.player_id, AIHeuristics.pick_mulligan_swaps(p.hand))
	HeadlessTurn._resolve_pending(gs)
	var policy_rng := RandomNumberGenerator.new()
	policy_rng.seed = game_seed + 123
	var start := Time.get_ticks_msec()
	for _turn in 240:
		if gs.current_phase == GameState.Phase.GAME_OVER:
			result["winner"] = gs.winner_id if not gs.winner_id.is_empty() else "draw"
			result["turns"] = gs.turn_number
			return result
		var actor := gs.active_player_id
		var profile := a if actor == "a" else b
		var engine := MCTSEngine.new(actor, int(profile["level"]), str(profile["style"]))
		engine._search_rng.seed = policy_rng.randi()
		var ended := false
		for _action in 100:
			if Time.get_ticks_msec() - start > 600000:
				return {}
			var action := await choose_action(gs, engine, profile, policy_rng)
			if not HeadlessTurn.apply_action(gs, action) or gs.has_pending_choice() or gs.has_pending():
				return {}
			engine.advance_after_real_action(gs)
			if gs.current_phase == GameState.Phase.GAME_OVER or gs.active_player_id != actor:
				ended = true
				break
		if not ended:
			return {} # An action cap is a failed attempt, never a fabricated draw.
	return {}

static func run_cli(tree: SceneTree) -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bot-") and arg.contains("="):
			var pair := arg.substr(6).split("=", true, 1)
			args[pair[0]] = pair[1]
	var profiles := roster()
	var a_id := str(args.get("a", ""))
	var b_id := str(args.get("b", ""))
	var first := str(args.get("first", "a"))
	var fa := int(args.get("faction-a", -1))
	var fb := int(args.get("faction-b", -1))
	var game_seed := int(args.get("seed", -1))
	var output := str(args.get("result", ""))
	if not profiles.has(a_id) or not profiles.has(b_id) or first not in ["a", "b"] or fa < 0 or fa > 4 or fb < 0 or fb > 4 or game_seed < 0 or output.is_empty():
		push_error("Invalid bot match arguments")
		tree.quit(1)
		return
	var result := await play(profiles[a_id], profiles[b_id], fa, fb, first, game_seed)
	if result.is_empty():
		push_error("Bot match did not complete")
		tree.quit(1)
		return
	var file := FileAccess.open(output + ".tmp", FileAccess.WRITE)
	if file == null:
		tree.quit(1)
		return
	file.store_string(JSON.stringify(result))
	file.close()
	if DirAccess.rename_absolute(output + ".tmp", output) != OK:
		tree.quit(1)
		return
	print("BOT MATCH COMPLETE: %s vs %s, winner=%s, turns=%s" % [a_id, b_id, result["winner"], result["turns"]])
	tree.quit(0)
