@tool
extends Node

## Runs an ordered list of steps, stopping at the first failure, with the wording
## around each transition. The defined sequences live here too: they differ only in
## their steps and wording, so adding one means adding a Definition, not a class.

const WavedashProcessStep = preload("wavedash_process_step.gd")
const WavedashExportStep = preload("wavedash_export_step.gd")
const WavedashDevCommandStep = preload("wavedash_dev_command_step.gd")
const WavedashBuildPushStep = preload("wavedash_build_push_step.gd")
const WavedashLog = preload("wavedash_log.gd")

## ACTIVE is the last step running: `wavedash dev` serving, or an upload.
enum State { IDLE, EXPORTING, ACTIVE }

signal output_line(text: String)
signal state_changed(state: State)
signal progress_changed(percent: int, description: String)

class Definition:
	## Scripts, not instances: each sequence builds its own steps.
	var steps: Array[Script]
	var start_message: String
	var handoff_message: String
	## Reads in "... cancelled -- the %s was stopped". "" cancels silently.
	var cancel_message_format: String

	func _init(step_scripts: Array[Script], start: String, handoff: String, cancel_format := "") -> void:
		steps = step_scripts
		start_message = start
		handoff_message = handoff
		cancel_message_format = cancel_format

static func dev() -> Definition:
	return Definition.new(
		[WavedashExportStep, WavedashDevCommandStep],
		"Starting dev run -- exporting project...",
		"Export complete -- starting local dev server...")

static func upload() -> Definition:
	return Definition.new(
		[WavedashExportStep, WavedashBuildPushStep],
		"Starting build push -- exporting project...",
		"Export complete -- uploading build to Wavedash...",
		"Build push cancelled -- the %s was stopped.")

var _definition: Definition
var _steps: Array[WavedashProcessStep] = []
var _index := -1

## Call once, before the first start(). Steps are built here so callers can reach
## them -- the upload window sets its message and listens for its build id.
func configure(definition: Definition) -> void:
	_definition = definition
	for script in definition.steps:
		var step: WavedashProcessStep = script.new()
		_steps.append(step)
		add_child(step)
		step.output_line.connect(func(text: String) -> void: output_line.emit(text))
		step.progress_changed.connect(func(percent: int, description: String) -> void: progress_changed.emit(percent, description))
		step.finished.connect(_on_step_finished.bind(step))

## By script rather than index, so a caller isn't tied to the list's order.
func find_step(script: Script) -> WavedashProcessStep:
	for step in _steps:
		if step.get_script() == script:
			return step
	return null

func is_running() -> bool:
	return _index >= 0

## "" when nothing is running.
func current_label() -> String:
	return _steps[_index].label if is_running() else ""

## False when the first step refused to launch, which the step itself reports.
func start() -> bool:
	if is_running() or _steps.is_empty():
		return false
	_index = 0
	if not _steps[0].run():
		_index = -1
		return false
	WavedashLog.console_started(_definition.start_message)
	state_changed.emit(State.EXPORTING)
	return true

func stop() -> void:
	if not is_running():
		return
	if _definition.cancel_message_format != "":
		var cancelled := _definition.cancel_message_format % ("export" if _index == 0 else "upload")
		output_line.emit(cancelled)
		WavedashLog.console(cancelled)
	_steps[_index].stop()

## Bound to the step so a late signal from an already-abandoned one is ignored.
func _on_step_finished(exit_code: int, step: WavedashProcessStep) -> void:
	if not is_running() or _steps[_index] != step:
		return
	var next := _index + 1
	if exit_code != 0 or next >= _steps.size():
		_return_to_idle()
		return
	_index = next
	if not _steps[next].run():
		_return_to_idle()
		return
	WavedashLog.console(_definition.handoff_message)
	state_changed.emit(State.ACTIVE)

func _return_to_idle() -> void:
	_index = -1
	state_changed.emit(State.IDLE)
