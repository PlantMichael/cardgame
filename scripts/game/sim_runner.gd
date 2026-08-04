class_name SimRunner
extends RefCounted

const FACTION_KEYS: Array[String] = ["GREEN", "CRIMSON", "BLACK", "ORANGE", "TEAL"]

## RANDOM matches the historical balance-testing behavior (raw card power,
## unaffected by deck-construction quality). ARCHETYPE uses DeckManager's
## archetype-aware builder, so it also captures how much win rate is being
## lost to bad deck construction vs. the cards themselves.
enum DeckMode { RANDOM, ARCHETYPE }

var deck_mode: DeckMode = DeckMode.RANDOM

var stats: Dictionary = {}
var total_games: int = 0
var card_wins: Dictionary = {}    # card_id -> int
var card_games: Dictionary = {}   # card_id -> int
var card_kills: Dictionary = {}   # card_id -> int
var card_damage: Dictionary = {}  # card_id -> int
var card_plays: Dictionary = {}   # card_id -> int

func _init(mode: DeckMode = DeckMode.RANDOM) -> void:
	deck_mode = mode
	for key in FACTION_KEYS:
		stats[key] = {"wins": 0, "losses": 0}

func run_batch(count: int) -> void:
	for _i in count:
		_run_one_game()

func _build_deck(color: CardData.CardColor) -> Array[CardData]:
	if deck_mode == DeckMode.ARCHETYPE:
		return DeckManager.build_archetype_deck(color)
	return DeckManager.build_random_faction_deck(color)

# ── Game runner ─────────────────────────────────────────────────────────────

func _run_one_game() -> void:
	var shuffled := FACTION_KEYS.duplicate()
	shuffled.shuffle()
	var key_a: String = shuffled[0]
	var key_b: String = shuffled[1]
	var color_a := _key_to_color(key_a)
	var color_b := _key_to_color(key_b)

	var deck_a := _force_copies(_build_deck(color_a), "gen_str_003", 2)
	var deck_b := _force_copies(_build_deck(color_b), "gen_str_003", 2)
	if deck_a.is_empty() or deck_b.is_empty():
		return

	var gs := GameState.new("sim_a", "sim_b", deck_a, deck_b)
	var first := "sim_a" if randi() % 2 == 0 else "sim_b"
	gs.start_game(first)
	_resolve_pending(gs)

	for _t in 200:
		if gs.current_phase == GameState.Phase.GAME_OVER:
			break
		var active := gs.active_player_id
		_sim_play_cards(gs, active)
		if gs.current_phase == GameState.Phase.GAME_OVER:
			break
		_sim_attack_phase(gs, active)
		if gs.current_phase == GameState.Phase.GAME_OVER:
			break
		gs.end_turn()
		_resolve_pending(gs)

	total_games += 1

	# Unique card IDs per deck (deduplicate 2x copies)
	var seen_a: Dictionary = {}
	for card in deck_a:
		if card.id not in seen_a:
			seen_a[card.id] = true
			card_games[card.id] = card_games.get(card.id, 0) + 1
	var seen_b: Dictionary = {}
	for card in deck_b:
		if card.id not in seen_b:
			seen_b[card.id] = true
			card_games[card.id] = card_games.get(card.id, 0) + 1

	if gs.winner_id == "sim_a":
		stats[key_a]["wins"] += 1
		stats[key_b]["losses"] += 1
		for id in seen_a:
			card_wins[id] = card_wins.get(id, 0) + 1
	elif gs.winner_id == "sim_b":
		stats[key_b]["wins"] += 1
		stats[key_a]["losses"] += 1
		for id in seen_b:
			card_wins[id] = card_wins.get(id, 0) + 1

func _track_combat(card_id: String, damage: int, is_kill: bool) -> void:
	if damage > 0:
		card_damage[card_id] = card_damage.get(card_id, 0) + damage
	if is_kill:
		card_kills[card_id] = card_kills.get(card_id, 0) + 1

func _do_challenge(challenger: Minion, target: Minion, gs: GameState, enemy: PlayerState) -> void:
	var pre_hp: int = target.current_health
	gs.apply_challenge(challenger, target)
	var still_alive: bool = target in enemy.board
	_track_combat(challenger.data.id,
		pre_hp - (target.current_health if still_alive else 0),
		not still_alive)

