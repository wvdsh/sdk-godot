# Since this is an autoload, it's already a singleton
# Access it directly via the global WavedashSDK variable
extends Node

const Constants = preload("WavedashConstants.gd")

# We expect window.WavedashJS to be available on the page
var WavedashJS : JavaScriptObject

# Cache what we can so the next call doesn't have to wait for JS
var user_id : String = ""
var username : String = ""
var isReady: bool = false

# Handle events broadcasted from JS to Godot
# JS -> GD
var _js_callback_receiver : JavaScriptObject

# Handle results when Godot calls async JS functions
# GD -> JS (async) -> GD
var _on_lobby_joined_js : JavaScriptObject
var _on_lobby_created_js : JavaScriptObject
var _on_get_leaderboard_result_js : JavaScriptObject
var _on_post_leaderboard_score_result_js : JavaScriptObject
var _on_get_leaderboard_entries_result_js : JavaScriptObject
var _on_create_ugc_item_result_js : JavaScriptObject
var _on_update_ugc_item_result_js : JavaScriptObject
var _on_download_ugc_item_result_js : JavaScriptObject

# Signals that Godot developers can connect to
signal lobby_joined(payload)
signal lobby_created(payload)
signal lobby_message(payload)
signal lobby_left(payload)
signal got_leaderboard(payload)
signal got_leaderboard_entries(payload)
signal posted_leaderboard_score(payload)
signal ugc_item_created(payload)
signal ugc_item_updated(payload)
signal ugc_item_downloaded(payload)

func _enter_tree():
	print("WavedashSDK._enter_tree() called, platform: ", OS.get_name())
	isReady = true
	if OS.get_name() == Constants.PLATFORM_WEB:
		WavedashJS = JavaScriptBridge.get_interface("WavedashJS")
		if not WavedashJS:
			print("WavedashSDK: WavedashJS not found on window")
			return
		_on_lobby_joined_js = JavaScriptBridge.create_callback(_on_lobby_joined_gd)
		_on_lobby_created_js = JavaScriptBridge.create_callback(_on_lobby_created_gd)
		_on_get_leaderboard_result_js = JavaScriptBridge.create_callback(_on_get_leaderboard_result_gd)
		_on_get_leaderboard_entries_result_js = JavaScriptBridge.create_callback(_on_get_leaderboard_entries_result_gd)
		_on_post_leaderboard_score_result_js = JavaScriptBridge.create_callback(_on_post_leaderboard_score_result_gd)
		_on_create_ugc_item_result_js = JavaScriptBridge.create_callback(_on_create_ugc_item_result_gd)
		_on_update_ugc_item_result_js = JavaScriptBridge.create_callback(_on_update_ugc_item_result_gd)
		_on_download_ugc_item_result_js = JavaScriptBridge.create_callback(_on_download_ugc_item_result_gd)
		_js_callback_receiver = JavaScriptBridge.create_callback(_dispatch_js_event)
		var engine = JavaScriptBridge.create_object("Object")
		engine["type"] = "Godot"
		engine["SendMessage"] = _js_callback_receiver
		WavedashJS.setEngineInstance(engine)

func init(config: Dictionary):
	print("WavedashSDK: init() called")
	assert(isReady, "WavedashSDK.init() called before WavedashSDK was added to the tree")
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		print("WavedashSDK: Initializing with config: ", config)
		WavedashJS.init(JSON.stringify(config))

func get_user_id() -> String:
	if user_id:
		return user_id
		
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		var user_data = JSON.parse_string(WavedashJS.getUser())
		user_id = user_data["id"]
		username = user_data["username"]
		return user_id
	
	return ""
	
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

func get_my_leaderboard_entries(leaderboard_id: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.getMyLeaderboardEntries(leaderboard_id).then(_on_get_leaderboard_entries_result_js)

func get_leaderboard_entry_count(leaderboard_id: String) -> int:
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		# Synchronous call, entry count is cached in the JS SDK
		return WavedashJS.getLeaderboardEntryCount(leaderboard_id)

	return -1

func get_leaderboard_entries_around_player(leaderboard_id: String, count_ahead: int, count_behind: int, friends_only: bool):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		# TODO: Support friends_only functionality
		WavedashJS.listLeaderboardEntriesAroundUser(leaderboard_id, count_ahead, count_behind).then(_on_get_leaderboard_entries_result_js)

func get_leaderboard_entries(leaderboard_id: String, offset: int, limit: int, friends_only: bool):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		# TODO: Support friends_only functionality
		WavedashJS.listLeaderboardEntries(leaderboard_id, offset, limit).then(_on_get_leaderboard_entries_result_js)

func post_leaderboard_score(leaderboard_id: String, keep_best: bool, score: int, ugc_id: String = ""):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.uploadLeaderboardScore(leaderboard_id, keep_best, score, ugc_id).then(_on_post_leaderboard_score_result_js)

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

# User Generated Content (UGC) functions
func create_ugc_item(title: String, description: String, local_file_path: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.createUGCItem(title, description, local_file_path).then(_on_create_ugc_item_result_js)

func update_ugc_item(item_id: String, title: String, description: String, local_file_path: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.updateUGCItem(item_id, title, description, local_file_path).then(_on_update_ugc_item_result_js)

func download_ugc_item(item_id: String, local_file_path: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.downloadUGCItem(item_id, local_file_path).then(_on_download_ugc_item_result_js)

# Handle callbacks triggered by Promises resolving
func _on_lobby_joined_gd(args):
	var lobby_json: String = args[0] if args.size() > 0 else null
	var lobby_data: Dictionary = JSON.parse_string(lobby_json) if lobby_json else {}
	lobby_joined.emit(lobby_data)

func _on_lobby_created_gd(args):
	var lobby_id: String = args[0]
	lobby_created.emit(lobby_id)

func _on_get_leaderboard_result_gd(args):
	print("[WavedashSDK] Got leaderboard: ", args)
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	got_leaderboard.emit(response)

func _on_get_leaderboard_entries_result_gd(args):
	print("[WavedashSDK] Got leaderboard entries: ", args)
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	got_leaderboard_entries.emit(response)

func _on_post_leaderboard_score_result_gd(args):
	print("[WavedashSDK] Posted leaderboard score: ", args)
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	posted_leaderboard_score.emit(response)

func _on_create_ugc_item_result_gd(args):
	print("[WavedashSDK] UGC item created: ", args)
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	ugc_item_created.emit(response)

func _on_update_ugc_item_result_gd(args):
	print("[WavedashSDK] UGC item updated: ", args)
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	ugc_item_updated.emit(response)

func _on_download_ugc_item_result_gd(args):
	print("[WavedashSDK] UGC item downloaded: ", args)
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	ugc_item_downloaded.emit(response)

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
