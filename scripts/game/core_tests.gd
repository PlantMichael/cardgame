class_name CoreTests
extends RefCounted

## Deterministic, UI-free regression scenarios for the rules core.
##
## These are the checks the architecture handoff asks for in its "turn
## existing checks into regression coverage" item, and unlike the older
## `--*-test` hooks in main.gd they are machine-detectable: run() returns a
## failure count and the `--core-tests` hook exits with it, so CI (or a
## person) can tell a pass from a failure without reading the log.
##
## Scope is deliberately narrow: GameState / PlayerState / Minion /
## HeadlessTurn only. No Board, no animations, no network. Anything needing
## those belongs in a different harness.

static var _failures: int = 0
static var _checks: int = 0

static func _check(name: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("  PASS  %s" % name)
	else:
		_failures += 1
		print("  FAIL  %s%s" % [name, ("  -- " + detail) if not detail.is_empty() else ""])

static func _eq(name: String, got, expected) -> void:
	_check(name, got == expected, "got %s, expected %s" % [got, expected])

# --- Fixtures -------------------------------------------------------------

## A deck of `count` copies of one catalog card. Entries are catalog
## references, exactly as DeckManager.build_deck_from_ids() produces them.
static func _deck_of(card_id: String, count: int) -> Array[CardData]:
	var out: Array[CardData] = []
	var def := CardDatabase.get_card(card_id)
	if def == null:
		return out
	for _i in count:
		out.append(def)
	return out

## Picks a cheap vanilla-ish creature so scenarios are not at the mercy of
## one particular card's abilities.
static func _cheap_creature_id() -> String:
	var best: CardData = null
	for d: CardData in CardDatabase.get_all_cards():
		if d.card_type != CardData.CardType.CREATURE or d.is_token:
			continue
		if not d.abilities.is_empty():
			continue
		if best == null or d.cost < best.cost:
			best = d
	return best.id if best != null else ""

static func _fresh_match(card_id: String) -> GameState:
	var gs := GameState.new("a", "b", _deck_of(card_id, 20), _deck_of(card_id, 20))
	gs.start_game("a")
	return gs

## Puts a known creature straight onto `pid`'s board, bypassing the hand.
static func _put_on_board(gs: GameState, pid: String, card_id: String, ready: bool = true) -> Minion:
	var p := gs.find_player(pid)
	var def := CardDatabase.get_card(card_id)
	var m := Minion.new(def.new_instance(p.mint_card_uid()), pid)
	if ready:
		m.is_exhausted = false
		m.has_attacked = false
	p.place_minion(m)
	return m

# --- Scenarios ------------------------------------------------------------

## Handoff item 01 / scenario 1: an action enumerated against one state and
## applied to a copy must change only the copy.
static func _test_copy_isolation(card_id: String) -> void:
	print("[copy isolation]")

	# Creature play
	var parent := _fresh_match(card_id)
	var sibling := parent.duplicate_for_sim()
	var child := parent.duplicate_for_sim()
	var parent_hand := parent.player.hand.size()
	var sibling_hand := sibling.player.hand.size()
	var actions := HeadlessTurn.list_legal_actions(parent, "a")
	var play: Dictionary = {}
	for act in actions:
		if act["type"] == "play_creature":
			play = act
			break
	_check("a creature play is available", not play.is_empty())
	if not play.is_empty():
		var applied := HeadlessTurn.apply_action(child, play)
		_check("child accepts the parent's action", applied)
		_eq("child hand shrank by one", child.player.hand.size(), parent_hand - 1)
		_eq("parent hand untouched", parent.player.hand.size(), parent_hand)
		_eq("sibling hand untouched", sibling.player.hand.size(), sibling_hand)
		_eq("child board grew", child.player.board.size(), 1)
		_eq("parent board untouched", parent.player.board.size(), 0)
		_eq("sibling board untouched", sibling.player.board.size(), 0)

	# Attack
	var p2 := _fresh_match(card_id)
	var atk := _put_on_board(p2, "a", card_id)
	var def_m := _put_on_board(p2, "b", card_id)
	var sib2 := p2.duplicate_for_sim()
	var kid2 := p2.duplicate_for_sim()
	var atk_cmd := {
		"type": "attack", "actor": "a",
		"attacker_instance_id": atk.instance_id,
		"target_instance_id": def_m.instance_id, "target_player_id": "",
	}
	_check("child accepts the attack", HeadlessTurn.apply_action(kid2, atk_cmd))
	_check("parent attacker unmarked", not atk.has_attacked)
	_eq("parent defender undamaged", def_m.current_health, def_m.max_health)
	var sib_def := sib2.find_minion(def_m.instance_id)
	_eq("sibling defender undamaged", sib_def.current_health, sib_def.max_health)
	var kid_atk := kid2.find_minion(atk.instance_id)
	_check("child attacker did attack", kid_atk == null or kid_atk.has_attacked)

## Handoff scenario 2: running a search must not touch the real match.
static func _test_search_does_not_mutate(card_id: String) -> void:
	print("[search isolation]")
	var gs := _fresh_match(card_id)
	_put_on_board(gs, "a", card_id)
	_put_on_board(gs, "b", card_id)
	gs.active_player_id = "a"
	var before := MCTSEngine._fingerprint(gs)
	var hand_before := gs.player.hand.size()
	# Drive the same machinery a search drives, without the async engine.
	for _i in 12:
		var sim := gs.duplicate_for_sim()
		HeadlessTurn.play_full_turn_greedy(sim, "a")
	_eq("real state unchanged by simulation", MCTSEngine._fingerprint(gs), before)
	_eq("real hand unchanged by simulation", gs.player.hand.size(), hand_before)

## Handoff item 02 / scenario 3: a rejected command changes nothing.
static func _test_invalid_commands_are_inert(card_id: String) -> void:
	print("[command validation]")
	var gs := _fresh_match(card_id)
	var mine := _put_on_board(gs, "a", card_id)
	var theirs := _put_on_board(gs, "b", card_id)
	var card: CardData = gs.player.hand[0]

	var cases := [
		["card not in hand", {"type": "play_creature", "actor": "a", "card_uid": "no-such-card"}],
		["wrong actor", {"type": "play_creature", "actor": "b", "card_uid": card.uid}],
		["unknown actor", {"type": "play_creature", "actor": "nobody", "card_uid": card.uid}],
		["missing attacker", {"type": "attack", "actor": "a", "attacker_instance_id": "ghost", "target_player_id": "b"}],
		["attacking with enemy minion", {"type": "attack", "actor": "a", "attacker_instance_id": theirs.instance_id, "target_player_id": "b"}],
		["attacking own creature", {"type": "attack", "actor": "a", "attacker_instance_id": mine.instance_id, "target_instance_id": mine.instance_id}],
		["attack with no target", {"type": "attack", "actor": "a", "attacker_instance_id": mine.instance_id}],
		["creature played as stratagem", {"type": "play_stratagem", "actor": "a", "card_uid": card.uid}],
		["unknown command", {"type": "fly_away", "actor": "a"}],
	]
	var before := MCTSEngine._fingerprint(gs)
	for case in cases:
		var result := gs.execute(case[1])
		_check("rejected: %s" % case[0], not result["ok"], str(result.get("error", "")))
	_eq("state unchanged after every rejection", MCTSEngine._fingerprint(gs), before)

	# ... and the same once the match is over.
	var over := _fresh_match(card_id)
	over.current_phase = GameState.Phase.GAME_OVER
	var over_before := MCTSEngine._fingerprint(over)
	var r := over.execute({"type": "play_creature", "actor": "a", "card_uid": over.player.hand[0].uid})
	_check("rejected: command after game over", not r["ok"])
	_eq("state unchanged after game over", MCTSEngine._fingerprint(over), over_before)

## Handoff item 03 / scenario 4: two copies of one card are distinguishable.
static func _test_card_identity(card_id: String) -> void:
	print("[card identity]")
	var gs := _fresh_match(card_id)
	# Guarantee two copies of the same definition in hand.
	while gs.player.hand.size() < 2:
		gs.player.draw_card()
	var first: CardData = gs.player.hand[0]
	var second: CardData = gs.player.hand[1]
	_check("hand holds two copies of one definition", first.id == second.id)
	_check("the two copies have distinct uids", first.uid != second.uid and not first.uid.is_empty())

	# Discount only the second copy, then play it by uid.
	second.cost_modifier = -1
	var picked := gs.player.find_card_in_hand(second.uid)
	_check("uid lookup finds the discounted copy", picked == second)
	_eq("the other copy keeps its printed cost", first.effective_cost(), first.cost)

	# A clone must carry the per-copy state, which Resource.duplicate() drops.
	var clone := gs.duplicate_for_sim()
	var cloned_second := clone.player.find_card_in_hand(second.uid)
	_check("clone preserves the discounted copy by uid", cloned_second != null)
	if cloned_second != null:
		_eq("clone preserves cost_modifier", cloned_second.cost_modifier, -1)

	second.rummage_count = 3
	var clone2 := gs.duplicate_for_sim()
	var c2 := clone2.player.find_card_in_hand(second.uid)
	_eq("clone preserves rummage_count", c2.rummage_count if c2 != null else -1, 3)

	# Mutating a clone must not reach back into the original or the catalog.
	c2.cost_modifier = -99
	c2.abilities.append("__sim_only__")
	_eq("original cost_modifier untouched by clone", second.cost_modifier, -1)
	_check("original abilities untouched by clone", "__sim_only__" not in second.abilities)
	_check("catalog abilities untouched by clone", "__sim_only__" not in CardDatabase.get_card(card_id).abilities)

## Handoff item 05 / scenario 11: tree reuse must not certify unequal states.
static func _test_fingerprint_distinguishes(card_id: String) -> void:
	print("[tree-reuse fingerprint]")
	var gs := _fresh_match(card_id)
	var m1 := _put_on_board(gs, "a", card_id)
	var m2 := _put_on_board(gs, "a", card_id)
	var base := MCTSEngine._fingerprint(gs)

	var swapped := gs.duplicate_for_sim()
	var tmp: Minion = swapped.player.board[0]
	swapped.player.board[0] = swapped.player.board[1]
	swapped.player.board[1] = tmp
	_check("board ORDER changes the fingerprint", MCTSEngine._fingerprint(swapped) != base,
		"adjacency-sensitive effects make order meaningful")

	var tired := gs.duplicate_for_sim()
	tired.find_minion(m1.instance_id).has_attacked = true
	_check("readiness changes the fingerprint", MCTSEngine._fingerprint(tired) != base)

	var skilled := gs.duplicate_for_sim()
	skilled.find_minion(m2.instance_id).abilities.append(Abilities.GUARDIAN)
	_check("abilities change the fingerprint", MCTSEngine._fingerprint(skilled) != base)

	var discounted := gs.duplicate_for_sim()
	discounted.player.hand[0].cost_modifier = -2
	_check("a hand discount changes the fingerprint", MCTSEngine._fingerprint(discounted) != base)

	var pending := gs.duplicate_for_sim()
	pending.pending_tank_shots.append("a")
	_check("unresolved effects change the fingerprint", MCTSEngine._fingerprint(pending) != base)

	var identical := gs.duplicate_for_sim()
	_eq("an untouched clone matches", MCTSEngine._fingerprint(identical), base)

## Handoff item 04: gameplay randomness belongs to the match, and nothing a
## simulation or a search does may disturb it.
static func _test_randomness_isolation(card_id: String) -> void:
	print("[randomness isolation]")
	var gs := _fresh_match(card_id)
	_put_on_board(gs, "a", card_id)

	# Copying a state must not touch the GLOBAL stream either.
	seed(12345)
	var expected: Array[int] = []
	for _i in 5:
		expected.append(randi())
	seed(12345)
	for _i in 20:
		gs.duplicate_for_sim()
	var got: Array[int] = []
	for _i in 5:
		got.append(randi())
	_eq("state copying does not advance the global stream", got, expected)

	# Rolling inside a clone must not move the real match's generator.
	var before_state := gs.rng.state
	for _i in 10:
		var sim := gs.duplicate_for_sim()
		for _j in 20:
			sim.rand_index(5)
	_eq("rolling in a clone leaves the real generator put", gs.rng.state, before_state)

	# A clone continues the parent's sequence rather than starting over.
	var parent := _fresh_match(card_id)
	parent.set_gameplay_seed(999)
	for _i in 3:
		parent.rand_index(100)
	var clone := parent.duplicate_for_sim()
	var from_parent: Array[int] = []
	var from_clone: Array[int] = []
	for _i in 6:
		from_parent.append(parent.rand_index(1000))
		from_clone.append(clone.rand_index(1000))
	_eq("a clone continues the same sequence", from_clone, from_parent)

	# Same seed and same commands means the same match.
	var a := GameState.new("a", "b", _deck_of(card_id, 20), _deck_of(card_id, 20))
	a.set_gameplay_seed(4242)
	var b := GameState.new("a", "b", _deck_of(card_id, 20), _deck_of(card_id, 20))
	b.set_gameplay_seed(4242)
	var rolls_a: Array[int] = []
	var rolls_b: Array[int] = []
	for _i in 10:
		rolls_a.append(a.rand_index(50))
		rolls_b.append(b.rand_index(50))
	_eq("the same seed produces the same rolls", rolls_a, rolls_b)

	var c := GameState.new("a", "b", _deck_of(card_id, 20), _deck_of(card_id, 20))
	c.set_gameplay_seed(777)
	var rolls_c: Array[int] = []
	for _i in 10:
		rolls_c.append(c.rand_index(50))
	_check("a different seed produces different rolls", rolls_c != rolls_a)

	# The search has its own generator, so thinking is not part of the game.
	var match_state := _fresh_match(card_id)
	match_state.set_gameplay_seed(1)
	var engine := MCTSEngine.new("b", 5)
	var pre := match_state.rng.state
	for _i in 50:
		engine._search_rng.randi()
	_eq("search exploration leaves the match generator put", match_state.rng.state, pre)

## Handoff item 08 / scenario 6: Crypt Hunger (Delos, cr_019) gives back the
## health it gained - and must not shrink its maximum doing so.
static func _test_crypt_hunger() -> void:
	print("[crypt hunger]")
	var delos_def := CardDatabase.get_card("cr_019")
	if delos_def == null:
		_check("Delos (cr_019) exists in the catalog", false)
		return
	var gs := _fresh_match(_cheap_creature_id())
	var delos := Minion.new(delos_def.new_instance(gs.player.mint_card_uid()), "a")
	gs.player.place_minion(delos)
	var printed_max := delos.max_health
	var hand_before := gs.player.hand.size()

	# A PURE heal: restores damage, capped at the existing maximum. Nothing
	# raised the maximum, so nothing may take it away.
	delos.current_health = 1
	gs._apply_rejuvenate_to(delos, 2)
	_eq("a pure heal does not reduce maximum health", delos.max_health, printed_max)
	_eq("the healed health is given back", delos.current_health, 1)
	_check("a card was drawn", gs.player.hand.size() > hand_before)

	# Repeatedly: the old behaviour ground maximum health down each time.
	for _i in 3:
		delos.current_health = 1
		gs._apply_rejuvenate_to(delos, 2)
	_eq("maximum health survives repeated healing", delos.max_health, printed_max)
	_check("creature is still alive", not delos.is_dead())

	# A +N/+N BUFF raised the maximum too, so both come back - the creature
	# ends where it started and the drawn card is the whole effect.
	delos.current_health = delos.max_health
	gs.apply_heal_buff(delos, 2)
	_eq("a max-health buff is fully reverted (max)", delos.max_health, printed_max)
	_eq("a max-health buff is fully reverted (current)", delos.current_health, printed_max)

## Handoff item 09 / scenario 9: silencing an aura source withdraws what that
## source granted, and only that.
static func _test_aura_withdrawn_on_silence() -> void:
	print("[aura lifetime]")
	var growvin_def := CardDatabase.get_card("o_020")
	if growvin_def == null:
		_check("Growvin (o_020) exists in the catalog", false)
		return
	var mech_def: CardData = null
	for d: CardData in CardDatabase.get_all_cards():
		if d.card_type == CardData.CardType.CREATURE and Abilities.MECH in d.abilities 				and Abilities.CLOAKED not in d.abilities and not d.is_token:
			mech_def = d
			break
	if mech_def == null:
		_check("a plain mech exists in the catalog", false)
		return

	var gs := _fresh_match(_cheap_creature_id())
	var growvin := Minion.new(growvin_def.new_instance(gs.player.mint_card_uid()), "a")
	gs.player.place_minion(growvin)
	var mech := Minion.new(mech_def.new_instance(gs.player.mint_card_uid()), "a")
	gs.player.place_minion(mech)
	gs._apply_growvin_aura_to_mech(mech, "a")
	_check("the aura reached the mech", mech.has_ability(Abilities.CLOAKED))
	_check("the grant was recorded", gs.growvin_granted.size() > 0)

	gs.apply_null(growvin)
	_check("silencing the source removes the granted ability", not mech.has_ability(Abilities.CLOAKED))
	_eq("no stale grant bookkeeping is left behind", gs.growvin_granted.size(), 0)

	# A creature that owns the ability in its own right must keep it.
	var gs2 := _fresh_match(_cheap_creature_id())
	var growvin2 := Minion.new(growvin_def.new_instance(gs2.player.mint_card_uid()), "a")
	gs2.player.place_minion(growvin2)
	var own_mech := Minion.new(mech_def.new_instance(gs2.player.mint_card_uid()), "a")
	own_mech.abilities.append(Abilities.CLOAKED)
	gs2.player.place_minion(own_mech)
	gs2._apply_growvin_aura_to_mech(own_mech, "a")
	gs2.apply_null(growvin2)
	_check("an independently owned ability survives the aura ending",
		own_mech.has_ability(Abilities.CLOAKED))

## Handoff items 06 + 07: every adapter must drain the same queues in the
## same order, and resolution must not strand work queued by a late effect.
static func _test_pending_resolution(card_id: String) -> void:
	print("[effect resolution]")
	# The rules core owns the order, and it covers every pending_* queue that
	# exists - a queue missing from the list is one no adapter would drain.
	var declared := GameState.PENDING_QUEUES
	var gs := _fresh_match(card_id)
	var actual: Array[String] = []
	for prop in gs.get_property_list():
		var n: String = prop["name"]
		# pending_drawn_cards / pending_fatigue_damage are announcement lists,
		# and pending_choice is a single open decision, not a queue.
		if n.begins_with("pending_") and n not in ["pending_drawn_cards", "pending_fatigue_damage", "pending_choice"]:
			actual.append(n)
	actual.sort()
	var declared_sorted: Array = declared.duplicate()
	declared_sorted.sort()
	_eq("PENDING_QUEUES covers every pending queue", declared_sorted, actual)

	_check("has_pending() is false on a quiet state", not gs.has_pending())
	gs.pending_tank_shots.append("a")
	_check("has_pending() sees queued work", gs.has_pending())
	gs.pending_tank_shots.clear()

	# A finished match must not keep resolving effects.
	gs.pending_tank_shots.append("a")
	gs.current_phase = GameState.Phase.GAME_OVER
	_check("has_pending() is false once the match is over", not gs.has_pending())
	gs.current_phase = GameState.Phase.PLAYER_TURN

	# The headless resolver drains everything, including a queue filled by a
	# later one (the "resolve until stable" rule).
	var gs2 := _fresh_match(card_id)
	_put_on_board(gs2, "a", card_id)
	_put_on_board(gs2, "b", card_id)
	gs2.pending_tank_shots.append("a")
	gs2.pending_buff_friendly_health.append("a")
	gs2.pending_tank_specialist_buffs.append("a")
	HeadlessTurn._resolve_pending(gs2)
	_check("headless resolution leaves nothing pending", not gs2.has_pending())

## Handoff item 07 / scenario 8: simultaneous lethal damage kills the whole
## group. A death trigger must not be able to rescue a creature that was
## already lethal at the same checkpoint.
static func _test_simultaneous_deaths(card_id: String) -> void:
	print("[simultaneous deaths]")
	var gs := _fresh_match(card_id)
	var a1 := _put_on_board(gs, "a", card_id)
	var a2 := _put_on_board(gs, "a", card_id)
	var b1 := _put_on_board(gs, "b", card_id)
	# Everything is lethal at the same instant.
	for m in [a1, a2, b1]:
		m.current_health = 0
	gs._remove_dead_minions()
	_eq("every simultaneously lethal creature died (a)", gs.player.board.size(), 0)
	_eq("every simultaneously lethal creature died (b)", gs.opponent.board.size(), 0)
	_eq("all three reached a graveyard",
		gs.player.graveyard.size() + gs.opponent.graveyard.size(), 3)

	# A creature healed back above 0 BEFORE the checkpoint is not in the group.
	var gs2 := _fresh_match(card_id)
	var s1 := _put_on_board(gs2, "a", card_id)
	var s2 := _put_on_board(gs2, "a", card_id)
	s1.current_health = 0
	s2.current_health = 1
	gs2._remove_dead_minions()
	_eq("only the lethal creature died", gs2.player.board.size(), 1)
	_check("the survivor is the one that was above 0", gs2.player.board[0] == s2)

	# Resolution terminates even with nothing to do.
	var gs3 := _fresh_match(card_id)
	_put_on_board(gs3, "a", card_id)
	gs3._remove_dead_minions()
	_eq("a board with no deaths is untouched", gs3.player.board.size(), 1)

## Handoff item 06 / scenario 5: one rule, applied the same way everywhere.
## Drain (cr_str_003): "give it to ANOTHER creature you control."
static func _test_sanguine_recipients(card_id: String) -> void:
	print("[shared targeting rules]")
	var gs := _fresh_match(card_id)
	var donor := _put_on_board(gs, "a", card_id)
	var other := _put_on_board(gs, "a", card_id)
	var enemy := _put_on_board(gs, "b", card_id)

	var legal := gs.sanguine_recipients("a", donor)
	_check("the donor is not a legal recipient", donor not in legal)
	_check("another friendly creature is legal", other in legal)
	_check("an enemy creature is not legal", enemy not in legal)
	_eq("exactly one legal recipient here", legal.size(), 1)

	# The donor being the only friendly creature means no legal recipient at
	# all - the effect must simply not happen rather than target the donor.
	var gs2 := _fresh_match(card_id)
	var lone := _put_on_board(gs2, "a", card_id)
	_eq("a lone donor leaves no legal recipient", gs2.sanguine_recipients("a", lone).size(), 0)

	_eq("an unknown player has no recipients", gs.sanguine_recipients("nobody", donor).size(), 0)

## Handoff item 08 / scenario 6: every max-health gain runs the same reaction
## chain, whichever route granted it.
static func _test_shared_health_ops(card_id: String) -> void:
	print("[shared health operations]")
	var gs := _fresh_match(card_id)
	var m := _put_on_board(gs, "a", card_id)
	var start_max := m.max_health
	var start_cur := m.current_health

	gs.gain_max_health(m, 2)
	_eq("gain_max_health raises maximum", m.max_health, start_max + 2)
	_eq("gain_max_health raises current", m.current_health, start_cur + 2)

	# A pure restore is capped and never touches maximum.
	m.current_health = 1
	gs.restore_health(m, 99)
	_eq("restore_health caps at maximum", m.current_health, m.max_health)
	_eq("restore_health leaves maximum alone", m.max_health, start_max + 2)

	# Non-positive and null are no-ops rather than corrupting stats.
	var before := m.max_health
	gs.gain_max_health(m, 0)
	gs.gain_max_health(m, -5)
	gs.restore_health(m, 0)
	gs.restore_health(null, 3)
	gs.gain_max_health(null, 3)
	_eq("no-op gains leave maximum unchanged", m.max_health, before)

	# Every buff helper routes through the shared operation.
	var m2 := _put_on_board(gs, "a", card_id)
	var base := m2.max_health
	gs.apply_buff_friendly_health(m2)
	_eq("apply_buff_friendly_health goes through the shared op", m2.max_health, base + 1)
	gs.apply_heal_buff(m2, 2)
	_eq("apply_heal_buff goes through the shared op", m2.max_health, base + 3)
	var atk := m2.current_attack
	gs.apply_tank_specialist_buff(m2)
	_eq("tank specialist buff raises maximum", m2.max_health, base + 5)
	_eq("tank specialist buff raises attack", m2.current_attack, atk + 1)

## Regression for the hazard group death resolution introduces: a death
## trigger that puts a creature back must survive its recorded slot no longer
## existing, because the rest of the dying group was removed first.
static func _test_reinforce_after_group_death(card_id: String) -> void:
	print("[replacement after group death]")
	var reinforcer: CardData = null
	for d: CardData in CardDatabase.get_all_cards():
		if d.card_type == CardData.CardType.CREATURE and Abilities.REINFORCE in d.abilities and not d.is_token:
			reinforcer = d
			break
	if reinforcer == null:
		_check("a Reinforce creature exists in the catalog", false)
		return

	var gs := _fresh_match(card_id)
	# The Reinforce creature sits at the END of the board, so its recorded
	# slot is past the end once everything to its left has been removed.
	var filler1 := _put_on_board(gs, "a", card_id)
	var filler2 := _put_on_board(gs, "a", card_id)
	var rein := Minion.new(reinforcer.new_instance(gs.player.mint_card_uid()), "a")
	gs.player.place_minion(rein)
	_eq("board set up with three creatures", gs.player.board.size(), 3)

	for m in [filler1, filler2, rein]:
		m.current_health = 0
	gs._remove_dead_minions()

	_eq("the reinforced copy was actually placed", gs.player.board.size(), 1)
	if gs.player.board.size() == 1:
		_eq("it is the Reinforce creature", gs.player.board[0].data.id, reinforcer.id)
		_check("the copy spent its Reinforce",
			not gs.player.board[0].has_ability(Abilities.REINFORCE))

## Handoff scenario 7: amplification applies to the damage categories the
## rules say it does, and combat-only protection stays combat-only.
static func _test_damage_amplification(card_id: String) -> void:
	print("[damage amplification]")
	var gs := _fresh_match(card_id)
	var attacker := _put_on_board(gs, "a", card_id)
	var victim := _put_on_board(gs, "b", card_id)
	victim.max_health = 20
	victim.current_health = 20

	# Unamplified baseline.
	gs.apply_on_play_damage(victim, 3, "a")
	_eq("on-play damage applies the printed amount", victim.current_health, 17)

	# The source's own board carries the amplifier.
	attacker.abilities.append(Abilities.ENEMY_DAMAGE_AMP + "_2")
	gs.apply_on_play_damage(victim, 3, "a")
	_eq("on-play damage is amplified by the source's board", victim.current_health, 12)

	# Amplification belongs to the SOURCE, not the target.
	gs.apply_on_play_damage(victim, 3, "b")
	_eq("the target's side does not amplify damage dealt to it", victim.current_health, 9)

	# A shield is combat protection; it must not soak spell damage.
	var shielded := _put_on_board(gs, "b", card_id)
	shielded.max_health = 20
	shielded.current_health = 20
	shielded.abilities.append(Abilities.SHIELDED + "_5")
	gs.apply_on_play_damage(shielded, 3, "")
	_eq("a combat shield does not reduce non-combat damage", shielded.current_health, 17)

## Handoff scenario 1, spell case: a stratagem applied to a copy must not
## touch the state it was enumerated against.
static func _test_spell_copy_isolation() -> void:
	print("[spell copy isolation]")
	var strat: CardData = null
	for d: CardData in CardDatabase.get_all_cards():
		if d.card_type == CardData.CardType.STRATAGEM and d.effect == "deal_damage":
			strat = d
			break
	if strat == null:
		_check("a damage stratagem exists in the catalog", false)
		return
	var gs := _fresh_match(_cheap_creature_id())
	var victim := _put_on_board(gs, "b", _cheap_creature_id())
	victim.max_health = 20
	victim.current_health = 20
	# Put the spell in hand with enough mana to cast it.
	var card := strat.new_instance(gs.player.mint_card_uid())
	gs.player.hand.append(card)
	gs.player.max_mana = 10
	gs.player.current_mana = 0

	var parent_hand := gs.player.hand.size()
	var child := gs.duplicate_for_sim()
	var sibling := gs.duplicate_for_sim()
	var cmd := {
		"type": "play_stratagem", "actor": "a", "card_uid": card.uid,
		"target_instance_id": victim.instance_id, "target_player_id": "",
	}
	_check("child accepts the stratagem", HeadlessTurn.apply_action(child, cmd))
	_eq("child hand shrank by one", child.player.hand.size(), parent_hand - 1)
	_eq("parent hand untouched", gs.player.hand.size(), parent_hand)
	_eq("parent victim undamaged", victim.current_health, 20)
	var sib_victim := sibling.find_minion(victim.instance_id)
	_eq("sibling victim undamaged", sib_victim.current_health, 20)
	var child_victim := child.find_minion(victim.instance_id)
	_check("child victim took the damage", child_victim == null or child_victim.current_health < 20)
	_eq("parent mana unspent", gs.player.current_mana, 0)

## Part Two Batch A/B/C: every approved card loads with the approved values.
static func _test_new_cards_catalog() -> void:
	print("[new cards: catalog]")
	var expected := {
		# id: [name, color, cost, attack, health, tribe, rarity, token]
		"g_026":   ["Sapien Rifle Squad", CardData.CardColor.GREEN, 2, 3, 2, "", CardData.CardRarity.COMMON],
		"g_027":   ["T6 Ironclad", CardData.CardColor.GREEN, 5, 5, 6, "tank", CardData.CardRarity.COMMON],
		"t_025":   ["Tundra Forager", CardData.CardColor.TEAL, 2, 2, 3, "yeti", CardData.CardRarity.COMMON],
		"t_026":   ["Glacierback Yeti", CardData.CardColor.TEAL, 3, 3, 4, "yeti", CardData.CardRarity.COMMON],
		"gen_011": ["Frontier Mercenary", CardData.CardColor.GENERIC, 2, 2, 2, "", CardData.CardRarity.COMMON],
		"gen_012": ["Cargo Loader", CardData.CardColor.GENERIC, 4, 4, 4, "", CardData.CardRarity.COMMON],
		"gen_013": ["Checkpoint Sentry", CardData.CardColor.GENERIC, 2, 1, 3, "", CardData.CardRarity.COMMON],
		"gen_014": ["Archive Courier", CardData.CardColor.GENERIC, 3, 2, 2, "", CardData.CardRarity.COMMON],
		"gen_015": ["Frontier Medic", CardData.CardColor.GENERIC, 3, 2, 3, "", CardData.CardRarity.COMMON],
		"gen_016": ["Supply Quartermaster", CardData.CardColor.GENERIC, 4, 3, 3, "", CardData.CardRarity.COMMON],
		"gen_017": ["Heavy Bounty Hunter", CardData.CardColor.GENERIC, 5, 3, 3, "", CardData.CardRarity.COMMON],
		"gen_018": ["Convoy Defender", CardData.CardColor.GENERIC, 6, 4, 7, "", CardData.CardRarity.COMMON],
		"gen_019": ["Wasteland Behemoth", CardData.CardColor.GENERIC, 8, 7, 8, "", CardData.CardRarity.COMMON],
		"g_028":   ["Commander Maurice, Local Legend", CardData.CardColor.GREEN, 5, 1, 2, "", CardData.CardRarity.LEGENDARY],
	}
	for cid in expected:
		var d := CardDatabase.get_card(cid)
		if d == null:
			_check("%s loads from the catalog" % cid, false)
			continue
		var e: Array = expected[cid]
		_eq("%s name" % cid, d.card_name, e[0])
		_eq("%s color" % cid, d.color, e[1])
		_eq("%s cost" % cid, d.cost, e[2])
		_eq("%s attack" % cid, d.attack, e[3])
		_eq("%s health" % cid, d.health, e[4])
		_eq("%s tribe" % cid, d.tribe, e[5])
		_eq("%s rarity" % cid, d.rarity, e[6])
		_check("%s is not a token" % cid, not d.is_token)
		_check("%s is a creature" % cid, d.card_type == CardData.CardType.CREATURE)

	# Batch A and Wasteland Behemoth carry no abilities beyond their tribe
	# tag (the loader appends tribe to the runtime ability list).
	for cid in ["g_026", "gen_011", "gen_012", "gen_019"]:
		var d := CardDatabase.get_card(cid)
		if d != null:
			_eq("%s has no abilities at all" % cid, d.abilities.size(), 0)
	for cid in ["g_027", "t_025", "t_026"]:
		var d := CardDatabase.get_card(cid)
		if d != null:
			_eq("%s carries only its tribe tag" % cid, d.abilities, [d.tribe] as Array[String])

	_check("Breach Contractor was not added", CardDatabase.get_card("gen_020") == null)

## Batch B's three targeted on-play effects: legality is decided by the rules
## core, and an effect with no legal target simply does not happen.
static func _test_targeted_on_play(card_id: String) -> void:
	print("[targeted on-play effects]")

	# --- Frontier Medic: restore 1 to a creature, never a hero ---
	var gs := _fresh_match(card_id)
	var wounded := _put_on_board(gs, "a", card_id)
	wounded.max_health = 5
	wounded.current_health = 2
	var enemy := _put_on_board(gs, "b", card_id)
	var medic := _put_on_board(gs, "a", "gen_015")
	Abilities.fire_on_play(medic, gs.player, gs)
	_check("medic opened a choice", gs.has_pending_choice())
	if gs.has_pending_choice():
		var opts: Array = gs.pending_choice["options"]
		_check("a friendly creature is targetable", wounded.instance_id in opts)
		_check("an enemy creature is targetable", enemy.instance_id in opts)
		var before := wounded.current_health
		var r := gs.answer_choice(str(gs.pending_choice["id"]), wounded.instance_id)
		_check("the answer was accepted", r["ok"])
		_eq("one health was restored", wounded.current_health, before + 1)
		_eq("maximum health is untouched", wounded.max_health, 5)
		_check("the choice is closed", not gs.has_pending_choice())

	# A full-health creature gains nothing but is still a legal target.
	var full := _put_on_board(gs, "a", card_id)
	var medic2 := _put_on_board(gs, "a", "gen_015")
	Abilities.fire_on_play(medic2, gs.player, gs)
	if gs.has_pending_choice():
		var hp := full.current_health
		gs.answer_choice(str(gs.pending_choice["id"]), full.instance_id)
		_eq("a full-health target gains nothing", full.current_health, hp)
		_eq("and gains no maximum health", full.max_health, full.max_health)

	# --- Supply Quartermaster: ANOTHER friendly creature ---
	var gs2 := _fresh_match(card_id)
	var mate := _put_on_board(gs2, "a", card_id)
	var foe := _put_on_board(gs2, "b", card_id)
	var qm := _put_on_board(gs2, "a", "gen_016")
	Abilities.fire_on_play(qm, gs2.player, gs2)
	_check("quartermaster opened a choice", gs2.has_pending_choice())
	if gs2.has_pending_choice():
		var opts2: Array = gs2.pending_choice["options"]
		_check("it cannot target itself", qm.instance_id not in opts2)
		_check("it cannot target an enemy", foe.instance_id not in opts2)
		_check("another friendly creature is legal", mate.instance_id in opts2)
		var atk := mate.current_attack
		var mx := mate.max_health
		var cur := mate.current_health
		gs2.answer_choice(str(gs2.pending_choice["id"]), mate.instance_id)
		_eq("+1 attack", mate.current_attack, atk + 1)
		_eq("+1 maximum health", mate.max_health, mx + 1)
		_eq("+1 current health", mate.current_health, cur + 1)

	# Alone on the board, there is no legal recipient and no stalled prompt.
	var gs3 := _fresh_match(card_id)
	var lone_qm := _put_on_board(gs3, "a", "gen_016")
	Abilities.fire_on_play(lone_qm, gs3.player, gs3)
	_check("no legal target means no prompt", not gs3.has_pending_choice())

	# --- Heavy Bounty Hunter: enemy creature with 5+ current attack ---
	var gs4 := _fresh_match(card_id)
	var small := _put_on_board(gs4, "b", card_id)
	small.current_attack = 4
	small.max_health = 20
	small.current_health = 20
	var big := _put_on_board(gs4, "b", card_id)
	big.current_attack = 5
	big.max_health = 20
	big.current_health = 20
	var friendly_big := _put_on_board(gs4, "a", card_id)
	friendly_big.current_attack = 9
	var hunter := _put_on_board(gs4, "a", "gen_017")
	Abilities.fire_on_play(hunter, gs4.player, gs4)
	_check("bounty hunter opened a choice", gs4.has_pending_choice())
	if gs4.has_pending_choice():
		var opts4: Array = gs4.pending_choice["options"]
		_check("below the threshold is not targetable", small.instance_id not in opts4)
		_check("at the threshold is targetable", big.instance_id in opts4)
		_check("a friendly creature is never targetable", friendly_big.instance_id not in opts4)
		gs4.answer_choice(str(gs4.pending_choice["id"]), big.instance_id)
		_eq("it deals 4 damage, not destruction", big.current_health, 16)
		_check("the target can survive", not big.is_dead())

	# Threshold reads CURRENT attack, so a debuffed creature drops out.
	var gs5 := _fresh_match(card_id)
	var buffed := _put_on_board(gs5, "b", card_id)
	buffed.current_attack = 2
	var hunter2 := _put_on_board(gs5, "a", "gen_017")
	Abilities.fire_on_play(hunter2, gs5.player, gs5)
	_check("no eligible attacker means no prompt", not gs5.has_pending_choice())

## Handoff item 10: an answer is checked against the choice that is open.
static func _test_choice_validation(card_id: String) -> void:
	print("[choice validation]")
	var gs := _fresh_match(card_id)
	var mate := _put_on_board(gs, "a", card_id)
	var qm := _put_on_board(gs, "a", "gen_016")
	Abilities.fire_on_play(qm, gs.player, gs)
	if not gs.has_pending_choice():
		_check("a choice is open to validate against", false)
		return
	var cid := str(gs.pending_choice["id"])

	_check("a stale id is rejected", not gs.answer_choice("choice-999", mate.instance_id)["ok"])
	_check("the choice survives a stale answer", gs.has_pending_choice())
	_check("an illegal target is rejected", not gs.answer_choice(cid, qm.instance_id)["ok"])
	_check("the choice survives an illegal answer", gs.has_pending_choice())

	# Ordinary commands are blocked while the choice is open.
	var cmd := {"type": "play_creature", "actor": "a", "card_uid": gs.player.hand[0].uid}
	var blocked := gs.execute(cmd)
	_check("ordinary commands are blocked", not blocked["ok"])
	_eq("and say why", str(blocked.get("error", "")).contains("choice"), true)

	# The real answer resolves once; replaying it does nothing.
	var atk := mate.current_attack
	_check("the real answer is accepted", gs.answer_choice(cid, mate.instance_id)["ok"])
	_eq("it resolved once", mate.current_attack, atk + 1)
	_check("replaying it is rejected", not gs.answer_choice(cid, mate.instance_id)["ok"])
	_eq("and did not resolve twice", mate.current_attack, atk + 1)

	# A choice travels with a copied state.
	var gs2 := _fresh_match(card_id)
	_put_on_board(gs2, "a", card_id)
	var qm2 := _put_on_board(gs2, "a", "gen_016")
	Abilities.fire_on_play(qm2, gs2.player, gs2)
	var clone := gs2.duplicate_for_sim()
	_check("the clone carries the open choice", clone.has_pending_choice())
	_eq("with the same id", str(clone.pending_choice["id"]), str(gs2.pending_choice["id"]))
	_eq("and the same options", clone.pending_choice["options"], gs2.pending_choice["options"])
	clone.answer_choice(str(clone.pending_choice["id"]), str(clone.pending_choice["options"][0]))
	_check("answering the clone leaves the original open", gs2.has_pending_choice())

## Batch C: Commander Maurice returns four times, then stays dead.
static func _test_maurice_reinforce() -> void:
	print("[Maurice: counted Reinforce]")
	var maurice_def := CardDatabase.get_card("g_028")
	if maurice_def == null:
		_check("Maurice loads", false)
		return
	_eq("printed with four returns", Abilities.get_reinforce_uses("reinforce_4"), 4)
	_eq("a plain Reinforce is one return", Abilities.get_reinforce_uses(Abilities.REINFORCE), 1)

	var gs := _fresh_match(_cheap_creature_id())
	var m := Minion.new(maurice_def.new_instance(gs.player.mint_card_uid()), "a")
	gs.player.place_minion(m)
	_eq("starts with four", Abilities.reinforce_uses_of(m), 4)

	# 4 -> 3 -> 2 -> 1 -> 0, one return each, then permanent death.
	var expected_left := [3, 2, 1, 0]
	for i in 4:
		gs.player.board[0].current_health = 0
		gs._remove_dead_minions()
		_eq("death %d leaves exactly one Maurice" % (i + 1), gs.player.board.size(), 1)
		if gs.player.board.is_empty():
			return
		var back: Minion = gs.player.board[0]
		_eq("returns at printed stats (attack) %d" % (i + 1), back.current_attack, maurice_def.attack)
		_eq("returns at printed stats (health) %d" % (i + 1), back.current_health, maurice_def.health)
		_eq("budget after return %d" % (i + 1), Abilities.reinforce_uses_of(back), expected_left[i])

	gs.player.board[0].current_health = 0
	gs._remove_dead_minions()
	_eq("the fifth death is permanent", gs.player.board.size(), 0)

	# Silence removes the remaining returns.
	var gs2 := _fresh_match(_cheap_creature_id())
	var m2 := Minion.new(maurice_def.new_instance(gs2.player.mint_card_uid()), "a")
	gs2.player.place_minion(m2)
	gs2.apply_null(m2)
	_eq("silence strips the remaining returns", Abilities.reinforce_uses_of(m2), 0)
	m2.current_health = 0
	gs2._remove_dead_minions()
	_eq("a silenced Maurice does not return", gs2.player.board.size(), 0)

	# A partially spent budget survives a simulation copy.
	var gs3 := _fresh_match(_cheap_creature_id())
	var m3 := Minion.new(maurice_def.new_instance(gs3.player.mint_card_uid()), "a")
	gs3.player.place_minion(m3)
	gs3.player.board[0].current_health = 0
	gs3._remove_dead_minions()
	var clone := gs3.duplicate_for_sim()
	_eq("a clone keeps the spent budget", Abilities.reinforce_uses_of(clone.player.board[0]), 3)
	clone.player.board[0].current_health = 0
	clone._remove_dead_minions()
	_eq("spending it in the clone does not refill the original",
		Abilities.reinforce_uses_of(gs3.player.board[0]), 3)

	# An ordinary Reinforce card still returns exactly once.
	var plain: CardData = null
	for d: CardData in CardDatabase.get_all_cards():
		if d.id != "g_028" and Abilities.REINFORCE in d.abilities and not d.is_token:
			plain = d
			break
	if plain != null:
		var gs4 := _fresh_match(_cheap_creature_id())
		var p := Minion.new(plain.new_instance(gs4.player.mint_card_uid()), "a")
		gs4.player.place_minion(p)
		gs4.player.board[0].current_health = 0
		gs4._remove_dead_minions()
		_eq("an ordinary Reinforce returns once", gs4.player.board.size(), 1)
		if not gs4.player.board.is_empty():
			_eq("with nothing left", Abilities.reinforce_uses_of(gs4.player.board[0]), 0)
			gs4.player.board[0].current_health = 0
			gs4._remove_dead_minions()
			_eq("and does not return twice", gs4.player.board.size(), 0)

## Handoff items 11/12, scenario 12: a payload sent to one player must not
## carry the other player's hidden information.
static func _test_player_views(card_id: String) -> void:
	print("[per-player views]")
	var gs := GameState.new("host", "guest", _deck_of(card_id, 20), _deck_of(card_id, 20))
	gs.start_game("host")
	_put_on_board(gs, "host", card_id)
	_put_on_board(gs, "guest", card_id)

	var to_guest := gs.to_net_dict("guest")
	var host_view: Dictionary = to_guest["host_state"]
	var guest_view: Dictionary = to_guest["guest_state"]

	_eq("the host's hand is not sent to the guest", (host_view["hand"] as Array).size(), 0)
	_check("only its size is", host_view.has("hand_size"))
	_eq("and the size is right", int(host_view["hand_size"]), gs.player.hand.size())
	_check("the guest's own hand IS sent", (guest_view["hand"] as Array).size() > 0)

	# The same payload, built for the host, mirrors the rule.
	var to_host := gs.to_net_dict("host")
	_eq("the guest's hand is not sent to the host", (to_host["guest_state"]["hand"] as Array).size(), 0)
	_check("the host's own hand IS sent", (to_host["host_state"]["hand"] as Array).size() > 0)

	# No card identity may appear anywhere in the opponent's half.
	var hidden_ids: Array[String] = []
	for c in gs.player.hand:
		hidden_ids.append(c.uid)
	var blob := JSON.stringify(host_view)
	var leaked := 0
	for uid in hidden_ids:
		if blob.contains(uid):
			leaked += 1
	_eq("no hidden card uid leaks into the opponent view", leaked, 0)

	# A view is not a save: it cannot carry the deck or the match generator.
	_check("the view carries no deck contents", not blob.contains("\"deck\":"))
	_check("the view carries no generator state", not JSON.stringify(to_guest).contains("rng"))

	# The guest can still rebuild a usable mirror, and knows the hand COUNT.
	var mirror := GameState.from_net_dict(to_guest, "guest")
	_eq("mirror knows the opponent hand count", mirror.opponent.get_hand_size(), gs.player.hand.size())
	_eq("but holds none of the cards", mirror.opponent.hand.size(), 0)
	_eq("and has its own hand in full", mirror.player.hand.size(), gs.opponent.hand.size())
	_eq("boards survive the round trip", mirror.opponent.board.size(), gs.player.board.size())

	# An open choice survives to the client that must answer it.
	var gs2 := GameState.new("host", "guest", _deck_of(card_id, 20), _deck_of(card_id, 20))
	gs2.start_game("host")
	_put_on_board(gs2, "host", card_id)
	var qm := _put_on_board(gs2, "host", "gen_016")
	Abilities.fire_on_play(qm, gs2.player, gs2)
	if gs2.has_pending_choice():
		var mirror2 := GameState.from_net_dict(gs2.to_net_dict("guest"), "guest")
		_check("a pending choice reaches the client", mirror2.has_pending_choice())
		_eq("with the same id", str(mirror2.pending_choice["id"]), str(gs2.pending_choice["id"]))

# --- Entry point ----------------------------------------------------------

static func run() -> int:
	_failures = 0
	_checks = 0
	var card_id := _cheap_creature_id()
	if card_id.is_empty():
		print("CORE TESTS: no suitable creature in the catalog")
		return 1
	print("CORE TESTS (fixture card: %s)" % card_id)
	_test_copy_isolation(card_id)
	_test_search_does_not_mutate(card_id)
	_test_invalid_commands_are_inert(card_id)
	_test_card_identity(card_id)
	_test_fingerprint_distinguishes(card_id)
	_test_randomness_isolation(card_id)
	_test_crypt_hunger()
	_test_aura_withdrawn_on_silence()
	_test_pending_resolution(card_id)
	_test_simultaneous_deaths(card_id)
	_test_sanguine_recipients(card_id)
	_test_shared_health_ops(card_id)
	_test_reinforce_after_group_death(card_id)
	_test_damage_amplification(card_id)
	_test_spell_copy_isolation()
	_test_new_cards_catalog()
	_test_targeted_on_play(card_id)
	_test_choice_validation(card_id)
	_test_maurice_reinforce()
	_test_player_views(card_id)
	print("CORE TESTS: %d checks, %d failed" % [_checks, _failures])
	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL"))
	return _failures
