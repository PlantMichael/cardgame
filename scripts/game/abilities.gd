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
const ATTACK_RUMMAGE        = "attack_rummage"
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
const ON_PLAY_HEAL_FRIENDLY_YETIS = "on_play_heal_friendly_yetis"
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
const ON_FRIENDLY_DEATH_REINFORCE     = "on_friendly_death_reinforce"
const ON_PLAY_HEALTH_PER_FRIENDLY     = "on_play_health_per_friendly"
const DEATHRATTLE_TRANSFORM           = "deathrattle_transform"
const END_TURN_DRAIN_RANDOM_ENEMY     = "end_turn_drain_random_enemy"
const STATS_FROM_GRAVEYARD            = "stats_from_graveyard"
const RUMMAGE_BUFF_CREATURE           = "rummage_buff_creature"
const END_TURN_HEAL_MECHS             = "end_turn_heal_mechs"
const END_TURN_YETI_DISCOUNT          = "end_turn_yeti_discount"
const TWO_SLOT                        = "two_slot"
const TRAMPLE                         = "trample"

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
	ATTACK_RUMMAGE:        { "display": "On Attack:",    "color": Color(0.30, 0.08, 0.42) },
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
	ON_PLAY_TRANSFORM:            { "display": "On Play: Morph",  "color": Color(0.80, 0.25, 0.10) },
	ON_PLAY_BUFF_FRIENDLY_HEALTH: { "display": "On Play:",        "color": Color(0.20, 0.55, 0.75) },
	ON_PLAY_RESTORE_HEALTH:      { "display": "On Play:",        "color": Color(0.20, 0.55, 0.75) },
	ON_PLAY_BUFF_OTHER_FRIENDLY: { "display": "On Play:",        "color": Color(0.20, 0.55, 0.75) },
	ON_PLAY_DAMAGE_HIGH_ATTACK:  { "display": "On Play:",        "color": Color(0.20, 0.55, 0.75) },
	WHEN_ATTACKED_BUFF_FRIENDLY:  { "display": "Lifegift",        "color": Color(0.70, 0.25, 0.45) },
	APOTHECARY:                   { "display": "Apothecary",      "color": Color(0.25, 0.65, 0.35) },
	MIRROR_TRANSFORM:             { "display": "Mimic",           "color": Color(0.80, 0.25, 0.10) },
	ON_PLAY_RUMMAGE_BUFF:            { "display": "On Play:",        "color": Color(0.30, 0.08, 0.42) },
	ATTACK_BUFF_FRIENDLY_HEALTH:     { "display": "On Attack:",      "color": Color(0.70, 0.25, 0.45) },
	ON_PLAY_BUFF_FRIENDLY_YETI_ATK:  { "display": "On Play:",        "color": Color(0.45, 0.70, 0.85) },
	ON_PLAY_HEAL_FRIENDLY_YETIS:     { "display": "On Play:",        "color": Color(0.45, 0.70, 0.85) },
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
	ON_FRIENDLY_DEATH_REINFORCE:      { "display": "Rally",          "color": Color(0.15, 0.55, 0.25) },
	ON_PLAY_HEALTH_PER_FRIENDLY:      { "display": "On Play:",       "color": Color(0.20, 0.55, 0.75) },
	DEATHRATTLE_TRANSFORM:            { "display": "On Death:",      "color": Color(0.50, 0.20, 0.60) },
	END_TURN_DRAIN_RANDOM_ENEMY:      { "display": "Siphon",         "color": Color(0.65, 0.10, 0.20) },
	STATS_FROM_GRAVEYARD:             { "display": "Scrapbuilt",     "color": Color(0.30, 0.08, 0.42) },
	RUMMAGE_BUFF_CREATURE:            { "display": "Refurbish",      "color": Color(0.30, 0.08, 0.42) },
	END_TURN_HEAL_MECHS:              { "display": "Repair Bay",     "color": Color(0.60, 0.38, 0.08) },
	END_TURN_YETI_DISCOUNT:           { "display": "Provision",      "color": Color(0.45, 0.70, 0.85) },
	TWO_SLOT:                         { "display": "Colossal",       "color": Color(0.45, 0.70, 0.85) },
	TRAMPLE:                          { "display": "Trample",        "color": Color(0.70, 0.30, 0.10) },
}

