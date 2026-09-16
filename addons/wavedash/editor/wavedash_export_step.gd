@tool
extends "wavedash_process_step.gd"

const WavedashExportPresets = preload("wavedash_export_presets.gd")
const WavedashToml = preload("wavedash_toml.gd")
const WavedashGate = preload("wavedash_gate.gd")
const WavedashLog = preload("wavedash_log.gd")
const WavedashGdextensions = preload("wavedash_gdextensions.gd")
const WavedashCompat = preload("wavedash_compat.gd")

const GDEXTENSION_CHECK_DONE_KEY := "gdextension_check_done"

const LIBRARY_LOCKED_NOTE := "The editor holds that extension's library open, so the export process couldn't copy it. The export doesn't need the library and the build is unaffected."

const EXTENSIONS_OFF_WARNING := "Preset '%s' has Extensions Support off, so these Web GDExtensions won't load in the browser. Enable it in Export Presets: %s"

## Godot colourises the task id in its progress lines, so they're stripped before matching.
var _ANSI_REGEX := RegEx.create_from_string("\u001b\\[[0-9;]*m")
var _PROGRESS_REGEX := RegEx.create_from_string("^\\[\\s*(\\d+)%\\s*\\]\\s*\\S+\\s*\\|\\s*(.+)$")

func _ready() -> void:
	label = "Exporting"
	finished.connect(_report_finished)

func _report_finished(exit_code: int) -> void:
	if exit_code == 0 or was_stopped():
		return
	_fail("Export failed with exit code %d." % exit_code)

func _args() -> PackedStringArray:
	return PackedStringArray([
		"--headless",
		"--path", ProjectSettings.globalize_path("res://"),
		"--export-release", WavedashExportPresets.get_active_preset(),
	])

func _spawn() -> WavedashOSProcess:
	var gate := WavedashGate.check_can_build().detailed_description
	if gate != "":
		_fail(gate)
		return null
	_sync_upload_dir()
	_warn_about_gdextensions()
	var process := WavedashOSProcess.new()
	add_child(process)
	if not process.start(OS.get_executable_path(), _args()):
		_fail("Failed to launch export.")
		process.queue_free()
		return null
	return process

func _warn_about_gdextensions() -> void:
	if WavedashCompat.session_get(GDEXTENSION_CHECK_DONE_KEY, false):
		return
	WavedashCompat.session_set(GDEXTENSION_CHECK_DONE_KEY, true)
	var warnings: Array[String] = []
	var web := WavedashGdextensions.with_web_build()
	if not web.is_empty() and not WavedashExportPresets.get_active_preset_option("variant/extensions_support", false):
		warnings.append(EXTENSIONS_OFF_WARNING % [WavedashExportPresets.get_active_preset(), ", ".join(web)])
	var threaded: bool = WavedashExportPresets.get_active_preset_option("variant/thread_support", false)
	for warning in [WavedashGdextensions.no_web_build_warning(), WavedashGdextensions.no_matching_library_warning(threaded)]:
		if warning != "":
			warnings.append(warning)
	for text in warnings:
		output_line.emit(text)
		WavedashLog.warning(text)

func _fail(text: String) -> void:
	output_line.emit(text)
	WavedashLog.error(text)

## Both CLI commands read upload_dir, so a stale value silently uses the previous build.
func _sync_upload_dir() -> void:
	var derived := WavedashExportPresets.derive_upload_dir()
	var toml := WavedashToml.read()
	if derived == "" or derived == toml.upload_dir:
		return
	var previous := toml.upload_dir
	toml.upload_dir = derived
	var err := toml.write()
	if err != OK:
		_fail("Couldn't update wavedash.toml's upload_dir to \"%s\" (%s) -- Wavedash would use \"%s\" instead." % [derived, error_string(err), previous])
		return
	var updated := "Updated wavedash.toml upload_dir: \"%s\" -> \"%s\" (follows the active preset)." % [previous, derived]
	output_line.emit(updated)
	WavedashLog.console(updated)

## `description` is Godot's per-phase message; the export runs several phases that each count 0-100.
func _on_line(line: String) -> void:
	super(line)
	var stripped := _ANSI_REGEX.sub(line, "", true)
	var progress_match := _PROGRESS_REGEX.search(stripped)
	if progress_match:
		progress_changed.emit(progress_match.get_string(1).to_int(), progress_match.get_string(2).strip_edges())
	if line.contains("Error copying library"):
		output_line.emit(LIBRARY_LOCKED_NOTE)
