extends Node

const BoardScene = preload("res://scenes/game/Board.tscn")
const DeckBuilderScene = preload("res://scenes/ui/DeckBuilderScreen.tscn")
const WallpaperTexture = preload("res://assets/wallapepr.png")
const CursorDefault = preload("res://assets/01.png")
const MenuFont = preload("res://assets/fonts/Orbitron.ttf")
# Explicit preloads (rather than relying on global class_name resolution)
# for scripts new in this session - Godot's global script class cache is
# only rebuilt when the editor scans the project, which hasn't happened yet
# for these, so the bare class names aren't resolvable from a --headless run.
const PackOpenerScript = preload("res://scripts/game/pack_opener.gd")
const ShopScreenScript = preload("res://scripts/ui/shop_screen.gd")
const PackOpenScreenScript = preload("res://scripts/ui/pack_open_screen.gd")

var _canvas: CanvasLayer
var _player_deck_ids: Array[String] = []
var _opponent_deck_ids: Array[String] = []

# Multiplayer state
var _mp_name: String = ""
var _mp_lobby_id: String = ""
var _mp_is_host: bool = false
var _mp_player_deck_ids: Array[String] = []
var _mp_guest_deck_ids: Array[String] = []
var _mp_manager: MpGameManager = null

# Ranked matchmaking state
const RANKED_SEARCH_TIMEOUT_SEC := 10.0
const RANKED_MATCH_COUNTDOWN_SEC := 5
# Bumped on every begin/cancel/resolve so a stale timer or match-found signal
# left over from a cancelled or already-resolved search (e.g. Cancel then
# immediately Start again) can tell it's no longer current and no-op instead
# of hijacking whatever search is active now.
var _ranked_search_id: int = 0
var _ranked_match_found_callable: Callable = Callable()
var _ranked_searching: bool = false
# Separate top-layer CanvasLayer (sibling of _canvas, not a child of it) so
# the "Searching for opponent..."/"Searching for campaign opponent..."
# indicator survives _clear_screen() calls and stays visible while the
# player freely navigates menus/card list/deck builder during a search.
# Shared by Ranked and Campaign matchmaking (see _show_queue_overlay) - only
# one of the two can ever be searching at a time in practice.
var _queue_layer: CanvasLayer = null

# Campaign mode state
var _campaign_state: CampaignState = null
var _campaign_ai_level: int = 5
var _campaign_opponent_deck_ids: Array[String] = []
var _campaign_opponent_deck_faction: CardData.CardColor = CardData.CardColor.GREEN
var _campaign_player_faction: CardData.CardColor = CardData.CardColor.GREEN
var _campaign_opponent_name: String = ""
var _campaign_searching: bool = false
var _campaign_search_id: int = 0
var _campaign_match_found_callable: Callable = Callable()
const CAMPAIGN_SEARCH_TIMEOUT_SEC := 10.0
## True for a PvP campaign run (matched with a human via Ranked-style
## matchmaking - see _start_campaign_pvp) rather than the local-AI fallback;
## drives whether each node is started via MpGameManager or
## GameManagerAutoload, and whether modifier picks need to be relayed.
var _campaign_pvp: bool = false
var _campaign_pvp_role: String = ""
const CAMPAIGN_OPPONENT_NAME := "Rival Warlord"

func _ready() -> void:
	# Set explicitly here (the actual game entry point) rather than relying
	# solely on the project.godot mouse_cursor/custom_image setting - that
	# setting doesn't reliably take effect on every export target (notably
	# the web/Vercel build this project ships as), so without this the OS
	# default arrow showed everywhere - including every menu - until
	# board.gd's own targeting-cursor logic happened to fire its first
	# Input.set_custom_mouse_cursor() call deep into an actual match.
	Input.set_custom_mouse_cursor(CursorDefault, Input.CURSOR_ARROW, Vector2.ZERO)
	if "--mcts-timing" in OS.get_cmdline_user_args():
		_run_mcts_timing_cli()
		return
	if "--mcts-benchmark" in OS.get_cmdline_user_args():
		_run_mcts_benchmark_cli()
		return
	if "--fatigue-test" in OS.get_cmdline_user_args():
		_run_fatigue_test_cli()
		return
	if "--haven-test" in OS.get_cmdline_user_args():
		_run_haven_test_cli()
		return
	if "--live-ai-test" in OS.get_cmdline_user_args():
		_run_live_ai_test_cli()
		return
	if "--campaign-test" in OS.get_cmdline_user_args():
		_run_campaign_test_cli()
		return
	if "--tank-test" in OS.get_cmdline_user_args():
		_run_tank_test_cli()
		return
	if "--shop-test" in OS.get_cmdline_user_args():
		_run_shop_test_cli()
		return

	_create_canvas()

	Net.opponent_left.connect(_on_opponent_left)
	if OS.has_feature("editor"):
		# Skip the login gate when run from the Godot editor (playtesting) —
		# "editor" is only ever true for an editor-launched debug run, never
		# for an exported build (web or otherwise), so this can't ship live.
		_show_main_menu()
	else:
		_require_login_then(_show_main_menu, false)

## Rebuilds `_canvas` (freed whenever a game starts, see _start_game/
## _start_ranked_pvp_match) so menu-style screens have somewhere to attach
## again — used at startup and whenever a ranked game-over screen requeues
## straight back into matchmaking instead of going through the full menu.
func _create_canvas() -> void:
	_canvas = CanvasLayer.new()
	add_child(_canvas)

	var bg := TextureRect.new()
	bg.texture = WallpaperTexture
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(bg)

func _clear_screen() -> void:
	# remove_child() (not just queue_free(), which only defers actual removal
	# to end-of-frame) so a screen switch that happens more than once per
	# frame — e.g. a fast double-click through menus — can't leave the
	# previous screen's nodes (and their signal connections) still attached
	# and piling up underneath the new one.
	for i in range(_canvas.get_child_count() - 1, 0, -1):
		var child := _canvas.get_child(i)
		_canvas.remove_child(child)
		child.queue_free()

## Dev-only headless verification hook: run via
##   godot --headless --path <project> -- --mcts-benchmark
## Bypasses the UI entirely (skipped autoloads aren't available in bare
## --script mode, so this runs through the real project instead) and prints
## win rates so MCTSEngine level tuning can be checked without manual play.
## Dev-only timing probe: godot --headless --path <project> -- --mcts-timing
## Measures wall-clock ms per choose_action() call at each level on a
## realistic mid-game board, to catch a level being too slow before it's
## ever played against.
func _run_mcts_timing_cli() -> void:
	var deck_a := DeckManager.build_random_faction_deck(CardData.CardColor.CRIMSON)
	var deck_b := DeckManager.build_random_faction_deck(CardData.CardColor.TEAL)
	var gs := GameState.new("sim_a", "sim_b", deck_a, deck_b)
	gs.start_game("sim_a")
	HeadlessTurn._resolve_pending(gs)
	# Play a few greedy turns each side first so the board isn't the empty
	# opening state (a mid-game board has more legal actions to search).
	for _t in 6:
		HeadlessTurn.play_full_turn_greedy(gs, gs.active_player_id)
		if gs.current_phase == GameState.Phase.GAME_OVER:
			break

	for level in [1, 3, 5, 7, 10]:
		var engine := MCTSEngine.new("sim_a", level)
		var start_ms := Time.get_ticks_msec()
		var action := await engine.choose_action(gs)
		var elapsed := Time.get_ticks_msec() - start_ms
		print("Level %d: %d ms, chose %s" % [level, elapsed, action["type"]])
	get_tree().quit()

## Dev-only one-shot check of the fatigue math (both players start with an
## empty deck, so every draw fatigues immediately): godot --headless --path
## <project> -- --fatigue-test
func _run_fatigue_test_cli() -> void:
	print("Testing fatigue with empty decks...")
	var gs := GameState.new("a", "b", [], [])
	gs.start_game("a")
	print("After opening hand: a.hp=%d a.fatigue=%d" % [gs.player.hero_health, gs.player.fatigue_damage])
	for i in 40:
		if gs.current_phase == GameState.Phase.GAME_OVER:
			print("GAME OVER after %d end_turns. winner=%s a.hp=%d b.hp=%d" % [
				i, gs.winner_id, gs.player.hero_health, gs.opponent.hero_health])
			break
		gs.end_turn()
		print("turn=%d active=%s a.hp=%d(fatigue=%d) b.hp=%d(fatigue=%d) phase=%d" % [
			gs.turn_number, gs.active_player_id, gs.player.hero_health, gs.player.fatigue_damage,
			gs.opponent.hero_health, gs.opponent.fatigue_damage, gs.current_phase])
	get_tree().quit()

## Dev-only check that health-threshold transform (Haven Guard -> Haven
## Warden at 4+ max health) fires even when a single effect jumps straight
## past the threshold instead of landing on it exactly (e.g. devour, which
## used to skip the check entirely): godot --headless --path <project> --
## --haven-test
func _run_haven_test_cli() -> void:
	print("Testing Haven Guard transform via a jump that skips over exactly 4...")
	var card := CardDatabase.get_card("cr_003")
	var gs := GameState.new("a", "b", [], [])
	var m := Minion.new(card, "a")
	gs.player.board.append(m)
	print("Before: name=%s max_health=%d" % [m.data.card_name, m.max_health])
	var fodder := Minion.new(card, "a")
	fodder.current_health = 5  # devour gain = 5, so max_health jumps 3 -> 8, skipping 4 entirely
	gs.player.board.append(fodder)
	gs.apply_devour_friendly(m, fodder, gs.player)
	var transformed := m.data.id != card.id
	print("After devour (3 -> 8, skipping 4): name=%s max_health=%d transformed=%s" % [
		m.data.card_name, m.max_health, transformed])
	print("RESULT: %s" % ("PASS" if transformed else "FAIL"))
	get_tree().quit()

## Dev-only repro for the reported in-match freeze: drives one real game
## through the actual Board/GameManager/AIController glue (tweens, refresh(),
## log_action()) instead of the headless SimRunner/HeadlessTurn path, so a
## hang specific to that glue (not the search engine itself) shows up here.
## godot --headless --path <project> -- --live-ai-test
func _run_live_ai_test_cli() -> void:
	print("Starting live (real Board/GameManager) local AI game to check for turn hangs...")
	var board := BoardScene.instantiate()
	add_child(board)
	var pd := DeckManager.build_random_faction_deck(CardData.CardColor.GREEN)
	var od := DeckManager.build_random_faction_deck(CardData.CardColor.CRIMSON)
	GameManagerAutoload.start_local_game(board, pd, od, 10, false)
	await get_tree().create_timer(4.5).timeout  # let the coinflip animation clear
	# Fingerprints actual board/hand/health state (via MCTSEngine's own helper)
	# rather than just turn_number/active_player_id, which legitimately don't
	# change while the AI is mid-turn working through several real actions —
	# that used to look identical to a true hang in this harness.
	var last_fp := ""
	var stall_ticks := 0
	for i in 180:
		await get_tree().create_timer(1.0).timeout
		var gs := GameManagerAutoload.game_state
		if gs.current_phase == GameState.Phase.GAME_OVER:
			print("RESULT: PASS - game reached GAME_OVER at t=%ds without hanging" % (i + 1))
			get_tree().quit()
			return
		if gs.is_local_player_turn():
			# Simulate the human immediately ending their turn every round so
			# the AI's turn (the suspected hang site) triggers repeatedly.
			board.end_turn_pressed.emit()
		var fp := MCTSEngine._fingerprint(gs)
		if fp == last_fp:
			stall_ticks += 1
		else:
			stall_ticks = 0
		last_fp = fp
		print("t=%ds turn=%d active=%s phase=%d stall_ticks=%d" % [i + 1, gs.turn_number, gs.active_player_id, gs.current_phase, stall_ticks])
		if stall_ticks >= 20 and not gs.is_local_player_turn():
			print("RESULT: FAIL - stuck on %s's turn (turn %d) for %d+ seconds with no state change at all" % [gs.active_player_id, gs.turn_number, stall_ticks])
			get_tree().quit()
			return
	print("RESULT: INCONCLUSIVE - loop ended without a clear stall or game over")
	get_tree().quit()

