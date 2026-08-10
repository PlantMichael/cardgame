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
var pending_fatigue_damage: Array[String] = []
var pending_rummages: Array[Dictionary] = []
var pending_tank_shots: Array[String] = []
var pending_nulls: Array[Dictionary] = []
var pending_overwatch_challenges: Array[String] = []
var pending_buff_friendly_health: Array[String] = []
var pending_tank_specialist_buffs: Array[String] = []
var pending_on_reinforce_damages: Array[Dictionary] = []
var temp_shielded: Array[Dictionary] = []
var growvin_granted: Array[Dictionary] = []
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
	var was_deck_empty: bool = active.deck.is_empty()
	var drawn := active.draw_card()
	if was_deck_empty:
		pending_fatigue_damage.append(active.player_id)
	elif _opening_hand_dealt and drawn != null and active.player_id == player.player_id:
		pending_drawn_cards.append(drawn)
	active.reset_for_new_turn()
	_check_win_condition()

func end_turn() -> void:
	_expire_temp_shields_for(active_player_id)
	_apply_rejuvenate(active_player_id)
	_apply_feast_attendant(active_player_id)
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
	Abilities.fire_on_play(minion, acting, self)
	if minion.has_ability(Abilities.MECH) and minion in acting.board:
		var has_growvin := false
		for _gm in acting.board:
			if _gm != minion and _gm.has_ability(Abilities.GROWVIN_AURA):
				has_growvin = true
				break
		if has_growvin:
			_apply_growvin_aura_to_mech(minion, acting_player_id)
	return minion

func apply_buff_friendly_health(target: Minion) -> void:
	var pre := target.current_health
	target.current_health += 1
	target.max_health += 1
	_try_heal_to_draw(target, target.current_health - pre)
	_try_apothecary_bonus(target.owner_id, target)
	_try_health_transform(target)

func apply_heal_buff(target: Minion, amount: int) -> void:
	var pre := target.current_health
	target.current_health += amount
	target.max_health += amount
	_try_heal_to_draw(target, target.current_health - pre)
	_try_apothecary_bonus(target.owner_id, target)
	_try_health_transform(target)

func apply_tank_specialist_buff(target: Minion) -> void:
	target.current_attack += 1
	target.current_health += 2
	target.max_health += 2
	_try_apothecary_bonus(target.owner_id, target)
	_try_health_transform(target)

func apply_null(target: Minion) -> void:
	target.abilities.clear()
	target.is_nulled = true

func play_stratagem(acting_player_id: String, card: CardData,
					target_minion: Minion = null, target_player_id: String = "") -> bool:
	if target_minion != null and card.effect != "eject_pilot":
		if target_minion.has_ability(Abilities.CLOAKED) and target_minion.owner_id != acting_player_id:
			return false
		if target_minion.has_ability(Abilities.AMBUSH) and target_minion.owner_id != acting_player_id:
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
	if target_minion != null and target_minion.has_ability(Abilities.AMBUSH):
		return

	attacker.has_attacked = true
	attacker.transform_counter += 1
	if attacker.has_ability(Abilities.AMBUSH):
		attacker.abilities.erase(Abilities.AMBUSH)

	var attacker_shield := _get_shield_value(attacker)
	var attacker_amp := _get_enemy_damage_amp(attacker.owner_id)

	if target_minion:
		var target_shield := _get_shield_value(target_minion)
		if not target_minion.has_ability(Abilities.COMBAT_IMMUNE):
			target_minion.take_damage(maxi(0, attacker.current_attack + attacker_amp - target_shield))
			if attacker.has_ability(Abilities.VOIDTOUCH):
				target_minion.current_health = mini(target_minion.current_health, 0)
		if not attacker.has_ability(Abilities.COMBAT_IMMUNE):
			attacker.take_damage(maxi(0, target_minion.current_attack - attacker_shield))
		Abilities.fire_on_attack(attacker, _get_player_by_id(attacker.owner_id), self)
		Abilities.fire_on_defend(target_minion, _get_player_by_id(target_minion.owner_id), self)
		_remove_dead_minions()
		var acting = _get_player_by_id(attacker.owner_id)
		if attacker in acting.board:
			_try_transform(attacker, acting)
		# Dual Strike: automatic second hit on same target
		if attacker.has_ability(Abilities.DUAL_STRIKE) and attacker in acting.board and target_minion in defending.board:
			if not target_minion.has_ability(Abilities.COMBAT_IMMUNE):
				target_minion.take_damage(maxi(0, attacker.current_attack + attacker_amp - target_shield))
				if attacker.has_ability(Abilities.VOIDTOUCH):
					target_minion.current_health = mini(target_minion.current_health, 0)
			if not attacker.has_ability(Abilities.COMBAT_IMMUNE):
				attacker.take_damage(maxi(0, target_minion.current_attack - attacker_shield))
			Abilities.fire_on_attack(attacker, acting, self)
			Abilities.fire_on_defend(target_minion, defending, self)
			_remove_dead_minions()
			if attacker in acting.board:
				_try_transform(attacker, acting)
	elif target_player_id != "":
		var target_player = _get_player_by_id(target_player_id)
		var hits := 2 if attacker.has_ability(Abilities.DUAL_STRIKE) else 1
		target_player.hero_health -= attacker.current_attack * hits
		Abilities.fire_on_attack(attacker, _get_player_by_id(attacker.owner_id), self)
		_try_transform(attacker, _get_player_by_id(attacker.owner_id))

	_check_win_condition()

