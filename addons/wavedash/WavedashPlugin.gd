@tool
extends EditorPlugin

const WavedashEditorScene = preload("editor/wavedash_editor.tscn")
const WavedashDevButtonScene = preload("editor/wavedash_dev_button.tscn")
const WavedashCompat = preload("editor/wavedash_compat.gd")

const SDK_AUTOLOAD_NAME := "WavedashSDK"
const SDK_AUTOLOAD_SETTING := "autoload/WavedashSDK"

var _dock: Control
var _dev_button: Button

func _enter_tree() -> void:
	var plugin_path: String = get_script().resource_path.get_base_dir()
	var sdk_path: String = plugin_path + "/WavedashSDK.gd"
	# add_autoload_singleton() writes ProjectSettings unconditionally, marking the project modified on every launch.
	if _resolved_autoload_path() != sdk_path:
		add_autoload_singleton(SDK_AUTOLOAD_NAME, sdk_path)

	if not WavedashCompat.supports_dock():
		push_warning("Wavedash dock needs Godot %s or newer, this is %s. The SDK autoload still works." % [
			WavedashCompat.dock_min_version_string(), Engine.get_version_info().string])
		return

	_dock = WavedashEditorScene.instantiate()
	_dock.name = "Wavedash"
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)

	_dev_button = WavedashDevButtonScene.instantiate()
	_dev_button.log_line.connect(_dock.append_log)
	_dock.gate_changed.connect(_dev_button.refresh_tooltip)
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, _dev_button)
	_move_dev_button_next_to_run_bar()

## Godot stores the entry as "*uid://..." when the Project Settings UI wrote it and "*res://..." when a plugin did.
func _resolved_autoload_path() -> String:
	if not ProjectSettings.has_setting(SDK_AUTOLOAD_SETTING):
		return ""
	var target := str(ProjectSettings.get_setting(SDK_AUTOLOAD_SETTING)).trim_prefix("*")
	if not target.begins_with("uid://"):
		return target
	var id := ResourceUID.text_to_id(target)
	return ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""

## CONTAINER_TOOLBAR appends to the far end of the title bar, with no API to place a control elsewhere.
func _move_dev_button_next_to_run_bar() -> void:
	var toolbar := _dev_button.get_parent()
	for i in toolbar.get_child_count():
		if toolbar.get_child(i).get_class() == "EditorRunBar":
			toolbar.move_child(_dev_button, i)
			return

func _exit_tree() -> void:
	remove_autoload_singleton("WavedashSDK")
	if _dev_button:
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, _dev_button)
		_dev_button.queue_free()
		_dev_button = null
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null

func _get_plugin_name() -> String:
	return "WavedashSDK"
