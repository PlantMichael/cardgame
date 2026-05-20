class_name GameState
extends RefCounted

enum Phase { WAITING, PLAYER_TURN, OPPONENT_TURN, GAME_OVER }

var player: PlayerState
var opponent: PlayerState
var current_phase: Phase = Phase.WAITING
var active_player_id: String = ""
var turn_number: int = 0
var winner_id: String = ""
var pending_drawn_cards: Array[CardData] = []
var pending_rummages: Array[Dictionary] = []
var pending_tank_shots: Array[String] = []
var pending_nulls: Array[Dictionary] = []
var pending_overwatch_challenges: Array[String] = []
var pending_buff_friendly_health: Array[String] = []
var _opening_hand_dealt: bool = false

func _init(local_player_id: String, opponent_player_id: String,
		   player_deck: Array[CardData], opponent_deck: Array[CardData]) -> void:
	player = PlayerState.new(local_player_id, player_deck)
	opponent = PlayerState.new(opponent_player_id, opponent_deck)

func start_game(first_player_id: String) -> void:
	active_player_id = first_player_id
	current_phase = Phase.PLAYER_TURN if first_player_id == player.player_id \
					else Phase.OPPONENT_TURN
	turn_number = 1
	for i in 3:
		player.draw_card()
		opponent.draw_card()
	_begin_turn()
	_opening_hand_dealt = true

func _begin_turn() -> void:
	var active = _get_active_player()
	active.gain_mana_crystal()
	var drawn := active.draw_card()
	if _opening_hand_dealt and drawn != null and active.player_id == player.player_id:
		pending_drawn_cards.append(drawn)
	active.reset_for_new_turn()

func end_turn() -> void:
	if active_player_id == player.player_id:
		active_player_id = opponent.player_id
		current_phase = Phase.OPPONENT_TURN
	else:
		active_player_id = player.player_id
		current_phase = Phase.PLAYER_TURN
		turn_number += 1
	_begin_turn()

# --- Actions ---

func play_creature(acting_player_id: String, card: CardData) -> Minion:
	var acting = _get_player_by_id(acting_player_id)
	if not acting.play_card_from_hand(card):
		return null
	var minion = Minion.new(card, acting_player_id)
	acting.place_minion(minion)
	if minion.has_ability(Abilities.RECON):
		var drawn := acting.draw_card()
		if drawn != null and acting.player_id == player.player_id:
			pending_drawn_cards.append(drawn)
	if minion.has_ability(Abilities.TANK):
		_get_player_by_id(_opponent_id(acting_player_id)).hero_health -= 1
		_check_win_condition()
	for i in minion.abilities.count(Abilities.RUMMAGE):
		pending_rummages.append({"player_id": acting_player_id, "max_cost": card.cost, "type_filter": ""})
	if minion.has_ability(Abilities.RUMMAGE_SPELL):
		pending_rummages.append({"player_id": acting_player_id, "max_cost": -1, "type_filter": "stratagem"})
	if minion.has_ability(Abilities.NULL):
		pending_nulls.append({"player_id": acting_player_id, "source": minion.data.card_name})
	if minion.has_ability(Abilities.ON_PLAY_BUFF_FRIENDLY_HEALTH):
		pending_buff_friendly_health.append(acting_player_id)
	if minion.has_ability(Abilities.ON_PLAY_RUMMAGE_BUFF) and card.rummage_count > 0:
		minion.current_attack += card.rummage_count
		minion.current_health += card.rummage_count
		minion.max_health += card.rummage_count
		_try_apothecary_bonus(acting_player_id, minion)
	return minion

func apply_buff_friendly_health(target: Minion) -> void:
	target.current_health += 1
	target.max_health += 1
	_try_apothecary_bonus(target.owner_id, target)

func apply_null(target: Minion) -> void:
	target.abilities.clear()
	target.is_nulled = true

func play_stratagem(acting_player_id: String, card: CardData,
					target_minion: Minion = null, target_player_id: String = "") -> bool:
	if target_minion != null and target_minion.has_ability(Abilities.SAFEGUARD):
		return false
	var acting = _get_player_by_id(acting_player_id)
	if not acting.play_card_from_hand(card):
		return false
	acting.graveyard.append(card)
	_apply_stratagem(card, target_minion, target_player_id, acting_player_id)
	return true