func apply_challenge(challenger: Minion, target: Minion) -> void:
	var was_yeti = challenger.has_ability(Abilities.YETI)
	var owner_id = challenger.owner_id
	var challenger_shield := _get_shield_value(challenger)
	var target_shield := _get_shield_value(target)
	var challenger_amp := _get_enemy_damage_amp(challenger.owner_id)
	if not target.has_ability(Abilities.COMBAT_IMMUNE):
		target.take_damage(maxi(0, challenger.current_attack + challenger_amp - target_shield))
		if challenger.has_ability(Abilities.VOIDTOUCH):
			target.current_health = mini(target.current_health, 0)
	if not challenger.has_ability(Abilities.COMBAT_IMMUNE):
		challenger.take_damage(maxi(0, target.current_attack - challenger_shield))
	_remove_dead_minions()
	var owner = _get_player_by_id(owner_id)
	if was_yeti and challenger in owner.board:
		for m in owner.board:
			if m.has_ability(Abilities.ON_YETI_CHALLENGE_BUFF):
				challenger.current_attack += 1
				challenger.current_health += 1
				challenger.max_health += 1
				_try_apothecary_bonus(owner_id, challenger)
				_try_health_transform(challenger)
				break

	if was_yeti:
		var enemy := _get_player_by_id(_opponent_id(owner_id))
		for m in owner.board.duplicate():
			if not m.has_ability(Abilities.ON_YETI_CHALLENGE_ATTACK) or not m.can_attack():
				continue
			if target not in enemy.board or current_phase == Phase.GAME_OVER:
				break
			var m_shield := _get_shield_value(m)
			var t_shield := _get_shield_value(target)
			var m_amp := _get_enemy_damage_amp(owner_id)
			if not target.has_ability(Abilities.COMBAT_IMMUNE):
				target.take_damage(maxi(0, m.current_attack + m_amp - t_shield))
				if m.has_ability(Abilities.VOIDTOUCH):
					target.current_health = mini(target.current_health, 0)
			if not m.has_ability(Abilities.COMBAT_IMMUNE):
				m.take_damage(maxi(0, target.current_attack - m_shield))
			m.has_attacked = true
			Abilities.fire_on_attack(m, owner, self)
			_remove_dead_minions()
			if m in owner.board:
				_try_transform(m, owner)

	_check_win_condition()

func apply_swap_friendly_health(minion_a: Minion, minion_b: Minion) -> void:
	var a_health := minion_a.current_health
	minion_a.current_health = mini(minion_b.current_health, minion_a.max_health)
	minion_b.current_health = mini(a_health, minion_b.max_health)
	_remove_dead_minions()

func apply_devour_friendly(devourer: Minion, target: Minion, owner: PlayerState) -> void:
	var gain := target.current_health
	owner.remove_minion(target)
	owner.graveyard.append(target.data)
	devourer.max_health += gain
	devourer.current_health += gain
	_try_health_transform(devourer)