const ON_PLAY_DAMAGE             = "on_play_damage"
const ON_PLAY_AOE_ENEMY          = "on_play_aoe_enemy"
const ON_REINFORCE_DAMAGE        = "on_reinforce_damage"
const ON_ANY_REINFORCE_SHOT      = "on_any_reinforce_shot"
const TRANSFORM                  = "transform"
const TRANSFORM_AT_MAX_HEALTH    = "transform_at_max_health"
const COMBAT_IMMUNE              = "combat_immune"
const ON_PLAY_TRANSFORM_CHOICE   = "on_play_transform_choice"
const ON_PLAY_TRANSFORM          = "on_play_transform"
const ON_PLAY_BUFF_FRIENDLY_HEALTH = "on_play_buff_friendly_health"
## Targeted on-play effects. Each opens a GameState pending choice rather than
## resolving against a target the caller picked, so legality is decided once
## in the rules core and every mode (human, AI, host, guest, search) answers
## the same question. See GameState's "Pending choices" section.
const ON_PLAY_RESTORE_HEALTH       = "on_play_restore_health"
const ON_PLAY_BUFF_OTHER_FRIENDLY  = "on_play_buff_other_friendly"
const ON_PLAY_DAMAGE_HIGH_ATTACK   = "on_play_damage_high_attack"
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
const DEATHRATTLE_DAMAGE_ALL_EXCEPT_MECH = "deathrattle_damage_all_except_mech"

const TRIBES: Array = [YETI, MECH, TANK, SPRITE, MONSTROSITY]

const KEYWORD_TOOLTIPS: Array[String] = [
	GUARDIAN, RUSH, REINFORCE, CHALLENGE, RECON, CLOAKED, CHALLENGE_ALL,
	RUMMAGE, RUMMAGE_SPELL, RUMMAGE_BUFF, RUMMAGE_DRAW, RUMMAGE_AND_PLAY,
	NULL, COMBAT_IMMUNE, WHEN_ATTACKED_BUFF_FRIENDLY, APOTHECARY, MIRROR_TRANSFORM,
	TACTICAL_OFFICER, ON_YETI_CHALLENGE_BUFF, ON_YETI_DEATH_CHALLENGE,
	ON_FRIENDLY_YETI_DEATH_BUFF, ON_FRIENDLY_MECH_DEATH_BUFF,
	STINKPILE_PASSIVE, HEAL_TO_DRAW,
	DUAL_STRIKE, VOIDTOUCH, AMBUSH, REJUVENATE, FEAST_ATTENDANT,
	TRAMPLE, TWO_SLOT,
	YETI, MECH, TANK, SPRITE,
]

## Reinforce with a finite number of returns. "reinforce" is one return;
## "reinforce_4" is four (Commander Maurice).
##
## Deliberately ONE ability carrying its remaining count, not N repeated
## "reinforce" entries. With repeats, a single death fires the handler once
## per entry - several copies from one death - and each copy drops only one
## entry while inheriting the rest from the card definition, so the budget
## never really runs down.
func is_reinforce(ability: String) -> bool:
	return ability == REINFORCE or ability.begins_with(REINFORCE + "_")

func get_reinforce_uses(ability: String) -> int:
	if ability == REINFORCE:
		return 1
	if ability.begins_with(REINFORCE + "_"):
		return maxi(0, int(ability.substr(REINFORCE.length() + 1)))
	return 0

## Returns left on a live creature, across however it is spelled.
func reinforce_uses_of(minion: Minion) -> int:
	var best := 0
	for ability in minion.abilities:
		best = maxi(best, get_reinforce_uses(ability))
	return best

## The ability string for `uses` remaining, or "" for none left.
func reinforce_ability(uses: int) -> String:
	if uses <= 0:
		return ""
	return REINFORCE if uses == 1 else "%s_%d" % [REINFORCE, uses]

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

func is_deathrattle_damage_all_except_mech(ability: String) -> bool:
	return ability.begins_with(DEATHRATTLE_DAMAGE_ALL_EXCEPT_MECH + "_")