func _force_copies(deck: Array[CardData], card_id: String, count: int) -> Array[CardData]:
	var card := CardDatabase.get_card(card_id)
	if card == null:
		return deck
	var out: Array[CardData] = []
	for c in deck:
		if c.id != card_id:
			out.append(c)
	while out.size() > 40 - count:
		out.pop_back()
	for _i in count:
		out.append(card)
	out.shuffle()
	return out

func _key_to_color(key: String) -> CardData.CardColor:
	match key:
		"GREEN":   return CardData.CardColor.GREEN
		"CRIMSON": return CardData.CardColor.CRIMSON
		"BLACK":   return CardData.CardColor.BLACK
		"ORANGE":  return CardData.CardColor.ORANGE
		_:         return CardData.CardColor.TEAL

# ── Pending queue resolver ───────────────────────────────────────────────────

func _resolve_pending(gs: GameState) -> void:
	gs.pending_drawn_cards.clear()
	var changed := true
	while changed:
		changed = false
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return

		while not gs.pending_rummages.is_empty():
			changed = true
			var entry: Dictionary = gs.pending_rummages.pop_front()
			var pid: String = entry["player_id"]
			var p_state: PlayerState = gs.player if pid == gs.player.player_id else gs.opponent
			var allow_equal: bool = p_state.board.any(
				func(m: Minion) -> bool: return m.has_ability(Abilities.RUMMAGE_EQUAL_COST))
			var options := gs.get_rummage_options(
				pid, entry.get("max_cost", -1), entry.get("type_filter", ""), allow_equal)
			if not options.is_empty():
				var chosen: CardData = options[randi() % options.size()]
				var placed := gs.complete_rummage(pid, chosen, entry.get("play_it", false), entry.get("discount", true))
				if placed != null:
					_sim_handle_on_play(placed, gs)
			gs.pending_drawn_cards.clear()
			if gs.current_phase == GameState.Phase.GAME_OVER:
				return

		while not gs.pending_tank_shots.is_empty():
			changed = true
			var pid: String = gs.pending_tank_shots.pop_front()
			var enemy: PlayerState = gs.opponent if pid == gs.player.player_id else gs.player
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
			var enemy: PlayerState = gs.opponent if pid == gs.player.player_id else gs.player
			if not enemy.board.is_empty():
				gs.apply_null(enemy.board[randi() % enemy.board.size()])

		while not gs.pending_buff_friendly_health.is_empty():
			changed = true
			var pid: String = gs.pending_buff_friendly_health.pop_front()
			var p_state: PlayerState = gs.player if pid == gs.player.player_id else gs.opponent
			if not p_state.board.is_empty():
				gs.apply_buff_friendly_health(_pick_health_buff_target(p_state.board))

		while not gs.pending_tank_specialist_buffs.is_empty():
			changed = true
			var pid: String = gs.pending_tank_specialist_buffs.pop_front()
			var p_state: PlayerState = gs.player if pid == gs.player.player_id else gs.opponent
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
			var enemy: PlayerState = gs.opponent if pid == gs.player.player_id else gs.player
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
			var p_state: PlayerState = gs.player if pid == gs.player.player_id else gs.opponent
			var enemy: PlayerState = gs.opponent if pid == gs.player.player_id else gs.player
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
					_do_challenge(yeti, tgts[randi() % tgts.size()], gs, enemy)
			gs.pending_drawn_cards.clear()
			if gs.current_phase == GameState.Phase.GAME_OVER:
				return

# ── Card play ────────────────────────────────────────────────────────────────

func _sim_play_cards(gs: GameState, active_id: String) -> void:
	var p_state: PlayerState = gs.player if active_id == gs.player.player_id else gs.opponent

	var played := true
	while played:
		played = false
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return
		var hand := p_state.hand.duplicate()
		hand.sort_custom(func(a: CardData, b: CardData) -> bool: return a.cost > b.cost)

		for card in hand:
			if card not in p_state.hand:
				continue
			if not p_state.can_play_card(card):
				continue
			if card.card_type == CardData.CardType.CREATURE:
				if p_state.board.size() >= PlayerState.MAX_BOARD_SIZE:
					continue
				var m := gs.play_creature(active_id, card)
				if m != null:
					card_plays[card.id] = card_plays.get(card.id, 0) + 1
					_sim_handle_on_play(m, gs)
					_resolve_pending(gs)
					played = true
					break
			elif card.card_type == CardData.CardType.STRATAGEM:
				var pick := _pick_stratagem(card, gs, active_id)
				if not pick["ready"]:
					continue
				var ok := gs.play_stratagem(active_id, card, pick.get("minion"), pick.get("player_id", ""))
				if ok:
					card_plays[card.id] = card_plays.get(card.id, 0) + 1
					_handle_stratagem_secondary(card, pick.get("minion"), gs, active_id)
					_resolve_pending(gs)
					played = true
					break

