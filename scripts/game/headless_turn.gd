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
##
## Actions are plain values addressed by uid/instance_id - never live CardData
## or Minion objects. An action produced here is therefore safe to apply to
## ANY state that still contains those entities, which is what makes MCTS
## expansion (enumerate against a parent, apply to a freshly copied child)
## correct. See GameState.validate() for the full reasoning.
static func list_legal_actions(gs: GameState, acting_id: String) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	if gs.current_phase == GameState.Phase.GAME_OVER:
		return actions

	var acting: PlayerState = gs.find_player(acting_id)
	if acting == null:
		return actions
	var enemy: PlayerState = gs.find_player(gs._opponent_id(acting_id))

	for card in acting.hand:
		if not acting.can_play_card(card):
			continue
		if card.occupies_board():
			if acting.can_fit_card(card):
				actions.append({"type": "play_creature", "actor": acting_id, "card_uid": card.uid})
		elif card.card_type == CardData.CardType.STRATAGEM:
			var pick := _pick_stratagem_target(card, gs, acting_id)
			if pick["ready"]:
				var picked_minion: Minion = pick["minion"]
				actions.append({
					"type": "play_stratagem", "actor": acting_id, "card_uid": card.uid,
					"target_instance_id": picked_minion.instance_id if picked_minion != null else "",
					"target_player_id": pick["player_id"],
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
				actions.append({
					"type": "attack", "actor": acting_id,
					"attacker_instance_id": attacker.instance_id,
					"target_instance_id": target.instance_id, "target_player_id": "",
				})
			if not forced:
				actions.append({
					"type": "attack", "actor": acting_id,
					"attacker_instance_id": attacker.instance_id,
					"target_instance_id": "", "target_player_id": enemy.player_id,
				})

	actions.append({"type": "end_turn", "actor": acting_id})
	return actions

## Applies exactly one atomic action produced by list_legal_actions() (or
## greedy_pick_action()) and resolves any pending_* queue it triggers.
##
## Returns whether the command was accepted. An action enumerated against a
## different state may legitimately no longer be legal here (the search
## applies a parent's action list to a child); that is a rejection, not a
## crash, and the caller gets `false` rather than a silently half-applied
## mutation.
static func apply_action(gs: GameState, action: Dictionary) -> bool:
	var result := gs.execute(action)
	if not result["ok"]:
		return false
	# Every decision an action opens is answered by policy, so the search sees
	# exactly what the real game would produce (no private copy of the rules).
	_resolve_pending(gs)
	return true

# --- Greedy policy (rollout completion / predicted opponent turn) ---

## Picks the single next action a greedy (one-ply) heuristic AI would take:
## play the highest-priority playable card, else make the best-scoring
## attack, else end the turn. Same priorities AIController/SimRunner already
## use, just returning one action instead of looping with UI side effects.
static func greedy_pick_action(gs: GameState, acting_id: String) -> Dictionary:
	var acting: PlayerState = gs.find_player(acting_id)
	if acting == null:
		return {"type": "end_turn", "actor": acting_id}
	var enemy: PlayerState = gs.find_player(gs._opponent_id(acting_id))

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
		if card.occupies_board():
			if acting.can_fit_card(card):
				return {"type": "play_creature", "actor": acting_id, "card_uid": card.uid}
		elif card.card_type == CardData.CardType.STRATAGEM:
			var pick := _pick_stratagem_target(card, gs, acting_id)
			if pick["ready"]:
				var picked: Minion = pick["minion"]
				return {
					"type": "play_stratagem", "actor": acting_id, "card_uid": card.uid,
					"target_instance_id": picked.instance_id if picked != null else "",
					"target_player_id": pick["player_id"],
				}

	var attackers: Array[Minion] = []
	for m in acting.board:
		if m.can_attack():
			attackers.append(m)
	if attackers.is_empty():
		return {"type": "end_turn", "actor": acting_id}

	var guardians := enemy.get_guardian_minions()
	var forced := not guardians.is_empty()
	var raw: Array[Minion] = guardians if forced else enemy.board.duplicate()
	var candidates: Array[Minion] = []
	for m in raw:
		if not m.has_ability(Abilities.COMBAT_IMMUNE) and not m.has_ability(Abilities.AMBUSH):
			candidates.append(m)

	if candidates.is_empty():
		if forced:
			return {"type": "end_turn", "actor": acting_id}
		return {
			"type": "attack", "actor": acting_id,
			"attacker_instance_id": attackers[0].instance_id,
			"target_instance_id": "", "target_player_id": enemy.player_id,
		}

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
		return {"type": "end_turn", "actor": acting_id}
	if best_target != null:
		return {
			"type": "attack", "actor": acting_id,
			"attacker_instance_id": best_attacker.instance_id,
			"target_instance_id": best_target.instance_id, "target_player_id": "",
		}
	return {
		"type": "attack", "actor": acting_id,
		"attacker_instance_id": best_attacker.instance_id,
		"target_instance_id": "", "target_player_id": enemy.player_id,
	}

## Plays out the rest of `acting_id`'s turn (including ending it) using
## greedy_pick_action repeatedly. Used to simulate the opponent's predicted
## response, or to finish an AI rollout beyond the point the search tree
## stopped branching, without spending search budget on it.
static func play_full_turn_greedy(gs: GameState, acting_id: String) -> void:
	for _i in 60:  # safety cap; a real turn never needs anywhere near this many atomic actions
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return
		var action := greedy_pick_action(gs, acting_id)
		# A rejected action would otherwise spin this loop to its safety cap
		# re-picking the same illegal move; end the turn instead.
		if not apply_action(gs, action):
			gs.execute({"type": "end_turn", "actor": acting_id})
			_resolve_pending(gs)
			return
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
		"deal_damage_all_enemy", "deal_damage_all_enemy_draw_yeti":
			result["ready"] = not enemy.board.is_empty()
		"return_friendly_to_hand":
			# Conservative rescue: only pull back a badly hurt creature that
			# is worth replaying. Never a Location, never for tempo alone.
			var rescue: Array[Minion] = []
			for m in friendly_targetable:
				if m.data.card_type == CardData.CardType.CREATURE and m.data.cost >= 2 \
						and m.current_health * 2 <= m.max_health:
					rescue.append(m)
			if not rescue.is_empty():
				result["minion"] = AIHeuristics.pick_lowest_health(rescue)
				result["ready"] = true
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

## Picks an answer for whatever choice is open, using AI scoring over the
## legal options the rules core produced. This is POLICY, not rules: it may
## only choose among options, never widen or narrow them.
##
## Shared by the search, the greedy rollout policy and the live AI, so all
## three resolve a targeted on-play effect the same way.
static func answer_pending_choice(gs: GameState) -> void:
	if not gs.has_pending_choice():
		return
	var choice := gs.pending_choice.duplicate(true)
	var selection := AIHeuristics.pick_choice_answer(gs, choice)
	var actor := str(choice["player_id"])
	var result := gs.execute({"type": GameState.CMD_ANSWER_CHOICE, "actor": actor,
		"choice_id": str(choice["id"]), "selection": selection})
	if not result["ok"]:
		# A policy answer the core refuses (a mandatory choice it wanted to
		# decline, say) falls back to the choice's own deterministic default.
		gs.execute({"type": GameState.CMD_ANSWER_CHOICE, "actor": actor,
			"choice_id": str(choice["id"]), "selection": str(choice["default"])})

# --- Pending-queue resolution (ported from SimRunner._resolve_pending) ---

## Works off every queued effect, repeating until nothing is pending.
##
## The queues are drained in GameState.PENDING_QUEUES order - the same order
## local play and the multiplayer host use. This used to take rummages
## before tank shots while both of those took tank shots first, so the
## search was predicting a different board than the game would actually
## produce whenever an action queued both.
static func _resolve_pending(gs: GameState) -> void:
	gs.pending_drawn_cards.clear()
	gs.pending_fatigue_damage.clear()
	for _i in 256:  # safety cap: a pathological trigger loop must not hang a search
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return
		gs.resolve_to_quiescence()
		if not gs.has_pending_choice():
			return
		answer_pending_choice(gs)
		gs.pending_drawn_cards.clear()

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