## Dev-only headless sanity check for Campaign mode (campaign_state.gd /
## GameState.node_modifier_ability): verifies node counts, that a node's
## modifier ability actually lands on played creatures for both sides, and
## that reporting results drives the campaign to completion. godot --headless
## --path <project> -- --campaign-test
func _run_campaign_test_cli() -> void:
	var ok := true

	var small := CampaignState.new(CampaignState.Size.SMALL)
	if small.total_nodes != 3 or small.wins_needed() != 2:
		print("FAIL: Small campaign should be best of 3 (wins_needed=2), got total_nodes=%d wins_needed=%d" % [small.total_nodes, small.wins_needed()])
		ok = false

	var large := CampaignState.new(CampaignState.Size.LARGE)
	if large.total_nodes != 7 or large.wins_needed() != 4:
		print("FAIL: Large campaign should be best of 7 (wins_needed=4), got total_nodes=%d wins_needed=%d" % [large.total_nodes, large.wins_needed()])
		ok = false

	# Exactly 4 of Large's 7 nodes should be flagged as modified - some may
	# already be resolved (index 0, see CampaignState._init), others are
	# lazily resolved later via current_node_needs_choice()/
	# resolve_current_node_modifier(), so check both rather than assuming
	# any particular index is pre-resolved (that's randomized per campaign).
	var flagged_count := 0
	var modifier: Dictionary = {}
	for i in large.total_nodes:
		large.current_node_index = i
		if not large.current_node().is_empty():
			flagged_count += 1
			modifier = large.current_node()
		elif large.current_node_needs_choice():
			flagged_count += 1
			if modifier.is_empty():
				var choices := large.get_modifier_choices()
				if not choices.is_empty():
					large.resolve_current_node_modifier(choices[0])
					modifier = choices[0]
	large.current_node_index = 0
	if flagged_count != 4:
		print("FAIL: expected 4 modified nodes on a Large campaign, found %d" % flagged_count)
		ok = false
	if modifier.is_empty():
		print("FAIL: expected at least one modified node on a Large campaign")
		ok = false
	else:
		var gs := GameState.new("a", "b", [], [])
		gs.node_modifier_ability = str(modifier["ability"])
		var card := CardDatabase.get_card("cr_003")
		gs.player.max_mana = 10
		gs.player.current_mana = 0
		gs.opponent.max_mana = 10
		gs.opponent.current_mana = 0
		gs.player.hand.append(card)
		gs.opponent.hand.append(card)
		var m1 := gs.play_creature("a", card)
		var m2 := gs.play_creature("b", card)
		if m1 == null or not m1.has_ability(modifier["ability"]):
			print("FAIL: node modifier '%s' not granted to player's creature" % modifier["ability"])
			ok = false
		if m2 == null or not m2.has_ability(modifier["ability"]):
			print("FAIL: node modifier '%s' not granted to opponent's creature" % modifier["ability"])
			ok = false

	# Drive a Small campaign to completion and check the final tally.
	small.current_node_index = 0
	small.player_wins = 0
	small.opponent_wins = 0
	small.report_node_result(true)
	if small.is_over():
		print("FAIL: campaign shouldn't be over after 1-0 in a best of 3")
		ok = false
	small.report_node_result(true)
	if not small.is_over() or not small.player_won_campaign() or small.score_string() != "2 - 0":
		print("FAIL: expected player to win 2-0, got is_over=%s won=%s score=%s" % [small.is_over(), small.player_won_campaign(), small.score_string()])
		ok = false

	print("RESULT: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit()

## Dev-only headless regression check for the "tank tribe silently pings 1
## damage" bug (T12 Serpent / Stealth Jet dealing unintended damage - fixed
## by removing abilities.gd's fire_on_play TANK case and fire_on_death's
## reinforce TANK check, which fired off of card_database.gd's tribe->
## abilities auto-append rather than an actual printed ability). Verifies
## tribe-only tank cards no longer queue a phantom tank shot on play or on
## reinforce, while tank cards with a real printed on-play damage ability
## are untouched. godot --headless --path <project> -- --tank-test
func _run_tank_test_cli() -> void:
	var ok := true

	var gs := GameState.new("a", "b", [], [])
	gs.player.max_mana = 10
	gs.player.current_mana = 0

	# Stealth Jet: tribe "tank", no printed on-play damage - must not queue
	# a tank shot just for being Tank-tribe.
	var stealth_jet := CardDatabase.get_card("g_018")
	gs.player.hand.append(stealth_jet)
	gs.play_creature("a", stealth_jet)
	if not gs.pending_tank_shots.is_empty():
		print("FAIL: Stealth Jet queued a phantom on-play tank shot")
		ok = false

	# T12 Serpent: tribe "tank" + reinforce, no printed on-play damage either
	# - same check, then verify reinforcing it doesn't queue one either.
	var serpent := CardDatabase.get_card("g_007")
	gs.player.hand.append(serpent)
	var serpent_minion := gs.play_creature("a", serpent)
	if not gs.pending_tank_shots.is_empty():
		print("FAIL: T12 Serpent queued a phantom on-play tank shot")
		ok = false
	serpent_minion.current_health = 0
	gs._remove_dead_minions()
	if not gs.pending_tank_shots.is_empty():
		print("FAIL: T12 Serpent's reinforce queued a phantom tank shot")
		ok = false

	# T8 Tigershark: tribe "tank" but *does* print its own on-play damage -
	# that real ability should still fire (via pending_on_play prompts, not
	# pending_tank_shots either way, but confirm it still has the ability).
	var tigershark := CardDatabase.get_card("g_005")
	if not tigershark.abilities.has("on_play_damage_2"):
		print("FAIL: T8 Tigershark lost its printed on_play_damage_2 ability")
		ok = false

	print("RESULT: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit()

## Dev-only headless sanity check for PackOpener (currency/shop/pack-
## unboxing feature): verifies rarity-weighted rolling, the guaranteed-
## rare-or-better rule (FR-008), duplicate-pulls-convert-to-dust (FR-012,
## both pre-owned and within a single pack), Legendary's 1-copy limit, and
## token exclusion. Uses tiny synthetic card pools with skewed weights so
## every assertion is deterministic - no reliance on true RNG luck.
##
## This only exercises the pure client-side roll (pack_opener.gd), which is
## what the headless dev-hook pattern can reach without a Node process/
## Postgres instance. The server-authoritative purchase/craft/earn
## endpoints (relay.js) and the Shop/PackOpenScreen UI are covered by
## specs/001-currency-pack-shop/quickstart.md's manual playtest instead.
## godot --headless --path <project> -- --shop-test
func _run_shop_test_cli() -> void:
	var ok := true

	var common_card := CardData.new()
	common_card.id = "test_common"
	common_card.card_name = "Test Common"
	common_card.rarity = CardData.CardRarity.COMMON

	var rare_card := CardData.new()
	rare_card.id = "test_rare"
	rare_card.card_name = "Test Rare"
	rare_card.rarity = CardData.CardRarity.RARE

	var legendary_card := CardData.new()
	legendary_card.id = "test_legendary"
	legendary_card.card_name = "Test Legendary"
	legendary_card.rarity = CardData.CardRarity.LEGENDARY

	var token_card := CardData.new()
	token_card.id = "test_token"
	token_card.rarity = CardData.CardRarity.COMMON
	token_card.is_token = true

	# 1. A single-card COMMON pool, pack_count=3: the first 2 pulls should be
	# new (DeckManager's non-Legendary max is 2), the 3rd should convert to
	# dust - proves within-pack duplicate detection, not just pre-owned.
	var dup_pack := {"card_count": 3, "rarity_weights": {"COMMON": 1.0}, "guaranteed_rare_or_better": false, "dust_value": {"COMMON": 5}}
	var dup_result: Dictionary = PackOpenerScript.roll_pack(dup_pack, [common_card], {})
	var new_count := 0
	for c in dup_result["cards"]:
		if c["was_new"]:
			new_count += 1
	if dup_result["cards"].size() != 3:
		print("FAIL: expected 3 cards in a 3-card pack, got %d" % dup_result["cards"].size())
		ok = false
	if new_count != 2:
		print("FAIL: expected exactly 2 new copies before hitting the copy limit, got %d" % new_count)
		ok = false
	if int(dup_result["dust_awarded"]) != 5:
		print("FAIL: expected 5 dust from the one over-limit duplicate, got %d" % int(dup_result["dust_awarded"]))
		ok = false

	# 2. RARE weighted at 0 so the natural roll always lands COMMON, but
	# guaranteed_rare_or_better must still force a Rare-or-better result.
	var guarantee_pack := {"card_count": 3, "rarity_weights": {"COMMON": 1.0, "RARE": 0.0}, "guaranteed_rare_or_better": true, "dust_value": {"COMMON": 5, "RARE": 20}}
	var guarantee_result: Dictionary = PackOpenerScript.roll_pack(guarantee_pack, [common_card, rare_card], {})
	var has_rare_or_better := false
	for c in guarantee_result["cards"]:
		if c["rarity"] != "COMMON":
			has_rare_or_better = true
	if not has_rare_or_better:
		print("FAIL: guaranteed_rare_or_better pack contained no Rare-or-better card")
		ok = false

	# 3. A card already owned at its copy limit before the pack is opened
	# should convert straight to dust.
	var preowned_pack := {"card_count": 1, "rarity_weights": {"COMMON": 1.0}, "guaranteed_rare_or_better": false, "dust_value": {"COMMON": 5}}
	var preowned_result: Dictionary = PackOpenerScript.roll_pack(preowned_pack, [common_card], {"test_common": 2})
	if bool(preowned_result["cards"][0]["was_new"]):
		print("FAIL: expected an already-owned-at-max card to convert to dust, not a new copy")
		ok = false
	if int(preowned_result["dust_awarded"]) != 5:
		print("FAIL: expected 5 dust for the pre-owned pull, got %d" % int(preowned_result["dust_awarded"]))
		ok = false

	# 4. Legendary's copy limit is 1 (DeckManager.max_copies_for), not 2.
	var legendary_pack := {"card_count": 2, "rarity_weights": {"LEGENDARY": 1.0}, "guaranteed_rare_or_better": false, "dust_value": {"LEGENDARY": 400}}
	var legendary_result: Dictionary = PackOpenerScript.roll_pack(legendary_pack, [legendary_card], {})
	if not bool(legendary_result["cards"][0]["was_new"]) or bool(legendary_result["cards"][1]["was_new"]):
		print("FAIL: expected Legendary's 2nd pull to convert to dust (copy limit 1), got %s" % [legendary_result["cards"]])
		ok = false
	if int(legendary_result["dust_awarded"]) != 400:
		print("FAIL: expected 400 dust from the 2nd Legendary pull, got %d" % int(legendary_result["dust_awarded"]))
		ok = false

	# 5. Tokens are never pack-eligible.
	var token_pack := {"card_count": 1, "rarity_weights": {"COMMON": 1.0}, "guaranteed_rare_or_better": false, "dust_value": {"COMMON": 5}}
	var token_result: Dictionary = PackOpenerScript.roll_pack(token_pack, [token_card], {})
	if not token_result["cards"].is_empty():
		print("FAIL: a token-only pool should yield no pack contents")
		ok = false

	print("RESULT: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit()

func _run_mcts_benchmark_cli() -> void:
	print("Running MCTS benchmark...")
	var r1 := await MCTSBenchmark.run(6, MCTSBenchmark.mcts(3), MCTSBenchmark.mcts(1))
	print("Level 3 MCTS vs Level 1 MCTS (6 games): ", r1)
	var r2 := await MCTSBenchmark.run(6, MCTSBenchmark.mcts(5), MCTSBenchmark.mcts(1))
	print("Level 5 MCTS vs Level 1 MCTS (6 games): ", r2)
	get_tree().quit()

# ── Main menu ──────────────────────────────────────────────────────────

func _show_main_menu() -> void:
	_build_profile_bar()

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 26)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "CARDGAME"
	title.add_theme_font_override("font", MenuFont)
	title.add_theme_font_size_override("font_size", 60)
	title.add_theme_constant_override("outline_size", 4)
	title.add_theme_color_override("font_outline_color", Color.BLACK)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 28)
	vbox.add_child(gap)

	var mp_btn := _menu_text_btn("MULTIPLAYER")
	mp_btn.pressed.connect(_on_multiplayer_pressed)
	vbox.add_child(mp_btn)

	var play_btn := _menu_text_btn("VS AI")
	play_btn.pressed.connect(_on_play_pressed)
	vbox.add_child(play_btn)

	var ranked_btn := _menu_text_btn("RANKED")
	ranked_btn.pressed.connect(_on_ranked_pressed)
	vbox.add_child(ranked_btn)

	var campaign_btn := _menu_text_btn("CAMPAIGN")
	campaign_btn.pressed.connect(_on_campaign_pressed)
	vbox.add_child(campaign_btn)

	var shop_btn := _menu_text_btn("SHOP")
	shop_btn.pressed.connect(_on_shop_pressed)
	vbox.add_child(shop_btn)

	var build_btn := _menu_text_btn("DECK BUILDER")
	build_btn.pressed.connect(_on_deck_builder_pressed)
	vbox.add_child(build_btn)

	var card_list_btn := _menu_text_btn("CARD LIST")
	card_list_btn.pressed.connect(_on_card_list_pressed)
	vbox.add_child(card_list_btn)

## ── Profile bar (main menu, top right) ───────────────────────────────────
## Player pfp (with a rank-tier badge clipped onto its corner), name, and
## gold/dust counters - Hearthstone-style. Profile pictures are user-supplied
## art dropped into PFP_DIR (see assets/pfps/README.txt); the picker below
## auto-scans that folder instead of hardcoding filenames, so adding more
## later needs no code change.
const PFP_DIR := "res://assets/pfps/"
const PFP_SIZE := 52.0
const PFP_BADGE_SIZE := 20.0
## Every account with no explicit choice yet (Auth.selected_pfp == "") shows
## this one - not just whichever file happens to sort first in PFP_DIR.
const DEFAULT_PFP_ID := "pfp_planet.png"

var _profile_bar: Control = null
var _pfp_texture_rect: TextureRect = null
var _circle_mask_material: ShaderMaterial = null
var _default_pfp_texture: ImageTexture = null

func _build_profile_bar() -> void:
	if is_instance_valid(_profile_bar):
		_profile_bar.queue_free()

	_profile_bar = PanelContainer.new()
	_profile_bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_profile_bar.position = Vector2(-380, 14)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.09, 0.85)
	style.set_corner_radius_all(28)
	style.content_margin_left = 6
	style.content_margin_right = 16
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	_profile_bar.add_theme_stylebox_override("panel", style)
	_canvas.add_child(_profile_bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_profile_bar.add_child(row)

	if not Auth.is_logged_in:
		var offline_lbl := Label.new()
		offline_lbl.text = "Offline (Editor)"
		offline_lbl.add_theme_font_size_override("font_size", 14)
		row.add_child(offline_lbl)
		return

	row.add_child(_build_pfp_control())

	var name_lbl := Label.new()
	name_lbl.text = Auth.username
	name_lbl.add_theme_font_override("font", MenuFont)
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", Color(0.92, 0.92, 0.96))
	row.add_child(name_lbl)

	row.add_child(VSeparator.new())
	row.add_child(_currency_cell(_glimmer_icon(), "dust"))
	row.add_child(_currency_cell(_cyllats_icon(), "gold"))

	var logout_btn := Button.new()
	logout_btn.text = "Log Out"
	logout_btn.add_theme_font_size_override("font_size", 13)
	logout_btn.pressed.connect(func():
		Auth.logout()
		_clear_screen()
		_require_login_then(_show_main_menu, false)
	)
	row.add_child(logout_btn)

## pfp circle (click to open the picker) with a rank-tier badge overlapping
## its bottom-left corner, both wrapped so the badge can overhang the pfp's
## own bounds without getting clipped by it.
func _build_pfp_control() -> Control:
	var wrap := Control.new()
	wrap.custom_minimum_size = Vector2(PFP_SIZE + 8, PFP_SIZE + 8)

	var btn := Button.new()
	btn.position = Vector2(4, 4)
	btn.custom_minimum_size = Vector2(PFP_SIZE, PFP_SIZE)
	btn.flat = true
	var empty := StyleBoxEmpty.new()
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		btn.add_theme_stylebox_override(state, empty)
	btn.pressed.connect(_show_pfp_picker)
	wrap.add_child(btn)

	var ring := Panel.new()
	ring.position = Vector2(4, 4)
	ring.custom_minimum_size = Vector2(PFP_SIZE, PFP_SIZE)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ring_style := StyleBoxFlat.new()
	ring_style.bg_color = Color(0, 0, 0, 0)
	ring_style.border_width_left = 3
	ring_style.border_width_top = 3
	ring_style.border_width_right = 3
	ring_style.border_width_bottom = 3
	ring_style.border_color = Color(0.75, 0.62, 0.32)
	ring_style.set_corner_radius_all(int(PFP_SIZE / 2))
	ring.add_theme_stylebox_override("panel", ring_style)
	wrap.add_child(ring)

	_pfp_texture_rect = TextureRect.new()
	_pfp_texture_rect.position = Vector2(7, 7)
	_pfp_texture_rect.custom_minimum_size = Vector2(PFP_SIZE - 6, PFP_SIZE - 6)
	_pfp_texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_pfp_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_pfp_texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pfp_texture_rect.material = _get_circle_mask_material()
	_pfp_texture_rect.texture = _load_current_pfp_texture()
	wrap.add_child(_pfp_texture_rect)

	var badge := _build_rank_badge()
	badge.position = Vector2(-2, PFP_SIZE - PFP_BADGE_SIZE + 6)
	wrap.add_child(badge)

	return wrap

func _build_rank_badge() -> Control:
	var badge := Panel.new()
	badge.custom_minimum_size = Vector2(PFP_BADGE_SIZE, PFP_BADGE_SIZE)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := StyleBoxFlat.new()
	st.bg_color = RankedProgress.get_tier_color(Auth.rank_bracket, Auth.rank_in_legend, Auth.rank_legend_rating)
	st.set_corner_radius_all(int(PFP_BADGE_SIZE / 2))
	st.border_width_left = 2
	st.border_width_top = 2
	st.border_width_right = 2
	st.border_width_bottom = 2
	st.border_color = Color(0.05, 0.05, 0.07)
	badge.add_theme_stylebox_override("panel", st)

	var lbl := Label.new()
	lbl.text = RankedProgress.get_badge_text(Auth.rank_bracket, Auth.rank_in_legend)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	badge.add_child(lbl)
	return badge

## `kind` is "gold" or "dust" - just picks which Economy field this cell
## tracks, both display-wise and when Economy.balance_changed fires.
func _currency_cell(icon: Control, kind: String) -> Control:
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 4)
	cell.add_child(icon)
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", Color(0.92, 0.92, 0.96))
	cell.add_child(lbl)
	var update: Callable
	update = func():
		if not is_instance_valid(lbl):
			Economy.balance_changed.disconnect(update)
			return
		lbl.text = str(Economy.dust if kind == "dust" else Economy.currency)
	Economy.balance_changed.connect(update)
	update.call()
	return cell