# ── On-play effect handler ───────────────────────────────────────────────────

func _sim_handle_on_play(m: Minion, gs: GameState) -> void:
	if gs.current_phase == GameState.Phase.GAME_OVER:
		return
	var friendly: PlayerState = gs.player if m.owner_id == gs.player.player_id else gs.opponent
	var enemy: PlayerState = gs.opponent if m.owner_id == gs.player.player_id else gs.player

	for ability in m.abilities:
		if Abilities.is_on_play_damage(ability):
			var dmg := Abilities.get_on_play_damage_value(ability)
			if not enemy.board.is_empty():
				var tgt := _pick_removal(enemy.board.duplicate(), dmg)
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
		var tgt := _pick_challenge(enemy.board, m)
		if tgt != null:
			_do_challenge(m, tgt, gs, enemy)
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
			_do_challenge(m, e, gs, enemy)
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return

	if m not in friendly.board:
		return

	if m.has_ability(Abilities.ON_PLAY_CHALLENGE_WIN_BUFF) and not enemy.board.is_empty():
		var tgt := _pick_challenge(enemy.board, m)
		if tgt != null:
			_do_challenge(m, tgt, gs, enemy)
			if m in friendly.board and tgt not in enemy.board:
				m.current_attack += 1
				m.current_health += 1
				m.max_health += 1
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
			var tgt := _pick_challenge(enemy.board, yeti)
			if tgt != null:
				_do_challenge(yeti, tgt, gs, enemy)
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
				gs.apply_pilot(m, mechs[randi() % mechs.size()], friendly)
			break

# ── Attack phase ─────────────────────────────────────────────────────────────

func _sim_attack_phase(gs: GameState, active_id: String) -> void:
	var p_state: PlayerState = gs.player if active_id == gs.player.player_id else gs.opponent
	var enemy: PlayerState = gs.opponent if active_id == gs.player.player_id else gs.player
	var enemy_id := enemy.player_id

	var made_attack := true
	while made_attack:
		made_attack = false
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return

		var attackers: Array[Minion] = []
		for m in p_state.board:
			if m.can_attack():
				attackers.append(m)
		if attackers.is_empty():
			break

		var guardians := enemy.get_guardian_minions()
		var raw: Array[Minion] = guardians if not guardians.is_empty() else enemy.board.duplicate()
		var targets: Array[Minion] = []
		for m in raw:
			if not m.has_ability(Abilities.COMBAT_IMMUNE) and not m.has_ability(Abilities.AMBUSH):
				targets.append(m)

		if targets.is_empty():
			if not guardians.is_empty():
				break  # Guardians present but all ethereal/ambush — stall
			for attacker in attackers:
				var pre_face_hp: int = enemy.hero_health
				gs.attack(attacker, null, enemy_id)
				_track_combat(attacker.data.id, pre_face_hp - max(0, enemy.hero_health), false)
				_resolve_pending(gs)
				if gs.current_phase == GameState.Phase.GAME_OVER:
					return
			made_attack = true
			continue

		var best_score := -999
		var best_atk: Minion = null
		var best_tgt: Minion = null

		for attacker in attackers:
			for tgt in targets:
				var sc := _score_trade(attacker, tgt)
				if sc > best_score:
					best_score = sc
					best_atk = attacker
					best_tgt = tgt
			if guardians.is_empty():
				var face := _face_score(enemy.hero_health, p_state.board.size(), enemy.board.size())
				var weighted := face + attacker.current_attack / 2
				if weighted > best_score:
					best_score = weighted
					best_atk = attacker
					best_tgt = null

		if best_score <= 0 and guardians.is_empty():
			break
		if best_atk == null:
			break

		if best_tgt != null:
			var pre_hp: int = best_tgt.current_health
			gs.attack(best_atk, best_tgt)
			var still_alive: bool = best_tgt in enemy.board
			_track_combat(best_atk.data.id,
				pre_hp - (best_tgt.current_health if still_alive else 0),
				not still_alive)
		else:
			var pre_face: int = enemy.hero_health
			gs.attack(best_atk, null, enemy_id)
			_track_combat(best_atk.data.id, pre_face - max(0, enemy.hero_health), false)
		_resolve_pending(gs)
		made_attack = true

