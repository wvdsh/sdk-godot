# Since this is an autoload, it's already a singleton
# Access it directly via the global WavedashSDK variable
extends Node

const Constants = preload("WavedashConstants.gd")

# We expect window.WavedashJS to be available on the page
var WavedashJS : JavaScriptObject

# Cache what we can so the next call doesn't have to wait for JS
var user_id : String = ""
var username : String = ""
var entered_tree: bool = false

var cached_lobby_host_id : String = ""
var cached_lobby_id : String = ""

# Handle events broadcasted from JS to Godot
# JS -> GD
var _js_callback_receiver : JavaScriptObject

# Handle results when Godot calls async JS functions
# GD -> JS (async) -> GD

var _on_lobby_created_js : JavaScriptObject
var _on_lobby_left_js : JavaScriptObject
var _on_get_leaderboard_result_js : JavaScriptObject
var _on_post_leaderboard_score_result_js : JavaScriptObject
var _on_get_leaderboard_entries_result_js : JavaScriptObject
var _on_create_ugc_item_result_js : JavaScriptObject
var _on_update_ugc_item_result_js : JavaScriptObject
var _on_download_ugc_item_result_js : JavaScriptObject
var _on_download_remote_file_result_js : JavaScriptObject
var _on_upload_remote_file_result_js : JavaScriptObject
var _on_download_remote_directory_result_js : JavaScriptObject
var _on_get_lobbies_result_js : JavaScriptObject
var _on_request_stats_result_js : JavaScriptObject

# Signals that Godot developers can connect to
signal lobby_joined(payload)
signal lobby_created(payload)
signal lobby_message(payload)
signal lobby_left(payload)
signal lobby_data_updated(payload)
signal lobby_users_updated(payload)
signal lobby_kicked(payload)
signal got_lobbies(payload)
signal got_leaderboard(payload)
signal got_leaderboard_entries(payload)
signal posted_leaderboard_score(payload)
signal ugc_item_created(payload)
signal ugc_item_updated(payload)
signal ugc_item_downloaded(payload)
signal remote_file_downloaded(payload)
signal remote_file_uploaded(payload)
signal remote_directory_downloaded(payload)
signal p2p_connection_established(payload)
signal p2p_connection_failed(payload)
signal p2p_peer_disconnected(payload)
signal current_stats_received(payload)
signal backend_connected(payload)
signal backend_reconnecting(payload)
signal backend_disconnected(payload)

func _enter_tree():
	print("WavedashSDK._enter_tree() called, platform: ", OS.get_name())
	entered_tree = true
	if OS.get_name() == Constants.PLATFORM_WEB:
		WavedashJS = JavaScriptBridge.get_interface("WavedashJS")
		if not WavedashJS:
			push_error("WavedashSDK: WavedashJS not found on window")
			return
		assert(WavedashJS.engineInstance != null, "WavedashSDK: WavedashJS.engineInstance not found on window. Call WavedashJS.setEngineInstance(engine) before calling engine.startGame()")
		_on_lobby_created_js = JavaScriptBridge.create_callback(_on_lobby_created_gd)
		_on_get_leaderboard_result_js = JavaScriptBridge.create_callback(_on_get_leaderboard_result_gd)
		_on_lobby_left_js = JavaScriptBridge.create_callback(_on_lobby_left_gd)
		_on_get_leaderboard_entries_result_js = JavaScriptBridge.create_callback(_on_get_leaderboard_entries_result_gd)
		_on_post_leaderboard_score_result_js = JavaScriptBridge.create_callback(_on_post_leaderboard_score_result_gd)
		_on_create_ugc_item_result_js = JavaScriptBridge.create_callback(_on_create_ugc_item_result_gd)
		_on_update_ugc_item_result_js = JavaScriptBridge.create_callback(_on_update_ugc_item_result_gd)
		_on_download_ugc_item_result_js = JavaScriptBridge.create_callback(_on_download_ugc_item_result_gd)
		_on_download_remote_directory_result_js = JavaScriptBridge.create_callback(_on_download_remote_directory_result_gd)
		_on_download_remote_file_result_js = JavaScriptBridge.create_callback(_on_download_remote_file_result_gd)
		_on_upload_remote_file_result_js = JavaScriptBridge.create_callback(_on_upload_remote_file_result_gd)
		_on_get_lobbies_result_js = JavaScriptBridge.create_callback(_on_get_lobbies_result_gd)
		_on_request_stats_result_js = JavaScriptBridge.create_callback(_on_request_stats_result_gd)
		_js_callback_receiver = JavaScriptBridge.create_callback(_dispatch_js_event)
		WavedashJS.engineInstance["type"] = Constants.ENGINE_GODOT
		WavedashJS.engineInstance["SendMessage"] = _js_callback_receiver
		# Expose Emscripten's FS so JS can use it for File IO
		JavaScriptBridge.eval("window.WavedashJS.engineInstance.FS = FS;")