const GLIMMER_ICON := preload("res://assets/icons/glimmer.png")
const CYLLATS_ICON := preload("res://assets/icons/cyllats.png")
## Glimmer's art is a plain black silhouette (a colorable mask, not a
## finished-color icon like Cyllats') - tinted here rather than left black.
## `self_modulate` can't do this: it multiplies, and black * any color is
## still black, so the tint shader below replaces the RGB outright and keeps
## only the source alpha as the shape mask.
const GLIMMER_TINT := Color(0.75, 0.88, 1.0)

var _icon_tint_shader: Shader = null

func _glimmer_icon() -> Control:
	var t := TextureRect.new()
	t.texture = GLIMMER_ICON
	t.custom_minimum_size = Vector2(16, 16)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.material = _make_icon_tint_material(GLIMMER_TINT)
	return t

## Cyllats' art is already a finished colored icon - shown as-is.
func _cyllats_icon() -> Control:
	var t := TextureRect.new()
	t.texture = CYLLATS_ICON
	t.custom_minimum_size = Vector2(16, 16)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	return t

func _make_icon_tint_material(color: Color) -> ShaderMaterial:
	if _icon_tint_shader == null:
		_icon_tint_shader = Shader.new()
		_icon_tint_shader.code = "shader_type canvas_item;\nuniform vec4 tint_color : source_color = vec4(1.0);\nvoid fragment() {\n\tCOLOR = vec4(tint_color.rgb, texture(TEXTURE, UV).a * tint_color.a);\n}"
	var mat := ShaderMaterial.new()
	mat.shader = _icon_tint_shader
	mat.set_shader_parameter("tint_color", color)
	return mat