# ── Stratagem targeting ──────────────────────────────────────────────────────

func _pick_stratagem(card: CardData, gs: GameState, acting_id: String) -> Dictionary:
	var result := {"ready": false, "minion": null, "player_id": ""}
	var friendly: PlayerState = gs.player if acting_id == gs.player.player_id else gs.opponent
	var enemy: PlayerState = gs.opponent if acting_id == gs.player.player_id else gs.player

	var enemy_tgts: Array[Minion] = []
	for m in enemy.board:
		if not m.has_ability(Abilities.CLOAKED) and not m.has_ability(Abilities.AMBUSH):
			enemy_tgts.append(m)
	var friendly_tgts: Array[Minion] = []
	for m in friendly.board:
		if not m.has_ability(Abilities.CLOAKED):
			friendly_tgts.append(m)

	match card.effect:
		"deal_damage":
			if not enemy_tgts.is_empty():
				result["minion"] = _pick_removal(enemy_tgts, card.effect_value)
				result["ready"] = true
			elif enemy.get_guardian_minions().is_empty():
				result["player_id"] = enemy.player_id
				result["ready"] = true
		"buff_creature", "give_ability":
			if not friendly_tgts.is_empty():
				result["minion"] = friendly_tgts[randi() % friendly_tgts.size()]
				result["ready"] = true
		"buff_health":
			if not friendly_tgts.is_empty():
				result["minion"] = friendly_tgts[randi() % friendly_tgts.size()]
				result["ready"] = true
		"destroy_all_creatures":
			var ep := 0
			for m in enemy.board:
				ep += m.current_attack + m.current_health
			var fp := 0
			for m in friendly.board:
				fp += m.current_attack + m.current_health
			result["ready"] = not enemy.board.is_empty() and ep >= fp
		"deal_damage_all_creatures", "deal_damage_all_enemy":
			result["ready"] = not enemy.board.is_empty()
		"buff_all_friendly_attack":
			result["ready"] = not friendly.board.is_empty()
		"blood_transfusion":
			if not enemy_tgts.is_empty():
				result["minion"] = _pick_removal(enemy_tgts, card.effect_value)
				result["ready"] = true
		"sanguine":
			var sources: Array[Minion] = []
			for m in friendly_tgts:
				if m.current_health > card.effect_value + 1:
					sources.append(m)
			if sources.size() >= 2 or (not sources.is_empty() and friendly_tgts.size() >= 2):
				result["minion"] = sources[randi() % sources.size()] if not sources.is_empty() else friendly_tgts[0]
				result["ready"] = true
		"heal":
			if not friendly_tgts.is_empty():
				var damaged: Array[Minion] = []
				for m in friendly_tgts:
					if m.current_health < m.max_health:
						damaged.append(m)
				if not damaged.is_empty():
					result["minion"] = _pick_lowest_health(damaged)
				else:
					result["minion"] = _pick_health_buff_target(friendly_tgts)
				result["ready"] = true
		"force_challenge", "poke_bear":
			for m in friendly.board:
				if m.has_ability(Abilities.YETI) and not enemy.board.is_empty():
					result["minion"] = m
					result["ready"] = true
					break
		"eject_pilot":
			result["ready"] = false
		"eject_all_pilots":
			result["ready"] = false
		"give_mech_shielded_temp":
			var best: Minion = null
			for m in friendly.board:
				if m.has_ability(Abilities.MECH):
					if best == null or m.current_health > best.current_health:
						best = m
			if best != null:
				result["minion"] = best
				result["ready"] = true

	return result

