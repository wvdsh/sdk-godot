extends Node

const Constants = preload("WavedashConstants.gd")

# We expect window.WavedashJS to be available on the page
var WavedashJS : JavaScriptObject

# Cache what we can so the next call doesn't have to wait for JS
var user_id : int = 0
var username : String = ""

# Handle events broadcasted from JS to Godot
# JS -> GD
var _js_callback_receiver : JavaScriptObject

# Handle results when Godot calls async JS functions
# GD -> JS (async) -> GD
var _on_lobby_joined_js : JavaScriptObject
var _on_lobby_created_js : JavaScriptObject

# Signals that Godot developers can connect to
signal lobby_joined(payload)
signal lobby_created(payload)
signal lobby_message(payload)
signal lobby_left(payload)

func _ready():
	if OS.get_name() == Constants.PLATFORM_WEB:
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
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.init(JSON.stringify(config))

func get_user_id() -> int:
	if user_id != 0:
		return user_id
		
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		var user_data = JSON.parse_string(WavedashJS.getUser())
		user_id = user_data["id"]
		username = user_data["username"]
		return user_id
	
	return 0
	
func get_username() -> String:
	if username != "":
		return username
		
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		var user_data = JSON.parse_string(WavedashJS.getUser())
		username = user_data["username"]
		return username
	
	return ""

func create_lobby(lobby_type: String, max_players = null):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.createLobby(lobby_type, max_players).then(_on_lobby_created_js)

func join_lobby(lobby_id: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.joinLobby(lobby_id).then(_on_lobby_joined_js)
		return true
	return false

func sendLobbyChatMsg(lobby_id: String, message: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		# Fire and forget
		WavedashJS.sendLobbyMessage(lobby_id, message)
		return true
	return false

# Handle callbacks triggered by Promises resolving
func _on_lobby_joined_gd(args):
	var lobby_json = args[0] if args.size() > 0 else null
	var lobby_data = JSON.parse_string(lobby_json) if lobby_json else {}
	lobby_joined.emit(lobby_data)

func _on_lobby_created_gd(args):
	var lobby_id = args[0]
	lobby_created.emit(lobby_id)

# Handle events broadcasted from JS to Godot
func _dispatch_js_event(args):
	var _game_object_name = args[0]  # Unused in Godot. Needed for Unity
	var method_name = args[1]
	var payload = args[2]
	match method_name:
		Constants.EVENT_LOBBY_MESSAGE:
			var data = JSON.parse_string(payload)
			lobby_message.emit(data)
		_:
			push_warning("[WavedashSDK] Received unknown event from JS: " + method_name)
