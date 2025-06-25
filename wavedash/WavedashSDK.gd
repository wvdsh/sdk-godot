extends Node

# We expect window.WavedashJS to be available on the page
var WavedashJS:JavaScriptObject

# Handle events broadcasted from JS to Godot
# JS -> GD
var _js_callback_receiver:JavaScriptObject

# Handle results when Godot calls async JS functions
# GD -> JS (async) -> GD
var _on_lobby_joined_js:JavaScriptObject
var _on_lobby_created_js:JavaScriptObject

# Signals that Godot developers can connect to
signal lobby_joined(payload)
signal lobby_created(payload)
signal lobby_message(payload)
signal lobby_left(payload)

func _ready():
	if OS.get_name() == "Web":
		WavedashJS = JavaScriptBridge.get_interface("WavedashJS")
		if not WavedashJS:
			print("WavedashSDK: WavedashJS not found on window")
			return
		_on_lobby_joined_js = JavaScriptBridge.create_callback(_on_lobby_joined_gd)
		_on_lobby_created_js = JavaScriptBridge.create_callback(_on_lobby_created_gd)
		_js_callback_receiver = JavaScriptBridge.create_callback(_dispatch_js_event)
		var engine = JavaScriptBridge.create_object("Object")
		engine["type"] = "Godot"
		engine["SendMessage"] = _js_callback_receiver
		WavedashJS.setEngineInstance(engine)

func init(config: Dictionary):
	if OS.get_name() == "Web" and WavedashJS:
		WavedashJS.init(JSON.stringify(config))

func get_user():
	if OS.get_name() == "Web" and WavedashJS:
		return JSON.parse_string(WavedashJS.getUser())
	return null

func join_lobby(lobby_id: String):
	if OS.get_name() == "Web" and WavedashJS:
		WavedashJS.joinLobby(lobby_id).then(_on_lobby_joined_js)
		return true
	return false

func sendLobbyChatMsg(lobby_id: String, message: String):
	if OS.get_name() == "Web" and WavedashJS:
		# Fire and forget
		WavedashJS.sendLobbyChatMsg(lobby_id, message)
		return true
	return false

# Handle callbacks triggered by Promises resolving
func _on_lobby_joined_gd(args):
	var lobby_json = args[0] if args.size() > 0 else null
	var lobby_data = JSON.parse_string(lobby_json) if lobby_json else {}
	lobby_joined.emit(lobby_data)

func _on_lobby_created_gd(args):
	var lobby_json = args[0] if args.size() > 0 else null
	var lobby_data = JSON.parse_string(lobby_json) if lobby_json else {}
	lobby_created.emit(lobby_data)

# Handle events broadcasted from JS to Godot
func _dispatch_js_event(args):
	var game_object_name = args[0]  # Unused in Godot. Needed for Unity
	var method_name = args[1]
	var payload = args[2]
	match method_name:
		"LobbyMessage":
			var data = JSON.parse_string(payload)
			lobby_message.emit(data)
		_:
			push_warning("[WavedashSDK] Received unknown event from JS: " + method_name)