## Discards fragment outside the unit circle so a square TextureRect reads as
## a circular portrait - built at runtime rather than as a .gdshader asset
## since it's tiny, has no parameters, and is only ever used here.
func _get_circle_mask_material() -> ShaderMaterial:
	if _circle_mask_material == null:
		var shader := Shader.new()
		shader.code = "shader_type canvas_item;\nvoid fragment() {\n\tif (length(UV - vec2(0.5)) > 0.5) {\n\t\tdiscard;\n\t}\n\tCOLOR = texture(TEXTURE, UV);\n}"
		_circle_mask_material = ShaderMaterial.new()
		_circle_mask_material.shader = shader
	return _circle_mask_material

## Flat gray square (the circle mask crops it to a disc) shown until the
## player picks a real picture, or if PFP_DIR is still empty.
func _get_default_pfp_texture() -> ImageTexture:
	if _default_pfp_texture == null:
		var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
		img.fill(Color(0.32, 0.34, 0.40))
		_default_pfp_texture = ImageTexture.create_from_image(img)
	return _default_pfp_texture

func _pfp_path(pfp_id: String) -> String:
	return PFP_DIR + pfp_id

## Filenames (not full paths) of every image dropped into PFP_DIR, sorted for
## a stable picker order. Works the same way in an exported build as in the
## editor - res:// listing still sees each imported image at its logical
## path, same as how card art (CardData.art) is loaded by path elsewhere.
func _list_pfp_files() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(PFP_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var lower := file_name.to_lower()
			if lower.ends_with(".png") or lower.ends_with(".jpg") or lower.ends_with(".jpeg") or lower.ends_with(".webp"):
				out.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out

func _load_current_pfp_texture() -> Texture2D:
	var wanted_id := Auth.selected_pfp if not Auth.selected_pfp.is_empty() else DEFAULT_PFP_ID
	var tex = load(_pfp_path(wanted_id))
	if tex is Texture2D:
		return tex
	# DEFAULT_PFP_ID missing (or an old/removed selection) - fall back to
	# whatever's first alphabetically rather than showing nothing.
	var files := _list_pfp_files()
	if not files.is_empty():
		var tex2 = load(_pfp_path(files[0]))
		if tex2 is Texture2D:
			return tex2
	return _get_default_pfp_texture()

## Full-screen grid modal for picking among every image in PFP_DIR - same
## overlay-in-_canvas shape as the rest of main.gd's screens, so it's torn
## down automatically by _clear_screen() if the player navigates away.
func _show_pfp_picker() -> void:
	var files := _list_pfp_files()

	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.78)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.add_child(overlay)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	var pstyle := StyleBoxFlat.new()
	pstyle.bg_color = Color(0.08, 0.09, 0.12, 0.96)
	pstyle.set_corner_radius_all(10)
	pstyle.content_margin_left = 24
	pstyle.content_margin_right = 24
	pstyle.content_margin_top = 20
	pstyle.content_margin_bottom = 20
	panel.add_theme_stylebox_override("panel", pstyle)
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Choose a Profile Picture"
	title.add_theme_font_size_override("font_size", 20)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	if files.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No profile pictures found in assets/pfps/ yet."
		vbox.add_child(empty_lbl)
	else:
		var grid := GridContainer.new()
		grid.columns = 6
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 10)
		vbox.add_child(grid)
		for pfp_id in files:
			var tex: Texture2D = load(_pfp_path(pfp_id))
			if tex == null:
				continue
			var btn := TextureButton.new()
			btn.custom_minimum_size = Vector2(72, 72)
			btn.texture_normal = tex
			btn.ignore_texture_size = true
			btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_COVERED
			btn.material = _get_circle_mask_material()
			var captured := pfp_id
			btn.pressed.connect(func():
				Auth.set_pfp(captured)
				if is_instance_valid(_pfp_texture_rect):
					_pfp_texture_rect.texture = tex
				overlay.queue_free()
			)
			grid.add_child(btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(100, 34)
	close_btn.pressed.connect(overlay.queue_free)
	vbox.add_child(close_btn)

func _menu_btn(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(300, 72)
	btn.add_theme_font_size_override("font_size", 24)
	return btn

## Boxless nav item for the main menu's top-level list (MULTIPLAYER/VS AI/
## RANKED/DECK BUILDER/CARD LIST) - plain clickable text in the same font/
## black-outline treatment card text uses instead of a boxed button, so the
## title screen reads as this game's own look rather than generic UI chrome.
## Every other screen (lobby, auth, ranked flow, etc.) keeps _menu_btn()'s
## boxed style - this is deliberately main-menu-only.
const MENU_TEXT_COLOR := Color(0.85, 0.85, 0.92)
const MENU_TEXT_HOVER_COLOR := Color(0.45, 0.85, 1.0)
const MENU_TEXT_PRESSED_COLOR := Color(1.0, 0.82, 0.35)

func _menu_text_btn(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.flat = true
	btn.custom_minimum_size = Vector2(320, 0)
	btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.add_theme_font_override("font", MenuFont)
	btn.add_theme_font_size_override("font_size", 28)
	btn.add_theme_color_override("font_color", MENU_TEXT_COLOR)
	btn.add_theme_color_override("font_hover_color", MENU_TEXT_HOVER_COLOR)
	btn.add_theme_color_override("font_pressed_color", MENU_TEXT_PRESSED_COLOR)
	btn.add_theme_color_override("font_focus_color", MENU_TEXT_COLOR)
	btn.add_theme_constant_override("outline_size", 3)
	btn.add_theme_color_override("font_outline_color", Color.BLACK)
	var empty := StyleBoxEmpty.new()
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		btn.add_theme_stylebox_override(state, empty)
	return btn

# ── Multiplayer ────────────────────────────────────────────────────────

func _on_multiplayer_pressed() -> void:
	_clear_screen()
	_require_login_then(func():
		_mp_name = Auth.username
		_with_connection(_show_lobby_browser)
	)

## Runs on_ready once Auth.is_logged_in is true, logging in first (silently
## resuming a saved session, or showing the login/register screen) if it
## isn't yet. allow_back controls whether the login screen offers a way back
## to the main menu — false at game startup, since it doesn't exist yet.
func _require_login_then(on_ready: Callable, allow_back: bool = true) -> void:
	if Auth.is_logged_in:
		on_ready.call()
		return
	if Auth.has_saved_session():
		_show_reconnecting_screen(on_ready, allow_back)
		return
	_show_auth_screen(false, on_ready, allow_back)

# Ensures the relay connection is open before running on_ready, connecting first if needed.
# If the connection doesn't open within CONNECT_TIMEOUT_SEC, on_timeout runs instead (if given).
const CONNECT_TIMEOUT_SEC := 8.0

func _with_connection(on_ready: Callable, on_timeout: Callable = Callable()) -> void:
	if Net._connected:
		on_ready.call()
		return
	var fired := false
	Net.connected_to_server.connect(func():
		fired = true
		on_ready.call()
	, CONNECT_ONE_SHOT)
	Net.connect_to_relay()
	if on_timeout.is_valid():
		get_tree().create_timer(CONNECT_TIMEOUT_SEC).timeout.connect(func():
			if not fired:
				on_timeout.call()
		)

func _show_reconnecting_screen(on_success: Callable, allow_back: bool = true) -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	center.add_child(vbox)

	var lbl := Label.new()
	lbl.text = "Reconnecting..."
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

	# The relay round-trip plus a cold WASM boot can take several seconds on
	# a fresh page load with nothing else on screen changing — a static
	# label in that stretch is indistinguishable from a real hang. Animating
	# it is a cheap way to make "still working" visible while that happens.
	var still_connecting := true
	_animate_loading_dots(lbl, "Reconnecting", func() -> bool: return still_connecting)

	_with_connection(func():
		Auth.login_result.connect(func(success: bool, message: String):
			still_connecting = false
			_on_resume_session_result(success, message, on_success, allow_back)
		, CONNECT_ONE_SHOT)
		Auth.try_resume_session()
	, func():
		still_connecting = false
		lbl.text = "Couldn't reach the server. Check your connection and try again."
		var retry_btn := _menu_btn("RETRY")
		retry_btn.pressed.connect(func():
			_clear_screen()
			_show_reconnecting_screen(on_success, allow_back)
		)
		vbox.add_child(retry_btn)
	)

## Cycles `lbl`'s text through base_text, base_text+".", +"..", +"..." every
## 0.4s until `lbl` is freed or `should_continue` returns false — call
## without awaiting (fire-and-forget); it stops itself.
func _animate_loading_dots(lbl: Label, base_text: String, should_continue: Callable) -> void:
	var dots := 0
	while is_instance_valid(lbl) and should_continue.call():
		lbl.text = base_text + ".".repeat((dots % 3) + 1)
		dots += 1
		await get_tree().create_timer(0.4).timeout

func _on_resume_session_result(success: bool, _message: String, on_success: Callable, allow_back: bool) -> void:
	_clear_screen()
	if success:
		_mp_name = Auth.username
		on_success.call()
	else:
		_show_auth_screen(false, on_success, allow_back)

func _show_auth_screen(is_register: bool, on_success: Callable, allow_back: bool = true) -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Create Account" if is_register else "Log In"
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var username_edit := LineEdit.new()
	username_edit.custom_minimum_size = Vector2(300, 48)
	username_edit.add_theme_font_size_override("font_size", 20)
	username_edit.placeholder_text = "Username"
	username_edit.text = _mp_name
	vbox.add_child(username_edit)

	var password_edit := LineEdit.new()
	password_edit.custom_minimum_size = Vector2(300, 48)
	password_edit.add_theme_font_size_override("font_size", 20)
	password_edit.placeholder_text = "Password"
	password_edit.secret = true
	vbox.add_child(password_edit)

	var status_lbl := Label.new()
	status_lbl.add_theme_font_size_override("font_size", 14)
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_lbl.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
	vbox.add_child(status_lbl)

	var submit_btn := _menu_btn("REGISTER" if is_register else "LOG IN")
	submit_btn.custom_minimum_size = Vector2(300, 56)
	vbox.add_child(submit_btn)

	var toggle_btn := Button.new()
	toggle_btn.text = "Already have an account? Log in" if is_register else "New here? Create an account"
	toggle_btn.add_theme_font_size_override("font_size", 14)
	vbox.add_child(toggle_btn)

	if allow_back:
		var back_btn := Button.new()
		back_btn.text = "Back"
		back_btn.custom_minimum_size = Vector2(300, 48)
		back_btn.add_theme_font_size_override("font_size", 18)
		vbox.add_child(back_btn)
		back_btn.pressed.connect(func():
			_clear_screen()
			_show_main_menu()
		)

	toggle_btn.pressed.connect(func():
		_mp_name = username_edit.text
		_clear_screen()
		_show_auth_screen(not is_register, on_success, allow_back)
	)

	submit_btn.pressed.connect(func():
		var uname := username_edit.text.strip_edges()
		var pw := password_edit.text
		if uname.is_empty() or pw.is_empty():
			status_lbl.text = "Enter a username and password."
			return
		submit_btn.disabled = true
		var still_connecting := true
		status_lbl.text = "Connecting..."
		_animate_loading_dots(status_lbl, "Connecting", func() -> bool: return still_connecting)
		_with_connection(func():
			still_connecting = false
			status_lbl.text = "Registering..." if is_register else "Logging in..."
			still_connecting = true
			_animate_loading_dots(status_lbl, "Registering" if is_register else "Logging in", func() -> bool: return still_connecting)
			var handler := func(success: bool, message: String):
				still_connecting = false
				if success:
					_clear_screen()
					_mp_name = Auth.username
					on_success.call()
				else:
					submit_btn.disabled = false
					status_lbl.text = message
			if is_register:
				Auth.register_result.connect(handler, CONNECT_ONE_SHOT)
				Auth.register(uname, pw)
			else:
				Auth.login_result.connect(handler, CONNECT_ONE_SHOT)
				Auth.login(uname, pw)
		, func():
			still_connecting = false
			submit_btn.disabled = false
			status_lbl.text = "Couldn't reach the server. Check your connection and try again."
		)
	)

func _show_lobby_browser() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	# Header
	var bar := _make_header_bar("Multiplayer Lobbies  —  " + Auth.username, func():
		_clear_screen()
		_show_main_menu()
	)
	root.add_child(bar)

	# Lobby list area
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	var lobby_vbox := VBoxContainer.new()
	lobby_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lobby_vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(lobby_vbox)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 20)
	lobby_vbox.add_child(margin)

	var list_container := VBoxContainer.new()
	list_container.add_theme_constant_override("separation", 10)
	margin.add_child(list_container)

	var status_lbl := Label.new()
	status_lbl.text = "Loading lobbies..."
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	list_container.add_child(status_lbl)

	# Bottom bar
	var bottom := HBoxContainer.new()
	bottom.custom_minimum_size = Vector2(0, 60)
	bottom.add_theme_constant_override("separation", 12)
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(bottom)

	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.custom_minimum_size = Vector2(160, 44)
	refresh_btn.add_theme_font_size_override("font_size", 18)
	bottom.add_child(refresh_btn)

	var host_btn := Button.new()
	host_btn.text = "Host Lobby"
	host_btn.custom_minimum_size = Vector2(180, 44)
	host_btn.add_theme_font_size_override("font_size", 18)
	bottom.add_child(host_btn)

	var logout_btn := Button.new()
	logout_btn.text = "Log Out"
	logout_btn.custom_minimum_size = Vector2(140, 44)
	logout_btn.add_theme_font_size_override("font_size", 18)
	bottom.add_child(logout_btn)
	logout_btn.pressed.connect(func():
		Auth.logout()
		_clear_screen()
		_show_main_menu()
	)

	var _populate_list = func(lobbies_data: Array):
		for c in list_container.get_children():
			list_container.remove_child(c)
			c.queue_free()
		if lobbies_data.is_empty():
			var lbl := Label.new()
			lbl.text = "No open lobbies. Host one!"
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			list_container.add_child(lbl)
			return
		for lobby_info in lobbies_data:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 12)
			list_container.add_child(row)
			var name_lbl := Label.new()
			name_lbl.text = str(lobby_info.get("name", "Lobby"))
			name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			name_lbl.add_theme_font_size_override("font_size", 16)
			row.add_child(name_lbl)
			var host_lbl := Label.new()
			host_lbl.text = "Host: " + str(lobby_info.get("host_name", "?"))
			host_lbl.add_theme_font_size_override("font_size", 14)
			row.add_child(host_lbl)
			var join_btn := Button.new()
			join_btn.text = "Join"
			join_btn.custom_minimum_size = Vector2(80, 36)
			var lid: String = str(lobby_info.get("id", ""))
			join_btn.pressed.connect(func():
				Net.join_lobby(lid, _mp_name)
			)
			row.add_child(join_btn)

	var _lobby_list_conn = Net.lobby_list_received.connect(func(data: Array):
		_populate_list.call(data)
	)

	refresh_btn.pressed.connect(func(): Net.list_lobbies())

	Net.joined_lobby.connect(func(lobby_id: String, host_name: String):
		_mp_lobby_id = lobby_id
		_mp_is_host = false
		_clear_screen()
		_show_guest_lobby(host_name)
	, CONNECT_ONE_SHOT)

	host_btn.pressed.connect(func():
		Net.create_lobby(_mp_name)
	)

	Net.lobby_created.connect(func(lobby_id: String):
		_mp_lobby_id = lobby_id
		_mp_is_host = true
		_clear_screen()
		_show_host_lobby()
	, CONNECT_ONE_SHOT)

	Net.list_lobbies()

func _show_host_lobby() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	root.add_child(_make_header_bar("Your Lobby — Waiting for opponent", func():
		Net.send({"type": "leave_lobby"})
		_clear_screen()
		_show_lobby_browser()
	))

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	center.add_child(vbox)

	var status_lbl := Label.new()
	status_lbl.text = "Waiting for a player to join..."
	status_lbl.add_theme_font_size_override("font_size", 22)
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(status_lbl)

	var id_lbl := Label.new()
	id_lbl.text = "Lobby ID: " + _mp_lobby_id
	id_lbl.add_theme_font_size_override("font_size", 16)
	id_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(id_lbl)

	Net.player_joined.connect(func(guest_name: String):
		status_lbl.text = guest_name + " joined! Select your deck."
		_clear_screen()
		_show_deck_select(
			"Choose Your Deck",
			DeckManager.get_all_decks(),
			func(): Net.send({"type": "leave_lobby"}); _clear_screen(); _show_main_menu(),
			func(deck: Dictionary):
				_mp_player_deck_ids.clear()
				for id in deck["card_ids"]:
					_mp_player_deck_ids.append(str(id))
				_show_host_waiting_for_guest_deck(guest_name)
		)
	, CONNECT_ONE_SHOT)

func _show_host_waiting_for_guest_deck(guest_name: String) -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(center)

	var lbl := Label.new()
	lbl.text = "Waiting for %s to select a deck..." % guest_name
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.add_child(lbl)

	_await_guest_deck_and_start()

func _await_guest_deck_and_start() -> void:
	var msg: Dictionary = await Net.await_relay_of_type("deck_selected")
	_mp_guest_deck_ids.clear()
	for id in msg.get("deck_ids", []):
		_mp_guest_deck_ids.append(str(id))
	_start_mp_game_as_host()

func _show_guest_lobby(host_name: String) -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	root.add_child(_make_header_bar("Joined " + host_name + "'s Lobby", func():
		Net.send({"type": "leave_lobby"})
		_clear_screen()
		_show_lobby_browser()
	))

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	center.add_child(vbox)

	var lbl := Label.new()
	lbl.text = "Select your deck to ready up."
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

	var ready_btn := _menu_btn("SELECT DECK")
	ready_btn.pressed.connect(func():
		_clear_screen()
		_show_deck_select(
			"Choose Your Deck",
			DeckManager.get_all_decks(),
			func(): _clear_screen(); _show_guest_lobby(host_name),
			func(deck: Dictionary):
				_mp_player_deck_ids.clear()
				for id in deck["card_ids"]:
					_mp_player_deck_ids.append(str(id))
				Net.relay({"type": "deck_selected", "deck_ids": _mp_player_deck_ids})
				_start_mp_game_as_guest()
		)
	)
	vbox.add_child(ready_btn)

func _start_mp_game_as_host() -> void:
	var pd := DeckManager.build_deck_from_ids(_mp_player_deck_ids)
	var od := DeckManager.build_deck_from_ids(_mp_guest_deck_ids)
	_canvas.queue_free()
	var board := BoardScene.instantiate()
	add_child(board)
	_mp_manager = MpGameManager.new()
	board.add_child(_mp_manager)
	_mp_manager.start_as_host(board, pd, od)

func _start_mp_game_as_guest() -> void:
	_canvas.queue_free()
	var board := BoardScene.instantiate()
	add_child(board)
	_mp_manager = MpGameManager.new()
	board.add_child(_mp_manager)
	_mp_manager.start_as_guest(board)

func _on_opponent_left() -> void:
	if _mp_manager != null:
		_mp_manager.queue_free()
		_mp_manager = null
	for child in get_children():
		if child is Board:
			child.queue_free()
	_canvas = CanvasLayer.new()
	add_child(_canvas)
	var bg := TextureRect.new()
	bg.texture = WallpaperTexture
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(bg)
	_show_main_menu()

# ── Deck select ────────────────────────────────────────────────────────

func _on_play_pressed() -> void:
	_clear_screen()
	_show_deck_select(
		"Choose Your Deck",
		DeckManager.get_all_decks(),
		func(): _clear_screen(); _show_main_menu(),
		func(deck: Dictionary):
			_player_deck_ids.clear()
			for id in deck["card_ids"]:
				_player_deck_ids.append(str(id))
			_clear_screen()
			_show_opponent_select()
	)

func _on_ranked_pressed() -> void:
	# A search is already running (the bottom-right queue indicator is the
	# way to check status/cancel it) - don't let a second deck-select/search
	# get started on top of it.
	if _ranked_searching:
		return
	_clear_screen()
	_show_deck_select(
		"Choose Your Deck",
		DeckManager.get_all_decks(),
		func(): _clear_screen(); _show_main_menu(),
		func(deck: Dictionary):
			_player_deck_ids.clear()
			for id in deck["card_ids"]:
				_player_deck_ids.append(str(id))
			_clear_screen()
			_show_ranked_start()
	)

func _show_ranked_start() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	root.add_child(_make_header_bar("Ranked", func():
		_clear_screen()
		_on_ranked_pressed()
	))

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	center.add_child(vbox)

	var level_lbl := Label.new()
	level_lbl.text = RankedProgress.get_display_string(Auth.rank_bracket, Auth.rank_in_legend, Auth.rank_legend_rating)
	level_lbl.add_theme_font_size_override("font_size", 32)
	level_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(level_lbl)

	var lp_str := RankedProgress.get_lp_string(Auth.rank_in_legend, Auth.rank_lp)
	if not lp_str.is_empty():
		var lp_lbl := Label.new()
		lp_lbl.text = lp_str
		lp_lbl.add_theme_font_size_override("font_size", 16)
		lp_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(lp_lbl)

		var lp_bar := ProgressBar.new()
		lp_bar.custom_minimum_size = Vector2(240, 14)
		lp_bar.max_value = RankedProgress.LP_PER_BRACKET
		lp_bar.value = Auth.rank_lp
		lp_bar.show_percentage = false
		vbox.add_child(lp_bar)

	var record_lbl := Label.new()
	record_lbl.text = "%d W - %d L" % [Auth.ranked_wins, Auth.ranked_losses]
	record_lbl.add_theme_font_size_override("font_size", 18)
	record_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(record_lbl)

	if Auth.ranked_win_streak >= RankedProgress.LP_WIN_STREAK_THRESHOLD:
		var streak_lbl := Label.new()
		streak_lbl.text = "%d win streak — bonus LP active!" % Auth.ranked_win_streak
		streak_lbl.add_theme_font_size_override("font_size", 14)
		streak_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		streak_lbl.add_theme_color_override("font_color", Color(0.95, 0.75, 0.25))
		vbox.add_child(streak_lbl)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(gap)

	var start_btn := _menu_btn("START MATCH")
	start_btn.pressed.connect(_begin_ranked_search)
	vbox.add_child(start_btn)

# ── Ranked matchmaking ──────────────────────────────────────────────────
#
# START MATCH sends the player back to the main menu (free to navigate menus/
# card list/deck builder in the meantime) with a small "Searching for
# opponent..." indicator pinned to the bottom-right of the screen, and queues
# for a same-skill human opponent for up to RANKED_SEARCH_TIMEOUT_SEC; if
# nobody's found in time, falls back to the existing AI match (with a fake
# bot name in the opponent nameplate) so Ranked always produces a match.
# Either resolution shows a "Match Found!" popup with a
# RANKED_MATCH_COUNTDOWN_SEC countdown - on top of whatever screen the player
# is currently looking at - before the game actually starts. `_ranked_search_id`
# guards against the match-found signal and the timeout racing each other,
# and against a stale timer/signal from an earlier cancelled search firing
# into a later one — whichever resolution is current wins, anything bound to
# an older id is a no-op.

func _begin_ranked_search() -> void:
	_ranked_search_id += 1
	var search_id := _ranked_search_id
	_ranked_searching = true
	_clear_screen()
	_show_main_menu()
	_show_queue_overlay("Searching for opponent...", _cancel_ranked_search, func() -> bool:
		return _ranked_search_id == search_id
	)
	Auth.queue_ranked()
	_ranked_match_found_callable = _on_ranked_match_found.bind(search_id)
	Net.ranked_match_found.connect(_ranked_match_found_callable, CONNECT_ONE_SHOT)
	get_tree().create_timer(RANKED_SEARCH_TIMEOUT_SEC).timeout.connect(_on_ranked_search_timeout.bind(search_id))

func _disconnect_ranked_match_found() -> void:
	if _ranked_match_found_callable.is_valid() and Net.ranked_match_found.is_connected(_ranked_match_found_callable):
		Net.ranked_match_found.disconnect(_ranked_match_found_callable)

## Small bottom-right status indicator + Cancel button, shared by Ranked and
## Campaign matchmaking. Lives in its own CanvasLayer (sibling of _canvas,
## not inside it) so it keeps showing across _clear_screen() calls as the
## player navigates other menus while queued. `still_active` gates the
## animated-dots loop - it should check the caller's own search-id guard, the
## same one `on_cancel` bumps, so a stale animation from an already-
## cancelled/resolved search can't keep running into a later one.
func _show_queue_overlay(status_text: String, on_cancel: Callable, still_active: Callable) -> void:
	_hide_queue_overlay()
	_queue_layer = CanvasLayer.new()
	_queue_layer.layer = 10
	add_child(_queue_layer)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	panel.position = Vector2(-270, -64)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.10, 0.85)
	style.set_corner_radius_all(6)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	_queue_layer.add_child(panel)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)
	panel.add_child(hbox)

	var status_lbl := Label.new()
	status_lbl.text = status_text
	status_lbl.add_theme_font_size_override("font_size", 16)
	hbox.add_child(status_lbl)
	_animate_loading_dots(status_lbl, status_text, func() -> bool:
		return still_active.call() and is_instance_valid(_queue_layer)
	)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.add_theme_font_size_override("font_size", 14)
	cancel_btn.pressed.connect(on_cancel)
	hbox.add_child(cancel_btn)

