extends Node

const MAX_DECK_SIZE := 40
const MAX_COPIES := 2
const SAVE_DIR := "user://decks/"
const LS_PREFIX := "cardgame_deck_"

const FACTION_NAMES = ["SAPIENS", "MOONLIGHT COVEN", "JUNKLINGS", "GUNDARI", "INYUITES"]
const FACTION_SWATCHES = [
	Color(0.20, 0.65, 0.20),  # GREEN
	Color(0.80, 0.20, 0.20),  # CRIMSON
	Color(0.25, 0.25, 0.25),  # BLACK
	Color(0.90, 0.50, 0.10),  # ORANGE
	Color(0.10, 0.60, 0.70),  # TEAL
	Color(0.55, 0.55, 0.62),  # GENERIC
]

func _ready() -> void:
	if not OS.has_feature("web"):
		DirAccess.make_dir_absolute(SAVE_DIR)

# ── Copy limits ────────────────────────────────────────────────────────

func max_copies_for(card: CardData) -> int:
	return 1 if card.rarity == CardData.CardRarity.LEGENDARY else MAX_COPIES

# ── Deck builders ──────────────────────────────────────────────────────

func build_random_faction_deck(faction_color: CardData.CardColor) -> Array[CardData]:
	var pool: Array[CardData] = []
	for card in CardDatabase.get_all_cards():
		if card.is_token:
			continue
		if card.color != faction_color and card.color != CardData.CardColor.GENERIC:
			continue
		var copies := max_copies_for(card)
		for _i in copies:
			pool.append(card)
	pool.shuffle()
	var deck: Array[CardData] = []
	for card in pool:
		if deck.size() >= MAX_DECK_SIZE:
			break
		deck.append(card)
	return deck

func build_deck_from_ids(ids: Array[String]) -> Array[CardData]:
	var deck: Array[CardData] = []
	for id in ids:
		var c := CardDatabase.get_card(id)
		if c != null:
			deck.append(c)
	deck.shuffle()
	return deck

# ── Archetype deck builder ────────────────────────────────────────────
# Picks an archetype the faction's card pool actually supports, then
# weighted-samples a deck that leans into that archetype's tags and curve.

enum Archetype { MIDRANGE, AGGRO, TRIBAL, VALUE }

const ARCHETYPE_NAMES := {
	Archetype.MIDRANGE: "Midrange",
	Archetype.AGGRO: "Aggro",
	Archetype.TRIBAL: "Tribal",
	Archetype.VALUE: "Value",
}

const ARCHETYPE_TAG_WEIGHTS := {
	Archetype.AGGRO: {
		"rush": 3.0, "dual_strike": 3.0, "challenge": 2.0, "force_challenge": 2.0,
		"challenge_all": 2.0, "ambush": 2.0, "cloaked": 1.0,
		"on_play_challenge_win_buff": 2.0, "on_yeti_challenge_attack": 2.0,
		"on_piloted_gain_rush": 2.0, "pilot_gives_rush": 2.0,
	},
	Archetype.TRIBAL: {
		"yeti": 2.0, "mech": 2.0, "tank": 2.0, "bat": 2.0, "wolf": 2.0, "monstrosity": 2.0,
		"on_play_pilot_mech": 3.0, "eject_pilot": 1.0, "eject_pilot_on_death": 1.0,
		"eject_all_pilots": 1.0, "on_piloted_gain_cloaked": 2.0, "on_piloted_stat_boost": 2.0,
		"pilot_gives_cloaked": 2.0, "pilot_gives_guardian": 2.0,
		"on_play_buff_if_yeti": 2.0, "on_play_buff_friendly_yeti_attack": 2.0,
		"on_play_yeti_challenge": 2.0, "on_yeti_death_challenge": 2.0, "on_yeti_challenge_buff": 2.0,
		"on_friendly_yeti_death_buff": 2.0, "on_friendly_mech_death_buff": 2.0,
		"on_friendly_tank_death_buff_tank": 2.0, "rummage_mech_on_death": 2.0,
		"on_friendly_transform_buff_self": 2.0, "on_friendly_transform_give_ambush": 2.0,
		"mirror_transform": 1.0, "on_play_transform_choice": 1.0, "deathrattle_aoe_transform": 2.0,
		"growvin_aura": 2.0, "broodtender_aura": 2.0, "tactical_officer": 1.0,
	},
	Archetype.VALUE: {
		"guardian": 2.0, "rummage": 3.0, "rummage_buff": 2.0, "rummage_draw": 2.0,
		"rummage_spell": 2.0, "rummage_and_play": 2.0, "rummage_equal_cost": 2.0,
		"reinforce": 2.0, "recon": 1.0, "heal": 2.0, "heal_to_draw": 2.0,
		"deathrattle_draw_card": 2.0, "deathrattle_draw_yeti": 2.0, "deathrattle_draw_tank": 2.0,
		"deathrattle_return_stratagem": 2.0, "deathrattle_rummage_creature": 2.0,
		"destroy_all_creatures": 2.0, "deal_damage_all_enemy": 2.0, "null": 2.0,
		"give_mech_shielded_temp": 2.0, "combat_immune": 2.0, "apothecary": 1.0,
		"blood_transfusion": 2.0, "sanguine": 2.0,
		# Health-gain *enablers* (not just the payoffs that consume them) — without
		# these, the builder over-drafts cards like Delos/Haven Guard that need a
		# trigger to matter, without also prioritizing the cards that trigger them.
		"on_play_buff_friendly_health": 2.0, "attack_buff_friendly_health": 2.0,
		"when_attacked_buff_friendly": 2.0, "on_play_swap_friendly_health": 1.5,
	},
}

