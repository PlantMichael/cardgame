class_name SimRunner
extends RefCounted

const FACTION_KEYS: Array[String] = ["GREEN", "CRIMSON", "BLACK", "ORANGE", "TEAL"]

## RANDOM matches the historical balance-testing behavior (raw card power,
## unaffected by deck-construction quality). ARCHETYPE uses DeckManager's
## archetype-aware builder, so it also captures how much win rate is being
## lost to bad deck construction vs. the cards themselves.
enum DeckMode { RANDOM, ARCHETYPE }

var deck_mode: DeckMode = DeckMode.RANDOM

## MCTSEngine level both sides search at (see mcts_ai.gd's AI_LEVEL_CONFIG).
## Higher is stronger/more realistic balance data but proportionally slower —
## level 10 does ~3x the iterations and one extra look-ahead ply versus
## level 5, so a full game can run into the minute-plus range.
var ai_level: int = 10

var stats: Dictionary = {}
var total_games: int = 0
var card_wins: Dictionary = {}    # card_id -> int
var card_games: Dictionary = {}   # card_id -> int
var card_kills: Dictionary = {}   # card_id -> int
var card_damage: Dictionary = {}  # card_id -> int
var card_plays: Dictionary = {}   # card_id -> int

func _init(mode: DeckMode = DeckMode.RANDOM, level: int = 10) -> void:
	deck_mode = mode
	ai_level = clampi(level, 1, 10)
	for key in FACTION_KEYS:
		stats[key] = {"wins": 0, "losses": 0}

func run_batch(count: int) -> void:
	for _i in count:
		await _run_one_game()

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
		await _sim_play_turn(gs, gs.active_player_id)
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
				gs.apply_buff_friendly_health(AIHeuristics.pick_health_buff_target(p_state.board))

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

# ── Turn driver (MCTSEngine for both sides, level configurable via ai_level) ──

## Balance stats are only meaningful if both sides play close to their best,
## so simulated games are driven by the same search engine real matches use
## (at `ai_level` for both sides) instead of the older one-ply greedy policy
## — a card's measured win rate should reflect strong play, not mediocre play.
## `ai_level` defaults to 10 (strongest, slowest) but is tunable since level
## 10 on both sides can push a single game past a minute — see main.gd's
## Simulation screen difficulty picker.
## This mirrors HeadlessTurn's atomic action loop, but keeps SimRunner's own
## per-card kill/damage/play tracking wired directly around each action.
func _sim_play_turn(gs: GameState, active_id: String) -> void:
	var engine := MCTSEngine.new(active_id, ai_level)
	for _i in 60:  # safety cap; a real turn never needs anywhere near this many actions
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return
		# MCTSEngine.choose_action() itself yields every few iterations now,
		# so a single call no longer blocks rendering/input for its whole
		# ~1-1.5s (level 10) — driving both sides at level 10 back-to-back no
		# longer stalls the engine for a whole game's worth of searches.
		var action := await engine.choose_action(gs)
		match action["type"]:
			"play_creature":
				var card: CardData = action["card"]
				var m := gs.play_creature(active_id, card)
				if m != null:
					card_plays[card.id] = card_plays.get(card.id, 0) + 1
					_sim_handle_on_play(m, gs)
					_resolve_pending(gs)
			"play_stratagem":
				var card: CardData = action["card"]
				var target_minion: Minion = action.get("minion")
				var ok := gs.play_stratagem(active_id, card, target_minion, action.get("player_id", ""))
				if ok:
					card_plays[card.id] = card_plays.get(card.id, 0) + 1
					_handle_stratagem_secondary(card, target_minion, gs, active_id)
					_resolve_pending(gs)
			"attack":
				var attacker: Minion = action["attacker"]
				var target: Minion = action.get("target")
				var target_player_id: String = action.get("target_player_id", "")
				if target != null:
					var enemy: PlayerState = gs._get_player_by_id(gs._opponent_id(active_id))
					var pre_hp: int = target.current_health
					gs.attack(attacker, target)
					var still_alive: bool = target in enemy.board
					_track_combat(attacker.data.id,
						pre_hp - (target.current_health if still_alive else 0), not still_alive)
				else:
					var enemy_p := gs._get_player_by_id(target_player_id)
					var pre_face: int = enemy_p.hero_health
					gs.attack(attacker, null, target_player_id)
					_track_combat(attacker.data.id, pre_face - maxi(0, enemy_p.hero_health), false)
				_resolve_pending(gs)
			"end_turn":
				return
		if gs.current_phase == GameState.Phase.GAME_OVER:
			return
		engine.advance_after_real_action(gs)

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
		var tgt := AIHeuristics.pick_challenge_target(enemy.board, m)
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
		var tgt := AIHeuristics.pick_challenge_target(enemy.board, m)
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
			var tgt := AIHeuristics.pick_challenge_target(enemy.board, yeti)
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

func _handle_stratagem_secondary(card: CardData, target: Minion, gs: GameState, acting_id: String) -> void:
	var friendly: PlayerState = gs.player if acting_id == gs.player.player_id else gs.opponent
	var enemy: PlayerState = gs.opponent if acting_id == gs.player.player_id else gs.player

	if card.effect == "blood_transfusion" and not friendly.board.is_empty():
		gs.apply_heal_buff(AIHeuristics.pick_health_buff_target(friendly.board), card.effect_value)

	if card.effect == "sanguine" and target != null:
		var others: Array[Minion] = []
		for m in friendly.board:
			if m != target:
				others.append(m)
		if not others.is_empty():
			gs.apply_heal_buff(AIHeuristics.pick_health_buff_target(others), card.effect_value)

	if card.effect in ["force_challenge", "poke_bear"] and target != null:
		var yeti: Minion = target
		if yeti in friendly.board and yeti.has_ability(Abilities.YETI) and not enemy.board.is_empty():
			var non_ambush: Array[Minion] = []
			for m in enemy.board:
				if not m.has_ability(Abilities.AMBUSH):
					non_ambush.append(m)
			if not non_ambush.is_empty():
				var tgt := AIHeuristics.pick_challenge_target(non_ambush, yeti)
				if tgt != null:
					_do_challenge(yeti, tgt, gs, enemy)
					if card.effect == "force_challenge" and card.effect_value > 0 \
							and tgt not in enemy.board and yeti in friendly.board:
						yeti.current_attack += card.effect_value
						yeti.current_health += card.effect_value
						yeti.max_health += card.effect_value

# Scoring/target-selection now lives in AIHeuristics (shared with
# AIController and MCTSEngine) — see score_trade, face_pressure_score,
# pick_lowest_health, pick_health_buff_target, pick_best_removal_target,
# pick_challenge_target.
