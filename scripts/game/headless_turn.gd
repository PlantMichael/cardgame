class_name HeadlessTurn
extends RefCounted

## Stateless, UI-free turn executor shared by SimRunner-style balance sims and
## MCTSEngine's search/rollouts. Operates purely on GameState — no Board, no
## animations, no awaits. Two levels of granularity are exposed:
##  - list_legal_actions()/apply_action(): one atomic decision at a time, for
##    MCTSEngine's tree search.
##  - greedy_pick_action()/play_full_turn_greedy(): the same "always take the
##    best-looking single action" policy AIController/SimRunner already use,
##    for finishing rollouts and simulating the opponent's predicted turn
##    without spending search budget on it.

# --- Atomic action enumeration (for search) ---

## Enumerates every legal atomic action `acting_id` can take right now: one
## per playable creature, one per ready stratagem (target pre-resolved via the
## shared heuristic pickers so the search doesn't also have to branch on
## *which* enemy minion a spell hits), one per legal attacker/target pairing
## (plus "attack face"), and always `end_turn`.
static func list_legal_actions(gs: GameState, acting_id: String) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	if gs.current_phase == GameState.Phase.GAME_OVER:
		return actions

	var acting: PlayerState = gs._get_player_by_id(acting_id)
	var enemy: PlayerState = gs._get_player_by_id(gs._opponent_id(acting_id))

	for card in acting.hand:
		if not acting.can_play_card(card):
			continue
		if card.card_type == CardData.CardType.CREATURE:
			if acting.board.size() < PlayerState.MAX_BOARD_SIZE:
				actions.append({"type": "play_creature", "card": card})
		elif card.card_type == CardData.CardType.STRATAGEM:
			var pick := _pick_stratagem_target(card, gs, acting_id)
			if pick["ready"]:
				actions.append({
					"type": "play_stratagem", "card": card,
					"minion": pick["minion"], "player_id": pick["player_id"],
				})

	var attackers: Array[Minion] = []
	for m in acting.board:
		if m.can_attack():
			attackers.append(m)
	if not attackers.is_empty():
		var guardians := enemy.get_guardian_minions()
		var forced := not guardians.is_empty()
		var raw_targets: Array[Minion] = guardians if forced else enemy.board
		var targets: Array[Minion] = []
		for m in raw_targets:
			if not m.has_ability(Abilities.COMBAT_IMMUNE) and not m.has_ability(Abilities.AMBUSH):
				targets.append(m)
		for attacker in attackers:
			for target in targets:
				actions.append({"type": "attack", "attacker": attacker, "target": target, "target_player_id": ""})
			if not forced:
				actions.append({"type": "attack", "attacker": attacker, "target": null, "target_player_id": enemy.player_id})

	actions.append({"type": "end_turn"})
	return actions

## Applies exactly one atomic action produced by list_legal_actions() (or
## greedy_pick_action()) and resolves any pending_* queue it triggers.
static func apply_action(gs: GameState, action: Dictionary) -> void:
	match action["type"]:
		"play_creature":
			var acting_id: String = gs.active_player_id
			var m := gs.play_creature(acting_id, action["card"])
			if m != null:
				_handle_on_play(m, gs)
			_resolve_pending(gs)
		"play_stratagem":
			var acting_id: String = gs.active_player_id
			var target_minion: Minion = action.get("minion")
			var ok := gs.play_stratagem(acting_id, action["card"], target_minion, action.get("player_id", ""))
			if ok:
				_apply_stratagem_secondary(action["card"], target_minion, gs, acting_id)
			_resolve_pending(gs)
		"attack":
			var attacker: Minion = action["attacker"]
			gs.attack(attacker, action.get("target"), action.get("target_player_id", ""))
			_resolve_pending(gs)
		"end_turn":
			gs.end_turn()
			_resolve_pending(gs)

# --- Greedy policy (rollout completion / predicted opponent turn) ---

