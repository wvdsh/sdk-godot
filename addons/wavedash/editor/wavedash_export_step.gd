@tool
extends "wavedash_process_step.gd"

## Exports the active preset by re-invoking Godot headlessly.

const WavedashExportPresets = preload("wavedash_export_presets.gd")
const WavedashToml = preload("wavedash_toml.gd")
const WavedashGate = preload("wavedash_gate.gd")
const WavedashLog = preload("wavedash_log.gd")

## Godot colourises the task id in its progress lines, so they must be stripped
## before matching.
var _ANSI_REGEX := RegEx.create_from_string("\u001b\\[[0-9;]*m")
var _PROGRESS_REGEX := RegEx.create_from_string("^\\[\\s*(\\d+)%\\s*\\]\\s*\\S+\\s*\\|\\s*(.+)$")

func _ready() -> void:
	label = "Exporting"
	finished.connect(_report_finished)

func _report_finished(exit_code: int) -> void:
	if exit_code == 0 or was_stopped():
		return
	output_line.emit("Export failed with exit code %d." % exit_code)
	WavedashLog.error("Export failed with exit code %d." % exit_code)

func _args() -> PackedStringArray:
	return PackedStringArray([
		"--headless",
		"--path", ProjectSettings.globalize_path("res://"),
		"--export-release", WavedashExportPresets.get_active_preset(),
	])

## Both flows reach an export only through here, so this is what actually blocks a
## dev run and an upload; the dock's hidden buttons are affordances on top of it.
func _spawn() -> WavedashOSProcess:
	var gate := WavedashGate.check_can_build().detailed_description
	if gate != "":
		output_line.emit(gate)
		WavedashLog.error(gate)
		return null
	_sync_upload_dir()
	_ensure_export_dir()
	var process := WavedashOSProcess.new()
	add_child(process)
	if not process.start(OS.get_executable_path(), _args()):
		output_line.emit("Failed to launch export.")
		WavedashLog.error("Failed to launch export.")
		process.queue_free()
		return null
	return process

## Godot's exporter refuses a missing target folder rather than creating one, and the first
## export after a fresh preset always has one.
func _ensure_export_dir() -> void:
	var target := WavedashExportPresets.get_active_preset_export_path().trim_prefix("res://").get_base_dir()
	if target == "":
		return
	if not target.is_absolute_path():
		target = ProjectSettings.globalize_path("res://").path_join(target)
	if DirAccess.dir_exists_absolute(target):
		return
	var err := DirAccess.make_dir_recursive_absolute(target)
	if err != OK:
		var failure := "Couldn't create the export folder \"%s\" (%s)." % [target, error_string(err)]
		output_line.emit(failure)
		WavedashLog.error(failure)
		return
	output_line.emit("Created export folder \"%s\"." % target)

## upload_dir is derived from the preset, so a mismatch is a stale value rather than
## a preference to respect. Both commands read it -- `build push` uploads it and
## `wavedash dev` serves it -- so a stale one silently uses the previous build.
func _sync_upload_dir() -> void:
	var derived := WavedashExportPresets.derive_upload_dir()
	var toml := WavedashToml.read()
	if derived == "" or derived == toml.upload_dir:
		return
	var previous := toml.upload_dir
	toml.upload_dir = derived
	var err := toml.write()
	if err != OK:
		var failure := "Couldn't update wavedash.toml's upload_dir to \"%s\" (%s) -- Wavedash would use \"%s\" instead." % [derived, error_string(err), previous]
		output_line.emit(failure)
		WavedashLog.error(failure)
		return
	var updated := "Updated wavedash.toml upload_dir: \"%s\" -> \"%s\" (follows the active preset)." % [previous, derived]
	output_line.emit(updated)
	WavedashLog.console(updated)

## `description` is Godot's own per-step message, which is what explains a percent
## resetting: the export runs several phases that each count 0-100.
func _on_line(line: String) -> void:
	super(line)
	var stripped := _ANSI_REGEX.sub(line, "", true)
	var progress_match := _PROGRESS_REGEX.search(stripped)
	if progress_match:
		progress_changed.emit(progress_match.get_string(1).to_int(), progress_match.get_string(2).strip_edges())
