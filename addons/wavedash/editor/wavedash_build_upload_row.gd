@tool
extends VBoxContainer

const WavedashGate = preload("wavedash_gate.gd")
const WavedashBuildUploadWindowScene = preload("wavedash_build_upload_window.tscn")
const WavedashIconTheme = preload("wavedash_icon_theme.gd")
const WavedashDialogs = preload("wavedash_dialogs.gd")
const WavedashCompat = preload("wavedash_compat.gd")

signal log_line(text: String)

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

func _apply_status_color() -> void:
	_status_label.add_theme_color_override("font_color", get_theme_color("error_color", "Editor"))

func refresh() -> void:
	var blocker := WavedashGate.check_can_build().summary_description
	_action_button.disabled = blocker != ""
	_status_label.visible = blocker != ""
	_status_label.text = blocker

func _on_action_pressed() -> void:
	var window := WavedashBuildUploadWindowScene.instantiate()
	window.log_line.connect(func(text: String) -> void: log_line.emit(text))
	WavedashDialogs.show_dialog(window)