func _hide_queue_overlay() -> void:
	if is_instance_valid(_queue_layer):
		_queue_layer.queue_free()
	_queue_layer = null

func _cancel_ranked_search() -> void:
	_ranked_search_id += 1
	_ranked_searching = false
	_disconnect_ranked_match_found()
	Auth.cancel_ranked_queue()
	_hide_queue_overlay()

func _on_ranked_search_timeout(search_id: int) -> void:
	if search_id != _ranked_search_id:
		return
	_ranked_search_id += 1
	_disconnect_ranked_match_found()
	Auth.cancel_ranked_queue()
	_hide_queue_overlay()
	var ai_level := RankedProgress.get_ai_level(Auth.rank_bracket, Auth.rank_in_legend)
	var bot_name := RankedProgress.random_bot_name()
	_show_match_found_popup(bot_name, -1, func():
		_ranked_searching = false
		_clear_screen()
		_start_game(_player_deck_ids, _random_ranked_opponent_ids(), ai_level, true, bot_name)
	)

func _on_ranked_match_found(lobby_id: String, role: String, opponent_name: String, opponent_rating: int,
							 search_id: int) -> void:
	if search_id != _ranked_search_id:
		return
	_ranked_search_id += 1
	_hide_queue_overlay()
	_show_match_found_popup(opponent_name, opponent_rating, func():
		_ranked_searching = false
		_start_ranked_pvp_match(role, opponent_name, opponent_rating)
	)