func apply_on_play_damage(target: Minion, damage: int, source_player_id: String = "") -> void:
	var amp := _get_enemy_damage_amp(source_player_id) if source_player_id != "" else 0
	target.take_damage(damage + amp)
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
			target_mech.piloted_by = pilot_minion.data
			target_mech.pilot_atk_bonus = Abilities.get_pilot_attack(ability)
			target_mech.pilot_hp_bonus = hp_bonus
			if target_mech.has_ability(Abilities.ON_PILOTED_GAIN_RUSH):
				if Abilities.RUSH not in target_mech.abilities:
					target_mech.abilities.append(Abilities.RUSH)
				target_mech.is_exhausted = false
			if target_mech.has_ability(Abilities.ON_PILOTED_GAIN_CLOAKED):
				if Abilities.CLOAKED not in target_mech.abilities:
					target_mech.abilities.append(Abilities.CLOAKED)
			if pilot_minion.has_ability(Abilities.PILOT_GIVES_RUSH):
				if Abilities.RUSH not in target_mech.abilities:
					target_mech.abilities.append(Abilities.RUSH)
				target_mech.is_exhausted = false
			if pilot_minion.has_ability(Abilities.PILOT_GIVES_CLOAKED):
				if Abilities.CLOAKED not in target_mech.abilities:
					target_mech.abilities.append(Abilities.CLOAKED)
			if pilot_minion.has_ability(Abilities.PILOT_GIVES_GUARDIAN):
				if Abilities.GUARDIAN not in target_mech.abilities:
					target_mech.abilities.append(Abilities.GUARDIAN)
			if target_mech.has_ability(Abilities.ON_PILOTED_STAT_BOOST):
				target_mech.current_attack += 1
				target_mech.current_health += 1
				target_mech.max_health += 1
			if hp_bonus > 0:
				_try_apothecary_bonus(target_mech.owner_id, target_mech)
			_try_health_transform(target_mech)
			break
	pilot_owner.remove_minion(pilot_minion)
	pilot_owner.graveyard.append(pilot_minion.data)
	for m in pilot_owner.board:
		if m.has_ability(Abilities.ON_FRIENDLY_PILOT_DRAW):
			var drawn = pilot_owner.draw_card()
			if drawn != null and pilot_owner.player_id == player.player_id:
				pending_drawn_cards.append(drawn)
			break

