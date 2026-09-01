@tool
extends Node

## One process, run to completion. Subclasses decide what to spawn and how to read
## its output; everything about owning and stopping it lives here.

const WavedashOSProcess = preload("wavedash_os_process.gd")

signal output_line(text: String)
signal finished(exit_code: int)
signal progress_changed(percent: int, description: String)

## Lets a caller show the current phase without hardcoding which step is which.
var label := ""

var _process: WavedashOSProcess
var _was_stopped := false

func _exit_tree() -> void:
	stop()

func is_running() -> bool:
	return _process != null

## True when the run ended because stop() was called. A killed process reports exit
## code -1, which is otherwise indistinguishable from the command failing, so
## subclasses check this before calling anything an error.
func was_stopped() -> bool:
	return _was_stopped

## False when the process never started, in which case `finished` does not fire.
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

## Started and parented, or null. Subclasses spawn however their binary requires.
func _spawn() -> WavedashOSProcess:
	push_error("%s must override _spawn()" % get_script().resource_path.get_file())
	return null

## Only for the echoed command line; the args themselves are the subclass's business.
func _args() -> PackedStringArray:
	return PackedStringArray()

## Forwards every line unchanged. Subclasses call super() then add their parsing.
func _on_line(line: String) -> void:
	output_line.emit(line)
