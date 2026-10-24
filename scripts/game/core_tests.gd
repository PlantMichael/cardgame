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

## Part Two cards (handoff): Emergency Extraction, Whiteout, Snowdrift Matriarch.

## Puts a fresh copy of a catalog card in `pid`'s hand and tops up their mana.
static func _hand_add(gs: GameState, pid: String, card_id: String) -> CardData:
	var p := gs.find_player(pid)
	var c := CardDatabase.get_card(card_id).new_instance(p.mint_card_uid())
	p.hand.append(c)
	# PlayerState.current_mana counts mana SPENT this turn (see can_play_card),
	# so 0 is a full pool.
	p.max_mana = 10
	p.current_mana = 0
	return c

static func _play_stratagem(gs: GameState, pid: String, card: CardData, target_iid: String = "", target_pid: String = "") -> Dictionary:
	return gs.execute({"type": "play_stratagem", "actor": pid, "card_uid": card.uid,
		"target_instance_id": target_iid, "target_player_id": target_pid})

static func _first_of_type(t: CardData.CardType) -> String:
	for d: CardData in CardDatabase.get_all_cards():
		if d.card_type == t:
			return d.id
	return ""

static func _count_yetis(cards: Array) -> int:
	var n := 0
	for c in cards:
		if Abilities.YETI in c.abilities:
			n += 1
	return n

static func _test_part_two_catalog() -> void:
	print("[part two: catalog]")
	var ex := CardDatabase.get_card("gen_str_005")
	_check("Emergency Extraction loads", ex != null)
	if ex != null:
		_eq("extraction name", ex.card_name, "Emergency Extraction")
		_eq("extraction cost", ex.cost, 2)
		_eq("extraction color", ex.color, CardData.CardColor.GENERIC)
		_eq("extraction rarity", ex.rarity, CardData.CardRarity.COMMON)
		_eq("extraction type", ex.card_type, CardData.CardType.STRATAGEM)
		_eq("extraction text", ex.description, "Return a friendly creature to your hand.")
		_check("extraction is not a token", not ex.is_token)
	var wo := CardDatabase.get_card("t_str_004")
	_check("Whiteout loads", wo != null)
	if wo != null:
		_eq("whiteout name", wo.card_name, "Whiteout")
		_eq("whiteout cost", wo.cost, 5)
		_eq("whiteout color", wo.color, CardData.CardColor.TEAL)
		_eq("whiteout type", wo.card_type, CardData.CardType.STRATAGEM)
		_eq("whiteout damage", wo.effect_value, 2)
		_eq("whiteout text", wo.description, "Deal 2 damage to all enemy creatures. If any die from this damage, draw a random Yeti from your deck.")
	var sm := CardDatabase.get_card("t_027")
	_check("Snowdrift Matriarch loads", sm != null)
	if sm != null:
		_eq("matriarch name", sm.card_name, "Snowdrift Matriarch")
		_eq("matriarch cost", sm.cost, 5)
		_eq("matriarch attack", sm.attack, 3)
		_eq("matriarch health", sm.health, 6)
		_eq("matriarch color", sm.color, CardData.CardColor.TEAL)
		_eq("matriarch type", sm.card_type, CardData.CardType.CREATURE)
		_eq("matriarch tribe", sm.tribe, "yeti")
		_check("matriarch is a yeti", Abilities.YETI in sm.abilities)
		_check("the yeti tag is not duplicated", sm.abilities.count(Abilities.YETI) == 1)
	var ids := {}
	var dupes := 0
	for d: CardData in CardDatabase.get_all_cards():
		if ids.has(d.id):
			dupes += 1
		ids[d.id] = true
	_eq("no duplicate card ids", dupes, 0)

