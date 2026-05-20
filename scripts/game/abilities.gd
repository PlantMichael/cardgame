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
const SAFEGUARD              = "safeguard"
const TACTICAL_OFFICER       = "tactical_officer"
const DEATHRATTLE_RETURN_STRATAGEM = "deathrattle_return_stratagem"
const DEATHRATTLE_DRAW_CARD = "deathrattle_draw_card"
const RUMMAGE_BUFF           = "rummage_buff"
const RUMMAGE_DRAW           = "rummage_draw"
const SPRITE                 = "sprite"
const NULL                   = "null"
const ON_YETI_CHALLENGE_BUFF = "on_yeti_challenge_buff"
const ON_YETI_DEATH_CHALLENGE = "on_yeti_death_challenge"
const ON_PLAY_RUMMAGE_BUFF      = "on_play_rummage_buff"
const ATTACK_BUFF_FRIENDLY_HEALTH = "attack_buff_friendly_health"

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
	SAFEGUARD:              { "display": "Safeguard",   "color": Color(0.20, 0.50, 0.80) },
	TACTICAL_OFFICER:       { "display": "Officer",     "color": Color(0.25, 0.55, 0.25) },
	DEATHRATTLE_RETURN_STRATAGEM: { "display": "On Death:", "color": Color(0.50, 0.20, 0.60) },
	DEATHRATTLE_DRAW_CARD:        { "display": "On Death:", "color": Color(0.50, 0.20, 0.60) },
	RUMMAGE_BUFF:                 { "display": "Rummage Buff", "color": Color(0.30, 0.08, 0.42) },
	RUMMAGE_DRAW:                 { "display": "Rummage Draw", "color": Color(0.30, 0.08, 0.42) },
	SPRITE:                       { "display": "Sprite",      "color": Color(0.75, 0.20, 0.60) },
	NULL:                         { "display": "Silence",     "color": Color(0.35, 0.15, 0.55) },
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
}

const ON_PLAY_DAMAGE             = "on_play_damage"
const TRANSFORM                  = "transform"
const TRANSFORM_AT_MAX_HEALTH    = "transform_at_max_health"
const COMBAT_IMMUNE              = "combat_immune"
const ON_PLAY_TRANSFORM_CHOICE   = "on_play_transform_choice"
const ON_PLAY_BUFF_FRIENDLY_HEALTH = "on_play_buff_friendly_health"
const WHEN_ATTACKED_BUFF_FRIENDLY  = "when_attacked_buff_friendly"
const APOTHECARY                   = "apothecary"
const MIRROR_TRANSFORM             = "mirror_transform"

const TRIBES: Array = [YETI, MECH, TANK, SPRITE]

func is_tribe(ability: String) -> bool:
	return ability in TRIBES

const ON_PLAY_DAMAGE_COLOR := Color(0.55, 0.12, 0.55)
const PILOT_COLOR          := Color(0.85, 0.45, 0.05)
const TRANSFORM_COLOR      := Color(0.80, 0.25, 0.10)

func get_display(ability: String) -> String:
	if is_on_play_damage(ability):
		return "On Play: %d dmg" % get_on_play_damage_value(ability)
	if is_pilot(ability):
		return "Pilot %d/%d" % [get_pilot_attack(ability), get_pilot_health(ability)]
	if is_transform(ability):
		return "Transform: %d" % get_transform_threshold(ability)
	if is_transform_at_max_health(ability):
		return "Transform at %dhp" % get_transform_health_threshold(ability)
	return DEFINITIONS[ability]["display"]

func get_color(ability: String) -> Color:
	if is_on_play_damage(ability):
		return ON_PLAY_DAMAGE_COLOR
	if is_pilot(ability):
		return PILOT_COLOR
	if is_transform(ability):
		return TRANSFORM_COLOR
	if is_transform_at_max_health(ability):
		return TRANSFORM_COLOR
	return DEFINITIONS[ability]["color"]

func is_on_play_damage(ability: String) -> bool:
	return ability.begins_with(ON_PLAY_DAMAGE + "_")

func get_on_play_damage_value(ability: String) -> int:
	if is_on_play_damage(ability):
		return int(ability.substr(ON_PLAY_DAMAGE.length() + 1))
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

func trigger_death(minion: Minion, owner: PlayerState, board_index: int, enemy: PlayerState = null) -> Dictionary:
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
	return {"drawn": drawn, "tank_shots": tank_shots}

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
