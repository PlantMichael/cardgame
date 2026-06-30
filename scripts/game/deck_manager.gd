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