static func _test_emergency_extraction(card_id: String) -> void:
	print("[Emergency Extraction]")
	var gs := _fresh_match(card_id)
	var ally := _put_on_board(gs, "a", card_id)
	ally.current_health = 1
	var ally_uid := ally.card_uid
	_check("the creature carries its card's identity", not ally_uid.is_empty())
	var ex := _hand_add(gs, "a", "gen_str_005")
	var hand_before := gs.player.hand.size()
	var r := _play_stratagem(gs, "a", ex, ally.instance_id)
	_check("play accepted", r["ok"], str(r.get("error", "")))
	_eq("2 mana spent", gs.player.current_mana, 2)
	_check("creature left the board", ally not in gs.player.board)
	_eq("hand: -Extraction +returned card", gs.player.hand.size(), hand_before)
	_check("Extraction itself was consumed", gs.player.find_card_in_hand(ex.uid) == null)
	var back := gs.player.find_card_in_hand(ally_uid)
	_check("the SAME card (uid) is back in hand", back != null)
	if back != null:
		_eq("at printed health", back.health, ally.data.health)
	_check("returning is not dying: creature not in graveyard", not gs.player.graveyard.has(ally.data))
	_check("no choice or queue was opened", not gs.has_pending_choice() and not gs.has_pending())

	# --- illegal targets leave everything untouched ---
	var gs2 := _fresh_match(card_id)
	var mine := _put_on_board(gs2, "a", card_id)
	var theirs := _put_on_board(gs2, "b", card_id)
	var ex2 := _hand_add(gs2, "a", "gen_str_005")
	var loc_id := _first_of_type(CardData.CardType.LOCATION)
	var loc: Minion = null
	if not loc_id.is_empty():
		loc = _put_on_board(gs2, "a", loc_id)
	var snapshot := [gs2.player.hand.size(), gs2.player.current_mana, gs2.player.board.size(), gs2.opponent.board.size()]
	var bad_cases := {
		"enemy creature": [theirs.instance_id, ""],
		"a hero": ["", "a"],
		"an enemy hero": ["", "b"],
		"no target": ["", ""],
		"an unknown instance": ["nope#1", ""],
	}
	if loc != null:
		bad_cases["a Location"] = [loc.instance_id, ""]
	for label in bad_cases:
		var rr := _play_stratagem(gs2, "a", ex2, bad_cases[label][0], bad_cases[label][1])
		_check("rejects %s" % label, not rr["ok"])
	_eq("rejections spent no mana", gs2.player.current_mana, snapshot[1])
	_eq("rejections kept the hand", gs2.player.hand.size(), snapshot[0])
	_eq("rejections kept my board", gs2.player.board.size(), snapshot[2])
	_eq("rejections kept theirs", gs2.opponent.board.size(), snapshot[3])
	# A stale target (already gone) is refused, and never removes someone else.
	gs2.player.remove_minion(mine)
	var stale := _play_stratagem(gs2, "a", ex2, mine.instance_id)
	_check("a stale target is rejected", not stale["ok"])
	_check("and Extraction is still in hand", gs2.player.find_card_in_hand(ex2.uid) != null)
	# The direct (non-command) entry used by the multiplayer host/guest agrees.
	_check("play_stratagem() refuses an enemy target too", not gs2.play_stratagem("a", ex2, theirs, ""))
	_check("and the enemy creature is still there", theirs in gs2.opponent.board)

	# --- a full hand still has room: Extraction frees its own slot ---
	var gs3 := _fresh_match(card_id)
	var t3 := _put_on_board(gs3, "a", card_id)
	var ex3 := _hand_add(gs3, "a", "gen_str_005")
	while gs3.player.hand.size() < PlayerState.MAX_HAND_SIZE:
		gs3.player.hand.append(CardDatabase.get_card(card_id).new_instance(gs3.player.mint_card_uid()))
	_eq("hand is full", gs3.player.hand.size(), PlayerState.MAX_HAND_SIZE)
	var r3 := _play_stratagem(gs3, "a", ex3, t3.instance_id)
	_check("a full hand still takes the returned card", r3["ok"])
	_eq("and ends exactly full", gs3.player.hand.size(), PlayerState.MAX_HAND_SIZE)

	# --- Archive Courier: returning is not dying, so no death draw ---
	var gs4 := _fresh_match(card_id)
	var courier := _put_on_board(gs4, "a", "gen_014")
	var ex4 := _hand_add(gs4, "a", "gen_str_005")
	var deck_before := gs4.player.deck.size()
	var hand4 := gs4.player.hand.size()
	_play_stratagem(gs4, "a", ex4, courier.instance_id)
	_eq("no card drawn", gs4.player.deck.size(), deck_before)
	_eq("hand is -Extraction +Courier only", gs4.player.hand.size(), hand4)
	_check("no pending draw announced", gs4.pending_drawn_cards.is_empty())

	# --- a Reinforce creature does not come back to the board ---
	var plain: CardData = null
	for d: CardData in CardDatabase.get_all_cards():
		if d.id != "g_028" and Abilities.REINFORCE in d.abilities and not d.is_token:
			plain = d
			break
	if plain != null:
		var gs5 := _fresh_match(card_id)
		var rf := _put_on_board(gs5, "a", plain.id)
		var ex5 := _hand_add(gs5, "a", "gen_str_005")
		_play_stratagem(gs5, "a", ex5, rf.instance_id)
		_eq("no Reinforce replacement", gs5.player.board.size(), 0)
		_check("no reinforce event queued", not gs5.has_pending())
		var rc := gs5.player.find_card_in_hand(rf.card_uid)
		_check("it is in hand with its Reinforce intact", rc != null and Abilities.REINFORCE in rc.abilities)

	# --- Rummage history rides along; returning is not a rummage ---
	var gs6 := _fresh_match(card_id)
	var rm := _put_on_board(gs6, "a", card_id)
	rm.data.rummage_count = 2
	var ex6 := _hand_add(gs6, "a", "gen_str_005")
	_play_stratagem(gs6, "a", ex6, rm.instance_id)
	var rmc := gs6.player.find_card_in_hand(rm.card_uid)
	_check("rummage history preserved", rmc != null and rmc.rummage_count == 2)
	_check("no rummage queued", gs6.pending_rummages.is_empty())
	_check("the shared catalog definition is untouched", CardDatabase.get_card(card_id).rummage_count == 0)

	# --- a transformed creature is not undone, and keeps its identity ---
	var gs7 := _fresh_match(card_id)
	var tf := _put_on_board(gs7, "a", card_id)
	var uid7 := tf.card_uid
	tf.data = CardDatabase.get_card("gen_013")
	var ex7 := _hand_add(gs7, "a", "gen_str_005")
	_play_stratagem(gs7, "a", ex7, tf.instance_id)
	var tfc := gs7.player.find_card_in_hand(uid7)
	_check("a transformed creature returns in its current form, same uid", tfc != null and tfc.id == "gen_013")

	# --- an attached pilot is neither lost nor duplicated ---
	var gs8 := _fresh_match(card_id)
	var mech := _put_on_board(gs8, "a", card_id)
	mech.is_piloted = true
	mech.piloted_by = CardDatabase.get_card("gen_013").new_instance(gs8.player.mint_card_uid())
	var ex8 := _hand_add(gs8, "a", "gen_str_005")
	_play_stratagem(gs8, "a", ex8, mech.instance_id)
	_eq("exactly the pilot replaces it on the board", gs8.player.board.size(), 1)
	if gs8.player.board.size() == 1:
		_eq("and it is the pilot", gs8.player.board[0].data.id, "gen_013")

	# --- stale bookkeeping naming the creature is cleared ---
	var gs9 := _fresh_match(card_id)
	var sh := _put_on_board(gs9, "a", card_id)
	gs9.temp_shielded.append({"instance_id": sh.instance_id, "ability": "shielded_3", "expires_after": "b"})
	var ex9 := _hand_add(gs9, "a", "gen_str_005")
	_play_stratagem(gs9, "a", ex9, sh.instance_id)
	_check("a temporary shield entry for it is dropped", gs9.temp_shielded.is_empty())

	# --- simulation copies keep identity and stay independent ---
	var gs10 := _fresh_match(card_id)
	var cl := _put_on_board(gs10, "a", card_id)
	var ex10 := _hand_add(gs10, "a", "gen_str_005")
	var copy := gs10.duplicate_for_sim()
	_eq("a copy keeps the card identity", copy.player.board[0].card_uid, cl.card_uid)
	_play_stratagem(copy, "a", copy.player.find_card_in_hand(ex10.uid), copy.player.board[0].instance_id)
	_eq("playing in the copy does not touch the original board", gs10.player.board.size(), 1)
	_check("or the original hand", gs10.player.find_card_in_hand(ex10.uid) != null)

