@tool
extends "wavedash_cli_step.gd"

## `wavedash build push`: uploads the exported build and reports what it created.

const WavedashLog = preload("wavedash_log.gd")

signal succeeded(build_id: String, playtest_url: String)

## Set before run(); the argument list is rebuilt from it each time so it can be
## checked without launching, which would push a real build.
var message := ""

var _build_id := ""
var _playtest_url := ""

var _PROGRESS_REGEX := RegEx.create_from_string("Uploading:\\s*(\\d+)%\\s*(\\(.*\\))?")
var _BUILD_ID_REGEX := RegEx.create_from_string("^Build ID:\\s*(.+)$")
## ASCII tail only, never the CLI's leading "▶": the Windows console codepage
## mangles multi-byte UTF-8 on the way through OS output capture.
var _PLAY_AT_REGEX := RegEx.create_from_string("Play at:\\s*(.+)$")

func _ready() -> void:
	label = "Uploading"
	noun = "wavedash build push"
	finished.connect(_report_finished)

func run() -> bool:
	_build_id = ""
	_playtest_url = ""
	args = build_args()
	return super()

func build_args() -> PackedStringArray:
	var built := PackedStringArray(["build", "push", "-c", ProjectSettings.globalize_path("res://wavedash.toml")])
	if message != "":
		built.append("-m")
		built.append(message)
	return built

func _report_finished(exit_code: int) -> void:
	# The sequence already said it was cancelled; a killed process's -1 isn't a failure.
	if was_stopped():
		return
	if exit_code != 0:
		WavedashLog.error("Build push failed (exit code %d)." % exit_code)
		return
	WavedashLog.console("Build pushed successfully: %s" % _build_id)
	if _playtest_url != "":
		WavedashLog.console_link("Play at: ", _playtest_url)
	succeeded.emit(_build_id, _playtest_url)

func _on_line(line: String) -> void:
	super(line)
	var progress_match := _PROGRESS_REGEX.search(line)
	if progress_match:
		progress_changed.emit(progress_match.get_string(1).to_int(), progress_match.get_string(2).strip_edges())
	var build_id_match := _BUILD_ID_REGEX.search(line)
	if build_id_match:
		_build_id = build_id_match.get_string(1).strip_edges()
	var playtest_match := _PLAY_AT_REGEX.search(line)
	if playtest_match:
		_playtest_url = playtest_match.get_string(1).strip_edges()
