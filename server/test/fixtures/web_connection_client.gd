extends "res://scripts/game/main.gd"

signal relay_ready
var _failures: Array[String] = []
var _calls := {"ready": 0, "timeout": 0}

# Override normal startup: no relay connection or real account requests.
func _ready() -> void:
	_run.call_deferred()

func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		push_error(message)

func _screen() -> Node:
	var screen := Node.new()
	add_child(screen)
	return screen

func _waiter(screen: Node, deadline: float = 0.05, with_timeout: bool = true) -> Node:
	var pending := ConnectionWaitScript.new()
	screen.add_child(pending)
	var timeout := func(): _calls.timeout += 1
	pending.start(relay_ready, func(): _calls.ready += 1, timeout if with_timeout else Callable(), deadline)
	return pending

func _run() -> void:
	_check(Net._ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, "fixture must have no live relay")
	Net.set_process(false)
	var screen := _screen()
	_waiter(screen)
	relay_ready.emit()
	screen.free()
	await get_tree().create_timer(0.12).timeout
	_check(_calls == {"ready": 1, "timeout": 0}, "success cancels its deadline after screen disposal")
	screen = _screen()
	_waiter(screen)
	await get_tree().create_timer(0.12).timeout
	relay_ready.emit()
	_check(_calls == {"ready": 1, "timeout": 1}, "timeout rejects late readiness")
	screen.free()
	screen = _screen()
	_waiter(screen)
	screen.free()
	relay_ready.emit()
	await get_tree().create_timer(0.12).timeout
	_check(_calls == {"ready": 1, "timeout": 1}, "screen exit silently cancels pending work")
	screen = _screen()
	_waiter(screen, 0.05, false)
	await get_tree().create_timer(0.12).timeout
	relay_ready.emit()
	_check(_calls.ready == 2, "retry without timeout callback still waits for readiness")
	screen.free()
	_check(relay_ready.get_connections().is_empty(), "terminal waits release their signal subscriptions")

	_canvas = CanvasLayer.new()
	add_child(_canvas)
	_canvas.add_child(Control.new()) # Wallpaper slot preserved by _clear_screen.
	Net._connected = true
	_with_connection(func(): _calls.ready += 1)
	_check(_calls.ready == 3, "already-connected path is synchronous")
	var login_baseline := Auth.login_result.get_connections().size()
	var register_baseline := Auth.register_result.get_connections().size()
	for registering in [false, true]:
		_show_auth_screen(registering, func(): _calls.ready += 1)
		var root := _canvas.get_child(1)
		var box := root.get_child(0)
		box.get_child(1).text = "fixture-user"
		box.get_child(2).text = "fixture-password"
		var status: Label = box.get_child(3)
		var submit: Button = box.get_child(4)
		submit.pressed.emit()
		var response: Signal = Auth.register_result if registering else Auth.login_result
		response.emit(false, "Synthetic auth failure")
		await get_tree().create_timer(0.5).timeout
		_check(status.text == "Synthetic auth failure" and not submit.disabled, "loading stops at auth failure")
		submit.pressed.emit()
		_clear_screen()
		await get_tree().process_frame
		response.emit(true, "Late result")
		_check(_calls.ready == 3, "late auth success cannot navigate a discarded screen")
		_check(Auth.login_result.get_connections().size() == login_baseline, "login callbacks released")
		_check(Auth.register_result.get_connections().size() == register_baseline, "register callbacks released")

	_show_reconnecting_screen(func(): _calls.ready += 1)
	_clear_screen()
	await get_tree().process_frame
	Auth.login_result.emit(true, "Late resume")
	_check(_calls.ready == 3 and Auth.login_result.get_connections().size() == login_baseline, "resume callback belongs to its screen")
	var balance_baseline := Economy.balance_changed.get_connections().size()
	var original_dust := Economy.dust
	for cycle in 3:
		var cell := _currency_cell(Control.new(), "dust")
		_canvas.add_child(cell)
		Economy.dust += 1
		Economy.balance_changed.emit()
		_check(cell.get_child(1).text == str(Economy.dust), "currency updates while screen is alive")
		_clear_screen()
		await get_tree().process_frame
		Economy.balance_changed.emit()
		_check(Economy.balance_changed.get_connections().size() == balance_baseline, "currency subscription released on screen exit")
	Economy.dust = original_dust
	# Cross the reported eight-second window, including pending animation timers.
	await get_tree().create_timer(8.5).timeout
	print("WEB_CONNECTION_RESULT ", JSON.stringify({"failures": _failures, "calls": _calls}))
	Net._connected = false
	get_tree().quit(_failures.size())
