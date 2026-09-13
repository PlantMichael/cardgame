extends Node

## Currency/dust/collection state (currency & pack unboxing feature). Mirrors
## server-authoritative values from `relay.js` — every field here only ever
## changes in response to a Net *_result signal, never speculatively, so the
## client can't invent a balance change the server didn't confirm.

signal balance_changed
signal pack_purchase_failed(message: String)
signal pack_opened(pack_id: String, cards: Array, dust_awarded: int)
signal craft_failed(message: String, dust_needed: int)
signal card_crafted(card_id: String)
signal earn_reward_result(success: bool, message: String, amount_awarded: int, reason: String)

var currency: int = 0
var dust: int = 0
## card_id -> quantity owned by the logged-in player.
var owned_cards: Dictionary = {}

func _ready() -> void:
	Net.economy_state_result.connect(_on_economy_state_result)
	Net.purchase_pack_result.connect(_on_purchase_pack_result)
	Net.craft_card_result.connect(_on_craft_card_result)
	Net.claim_earn_reward_result.connect(_on_claim_earn_reward_result)
	# Fetch state whenever Auth applies a fresh profile (covers both login and
	# session-resume, since net.gd maps resume_session's reply to the same
	# "login_result" type auth.gd already listens for).
	Auth.login_result.connect(_on_auth_login_result)

func request_state() -> void:
	Net.get_economy_state(Auth.token)

func purchase_pack(pack_id: String) -> void:
	Net.purchase_pack(Auth.token, pack_id)

func craft_card(card_id: String) -> void:
	Net.craft_card(Auth.token, card_id)

func claim_earn_reward(reason: String) -> void:
	Net.claim_earn_reward(Auth.token, reason)

func owned_quantity(card_id: String) -> int:
	return int(owned_cards.get(card_id, 0))

func _on_auth_login_result(success: bool, _message: String) -> void:
	if success:
		request_state()

func _on_economy_state_result(success: bool, new_currency: int, new_dust: int, new_owned_cards: Dictionary) -> void:
	if not success:
		return
	currency = new_currency
	dust = new_dust
	owned_cards = new_owned_cards
	balance_changed.emit()

func _on_purchase_pack_result(success: bool, message: String, new_currency: int, new_dust: int, pack_id: String, cards: Array, dust_awarded: int) -> void:
	if not success:
		pack_purchase_failed.emit(message)
		return
	currency = new_currency
	dust = new_dust
	for entry in cards:
		if not entry is Dictionary:
			continue
		if bool(entry.get("was_new", false)):
			var card_id := str(entry.get("card_id", ""))
			owned_cards[card_id] = owned_quantity(card_id) + 1
	balance_changed.emit()
	pack_opened.emit(pack_id, cards, dust_awarded)

func _on_craft_card_result(success: bool, message: String, new_dust: int, card_id: String, dust_needed: int) -> void:
	if not success:
		craft_failed.emit(message, dust_needed)
		return
	dust = new_dust
	owned_cards[card_id] = owned_quantity(card_id) + 1
	balance_changed.emit()
	card_crafted.emit(card_id)

func _on_claim_earn_reward_result(success: bool, message: String, new_currency: int, new_dust: int, amount_awarded: int, reason: String) -> void:
	if success:
		currency = new_currency
		dust = new_dust
		balance_changed.emit()
	earn_reward_result.emit(success, message, amount_awarded, reason)
