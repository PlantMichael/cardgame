class_name RankedProgress
extends RefCounted

## Pure display/derivation math for the ranked ladder. The ladder state
## itself (bracket_index/in_legend/legend_rating/rank_lp/win_streak/wins/
## losses) lives on the player's account, authoritative on the server (see
## Auth.rank_* and Auth.report_ranked_result(), and server/relay.js's
## nextRankState()) — this class holds no state of its own and isn't an
## autoload.
##
## The ladder has two regimes:
##  - Bracketed tiers (Orbital -> Cosmic): 7 named tiers x 3 sub-ranks each
##    (III lowest -> I highest within a tier), 21 discrete brackets total.
##    Progress within a bracket is an LP bar (0-100, see LP_PER_BRACKET): a
##    win adds LP_WIN_BASE, or LP_WIN_STREAK once 3+ wins in a row (see
##    LP_WIN_STREAK_THRESHOLD); hitting 100 promotes to the next bracket,
##    carrying the overflow. A loss subtracts LP_LOSS, floored at 0 — losses
##    never demote a bracket here.
##  - Legend-style tiers (Superluminal, Celestial, Universal): reached once
##    Cosmic I is beaten. From here progress is a single continuous rating
##    (like Hearthstone's Legend rank) that goes up on a win and down on a
##    loss. A loss that would push rating below 0 while still in the lowest
##    band (Superluminal) demotes back out to Cosmic I, landing LP carrying
##    the negative overflow the same way bracket promotion does.

const TIER_NAMES := ["Orbital", "Lunar", "Planetary", "Solar", "Nebular", "Galactic", "Cosmic"]
const SUB_RANKS := ["III", "II", "I"]  # III lowest, I highest within a tier
const BRACKET_COUNT := 21  # TIER_NAMES.size() * SUB_RANKS.size()

const LEGEND_TIER_NAMES := ["Superluminal", "Celestial", "Universal"]
const LEGEND_TIER_SPAN := 1000  # rating points per legend tier name; Universal has no cap

## LP economy for the bracketed ladder — keep in sync with relay.js's
## RANK_LP_* constants, which are authoritative.
const LP_PER_BRACKET := 100
const LP_WIN_BASE := 34
const LP_WIN_STREAK := 45  # 3rd win-in-a-row and every win after, until a loss
const LP_WIN_STREAK_THRESHOLD := 3
const LP_LOSS := 20

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

## e.g. "Orbital III", "Cosmic I", or "Superluminal (1240)". Doesn't include
## LP — see get_lp_string for the "62 / 100 LP" progress readout.
static func get_display_string(bracket_index: int, in_legend: bool, legend_rating: int) -> String:
	if in_legend:
		return "%s (%d)" % [_legend_tier_name(legend_rating), legend_rating]
	var tier := bracket_index / SUB_RANKS.size()
	var sub := bracket_index % SUB_RANKS.size()
	return "%s %s" % [TIER_NAMES[tier], SUB_RANKS[sub]]

## e.g. "62 / 100 LP". Empty once in Legend, which has no LP bar (see
## get_display_string's legend rating readout instead).
static func get_lp_string(in_legend: bool, lp: int) -> String:
	if in_legend:
		return ""
	return "%d / %d LP" % [lp, LP_PER_BRACKET]

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
	"gwentbetter", "mrawsome1100", "KingKoontz", "Highlander", "hatsoffgaming",
]

static func random_bot_name() -> String:
	return BOT_NAMES[randi() % BOT_NAMES.size()]