const ARCHETYPE_CURVE_WEIGHTS := {
	Archetype.AGGRO:    {1: 1.6, 2: 1.5, 3: 1.3, 4: 1.0, 5: 0.7, 6: 0.4, 7: 0.3},
	Archetype.TRIBAL:   {1: 0.8, 2: 1.2, 3: 1.4, 4: 1.3, 5: 1.1, 6: 0.9, 7: 0.8},
	Archetype.VALUE:    {1: 0.6, 2: 1.0, 3: 1.2, 4: 1.3, 5: 1.3, 6: 1.1, 7: 1.1},
	Archetype.MIDRANGE: {1: 1.0, 2: 1.2, 3: 1.3, 4: 1.2, 5: 1.0, 6: 0.8, 7: 0.7},
}

## Weights for dynamic-suffix ability tags (e.g. "pilot_1_3", "shielded_2")
## that ARCHETYPE_TAG_WEIGHTS can't match by exact string. Matched by prefix,
## and only checked when there's no exact-tag hit above.
const ARCHETYPE_TAG_PREFIXES := {
	Archetype.TRIBAL: {
		"pilot_": 2.0,
		"transform_at_max_health_": 1.5,
	},
	Archetype.VALUE: {
		"shielded_": 2.0,
		"rejuvenate_": 1.5,
		"enemy_damage_amp_": 1.5,
		"on_play_damage_": 1.5,
		"on_play_aoe_enemy_": 2.0,
		"on_reinforce_damage_": 1.5,
		"on_any_reinforce_shot_": 1.5,
	},
}

const MIN_ARCHETYPE_SUPPORT := 6.0
const MIDRANGE_BASE_WEIGHT := 4.0

func _tag_weight(archetype: int, ability: String) -> float:
	var tag_weights: Dictionary = ARCHETYPE_TAG_WEIGHTS.get(archetype, {})
	if tag_weights.has(ability):
		return float(tag_weights[ability])
	var prefixes: Dictionary = ARCHETYPE_TAG_PREFIXES.get(archetype, {})
	for prefix in prefixes:
		if ability.begins_with(prefix):
			return float(prefixes[prefix])
	return 0.0

func build_archetype_deck(faction_color: CardData.CardColor) -> Array[CardData]:
	return _build_deck_for_archetype(faction_color, pick_archetype_for(faction_color))

## Chooses an archetype weighted by how much the faction's own cards (generic
## excluded) actually support it, so a color without real tribal identity
## won't get pushed into a hollow Tribal deck. Midrange is always a fallback
## option so the pick isn't deterministic even for lopsided colors.
func pick_archetype_for(faction_color: CardData.CardColor) -> int:
	var pool := _faction_pool(faction_color, false)
	var candidates: Array[int] = [Archetype.MIDRANGE]
	var weights: Array[float] = [MIDRANGE_BASE_WEIGHT]
	for archetype in ARCHETYPE_TAG_WEIGHTS:
		var support := _archetype_support(pool, archetype)
		if support >= MIN_ARCHETYPE_SUPPORT:
			candidates.append(archetype)
			weights.append(support)
	return candidates[_weighted_index(weights)]

## Stratagems carry their identity in `effect` (e.g. "blood_transfusion"),
## not `abilities` (which is empty for every stratagem card), so both must
## be checked or every stratagem scores as archetype-blind baseline.
func _card_tag_score(card: CardData, archetype: int) -> float:
	var score := 0.0
	for ability in card.abilities:
		score += _tag_weight(archetype, ability)
	if not card.effect.is_empty():
		score += _tag_weight(archetype, card.effect)
	return score

func _archetype_support(pool: Array[CardData], archetype: int) -> float:
	var total := 0.0
	for card in pool:
		total += _card_tag_score(card, archetype)
	return total

func _build_deck_for_archetype(faction_color: CardData.CardColor, archetype: int) -> Array[CardData]:
	var pool := _faction_pool(faction_color, true)
	var entries: Array[CardData] = []
	var weights: Array[float] = []
	for card in pool:
		var score := _score_card(card, archetype)
		for _i in max_copies_for(card):
			entries.append(card)
			weights.append(score)
	return _weighted_take(entries, weights, MAX_DECK_SIZE)