func attack(attacker: Minion, target_minion: Minion = null,
			target_player_id: String = "") -> void:
	if not attacker.can_attack():
		return

	var defending = _get_player_by_id(_opponent_id(attacker.owner_id))
	var guardians = defending.get_guardian_minions()
	if not guardians.is_empty() and target_minion not in guardians:
		return

	attacker.has_attacked = true
	attacker.transform_counter += 1

	if attacker.has_ability(Abilities.ATTACK_BUFF_FRIENDLY_HEALTH):
		var acting = _get_player_by_id(attacker.owner_id)
		if not acting.board.is_empty():
			var buff_target = acting.board[randi() % acting.board.size()]
			buff_target.current_health += 1
			buff_target.max_health += 1
			_try_apothecary_bonus(attacker.owner_id, buff_target)

	if target_minion:
		if target_minion.has_ability(Abilities.WHEN_ATTACKED_BUFF_FRIENDLY):
			var defender = _get_player_by_id(target_minion.owner_id)
			for m in defender.board:
				m.current_health += 1
				m.max_health += 1
			for m in defender.board.duplicate():
				_try_apothecary_bonus(target_minion.owner_id, m)
		if not target_minion.has_ability(Abilities.COMBAT_IMMUNE):
			target_minion.take_damage(attacker.current_attack)
		if not attacker.has_ability(Abilities.COMBAT_IMMUNE):
			attacker.take_damage(target_minion.current_attack)
		_remove_dead_minions()
		var acting = _get_player_by_id(attacker.owner_id)
		if attacker in acting.board:
			_try_transform(attacker, acting)
	elif target_player_id != "":
		var target_player = _get_player_by_id(target_player_id)
		target_player.hero_health -= attacker.current_attack
		_try_transform(attacker, _get_player_by_id(attacker.owner_id))

	_check_win_condition()

func apply_challenge(challenger: Minion, target: Minion) -> void:
	var was_yeti = challenger.has_ability(Abilities.YETI)
	var owner_id = challenger.owner_id
	if not target.has_ability(Abilities.COMBAT_IMMUNE):
		target.take_damage(challenger.current_attack)
	if not challenger.has_ability(Abilities.COMBAT_IMMUNE):
		challenger.take_damage(target.current_attack)
	_remove_dead_minions()
	if was_yeti:
		for m in _get_player_by_id(owner_id).board:
			if m.has_ability(Abilities.ON_YETI_CHALLENGE_BUFF):
				m.current_attack += 1
				m.current_health += 1
				m.max_health += 1
				_try_apothecary_bonus(owner_id, m)
	_check_win_condition()

func apply_on_play_damage(target: Minion, damage: int) -> void:
	target.take_damage(damage)
	_remove_dead_minions()
	_check_win_condition()

func apply_pilot(pilot_minion: Minion, target_mech: Minion, pilot_owner: PlayerState) -> void:
	for ability in pilot_minion.abilities:
		if Abilities.is_pilot(ability):
			target_mech.current_attack += Abilities.get_pilot_attack(ability)
			var hp_bonus = Abilities.get_pilot_health(ability)
			target_mech.current_health += hp_bonus
			target_mech.max_health += hp_bonus
			target_mech.is_piloted = true
			if hp_bonus > 0:
				_try_apothecary_bonus(target_mech.owner_id, target_mech)
			_try_health_transform(target_mech)
			break
	pilot_owner.remove_minion(pilot_minion)
	pilot_owner.graveyard.append(pilot_minion.data)

func apply_transform_choice(minion: Minion, chosen_id: String) -> void:
	var new_data = CardDatabase.get_card(chosen_id)
	if new_data == null:
		return
	var damage_taken = minion.max_health - minion.current_health
	minion.data = new_data
	minion.current_attack = new_data.attack
	minion.max_health = new_data.health
	minion.current_health = max(1, new_data.health - damage_taken)
	minion.abilities = new_data.abilities.duplicate()
	if minion.has_ability(Abilities.RUSH):
		minion.is_exhausted = false
	minion.is_newly_transformed = true
	_try_mirror_transform(new_data, minion, _get_player_by_id(minion.owner_id))

