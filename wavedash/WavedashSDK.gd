extends Node

const Constants = preload("WavedashConstants.gd")

# Static instance for singleton-like access
static var _instance : Node = null

# We expect window.WavedashJS to be available on the page
var WavedashJS : JavaScriptObject

# Cache what we can so the next call doesn't have to wait for JS
var user_id : int = 0
var username : String = ""
# Leaderboard name -> leaderboard data (id, num_entries)
var leaderboard_cache : Dictionary = {}
var leaderboard_handles : Dictionary = {}

# Handle events broadcasted from JS to Godot
# JS -> GD
var _js_callback_receiver : JavaScriptObject

# Handle results when Godot calls async JS functions
# GD -> JS (async) -> GD
var _on_lobby_joined_js : JavaScriptObject
var _on_lobby_created_js : JavaScriptObject
var _on_get_leaderboard_result_js : JavaScriptObject
var _on_post_leaderboard_score_result_js : JavaScriptObject

# Signals that Godot developers can connect to
signal lobby_joined(payload)
signal lobby_created(payload)
signal lobby_message(payload)
signal lobby_left(payload)
signal get_leaderboard_result(payload)
signal post_leaderboard_score_result(payload)

func _ready():
	# Register this instance as the singleton
	_instance = self
	print("WavedashSDK._ready() called, platform: ", OS.get_name())
	if OS.get_name() == Constants.PLATFORM_WEB:
		WavedashJS = JavaScriptBridge.get_interface("WavedashJS")
		if not WavedashJS:
			print("WavedashSDK: WavedashJS not found on window")
			return
		_on_lobby_joined_js = JavaScriptBridge.create_callback(_on_lobby_joined_gd)
		_on_lobby_created_js = JavaScriptBridge.create_callback(_on_lobby_created_gd)
		_on_get_leaderboard_result_js = JavaScriptBridge.create_callback(_on_get_leaderboard_result_gd)
		_on_post_leaderboard_score_result_js = JavaScriptBridge.create_callback(_on_post_leaderboard_score_result_gd)
		_js_callback_receiver = JavaScriptBridge.create_callback(_dispatch_js_event)
		var engine = JavaScriptBridge.create_object("Object")
		engine["type"] = "Godot"
		engine["SendMessage"] = _js_callback_receiver
		WavedashJS.setEngineInstance(engine)

func init(config: Dictionary):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		print("WavedashSDK: Initializing with config: ", config)
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

func get_leaderboard(leaderboard_name: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.getLeaderboard(leaderboard_name).then(_on_get_leaderboard_result_js)

func get_or_create_leaderboard(leaderboard_name: String, sort_method: int, display_type: int):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.getOrCreateLeaderboard(leaderboard_name, sort_method, display_type).then(_on_get_leaderboard_result_js)

func post_leaderboard_score(leaderboard_id: String, keep_best: bool, score: int, metadata: PackedByteArray):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.postLeaderboardScore(leaderboard_id, keep_best, score, metadata).then(_on_post_leaderboard_score_result_js)

func create_lobby(lobby_type: int, max_players = null):
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

func _on_get_leaderboard_result_gd(args):
	var leaderboard_json = args[0] if args.size() > 0 else null
	var leaderboard_data = JSON.parse_string(leaderboard_json) if leaderboard_json else {}
	if leaderboard_data.has("id"):
		leaderboard_cache[leaderboard_data["name"]] = leaderboard_data
		leaderboard_handles[leaderboard_data["name"]] = leaderboard_data["id"]
		leaderboard_data["success"] = true
		get_leaderboard_result.emit(leaderboard_data)
	else:
		get_leaderboard_result.emit({"success":false, "name":leaderboard_data["name"]})

func _on_post_leaderboard_score_result_gd(args):
	var leaderboard_json = args[0] if args.size() > 0 else null
	var leaderboard_data = JSON.parse_string(leaderboard_json) if leaderboard_json else {}
	if leaderboard_data.has("success"):
		post_leaderboard_score_result.emit(leaderboard_data)
	else:
		post_leaderboard_score_result.emit({"success":false, "name":leaderboard_data["name"]})

# Handle events broadcasted from JS to Godot
func _dispatch_js_event(args):
	var _game_object_name = args[0]  # Unused in Godot. Needed for Unity
	var method_name = args[1]
	var payload = args[2]
	match method_name:
		Constants.JS_EVENT_LOBBY_MESSAGE:
			var data = JSON.parse_string(payload)
			lobby_message.emit(data)
		_:
			push_warning("[WavedashSDK] Received unknown event from JS: " + method_name)

# Static method to get the singleton instance
func get_singleton() -> Node:
	return _instance

# Static method to check if singleton exists
func has_singleton() -> bool:
	return _instance != null

func _exit_tree():
	# Clear the static instance when node is freed
	if _instance == self:
		_instance = null
