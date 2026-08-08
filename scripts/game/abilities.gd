extends Node

const GUARDIAN              = "guardian"
const RUSH                  = "rush"
const REINFORCE             = "reinforce"
const YETI                  = "yeti"
const DEATHRATTLE_DRAW_YETI = "deathrattle_draw_yeti"
const CHALLENGE             = "challenge"
const RECON                 = "recon"
const TANK                  = "tank"
const DEATHRATTLE_DRAW_TANK = "deathrattle_draw_tank"
const RUMMAGE               = "rummage"
const RUMMAGE_ON_DEATH      = "rummage_on_death"
const RUMMAGE_MECH_ON_DEATH = "rummage_mech_on_death"
const RUMMAGE_SPELL         = "rummage_spell"
const PILOT                 = "pilot"
const MECH                  = "mech"
const ON_PLAY_YETI_CHALLENGE = "on_play_yeti_challenge"
const CLOAKED                = "cloaked"
const TACTICAL_OFFICER       = "tactical_officer"
const DEATHRATTLE_RETURN_STRATAGEM = "deathrattle_return_stratagem"
const DEATHRATTLE_DRAW_CARD = "deathrattle_draw_card"
const RUMMAGE_BUFF           = "rummage_buff"
const RUMMAGE_DRAW           = "rummage_draw"
const SPRITE                 = "sprite"
const NULL                   = "null"
const ON_YETI_CHALLENGE_BUFF = "on_yeti_challenge_buff"
const ON_YETI_DEATH_CHALLENGE = "on_yeti_death_challenge"
const ON_PLAY_RUMMAGE_BUFF           = "on_play_rummage_buff"
const ATTACK_BUFF_FRIENDLY_HEALTH    = "attack_buff_friendly_health"
const ON_PLAY_BUFF_FRIENDLY_YETI_ATK = "on_play_buff_friendly_yeti_attack"
const ON_FRIENDLY_YETI_DEATH_BUFF    = "on_friendly_yeti_death_buff"
const ON_FRIENDLY_MECH_DEATH_BUFF    = "on_friendly_mech_death_buff"
const ON_PLAY_BUFF_IF_YETI           = "on_play_buff_if_yeti"
const DEATHRATTLE_AOE_TRANSFORM      = "deathrattle_aoe_transform"
const STINKPILE_PASSIVE              = "stinkpile_passive"
const RUMMAGE_AND_PLAY               = "rummage_and_play"
const CHALLENGE_ALL                  = "challenge_all"
const ON_PLAY_CHALLENGE_WIN_BUFF     = "on_play_challenge_win_buff"
const DUAL_STRIKE                    = "dual_strike"
const VOIDTOUCH                      = "voidtouch"
const SHIELDED                       = "shielded"
const AMBUSH                         = "ambush"
const REJUVENATE                     = "rejuvenate"
const MONSTROSITY                    = "monstrosity"
const BROODTENDER_AURA               = "broodtender_aura"
const GROWVIN_AURA                   = "growvin_aura"
const ON_FRIENDLY_TRANSFORM_BUFF_SELF = "on_friendly_transform_buff_self"

