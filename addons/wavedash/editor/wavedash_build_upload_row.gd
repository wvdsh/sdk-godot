@tool
extends VBoxContainer

## "[Push Build...]" dock section. Both the button's enabled state and the reason under it
## come from WavedashGate, the same check the export step enforces, so it can't offer a
## refused action.

const WavedashGate = preload("wavedash_gate.gd")
const WavedashBuildUploadWindowScene = preload("wavedash_build_upload_window.tscn")
const WavedashIconTheme = preload("wavedash_icon_theme.gd")
const WavedashDialogs = preload("wavedash_dialogs.gd")
const WavedashCompat = preload("wavedash_compat.gd")

signal log_line(text: String)

## Setup here would dirty the open scene and bake session state into a shipped .tscn.
@onready var _in_edited_scene := WavedashCompat.is_part_of_edited_scene(self)

@onready var _action_button: Button = $ActionButton
@onready var _status_label: Label = $StatusLabel

func _ready() -> void:
	if _in_edited_scene:
		return
	_action_button.pressed.connect(_on_action_pressed)
	WavedashIconTheme.apply_to_button(_action_button)
	_apply_status_color()
	refresh()

func _notification(what: int) -> void:
	if _in_edited_scene:
		return
	if what == NOTIFICATION_THEME_CHANGED and _action_button:
		WavedashIconTheme.apply_to_button(_action_button)
		_apply_status_color()

## The editor's own error colour, so this reads as an error in either theme.
func _apply_status_color() -> void:
	_status_label.add_theme_color_override("font_color", get_theme_color("error_color", "Editor"))

## Re-run by every row that owns part of the answer -- see wavedash_editor.gd.
func refresh() -> void:
	var blocker := WavedashGate.check_can_build().summary_description
	_action_button.disabled = blocker != ""
	_status_label.visible = blocker != ""
	_status_label.text = blocker

func _on_action_pressed() -> void:
	var window := WavedashBuildUploadWindowScene.instantiate()
	window.log_line.connect(func(text: String) -> void: log_line.emit(text))
	WavedashDialogs.show_dialog(window)
