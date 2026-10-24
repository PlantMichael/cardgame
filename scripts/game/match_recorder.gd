class_name MatchRecorder
extends RefCounted

## Per-match facts for the card statistics database (specs/002-card-stats-database),
## captured inside the server-run match host where the real state lives, so the
## numbers are verified by construction rather than reported by a client.
##
## Per seat it records the starting deck, and for each deck card how many copies
## were drawn, kept through the mulligan and played, plus the first turn one was
## played. A card whose uid was not in the starting deck (a token, a created or
## returned card) is counted separately and never as a deck card.
##
## It only observes: it reads the state and the event feed after each command
## and never changes either. It is created by MatchHost for real matches only,
## never by duplicate_for_sim(), so AI search cannot record.

const SEATS := ["host", "guest"]

var _seat := {}   # player id -> {uids, copies, drawn, kept, played, first_played, created, opening, mulligan_done}
var turns: int = 0

func begin(gs: GameState) -> void:
	for p in [gs.player, gs.opponent]:
		var uids := {}
		var copies := {}
		var opening := {}
		for c in p.deck:
			uids[c.uid] = c.id
			copies[c.id] = int(copies.get(c.id, 0)) + 1
		for c in p.hand:
			uids[c.uid] = c.id
			copies[c.id] = int(copies.get(c.id, 0)) + 1
			opening[c.uid] = true
		_seat[p.player_id] = {
			"uids": uids, "copies": copies, "opening": opening,
			"drawn": opening.duplicate(), "kept": {}, "played": {}, "first_played": {},
			"created": {}, "mulligan_done": false,
		}

## Called after every accepted command / timeout with the events it produced.
func observe(gs: GameState, events: Array) -> void:
	turns = gs.turn_number
	for e in events:
		var owner_id := str(e.get("owner", ""))
		if not _seat.has(owner_id):
			continue
		var s: Dictionary = _seat[owner_id]
		match str(e.get("type", "")):
			"draw":
				_note_card(s, str(e.get("uid", "")), str(e.get("card_id", "")), true)
			"play":
				var uid := str(e.get("uid", ""))
				var card_id := str(e.get("card_id", ""))
				if (s["uids"] as Dictionary).has(uid):
					s["played"][card_id] = int(s["played"].get(card_id, 0)) + 1
					if not (s["first_played"] as Dictionary).has(card_id):
						s["first_played"][card_id] = gs.turn_number
				else:
					_note_card(s, uid, card_id, false)
	# Once a seat's mulligan is over, what it still holds of its opening hand was kept,
	# and what replaced the rest was drawn.
	for p in [gs.player, gs.opponent]:
		var s: Dictionary = _seat[p.player_id]
		if s["mulligan_done"] or gs.mulligan_pending.get(p.player_id, false):
			continue
		s["mulligan_done"] = true
		var in_hand := {}
		for c in p.hand:
			in_hand[c.uid] = true
		for uid in s["opening"]:
			if in_hand.has(uid):
				s["kept"][uid] = true
		for c in p.hand:
			if not (s["opening"] as Dictionary).has(c.uid):
				_note_card(s, c.uid, c.id, true)

func _note_card(s: Dictionary, uid: String, card_id: String, drawn: bool) -> void:
	if uid.is_empty() or card_id.is_empty():
		return
	if (s["uids"] as Dictionary).has(uid):
		if drawn:
			s["drawn"][uid] = true
	else:
		# Not from the starting deck: counted as created, once per physical copy.
		if not (s["created"] as Dictionary).has(uid):
			s["created"][uid] = card_id

## The facts for both seats, keyed by seat letter, in a JSON-safe shape.
func facts(gs: GameState) -> Dictionary:
	var out := {"turns": turns, "seats": {}}
	for pid in SEATS:
		if not _seat.has(pid):
			continue
		var s: Dictionary = _seat[pid]
		var uids: Dictionary = s["uids"]
		var drawn_by_card := {}
		var kept_by_card := {}
		for uid in s["drawn"]:
			if uids.has(uid):
				drawn_by_card[uids[uid]] = int(drawn_by_card.get(uids[uid], 0)) + 1
		for uid in s["kept"]:
			if uids.has(uid):
				kept_by_card[uids[uid]] = int(kept_by_card.get(uids[uid], 0)) + 1
		var deck_cards: Array = []
		var ids: Array = (s["copies"] as Dictionary).keys()
		ids.sort()
		for cid in ids:
			deck_cards.append({
				"card_id": cid,
				"copies": int(s["copies"][cid]),
				"drawn_copies": int(drawn_by_card.get(cid, 0)),
				"kept_copies": int(kept_by_card.get(cid, 0)),
				"played_copies": int(s["played"].get(cid, 0)),
				"first_played_turn": s["first_played"].get(cid, null),
			})
		var created := {}
		for uid in s["created"]:
			var cid := str(s["created"][uid])
			created[cid] = int(created.get(cid, 0)) + 1
		out["seats"]["a" if pid == "host" else "b"] = {"deck_cards": deck_cards, "created": created}
	return out
