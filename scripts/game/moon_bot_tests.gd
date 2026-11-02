extends RefCounted

const Bots = preload("res://scripts/game/moon_bots.gd")
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
	for id in ["io", "callisto", "europa"]:
		var profile: Dictionary = profiles[id]
		var action := await Bots.choose_action(gs, MCTSEngine.new("a", int(profile["level"]), str(profile["style"])), profile, rng)
		var after := gs.duplicate_for_sim()
		HeadlessTurn.apply_action(after, action)
		check("%s takes an immediate win despite style" % id, after.winner_id == "a")
	var missed := 0
	var legal_mistakes := true
	for i in 40:
		rng.seed = i
		var action := await Bots.choose_action(gs, MCTSEngine.new("a", 1), profiles["ganymede"], rng)
		legal_mistakes = legal_mistakes and bool(gs.validate(action)["ok"])
		if action["type"] == "end_turn":
			missed += 1
	check("Ganymede's mistakes remain legal", legal_mistakes)
	check("Ganymede frequently passes up a visible win", missed >= 8)
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
	print("MOON BOT TESTS: %s failed" % failures)
	return failures