## Picks the single next action a greedy (one-ply) heuristic AI would take:
## play the highest-priority playable card, else make the best-scoring
## attack, else end the turn. Same priorities AIController/SimRunner already
## use, just returning one action instead of looping with UI side effects.
static func greedy_pick_action(gs: GameState, acting_id: String) -> Dictionary:
	var acting: PlayerState = gs._get_player_by_id(acting_id)
	var enemy: PlayerState = gs._get_player_by_id(gs._opponent_id(acting_id))

	var hand := acting.hand.duplicate()
	hand.sort_custom(func(a: CardData, b: CardData) -> bool:
		if not enemy.get_guardian_minions().is_empty():
			var a_rush = _can_rush_kill_guardian(a, enemy)
			var b_rush = _can_rush_kill_guardian(b, enemy)
			if a_rush != b_rush:
				return a_rush
		var a_blocked := _is_pilot_without_target(a, acting)
		var b_blocked := _is_pilot_without_target(b, acting)
		if a_blocked != b_blocked:
			return not a_blocked
		return a.cost > b.cost
	)
	for card in hand:
		if not acting.can_play_card(card):
			continue
		if card.card_type == CardData.CardType.CREATURE:
			if acting.board.size() < PlayerState.MAX_BOARD_SIZE:
				return {"type": "play_creature", "card": card}
		elif card.card_type == CardData.CardType.STRATAGEM:
			var pick := _pick_stratagem_target(card, gs, acting_id)
			if pick["ready"]:
				return {
					"type": "play_stratagem", "card": card,
					"minion": pick["minion"], "player_id": pick["player_id"],
				}

	var attackers: Array[Minion] = []
	for m in acting.board:
		if m.can_attack():
			attackers.append(m)
	if attackers.is_empty():
		return {"type": "end_turn"}

	var guardians := enemy.get_guardian_minions()
	var forced := not guardians.is_empty()
	var raw: Array[Minion] = guardians if forced else enemy.board.duplicate()
	var candidates: Array[Minion] = []
	for m in raw:
		if not m.has_ability(Abilities.COMBAT_IMMUNE) and not m.has_ability(Abilities.AMBUSH):
			candidates.append(m)

	if candidates.is_empty():
		if forced:
			return {"type": "end_turn"}
		return {"type": "attack", "attacker": attackers[0], "target": null, "target_player_id": enemy.player_id}

	var best_score := -999
	var best_attacker: Minion = null
	var best_target: Minion = null
	for attacker in attackers:
		for target in candidates:
			var score = AIHeuristics.score_trade(attacker, target, gs)
			if score > best_score:
				best_score = score
				best_attacker = attacker
				best_target = target
		if not forced:
			var face_score = AIHeuristics.face_pressure_score(enemy.hero_health, acting.board.size(), enemy.board.size()) + attacker.current_attack / 2
			if face_score > best_score:
				best_score = face_score
				best_attacker = attacker
				best_target = null

	if best_attacker == null or (best_score <= 0 and not forced):
		return {"type": "end_turn"}
	if best_target != null:
		return {"type": "attack", "attacker": best_attacker, "target": best_target, "target_player_id": ""}
	return {"type": "attack", "attacker": best_attacker, "target": null, "target_player_id": enemy.player_id}

## Plays out the rest of `acting_id`'s turn (including ending it) using
## greedy_pick_action repeatedly. Used to simulate the opponent's predicted
## response, or to finish an AI rollout beyond the point the search tree
## stopped branching, without spending search budget on it.
static func play_full_turn_greedy(gs: GameState, acting_id: String) -> void:
	for _i in 60:  # safety cap; a real turn never needs anywhere near this many atomic actions
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return
		var action := greedy_pick_action(gs, acting_id)
		apply_action(gs, action)
		if action["type"] == "end_turn" or gs.current_phase == GameState.Phase.GAME_OVER:
			return

# --- Stratagem targeting (shared by both granularities above) ---

