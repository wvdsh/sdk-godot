@tool
extends EditorPlugin

func _enter_tree():
	var plugin_path = get_script().resource_path.get_base_dir()
	var sdk_path = plugin_path + "/WavedashSDK.gd"
	add_autoload_singleton("WavedashSDK", sdk_path)

func _exit_tree():
	remove_autoload_singleton("WavedashSDK")

func _get_plugin_name():
	return "WavedashSDK"

func _get_plugin_icon():
	return EditorInterface.get_editor_theme().get_icon("Node", "EditorIcons")