const DEFINITIONS: Dictionary = {
	GUARDIAN:              { "display": "Guardian",    "color": Color(0.55, 0.42, 0.08) },
	RUSH:                  { "display": "Rush",        "color": Color(0.10, 0.42, 0.10) },
	REINFORCE:             { "display": "Reinforce",   "color": Color(0.15, 0.55, 0.25) },
	YETI:                  { "display": "Yeti",        "color": Color(0.45, 0.70, 0.85) },
	DEATHRATTLE_DRAW_YETI: { "display": "On Death:",   "color": Color(0.50, 0.20, 0.60) },
	CHALLENGE:             { "display": "Challenge",   "color": Color(0.70, 0.30, 0.10) },
	RECON:                 { "display": "Recon",       "color": Color(0.20, 0.55, 0.75) },
	TANK:                  { "display": "Tank",        "color": Color(0.10, 0.55, 0.20) },
	DEATHRATTLE_DRAW_TANK: { "display": "On Death:",   "color": Color(0.50, 0.20, 0.60) },
	RUMMAGE:               { "display": "Rummage",      "color": Color(0.30, 0.08, 0.42) },
	RUMMAGE_ON_DEATH:      { "display": "On Death:",    "color": Color(0.50, 0.20, 0.60) },
	RUMMAGE_MECH_ON_DEATH: { "display": "On Death:",    "color": Color(0.50, 0.20, 0.60) },
	RUMMAGE_SPELL:         { "display": "Spell Rummage","color": Color(0.30, 0.08, 0.42) },
	MECH:                  { "display": "Mech",         "color": Color(0.60, 0.38, 0.08) },
	ON_PLAY_YETI_CHALLENGE: { "display": "On Play:",    "color": Color(0.20, 0.55, 0.75) },
	CLOAKED:                { "display": "Cloaked",     "color": Color(0.20, 0.50, 0.80) },
	TACTICAL_OFFICER:       { "display": "Officer",     "color": Color(0.25, 0.55, 0.25) },
	DEATHRATTLE_RETURN_STRATAGEM: { "display": "On Death:", "color": Color(0.50, 0.20, 0.60) },
	DEATHRATTLE_DRAW_CARD:        { "display": "On Death:", "color": Color(0.50, 0.20, 0.60) },
	RUMMAGE_BUFF:                 { "display": "Rummage Buff", "color": Color(0.30, 0.08, 0.42) },
	RUMMAGE_DRAW:                 { "display": "Rummage Draw", "color": Color(0.30, 0.08, 0.42) },
	SPRITE:                       { "display": "Sprite",      "color": Color(0.75, 0.20, 0.60) },
	NULL:                         { "display": "Null",        "color": Color(0.35, 0.15, 0.55) },
	ON_YETI_CHALLENGE_BUFF:       { "display": "Yeti Bond",       "color": Color(0.45, 0.70, 0.85) },
	ON_YETI_DEATH_CHALLENGE:      { "display": "Overwatch",       "color": Color(0.20, 0.55, 0.75) },
	COMBAT_IMMUNE:                { "display": "Ethereal",        "color": Color(0.55, 0.75, 0.95) },
	ON_PLAY_TRANSFORM_CHOICE:     { "display": "On Play: Morph",  "color": Color(0.80, 0.25, 0.10) },
	ON_PLAY_BUFF_FRIENDLY_HEALTH: { "display": "On Play:",        "color": Color(0.20, 0.55, 0.75) },
	WHEN_ATTACKED_BUFF_FRIENDLY:  { "display": "Lifegift",        "color": Color(0.70, 0.25, 0.45) },
	APOTHECARY:                   { "display": "Apothecary",      "color": Color(0.25, 0.65, 0.35) },
	MIRROR_TRANSFORM:             { "display": "Mimic",           "color": Color(0.80, 0.25, 0.10) },
	ON_PLAY_RUMMAGE_BUFF:            { "display": "On Play:",        "color": Color(0.30, 0.08, 0.42) },
	ATTACK_BUFF_FRIENDLY_HEALTH:     { "display": "On Attack:",      "color": Color(0.70, 0.25, 0.45) },
	ON_PLAY_BUFF_FRIENDLY_YETI_ATK:  { "display": "On Play:",        "color": Color(0.45, 0.70, 0.85) },
	ON_FRIENDLY_YETI_DEATH_BUFF:     { "display": "Yeti Bond",       "color": Color(0.45, 0.70, 0.85) },
	ON_FRIENDLY_MECH_DEATH_BUFF:     { "display": "Mech Bond",       "color": Color(0.60, 0.38, 0.08) },
	ON_PLAY_BUFF_IF_YETI:            { "display": "On Play:",        "color": Color(0.45, 0.70, 0.85) },
	DEATHRATTLE_AOE_TRANSFORM:       { "display": "On Death:",       "color": Color(0.50, 0.20, 0.60) },
	STINKPILE_PASSIVE:               { "display": "Salvage",         "color": Color(0.25, 0.45, 0.15) },
	RUMMAGE_AND_PLAY:                { "display": "Rummage & Play",  "color": Color(0.30, 0.08, 0.42) },
	CHALLENGE_ALL:                   { "display": "Rampage",         "color": Color(0.70, 0.30, 0.10) },
	ON_PLAY_CHALLENGE_WIN_BUFF:      { "display": "On Play:",        "color": Color(0.70, 0.30, 0.10) },
	ON_PILOTED_GAIN_CLOAKED:         { "display": "Boost: Cloaked", "color": Color(0.20, 0.50, 0.80) },
	ON_FRIENDLY_PILOT_DRAW:          { "display": "Pilot Bond",    "color": Color(0.60, 0.38, 0.08) },
	EJECT_PILOT_ON_DEATH:            { "display": "On Death:",       "color": Color(0.50, 0.20, 0.60) },
	PILOT_GIVES_RUSH:                { "display": "Boost: Rush",     "color": Color(0.10, 0.42, 0.10) },
	PILOT_GIVES_CLOAKED:             { "display": "Boost: Cloaked", "color": Color(0.20, 0.50, 0.80) },
	PILOT_GIVES_GUARDIAN:            { "display": "Boost: Guardian", "color": Color(0.55, 0.42, 0.08) },
	ON_PILOTED_STAT_BOOST:           { "display": "Boost: +1/+1",   "color": Color(0.60, 0.38, 0.08) },
	ON_PLAY_PILOT_MECH:              { "display": "On Play:",        "color": Color(0.60, 0.38, 0.08) },
	HEAL_TO_DRAW:                    { "display": "Crypt Hunger",    "color": Color(0.65, 0.10, 0.20) },
	DUAL_STRIKE:                     { "display": "Dual Strike",     "color": Color(0.80, 0.60, 0.10) },
	VOIDTOUCH:                       { "display": "Voidtouch",       "color": Color(0.45, 0.10, 0.65) },
	AMBUSH:                          { "display": "Ambush",          "color": Color(0.20, 0.50, 0.20) },
	REJUVENATE:                      { "display": "Rejuvenate",      "color": Color(0.20, 0.75, 0.40) },
	MONSTROSITY:                     { "display": "Monstrosity",     "color": Color(0.55, 0.15, 0.55) },
	BROODTENDER_AURA:                { "display": "Broodtender",     "color": Color(0.40, 0.65, 0.30) },
	GROWVIN_AURA:                    { "display": "Architect",       "color": Color(0.85, 0.55, 0.10) },
	ON_FRIENDLY_TRANSFORM_BUFF_SELF: { "display": "Metamorphosis",   "color": Color(0.80, 0.25, 0.10) },
	ON_PLAY_SWAP_FRIENDLY_HEALTH:    { "display": "On Play:",        "color": Color(0.55, 0.10, 0.20) },
	ON_PLAY_DEVOUR_FRIENDLY:         { "display": "On Play:",        "color": Color(0.55, 0.10, 0.20) },
	DEATHRATTLE_RUMMAGE_CREATURE:    { "display": "On Death:",       "color": Color(0.45, 0.10, 0.30) },
	RUMMAGE_EQUAL_COST:              { "display": "Equal Rummage",   "color": Color(0.30, 0.15, 0.45) },
	ON_PLAY_BUFF_ALL_FRIENDLY_HEALTH: { "display": "On Play:",       "color": Color(0.70, 0.25, 0.45) },
	ON_PLAY_VOIDTOUCH_IF_RUMMAGED:    { "display": "On Play:",       "color": Color(0.45, 0.10, 0.65) },
	FEAST_ATTENDANT:                  { "display": "Feast",          "color": Color(0.70, 0.25, 0.45) },
	ON_PLAY_DEVOUR_ALL:               { "display": "On Play:",       "color": Color(0.55, 0.10, 0.20) },
}

