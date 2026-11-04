extends Node

var failures: Array[String] = []

func _ready() -> void:
	Net.set_process(false)
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)

func click(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	get_viewport().push_input(motion, true)
	await get_tree().process_frame
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		get_viewport().push_input(event, true)
		await get_tree().process_frame

func key(code: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = down
		get_viewport().push_input(event, true)
		await get_tree().process_frame

func load_definition(raw: Dictionary) -> CardData:
	var file := "user://card-inspect-fixture.json"
	var output := FileAccess.open(file, FileAccess.WRITE)
	output.store_string(JSON.stringify([raw]))
	output.close()
	CardDatabase._load_file(file)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
	return CardDatabase.get_card(raw["id"])

func _run() -> void:
	var green: Array = JSON.parse_string(FileAccess.get_file_as_string("res://data/cards/green.json"))
	green.sort_custom(func(a, b): return a["cost"] < b["cost"] if a["cost"] != b["cost"] else a["card_name"] < b["card_name"])
	var raw: Dictionary = green[0].duplicate(true)
	var original := CardDatabase.get_card(raw["id"])
	raw.erase("flavor_text")
	raw.erase("artist_name")
	var legacy := load_definition(raw)
	check(legacy.flavor_text.is_empty() and legacy.artist_name.is_empty(), "older card JSON defaults to blank metadata")
	raw["flavor_text"] = "Test lore: <stars> & stories. ".repeat(60)
	raw["artist_name"] = "Test Artist <&>"
	var definition := load_definition(raw)
	var physical := definition.new_instance("inspect-card")
	check(physical.flavor_text == raw["flavor_text"] and physical.clone_instance().artist_name == raw["artist_name"], "loaded metadata survives physical and simulation copies")
	var screen := CardListScreen.new()
	add_child(screen)
	var state := {"back": 0}
	screen.back_pressed.connect(func(): state["back"] += 1)
	await get_tree().process_frame
	await get_tree().process_frame
	var thumbnail: Button = screen.find_children("*", "Button", true, false).filter(func(button): return button.accessibility_name == "Inspect " + definition.card_name)[0]
	if OS.get_cmdline_user_args().has("--inspect-preview"):
		screen._show_inspect(definition)
		print("CARD_INSPECT_PREVIEW_READY")
		return
	await click(thumbnail.get_global_rect().get_center())
	check(screen._inspect_layer != null, "clicking a list card opens inspection")
	if screen._inspect_layer != null:
		var labels := screen._inspect_content.find_children("*", "Label", true, false)
		check(labels.any(func(label): return label.text == raw["flavor_text"]) and labels.any(func(label): return label.text == raw["artist_name"]), "both metadata boxes display the loaded text literally")
		await click(screen._inspect_card_holder.get_global_rect().get_center())
		check(screen._inspect_layer != null, "clicking the enlarged card keeps inspection open")
		# Canvas layers can map GUI coordinates differently from the list's
		# global rectangle (as in the scaled Web viewport).
		var foreground: CanvasLayer = screen._inspect_content.get_parent()
		foreground.transform = Transform2D(0, Vector2(300, 0))
		await click(screen._inspect_card_holder.get_global_transform_with_canvas() * (screen._inspect_card_holder.size * 0.5))
		check(screen._inspect_layer != null, "the card stays open through a canvas coordinate transform")
		foreground.transform = Transform2D.IDENTITY
		var previous_filter := screen._color_filter
		await key(KEY_TAB)
		check(screen._color_filter == previous_filter and not thumbnail.has_focus(), "keyboard focus stays in inspection")
		get_tree().root.size = Vector2i(960, 640)
		await get_tree().process_frame
		await get_tree().process_frame
		check(screen.get_global_rect().encloses(screen._inspect_content.get_global_rect()), "card and metadata fit a smaller viewport")
		await click(Vector2(30, 25))
		check(screen._inspect_layer == null and state["back"] == 0, "outside click closes without activating the Back button behind it")
		check(thumbnail.has_focus(), "closing restores focus to the selected thumbnail")
		thumbnail.grab_focus()
		await key(KEY_ENTER)
		check(screen._inspect_layer != null, "keyboard activation opens inspection")
		await click(screen._inspect_content.get_child(1).get_global_rect().get_center())
		check(screen._inspect_layer == null, "clicking the flavor box outside the card closes inspection")
		await key(KEY_ENTER)
		await key(KEY_ESCAPE)
		check(screen._inspect_layer == null, "Escape closes inspection")
		var blank: CardData = CardDatabase.get_all_cards().filter(func(card): return card.flavor_text.is_empty() and card.artist_name.is_empty() and not card.is_token)[0]
		screen._show_inspect(blank)
		var blank_labels := screen._inspect_content.find_children("*", "Label", true, false)
		check(blank_labels.any(func(label): return label.text == "No flavor text yet.") and blank_labels.any(func(label): return label.text == "Not credited yet."), "blank metadata has honest placeholders")
		# Removing the screen also removes its active modal and shader.
	screen.queue_free()
	await get_tree().process_frame
	CardDatabase.cards[original.id] = original
	print("CARD_INSPECT_RESULT ", JSON.stringify({"failures": failures}))
	get_tree().quit(failures.size())