## Popup shown on top of whatever screen the player is currently on (menu,
## card list, deck builder, ...) once a match is found, with a countdown
## before the match actually starts. `opponent_rating < 0` hides the rating
## (used for the AI-fallback case, where there's no real rating to show).
func _show_match_found_popup(opponent_name: String, opponent_rating: int, on_complete: Callable) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.13, 0.96)
	style.set_corner_radius_all(10)
	style.content_margin_left = 40
	style.content_margin_right = 40
	style.content_margin_top = 28
	style.content_margin_bottom = 28
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var found_lbl := Label.new()
	found_lbl.text = "Match Found!"
	found_lbl.add_theme_font_size_override("font_size", 36)
	found_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(found_lbl)

	var vs_lbl := Label.new()
	vs_lbl.text = ("vs %s (~%d)" % [opponent_name, opponent_rating]) if opponent_rating >= 0 else ("vs %s" % opponent_name)
	vs_lbl.add_theme_font_size_override("font_size", 20)
	vs_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(vs_lbl)

	var countdown_lbl := Label.new()
	countdown_lbl.add_theme_font_size_override("font_size", 26)
	countdown_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(countdown_lbl)

	var seconds_left := RANKED_MATCH_COUNTDOWN_SEC
	countdown_lbl.text = "Match starts in %d..." % seconds_left
	for _i in RANKED_MATCH_COUNTDOWN_SEC:
		await get_tree().create_timer(1.0).timeout
		seconds_left -= 1
		if is_instance_valid(countdown_lbl):
			countdown_lbl.text = "Match starts in %d..." % max(seconds_left, 0)

	layer.queue_free()
	on_complete.call()

func _start_ranked_pvp_match(role: String, opponent_name: String, opponent_rating: int) -> void:
	if role == "host":
		_await_ranked_guest_deck_and_start(opponent_name, opponent_rating)
	else:
		Net.relay({"type": "deck_selected", "deck_ids": _player_deck_ids})
		_canvas.queue_free()
		var board := BoardScene.instantiate()
		add_child(board)
		_connect_ranked_requeue(board)
		_mp_manager = MpGameManager.new()
		board.add_child(_mp_manager)
		_mp_manager.start_as_guest(board, opponent_name, true, opponent_rating)

func _await_ranked_guest_deck_and_start(opponent_name: String, opponent_rating: int) -> void:
	var msg: Dictionary = await Net.await_relay_of_type("deck_selected")
	var guest_deck_ids: Array[String] = []
	for id in msg.get("deck_ids", []):
		guest_deck_ids.append(str(id))
	var pd := DeckManager.build_deck_from_ids(_player_deck_ids)
	var od := DeckManager.build_deck_from_ids(guest_deck_ids)
	_canvas.queue_free()
	var board := BoardScene.instantiate()
	add_child(board)
	_connect_ranked_requeue(board)
	_mp_manager = MpGameManager.new()
	board.add_child(_mp_manager)
	_mp_manager.start_as_host(board, pd, od, opponent_name, true, opponent_rating)

const RANKED_FACTIONS := [
	CardData.CardColor.GREEN, CardData.CardColor.CRIMSON, CardData.CardColor.BLACK,
	CardData.CardColor.ORANGE, CardData.CardColor.TEAL,
]

func _random_ranked_opponent_ids() -> Array[String]:
	var faction_color: CardData.CardColor = RANKED_FACTIONS[randi() % RANKED_FACTIONS.size()]
	var opp_deck := DeckManager.build_archetype_deck(faction_color)
	var opp_ids: Array[String] = []
	for c in opp_deck:
		opp_ids.append(c.id)
	return opp_ids

const AI_DIFFICULTIES := [
	{"label": "EASY",   "level": 1,  "color": Color(0.30, 0.80, 0.30)},
	{"label": "MEDIUM", "level": 5,  "color": Color(0.90, 0.70, 0.20)},
	{"label": "HARD",   "level": 10, "color": Color(0.85, 0.25, 0.25)},
]

## Shared Easy/Medium/Hard (AI level 1/5/10) toggle row, used by both the VS
## AI opponent-select screen and the Simulation screen. on_change(level) is
## called immediately when a different option is picked.
func _add_difficulty_row(vbox: Control, default_level: int, on_change: Callable) -> void:
	var diff_label := Label.new()
	diff_label.text = "Difficulty"
	diff_label.add_theme_font_size_override("font_size", 16)
	diff_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(diff_label)

	var diff_row := HBoxContainer.new()
	diff_row.alignment = BoxContainer.ALIGNMENT_CENTER
	diff_row.add_theme_constant_override("separation", 10)
	vbox.add_child(diff_row)

	var diff_group := ButtonGroup.new()
	for entry in AI_DIFFICULTIES:
		var level: int = entry["level"]
		var swatch: Color = entry["color"]

		var dbtn := Button.new()
		dbtn.text = entry["label"]
		dbtn.custom_minimum_size = Vector2(110, 48)
		dbtn.add_theme_font_size_override("font_size", 16)
		dbtn.toggle_mode = true
		dbtn.button_group = diff_group
		dbtn.button_pressed = (level == default_level)

		var ns := StyleBoxFlat.new()
		ns.bg_color = Color(0.14, 0.14, 0.17)
		ns.set_corner_radius_all(6)
		ns.border_width_left = 3
		ns.border_color = swatch.darkened(0.3)
		dbtn.add_theme_stylebox_override("normal", ns)
		var pressed_s := StyleBoxFlat.new()
		pressed_s.bg_color = swatch.darkened(0.55)
		pressed_s.set_corner_radius_all(6)
		pressed_s.border_width_left = 3
		pressed_s.border_color = swatch
		dbtn.add_theme_stylebox_override("pressed", pressed_s)

		dbtn.pressed.connect(func(): on_change.call(level))
		diff_row.add_child(dbtn)