func get_deathrattle_damage_all_except_mech_value(ability: String) -> int:
	if is_deathrattle_damage_all_except_mech(ability):
		return int(ability.substr(DEATHRATTLE_DAMAGE_ALL_EXCEPT_MECH.length() + 1))
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
	if is_deathrattle_damage_all_except_mech(ability):
		return "On Death: %d to all except mechs" % get_deathrattle_damage_all_except_mech_value(ability)
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
	if is_deathrattle_damage_all_except_mech(ability):
		return Color(0.50, 0.20, 0.60)
	if is_transform(ability):
		return TRANSFORM_COLOR
	if is_transform_at_max_health(ability):
		return TRANSFORM_COLOR
	if ability == ON_PILOTED_GAIN_RUSH:
		return ON_PILOTED_GAIN_RUSH_COLOR
	return DEFINITIONS[ability]["color"]

func is_on_play_damage(ability: String) -> bool:
	return ability.begins_with(ON_PLAY_DAMAGE + "_") and not ability.begins_with(ON_PLAY_AOE_ENEMY + "_") and not ability.begins_with(ON_REINFORCE_DAMAGE + "_") and ability != ON_PLAY_DAMAGE_HIGH_ATTACK

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
			RUMMAGE:
				gs.pending_rummages.append({"player_id": owner.player_id, "max_cost": minion.data.cost, "type_filter": ""})
			RUMMAGE_AND_PLAY:
				gs.pending_rummages.append({"player_id": owner.player_id, "max_cost": minion.data.cost, "type_filter": "", "play_it": true})
			RUMMAGE_SPELL:
				gs.pending_rummages.append({"player_id": owner.player_id, "max_cost": -1, "type_filter": "stratagem"})
			NULL:
				gs.pending_nulls.append({"player_id": owner.player_id, "source": minion.data.card_name})
			ON_PLAY_TRANSFORM:
				if not minion.data.transform_into.is_empty():
					gs.apply_transform_choice(minion, minion.data.transform_into)
			ON_PLAY_BUFF_FRIENDLY_HEALTH:
				gs.pending_buff_friendly_health.append(owner.player_id)
			ON_PLAY_RESTORE_HEALTH:
				gs.request_choice(owner.player_id, GameState.CHOICE_RESTORE_HEALTH, 1, minion)
			ON_PLAY_BUFF_OTHER_FRIENDLY:
				gs.request_choice(owner.player_id, GameState.CHOICE_BUFF_OTHER_FRIENDLY, 1, minion)
			ON_PLAY_DAMAGE_HIGH_ATTACK:
				gs.request_choice(owner.player_id, GameState.CHOICE_DAMAGE_HIGH_ATTACK, 4, minion)
			ON_PLAY_RUMMAGE_BUFF:
				if minion.data.rummage_count > 0:
					minion.current_attack += minion.data.rummage_count
					gs.gain_max_health(minion, minion.data.rummage_count)
			ON_PLAY_BUFF_FRIENDLY_YETI_ATK:
				for m in owner.board:
					if m != minion and m.has_ability(YETI):
						m.current_attack += 2
			ON_PLAY_HEAL_FRIENDLY_YETIS:
				# One group, no target picker. The recipients are fixed up
				# front so a reaction that changes the board mid-heal can
				# neither skip nor repeat one; restore_health() is the shared
				# pipeline (cap at max, Crypt Hunger/Apothecary reactions) and
				# does nothing - fires nothing - for a full-health creature.
				var recipients: Array[Minion] = []
				for m in owner.board:
					if m != minion and m.has_ability(YETI) and not m.is_location():
						recipients.append(m)
				for m in recipients:
					if m in owner.board and not m.is_dead():
						gs.restore_health(m, 2)
			ON_PLAY_BUFF_IF_YETI:
				for m in owner.board:
					if m != minion and m.has_ability(YETI):
						minion.current_attack += 2
						gs.gain_max_health(minion, 1)
						break
			GROWVIN_AURA:
				for m in owner.board:
					if m != minion and m.has_ability(MECH):
						gs._apply_growvin_aura_to_mech(m, owner.player_id)
			ON_PLAY_BUFF_ALL_FRIENDLY_HEALTH:
				for m in owner.board.duplicate():
					gs.gain_max_health(m, 1)
			ON_PLAY_VOIDTOUCH_IF_RUMMAGED:
				if minion.data.rummage_count > 0 and not minion.has_ability(VOIDTOUCH):
					minion.abilities.append(VOIDTOUCH)
			ON_PLAY_HEALTH_PER_FRIENDLY:
				var others: int = owner.board.size() - 1
				if others > 0:
					gs.gain_max_health(minion, others)
			STATS_FROM_GRAVEYARD:
				# Floors at 1 so playing this on an empty graveyard doesn't put
				# a 0/0 on the board that instantly dies.
				var pile: int = maxi(1, owner.graveyard.size())
				minion.current_attack = pile
				minion.max_health = pile
				minion.current_health = pile
			RUMMAGE_BUFF_CREATURE:
				gs.pending_rummages.append({"player_id": owner.player_id, "max_cost": minion.data.cost, "type_filter": "", "buff_creature": true})
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
					gs.gain_max_health(minion, total_hp)
				gs._check_win_condition()
	_fire_on_play_decisions(minion, owner, gs)
	for ability in minion.abilities:
		if is_on_play_aoe_enemy(ability):
			var damage = get_on_play_aoe_enemy_value(ability)
			var enemy = gs.opponent if owner == gs.player else gs.player
			# Through the shared damage path, with this creature's controller
			# as the source: take_damage() writes to the creature directly and
			# skips the enemy-damage amplification that every other on-play
			# damage route applies, so an amplified board wiped for the
			# printed number instead of the amplified one.
			#
			# Damage is dealt to the whole group BEFORE any removal, so
			# simultaneous lethal damage stays simultaneous (see
			# GameState._remove_dead_minions).
			var amp := gs._get_enemy_damage_amp(owner.player_id)
			for m in enemy.board.duplicate():
				m.take_damage(damage + amp)
			gs._remove_dead_minions()
			gs._check_win_condition()
			break