static func _pick_stratagem_target(card: CardData, gs: GameState, acting_id: String) -> Dictionary:
	var acting: PlayerState = gs._get_player_by_id(acting_id)
	var enemy_id: String = gs._opponent_id(acting_id)
	var enemy: PlayerState = gs._get_player_by_id(enemy_id)
	var result = {"ready": false, "minion": null, "player_id": ""}

	var enemy_targetable: Array[Minion] = []
	for m in enemy.board:
		if not m.has_ability(Abilities.CLOAKED) and not m.has_ability(Abilities.AMBUSH):
			enemy_targetable.append(m)
	var friendly_targetable: Array[Minion] = acting.board.duplicate()

	match card.effect:
		"deal_damage":
			var no_guardians = enemy.get_guardian_minions().is_empty()
			if no_guardians and card.effect_value >= enemy.hero_health:
				result["player_id"] = enemy_id
				result["ready"] = true
			elif not enemy_targetable.is_empty():
				result["minion"] = AIHeuristics.pick_best_removal_target(enemy_targetable, card.effect_value)
				result["ready"] = true
			elif no_guardians:
				result["player_id"] = enemy_id
				result["ready"] = true
		"exsanguinate":
			if not enemy_targetable.is_empty():
				result["minion"] = AIHeuristics.pick_strongest(enemy_targetable)
				result["ready"] = true
		"blood_boil":
			if not friendly_targetable.is_empty():
				result["minion"] = AIHeuristics.pick_health_buff_target(friendly_targetable)
				result["ready"] = true
		"bloodlet":
			var no_guardians_bl = enemy.get_guardian_minions().is_empty()
			if no_guardians_bl and card.effect_value >= enemy.hero_health:
				result["player_id"] = enemy_id
				result["ready"] = true
			elif not enemy_targetable.is_empty():
				result["minion"] = AIHeuristics.pick_best_removal_target(enemy_targetable, card.effect_value)
				result["ready"] = true
			else:
				var damaged: Array[Minion] = []
				for m in friendly_targetable:
					if m.current_health < m.max_health:
						damaged.append(m)
				if not damaged.is_empty():
					result["minion"] = AIHeuristics.pick_lowest_health(damaged)
					result["ready"] = true
				elif no_guardians_bl:
					result["player_id"] = enemy_id
					result["ready"] = true
		"buff_creature":
			if not friendly_targetable.is_empty():
				result["minion"] = AIHeuristics.pick_strongest(friendly_targetable)
				result["ready"] = true
		"buff_health":
			if not friendly_targetable.is_empty():
				result["minion"] = AIHeuristics.pick_lowest_health(friendly_targetable)
				result["ready"] = true
		"give_ability":
			if not friendly_targetable.is_empty():
				result["minion"] = AIHeuristics.pick_strongest(friendly_targetable)
				result["ready"] = true
		"destroy_all_creatures":
			var acting_power := 0
			for m in acting.board:
				acting_power += m.current_attack + m.current_health
			var enemy_power := 0
			for m in enemy.board:
				enemy_power += m.current_attack + m.current_health
			result["ready"] = not enemy.board.is_empty() and enemy_power >= acting_power
		"deal_damage_all_creatures":
			result["ready"] = not enemy.board.is_empty()
		"deal_damage_all_enemy":
			result["ready"] = not enemy.board.is_empty()
		"sludge_spray":
			result["ready"] = not enemy.board.is_empty()
		"buff_all_friendly_attack":
			result["ready"] = not acting.board.is_empty()
		"buff_all_friendly_health":
			result["ready"] = not acting.board.is_empty()
		"blood_transfusion":
			if not enemy_targetable.is_empty():
				result["minion"] = AIHeuristics.pick_best_removal_target(enemy_targetable, card.effect_value)
				result["ready"] = true
		"sanguine":
			var sources: Array[Minion] = []
			for m in friendly_targetable:
				if m.current_health > 2:
					sources.append(m)
			if sources.size() >= 2 or (sources.size() == 1 and friendly_targetable.size() >= 2):
				result["minion"] = AIHeuristics.pick_strongest(sources)
				result["ready"] = true
		"force_challenge", "poke_bear":
			for m in acting.board:
				if m.has_ability(Abilities.YETI) and not enemy.board.is_empty():
					result["minion"] = m
					result["ready"] = true
					break
		"tainted_blood":
			if not friendly_targetable.is_empty():
				var candidate := AIHeuristics.pick_highest_health(friendly_targetable)
				var dmg: int = candidate.current_health / 2
				if friendly_targetable.size() > 1 or dmg >= enemy.hero_health:
					result["minion"] = candidate
					result["ready"] = true
		"heal":
			if not friendly_targetable.is_empty():
				var damaged: Array[Minion] = []
				for m in friendly_targetable:
					if m.current_health < m.max_health:
						damaged.append(m)
				if not damaged.is_empty():
					result["minion"] = AIHeuristics.pick_lowest_health(damaged)
				else:
					result["minion"] = AIHeuristics.pick_health_buff_target(friendly_targetable)
				result["ready"] = true
		"eject_pilot":
			var piloted: Array[Minion] = []
			for m in acting.board:
				if m.is_piloted:
					piloted.append(m)
			if not piloted.is_empty():
				result["minion"] = AIHeuristics.pick_strongest(piloted)
				result["ready"] = true
		"eject_all_pilots":
			for m in acting.board:
				if m.is_piloted:
					result["ready"] = true
					break
		"give_mech_shielded_temp":
			var mechs: Array[Minion] = []
			for m in friendly_targetable:
				if m.has_ability(Abilities.MECH):
					mechs.append(m)
			if not mechs.is_empty():
				result["minion"] = AIHeuristics.pick_strongest(mechs)
				result["ready"] = true
	return result