const ON_PLAY_DAMAGE             = "on_play_damage"
const ON_PLAY_AOE_ENEMY          = "on_play_aoe_enemy"
const ON_REINFORCE_DAMAGE        = "on_reinforce_damage"
const ON_ANY_REINFORCE_SHOT      = "on_any_reinforce_shot"
const TRANSFORM                  = "transform"
const TRANSFORM_AT_MAX_HEALTH    = "transform_at_max_health"
const COMBAT_IMMUNE              = "combat_immune"
const ON_PLAY_TRANSFORM_CHOICE   = "on_play_transform_choice"
const ON_PLAY_BUFF_FRIENDLY_HEALTH = "on_play_buff_friendly_health"
const WHEN_ATTACKED_BUFF_FRIENDLY  = "when_attacked_buff_friendly"
const APOTHECARY                   = "apothecary"
const MIRROR_TRANSFORM                    = "mirror_transform"
const ON_FRIENDLY_TRANSFORM_GIVE_AMBUSH    = "on_friendly_transform_give_ambush"
const ON_FRIENDLY_TANK_DEATH_BUFF_TANK     = "on_friendly_tank_death_buff_tank"
const ON_YETI_CHALLENGE_ATTACK             = "on_yeti_challenge_attack"
const ON_PILOTED_GAIN_RUSH         = "on_piloted_gain_rush"
const ON_FRIENDLY_PILOT_DRAW       = "on_friendly_pilot_draw"
const ON_PILOTED_GAIN_CLOAKED      = "on_piloted_gain_cloaked"
const EJECT_PILOT_ON_DEATH         = "eject_pilot_on_death"
const PILOT_GIVES_RUSH             = "pilot_gives_rush"
const PILOT_GIVES_CLOAKED          = "pilot_gives_cloaked"
const PILOT_GIVES_GUARDIAN         = "pilot_gives_guardian"
const ON_PILOTED_STAT_BOOST        = "on_piloted_stat_boost"
const ON_PLAY_PILOT_MECH           = "on_play_pilot_mech"
const HEAL_TO_DRAW                 = "heal_to_draw"
const ENEMY_DAMAGE_AMP             = "enemy_damage_amp"
const ON_PLAY_SWAP_FRIENDLY_HEALTH   = "on_play_swap_friendly_health"
const ON_PLAY_DEVOUR_FRIENDLY        = "on_play_devour_friendly"
const DEATHRATTLE_RUMMAGE_CREATURE   = "deathrattle_rummage_creature"
const RUMMAGE_EQUAL_COST             = "rummage_equal_cost"
const ON_PLAY_BUFF_ALL_FRIENDLY_HEALTH  = "on_play_buff_all_friendly_health"
const ON_PLAY_VOIDTOUCH_IF_RUMMAGED     = "on_play_voidtouch_if_rummaged"
const FEAST_ATTENDANT                   = "feast_attendant"
const ON_PLAY_DEVOUR_ALL                = "on_play_devour_all"

