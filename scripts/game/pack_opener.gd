class_name PackOpener
extends RefCounted

## Pure pack-rolling logic (no Node dependencies), mirroring the roll
## `relay.js`'s `purchase_pack` handler performs server-side (see
## specs/001-currency-pack-shop/research.md decision 3). Kept here, in the
## same style as HeadlessTurn/AIHeuristics, so it's exercisable by the
## `--shop-test` headless CLI hook without a network connection.

## Rolls one pack. `pack_def` matches a data/shop_packs.json entry
## (rarity_weights, card_count, guaranteed_rare_or_better, dust_value).
## `card_pool` is every non-token CardData available (e.g.
## CardDatabase.get_all_cards()). `owned_cards` is a card_id -> quantity
## snapshot; it is read, not mutated (a local working copy is used so two
## pulls of the same card within one pack are both resolved correctly).
##
## Returns { "cards": [{card_id, was_new, rarity}], "dust_awarded": int } —
## the same shape as contracts/shop-protocol.md's purchase_pack_result.result.
static func roll_pack(pack_def: Dictionary, card_pool: Array, owned_cards: Dictionary, rng: RandomNumberGenerator = null) -> Dictionary:
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()

	var pool_by_rarity := _bucket_by_rarity(card_pool)
	var weights: Dictionary = pack_def.get("rarity_weights", {})
	var card_count: int = int(pack_def.get("card_count", 5))

	var picks: Array[CardData] = []
	for _i in card_count:
		var card := _roll_one(pool_by_rarity, weights, rng)
		if card != null:
			picks.append(card)

	if bool(pack_def.get("guaranteed_rare_or_better", false)) and not picks.is_empty() and not _has_rare_or_better(picks):
		var better := _roll_one(pool_by_rarity, weights, rng, ["RARE", "EPIC", "LEGENDARY"])
		if better != null:
			picks[0] = better

	var working_owned: Dictionary = owned_cards.duplicate()
	var dust_value: Dictionary = pack_def.get("dust_value", {})
	var cards_out: Array[Dictionary] = []
	var dust_awarded := 0
	for card in picks:
		var rarity_name: String = CardData.CardRarity.keys()[card.rarity]
		var max_copies := DeckManager.max_copies_for(card)
		var owned := int(working_owned.get(card.id, 0))
		var was_new := owned < max_copies
		if was_new:
			working_owned[card.id] = owned + 1
		else:
			dust_awarded += int(dust_value.get(rarity_name, 0))
		cards_out.append({"card_id": card.id, "was_new": was_new, "rarity": rarity_name})

	return {"cards": cards_out, "dust_awarded": dust_awarded}

## Excludes tokens (is_token) - they're summoned minions, not collectible
## pack contents.
static func _bucket_by_rarity(card_pool: Array) -> Dictionary:
	var buckets := {}
	for card in card_pool:
		if card.is_token:
			continue
		var rarity_name: String = CardData.CardRarity.keys()[card.rarity]
		if not buckets.has(rarity_name):
			buckets[rarity_name] = []
		buckets[rarity_name].append(card)
	return buckets

static func _roll_one(pool_by_rarity: Dictionary, weights: Dictionary, rng: RandomNumberGenerator, allowed_rarities: Array = []) -> CardData:
	var candidates: Array[String] = []
	var candidate_weights: Array[float] = []
	for rarity_name in weights.keys():
		if not allowed_rarities.is_empty() and not allowed_rarities.has(rarity_name):
			continue
		var bucket: Array = pool_by_rarity.get(rarity_name, [])
		if bucket.is_empty():
			continue
		candidates.append(rarity_name)
		candidate_weights.append(float(weights[rarity_name]))
	if candidates.is_empty():
		return null
	var chosen_rarity := _weighted_pick(candidates, candidate_weights, rng)
	var bucket: Array = pool_by_rarity[chosen_rarity]
	return bucket[rng.randi_range(0, bucket.size() - 1)]

static func _weighted_pick(items: Array[String], weights: Array[float], rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for w in weights:
		total += w
	var roll := rng.randf() * total
	var cumulative := 0.0
	for i in items.size():
		cumulative += weights[i]
		if roll <= cumulative:
			return items[i]
	return items[items.size() - 1]

static func _has_rare_or_better(picks: Array[CardData]) -> bool:
	for card in picks:
		if card.rarity != CardData.CardRarity.COMMON:
			return true
	return false