func _try_health_transform(minion: Minion) -> void:
	for ability in minion.abilities:
		if not Abilities.is_transform_at_max_health(ability):
			continue
		if minion.max_health < Abilities.get_transform_health_threshold(ability):
			return
		if minion.data.transform_into.is_empty():
			return
		var new_data = CardDatabase.get_card(minion.data.transform_into)
		if new_data == null:
			return
		var damage_taken = minion.max_health - minion.current_health
		minion.data = new_data
		minion.current_attack = new_data.attack
		minion.max_health = new_data.health
		minion.current_health = max(1, new_data.health - damage_taken)
		minion.abilities = new_data.abilities.duplicate()
		if minion.has_ability(Abilities.RUSH):
			minion.is_exhausted = false
		minion.is_newly_transformed = true
		_try_mirror_transform(new_data, minion, _get_player_by_id(minion.owner_id))
		return

func _try_transform(minion: Minion, owner: PlayerState) -> void:
	for ability in minion.abilities:
		if not Abilities.is_transform(ability):
			continue
		if minion.transform_counter < Abilities.get_transform_threshold(ability):
			return
		if minion.data.transform_into.is_empty():
			return
		var new_data = CardDatabase.get_card(minion.data.transform_into)
		if new_data == null:
			return
		var damage_taken = minion.max_health - minion.current_health
		minion.data = new_data
		minion.current_attack = new_data.attack
		minion.max_health = new_data.health
		minion.current_health = max(1, new_data.health - damage_taken)
		minion.abilities = new_data.abilities.duplicate()
		minion.transform_counter = 0
		if minion.has_ability(Abilities.RUSH):
			minion.is_exhausted = false
		minion.is_newly_transformed = true
		_try_mirror_transform(new_data, minion, owner)
		return

func _apply_stratagem(card: CardData, target_minion: Minion,
					  target_player_id: String, acting_player_id: String = "") -> void:
	match card.effect:
		"deal_damage":
			if target_minion:
				target_minion.take_damage(card.effect_value)
				_remove_dead_minions()
			elif target_player_id != "":
				var target = _get_player_by_id(target_player_id)
				target.hero_health -= card.effect_value
		"buff_creature":
			if target_minion:
				target_minion.current_attack += card.effect_value
				target_minion.current_health += card.effect_value
				target_minion.max_health += card.effect_value
				_try_apothecary_bonus(target_minion.owner_id, target_minion)
				_try_health_transform(target_minion)
		"buff_health":
			if target_minion:
				target_minion.current_health += card.effect_value
				target_minion.max_health += card.effect_value
				_try_apothecary_bonus(target_minion.owner_id, target_minion)
				_try_health_transform(target_minion)
		"give_ability":
			if target_minion and not card.abilities.is_empty():
				var ability: String = card.abilities[0]
				if ability not in target_minion.abilities:
					target_minion.abilities.append(ability)
		"deal_damage_all_creatures":
			for p in [player, opponent]:
				for minion in p.board.duplicate():
					minion.take_damage(card.effect_value)
			_remove_dead_minions()
		"buff_all_friendly_attack":
			if acting_player_id != "":
				var acting = _get_player_by_id(acting_player_id)
				for m in acting.board:
					m.current_attack += card.effect_value
		"poke_bear":
			if target_minion:
				target_minion.take_damage(card.effect_value)
				_remove_dead_minions()
				_check_win_condition()