const TRIBES: Array = [YETI, MECH, TANK, SPRITE, MONSTROSITY]

const KEYWORD_TOOLTIPS: Array[String] = [
	GUARDIAN, RUSH, REINFORCE, CHALLENGE, RECON, CLOAKED, CHALLENGE_ALL,
	RUMMAGE, RUMMAGE_SPELL, RUMMAGE_BUFF, RUMMAGE_DRAW, RUMMAGE_AND_PLAY,
	NULL, COMBAT_IMMUNE, WHEN_ATTACKED_BUFF_FRIENDLY, APOTHECARY, MIRROR_TRANSFORM,
	TACTICAL_OFFICER, ON_YETI_CHALLENGE_BUFF, ON_YETI_DEATH_CHALLENGE,
	ON_FRIENDLY_YETI_DEATH_BUFF, ON_FRIENDLY_MECH_DEATH_BUFF,
	STINKPILE_PASSIVE, HEAL_TO_DRAW,
	DUAL_STRIKE, VOIDTOUCH, AMBUSH, REJUVENATE, FEAST_ATTENDANT,
	YETI, MECH, TANK, SPRITE,
]

func is_tribe(ability: String) -> bool:
	return ability in TRIBES

func is_shielded(ability: String) -> bool:
	return ability.begins_with(SHIELDED + "_")

func get_shield_value(ability: String) -> int:
	if is_shielded(ability):
		return int(ability.substr(SHIELDED.length() + 1))
	return 0

func is_enemy_damage_amp(ability: String) -> bool:
	return ability.begins_with(ENEMY_DAMAGE_AMP + "_")

func get_enemy_damage_amp_value(ability: String) -> int:
	if is_enemy_damage_amp(ability):
		return int(ability.substr(ENEMY_DAMAGE_AMP.length() + 1))
	return 0

