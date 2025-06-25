extends Node

# We expect window.WavedashJS to be available on the page
var WavedashJS:JavaScriptObject

# Handle events broadcasted from JS to Godot
# JS -> GD
var js_callback_receiver:JavaScriptObject

# Handle results when Godot calls async JS functions
# GD -> JS (async) -> GD
var on_lobby_joined_js:JavaScriptObject

# Signals that Godot developers can connect to
signal lobby_joined(payload)
signal lobby_message(payload)

func _ready():
	if OS.get_name() == "Web":
		WavedashJS = JavaScriptBridge.get_interface("WavedashJS")
		if not WavedashJS:
			print("WavedashSDK: WavedashJS not found on window")
			return
		on_lobby_joined_js = JavaScriptBridge.create_callback(on_lobby_joined_gd)
		js_callback_receiver = JavaScriptBridge.create_callback(dispatch_js_event)
		var engine = JavaScriptBridge.create_object()
		engine["type"] = "Godot"
		engine["sendMessage"] = js_callback_receiver
		WavedashJS.setEngineInstance(engine)



# Handle events broadcasted from JS to Godot
func dispatch_js_event(args):
	var game_object_name = args[0]  # Unused in Godot. Needed for Unity
	var method_name = args[1] as String
	var payload = args[2] as String
	match method_name:
		"OnLobbyMessage":
			var data = JSON.parse_string(payload)
			lobby_message.emit(data)
		_:
			push_warning("[WavedashSDK] Received unknown event from JS: " + method_name)


func init(config: Dictionary):
	if OS.get_name() == "Web" and WavedashJS:
		WavedashJS.init(JSON.stringify(config))

func get_user():
	if OS.get_name() == "Web" and WavedashJS:
		return JSON.parse_string(WavedashJS.getUser())
	return null

func join_lobby(lobby_id: String):
	if OS.get_name() == "Web" and WavedashJS:
		WavedashJS.joinLobby(lobby_id).then(on_lobby_joined_js)

func on_lobby_joined_gd(args):
	var lobby_json = args[0] if args.size() > 0 else null
	var lobby_data = JSON.parse_string(lobby_json) if lobby_json else {}
	lobby_joined.emit(lobby_data)