## The on-play effects that need a player decision (or a loop over targets).
## They used to run in four controllers; they live here so one implementation
## serves local play, the AI, the search and the match host. Requests queue in
## this order and are answered one at a time (see GameState.request_choice).
func _fire_on_play_decisions(minion: Minion, owner: PlayerState, gs: GameState) -> void:
	var pid := owner.player_id
	if minion.has_ability(ON_PLAY_TRANSFORM_CHOICE) and not minion.data.transform_choices.is_empty():
		gs.request_choice(pid, GameState.CHOICE_TRANSFORM, 0, minion)
	for ability in minion.abilities:
		if is_on_play_damage(ability):
			gs.request_choice(pid, GameState.CHOICE_DAMAGE_TARGET, get_on_play_damage_value(ability), minion)
			break
	if minion.has_ability(CHALLENGE):
		gs.request_choice(pid, GameState.CHOICE_CHALLENGE, 0, minion)
	if minion.has_ability(ON_PLAY_YETI_CHALLENGE):
		gs.request_choice(pid, GameState.CHOICE_PICK_CHALLENGER, 0, minion, {"exclude": minion.instance_id})
	if minion.has_ability(CHALLENGE_ALL):
		var enemy := gs.find_player(gs._opponent_id(pid))
		for target in enemy.board.duplicate():
			if minion.is_dead() or minion not in owner.board or gs.current_phase == GameState.Phase.GAME_OVER:
				break
			if target not in enemy.board or target.has_ability(AMBUSH):
				continue
			gs.apply_challenge(minion, target)
	if minion.has_ability(ON_PLAY_PILOT_MECH):
		gs.request_choice(pid, GameState.CHOICE_PILOT_TARGET, 0, minion)
	if minion.has_ability(ON_PLAY_CHALLENGE_WIN_BUFF):
		gs.request_choice(pid, GameState.CHOICE_CHALLENGE, 1, minion)
	if minion.has_ability(ON_PLAY_SWAP_FRIENDLY_HEALTH):
		gs.request_choice(pid, GameState.CHOICE_SWAP_HEALTH, 0, minion)
	if minion.has_ability(ON_PLAY_DEVOUR_FRIENDLY):
		gs.request_choice(pid, GameState.CHOICE_DEVOUR, 0, minion)

func fire_on_attack(attacker: Minion, owner: PlayerState, gs: GameState) -> void:
	for ability in attacker.abilities:
		match ability:
			ATTACK_BUFF_FRIENDLY_HEALTH:
				if not owner.board.is_empty():
					var target: Minion = gs.rand_pick(owner.board)
					gs.gain_max_health(target, 1)
			ATTACK_RUMMAGE:
				gs.pending_rummages.append({"player_id": owner.player_id, "max_cost": attacker.data.cost, "type_filter": ""})