func is_rejuvenate(ability: String) -> bool:
	return ability.begins_with(REJUVENATE + "_")

func get_rejuvenate_value(ability: String) -> int:
	if is_rejuvenate(ability):
		return int(ability.substr(REJUVENATE.length() + 1))
	return 0

func is_keyword_tooltip(ability: String) -> bool:
	return ability in KEYWORD_TOOLTIPS or is_pilot(ability) or is_shielded(ability) or is_enemy_damage_amp(ability) or is_rejuvenate(ability)

func get_tooltip_key(ability: String) -> String:
	if is_pilot(ability):
		return "Pilot"
	if is_shielded(ability):
		return "Shielded"
	if is_enemy_damage_amp(ability):
		return "Amplify"
	if is_rejuvenate(ability):
		return "Rejuvenate"
	return get_display(ability)

func get_color_for_display(display_name: String) -> Color:
	for ability in DEFINITIONS:
		if DEFINITIONS[ability]["display"] == display_name:
			return DEFINITIONS[ability]["color"]
	return Color(0.6, 0.6, 0.7)

const REJUVENATE_COLOR            := Color(0.20, 0.75, 0.40)
const ON_PLAY_DAMAGE_COLOR        := Color(0.55, 0.12, 0.55)
const ON_PLAY_AOE_ENEMY_COLOR        := Color(0.55, 0.12, 0.12)
const ON_REINFORCE_DAMAGE_COLOR      := Color(0.15, 0.55, 0.25)
const ON_ANY_REINFORCE_SHOT_COLOR    := Color(0.10, 0.42, 0.55)
const PILOT_COLOR                 := Color(0.85, 0.45, 0.05)
const TRANSFORM_COLOR             := Color(0.80, 0.25, 0.10)
const ON_PILOTED_GAIN_RUSH_COLOR  := Color(0.10, 0.42, 0.10)

func get_display(ability: String) -> String:
	if is_on_play_damage(ability):
		return "On Play: %d dmg" % get_on_play_damage_value(ability)
	if is_on_play_aoe_enemy(ability):
		return "On Play: %d to all enemies" % get_on_play_aoe_enemy_value(ability)
	if is_on_reinforce_damage(ability):
		return "On Reinforce: %d dmg" % get_on_reinforce_damage_value(ability)
	if is_on_any_reinforce_shot(ability):
		return "Friendly Reinforce: %d dmg" % get_on_any_reinforce_shot_value(ability)
	if is_pilot(ability):
		return "Pilot %d/%d" % [get_pilot_attack(ability), get_pilot_health(ability)]
	if is_shielded(ability):
		return "Shielded %d" % get_shield_value(ability)
	if is_enemy_damage_amp(ability):
		return "Amplify +%d" % get_enemy_damage_amp_value(ability)
	if is_rejuvenate(ability):
		return "Rejuvenate %d" % get_rejuvenate_value(ability)
	if is_transform(ability):
		return "Transform: %d" % get_transform_threshold(ability)
	if is_transform_at_max_health(ability):
		return "Transform at %dhp" % get_transform_health_threshold(ability)
	if ability == ON_PILOTED_GAIN_RUSH:
		return "Boost: Rush"
	return DEFINITIONS[ability]["display"]

func get_color(ability: String) -> Color:
	if is_on_play_damage(ability):
		return ON_PLAY_DAMAGE_COLOR
	if is_on_play_aoe_enemy(ability):
		return ON_PLAY_AOE_ENEMY_COLOR
	if is_on_reinforce_damage(ability):
		return ON_REINFORCE_DAMAGE_COLOR
	if is_on_any_reinforce_shot(ability):
		return ON_ANY_REINFORCE_SHOT_COLOR
	if is_pilot(ability):
		return PILOT_COLOR
	if is_shielded(ability):
		return Color(0.45, 0.55, 0.70)
	if is_enemy_damage_amp(ability):
		return Color(0.70, 0.20, 0.20)
	if is_rejuvenate(ability):
		return REJUVENATE_COLOR
	if is_transform(ability):
		return TRANSFORM_COLOR
	if is_transform_at_max_health(ability):
		return TRANSFORM_COLOR
	if ability == ON_PILOTED_GAIN_RUSH:
		return ON_PILOTED_GAIN_RUSH_COLOR
	return DEFINITIONS[ability]["color"]