static func _apply_stratagem_secondary(card: CardData, target: Minion, gs: GameState, acting_id: String) -> void:
	var acting: PlayerState = gs._get_player_by_id(acting_id)
	var enemy: PlayerState = gs._get_player_by_id(gs._opponent_id(acting_id))

	if card.effect == "blood_transfusion" and not acting.board.is_empty():
		gs.apply_heal_buff(AIHeuristics.pick_health_buff_target(acting.board.duplicate()), 2)

	if card.effect == "sanguine" and target != null:
		var others: Array[Minion] = []
		for m in acting.board:
			if m != target:
				others.append(m)
		if not others.is_empty():
			gs.apply_heal_buff(AIHeuristics.pick_health_buff_target(others), 2)

	if card.effect in ["force_challenge", "poke_bear"] and target != null:
		var yeti: Minion = target
		if yeti in acting.board and yeti.has_ability(Abilities.YETI) and not enemy.board.is_empty():
			var non_ambush: Array[Minion] = []
			for m in enemy.board:
				if not m.has_ability(Abilities.AMBUSH):
					non_ambush.append(m)
			if not non_ambush.is_empty():
				var tgt := AIHeuristics.pick_challenge_target(non_ambush, yeti)
				if tgt != null:
					gs.apply_challenge(yeti, tgt)
					if card.effect == "force_challenge" and card.effect_value > 0 \
							and tgt not in enemy.board and yeti in acting.board:
						yeti.current_attack += card.effect_value
						var pre := yeti.current_health
						yeti.current_health += card.effect_value
						yeti.max_health += card.effect_value
						gs._try_heal_to_draw(yeti, yeti.current_health - pre)

# --- On-play effect resolution (ported from SimRunner._sim_handle_on_play) ---