## Raw stat quality always contributes, not just archetype tag matches —
## otherwise a weak card whose only asset is a matching tag (e.g. a 1/3 for 3
## that merely triggers on a teammate transforming) outscores a strong
## standalone body with no tags at all, and the builder over-drafts duds.
func _score_card(card: CardData, archetype: int) -> float:
	var tag_score := _card_tag_score(card, archetype)
	var curve_weights: Dictionary = ARCHETYPE_CURVE_WEIGHTS.get(archetype, {})
	var curve_weight: float = curve_weights.get(clampi(card.cost, 1, 7), 1.0)
	var stat_quality := 1.0
	if card.card_type == CardData.CardType.CREATURE and card.cost > 0:
		stat_quality = maxf(1.0, float(card.attack + card.health) / float(card.cost))
	return (stat_quality + tag_score) * curve_weight

func _faction_pool(faction_color: CardData.CardColor, include_generic: bool) -> Array[CardData]:
	var pool: Array[CardData] = []
	for card in CardDatabase.get_all_cards():
		if card.is_token:
			continue
		if card.color == faction_color:
			pool.append(card)
		elif include_generic and card.color == CardData.CardColor.GENERIC:
			pool.append(card)
	return pool

func _weighted_index(weights: Array[float]) -> int:
	var total := 0.0
	for w in weights:
		total += w
	if total <= 0.0:
		return randi() % weights.size()
	var r := randf() * total
	var acc := 0.0
	for i in weights.size():
		acc += weights[i]
		if r <= acc:
			return i
	return weights.size() - 1

func _weighted_take(entries: Array[CardData], weights: Array[float], count: int) -> Array[CardData]:
	var result: Array[CardData] = []
	var idxs: Array[int] = []
	for i in entries.size():
		idxs.append(i)
	while result.size() < count and idxs.size() > 0:
		var sub_weights: Array[float] = []
		for i in idxs:
			sub_weights.append(weights[i])
		var pick := _weighted_index(sub_weights)
		result.append(entries[idxs[pick]])
		idxs.remove_at(pick)
	return result

# ── Deck listings ──────────────────────────────────────────────────────

func get_starter_decks() -> Array[Dictionary]:
	var file := FileAccess.open("res://data/starters.json", FileAccess.READ)
	if not file:
		return []
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Array:
		return []
	var out: Array[Dictionary] = []
	for entry in parsed:
		if entry is Dictionary and entry.has("card_ids"):
			var d: Dictionary = entry.duplicate()
			d["is_starter"] = true
			out.append(d)
	return out

func get_all_decks() -> Array[Dictionary]:
	var out := get_starter_decks()
	out.append_array(get_custom_decks())
	return out

func get_custom_decks() -> Array[Dictionary]:
	if OS.has_feature("web"):
		return _load_from_localstorage()
	return _load_from_files()

# ── Save / delete ──────────────────────────────────────────────────────

func save_deck(deck_name: String, faction_idx: int, card_ids: Array[String]) -> void:
	var data := {"name": deck_name, "faction_idx": faction_idx, "card_ids": Array(card_ids)}
	var json_str := JSON.stringify(data)
	if OS.has_feature("web"):
		var key := JSON.stringify(LS_PREFIX + _safe(deck_name))
		var val := JSON.stringify(json_str)
		JavaScriptBridge.eval("localStorage.setItem(%s, %s)" % [key, val])
	else:
		var file := FileAccess.open(SAVE_DIR + _safe(deck_name) + ".json", FileAccess.WRITE)
		if file:
			file.store_string(json_str)
			file.close()

func delete_deck(deck_name: String) -> void:
	if OS.has_feature("web"):
		var key := JSON.stringify(LS_PREFIX + _safe(deck_name))
		JavaScriptBridge.eval("localStorage.removeItem(%s)" % key)
	else:
		DirAccess.remove_absolute(SAVE_DIR + _safe(deck_name) + ".json")

# ── Internal loaders ───────────────────────────────────────────────────

func _load_from_localstorage() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var js := "(function(){"
	js += "var keys=[];"
	js += "for(var i=0;i<localStorage.length;i++){"
	js += "var k=localStorage.key(i);"
	js += "if(k.startsWith('%s'))keys.push(k);" % LS_PREFIX
	js += "}return JSON.stringify(keys);})()"
	var result = JavaScriptBridge.eval(js)
	if result == null:
		return out
	var keys = JSON.parse_string(str(result))
	if not keys is Array:
		return out
	for key in keys:
		var val = JavaScriptBridge.eval("localStorage.getItem(%s)" % JSON.stringify(str(key)))
		if val == null:
			continue
		var parsed = JSON.parse_string(str(val))
		if parsed is Dictionary and parsed.has("card_ids"):
			var d: Dictionary = parsed
			if not d.has("faction_idx"):
				d["faction_idx"] = 0
			d["is_starter"] = false
			out.append(d)
	return out

func _load_from_files() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			var file := FileAccess.open(SAVE_DIR + fname, FileAccess.READ)
			if file:
				var parsed = JSON.parse_string(file.get_as_text())
				file.close()
				if parsed is Dictionary and parsed.has("card_ids"):
					var d: Dictionary = parsed
					if not d.has("faction_idx"):
						d["faction_idx"] = 0
					d["is_starter"] = false
					out.append(d)
		fname = dir.get_next()
	return out

func _safe(name: String) -> String:
	return name.strip_edges().replace("/", "_").replace("\\", "_").replace(":", "_")
