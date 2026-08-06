class_name RankedProgress
extends RefCounted

## Pure display/derivation math for the ranked ladder. The ladder state
## itself (bracket_index/in_legend/legend_rating/rank_floor/wins/losses)
## lives on the player's account, authoritative on the server (see
## Auth.rank_* and Auth.report_ranked_result(), and server/relay.js's
## nextRankState()) — this class holds no state of its own and isn't an
## autoload.
##
## The ladder has two regimes:
##  - Bracketed tiers (Orbital -> Cosmic): 7 named tiers x 3 sub-ranks each
##    (III lowest -> I highest within a tier), 21 discrete brackets total.
##    A win advances one bracket, a loss drops one bracket — except a loss
##    can never drop the player below their rank_floor, computed server-side
##    in relay.js's nextRankState()/tierFloor() (see get_floor_display_string
##    below for the client-side display of that value): once you've reached
##    the "III" sub-rank of a tier, that tier is locked in, Hearthstone-style.
##  - Legend-style tiers (Superluminal, Celestial, Universal): reached once
##    Cosmic I is beaten. From here progress is a single continuous rating
##    (like Hearthstone's Legend rank) that goes up on a win and down on a
##    loss, but never demotes back into the bracketed ladder — matches
##    Hearthstone Legend never dropping back to ranked. The three tier names
##    are just readable bands over that rating, with Universal (highest)
##    having no ceiling.

const TIER_NAMES := ["Orbital", "Lunar", "Planetary", "Solar", "Nebular", "Galactic", "Cosmic"]
const SUB_RANKS := ["III", "II", "I"]  # III lowest, I highest within a tier
const BRACKET_COUNT := 21  # TIER_NAMES.size() * SUB_RANKS.size()

const LEGEND_TIER_NAMES := ["Superluminal", "Celestial", "Universal"]
const LEGEND_TIER_SPAN := 1000  # rating points per legend tier name; Universal has no cap

const MIN_AI_LEVEL := 1
const MAX_AI_LEVEL := 10

## Difficulty passed to AIController for the next match, scaled across the
## whole ladder: level 1 at Orbital III up to level 10 at Cosmic I, then
## pinned at 10 for all three legend tiers (toughest bots, same as facing
## the hardest opponents once you've reached Legend in Hearthstone).
static func get_ai_level(bracket_index: int, in_legend: bool) -> int:
	if in_legend:
		return MAX_AI_LEVEL
	var span := BRACKET_COUNT - 1
	return clampi(MIN_AI_LEVEL + (bracket_index * (MAX_AI_LEVEL - MIN_AI_LEVEL)) / span, MIN_AI_LEVEL, MAX_AI_LEVEL)

## e.g. "Orbital III", "Cosmic I", or "Superluminal (1240)".
static func get_display_string(bracket_index: int, in_legend: bool, legend_rating: int) -> String:
	if in_legend:
		return "%s (%d)" % [_legend_tier_name(legend_rating), legend_rating]
	var tier := bracket_index / SUB_RANKS.size()
	var sub := bracket_index % SUB_RANKS.size()
	return "%s %s" % [TIER_NAMES[tier], SUB_RANKS[sub]]

## Human-readable name for the tier a rank_floor value protects, e.g.
## "Lunar III". Returns "" when floor is 0 (Orbital III grants no real
## protection, since that's the bottom of the whole ladder).
static func get_floor_display_string(floor_index: int) -> String:
	if floor_index <= 0:
		return ""
	return get_display_string(floor_index, false, 0)

static func _legend_tier_name(rating: int) -> String:
	var idx := rating / LEGEND_TIER_SPAN
	idx = mini(idx, LEGEND_TIER_NAMES.size() - 1)
	return LEGEND_TIER_NAMES[idx]

## Fake opponent names for the AI-fallback path when ranked matchmaking finds
## no human within the ~10s search window (see main.gd's ranked flow) — the
## bot still needs *something* to show in the opponent nameplate. Themed to
## match the space-ladder tier names above rather than looking like a real
## account.
const BOT_NAMES := [
	"THESCOURGE", "Voidstar", "commetwing55", "starf4ll", "Ionizer",
	"fairs67", "TakeoutLemur95", "Solstice_60", "Driftwake", "jinx325",
	"magicninja23", "CrytoKing", "gooby", "Meteor_Sable_Star", "vibrantjuggler7",
	"dubiousbug", "KingLebronIV", "BIRDMANN", "feetlover21", "slimelauncherlover67",
	"PyahPelican", "CADENO", "BotLacek", "BarilBot", "hatsoffgaming",
]

static func random_bot_name() -> String:
	return BOT_NAMES[randi() % BOT_NAMES.size()]
