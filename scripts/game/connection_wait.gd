extends Node

# A pending relay connection belongs to the screen that requested it.
var _ready_signal: Signal
var _on_ready: Callable
var _on_timeout: Callable
var _timer: Timer
var _settled := false

func start(ready_signal: Signal, on_ready: Callable, on_timeout: Callable, timeout_seconds: float) -> void:
	_ready_signal = ready_signal
	_on_ready = on_ready
	_on_timeout = on_timeout
	_ready_signal.connect(_connected)
	if on_timeout.is_valid():
		_timer = Timer.new()
		_timer.one_shot = true
		add_child(_timer)
		_timer.timeout.connect(_timed_out)
		_timer.start(timeout_seconds)

func _connected() -> void:
	_finish(_on_ready)

func _timed_out() -> void:
	_finish(_on_timeout)

func _finish(callback: Callable) -> void:
	if _settled:
		return
	_cancel()
	queue_free()
	if callback.is_valid():
		callback.call()

func _cancel() -> void:
	_settled = true
	if not _ready_signal.is_null() and _ready_signal.is_connected(_connected):
		_ready_signal.disconnect(_connected)
	if is_instance_valid(_timer):
		_timer.stop()
	_on_ready = Callable()
	_on_timeout = Callable()

func _exit_tree() -> void:
	_cancel()
