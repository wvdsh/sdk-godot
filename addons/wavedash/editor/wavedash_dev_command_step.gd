@tool
extends "wavedash_cli_step.gd"

## `wavedash dev`: serves the exported build locally until stopped.

const WavedashLog = preload("wavedash_log.gd")

## The CLI prints "wavedash dev → http://localhost:<port>". Matched on the ASCII
## URL, never the arrow, which the Windows console codepage mangles. Under
## --verbose other lines repeat the same base URL, so first match wins.
var _DEV_URL_REGEX := RegEx.create_from_string("http://localhost:\\d+")
var _url_logged := false

func _ready() -> void:
	label = "Serving"
	noun = "wavedash dev"
	args = PackedStringArray(["dev", "-c", _config_path(), "--verbose"])
	finished.connect(_report_finished)

func run() -> bool:
	_url_logged = false
	return super()

func _config_path() -> String:
	return ProjectSettings.globalize_path("res://wavedash.toml")

## Stopping it yourself is the normal way this ends, whether the CLI exits 0 or gets
## killed mid-serve, so neither is an error.
func _report_finished(exit_code: int) -> void:
	if exit_code == 0 or was_stopped():
		WavedashLog.console("Local dev server stopped.")
	else:
		WavedashLog.error("Local dev server exited with code %d." % exit_code)

func _on_line(line: String) -> void:
	super(line)
	if _url_logged:
		return
	var url_match := _DEV_URL_REGEX.search(line)
	if url_match:
		_url_logged = true
		WavedashLog.console_link("Dev server running at ", url_match.get_string())