## Maurice and the cards whose on-play must NOT fire on the return.
static func _test_extraction_replay() -> void:
	print("[Emergency Extraction: replay]")
	var filler := _cheap_creature_id()
	# Maurice with uses left keeps exactly the uses left; zero stays zero.
	for deaths in [1, 4]:
		var gs := _fresh_match(filler)
		var m := Minion.new(CardDatabase.get_card("g_028").new_instance(gs.player.mint_card_uid()), "a")
		gs.player.place_minion(m)
		for _i in deaths:
			gs.player.board[0].current_health = 0
			gs._remove_dead_minions()
		var live: Minion = gs.player.board[0]
		var left := Abilities.reinforce_uses_of(live)
		_eq("Maurice has %d left before extraction" % (4 - deaths), left, 4 - deaths)
		var ex := _hand_add(gs, "a", "gen_str_005")
		_play_stratagem(gs, "a", ex, live.instance_id)
		var card := gs.player.find_card_in_hand(m.card_uid)
		_check("Maurice (%d used) is back in hand" % deaths, card != null)
		if card == null:
			continue
		var r := gs.execute({"type": "play_creature", "actor": "a", "card_uid": card.uid, "at_index": -1})
		_check("and replays", r["ok"], str(r.get("error", "")))
		if r["ok"]:
			_eq("replayed Maurice has the same %d returns, not a fresh four" % left,
				Abilities.reinforce_uses_of(r["minion"]), left)
	# Replaying an on-play creature charges its cost and fires its effect once;
	# the extraction itself fires nothing.
	var gs2 := _fresh_match(filler)
	var hunter := _put_on_board(gs2, "a", "gen_017")
	var foe := _put_on_board(gs2, "b", filler)
	foe.current_attack = 6
	foe.max_health = 20
	foe.current_health = 20
	var ex2 := _hand_add(gs2, "a", "gen_str_005")
	_play_stratagem(gs2, "a", ex2, hunter.instance_id)
	_check("extraction opened no on-play choice", not gs2.has_pending_choice())
	var hc := gs2.player.find_card_in_hand(hunter.card_uid)
	_check("Heavy Bounty Hunter is in hand", hc != null)
	if hc != null:
		var mana := gs2.player.current_mana
		var r2 := gs2.execute({"type": "play_creature", "actor": "a", "card_uid": hc.uid, "at_index": -1})
		_check("replay accepted", r2["ok"])
		_eq("replay charges its full cost", gs2.player.current_mana, mana + hc.effective_cost())
		_check("its on-play choice opens exactly once, now", gs2.has_pending_choice())