func init(config: Dictionary):
	assert(entered_tree, "WavedashSDK.init() called before WavedashSDK was added to the tree")
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.init(JSON.stringify(config))

# Signal to JS SDK that game is ready to receive events like LOBBY_JOINED, LOBBY_LEFT, etc.
func ready_for_events() -> void:
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.readyForEvents()

func show_overlay() -> void:
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.toggleOverlay()

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

func post_leaderboard_score(leaderboard_id: String, score: int, keep_best: bool, ugc_id: String = ""):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.uploadLeaderboardScore(leaderboard_id, score, keep_best, ugc_id).then(_on_post_leaderboard_score_result_js)

func create_lobby(lobby_type: int, max_players = null):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.createLobby(lobby_type, max_players).then(_on_lobby_created_js)

func download_remote_directory(path: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.downloadRemoteDirectory(path).then(_on_download_remote_directory_result_js)

func download_remote_file(file_path: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.downloadRemoteFile(file_path).then(_on_download_remote_file_result_js)

func upload_remote_file(file_path: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.uploadRemoteFile(file_path).then(_on_upload_remote_file_result_js)

func join_lobby(lobby_id: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.joinLobby(lobby_id)

func leave_lobby(lobby_id: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.leaveLobby(lobby_id).then(_on_lobby_left_js)
		return true
	return false

func list_available_lobbies():
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.listAvailableLobbies().then(_on_get_lobbies_result_js)

func get_lobby_host_id(lobby_id: String) -> String:
	if lobby_id == "":
		return ""
	if cached_lobby_id == lobby_id and cached_lobby_host_id != "":
		return cached_lobby_host_id
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		var result = WavedashJS.getLobbyHostId(lobby_id)
		if lobby_id == cached_lobby_id:
			cached_lobby_host_id = result if result else ""
		return result if result else ""
	return ""

func get_lobby_data(lobby_id: String, key: String) -> String:
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		return WavedashJS.getLobbyData(lobby_id, key)
	return ""

func set_lobby_data(lobby_id: String, key: String, value: String) -> bool:
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		return WavedashJS.setLobbyData(lobby_id, key, value)
	return false

func get_lobby_users(lobby_id: String) -> Array:
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		var result: String = WavedashJS.getLobbyUsers(lobby_id)
		print("[WavedashSDK] Got lobby users: ", result)
		var users: Array = JSON.parse_string(result) if result else []
		return users
	return []

func get_num_lobby_users(lobby_id: String) -> int:
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		return WavedashJS.getNumLobbyUsers(lobby_id)
	return 0

func send_lobby_chat_message(lobby_id: String, message: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		# Fire and forget
		return WavedashJS.sendLobbyMessage(lobby_id, message)
	return false

# User Generated Content (UGC) functions
func create_ugc_item(ugcType: int, title: String = "", description: String = "", visibility: int = Constants.UGC_VISIBILITY_PUBLIC, local_file_path: Variant = null):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		# TODO: Consider just passing along file data as PackedByteArray if it's small enough (< 5MB)
		# Faster, no I/O, saves the file system sync overhead
		WavedashJS.createUGCItem(ugcType, title, description, visibility, local_file_path).then(_on_create_ugc_item_result_js)

func update_ugc_item(ugc_id: String, title: String = "", description: String = "", visibility: int = Constants.UGC_VISIBILITY_PUBLIC, local_file_path: Variant = null):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		# TODO: Consider just passing along file data as PackedByteArray if it's small enough (< 5MB)
		# Faster, no I/O, saves the file system sync overhead
		WavedashJS.updateUGCItem(ugc_id, title, description, visibility, local_file_path).then(_on_update_ugc_item_result_js)

# Download the given UGC item to the given local file path
func download_ugc_item(ugc_id: String, local_file_path: String):
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		WavedashJS.downloadUGCItem(ugc_id, local_file_path).then(_on_download_ugc_item_result_js)

# P2P messaging
# Send a P2P message from Godot. JS will only send the message if the peer is ready to receive
func send_p2p_message(target_user_id: String, payload: PackedByteArray, channel: int = 0, reliable: bool = true) -> bool:
	if payload.size() == 0:
		push_warning("Dropping empty P2P message")
		return false
	
	# Tried a few options here for getting a Godot PackedByteArray across the JS barrier into a Uint8Array.
	# Logging them for clarity, Option 4 is the best for < 16KB payloads
	# (TODO: Pass a direct view into the Godot WASM heap if Godot ever supports it the way Unity JSLib does)
	
	# Option 1: Can we get our PackedByteArray across the JS barrier into a Uint8Array? Godot doesn't support this natively
	# var js_array = JavaScriptBridge.create_object("Uint8Array", payload)

	# Option 2: Write to a SharedArrayBuffer that JS will read from
	# This still requires calling JS functions to write to the buffer via JS bridge, so we don't win any performance here
	# var buffer = WavedashJS.getP2PChannelQueue(channel)
	# write_to_outgoing_queue(buffer, payload, channel)

	# Option 3: Just base64 encode and pass along as a string
	# var base64_data = Marshalls.raw_to_base64(payload)

	# Option 4: Copy data byte by byte to a pre-allocated JS ArrayBuffer. Fastest option for small payloads.
	var payload_size = payload.size()
	var js_buffer = WavedashJS.getP2POutgoingMessageBuffer()
	if payload_size > js_buffer.length:
		push_warning("P2P message exceeds maximum payload length ", payload_size, " > ", js_buffer.length, " dropping message")
		return false
	# Copy bytes (1 bridge call per byte unfortunately, still faster than base64 encoding as long as payload is < 16KB)
	for i in range(payload_size):
		js_buffer[i] = payload[i]
	if target_user_id == "":
		# Broadcast to all peers
		return WavedashJS.broadcastP2PMessage(channel, reliable, js_buffer, payload_size)
	else:
		# Send to specific peer
		return WavedashJS.sendP2PMessage(target_user_id, channel, reliable, js_buffer, payload_size)

# Read all P2P messages from the incoming queue for a specific channel
func drain_p2p_channel(channel: int) -> Array[Dictionary]:
	if OS.get_name() != Constants.PLATFORM_WEB or not WavedashJS:
		return []
	
	var messages: Array[Dictionary] = []
	var raw_messages: PackedByteArray = JavaScriptBridge.js_buffer_to_packed_byte_array(WavedashJS.drainP2PChannelToBuffer(channel))
	var read_offset = 0

	while read_offset + 4 <= raw_messages.size():
		var message_length = raw_messages[read_offset] | (raw_messages[read_offset + 1] << 8) | (raw_messages[read_offset + 2] << 16) | (raw_messages[read_offset + 3] << 24)
		read_offset += 4
		if read_offset + message_length > raw_messages.size():
			push_warning("P2P message exceeds buffer length", read_offset + message_length, " > ", raw_messages.size(), " dropping message")
			break
		var message = raw_messages.slice(read_offset, read_offset + message_length)
		read_offset += message_length
		var decoded: Dictionary = _decode_p2p_packet(message)
		if decoded:
			messages.append(decoded)
		else:
			push_warning("P2P message is malformed, dropping message")
			continue
	
	return messages

# Handle callbacks triggered by Promises resolving
func _on_lobby_created_gd(args):
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	print("[WavedashSDK] Lobby created: ", response)
	var success: bool = response.get("success", false)
	# Cache the lobbyId from the response (creating means we're the host)
	if success:
		cached_lobby_id = response.get("data", "")
		cached_lobby_host_id = user_id
	lobby_created.emit(response)
	# Note: Don't emit lobby_joined here - let JS event dispatch handle it
	# This prevents duplicate signals when game calls create_lobby()

func _on_lobby_left_gd(args):
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	print("[WavedashSDK] Lobby left: ", response)
	cached_lobby_id = ""
	cached_lobby_host_id = ""
	lobby_left.emit(response)

func _on_get_leaderboard_result_gd(args):
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	got_leaderboard.emit(response)

func _on_get_leaderboard_entries_result_gd(args):
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	got_leaderboard_entries.emit(response)

func _on_post_leaderboard_score_result_gd(args):
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	posted_leaderboard_score.emit(response)

func _on_create_ugc_item_result_gd(args):
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	ugc_item_created.emit(response)

func _on_update_ugc_item_result_gd(args):
	print("[WavedashSDK] UGC item updated: ", args)
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	ugc_item_updated.emit(response)

func _on_download_ugc_item_result_gd(args):
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	ugc_item_downloaded.emit(response)

func _on_download_remote_directory_result_gd(args):
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	remote_directory_downloaded.emit(response)

func _on_download_remote_file_result_gd(args):
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	remote_file_downloaded.emit(response)

func _on_upload_remote_file_result_gd(args):
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	remote_file_uploaded.emit(response)

func _on_get_lobbies_result_gd(args):
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	print("[WavedashSDK] Got lobbies: ", response)
	if response.get("success", false):
		got_lobbies.emit(response.get("data", []))

func _on_request_stats_result_gd(args):
	var response_json: String = args[0] if args.size() > 0 else null
	var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
	print("[WavedashSDK] Got stats: ", response)
	current_stats_received.emit(response)

# Handle events broadcasted from JS to Godot
func _dispatch_js_event(args):
	var _game_object_name = args[0]  # Unused in Godot. Needed for Unity
	var method_name = args[1]
	var payload = args[2]
	match method_name:
		Constants.JS_EVENT_LOBBY_MESSAGE:
			var data = JSON.parse_string(payload)
			print("[WavedashSDK] Lobby message: ", payload)
			lobby_message.emit(data)
		Constants.JS_EVENT_LOBBY_DATA_UPDATED:
			var data = JSON.parse_string(payload)
			print("[WavedashSDK] Lobby data updated: ", payload)
			lobby_data_updated.emit(data)
		Constants.JS_EVENT_LOBBY_USERS_UPDATED:
			var data = JSON.parse_string(payload)
			print("[WavedashSDK] Lobby users updated: ", payload)
			# Reset lobby host, might have changed when users shuffled
			cached_lobby_host_id = ""
			lobby_users_updated.emit(data)
		Constants.JS_EVENT_LOBBY_JOINED:
			var data = JSON.parse_string(payload)
			print("[WavedashSDK] Lobby joined: ", payload)
			# Enriched signal payload: { lobbyId, hostId, users, metadata }
			cached_lobby_id = data.get("lobbyId", "")
			cached_lobby_host_id = data.get("hostId", "")
			lobby_joined.emit(data)
		Constants.JS_EVENT_LOBBY_KICKED:
			var data = JSON.parse_string(payload)
			# payload: { lobbyId, reason }
			var reason = data.get("reason", Constants.LOBBY_KICKED_REASON_KICKED)
			print("[WavedashSDK] Lobby kicked (reason: %s): %s" % [reason, payload])
			cached_lobby_id = ""
			cached_lobby_host_id = ""
			lobby_kicked.emit(data)
		Constants.JS_EVENT_P2P_CONNECTION_ESTABLISHED:
			var data = JSON.parse_string(payload)
			print("[WavedashSDK] P2P connection established: ", payload)
			p2p_connection_established.emit(data)
		Constants.JS_EVENT_P2P_CONNECTION_FAILED:
			var data = JSON.parse_string(payload)
			print("[WavedashSDK] P2P connection failed: ", payload)
			p2p_connection_failed.emit(data)
		Constants.JS_EVENT_P2P_PEER_DISCONNECTED:
			var data = JSON.parse_string(payload)
			print("[WavedashSDK] P2P peer disconnected: ", payload)
			p2p_peer_disconnected.emit(data)
		Constants.JS_EVENT_BACKEND_CONNECTED:
			var data = JSON.parse_string(payload)
			print("[WavedashSDK] Backend connected: ", payload)
			backend_connected.emit(data)
		Constants.JS_EVENT_BACKEND_RECONNECTING:
			var data = JSON.parse_string(payload)
			print("[WavedashSDK] Backend reconnecting: ", payload)
			backend_reconnecting.emit(data)
		Constants.JS_EVENT_BACKEND_DISCONNECTED:
			var data = JSON.parse_string(payload)
			print("[WavedashSDK] Backend disconnected: ", payload)
			backend_disconnected.emit(data)
		_:
			push_warning("[WavedashSDK] Received unknown event from JS: " + method_name)

# Helper functions
# Decode a binary P2P packet into {identity: String, channel: int, payload: PackedByteArray}
func _decode_p2p_packet(data: PackedByteArray) -> Dictionary:
	# Binary format: [fromUserId(32)][channel(4)][dataLength(4)][payload(...)]
	if data.size() < 40:  # Minimum size for header
		return {}
	
	var result = {}
	var offset = 0
	
	# fromUserId (32 bytes)
	var from_user_bytes = data.slice(offset, offset + 32)
	var from_user_str = from_user_bytes.get_string_from_ascii()
	# Remove null padding (resize(32) fills with zeros)
	var null_pos = from_user_str.find(String.chr(0))
	if null_pos != -1:
		from_user_str = from_user_str.substr(0, null_pos)
	result["identity"] = from_user_str
	offset += 32
	
	# channel (4 bytes, little-endian)
	var channel = data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)
	result["channel"] = channel
	offset += 4
	
	# dataLength (4 bytes, little-endian)
	var payload_length = data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)
	offset += 4
	
	# payload (variable length)
	if payload_length > 0 and offset + payload_length <= data.size():
		result["payload"] = data.slice(offset, offset + payload_length)
	else:
		result["payload"] = PackedByteArray()
	
	return result
	
func request_stats() -> void:
	if OS.get_name() == Constants.PLATFORM_WEB:
		WavedashJS.requestStats().then(_on_request_stats_result_js)

func set_stat_int(stat_name:String, val:int, store_now:bool) -> void:
	if OS.get_name() == Constants.PLATFORM_WEB:
		WavedashJS.setStat(stat_name, val)
		if store_now:
			WavedashJS.storeStats()

func get_stat_int(stat_name: String) -> int:
	if OS.get_name() == Constants.PLATFORM_WEB:
		return WavedashJS.getStat(stat_name)
	return -1

func set_achievement(ach_name:String) -> void:
	if OS.get_name() == Constants.PLATFORM_WEB:
		WavedashJS.setAchievement(ach_name)
		WavedashJS.storeStats()
	
func get_achievement(ach_name:String) -> bool:
	if OS.get_name() == Constants.PLATFORM_WEB and WavedashJS:
		return WavedashJS.getAchievement(ach_name)
	return false