func fire_on_defend(defender: Minion, owner: PlayerState, gs: GameState) -> void:
	for ability in defender.abilities:
		match ability:
			WHEN_ATTACKED_BUFF_FRIENDLY:
				for m in owner.board.duplicate():
					gs.gain_max_health(m, 1)

## Where to put a replacement creature back on the board.
##
## The slot recorded when a creature died can be past the end of the board by
## the time its death trigger runs: deaths resolve in GROUPS (see
## GameState._remove_dead_minions), so several creatures may have been removed
## between the position being recorded and this firing. Array.insert() with an
## out-of-range index logs an error and does nothing at all, so the
## replacement was silently never placed - a Reinforce that simply did not
## happen whenever its creature died alongside others.
func _safe_board_index(owner: PlayerState, board_index: int) -> int:
	return clampi(board_index, 0, owner.board.size())

func fire_on_death(minion: Minion, owner: PlayerState, board_index: int, enemy: PlayerState, gs: GameState) -> Dictionary:
	var drawn: Array[CardData] = []
	var tank_shots: int = 0
	# Reinforce resolves once per death, before the ability loop, so a
	# creature with several returns left still comes back exactly once and
	# the replacement carries the reduced budget.
	var reinforce_uses := reinforce_uses_of(minion)
	if reinforce_uses > 0:
		_reinforce_minion(minion, owner, board_index, gs, reinforce_uses - 1)
	for ability in minion.abilities:
		match ability:
			DEATHRATTLE_DRAW_YETI:
				var card = _draw_by_tag(owner, YETI, gs)
				if card:
					drawn.append(card)
			DEATHRATTLE_DRAW_TANK:
				var card = _draw_by_tag(owner, TANK, gs)
				if card:
					drawn.append(card)
			DEATHRATTLE_DRAW_CARD:
				if not owner.deck.is_empty() and owner.hand.size() < owner.MAX_HAND_SIZE:
					var card: CardData = owner.deck.pop_back().new_instance(owner.mint_card_uid())
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
			DEATHRATTLE_TRANSFORM:
				if not minion.data.transform_into.is_empty():
					var new_data = CardDatabase.get_card(minion.data.transform_into)
					if new_data != null:
						var new_minion = Minion.new(new_data, minion.owner_id, owner.mint_minion_id(new_data.id))
						new_minion.is_newly_reinforced = true
						owner.board.insert(_safe_board_index(owner, board_index), new_minion)
			DEATHRATTLE_AOE_TRANSFORM:
				# Unamplified, deliberately. _get_enemy_damage_amp() is the
				# bonus a player's own board adds to damage THEY deal to the
				# enemy; this hits both boards symmetrically, so there is no
				# single amp that applies to all of it. Amplifying only the
				# enemy half is defensible but is a rules decision nobody has
				# made - see .docs/abilities.md, "damage amplification scope".
				for p in [gs.player, gs.opponent]:
					for m in p.board:
						m.take_damage(1)
				if not minion.data.transform_into.is_empty():
					var new_data = CardDatabase.get_card(minion.data.transform_into)
					if new_data != null:
						var new_minion = Minion.new(new_data, minion.owner_id, owner.mint_minion_id(new_data.id))
						new_minion.is_newly_reinforced = true
						owner.board.insert(_safe_board_index(owner, board_index), new_minion)
			EJECT_PILOT_ON_DEATH:
				if minion.is_piloted and minion.piloted_by != null:
					if owner.has_room_for(minion.piloted_by.abilities):
						var pilot_minion = Minion.new(minion.piloted_by, minion.owner_id, owner.mint_minion_id(minion.piloted_by.id))
						pilot_minion.is_newly_reinforced = true
						owner.board.insert(_safe_board_index(owner, board_index), pilot_minion)
					elif owner.hand.size() < owner.MAX_HAND_SIZE:
						owner.hand.append(minion.piloted_by)
			GROWVIN_AURA:
				gs._remove_growvin_aura(owner.player_id)
	for ability in minion.abilities:
		if is_deathrattle_damage_all_except_mech(ability):
			var damage = get_deathrattle_damage_all_except_mech_value(ability)
			# Unamplified for the same reason as DEATHRATTLE_AOE_TRANSFORM
			# above: this hits both boards.
			for p in [gs.player, gs.opponent]:
				for m in p.board:
					if m.has_ability(MECH):
						continue
					m.take_damage(damage)
			break
	if YETI in minion.abilities:
		for watcher in owner.board:
			if watcher.has_ability(ON_FRIENDLY_YETI_DEATH_BUFF):
				gs.gain_max_health(watcher, 2)
		for watcher in owner.board:
			if watcher.has_ability(ON_YETI_DEATH_CHALLENGE):
				gs.pending_overwatch_challenges.append(owner.player_id)
				break
	if MECH in minion.abilities:
		for watcher in owner.board:
			if watcher.has_ability(ON_FRIENDLY_MECH_DEATH_BUFF):
				watcher.current_attack += 1
				gs.gain_max_health(watcher, 1)
	# Corporal Garrick. The dying minion is already off the board by the time
	# this runs, so a lone Garrick can never save itself - only the creatures
	# it outlives.
	if owner.player_id not in gs.death_reinforce_used:
		for watcher in owner.board:
			if not watcher.has_ability(ON_FRIENDLY_DEATH_REINFORCE):
				continue
			if not owner.has_room_for(minion.data.abilities):
				break
			gs.death_reinforce_used.append(owner.player_id)
			# Garrick's save is its own effect, not a Reinforce use: a saved
			# creature keeps whatever returns it still had.
			_reinforce_minion(minion, owner, board_index, gs, reinforce_uses_of(minion))
			break
	return {"drawn": drawn, "tank_shots": tank_shots}