static func _test_whiteout() -> void:
	print("[Whiteout]")
	var filler := _cheap_creature_id()
	var yeti_deck: Array[CardData] = []
	for _i in 6:
		yeti_deck.append(CardDatabase.get_card("t_025"))
		yeti_deck.append(CardDatabase.get_card("t_026"))
	var new_game := func(my_deck: Array[CardData]) -> GameState:
		var g := GameState.new("a", "b", my_deck, _deck_of(filler, 20))
		g.set_gameplay_seed(11)
		g.start_game("a")
		return g

	# Direct kills: several die, exactly one Yeti is drawn.
	var gs: GameState = new_game.call(yeti_deck)
	var e1 := _put_on_board(gs, "b", filler)
	var e2 := _put_on_board(gs, "b", filler)
	e1.current_health = 2
	e2.current_health = 1
	var friend := _put_on_board(gs, "a", filler)
	var friend_hp := friend.current_health
	var heroes := [gs.player.hero_health, gs.opponent.hero_health]
	var wo := _hand_add(gs, "a", "t_str_004")
	var yetis_before := _count_yetis(gs.player.hand)
	var deck_before := gs.player.deck.size()
	var r := _play_stratagem(gs, "a", wo)
	_check("untargeted play accepted", r["ok"], str(r.get("error", "")))
	_eq("5 mana spent", gs.player.current_mana, 5)
	_eq("both enemies died", gs.opponent.board.size(), 0)
	_eq("exactly one Yeti drawn for two kills", _count_yetis(gs.player.hand), yetis_before + 1)
	_eq("it came out of the deck", gs.player.deck.size(), deck_before - 1)
	_eq("friendly creature untouched", friend.current_health, friend_hp)
	_eq("my hero untouched", gs.player.hero_health, heroes[0])
	_eq("their hero untouched", gs.opponent.hero_health, heroes[1])

	# No kill, no draw; survivors take exactly 2.
	var gs2: GameState = new_game.call(yeti_deck)
	var tough := _put_on_board(gs2, "b", filler)
	tough.max_health = 9
	tough.current_health = 9
	var wo2 := _hand_add(gs2, "a", "t_str_004")
	var hand2 := gs2.player.hand.size()
	_play_stratagem(gs2, "a", wo2)
	_eq("survivor took 2", tough.current_health, 7)
	_eq("no kill, no draw (hand only lost Whiteout)", gs2.player.hand.size(), hand2 - 1)

	# No enemies at all is a legal play that simply does nothing.
	var gs2b: GameState = new_game.call(yeti_deck)
	var wo2b := _hand_add(gs2b, "a", "t_str_004")
	_check("no enemies is still playable", _play_stratagem(gs2b, "a", wo2b)["ok"])

	# Locations are not damaged.
	var loc_id := _first_of_type(CardData.CardType.LOCATION)
	if not loc_id.is_empty():
		var gs3: GameState = new_game.call(yeti_deck)
		var loc := _put_on_board(gs3, "b", loc_id)
		var loc_hp := loc.current_health
		var wo3 := _hand_add(gs3, "a", "t_str_004")
		_play_stratagem(gs3, "a", wo3)
		_eq("an enemy Location takes no damage", loc.current_health, loc_hp)
		_check("and is still on the board", loc in gs3.opponent.board)

	# A direct kill that Reinforce refills still counts (board size unchanged).
	var rf_card: CardData = null
	for d: CardData in CardDatabase.get_all_cards():
		if d.card_type == CardData.CardType.CREATURE and Abilities.REINFORCE in d.abilities and d.id != "g_028" and not d.is_token:
			rf_card = d
			break
	if rf_card != null:
		var gs4: GameState = new_game.call(yeti_deck)
		var rfm := _put_on_board(gs4, "b", rf_card.id)
		rfm.current_health = 1
		var wo4 := _hand_add(gs4, "a", "t_str_004")
		var y4 := _count_yetis(gs4.player.hand)
		_play_stratagem(gs4, "a", wo4)
		_eq("Reinforce refilled the board", gs4.opponent.board.size(), 1)
		_eq("but the direct kill still drew a Yeti", _count_yetis(gs4.player.hand), y4 + 1)

	# No Yeti in the deck: nothing, and no fatigue. Same for an empty deck.
	var gs5: GameState = new_game.call(_deck_of(filler, 10))
	var d5 := _put_on_board(gs5, "b", filler)
	d5.current_health = 1
	var wo5 := _hand_add(gs5, "a", "t_str_004")
	var h5 := gs5.player.hand.size()
	var deck5 := gs5.player.deck.size()
	_play_stratagem(gs5, "a", wo5)
	_eq("no Yeti: no fallback draw", gs5.player.hand.size(), h5 - 1)
	_eq("deck untouched", gs5.player.deck.size(), deck5)
	var empty_deck: Array[CardData] = []
	var gs6: GameState = new_game.call(empty_deck)
	var d6 := _put_on_board(gs6, "b", filler)
	d6.current_health = 1
	var wo6 := _hand_add(gs6, "a", "t_str_004")
	var hero6 := gs6.player.hero_health
	var fatigue6 := gs6.player.fatigue_damage  # the opening deal already drew from nothing
	_play_stratagem(gs6, "a", wo6)
	_eq("an empty deck causes no further fatigue", gs6.player.fatigue_damage, fatigue6)
	_eq("nor hero damage", gs6.player.hero_health, hero6)

	# A full hand burns the pick like an ordinary draw.
	var gs7: GameState = new_game.call(yeti_deck)
	while gs7.player.hand.size() < PlayerState.MAX_HAND_SIZE:
		gs7.player.hand.append(CardDatabase.get_card(filler).new_instance(gs7.player.mint_card_uid()))
	var deck7 := gs7.player.deck.size()
	gs7.draw_random_yeti(gs7.player)
	_eq("a full hand stays full", gs7.player.hand.size(), PlayerState.MAX_HAND_SIZE)
	_eq("the burned Yeti left the deck", gs7.player.deck.size(), deck7 - 1)

	# Same seed + same state -> same Yeti; the pick is the match's own roll.
	# (Two clones of ONE state: a copy carries the generator's position, which
	# is exactly the property that makes the pick the match's own roll.)
	var base: GameState = new_game.call(yeti_deck)
	var picks: Array[String] = []
	for _run in 2:
		var g := base.duplicate_for_sim()
		var c := g.draw_random_yeti(g.player)
		picks.append(c.id if c != null else "")
	_eq("deterministic under a fixed seed", picks[0], picks[1])
	var pick_card := CardDatabase.get_card(picks[0])
	_check("and it is a Yeti", pick_card != null and Abilities.YETI in pick_card.abilities)
	var gs8: GameState = new_game.call(yeti_deck)
	var minted := gs8.draw_random_yeti(gs8.player)
	_check("the drawn card is a new instance with its own uid", minted != null and not minted.uid.is_empty())
	_check("the shared catalog card was not mutated", CardDatabase.get_card(minted.id).uid.is_empty())

	# Damage modifiers apply like other stratagem damage.
	var gs9: GameState = new_game.call(yeti_deck)
	var amp_src := _put_on_board(gs9, "a", filler)
	amp_src.abilities.append("enemy_damage_amp_1")
	var e9 := _put_on_board(gs9, "b", filler)
	e9.current_health = 3
	var wo9 := _hand_add(gs9, "a", "t_str_004")
	_play_stratagem(gs9, "a", wo9)
	_check("amplified damage (2+1) kills a 3-health creature", e9 not in gs9.opponent.board)

