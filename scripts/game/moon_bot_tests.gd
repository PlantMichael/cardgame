extends RefCounted

const Bots = preload("res://scripts/game/moon_bots.gd")
const RankedClient = preload("res://scripts/game/ranked_bots_client.gd")
class LocalDriver:
	extends "res://scripts/game/ranked_bots_client.gd"
	var sent: Array[Dictionary] = []
	func _send(_c: BotConnection, message: Dictionary) -> void:
		sent.append(message)
static var failures := 0

static func check(label: String, value: bool) -> void:
	print("%s %s" % ["PASS" if value else "FAIL", label])
	if not value:
		failures += 1

static func position() -> GameState:
	var empty: Array[CardData] = []
	var gs := GameState.new("a", "b", empty, empty, 17)
	gs.start_game("a")
	gs.player.hero_health = 30
	gs.opponent.hero_health = 30
	return gs

static func body(gs: GameState, owner: String, attack: int, hp: int, tags: Array[String] = []) -> Minion:
	var card := CardData.new()
	card.id = "scenario"
	card.attack = attack
	card.health = hp
	card.abilities = tags
	var p := gs.find_player(owner)
	var m := Minion.new(card.new_instance(p.mint_card_uid()), owner)
	m.is_exhausted = false
	p.place_minion(m)
	return m

static func opening_state(first: String) -> GameState:
	var cards: Array[CardData] = []
	for _i in 20: cards.append(CardDatabase.get_card("gen_013"))
	var gs := GameState.new("host", "guest", cards, cards, 77)
	gs.start_game(first)
	gs.begin_mulligan(true)
	return gs

static func test_opening(profiles: Dictionary) -> void:
	for first in ["host", "guest"]:
		var second := "guest" if first == "host" else "host"
		for id in ["io", "callisto", "europa", "ganymede"]:
			var gs := opening_state(first)
			var before := gs.state_hash()
			var waiting := await Bots.choose_view_action(gs.to_net_dict(first), first, [], profiles[id])
			check("%s waits before opponent opening" % id, waiting.is_empty() and gs.state_hash() == before)
			var command := await Bots.choose_view_action(gs.to_net_dict(second), second, [], profiles[id])
			command["actor"] = second
			check("%s answers opening before mulligan" % id, command.get("type") == "answer_choice" and gs.execute(command)["ok"])
			check("%s can select Coin from its known hand" % id, gs.opening_bonus["selection"] == "coin")
			for pid in [first, second]:
				var mulligan := await Bots.choose_view_action(gs.to_net_dict(pid), pid, [], profiles[id])
				mulligan["actor"] = pid
				check("%s submits valid mulligan afterward" % id, mulligan.get("type") == "mulligan" and gs.execute(mulligan)["ok"])
		var driver := LocalDriver.new()
		var local := RankedClient.BotConnection.new()
		local.profile = profiles["io"]
		local.stage = "ai_playing"
		local.ai_state = opening_state(first)
		local.ai_started = Time.get_ticks_msec()
		local.ai_level = 3
		for _i in 3: await driver._ai_step(local)
		check("Local bot/Standard AI opening finishes in either orientation", not local.ai_state.opening_choice_pending() and local.ai_state.mulligan_pending.is_empty() and local.stage == "ai_playing" and driver.sent.is_empty())
		var network := RankedClient.BotConnection.new()
		network.profile = profiles["io"]
		network.stage = "playing"
		network.my_id = first
		network.view = opening_state(first).to_net_dict(first)
		await driver._think(network)
		check("Network first seat sends no premature mulligan", driver.sent.is_empty())
		network.my_id = second
		network.view = opening_state(first).to_net_dict(second)
		await driver._think(network)
		check("Network second seat sends opening answer", driver.sent.size() == 1 and driver.sent[0]["cmd"]["type"] == "answer_choice")
		driver.free()
	# Real filtered policy can use the generated Coin, not just choose its option.
	var lethal := opening_state("guest")
	lethal.execute({"type": "answer_choice", "actor": "host", "choice_id": "choice-1", "selection": "coin"})
	for pid in ["host", "guest"]: lethal.execute({"type": "mulligan", "actor": pid, "card_uids": []})
	lethal.execute({"type": "end_turn", "actor": "guest"})
	lethal.opponent.hero_health = 3
	# Keep the real generated Coin, replacing only the unrelated hand fixture.
	var coin: CardData = lethal.player.hand.back()
	lethal.player.hand = [coin, CardDatabase.get_card("cr_016").new_instance(lethal.player.mint_card_uid())]
	var types := []
	for _i in 3:
		var command := await Bots.choose_view_action(lethal.to_net_dict("host"), "host", [], profiles["io"])
		command["actor"] = "host"
		types.append(command.get("type"))
		check("Filtered Moon bot executes its Coin sequence", lethal.execute(command)["ok"])
	check("Io converts Coin into Rush lethal", types == ["play_stratagem", "play_creature", "attack"] and lethal.winner_id == "host")

