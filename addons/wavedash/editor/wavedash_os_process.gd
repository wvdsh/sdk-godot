@tool
extends Node

## Runs a command without blocking, polling from _process and emitting output line by line
## so the editor doesn't freeze.

signal output_line(text: String)
signal finished(exit_code: int)

const WavedashCompat = preload("wavedash_compat.gd")

const NO_PID := -1

var _stdio: FileAccess
var _stderr: FileAccess
var _pid: int = NO_PID
var _done: bool = false

## The path the running process was actually started from, which after a retry is
## not necessarily the one the caller first resolved.
var executable_path := ""

func start(path: String, arguments: PackedStringArray) -> bool:
	var result := WavedashCompat.os_execute_with_pipe(path, arguments, false)
	if result.is_empty():
		return false
	executable_path = path
	_stdio = result.get("stdio")
	_stderr = result.get("stderr")
	_pid = result.get("pid", NO_PID)
	set_process(true)
	return true

func get_pid() -> int:
	return _pid

func stop() -> void:
	if _pid != NO_PID and OS.is_process_running(_pid):
		OS.kill(_pid)

func _process(_delta: float) -> void:
	_drain(_stdio)
	_drain(_stderr)
	if _done or _pid == NO_PID:
		return
	if not OS.is_process_running(_pid):
		# One more drain -- output written just before exit may still be buffered.
		_drain(_stdio)
		_drain(_stderr)
		_done = true
		set_process(false)
		finished.emit(WavedashCompat.os_get_process_exit_code(_pid))

func _drain(pipe: FileAccess) -> void:
	if not pipe:
		return
	while true:
		var line := pipe.get_line()
		if line == "":
			break
		output_line.emit(line)