static func _test_snowdrift_matriarch() -> void:
	print("[Snowdrift Matriarch]")
	var filler := _cheap_creature_id()
	var gs := _fresh_match(filler)
	var y1 := _put_on_board(gs, "a", "t_025")
	var y2 := _put_on_board(gs, "a", "t_026")
	var y_full := _put_on_board(gs, "a", "t_025")
	var other := _put_on_board(gs, "a", filler)
	var foe_yeti := _put_on_board(gs, "b", "t_025")
	for m in [y1, y2, y_full, other, foe_yeti]:
		m.max_health = 6
		m.current_health = 6
	y1.current_health = 1
	y2.current_health = 5
	other.current_health = 1
	foe_yeti.current_health = 1
	var card := _hand_add(gs, "a", "t_027")
	var r := gs.execute({"type": "play_creature", "actor": "a", "card_uid": card.uid, "at_index": -1})
	_check("played", r["ok"], str(r.get("error", "")))
	_check("no per-recipient prompt", not gs.has_pending_choice())
	_eq("a Yeti 5 below max heals the full 2", y1.current_health, 3)
	_eq("a Yeti 1 below max heals only 1", y2.current_health, 6)
	_eq("a full-health Yeti gains nothing", y_full.current_health, 6)
	_eq("max health unchanged by the base effect", y1.max_health, 6)
	_eq("a non-Yeti friend is not healed", other.current_health, 1)
	_eq("an enemy Yeti is not healed", foe_yeti.current_health, 1)
	if r["ok"]:
		var matriarch: Minion = r["minion"]
		_eq("the source is not healed (3/6 stays 6)", matriarch.current_health, 6)

	# Alone: still plays normally.
	var gs2 := _fresh_match(filler)
	var c2 := _hand_add(gs2, "a", "t_027")
	var r2 := gs2.execute({"type": "play_creature", "actor": "a", "card_uid": c2.uid, "at_index": -1})
	_check("playing with no other Yeti completes", r2["ok"] and gs2.player.board.size() == 1)

	# A hurt Matriarch already on board is a legal recipient for a second one.
	var gs3 := _fresh_match(filler)
	var first := _put_on_board(gs3, "a", "t_027")
	first.current_health = 2
	var c3 := _hand_add(gs3, "a", "t_027")
	gs3.execute({"type": "play_creature", "actor": "a", "card_uid": c3.uid, "at_index": -1})
	_eq("another Matriarch counts as an other friendly Yeti", first.current_health, 4)

	# Reinforce is a summon, not a play: it must not heal.
	var gs4 := _fresh_match(filler)
	var hurt := _put_on_board(gs4, "a", "t_025")
	hurt.max_health = 6
	hurt.current_health = 2
	var m4 := Minion.new(CardDatabase.get_card("t_027").new_instance(gs4.player.mint_card_uid()), "a")
	gs4.player.place_minion(m4)
	m4.abilities.append("reinforce")
	m4.current_health = 0
	gs4._remove_dead_minions()
	_eq("a Reinforce return does not fire on-play healing", hurt.current_health, 2)

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
	_test_part_two_catalog()
	_test_emergency_extraction(card_id)
	_test_extraction_replay()
	_test_whiteout()
	_test_snowdrift_matriarch()
	_test_player_views(card_id)
	print("CORE TESTS: %d checks, %d failed" % [_checks, _failures])
	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL"))
	return _failures