func is_on_play_damage(ability: String) -> bool:
	return ability.begins_with(ON_PLAY_DAMAGE + "_") and not ability.begins_with(ON_PLAY_AOE_ENEMY + "_") and not ability.begins_with(ON_REINFORCE_DAMAGE + "_")

func get_on_play_damage_value(ability: String) -> int:
	if is_on_play_damage(ability):
		return int(ability.substr(ON_PLAY_DAMAGE.length() + 1))
	return 0

func is_on_play_aoe_enemy(ability: String) -> bool:
	return ability.begins_with(ON_PLAY_AOE_ENEMY + "_")

func get_on_play_aoe_enemy_value(ability: String) -> int:
	if is_on_play_aoe_enemy(ability):
		return int(ability.substr(ON_PLAY_AOE_ENEMY.length() + 1))
	return 0

func is_on_any_reinforce_shot(ability: String) -> bool:
	return ability.begins_with(ON_ANY_REINFORCE_SHOT + "_")

func get_on_any_reinforce_shot_value(ability: String) -> int:
	if is_on_any_reinforce_shot(ability):
		return int(ability.substr(ON_ANY_REINFORCE_SHOT.length() + 1))
	return 0

func is_on_reinforce_damage(ability: String) -> bool:
	return ability.begins_with(ON_REINFORCE_DAMAGE + "_")

func get_on_reinforce_damage_value(ability: String) -> int:
	if is_on_reinforce_damage(ability):
		return int(ability.substr(ON_REINFORCE_DAMAGE.length() + 1))
	return 0

func is_pilot(ability: String) -> bool:
	return ability.begins_with(PILOT + "_")

func get_pilot_attack(ability: String) -> int:
	if is_pilot(ability):
		return int(ability.split("_")[1])
	return 0

func get_pilot_health(ability: String) -> int:
	if is_pilot(ability):
		return int(ability.split("_")[2])
	return 0

func is_transform(ability: String) -> bool:
	return ability.begins_with(TRANSFORM + "_")

func get_transform_threshold(ability: String) -> int:
	if is_transform(ability):
		return int(ability.substr(TRANSFORM.length() + 1))
	return 0

func is_transform_at_max_health(ability: String) -> bool:
	return ability.begins_with(TRANSFORM_AT_MAX_HEALTH + "_")

func get_transform_health_threshold(ability: String) -> int:
	if is_transform_at_max_health(ability):
		return int(ability.substr(TRANSFORM_AT_MAX_HEALTH.length() + 1))
	return 0