static func _handle_on_play(m: Minion, gs: GameState) -> void:
	if gs.current_phase == GameState.Phase.GAME_OVER:
		return
	var friendly: PlayerState = gs._get_player_by_id(m.owner_id)
	var enemy: PlayerState = gs._get_player_by_id(gs._opponent_id(m.owner_id))

	for ability in m.abilities:
		if Abilities.is_on_play_damage(ability):
			var dmg := Abilities.get_on_play_damage_value(ability)
			if not enemy.board.is_empty():
				var tgt := AIHeuristics.pick_best_removal_target(enemy.board.duplicate(), dmg)
				if tgt != null:
					gs.apply_on_play_damage(tgt, dmg, m.owner_id)
				else:
					enemy.hero_health -= dmg
					gs._check_win_condition()
			else:
				enemy.hero_health -= dmg
				gs._check_win_condition()
			if gs.current_phase == GameState.Phase.GAME_OVER:
				return
			break

	if m not in friendly.board:
		return
	if m.has_ability(Abilities.CHALLENGE) and not enemy.board.is_empty():
		var tgt := AIHeuristics.pick_challenge_target(enemy.board.duplicate(), m)
		if tgt != null:
			gs.apply_challenge(m, tgt)
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return

	if m not in friendly.board:
		return
	if m.has_ability(Abilities.CHALLENGE_ALL):
		var enemies_snap := enemy.board.duplicate()
		for e in enemies_snap:
			if m not in friendly.board or gs.current_phase == GameState.Phase.GAME_OVER:
				break
			if e not in enemy.board or e.has_ability(Abilities.AMBUSH):
				continue
			gs.apply_challenge(m, e)
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return

	if m not in friendly.board:
		return
	if m.has_ability(Abilities.ON_PLAY_CHALLENGE_WIN_BUFF) and not enemy.board.is_empty():
		var tgt := AIHeuristics.pick_challenge_target(enemy.board.duplicate(), m)
		if tgt != null:
			gs.apply_challenge(m, tgt)
			if m in friendly.board and tgt not in enemy.board:
				m.current_attack += 1
				var pre := m.current_health
				m.current_health += 1
				m.max_health += 1
				gs._try_heal_to_draw(m, m.current_health - pre)
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return

	if m not in friendly.board:
		return
	if m.has_ability(Abilities.ON_PLAY_YETI_CHALLENGE) and not enemy.board.is_empty():
		var yeti: Minion = null
		for bm in friendly.board:
			if bm != m and bm.has_ability(Abilities.YETI):
				yeti = bm
				break
		if yeti != null:
			var tgt := AIHeuristics.pick_challenge_target(enemy.board.duplicate(), yeti)
			if tgt != null:
				gs.apply_challenge(yeti, tgt)
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return

	if m not in friendly.board:
		return
	if m.has_ability(Abilities.ON_PLAY_TRANSFORM_CHOICE) and not m.data.transform_choices.is_empty():
		var best_id := m.data.transform_choices[0]
		var best_val := -1
		for cid in m.data.transform_choices:
			var cd := CardDatabase.get_card(cid)
			if cd != null and cd.attack + cd.health > best_val:
				best_val = cd.attack + cd.health
				best_id = cid
		gs.apply_transform_choice(m, best_id)

	if m not in friendly.board:
		return
	if m.has_ability(Abilities.ON_PLAY_DEVOUR_FRIENDLY):
		var cands: Array[Minion] = []
		for bm in friendly.board:
			if bm != m:
				cands.append(bm)
		if not cands.is_empty():
			var weakest: Minion = cands[0]
			for bm in cands:
				if bm.current_attack + bm.current_health < weakest.current_attack + weakest.current_health:
					weakest = bm
			gs.apply_devour_friendly(m, weakest, friendly)

	if m not in friendly.board:
		return
	if m.has_ability(Abilities.ON_PLAY_SWAP_FRIENDLY_HEALTH):
		var cands: Array[Minion] = []
		for bm in friendly.board:
			if bm != m:
				cands.append(bm)
		if cands.size() >= 2:
			var a := cands[randi() % cands.size()]
			var rest: Array[Minion] = []
			for bm in cands:
				if bm != a:
					rest.append(bm)
			if not rest.is_empty():
				gs.apply_swap_friendly_health(a, rest[randi() % rest.size()])

	if m not in friendly.board:
		return
	for ability in m.abilities:
		if Abilities.is_pilot(ability):
			var mechs: Array[Minion] = []
			for bm in friendly.board:
				if bm != m and bm.has_ability(Abilities.MECH) and not bm.is_piloted:
					mechs.append(bm)
			if not mechs.is_empty():
				gs.apply_pilot(m, AIHeuristics.pick_best_pilot_target(mechs, m), friendly, false)
			break

# --- Pending-queue resolution (ported from SimRunner._resolve_pending) ---

