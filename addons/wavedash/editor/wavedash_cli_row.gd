@tool
extends HBoxContainer

## Hidden by default; appears only to prompt for an install or an update.

const WavedashCli = preload("wavedash_cli.gd")
const WavedashCliRunner = preload("wavedash_cli_runner.gd")
const WavedashOSProcess = preload("wavedash_os_process.gd")
const WavedashDialogs = preload("wavedash_dialogs.gd")
const WavedashCompat = preload("wavedash_compat.gd")

const RELEASES_URL := "https://api.github.com/repos/wvdsh/cli/releases/latest"
const INSTALL_DIALOG_TITLE := "Install Wavedash CLI"
const LAUNCH_FAILED_EXIT_CODE := -1

signal log_line(text: String)
## Whenever CLI-installed-ness might have changed. Not fired for update state,
## which doesn't affect it.
signal status_changed

@onready var _status_label: Label = $StatusLabel
@onready var _action_button: Button = $ActionButton
@onready var _update_button: Button = $UpdateButton

## Shared by install and update; they never run concurrently.
var _process: WavedashOSProcess

func _ready() -> void:
	# Setup here would dirty the open scene and bake session state into a shipped .tscn.
	if WavedashCompat.is_part_of_edited_scene(self):
		return
	visible = false
	_action_button.pressed.connect(_on_action_pressed)
	_update_button.pressed.connect(_on_update_pressed)
	if WavedashCli.is_installed():
		_check_for_update_async()
	else:
		_show_not_installed()

func _exit_tree() -> void:
	if _process:
		_process.stop()

func _show_not_installed() -> void:
	visible = true
	_status_label.text = "Could not find Wavedash CLI"
	_action_button.text = "Install"
	_action_button.visible = true
	_update_button.visible = false
	status_changed.emit()

## Rechecks, then installs only if still missing -- one click for one question.
func _on_action_pressed() -> void:
	if not _recheck_and_hide_if_installed():
		_open_install_dialog()

func _recheck_and_hide_if_installed() -> bool:
	if WavedashCli.recheck_installation() == "":
		return false
	visible = false
	status_changed.emit()
	_check_for_update_async()
	return true

func _open_install_dialog() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = INSTALL_DIALOG_TITLE
	dialog.dialog_text = "The Wavedash CLI is needed for certain functions of the Wavedash Plugin.\n\nInstalling will run the following command:\n\n%s\n\nContinue?" % WavedashCli.get_install_command_display_string()
	dialog.get_ok_button().text = "Install Now"
	dialog.add_button("Open Installation Docs Instead", false, "open_docs")
	dialog.custom_action.connect(func(action: StringName) -> void:
		if action == "open_docs":
			OS.shell_open("https://docs.wavedash.com/cli/installation")
			dialog.hide()
	)
	dialog.confirmed.connect(_run_install)
	WavedashDialogs.show_dialog(dialog)

func _run_install() -> void:
	if _process:
		return
	_set_buttons_disabled(true)
	_status_label.text = "Installing..."
	log_line.emit("$ %s" % WavedashCli.get_install_command_display_string())
	var cmd := WavedashCli.get_install_shell_command()
	_process = WavedashOSProcess.new()
	add_child(_process)
	_process.output_line.connect(func(text: String) -> void: log_line.emit(text))
	_process.finished.connect(_on_install_finished)
	if not _process.start(cmd.path, cmd.arguments):
		log_line.emit("Failed to launch installer.")
		_on_install_finished(LAUNCH_FAILED_EXIT_CODE)

func _on_install_finished(exit_code: int) -> void:
	log_line.emit("Installer exited with code %d." % exit_code)
	_cleanup_process()
	if not _recheck_and_hide_if_installed():
		log_line.emit("Still not found after install -- you may need to restart the editor for PATH changes to take effect.")
		_show_not_installed()