func fire_on_play(minion: Minion, owner: PlayerState, gs: GameState) -> void:
	for ability in minion.abilities:
		match ability:
			RECON:
				var drawn = owner.draw_card()
				if drawn != null and owner.player_id == gs.player.player_id:
					gs.pending_drawn_cards.append(drawn)
			TANK:
				var _has_opd := false
				for _ab in minion.abilities:
					if is_on_play_damage(_ab):
						_has_opd = true
						break
				if not _has_opd:
					gs.pending_tank_shots.append(owner.player_id)
			RUMMAGE:
				gs.pending_rummages.append({"player_id": owner.player_id, "max_cost": minion.data.cost, "type_filter": ""})
			RUMMAGE_AND_PLAY:
				gs.pending_rummages.append({"player_id": owner.player_id, "max_cost": minion.data.cost, "type_filter": "", "play_it": true})
			RUMMAGE_SPELL:
				gs.pending_rummages.append({"player_id": owner.player_id, "max_cost": -1, "type_filter": "stratagem"})
			NULL:
				gs.pending_nulls.append({"player_id": owner.player_id, "source": minion.data.card_name})
			ON_PLAY_BUFF_FRIENDLY_HEALTH:
				gs.pending_buff_friendly_health.append(owner.player_id)
			ON_PLAY_RUMMAGE_BUFF:
				if minion.data.rummage_count > 0:
					minion.current_attack += minion.data.rummage_count
					minion.current_health += minion.data.rummage_count
					minion.max_health += minion.data.rummage_count
					gs._try_apothecary_bonus(owner.player_id, minion)
			ON_PLAY_BUFF_FRIENDLY_YETI_ATK:
				for m in owner.board:
					if m != minion and m.has_ability(YETI):
						m.current_attack += 2
			ON_PLAY_BUFF_IF_YETI:
				for m in owner.board:
					if m != minion and m.has_ability(YETI):
						minion.current_attack += 2
						minion.current_health += 1
						minion.max_health += 1
						gs._try_apothecary_bonus(owner.player_id, minion)
						break
			GROWVIN_AURA:
				for m in owner.board:
					if m != minion and m.has_ability(MECH):
						gs._apply_growvin_aura_to_mech(m, owner.player_id)
			ON_PLAY_BUFF_ALL_FRIENDLY_HEALTH:
				for m in owner.board:
					m.current_health += 1
					m.max_health += 1
				for m in owner.board.duplicate():
					gs._try_apothecary_bonus(owner.player_id, m)
			ON_PLAY_VOIDTOUCH_IF_RUMMAGED:
				if minion.data.rummage_count > 0 and not minion.has_ability(VOIDTOUCH):
					minion.abilities.append(VOIDTOUCH)
			ON_PLAY_DEVOUR_ALL:
				var total_atk := 0
				var total_hp := 0
				for p in [gs.player, gs.opponent]:
					for m in p.board.duplicate():
						if m == minion:
							continue
						total_atk += m.current_attack
						total_hp += m.current_health
						m.current_health = 0
				gs._remove_dead_minions()
				if minion in owner.board:
					minion.current_attack += total_atk
					minion.current_health += total_hp
					minion.max_health += total_hp
					gs._try_apothecary_bonus(owner.player_id, minion)
				gs._check_win_condition()
	for ability in minion.abilities:
		if is_on_play_aoe_enemy(ability):
			var damage = get_on_play_aoe_enemy_value(ability)
			var enemy = gs.opponent if owner == gs.player else gs.player
			for m in enemy.board.duplicate():
				m.take_damage(damage)
			gs._remove_dead_minions()
			gs._check_win_condition()
			break

func fire_on_attack(attacker: Minion, owner: PlayerState, gs: GameState) -> void:
	for ability in attacker.abilities:
		match ability:
			ATTACK_BUFF_FRIENDLY_HEALTH:
				if not owner.board.is_empty():
					var target = owner.board[randi() % owner.board.size()]
					target.current_health += 1
					target.max_health += 1
					gs._try_apothecary_bonus(owner.player_id, target)

func fire_on_defend(defender: Minion, owner: PlayerState, gs: GameState) -> void:
	for ability in defender.abilities:
		match ability:
			WHEN_ATTACKED_BUFF_FRIENDLY:
				for m in owner.board:
					m.current_health += 1
					m.max_health += 1
				for m in owner.board.duplicate():
					gs._try_apothecary_bonus(owner.player_id, m)