static func _resolve_pending(gs: GameState) -> void:
	gs.pending_drawn_cards.clear()
	gs.pending_fatigue_damage.clear()
	var changed := true
	while changed:
		changed = false
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return

		while not gs.pending_rummages.is_empty():
			changed = true
			var entry: Dictionary = gs.pending_rummages.pop_front()
			var pid: String = entry["player_id"]
			var p_state: PlayerState = gs._get_player_by_id(pid)
			var allow_equal: bool = p_state.board.any(
				func(m: Minion) -> bool: return m.has_ability(Abilities.RUMMAGE_EQUAL_COST))
			var options := gs.get_rummage_options(pid, entry.get("max_cost", -1), entry.get("type_filter", ""), allow_equal)
			if not options.is_empty():
				var chosen: CardData = options[randi() % options.size()]
				var placed := gs.complete_rummage(pid, chosen, entry.get("play_it", false), entry.get("discount", true))
				if placed != null:
					_handle_on_play(placed, gs)
			gs.pending_drawn_cards.clear()
			if gs.current_phase == GameState.Phase.GAME_OVER:
				return

		while not gs.pending_tank_shots.is_empty():
			changed = true
			var pid: String = gs.pending_tank_shots.pop_front()
			var enemy: PlayerState = gs._get_player_by_id(gs._opponent_id(pid))
			if not enemy.board.is_empty():
				gs.apply_on_play_damage(enemy.board[randi() % enemy.board.size()], 1, pid)
			else:
				enemy.hero_health -= 1
				gs._check_win_condition()
			gs.pending_drawn_cards.clear()
			if gs.current_phase == GameState.Phase.GAME_OVER:
				return

		while not gs.pending_nulls.is_empty():
			changed = true
			var entry: Dictionary = gs.pending_nulls.pop_front()
			var pid: String = entry["player_id"]
			var enemy: PlayerState = gs._get_player_by_id(gs._opponent_id(pid))
			if not enemy.board.is_empty():
				gs.apply_null(enemy.board[randi() % enemy.board.size()])

		while not gs.pending_buff_friendly_health.is_empty():
			changed = true
			var pid: String = gs.pending_buff_friendly_health.pop_front()
			var p_state: PlayerState = gs._get_player_by_id(pid)
			if not p_state.board.is_empty():
				gs.apply_buff_friendly_health(AIHeuristics.pick_health_buff_target(p_state.board))

		while not gs.pending_tank_specialist_buffs.is_empty():
			changed = true
			var pid: String = gs.pending_tank_specialist_buffs.pop_front()
			var p_state: PlayerState = gs._get_player_by_id(pid)
			var tanks: Array[Minion] = []
			for m in p_state.board:
				if m.data.tribe == "tank":
					tanks.append(m)
			if not tanks.is_empty():
				gs.apply_tank_specialist_buff(tanks[randi() % tanks.size()])

		while not gs.pending_on_reinforce_damages.is_empty():
			changed = true
			var entry: Dictionary = gs.pending_on_reinforce_damages.pop_front()
			var pid: String = entry["player_id"]
			var dmg: int = entry["damage"]
			var enemy: PlayerState = gs._get_player_by_id(gs._opponent_id(pid))
			if not enemy.board.is_empty():
				gs.apply_on_play_damage(enemy.board[randi() % enemy.board.size()], dmg, pid)
			else:
				enemy.hero_health -= dmg
				gs._check_win_condition()
			gs.pending_drawn_cards.clear()
			if gs.current_phase == GameState.Phase.GAME_OVER:
				return

		while not gs.pending_overwatch_challenges.is_empty():
			changed = true
			var pid: String = gs.pending_overwatch_challenges.pop_front()
			var p_state: PlayerState = gs._get_player_by_id(pid)
			var enemy: PlayerState = gs._get_player_by_id(gs._opponent_id(pid))
			var yeti: Minion = null
			for m in p_state.board:
				if m.has_ability(Abilities.YETI):
					yeti = m
					break
			if yeti != null and not enemy.board.is_empty():
				var tgts: Array[Minion] = []
				for m in enemy.board:
					if not m.has_ability(Abilities.AMBUSH):
						tgts.append(m)
				if not tgts.is_empty():
					var target := AIHeuristics.pick_challenge_target(tgts, yeti)
					gs.apply_challenge(yeti, target)
			gs.pending_drawn_cards.clear()
			if gs.current_phase == GameState.Phase.GAME_OVER:
				return

# --- Card-play priority helpers (ported from AIController) ---

static func _can_rush_kill_guardian(card: CardData, enemy: PlayerState) -> bool:
	if card.card_type != CardData.CardType.CREATURE or Abilities.RUSH not in card.abilities:
		return false
	for g in enemy.get_guardian_minions():
		if card.attack >= g.current_health:
			return true
	return false

static func _is_pilot_without_target(card: CardData, acting: PlayerState) -> bool:
	if card.card_type != CardData.CardType.CREATURE:
		return false
	for ab in card.abilities:
		if Abilities.is_pilot(ab):
			for m in acting.board:
				if m.has_ability(Abilities.MECH) and not m.is_piloted:
					return false
			return true
	return false