static func run() -> int:
	failures = 0
	var profiles := Bots.roster()
	var allowed := Bots.published_ids()
	# Actual production drafting: full public decks across every profile/faction.
	var means := {"io": 0.0, "europa": 0.0}
	for profile in profiles.values():
		for faction in 5:
			seed(91 + faction)
			var deck := Bots.build_deck(profile, faction, allowed)
			var copies := {}
			var valid := deck.size() == 40
			for card in deck:
				copies[card.id] = int(copies.get(card.id, 0)) + 1
				valid = valid and allowed.has(card.id) and not card.is_token and (card.color == faction or card.color == CardData.CardColor.GENERIC)
				valid = valid and copies[card.id] <= DeckManager.max_copies_for(card)
				if means.has(profile["id"]):
					means[profile["id"]] += card.cost
			check("%s faction %s drafts a full legal published deck" % [profile["name"], faction], valid)
	check("Europa drafts a lower curve than Io", means["europa"] < means["io"])
	check("Unavailable publication fails closed", Bots.build_deck(profiles["io"], 0, {}).is_empty())

	var gs := position()
	var attacker := body(gs, "a", 4, 5)
	var target := body(gs, "b", 2, 2)
	var face := {"type": "attack", "actor": "a", "attacker_instance_id": attacker.instance_id, "target_instance_id": "", "target_player_id": "b"}
	var trade := {"type": "attack", "actor": "a", "attacker_instance_id": attacker.instance_id, "target_instance_id": target.instance_id, "target_player_id": ""}
	var face_state := gs.duplicate_for_sim()
	var trade_state := gs.duplicate_for_sim()
	check("Scenario face action is accepted", HeadlessTurn.apply_action(face_state, face))
	check("Scenario trade action is accepted", HeadlessTurn.apply_action(trade_state, trade))
	check("Io prefers tempo trade", AIHeuristics.evaluate_state(trade_state, "a", "tempo") > AIHeuristics.evaluate_state(face_state, "a", "tempo"))
	check("Europa prefers face pressure", AIHeuristics.evaluate_state(face_state, "a", "aggro") > AIHeuristics.evaluate_state(trade_state, "a", "aggro"))
	var rng := RandomNumberGenerator.new()
	rng.seed = 88
	for id in ["io", "europa"]:
		var profile: Dictionary = profiles[id]
		var engine := MCTSEngine.new("a", int(profile["level"]), str(profile["style"]))
		engine._search_rng.seed = 41
		var action := await Bots.choose_action(gs, engine, profile, rng)
		print("DECISION %s: %s" % [id, action])
		check("%s chooses a legal action" % id, bool(gs.validate(action)["ok"]))
		check("%s follows its trade/face preference in search" % id, action.get("target_instance_id", "") == target.instance_id if id == "io" else action.get("target_player_id", "") == "b")

	var combo := position()
	var enabler := body(combo, "a", 1, 2, ["on_play_buff_friendly_health"])
	var payoff := body(combo, "a", 1, 2, [Abilities.HEAL_TO_DRAW])
	var disconnected := combo.duplicate_for_sim()
	disconnected.find_minion(payoff.instance_id).abilities.clear()
	var neutral_delta := AIHeuristics.evaluate_state(combo, "a") - AIHeuristics.evaluate_state(disconnected, "a")
	var combo_delta := AIHeuristics.evaluate_state(combo, "a", "combo") - AIHeuristics.evaluate_state(disconnected, "a", "combo")
	check("Callisto values a health-gain/draw combo above disconnected bodies", combo_delta > neutral_delta + 8)
	# Holding a supporting piece has value, but playing it to activate the pair has more.
	var held := combo.duplicate_for_sim()
	var held_body := held.find_minion(enabler.instance_id)
	held.player.board.erase(held_body)
	held.player.hand.append(held_body.data)
	check("Callisto rewards activating rather than endlessly hoarding combo pieces", AIHeuristics.evaluate_state(combo, "a", "combo") > AIHeuristics.evaluate_state(held, "a", "combo"))
	var setup := position()
	setup.player.current_mana = 0 # The game's current_mana field counts spent mana.
	setup.player.max_mana = 3
	var draw_engine := body(setup, "a", 1, 2, [Abilities.HEAL_TO_DRAW])
	draw_engine.is_exhausted = true
	var support := CardData.new()
	support.id = "support"
	support.cost = 3
	support.attack = 1
	support.health = 1
	support.abilities = ["on_play_buff_friendly_health"]
	var stats_card := CardData.new()
	stats_card.id = "stats"
	stats_card.cost = 3
	stats_card.attack = 3
	stats_card.health = 3
	setup.player.hand = [support.new_instance(setup.player.mint_card_uid()), stats_card.new_instance(setup.player.mint_card_uid())]
	for _i in 12:
		setup.player.deck.append(CardDatabase.get_card("g_001"))
		setup.opponent.deck.append(CardDatabase.get_card("cr_002"))
	var combo_engine := MCTSEngine.new("a", 8, "combo")
	combo_engine._search_rng.seed = 31
	var combo_action := await Bots.choose_action(setup, combo_engine, profiles["callisto"], rng)
	print("DECISION callisto: %s" % combo_action)
	check("Callisto chooses the supporting combo play over raw stats", combo_action.get("card_uid", "") == setup.player.hand[0].uid)

	gs.opponent.hero_health = 4
	for id in ["io", "callisto", "europa", "ganymede"]:
		var profile: Dictionary = profiles[id]
		var action := await Bots.choose_action(gs, MCTSEngine.new("a", int(profile["level"]), str(profile["style"])), profile, rng)
		var after := gs.duplicate_for_sim()
		HeadlessTurn.apply_action(after, action)
		check("%s takes an immediate win despite style" % id, after.winner_id == "a")
	var missed := 0
	var legal_mistakes := true
	var legacy := {"id": "ganymede", "name": "Ganymede", "version": "1.0", "level": 1, "style": "random"}
	for i in 40:
		rng.seed = i
		var action := await Bots.choose_action(gs, MCTSEngine.new("a", 1), legacy, rng)
		legal_mistakes = legal_mistakes and bool(gs.validate(action)["ok"])
		if action["type"] == "end_turn":
			missed += 1
	check("Legacy Ganymede's mistakes remain legal", legal_mistakes)
	check("Legacy Ganymede frequently passes up a visible win", missed >= 8)

	# Cross the private startup config, normal authentication, deck restore and
	# actual decision path before/after an old match disappears on restart.
	var driver := LocalDriver.new()
	var old_url := OS.get_environment("RANKED_BOT_URL")
	var old_sessions := OS.get_environment("RANKED_BOT_SESSIONS")
	var sessions := []
	for id in ["io", "callisto", "europa", "ganymede"]:
		var account := {"id": id, "token": "a".repeat(64)}
		if id == "ganymede":
			account["active_match"] = {"id": "old_policy", "profile": legacy}
		sessions.append(account)
	OS.set_environment("RANKED_BOT_URL", "ws://127.0.0.1:1")
	OS.set_environment("RANKED_BOT_SESSIONS", JSON.stringify(sessions))
	driver._ready()
	OS.set_environment("RANKED_BOT_URL", old_url)
	OS.set_environment("RANKED_BOT_SESSIONS", old_sessions)
	var upgraded: RankedClient.BotConnection = driver._bots[3]
	driver._receive(upgraded, {"type": "login_result", "success": true, "username": "Ganymede",
		"bot_profile": profiles["ganymede"], "ranked_authoritative": true, "rules_version": RulesVersion.RULES_VERSION,
		"ranked_bot_ai": true, "decks": [{"name": "Moon Bot 1.0", "faction_idx": 1, "card_ids": ["cr_002"]}]}, 0)
	check("Policy upgrade authenticates current profile and rejoins old match with its saved draft",
		driver.sent.back().get("match_id", "") == "old_policy" and upgraded.deck.size() == 1 and upgraded.deck[0].id == "cr_002")
	# Network reconstruction resolves printed card IDs; use a real published body.
	var network_game := position()
	var real_body := Minion.new(CardDatabase.get_card("g_001").new_instance("network-attacker"), "a")
	real_body.is_exhausted = false
	network_game.player.place_minion(real_body)
	network_game.opponent.hero_health = 1
	var old_command := {}
	for i in 20:
		network_game.player.hero_health = 30 - i
		old_command = await Bots.choose_view_action(network_game.to_net_dict("a"), "a", upgraded.deck, legacy)
		if old_command.get("type", "") == "end_turn":
			break
	check("Legacy restart scenario has an intentional passed win", old_command.get("type", "") == "end_turn")
	upgraded.view = network_game.to_net_dict("a")
	upgraded.my_id = "a"
	upgraded.seat = "a"
	upgraded.stage = "playing"
	await driver._think(upgraded)
	check("Restarted old match keeps its snapshotted policy", driver.sent.back().get("cmd", {}) == old_command)
	driver._receive(upgraded, {"type": "match_error", "match_id": "old_policy", "reason": "unknown_match"}, 0)
	driver._draft(upgraded, 0)
	check("Next release saves a fresh versioned archetype draft", driver.sent.back().get("name", "") == "Moon Bot 1.1" and upgraded.deck.size() == 40)
	upgraded.view = network_game.to_net_dict("a")
	upgraded.stage = "playing"
	await driver._think(upgraded)
	var new_command: Dictionary = driver.sent.back().get("cmd", {})
	new_command["actor"] = "a"
	var upgraded_result := network_game.duplicate_for_sim()
	HeadlessTurn.apply_action(upgraded_result, new_command)
	check("Next match uses normal level-four policy and takes the visible win", upgraded_result.winner_id == "a")
	driver.free()
	# Ranked planning is derived from a filtered view, not a privileged game copy.
	var draft := Bots.build_deck(profiles["io"], 0, allowed)
	var foe := Bots.build_deck(profiles["ganymede"], 1, allowed)
	var live := GameState.new("host", "guest", draft, foe, 401)
	live.start_game("host")
	var before := live.state_hash()
	var visible := live.to_net_dict("host")
	var secret := live.duplicate_for_sim()
	var plan := Bots.planning_state(visible, "host", draft, 501)
	check("Ranked beliefs preserve visible hand identities", plan.player.hand.map(func(c): return c.uid) == live.player.hand.map(func(c): return c.uid))
	check("Ranked beliefs use only visible hidden-card counts", plan.opponent.hand.size() == live.opponent.hand.size() and plan.opponent.deck.size() == live.opponent.deck.size())
	var policy_engine := MCTSEngine.new("host", 10, "tempo")
	policy_engine._search_rng.seed = 91
	var real_command := await Bots.choose_action(plan, policy_engine, profiles["io"], rng)
	check("Filtered-view planning leaves authoritative state unchanged", live.state_hash() == before)
	check("Filtered-view policy returns a real legal command", bool(live.execute(real_command)["ok"]))
	# Change hidden cards/order without changing the public observation.
	var hand_count := secret.opponent.hand.size()
	var deck_count := secret.opponent.deck.size()
	secret.opponent.hand.clear()
	secret.opponent.deck.clear()
	for _i in hand_count:
		secret.opponent.hand.append(CardDatabase.get_card("b_009").new_instance("private"))
	for _i in deck_count:
		secret.opponent.deck.append(CardDatabase.get_card("b_009"))
	var other_view := secret.to_net_dict("host")
	check("Different hidden cards produce the same observation", visible == other_view)
	var plan_again := Bots.planning_state(other_view, "host", draft, 501)
	check("Ranked beliefs do not depend on hidden card identities", plan.to_net_dict() == plan_again.to_net_dict())
	driver = LocalDriver.new()
	var capped := RankedClient.BotConnection.new()
	capped.profile = profiles["io"]
	capped.stage = "ai_playing"
	capped.ai_state = live.duplicate_for_sim()
	capped.ai_match_id = "ai_1_2"
	capped.ai_started = Time.get_ticks_msec() - 600001
	await driver._ai_step(capped)
	check("Capped local AI attempt cancels without awarding or advancing rotation", capped.ai_state == null and capped.next_ai and capped.stage == "pause" and driver.sent.size() == 1 and driver.sent[0]["type"] == "ranked_bot_ai_cancel")
	driver.free()
	await test_opening(profiles)
	print("MOON BOT TESTS: %s failed" % failures)
	return failures