func apply_eject_pilot(target_mech: Minion, owner: PlayerState) -> Minion:
	if not target_mech.is_piloted or target_mech.piloted_by == null:
		return null
	target_mech.current_attack -= target_mech.pilot_atk_bonus
	target_mech.max_health -= target_mech.pilot_hp_bonus
	target_mech.current_health = max(1, target_mech.current_health - target_mech.pilot_hp_bonus)
	target_mech.is_piloted = false
	var pilot_data := target_mech.piloted_by
	target_mech.piloted_by = null
	target_mech.pilot_atk_bonus = 0
	target_mech.pilot_hp_bonus = 0
	if owner.board.size() < PlayerState.MAX_BOARD_SIZE:
		var pilot_minion := Minion.new(pilot_data, owner.player_id)
		owner.place_minion(pilot_minion)
		return pilot_minion
	elif owner.hand.size() < PlayerState.MAX_HAND_SIZE:
		owner.hand.append(pilot_data)
	return null

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
				var amp := _get_enemy_damage_amp(acting_player_id) if acting_player_id != "" else 0
				target_minion.take_damage(card.effect_value + amp)
				_remove_dead_minions()
			elif target_player_id != "":
				var target = _get_player_by_id(target_player_id)
				target.hero_health -= card.effect_value
				_check_win_condition()
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
		"destroy_all_creatures":
			for p in [player, opponent]:
				for minion in p.board.duplicate():
					minion.current_health = 0
			_remove_dead_minions()
			_check_win_condition()
		"deal_damage_all_creatures":
			for p in [player, opponent]:
				for minion in p.board.duplicate():
					minion.take_damage(card.effect_value)
			_remove_dead_minions()
		"deal_damage_all_enemy":
			var acting := _get_player_by_id(acting_player_id)
			var enemy := opponent if acting == player else player
			var amp := _get_enemy_damage_amp(acting_player_id) if acting_player_id != "" else 0
			for minion in enemy.board.duplicate():
				minion.take_damage(card.effect_value + amp)
			_remove_dead_minions()
			_check_win_condition()
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
		"blood_transfusion":
			if target_minion:
				target_minion.take_damage(card.effect_value)
				_remove_dead_minions()
				_check_win_condition()
		"sanguine":
			if target_minion:
				target_minion.take_damage(card.effect_value)
				_remove_dead_minions()
				_check_win_condition()
		"exsanguinate":
			if target_minion:
				target_minion.take_damage(target_minion.current_health * card.effect_value)
				_remove_dead_minions()
				_check_win_condition()
		"blood_boil":
			if target_minion:
				var gain := target_minion.current_health * card.effect_value
				target_minion.current_health += gain
				target_minion.max_health += gain
				_try_apothecary_bonus(target_minion.owner_id, target_minion)
				_try_health_transform(target_minion)
		"tainted_blood":
			if target_minion:
				var acting := _get_player_by_id(acting_player_id)
				var enemy := opponent if acting == player else player
				enemy.hero_health -= target_minion.current_health / 2
				acting.remove_minion(target_minion)
				acting.graveyard.append(target_minion.data)
				_check_win_condition()
		"bloodlet":
			if target_minion:
				if target_minion.owner_id == acting_player_id:
					var pre := target_minion.current_health
					target_minion.current_health = mini(target_minion.current_health + card.effect_value, target_minion.max_health)
					_try_heal_to_draw(target_minion, target_minion.current_health - pre)
					_try_apothecary_bonus(target_minion.owner_id, target_minion)
				else:
					var amp := _get_enemy_damage_amp(acting_player_id) if acting_player_id != "" else 0
					target_minion.take_damage(card.effect_value + amp)
					_remove_dead_minions()
					_check_win_condition()
			elif target_player_id != "":
				var target_p := _get_player_by_id(target_player_id)
				if target_player_id == acting_player_id:
					target_p.hero_health += card.effect_value
				else:
					target_p.hero_health -= card.effect_value
				_check_win_condition()
		"heal":
			if target_minion:
				var pre := target_minion.current_health
				if target_minion.current_health >= target_minion.max_health:
					target_minion.max_health += 1
					target_minion.current_health += 1
					_try_heal_to_draw(target_minion, 1)
					_try_apothecary_bonus(target_minion.owner_id, target_minion)
					_try_health_transform(target_minion)
				else:
					target_minion.current_health = min(target_minion.current_health + card.effect_value, target_minion.max_health)
					_try_heal_to_draw(target_minion, target_minion.current_health - pre)
		"eject_pilot":
			if target_minion != null and target_minion.is_piloted:
				apply_eject_pilot(target_minion, _get_player_by_id(acting_player_id))
		"eject_all_pilots":
			var acting := _get_player_by_id(acting_player_id)
			for minion in acting.board.duplicate():
				if minion.is_piloted:
					apply_eject_pilot(minion, acting)
		"give_mech_shielded_temp":
			if target_minion and target_minion.has_ability(Abilities.MECH):
				var ability := Abilities.SHIELDED + "_" + str(card.effect_value)
				for existing in target_minion.abilities.duplicate():
					if Abilities.is_shielded(existing):
						target_minion.abilities.erase(existing)
				target_minion.abilities.append(ability)
				temp_shielded.append({
					"instance_id": target_minion.instance_id,
					"ability": ability,
					"expires_after": _opponent_id(acting_player_id)
				})

func _remove_dead_minions() -> void:
	var any_removed := true
	while any_removed:
		any_removed = false
		for p in [player, opponent]:
			for minion in p.board.duplicate():
				if minion.is_dead():
					any_removed = true
					var idx = p.board.find(minion)
					p.remove_minion(minion)
					p.graveyard.append(minion.data)
					var enemy = _get_player_by_id(_opponent_id(p.player_id))
					var death_result := Abilities.fire_on_death(minion, p, idx, enemy, self)
					if p.player_id == player.player_id:
						pending_drawn_cards.append_array(death_result["drawn"])
					for _i in death_result["tank_shots"]:
						pending_tank_shots.append(p.player_id)
					if minion.data.tribe == "tank":
						for watcher in p.board:
							if watcher.has_ability(Abilities.ON_FRIENDLY_TANK_DEATH_BUFF_TANK):
								pending_tank_specialist_buffs.append(p.player_id)