func _show_opponent_select() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	root.add_child(_make_header_bar("Choose Opponent Faction", func():
		_clear_screen()
		_on_play_pressed()
	))

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	center.add_child(vbox)

	var selected_ai_level := 5  # Medium by default
	_add_difficulty_row(vbox, selected_ai_level, func(level: int): selected_ai_level = level)

	var diff_gap := Control.new()
	diff_gap.custom_minimum_size = Vector2(0, 10)
	vbox.add_child(diff_gap)

	var FACTIONS := [
		{"label": "Random Sapiens",        "color": CardData.CardColor.GREEN,   "swatch": Color(0.20, 0.65, 0.20)},
		{"label": "Random Moonlight Coven", "color": CardData.CardColor.CRIMSON, "swatch": Color(0.80, 0.20, 0.20)},
		{"label": "Random Junklings",       "color": CardData.CardColor.BLACK,   "swatch": Color(0.45, 0.45, 0.50)},
		{"label": "Random Gundari",         "color": CardData.CardColor.ORANGE,  "swatch": Color(0.90, 0.50, 0.10)},
		{"label": "Random Inyuites",        "color": CardData.CardColor.TEAL,    "swatch": Color(0.10, 0.60, 0.70)},
	]

	for entry in FACTIONS:
		var faction_color: CardData.CardColor = entry["color"]
		var swatch: Color = entry["swatch"]
		var label: String = entry["label"]

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(340, 68)
		btn.add_theme_font_size_override("font_size", 22)

		var ns := StyleBoxFlat.new()
		ns.bg_color = swatch.darkened(0.45)
		ns.set_corner_radius_all(8)
		ns.border_width_left = 5
		ns.border_color = swatch
		btn.add_theme_stylebox_override("normal", ns)
		var hs := StyleBoxFlat.new()
		hs.bg_color = swatch.darkened(0.25)
		hs.set_corner_radius_all(8)
		hs.border_width_left = 5
		hs.border_color = swatch.lightened(0.2)
		btn.add_theme_stylebox_override("hover", hs)
		var ps := StyleBoxFlat.new()
		ps.bg_color = swatch.darkened(0.55)
		ps.set_corner_radius_all(8)
		btn.add_theme_stylebox_override("pressed", ps)

		btn.text = label
		btn.pressed.connect(func():
			var opp_deck := DeckManager.build_archetype_deck(faction_color)
			var opp_ids: Array[String] = []
			for c in opp_deck:
				opp_ids.append(c.id)
			_start_game(_player_deck_ids, opp_ids, selected_ai_level)
		)
		vbox.add_child(btn)


func _show_deck_select(title: String, decks: Array[Dictionary], on_back: Callable, on_select: Callable) -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	root.add_child(_make_header_bar(title, on_back))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	var outer := MarginContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		outer.add_theme_constant_override(side, 30)
	scroll.add_child(outer)

	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 20)
	flow.add_theme_constant_override("v_separation", 20)
	outer.add_child(flow)

	for deck in decks:
		flow.add_child(_deck_card_btn(deck, on_select))

func _make_header_bar(title: String, on_back: Callable) -> Panel:
	var bar := Panel.new()
	bar.custom_minimum_size = Vector2(0, 64)
	var bar_style := StyleBoxFlat.new()
	bar_style.bg_color = Color(0.10, 0.11, 0.16)
	bar.add_theme_stylebox_override("panel", bar_style)

	var bar_m := MarginContainer.new()
	bar_m.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		bar_m.add_theme_constant_override(side, 10)
	bar.add_child(bar_m)

	var bar_hbox := HBoxContainer.new()
	bar_hbox.add_theme_constant_override("separation", 14)
	bar_m.add_child(bar_hbox)

	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(100, 42)
	back_btn.add_theme_font_size_override("font_size", 16)
	bar_hbox.add_child(back_btn)
	back_btn.pressed.connect(on_back)

	var title_lbl := Label.new()
	title_lbl.text = title
	title_lbl.add_theme_font_size_override("font_size", 28)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar_hbox.add_child(title_lbl)

	return bar

func _deck_card_btn(deck: Dictionary, on_select: Callable) -> Button:
	var faction_idx: int = int(deck.get("faction_idx", 0))
	var sw: Color = DeckManager.FACTION_SWATCHES[faction_idx]
	var deck_name: String = str(deck.get("name", "Unknown"))
	var is_starter: bool = bool(deck.get("is_starter", false))
	var count: int = (deck.get("card_ids", []) as Array).size()

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(260, 148)
	btn.clip_contents = true

	var ns := StyleBoxFlat.new()
	ns.bg_color = sw.darkened(0.4)
	ns.set_corner_radius_all(10)
	ns.border_width_left = 4
	ns.border_color = sw
	btn.add_theme_stylebox_override("normal", ns)
	var hs := StyleBoxFlat.new()
	hs.bg_color = sw.darkened(0.2)
	hs.set_corner_radius_all(10)
	hs.border_width_left = 4
	hs.border_color = sw.lightened(0.2)
	btn.add_theme_stylebox_override("hover", hs)
	var ps := StyleBoxFlat.new()
	ps.bg_color = sw.darkened(0.5)
	ps.set_corner_radius_all(10)
	btn.add_theme_stylebox_override("pressed", ps)

	var inner := VBoxContainer.new()
	inner.set_anchors_preset(Control.PRESET_FULL_RECT)
	inner.alignment = BoxContainer.ALIGNMENT_CENTER
	inner.add_theme_constant_override("separation", 5)
	btn.add_child(inner)

	if is_starter:
		var badge := Label.new()
		badge.text = "STARTER"
		badge.add_theme_font_size_override("font_size", 10)
		badge.add_theme_color_override("font_color", sw.lightened(0.5))
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.add_child(badge)

	var name_lbl := Label.new()
	name_lbl.text = deck_name
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(name_lbl)

	var info := Label.new()
	info.text = "%s  •  %d cards" % [DeckManager.FACTION_NAMES[faction_idx], count]
	info.add_theme_font_size_override("font_size", 12)
	info.add_theme_color_override("font_color", Color(0.70, 0.70, 0.70))
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(info)

	btn.pressed.connect(func(): on_select.call(deck))
	return btn

# ── Deck builder ───────────────────────────────────────────────────────

func _on_deck_builder_pressed() -> void:
	_clear_screen()
	var builder := DeckBuilderScene.instantiate()
	_canvas.add_child(builder)
	builder.back_pressed.connect(func():
		_clear_screen()
		_show_main_menu()
	)

# ── Shop (currency, packs, crafting) ────────────────────────────────────

func _on_shop_pressed() -> void:
	_clear_screen()
	var screen := ShopScreenScript.new()
	_canvas.add_child(screen)
	screen.back_pressed.connect(func():
		_clear_screen()
		_show_main_menu()
	)
	screen.pack_opened_ready.connect(func(cards: Array, dust_awarded: int):
		_clear_screen()
		var open_screen := PackOpenScreenScript.new()
		_canvas.add_child(open_screen)
		open_screen.finished.connect(func():
			_clear_screen()
			_on_shop_pressed()
		)
		open_screen.setup(cards, dust_awarded)
	)

# ── Card list ──────────────────────────────────────────────────────────

func _on_card_list_pressed() -> void:
	_clear_screen()
	var screen := CardListScreen.new()
	_canvas.add_child(screen)
	screen.back_pressed.connect(func():
		_clear_screen()
		_show_main_menu()
	)

# ── Game start ─────────────────────────────────────────────────────────

func _start_game(player_ids: Array[String], opp_ids: Array[String], ai_level: int = 5, ranked: bool = false,
				  opponent_name: String = "") -> void:
	_player_deck_ids = player_ids.duplicate()
	_opponent_deck_ids = opp_ids.duplicate()
	var pd := DeckManager.build_deck_from_ids(player_ids)
	var od := DeckManager.build_deck_from_ids(opp_ids)
	if is_instance_valid(_canvas):
		_canvas.queue_free()
	var board := BoardScene.instantiate()
	add_child(board)
	if not opponent_name.is_empty():
		board.set_opponent_name(opponent_name)
	if ranked:
		_connect_ranked_requeue(board)
	else:
		board.restart_requested.connect(func():
			board.queue_free()
			_start_game(_player_deck_ids, _opponent_deck_ids, ai_level, ranked)
		, CONNECT_ONE_SHOT)
	GameManagerAutoload.start_local_game(board, pd, od, ai_level, ranked)

## Wires up the "Queue" button on a ranked game-over screen (see
## board.gd's show_game_over) to drop the finished board and jump straight
## back into ranked matchmaking — same as pressing START MATCH from the
## Ranked menu, so a requeue can find a human opponent again instead of
## just replaying the same AI.
func _connect_ranked_requeue(board: Board) -> void:
	board.ranked_requeue_requested.connect(func():
		board.queue_free()
		_create_canvas()
		_begin_ranked_search()
	, CONNECT_ONE_SHOT)

# ── Campaign ───────────────────────────────────────────────────────────
#
# A Campaign run is a best-of-3/5/7 sequence of independent local-AI matches
# ("nodes") against one fixed opponent deck; some nodes carry a
# battlefield-wide modifier (CampaignModifiers / GameState.node_modifier_ability).
# Whoever lost the previous node picks the next flagged node's modifier from
# two options; falling 2+ node-wins behind grants a one-time extra starting
# mana crystal on the next node. See campaign_state.gd for the full rules.

func _on_campaign_pressed() -> void:
	# A campaign search is already running - the bottom-right queue indicator
	# is the way to check status/cancel it, same as Ranked.
	if _campaign_searching:
		return
	_clear_screen()
	_show_deck_select(
		"Choose Your Deck",
		DeckManager.get_all_decks(),
		func(): _clear_screen(); _show_main_menu(),
		func(deck: Dictionary):
			_player_deck_ids.clear()
			for id in deck["card_ids"]:
				_player_deck_ids.append(str(id))
			_campaign_player_faction = int(deck.get("faction_idx", 0))
			_clear_screen()
			_show_campaign_setup()
	)

func _show_campaign_setup() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	_canvas.add_child(root)

	root.add_child(_make_header_bar("Campaign", func():
		_clear_screen()
		_on_campaign_pressed()
	))

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	center.add_child(vbox)

	var selected_ai_level := 5  # Medium by default
	_add_difficulty_row(vbox, selected_ai_level, func(level: int): selected_ai_level = level)

	var diff_gap := Control.new()
	diff_gap.custom_minimum_size = Vector2(0, 10)
	vbox.add_child(diff_gap)

	var campaign_sizes := [
		{"label": "SMALL",  "size": CampaignState.Size.SMALL,  "desc": "Best of 3 · 1 modified node"},
		{"label": "MEDIUM", "size": CampaignState.Size.MEDIUM, "desc": "Best of 5 · 2 modified nodes"},
		{"label": "LARGE",  "size": CampaignState.Size.LARGE,  "desc": "Best of 7 · 4 modified nodes"},
	]
	for entry in campaign_sizes:
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		vbox.add_child(row)

		var btn := _menu_btn(entry["label"])
		btn.pressed.connect(func():
			_begin_campaign_search(entry["size"], selected_ai_level)
		)
		row.add_child(btn)

		var desc_lbl := Label.new()
		desc_lbl.text = entry["desc"]
		desc_lbl.add_theme_font_size_override("font_size", 14)
		desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(desc_lbl)

# ── Campaign matchmaking ─────────────────────────────────────────────────
#
# Picking a size queues for a same-size human opponent for up to
# CAMPAIGN_SEARCH_TIMEOUT_SEC (identical shape to the Ranked search above:
# bottom-right queue indicator, free navigation while queued, "Match Found!"
# countdown popup); if nobody's found in time, falls back to today's local
# AI campaign (fixed "Rival Warlord" opponent). A found human opponent plays
# every node of the run - see _start_campaign_pvp.

