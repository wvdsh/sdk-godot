@tool
extends HBoxContainer

## "Game: <status> [Connect.../Change...]" dock row. Opens WavedashInitWindow to
## set or change the target game; never edits wavedash.toml itself.

const WavedashAuth = preload("wavedash_auth.gd")
const WavedashCli = preload("wavedash_cli.gd")
const WavedashToml = preload("wavedash_toml.gd")
const WavedashProjectApi = preload("wavedash_project_api.gd")
const WavedashDialogs = preload("wavedash_dialogs.gd")
const WavedashInitWindowScene = preload("wavedash_init_window.tscn")
const WavedashIconTheme = preload("wavedash_icon_theme.gd")
const ChangeGameIcon = preload("assets/wrench_white.svg")
const WavedashCompat = preload("wavedash_compat.gd")

signal log_line(text: String)
## Must be emitted on every refresh() path, including the early return:
## wavedash_editor.gd routes WavedashBuildUploadRow's refresh through it.
signal status_changed

## Setup here would dirty the open scene and bake session state into a shipped .tscn.
@onready var _in_edited_scene := WavedashCompat.is_part_of_edited_scene(self)

@onready var _status_label: Label = $StatusLabel
@onready var _action_button: Button = $ActionButton

func _ready() -> void:
	if _in_edited_scene:
		return
	_action_button.pressed.connect(_on_action_pressed)
	_action_button.icon = ChangeGameIcon
	WavedashIconTheme.apply_to_button(_action_button)
	refresh()

func _notification(what: int) -> void:
	if _in_edited_scene:
		return
	if what == NOTIFICATION_THEME_CHANGED and _action_button:
		WavedashIconTheme.apply_to_button(_action_button)

## Hidden without both a key and a CLI, since resolving the game name shells out
## and a failed call would report "Game not found" for a perfectly fine game.
func refresh() -> void:
	if not WavedashAuth.check_status().authenticated or not WavedashCli.is_installed():
		visible = false
		status_changed.emit()
		return
	visible = true
	var toml := WavedashToml.read()
	if not toml.exists or toml.game_id == "":
		_status_label.text = "Not connected to a game on Wavedash"
		_action_button.text = "Connect..."
		status_changed.emit()
		return
	var project := WavedashProjectApi.find_project(toml.game_id)
	if project == null:
		# Detail goes in the tooltip; the dock row has to stay narrow.
		_status_label.text = "Game not found"
		_status_label.tooltip_text = "wavedash.toml's game_id doesn't match any team/project this account can see -- it may have been deleted, or belongs to a team you're no longer a member of."
	else:
		_status_label.text = "Game: %s" % project.title
		_status_label.tooltip_text = ""
	_action_button.text = "Change..."
	status_changed.emit()

func _on_action_pressed() -> void:
	var window := WavedashInitWindowScene.instantiate()
	window.initialized.connect(refresh)
	WavedashDialogs.show_dialog(window)