func _check_win_condition() -> void:
	if opponent.is_dead():
		winner_id = player.player_id
		current_phase = Phase.GAME_OVER
	elif player.is_dead():
		winner_id = opponent.player_id
		current_phase = Phase.GAME_OVER

func get_rummage_options(player_id: String, max_cost: int = -1, type_filter: String = "", allow_equal_cost: bool = false) -> Array[CardData]:
	var p = _get_player_by_id(player_id)
	var seen_ids: Array[String] = []
	var options: Array[CardData] = []
	for card in p.graveyard:
		if max_cost >= 0:
			if allow_equal_cost and card.cost > max_cost:
				continue
			elif not allow_equal_cost and card.cost >= max_cost:
				continue
		if type_filter == "creature" and card.card_type != CardData.CardType.CREATURE:
			continue
		if type_filter == "stratagem" and card.card_type != CardData.CardType.STRATAGEM:
			continue
		if type_filter == "mech" and Abilities.MECH not in card.abilities:
			continue
		if type_filter == "creature_nonlegendary":
			if card.card_type != CardData.CardType.CREATURE or card.rarity == CardData.CardRarity.LEGENDARY:
				continue
		if card.id not in seen_ids:
			seen_ids.append(card.id)
			options.append(card)
	return options

func complete_rummage(player_id: String, card: CardData, play_it: bool = false, discount: bool = true) -> Minion:
	var p = _get_player_by_id(player_id)
	for i in p.graveyard.size():
		if p.graveyard[i].id == card.id:
			p.graveyard.remove_at(i)
			break
	var has_stinkpile := false
	for m in p.board:
		if m.has_ability(Abilities.STINKPILE_PASSIVE):
			has_stinkpile = true
			break
	var placed: Minion = null
	if (has_stinkpile or play_it) and card.card_type == CardData.CardType.CREATURE and p.board.size() < PlayerState.MAX_BOARD_SIZE:
		card.rummage_count += 1
		placed = Minion.new(card, player_id)
		p.place_minion(placed)
		Abilities.fire_on_play(placed, p, self)
	elif p.hand.size() < PlayerState.MAX_HAND_SIZE:
		if discount:
			card.cost_modifier = -1
		card.rummage_count += 1
		p.hand.append(card)
	Abilities.fire_on_rummage(p, self)
	return placed

func is_local_player_turn() -> bool:
	return active_player_id == player.player_id

## Deep copy for AI search simulation (distinct from to_net_dict/from_net_dict,
## which serve wire serialization). Safe for a search rollout to mutate freely
## without affecting the real match.
func duplicate_for_sim() -> GameState:
	var gs := GameState.new(player.player_id, opponent.player_id, [], [])
	gs.player = player.duplicate_for_sim()
	gs.opponent = opponent.duplicate_for_sim()
	gs.current_phase = current_phase
	gs.active_player_id = active_player_id
	gs.turn_number = turn_number
	gs.winner_id = winner_id
	gs.pending_drawn_cards = pending_drawn_cards.duplicate()
	gs.pending_fatigue_damage = pending_fatigue_damage.duplicate()
	gs.pending_rummages = pending_rummages.duplicate(true)
	gs.pending_tank_shots = pending_tank_shots.duplicate()
	gs.pending_nulls = pending_nulls.duplicate(true)
	gs.pending_overwatch_challenges = pending_overwatch_challenges.duplicate()
	gs.pending_buff_friendly_health = pending_buff_friendly_health.duplicate()
	gs.pending_tank_specialist_buffs = pending_tank_specialist_buffs.duplicate()
	gs.pending_on_reinforce_damages = pending_on_reinforce_damages.duplicate(true)
	gs.temp_shielded = temp_shielded.duplicate(true)
	gs.growvin_granted = growvin_granted.duplicate(true)
	gs._opening_hand_dealt = _opening_hand_dealt
	return gs