## Once per editor session -- unauthenticated GitHub calls share a 60/hour/IP
## budget. Set only on success, so being offline doesn't burn the attempt.
const UPDATE_CHECKED_KEY := "cli_update_checked"

## Checks the releases endpoint directly rather than running `wavedash update`,
## which has no dry-run flag and would install whatever it found.
func _check_for_update_async() -> void:
	if WavedashCompat.session_get(UPDATE_CHECKED_KEY, false):
		return
	var exe := WavedashCli.resolve_executable()
	var current := _parse_version_number(WavedashCli.get_version_string(exe))
	if current == "":
		return
	var request := HTTPRequest.new()
	add_child(request)
	request.request_completed.connect(_on_release_check_completed.bind(request, current))
	# request() returns ERR_UNCONFIGURED if called in the same step as
	# add_child(). Deferred rather than awaited: a @tool script suspended
	# mid-coroutine doesn't survive this same file being saved.
	_fire_request.call_deferred(request)

func _fire_request(request: HTTPRequest) -> void:
	if request.request(RELEASES_URL) != OK:
		request.queue_free()

func _on_release_check_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, request: HTTPRequest, current: String) -> void:
	request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != HTTPClient.RESPONSE_OK:
		return
	WavedashCompat.session_set(UPDATE_CHECKED_KEY, true)
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary) or not parsed.has("tag_name"):
		return
	var latest: String = parsed["tag_name"]
	if _is_version_newer(latest, current):
		_show_update_prompt(current, latest)

func _show_update_prompt(current: String, latest: String) -> void:
	visible = true
	_status_label.text = "CLI update available: %s (currently: %s)" % [latest, current]
	_action_button.visible = false
	_update_button.text = "Update Now"
	_update_button.visible = true

## Not the last token: "wavedash 0.1.90 (abc123)" would yield "(abc123)".
static func _version_token() -> RegEx:
	return RegEx.create_from_string("\\d+(\\.\\d+)+")

func _parse_version_number(version_string: String) -> String:
	var found := _version_token().search(version_string)
	return found.get_string() if found else ""

## Numeric-tuple comparison, not full semver. Tolerates a "v" prefix because
## "v1".to_int() is 0, which would make v1.0.1 compare as older than 1.0.0.
func _is_version_newer(candidate: String, baseline: String) -> bool:
	var candidate_parts := _version_parts(candidate)
	var baseline_parts := _version_parts(baseline)
	for i in maxi(candidate_parts.size(), baseline_parts.size()):
		var candidate_part: int = candidate_parts[i] if i < candidate_parts.size() else 0
		var baseline_part: int = baseline_parts[i] if i < baseline_parts.size() else 0
		if candidate_part != baseline_part:
			return candidate_part > baseline_part
	return false

func _version_parts(version: String) -> Array[int]:
	var parts: Array[int] = []
	for part in version.strip_edges().trim_prefix("v").split("."):
		parts.append(part.to_int())
	return parts

func _on_update_pressed() -> void:
	if _process:
		return
	if not WavedashCli.is_installed():
		return
	_set_buttons_disabled(true)
	_status_label.text = "Updating..."
	_process = WavedashCliRunner.start_streaming(self, ["update"])
	if _process == null:
		log_line.emit("Failed to launch update.")
		_on_update_finished(LAUNCH_FAILED_EXIT_CODE)
		return
	log_line.emit("$ %s update" % _process.executable_path)
	_process.output_line.connect(func(text: String) -> void: log_line.emit(text))
	_process.finished.connect(_on_update_finished)

func _on_update_finished(exit_code: int) -> void:
	log_line.emit("Update exited with code %d." % exit_code)
	_cleanup_process()
	WavedashCli.recheck_installation()
	visible = false

func _cleanup_process() -> void:
	if is_instance_valid(_process):
		_process.queue_free()
	_process = null
	_set_buttons_disabled(false)

func _set_buttons_disabled(disabled: bool) -> void:
	_action_button.disabled = disabled
	_update_button.disabled = disabled
