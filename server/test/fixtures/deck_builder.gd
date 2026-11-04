extends Node

var failures: Array[String] = []
var screen: DeckBuilderScreen
var captures := ""

func _ready() -> void:
	Net.set_process(false)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--deck-captures="): captures = arg.trim_prefix("--deck-captures=")
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)

func settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

func click(control: Control) -> void:
	var at := control.get_global_rect().get_center()
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		get_viewport().push_input(event, true)
		await get_tree().process_frame
	await settle()

func key(code: Key, ctrl: bool = false) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.ctrl_pressed = ctrl
		event.pressed = down
		get_viewport().push_input(event, true)
		await get_tree().process_frame
	await settle()

func button(label: String) -> Button:
	for b in screen.find_children("*", "Button", true, false):
		if b.is_visible_in_tree() and b.accessibility_name == label: return b
	check(false, "button missing: " + label)
	return null

func capture(label: String) -> void:
	if captures.is_empty(): return
	await settle()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(captures.path_join("deck-builder-" + label + ".png"))

func _run() -> void:
	get_tree().root.content_scale_size = Vector2i.ZERO
	get_tree().root.size = Vector2i(1920, 1080)
	screen = preload("res://scenes/ui/DeckBuilderScreen.tscn").instantiate()
	add_child(screen)
	await settle()
	await capture("empty-hub")
	await click(button("Create a deck"))
	check(screen._faction_page.visible, "create opens factions")
	await capture("factions")
	get_tree().root.size = Vector2i(960, 640)
	await settle()
	await capture("factions-960")
	get_tree().root.size = Vector2i(1920, 1080)
	await settle()
	await click(button(DeckManager.FACTION_NAMES[0]))
	check(screen._editor_page.visible and screen._faction_idx == 0, "faction action opens editor")
	var ids: Array[String] = []
	for c in DeckManager.build_random_faction_deck(CardData.CardColor.GREEN): ids.append(c.id)
	screen._show_editor_page(0, "A very long deck name for frontier pilots", ids)
	await settle()
	await capture("editor-wide")
	for dimensions in [Vector2i(1280, 800), Vector2i(960, 640)]:
		get_tree().root.size = dimensions
		await settle()
		check(screen.get_global_rect().encloses(screen._editor_page.get_global_rect()), "editor fits viewport " + str(dimensions.x))
		await capture("editor-" + str(dimensions.x))
	await behavior()
	print("DECK_BUILDER_RESULT " + JSON.stringify({"failures": failures}))
	get_tree().quit(0 if failures.is_empty() else 1)

func type_text(edit: LineEdit, text: String) -> void:
	await click(edit)
	await key(KEY_A, true)
	await key(KEY_BACKSPACE)
	for character in text:
		var event := InputEventKey.new()
		event.unicode = character.unicode_at(0)
		event.pressed = true
		get_viewport().push_input(event, true)
	await settle()

func saved(name_value: String) -> Dictionary:
	for deck in DeckManager.get_custom_decks():
		if deck.name == name_value: return deck
	return {}

