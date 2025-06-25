@tool
extends EditorPlugin

func _enter_tree():
	add_autoload_singleton("WavedashSDK", "res://addons/wavedash/WavedashSDK.gd")
	print("Wavedash: Plugin loaded")

func _exit_tree():
	remove_autoload_singleton("WavedashSDK")
	print("Wavedash: Plugin unloaded")