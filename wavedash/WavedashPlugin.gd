@tool
extends EditorPlugin

func _enter_tree():
	var plugin_path = get_script().resource_path.get_base_dir()
	add_autoload_singleton("WavedashSDK", plugin_path + "/WavedashSDK.gd")
	print("Wavedash: Plugin loaded")

func _exit_tree():
	remove_autoload_singleton("WavedashSDK")
	print("Wavedash: Plugin unloaded")

func _get_plugin_name():
	return "WavedashSDK"

func _get_plugin_icon():
	return EditorInterface.get_editor_theme().get_icon("Node", "EditorIcons")