func fire_on_death(minion: Minion, owner: PlayerState, board_index: int, enemy: PlayerState, gs: GameState) -> Dictionary:
	var drawn: Array[CardData] = []
	var tank_shots: int = 0
	for ability in minion.abilities:
		match ability:
			REINFORCE:
				var copy = Minion.new(minion.data, minion.owner_id)
				copy.abilities.erase(REINFORCE)
				copy.is_newly_reinforced = true
				owner.board.insert(board_index, copy)
				for m in owner.board:
					if m != copy and m.has_ability(TACTICAL_OFFICER):
						copy.current_attack += 1
				if copy.has_ability(TANK) and enemy != null:
					tank_shots += 1
				for ab in minion.abilities:
					if is_on_reinforce_damage(ab):
						gs.pending_on_reinforce_damages.append({"player_id": owner.player_id, "damage": get_on_reinforce_damage_value(ab), "source": minion.data.card_name})
						break
				for watcher in owner.board:
					for ab in watcher.abilities:
						if is_on_any_reinforce_shot(ab):
							gs.pending_on_reinforce_damages.append({"player_id": watcher.owner_id, "damage": get_on_any_reinforce_shot_value(ab), "source": watcher.data.card_name})
							break
			DEATHRATTLE_DRAW_YETI:
				var card = _draw_by_tag(owner, YETI)
				if card:
					drawn.append(card)
			DEATHRATTLE_DRAW_TANK:
				var card = _draw_by_tag(owner, TANK)
				if card:
					drawn.append(card)
			DEATHRATTLE_DRAW_CARD:
				if not owner.deck.is_empty() and owner.hand.size() < owner.MAX_HAND_SIZE:
					var card: CardData = owner.deck.pop_back().duplicate()
					owner.hand.append(card)
					drawn.append(card)
			RUMMAGE_ON_DEATH:
				gs.pending_rummages.append({"player_id": owner.player_id, "max_cost": minion.data.cost, "type_filter": ""})
			RUMMAGE_MECH_ON_DEATH:
				gs.pending_rummages.append({"player_id": owner.player_id, "max_cost": -1, "type_filter": "mech", "discount": false})
			DEATHRATTLE_RETURN_STRATAGEM:
				gs.pending_rummages.append({"player_id": owner.player_id, "max_cost": -1, "type_filter": "stratagem", "discount": false})
			DEATHRATTLE_RUMMAGE_CREATURE:
				gs.pending_rummages.append({"player_id": owner.player_id, "max_cost": -1, "type_filter": "creature_nonlegendary", "discount": false})
			DEATHRATTLE_AOE_TRANSFORM:
				for p in [gs.player, gs.opponent]:
					for m in p.board:
						m.take_damage(1)
				if not minion.data.transform_into.is_empty():
					var new_data = CardDatabase.get_card(minion.data.transform_into)
					if new_data != null:
						var new_minion = Minion.new(new_data, minion.owner_id)
						new_minion.is_newly_reinforced = true
						owner.board.insert(board_index, new_minion)
			EJECT_PILOT_ON_DEATH:
				if minion.is_piloted and minion.piloted_by != null:
					if owner.board.size() < PlayerState.MAX_BOARD_SIZE:
						var pilot_minion = Minion.new(minion.piloted_by, minion.owner_id)
						pilot_minion.is_newly_reinforced = true
						owner.board.insert(board_index, pilot_minion)
					elif owner.hand.size() < owner.MAX_HAND_SIZE:
						owner.hand.append(minion.piloted_by)
			GROWVIN_AURA:
				gs._remove_growvin_aura(owner.player_id)
	if YETI in minion.abilities:
		for watcher in owner.board:
			if watcher.has_ability(ON_FRIENDLY_YETI_DEATH_BUFF):
				watcher.current_health += 2
				watcher.max_health += 2
				gs._try_apothecary_bonus(owner.player_id, watcher)
		for watcher in owner.board:
			if watcher.has_ability(ON_YETI_DEATH_CHALLENGE):
				gs.pending_overwatch_challenges.append(owner.player_id)
				break
	if MECH in minion.abilities:
		for watcher in owner.board:
			if watcher.has_ability(ON_FRIENDLY_MECH_DEATH_BUFF):
				watcher.current_attack += 1
				watcher.current_health += 1
				watcher.max_health += 1
				gs._try_apothecary_bonus(owner.player_id, watcher)
	return {"drawn": drawn, "tank_shots": tank_shots}

func fire_on_rummage(owner: PlayerState, gs: GameState) -> void:
	for m in owner.board:
		if m.has_ability(RUMMAGE_BUFF):
			m.current_health += 1
			m.max_health += 1
			gs._try_apothecary_bonus(owner.player_id, m)
	for m in owner.board:
		if m.has_ability(RUMMAGE_DRAW):
			var drawn = owner.draw_card()
			if drawn != null and owner.player_id == gs.player.player_id:
				gs.pending_drawn_cards.append(drawn)

func _draw_by_tag(owner: PlayerState, tag: String) -> CardData:
	var matching: Array[CardData] = []
	for card in owner.deck:
		if tag in card.abilities:
			matching.append(card)
	if matching.is_empty() or owner.hand.size() >= owner.MAX_HAND_SIZE:
		return null
	var chosen: CardData = matching[randi() % matching.size()]
	owner.deck.erase(chosen)
	var copy: CardData = chosen.duplicate()
	owner.hand.append(copy)
	return copy
	return copy