## Puts a fresh copy of `minion` back on the board at `board_index` and fires
## everything that watches for a reinforce. Shared by the Reinforce keyword
## and Corporal Garrick's once-per-turn save. The copy never keeps REINFORCE
## itself, so nothing can chain-revive forever.
func _reinforce_minion(minion: Minion, owner: PlayerState, board_index: int, gs: GameState,
					   remaining_uses: int = 0) -> Minion:
	var copy := Minion.new(minion.data, minion.owner_id, owner.mint_minion_id(minion.data.id))
	# The copy is built from the card DEFINITION, so it starts with whatever
	# Reinforce is printed on the card. Strip that and put back only what is
	# actually left, or a returned Maurice would be handed a fresh four.
	var kept: Array[String] = []
	for ab in copy.abilities:
		if not is_reinforce(ab):
			kept.append(ab)
	copy.abilities = kept
	var carried := reinforce_ability(remaining_uses)
	if not carried.is_empty():
		copy.abilities.append(carried)
	copy.card_uid = minion.card_uid
	copy.is_newly_reinforced = true
	owner.board.insert(_safe_board_index(owner, board_index), copy)
	for m in owner.board:
		if m != copy and m.has_ability(TACTICAL_OFFICER):
			copy.current_attack += 1
	for ab in minion.abilities:
		if is_on_reinforce_damage(ab):
			gs.pending_on_reinforce_damages.append({"player_id": owner.player_id, "damage": get_on_reinforce_damage_value(ab), "source": minion.data.card_name})
			break
	for watcher in owner.board:
		for ab in watcher.abilities:
			if is_on_any_reinforce_shot(ab):
				gs.pending_on_reinforce_damages.append({"player_id": watcher.owner_id, "damage": get_on_any_reinforce_shot_value(ab), "source": watcher.data.card_name})
				break
	return copy

func fire_on_rummage(owner: PlayerState, gs: GameState) -> void:
	for m in owner.board:
		if m.has_ability(RUMMAGE_BUFF):
			gs.gain_max_health(m, 1)
	for m in owner.board:
		if m.has_ability(RUMMAGE_DRAW):
			var drawn = owner.draw_card()
			if drawn != null and owner.player_id == gs.player.player_id:
				gs.pending_drawn_cards.append(drawn)

func _draw_by_tag(owner: PlayerState, tag: String, gs: GameState) -> CardData:
	var matching: Array[CardData] = []
	for card in owner.deck:
		if tag in card.abilities:
			matching.append(card)
	if matching.is_empty() or owner.hand.size() >= owner.MAX_HAND_SIZE:
		return null
	var chosen: CardData = gs.rand_pick(matching)
	owner.deck.erase(chosen)
	var copy: CardData = chosen.new_instance(owner.mint_card_uid())
	owner.hand.append(copy)
	return copy
	return copy
