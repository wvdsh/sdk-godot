@tool
extends Node

const WavedashOSProcess = preload("wavedash_os_process.gd")

signal output_line(text: String)
signal finished(exit_code: int)
signal progress_changed(percent: int, description: String)

var label := ""

var _process: WavedashOSProcess
var _was_stopped := false

func _exit_tree() -> void:
	stop()

func is_running() -> bool:
	return _process != null

## A killed process reports exit code -1, otherwise indistinguishable from the command failing.
func was_stopped() -> bool:
	return _was_stopped

func run() -> bool:
	if is_running():
		return false
	_was_stopped = false
	var process := _spawn()
	if process == null:
		return false
	output_line.emit("$ %s %s" % [process.executable_path, " ".join(_args())])
	process.output_line.connect(_on_line)
	process.finished.connect(func(code: int) -> void:
		process.queue_free()
		if _process == process:
			_process = null
		finished.emit(code)
	)
	_process = process
	return true

func stop() -> void:
	if _process:
		_was_stopped = true
		_process.stop()

func _spawn() -> WavedashOSProcess:
	push_error("%s must override _spawn()" % get_script().resource_path.get_file())
	return null

func _args() -> PackedStringArray:
	return PackedStringArray()

func _on_line(line: String) -> void:
	output_line.emit(line)