func behavior() -> void:
	get_tree().root.size = Vector2i(1280, 800)
	screen._show_editor_page(0, "UI original deck", [])
	await settle()
	await click(button("Add Lone Operative"))
	button("Add Lone Operative").grab_focus()
	await key(KEY_ENTER)
	check(screen._deck_ids.size() == 2 and screen._deck_ids.all(func(id): return CardDatabase.get_card(id).card_name == "Lone Operative"), "clicking collection adds up to the copy limit")
	check(button("Add Lone Operative").disabled, "two-copy card disables at its limit")
	button("Remove one Lone Operative").grab_focus()
	await key(KEY_ENTER)
	check(screen._deck_ids.size() == 1, "keyboard deck row removes one copy")
	check(int(screen._curve_counts[1].text) == 1, "mana curve follows removal")
	await type_text(screen._search_bar, "reinforce")
	check(screen._cells.values().any(func(cell): return cell.add.accessibility_name == "Add Cocky Commando"), "search includes ability descriptions")
	await type_text(screen._search_bar, "no-card-can-match-this")
	check(screen._cells.is_empty() and screen._result_lbl.text.begins_with("0 cards"), "unmatched search shows no results")
	await capture("no-results")
	await click(button("Reset"))
	button("Generics").grab_focus()
	await key(KEY_ENTER)
	check(not screen._cells.is_empty() and screen._cells.keys().all(func(id): return int(CardDatabase.get_card(id).color) == int(CardData.CardColor.GENERIC)), "generic filter changes available collection")
	await click(button("Stratagems"))
	check(not screen._cells.is_empty() and screen._cells.keys().all(func(id): return CardDatabase.get_card(id).card_type == CardData.CardType.STRATAGEM), "type filter combines with source filter")
	await click(button("Mana 2"))
	check(screen._cells.keys().all(func(id): return CardDatabase.get_card(id).cost == 2), "mana filter narrows collection")
	await click(button("Reset"))
	var legendary: CardData
	for id in screen._cells:
		if DeckManager.max_copies_for(CardDatabase.get_card(id)) == 1:
			legendary = CardDatabase.get_card(id)
			break
	await type_text(screen._search_bar, legendary.card_name)
	await click(button("Add " + legendary.card_name))
	check(screen._deck_ids.count(legendary.id) == 1 and button("Add " + legendary.card_name).disabled, "legendary copy limit is one")
	await click(button("Reset"))
	# A real canonical 39-card deck makes the capacity transition cheap to reach.
	var ids: Array[String] = []
	for c in DeckManager.build_random_faction_deck(CardData.CardColor.GREEN): ids.append(c.id)
	var missing: String = ids.pop_back()
	screen._show_editor_page(0, "UI original deck", ids)
	await settle()
	await type_text(screen._search_bar, CardDatabase.get_card(missing).card_name)
	await click(button("Add " + CardDatabase.get_card(missing).card_name))
	check(screen._deck_ids.size() == 40 and screen._count_lbl.text.contains("Ready"), "fortieth card updates readiness")
	check(screen._cells.values().all(func(cell): return cell.add.disabled), "full deck disables collection additions")
	var count_sum := 0
	for label in screen._curve_counts: count_sum += int(label.text)
	check(count_sum == 40, "all mana buckets total the deck size")
	var preview: Button = screen._cells[missing].preview
	get_tree().root.size = Vector2i(960, 640)
	await settle()
	var motion := InputEventMouseMotion.new()
	motion.position = preview.get_global_rect().get_center()
	get_viewport().push_input(motion, true)
	await settle()
	check(screen._preview_panel.visible, "hovering Preview opens inspection")
	await key(KEY_ESCAPE)
	preview.grab_focus()
	await key(KEY_ENTER)
	check(screen._preview_panel.visible, "keyboard preview works at capacity")
	check(screen.get_global_rect().encloses(screen._preview_panel.get_global_rect()), "preview stays inside viewport")
	await capture("preview")
	await key(KEY_ESCAPE)
	check(not screen._preview_panel.visible and screen._editor_page.visible, "Escape closes preview before navigating")
	await type_text(screen._name_edit, "")
	await click(screen._save_btn)
	check(not screen._status_lbl.text.is_empty() and screen._deck_ids.size() == 40, "blank-name save shows error without losing deck")
	var long_name := "x".repeat(41)
	await type_text(screen._name_edit, long_name)
	await click(screen._save_btn)
	check(screen._name_edit.text == long_name and saved(long_name).is_empty() and not screen._status_lbl.text.is_empty(), "41-character name is preserved and refused")
	await capture("name-error")
	var max_name := "x".repeat(40)
	await type_text(screen._name_edit, max_name)
	await key(KEY_S, true)
	check(saved(max_name).get("card_ids", []).size() == 40 and not screen._has_unsaved_changes(), "40-character name saves through file reload")
	await type_text(screen._name_edit, "UI copied deck")
	check(screen._save_btn.text == "Save as new deck", "rename explains name-keyed save-as")
	await click(screen._save_btn)
	check(not saved(max_name).is_empty() and saved("UI copied deck").get("card_ids", []).size() == 40, "save-as preserves original and persists copy")
	await click(button("Back"))
	check(screen._hub_page.visible, "saved deck exits without prompt")
	await capture("populated-hub")
	await click(button("Open deck UI copied deck"))
	check(screen._deck_ids.size() == 40, "hub reloads saved copy")
	await click(screen._delete_btn)
	check(saved("UI copied deck").is_empty() and not saved(max_name).is_empty(), "delete targets current copy and preserves original")
	await click(button("Open deck " + max_name))
	await click(button("Clear"))
	check(screen._deck_ids.is_empty() and screen._curve_counts.all(func(label): return label.text == "0"), "clear resets list and curve")
	await click(button("Back"))
	check(is_instance_valid(screen._prompt), "dirty Back opens prompt")
	for i in 5:
		await key(KEY_TAB)
		check(screen._prompt_buttons.has(get_viewport().gui_get_focus_owner()), "Tab remains in exit prompt")
	await capture("prompt-focus")
	await key(KEY_ESCAPE)
	check(not is_instance_valid(screen._prompt) and button("Back").has_focus(), "cancel restores previous focus and keeps edits")
	await click(button("Back"))
	await click(button("Discard and exit"))
	await click(button("Open deck " + max_name))
	check(screen._deck_ids.size() == 40, "discard leaves persisted deck unchanged")
	await click(button("Clear"))
	await click(button("Back"))
	await click(button("Save and exit"))
	check(screen._hub_page.visible and saved(max_name).get("card_ids", []).is_empty(), "save before exit persists incomplete deck")
	await click(button("Open deck " + max_name))
	await click(screen._delete_btn)
	check(saved(max_name).is_empty(), "synthetic deck cleanup uses current delete identity")
	# Historical saves can still reference Crypt Chapel, removed in 0.0.1.
	var historical_ids: Array[String] = ["cr_021", "g_001"]
	DeckManager.save_deck("UI retired card deck", 0, historical_ids)
	screen._show_hub_page()
	await settle()
	await click(button("Open deck UI retired card deck"))
	check(screen._deck_ids == historical_ids and int(screen._curve_counts[1].text) == 1, "historical save retains retired ID and renders known card curve")
	check(screen._count_lbl.text.contains("Check cards") and button("Remove one Lone Operative") != null, "historical deck explains unavailable card without hiding valid rows")
	await click(screen._save_btn)
	check(saved("UI retired card deck").card_ids == historical_ids, "saving does not silently discard retired cards")
	await capture("retired-card")
	await click(button("Remove one Unavailable card (cr_021)"))
	check(screen._deck_ids == ["g_001"], "unavailable row lets the player explicitly remove retired card")
	await click(screen._delete_btn)
	screen._show_editor_page(0, "Unicode boundary", [])
	await settle()
	var supplementary := String.chr(0x1f680)
	var rejected := supplementary.repeat(21)
	await type_text(screen._name_edit, rejected)
	await click(screen._save_btn)
	check(screen._name_edit.text == rejected and saved(rejected).is_empty() and screen._has_unsaved_changes() and not screen._status_lbl.text.is_empty(), "42 UTF-16-unit name is refused with text and dirty state preserved")
	var accepted := supplementary.repeat(20)
	await type_text(screen._name_edit, accepted)
	await click(screen._save_btn)
	check(not saved(accepted).is_empty() and not screen._has_unsaved_changes(), "40 UTF-16-unit name saves and reloads")
	await click(screen._delete_btn)
	screen._show_editor_page(0, "Preview cleanup", [])
	await settle()
	var first_cell: Dictionary = screen._cells.values()[0]
	first_cell.preview.grab_focus()
	await key(KEY_ENTER)
	screen._schedule_hide_preview()
	screen.queue_free()
	await get_tree().create_timer(0.2).timeout
	check(not is_instance_valid(screen), "closing during preview timer frees the screen")