func to_net_dict() -> Dictionary:
	return {
		"phase": current_phase,
		"active_player_id": active_player_id,
		"turn_number": turn_number,
		"winner_id": winner_id,
		"host_state": player.to_net_dict() if player.player_id == "host" else opponent.to_net_dict(),
		"guest_state": opponent.to_net_dict() if player.player_id == "host" else player.to_net_dict(),
		"pending_rummages": pending_rummages.duplicate(true),
		"pending_tank_shots": pending_tank_shots.duplicate(),
		"pending_nulls": pending_nulls.duplicate(true),
		"pending_buff_friendly_health": pending_buff_friendly_health.duplicate(),
		"pending_tank_specialist_buffs": pending_tank_specialist_buffs.duplicate(),
		"pending_on_reinforce_damages": pending_on_reinforce_damages.duplicate(true),
		"pending_overwatch_challenges": pending_overwatch_challenges.duplicate(),
		"pending_drawn_cards": pending_drawn_cards.map(func(c): return c.id),
		"pending_fatigue_damage": pending_fatigue_damage.duplicate(),
	}

static func from_net_dict(d: Dictionary, my_id: String) -> GameState:
	var opp_id := "guest" if my_id == "host" else "host"
	var gs := GameState.new(my_id, opp_id, [], [])
	gs.player = PlayerState.from_net_dict(d["host_state"] if my_id == "host" else d["guest_state"])
	gs.opponent = PlayerState.from_net_dict(d["guest_state"] if my_id == "host" else d["host_state"])
	gs.current_phase = int(d["phase"])
	gs.active_player_id = str(d["active_player_id"])
	gs.turn_number = int(d["turn_number"])
	gs.winner_id = str(d.get("winner_id", ""))
	gs.pending_rummages.clear()
	for r in d.get("pending_rummages", []):
		gs.pending_rummages.append(r)
	gs.pending_tank_shots.clear()
	for t in d.get("pending_tank_shots", []):
		gs.pending_tank_shots.append(str(t))
	gs.pending_nulls.clear()
	for n in d.get("pending_nulls", []):
		gs.pending_nulls.append(n)
	gs.pending_buff_friendly_health.clear()
	for b in d.get("pending_buff_friendly_health", []):
		gs.pending_buff_friendly_health.append(str(b))
	gs.pending_tank_specialist_buffs.clear()
	for b in d.get("pending_tank_specialist_buffs", []):
		gs.pending_tank_specialist_buffs.append(str(b))
	gs.pending_on_reinforce_damages.clear()
	for od in d.get("pending_on_reinforce_damages", []):
		gs.pending_on_reinforce_damages.append(od)
	gs.pending_overwatch_challenges.clear()
	for oc in d.get("pending_overwatch_challenges", []):
		gs.pending_overwatch_challenges.append(str(oc))
	gs.pending_drawn_cards.clear()
	for cid in d.get("pending_drawn_cards", []):
		var card = CardDatabase.get_card(str(cid))
		if card != null:
			gs.pending_drawn_cards.append(card)
	gs.pending_fatigue_damage.clear()
	for pid in d.get("pending_fatigue_damage", []):
		gs.pending_fatigue_damage.append(str(pid))
	gs._opening_hand_dealt = true
	return gs

func _try_apothecary_bonus(owner_id: String, target: Minion) -> void:
	var owner = _get_player_by_id(owner_id)
	for m in owner.board:
		if m.has_ability(Abilities.APOTHECARY):
			var pre := target.current_health
			target.current_health += 1
			target.max_health += 1
			_try_heal_to_draw(target, target.current_health - pre)
			return

func _try_heal_to_draw(target: Minion, gained: int) -> void:
	if gained <= 0 or not target.has_ability(Abilities.HEAL_TO_DRAW):
		return
	target.current_health -= gained
	target.max_health -= gained
	_get_player_by_id(target.owner_id).draw_card()

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

	if transforming in owner.board:
		for m in owner.board:
			if m != transforming and m.has_ability(Abilities.ON_FRIENDLY_TRANSFORM_GIVE_AMBUSH):
				if not transforming.has_ability(Abilities.AMBUSH):
					transforming.abilities.append(Abilities.AMBUSH)
		for m in owner.board:
			if m != transforming and m.has_ability(Abilities.ON_FRIENDLY_TRANSFORM_BUFF_SELF):
				m.current_attack += 1
				m.current_health += 1
				m.max_health += 1
				_try_apothecary_bonus(owner.player_id, m)
				_try_health_transform(m)