func _begin_campaign_search(size: CampaignState.Size, ai_level: int) -> void:
	_campaign_search_id += 1
	var search_id := _campaign_search_id
	_campaign_searching = true
	_campaign_ai_level = ai_level
	_clear_screen()
	_show_main_menu()
	_show_queue_overlay("Searching for campaign opponent...", _cancel_campaign_search, func() -> bool:
		return _campaign_search_id == search_id
	)
	Auth.queue_campaign(size)
	_campaign_match_found_callable = _on_campaign_match_found.bind(search_id)
	Net.campaign_match_found.connect(_campaign_match_found_callable, CONNECT_ONE_SHOT)
	get_tree().create_timer(CAMPAIGN_SEARCH_TIMEOUT_SEC).timeout.connect(_on_campaign_search_timeout.bind(size, search_id))

func _disconnect_campaign_match_found() -> void:
	if _campaign_match_found_callable.is_valid() and Net.campaign_match_found.is_connected(_campaign_match_found_callable):
		Net.campaign_match_found.disconnect(_campaign_match_found_callable)

func _cancel_campaign_search() -> void:
	_campaign_search_id += 1
	_campaign_searching = false
	_disconnect_campaign_match_found()
	Auth.cancel_campaign_queue()
	_hide_queue_overlay()

func _on_campaign_search_timeout(size: CampaignState.Size, search_id: int) -> void:
	if search_id != _campaign_search_id:
		return
	_campaign_search_id += 1
	_disconnect_campaign_match_found()
	Auth.cancel_campaign_queue()
	_hide_queue_overlay()
	_show_match_found_popup(CAMPAIGN_OPPONENT_NAME, -1, func():
		_campaign_searching = false
		_clear_screen()
		_start_campaign(size, _campaign_ai_level)
	)

func _on_campaign_match_found(lobby_id: String, role: String, opponent_name: String, size: int,
							   search_id: int) -> void:
	if search_id != _campaign_search_id:
		return
	_campaign_search_id += 1
	_hide_queue_overlay()
	_show_match_found_popup(opponent_name, -1, func():
		_campaign_searching = false
		_start_campaign_pvp(role, opponent_name, size)
	)

func _start_campaign(size: CampaignState.Size, ai_level: int) -> void:
	_campaign_pvp = false
	_campaign_state = CampaignState.new(size)
	_campaign_ai_level = ai_level
	_campaign_opponent_name = CAMPAIGN_OPPONENT_NAME
	var opponent_faction: CardData.CardColor = RANKED_FACTIONS[randi() % RANKED_FACTIONS.size()]
	var opp_deck := DeckManager.build_archetype_deck(opponent_faction)
	_campaign_opponent_deck_ids.clear()
	for c in opp_deck:
		_campaign_opponent_deck_ids.append(c.id)
	_campaign_opponent_deck_faction = opponent_faction
	_campaign_state.set_faction_colors(_campaign_player_faction, opponent_faction)
	_show_campaign_map_screen(null)

## One-time handshake right after a human opponent is found: decks (fixed
## for the whole run, same as the local-AI campaign's one fixed opponent
## deck) and the host's authoritative CampaignState layout (which nodes are
## modified, node 0's modifier, map choice, node positions) are exchanged
## exactly once here via the generic relay/await_relay_of_type channel
## already used for Ranked's deck exchange - every later node in the run
## reuses this same lobby/relay connection, no further matchmaking needed.
func _start_campaign_pvp(role: String, opponent_name: String, size: int) -> void:
	_campaign_pvp = true
	_campaign_pvp_role = role
	_campaign_opponent_name = opponent_name
	if role == "host":
		_await_campaign_guest_deck_and_start(size as CampaignState.Size)
	else:
		Net.relay({"type": "campaign_deck", "deck_ids": _player_deck_ids, "faction_idx": int(_campaign_player_faction)})
		var msg: Dictionary = await Net.await_relay_of_type("campaign_layout")
		_campaign_state = CampaignState.new(size as CampaignState.Size)
		_campaign_state.apply_layout(msg.get("layout", {}))
		_campaign_opponent_deck_ids.clear()
		for id in msg.get("opponent_deck_ids", []):
			_campaign_opponent_deck_ids.append(str(id))
		_campaign_opponent_deck_faction = int(msg.get("opponent_faction_idx", 0))
		_campaign_state.set_faction_colors(_campaign_player_faction, _campaign_opponent_deck_faction)
		_show_campaign_map_screen(null)

func _await_campaign_guest_deck_and_start(size: CampaignState.Size) -> void:
	var msg: Dictionary = await Net.await_relay_of_type("campaign_deck")
	_campaign_opponent_deck_ids.clear()
	for id in msg.get("deck_ids", []):
		_campaign_opponent_deck_ids.append(str(id))
	_campaign_opponent_deck_faction = int(msg.get("faction_idx", 0))
	_campaign_state = CampaignState.new(size)
	_campaign_state.set_faction_colors(_campaign_player_faction, _campaign_opponent_deck_faction)
	Net.relay({
		"type": "campaign_layout",
		"layout": _campaign_state.to_layout_dict(),
		"opponent_deck_ids": _player_deck_ids,
		"opponent_faction_idx": int(_campaign_player_faction),
	})
	_show_campaign_map_screen(null)

# ── Campaign map / node loop ─────────────────────────────────────────────

## Shown before the first node and again after every subsequent one - a
## cinematic map (CampaignMapScreen) that reports the last node's result (if
## any), resolves/waits for the next flagged node's modifier if one is
## needed, zooms to the next node and counts down to it automatically. Not
## shown inside a match itself. `last_result` is null for the very first
## node of a run.
func _show_campaign_map_screen(last_result) -> void:
	_clear_screen()
	var map_screen := CampaignMapScreen.new()
	map_screen.campaign_state = _campaign_state
	map_screen.opponent_name = _campaign_opponent_name
	map_screen.last_result = last_result
	if _campaign_pvp and last_result == true and _campaign_state.current_node_needs_choice():
		map_screen.awaiting_opponent_modifier = true
	_canvas.add_child(map_screen)
	map_screen.proceed_pressed.connect(_start_campaign_node_match, CONNECT_ONE_SHOT)
	if _campaign_pvp:
		map_screen.modifier_chosen.connect(func(chosen: Dictionary):
			Net.relay({"type": "campaign_modifier_chosen", "modifier": chosen})
		)
		if map_screen.awaiting_opponent_modifier:
			_await_campaign_modifier_choice(map_screen)

## Fire-and-forget: only relevant when _show_campaign_map_screen just put the
## map screen into its "waiting for opponent to choose" state.
func _await_campaign_modifier_choice(map_screen: CampaignMapScreen) -> void:
	var msg: Dictionary = await Net.await_relay_of_type("campaign_modifier_chosen")
	if is_instance_valid(map_screen):
		map_screen.on_modifier_resolved(msg.get("modifier", {}))

func _start_campaign_node_match() -> void:
	if _campaign_pvp:
		_start_campaign_pvp_match()
	else:
		_start_campaign_match()

func _start_campaign_match() -> void:
	var node := _campaign_state.current_node()
	var pd := DeckManager.build_deck_from_ids(_player_deck_ids)
	var od := DeckManager.build_deck_from_ids(_campaign_opponent_deck_ids)
	if is_instance_valid(_canvas):
		_canvas.queue_free()
	var board := BoardScene.instantiate()
	add_child(board)
	board.set_opponent_name(_campaign_opponent_name)
	if not node.is_empty():
		board.set_node_modifier_label("%s: %s" % [node["name"], node["description"]])
	board.campaign_continue_requested.connect(_on_campaign_match_finished.bind(board), CONNECT_ONE_SHOT)
	var modifier_ability: String = str(node.get("ability", ""))
	var grant_bonus := _campaign_state.is_player_behind()
	GameManagerAutoload.start_local_game(board, pd, od, _campaign_ai_level, false, true, modifier_ability, grant_bonus)

## PvP sibling of _start_campaign_match - a fresh Board + MpGameManager per
## node (same recreate-per-match pattern _start_ranked_pvp_match uses), host-
## authoritative same as Ranked. Only the host computes node_modifier_ability/
## grant_bonus_*: those drive game_state on the host's own authoritative copy
## and reach the guest purely as a side effect of the normal state sync
## (see mp_game_manager.gd), so the guest call doesn't need them at all.
func _start_campaign_pvp_match() -> void:
	var node := _campaign_state.current_node()
	if is_instance_valid(_canvas):
		_canvas.queue_free()
	var board := BoardScene.instantiate()
	add_child(board)
	board.set_opponent_name(_campaign_opponent_name)
	if not node.is_empty():
		board.set_node_modifier_label("%s: %s" % [node["name"], node["description"]])
	board.campaign_continue_requested.connect(_on_campaign_match_finished.bind(board), CONNECT_ONE_SHOT)
	_mp_manager = MpGameManager.new()
	board.add_child(_mp_manager)
	if _campaign_pvp_role == "host":
		var pd := DeckManager.build_deck_from_ids(_player_deck_ids)
		var od := DeckManager.build_deck_from_ids(_campaign_opponent_deck_ids)
		var modifier_ability: String = str(node.get("ability", ""))
		_mp_manager.start_as_host(board, pd, od, _campaign_opponent_name, false, -1,
			modifier_ability, _campaign_state.is_player_behind(), _campaign_state.is_opponent_behind(), true)
	else:
		_mp_manager.start_as_guest(board, _campaign_opponent_name, false, -1, true)

func _on_campaign_match_finished(board: Board) -> void:
	var won: bool
	if _campaign_pvp:
		var my_id := MpGameManager.HOST_ID if _campaign_pvp_role == "host" else MpGameManager.GUEST_ID
		won = _mp_manager.game_state.winner_id == my_id
	else:
		won = GameManagerAutoload.game_state.winner_id == GameManagerAutoload.LOCAL_PLAYER_ID
	_campaign_state.report_node_result(won)
	board.queue_free()
	_create_canvas()
	if _campaign_state.is_over():
		_show_campaign_final_screen()
	else:
		_show_campaign_map_screen(won)

func _show_campaign_final_screen() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 14)
	center.add_child(vbox)

	var won := _campaign_state.player_won_campaign()
	if won:
		Economy.claim_earn_reward("campaign_milestone")
	var result_lbl := Label.new()
	result_lbl.text = "Campaign Won!" if won else "Campaign Lost"
	result_lbl.add_theme_font_size_override("font_size", 48)
	result_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(result_lbl)

	var score_lbl := Label.new()
	score_lbl.text = "Final score: %s" % _campaign_state.score_string()
	score_lbl.add_theme_font_size_override("font_size", 22)
	score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(score_lbl)

	var menu_btn := _menu_btn("RETURN TO MENU")
	menu_btn.pressed.connect(func():
		_campaign_state = null
		_campaign_pvp = false
		_campaign_pvp_role = ""
		_mp_manager = null
		_clear_screen()
		_show_main_menu()
	)
	vbox.add_child(menu_btn)