func _remove_dead_minions() -> void:
	for p in [player, opponent]:
		for minion in p.board.duplicate():
			if minion.is_dead():
				var idx = p.board.find(minion)
				p.remove_minion(minion)
				p.graveyard.append(minion.data)
				var enemy = _get_player_by_id(_opponent_id(p.player_id))
				var death_result := Abilities.trigger_death(minion, p, idx, enemy)
				if p.player_id == player.player_id:
					pending_drawn_cards.append_array(death_result["drawn"])
				for _i in death_result["tank_shots"]:
					pending_tank_shots.append(p.player_id)
				if minion.has_ability(Abilities.RUMMAGE_ON_DEATH):
					pending_rummages.append({"player_id": p.player_id, "max_cost": minion.data.cost, "type_filter": ""})
				if minion.has_ability(Abilities.RUMMAGE_MECH_ON_DEATH):
					pending_rummages.append({"player_id": p.player_id, "max_cost": -1, "type_filter": "mech"})
				if minion.has_ability(Abilities.DEATHRATTLE_RETURN_STRATAGEM):
					pending_rummages.append({"player_id": p.player_id, "max_cost": -1, "type_filter": "stratagem"})
				if minion.has_ability(Abilities.YETI):
					for watcher in p.board:
						if watcher.has_ability(Abilities.ON_YETI_DEATH_CHALLENGE):
							pending_overwatch_challenges.append(p.player_id)
							break

func _check_win_condition() -> void:
	if opponent.is_dead():
		winner_id = player.player_id
		current_phase = Phase.GAME_OVER
	elif player.is_dead():
		winner_id = opponent.player_id
		current_phase = Phase.GAME_OVER

func get_rummage_options(player_id: String, max_cost: int = -1, type_filter: String = "") -> Array[CardData]:
	var p = _get_player_by_id(player_id)
	var seen_ids: Array[String] = []
	var options: Array[CardData] = []
	for card in p.graveyard:
		if max_cost >= 0 and card.cost >= max_cost:
			continue
		if type_filter == "creature" and card.card_type != CardData.CardType.CREATURE:
			continue
		if type_filter == "stratagem" and card.card_type != CardData.CardType.STRATAGEM:
			continue
		if type_filter == "mech" and Abilities.MECH not in card.abilities:
			continue
		if card.id not in seen_ids:
			seen_ids.append(card.id)
			options.append(card)
	return options

func complete_rummage(player_id: String, card: CardData) -> void:
	var p = _get_player_by_id(player_id)
	for i in p.graveyard.size():
		if p.graveyard[i].id == card.id:
			p.graveyard.remove_at(i)
			break
	if p.hand.size() < PlayerState.MAX_HAND_SIZE:
		card.cost_modifier = -1
		card.rummage_count += 1
		p.hand.append(card)
	for m in p.board:
		if m.has_ability(Abilities.RUMMAGE_BUFF):
			m.current_health += 1
			m.max_health += 1
			_try_apothecary_bonus(p.player_id, m)
	for m in p.board:
		if m.has_ability(Abilities.RUMMAGE_DRAW):
			var drawn = p.draw_card()
			if drawn != null and p.player_id == player.player_id:
				pending_drawn_cards.append(drawn)

func is_local_player_turn() -> bool:
	return active_player_id == player.player_id

func _try_apothecary_bonus(owner_id: String, target: Minion) -> void:
	var owner = _get_player_by_id(owner_id)
	for m in owner.board:
		if m.has_ability(Abilities.APOTHECARY):
			target.current_health += 1
			target.max_health += 1
			return

func _try_mirror_transform(new_data: CardData, transforming: Minion, owner: PlayerState) -> void:
	var candidates: Array[Minion] = []
	for m in owner.board:
		if m != transforming and m.has_ability(Abilities.MIRROR_TRANSFORM):
			candidates.append(m)
	for m in candidates:
		if m not in owner.board:
			continue
		var target_data: CardData = new_data
		if not m.data.transform_into.is_empty():
			var own_target = CardDatabase.get_card(m.data.transform_into)
			if own_target != null:
				target_data = own_target
		var damage_taken = m.max_health - m.current_health
		m.data = target_data
		m.current_attack = target_data.attack
		m.max_health = target_data.health
		m.current_health = max(1, target_data.health - damage_taken)
		m.abilities = target_data.abilities.duplicate()
		if m.has_ability(Abilities.RUSH):
			m.is_exhausted = false
		m.is_newly_transformed = true

func _get_active_player() -> PlayerState:
	return _get_player_by_id(active_player_id)

func _get_player_by_id(id: String) -> PlayerState:
	return player if id == player.player_id else opponent

func _opponent_id(id: String) -> String:
	return opponent.player_id if id == player.player_id else player.player_id