func _apply_rejuvenate(player_id: String) -> void:
	var owner := _get_player_by_id(player_id)
	var broodtender_active := owner.board.any(func(m): return m.has_ability(Abilities.BROODTENDER_AURA))
	for m in owner.board:
		var regen := 0
		for ab in m.abilities:
			if Abilities.is_rejuvenate(ab):
				regen = maxi(regen, Abilities.get_rejuvenate_value(ab))
				break
		if broodtender_active and m.has_ability(Abilities.MONSTROSITY):
			regen = maxi(regen, 2)
		if regen > 0:
			var pre := m.current_health
			m.current_health = mini(m.current_health + regen, m.max_health)
			var gained := m.current_health - pre
			if gained > 0:
				_try_heal_to_draw(m, gained)
				_try_apothecary_bonus(player_id, m)

func _apply_feast_attendant(player_id: String) -> void:
	var owner := _get_player_by_id(player_id)
	for i in range(owner.board.size()):
		if not owner.board[i].has_ability(Abilities.FEAST_ATTENDANT):
			continue
		for j in [i - 1, i + 1]:
			if j < 0 or j >= owner.board.size():
				continue
			var neighbor: Minion = owner.board[j]
			neighbor.current_health += 1
			neighbor.max_health += 1
			_try_apothecary_bonus(player_id, neighbor)
			_try_health_transform(neighbor)

func _expire_temp_shields_for(ending_player_id: String) -> void:
	var keep: Array[Dictionary] = []
	for entry in temp_shielded:
		if entry["expires_after"] == ending_player_id:
			var iid: String = entry["instance_id"]
			var ab: String = entry["ability"]
			for p in [player, opponent]:
				for m in p.board:
					if m.instance_id == iid:
						m.abilities.erase(ab)
		else:
			keep.append(entry)
	temp_shielded = keep

func _apply_growvin_aura_to_mech(mech: Minion, owner_id: String) -> void:
	for ab in [Abilities.CLOAKED, "shielded_1", "rejuvenate_1"]:
		if mech.has_ability(ab):
			continue
		if ab == "shielded_1" and _get_shield_value(mech) > 0:
			continue
		if ab == "rejuvenate_1":
			var has_regen := false
			for existing in mech.abilities:
				if Abilities.is_rejuvenate(existing):
					has_regen = true
					break
			if has_regen:
				continue
		mech.abilities.append(ab)
		growvin_granted.append({"instance_id": mech.instance_id, "ability": ab, "owner_id": owner_id})

func _remove_growvin_aura(owner_id: String) -> void:
	for m in _get_player_by_id(owner_id).board:
		if m.has_ability(Abilities.GROWVIN_AURA):
			return
	var keep: Array[Dictionary] = []
	for entry in growvin_granted:
		if entry["owner_id"] != owner_id:
			keep.append(entry)
			continue
		var iid: String = entry["instance_id"]
		var ab: String = entry["ability"]
		for p in [player, opponent]:
			for m in p.board:
				if m.instance_id == iid:
					m.abilities.erase(ab)
	growvin_granted = keep

func _get_enemy_damage_amp(source_player_id: String) -> int:
	var total := 0
	for m in _get_player_by_id(source_player_id).board:
		for ability in m.abilities:
			if Abilities.is_enemy_damage_amp(ability):
				total += Abilities.get_enemy_damage_amp_value(ability)
	return total

func _get_shield_value(minion: Minion) -> int:
	for ability in minion.abilities:
		if Abilities.is_shielded(ability):
			return Abilities.get_shield_value(ability)
	return 0

func _get_active_player() -> PlayerState:
	return _get_player_by_id(active_player_id)

func _get_player_by_id(id: String) -> PlayerState:
	return player if id == player.player_id else opponent

func _opponent_id(id: String) -> String:
	return opponent.player_id if id == player.player_id else player.player_id