func _handle_stratagem_secondary(card: CardData, target: Minion, gs: GameState, acting_id: String) -> void:
	var friendly: PlayerState = gs.player if acting_id == gs.player.player_id else gs.opponent
	var enemy: PlayerState = gs.opponent if acting_id == gs.player.player_id else gs.player

	if card.effect == "blood_transfusion" and not friendly.board.is_empty():
		gs.apply_heal_buff(_pick_health_buff_target(friendly.board), card.effect_value)

	if card.effect == "sanguine" and target != null:
		var others: Array[Minion] = []
		for m in friendly.board:
			if m != target:
				others.append(m)
		if not others.is_empty():
			gs.apply_heal_buff(_pick_health_buff_target(others), card.effect_value)

	if card.effect in ["force_challenge", "poke_bear"] and target != null:
		var yeti: Minion = target
		if yeti in friendly.board and yeti.has_ability(Abilities.YETI) and not enemy.board.is_empty():
			var non_ambush: Array[Minion] = []
			for m in enemy.board:
				if not m.has_ability(Abilities.AMBUSH):
					non_ambush.append(m)
			if not non_ambush.is_empty():
				var tgt := _pick_challenge(non_ambush, yeti)
				if tgt != null:
					_do_challenge(yeti, tgt, gs, enemy)
					if card.effect == "force_challenge" and card.effect_value > 0 \
							and tgt not in enemy.board and yeti in friendly.board:
						yeti.current_attack += card.effect_value
						yeti.current_health += card.effect_value
						yeti.max_health += card.effect_value

# ── Scoring helpers ──────────────────────────────────────────────────────────

func _score_trade(attacker: Minion, target: Minion) -> int:
	var we_kill    := attacker.current_attack >= target.current_health
	var we_survive := attacker.current_health > target.current_attack
	if we_kill and we_survive:
		return target.current_attack * 2 + target.current_health + 10
	elif we_kill:
		return (target.current_attack + target.current_health) - (attacker.current_attack + attacker.current_health) + 1
	elif we_survive:
		return -5
	else:
		return -15

func _face_score(enemy_hp: int, my_board: int, their_board: int) -> int:
	var s := 0
	if enemy_hp <= 8:    s = 30
	elif enemy_hp <= 12: s = 18
	elif enemy_hp <= 16: s = 8
	elif enemy_hp <= 20: s = 3
	if my_board > their_board + 1:
		s += 6
	return s

func _pick_lowest_health(minions: Array[Minion]) -> Minion:
	var lowest := minions[0]
	for m in minions:
		if m.current_health < lowest.current_health:
			lowest = m
	return lowest

## Mirrors AIController._pick_health_buff_target: Heal-to-Draw minions always
## take priority (free card), then Transform-at-max-health minions closest to
## their threshold, then fall back to the weakest body on board.
func _pick_health_buff_target(minions: Array[Minion]) -> Minion:
	if minions.is_empty():
		return null
	for m in minions:
		if m.has_ability(Abilities.HEAL_TO_DRAW):
			return m
	var best_transform: Minion = null
	var best_gap := 999
	for m in minions:
		for ab in m.abilities:
			if Abilities.is_transform_at_max_health(ab):
				var gap: int = Abilities.get_transform_health_threshold(ab) - m.max_health
				if gap >= 0 and gap < best_gap:
					best_gap = gap
					best_transform = m
				break
	if best_transform != null:
		return best_transform
	return _pick_lowest_health(minions)

func _pick_removal(minions: Array[Minion], damage: int) -> Minion:
	var best_kill: Minion = null
	var highest_atk: Minion = null
	for m in minions:
		if m.current_health <= damage:
			if best_kill == null or m.current_attack > best_kill.current_attack:
				best_kill = m
		if highest_atk == null or m.current_attack > highest_atk.current_attack:
			highest_atk = m
	return best_kill if best_kill != null else highest_atk

func _pick_challenge(minions: Array[Minion], challenger: Minion) -> Minion:
	var best: Minion = null
	var best_score := -999
	for m in minions:
		if m.has_ability(Abilities.AMBUSH):
			continue
		var wk := challenger.current_attack >= m.current_health
		var ws := challenger.current_health > m.current_attack
		var sc: int
		if wk and ws:      sc = m.current_attack * 2 + m.current_health + 10
		elif wk:           sc = (m.current_attack + m.current_health) - (challenger.current_attack + challenger.current_health) + 1
		elif ws:           sc = -5
		else:              sc = -15
		if sc > best_score:
			best_score = sc
			best = m
	return best
