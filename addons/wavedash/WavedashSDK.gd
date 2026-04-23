# Since this is an autoload, it's already a singleton
# Access it directly via the global WavedashSDK variable
extends Node

const Constants = preload("WavedashConstants.gd")

# We expect window.WavedashJS to be available on the page
var WavedashJS : JavaScriptObject
var _is_web : bool = OS.get_name() == Constants.PLATFORM_WEB

# Cache what we can so the next call doesn't have to wait for JS
var _cached_user : Dictionary = {}
var _user_id : String = ""
var _username : String = ""
var _entered_tree: bool = false

var _cached_lobby_host_id : String = ""
var _cached_lobby_id : String = ""
var _p2p_outgoing_buffer : JavaScriptObject
var _p2p_outgoing_buffer_size : int = 0

# Godot compatibility checks for which P2P method to use
# Initialized at startup
var _has_js_buffer_transfer : bool = false
var _eval_returns_byte_array : bool = false

# Handle events broadcasted from JS to Godot
# JS -> GD
var _js_callback_receiver : JavaScriptObject

# Per-request tracking for async JS calls (GD -> JS -> GD)
# Each call gets a unique ID so concurrent awaits don't cross-wire responses
var _next_request_id: int = 0
var _pending_results: Dictionary = {}
var _active_callbacks: Dictionary = {}
signal _request_resolved(request_id: int)

# Signals that Godot developers can connect to
signal lobby_joined(payload)
signal lobby_created(payload)
signal lobby_message(payload)
signal lobby_left(payload)
signal lobby_data_updated(payload)
signal lobby_users_updated(payload)
signal lobby_kicked(payload)
signal lobby_invite(payload)
signal sent_lobby_invite(payload)
signal got_lobby_invite_link(payload)
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
signal got_remote_directory_listing(payload)
signal p2p_connection_established(payload)
signal p2p_connection_failed(payload)
signal p2p_peer_disconnected(payload)
signal p2p_peer_reconnecting(payload)
signal p2p_peer_reconnected(payload)
signal p2p_packet_dropped(payload)
signal current_stats_received(payload)
signal stats_stored(payload)
signal backend_connected(payload)
signal backend_reconnecting(payload)
signal backend_disconnected(payload)
signal user_avatar_loaded(texture: Texture2D, user_id: String)
signal got_friends(payload)
signal got_user_jwt(payload)

func _log(msg: String) -> void:
	if OS.is_debug_build():
		print("[WavedashSDK] ", msg)

func _web_unsupported(method_name: String) -> Dictionary:
	return {"success": false, "data": null, "message": "%s is only supported in Web builds" % method_name}

func _enter_tree():
	_log("_enter_tree() called, platform: %s" % OS.get_name())
	_entered_tree = true
	if _is_web:
		WavedashJS = JavaScriptBridge.get_interface("WavedashJS")
		if not WavedashJS:
			push_error("WavedashSDK: WavedashJS not found on window")
			return
		assert(WavedashJS.engineInstance != null, "WavedashSDK: WavedashJS.engineInstance not found on window. Call WavedashJS.setEngineInstance(engine) before calling engine.startGame()")
		_js_callback_receiver = JavaScriptBridge.create_callback(_dispatch_js_event)
		WavedashJS.engineInstance["type"] = Constants.ENGINE_GODOT
		WavedashJS.engineInstance["SendMessage"] = _js_callback_receiver
		JavaScriptBridge.eval("window.WavedashJS.engineInstance.FS = FS;")
		_has_js_buffer_transfer = JavaScriptBridge.has_method("js_buffer_to_packed_byte_array")
		if not _has_js_buffer_transfer:
			_eval_returns_byte_array = JavaScriptBridge.eval("new Uint8Array([1,2,3])") is PackedByteArray

func init(config: Dictionary):
	assert(_entered_tree, "WavedashSDK.init() called before WavedashSDK was added to the tree")
	if _is_web and WavedashJS:
		WavedashJS.init(JSON.stringify(config))

## Signal that the game is ready to receive events (LobbyJoined, LobbyMessage, etc).
## Called automatically by init() unless deferEvents is set to true in the config.
## If deferEvents is true, call this manually after your pre-game setup is complete.
func ready_for_events() -> void:
	if _is_web and WavedashJS:
		WavedashJS.readyForEvents()

func toggle_overlay() -> void:
	if _is_web and WavedashJS:
		WavedashJS.toggleOverlay()

func _fetch_user() -> Dictionary:
	if _cached_user.is_empty() and _is_web and WavedashJS:
		_cached_user = JSON.parse_string(WavedashJS.getUser())
		_user_id = _cached_user.get("id", "")
		_username = _cached_user.get("username", "")
	return _cached_user

func get_user() -> Dictionary:
	return _fetch_user()

func get_user_id() -> String:
	if _user_id == "":
		_fetch_user()
	return _user_id

## Returns the username for the given user_id, or the current user's username if no user_id is provided.
## Username will only be known if the game has seen the user either from a call to list_friends or from
## being in a lobby with the user.
func get_username(user_id: String = "") -> String:
	if user_id != "":
		if not _is_web or not WavedashJS:
			return ""
		var result = WavedashJS.getUsername(user_id)
		return result if result else ""
	if _username == "":
		_fetch_user()
	return _username

## Returns the current user's gameplay JWT, fetching it if not already cached.
## Use this to authenticate requests to your game's own backend, if you have one.
## Response shape: { success, data: <jwt>, message }.
func get_user_jwt():
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.getUserJwt())
		got_user_jwt.emit(result)
		return result
	else:
		var result = _web_unsupported("get_user_jwt")
		got_user_jwt.emit(result)
		return result

## Returns the launch params that were passed via URL when the game was launched.
## {"lobby": "lobbyId123"}
func get_launch_params() -> Dictionary:
	if _is_web and WavedashJS:
		var result: String = WavedashJS.getLaunchParams()
		return JSON.parse_string(result) if result else {}
	return {}

## Returns the CDN URL for a cached user's avatar with size transformation.
## Users are cached when seen via friends list or lobby membership.
## Returns empty string if user not cached or has no avatar.
func get_user_avatar_url(user_id_to_fetch: String, size: int = Constants.AVATAR_SIZE_MEDIUM) -> String:
	if _is_web and WavedashJS:
		var result = WavedashJS.getUserAvatarUrl(user_id_to_fetch, size)
		return result if result else ""
	return ""

## Fetches avatar for a user and emits user_avatar_loaded signal when complete.
## Users must be cached (seen via friends list or lobby membership) for this to work.
## Emits user_avatar_loaded(texture, user_id) - texture is null on failure.
func get_user_avatar(user_id_to_fetch: String, size: int = Constants.AVATAR_SIZE_MEDIUM) -> Texture2D:
	var url = get_user_avatar_url(user_id_to_fetch, size)
	if url.is_empty():
		user_avatar_loaded.emit(null, user_id_to_fetch)
		return null

	var http = HTTPRequest.new()
	add_child(http)
	var error = http.request(url)
	if error != OK:
		push_warning("Failed to start avatar request for user: " + user_id_to_fetch)
		http.queue_free()
		user_avatar_loaded.emit(null, user_id_to_fetch)
		return null

	var response = await http.request_completed
	http.queue_free()
	var result: int = response[0]
	var response_code: int = response[1]
	var body: PackedByteArray = response[3]

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning("Failed to load avatar for user: " + user_id_to_fetch)
		user_avatar_loaded.emit(null, user_id_to_fetch)
		return null

	var image = Image.new()
	var err = image.load_png_from_buffer(body)
	if err != OK:
		err = image.load_jpg_from_buffer(body)
	if err != OK:
		err = image.load_webp_from_buffer(body)

	if err != OK:
		push_warning("Failed to decode avatar for user: " + user_id_to_fetch)
		user_avatar_loaded.emit(null, user_id_to_fetch)
		return null

	var texture = ImageTexture.create_from_image(image)
	user_avatar_loaded.emit(texture, user_id_to_fetch)
	return texture

## Lists the current user's friends.
## Emits got_friends signal with response containing: userId, username, avatarUrl (optional), isOnline.
## Friends are automatically cached for avatar lookups via get_user_avatar_url/get_user_avatar.
func list_friends():
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.listFriends())
		got_friends.emit(result)
		return result
	else:
		var result = _web_unsupported("list_friends")
		got_friends.emit(result)
		return result

func get_leaderboard(leaderboard_name: String):
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.getLeaderboard(leaderboard_name))
		got_leaderboard.emit(result)
		return result
	else:
		var result = _web_unsupported("get_leaderboard")
		got_leaderboard.emit(result)
		return result

func get_or_create_leaderboard(leaderboard_name: String, sort_method: int, display_type: int):
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.getOrCreateLeaderboard(leaderboard_name, sort_method, display_type))
		got_leaderboard.emit(result)
		return result
	else:
		var result = _web_unsupported("get_or_create_leaderboard")
		got_leaderboard.emit(result)
		return result

func get_my_leaderboard_entries(leaderboard_id: String):
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.getMyLeaderboardEntries(leaderboard_id))
		got_leaderboard_entries.emit(result)
		return result
	else:
		var result = _web_unsupported("get_my_leaderboard_entries")
		got_leaderboard_entries.emit(result)
		return result

func get_leaderboard_entry_count(leaderboard_id: String) -> int:
	if _is_web and WavedashJS:
		# Synchronous call, entry count is cached in the JS SDK
		return WavedashJS.getLeaderboardEntryCount(leaderboard_id)

	return -1

func get_leaderboard_entries_around_player(leaderboard_id: String, count_ahead: int, count_behind: int, friends_only: bool):
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.listLeaderboardEntriesAroundUser(leaderboard_id, count_ahead, count_behind, friends_only))
		got_leaderboard_entries.emit(result)
		return result
	else:
		var result = _web_unsupported("get_leaderboard_entries_around_player")
		got_leaderboard_entries.emit(result)
		return result

func get_leaderboard_entries(leaderboard_id: String, offset: int, limit: int, friends_only: bool):
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.listLeaderboardEntries(leaderboard_id, offset, limit, friends_only))
		got_leaderboard_entries.emit(result)
		return result
	else:
		var result = _web_unsupported("get_leaderboard_entries")
		got_leaderboard_entries.emit(result)
		return result

func post_leaderboard_score(leaderboard_id: String, score: int, keep_best: bool, ugc_id: String = ""):
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.uploadLeaderboardScore(leaderboard_id, score, keep_best, ugc_id))
		posted_leaderboard_score.emit(result)
		return result
	else:
		var result = _web_unsupported("post_leaderboard_score")
		posted_leaderboard_score.emit(result)
		return result

func create_lobby(lobby_type: int, max_players = null):
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.createLobby(lobby_type, max_players))
		if result.get("success", false):
			_cached_lobby_id = result.get("data", "")
			_cached_lobby_host_id = _user_id
		lobby_created.emit(result)
		return result
	else:
		var result = _web_unsupported("create_lobby")
		lobby_created.emit(result)
		return result

func _normalize_user_path(path: String) -> String:
	if path.begins_with("user://"):
		var subpath = path.substr(7)
		if subpath.is_empty():
			return OS.get_user_data_dir()
		return OS.get_user_data_dir().rstrip("/") + "/" + subpath
	return path

func _validate_user_data_path(path: String, func_name: String) -> bool:
	var user_data_dir = OS.get_user_data_dir()
	if not path.begins_with(user_data_dir):
		push_error("[WavedashSDK] %s: file_path must be an absolute path starting with 'user://' or OS.get_user_data_dir() ('%s'). Got: '%s'" % [func_name, user_data_dir, path])
		return false
	return true

func download_remote_directory(path: String):
	path = _normalize_user_path(path)
	if _is_web and WavedashJS:
		if not _validate_user_data_path(path, "download_remote_directory"):
			var err = {"success": false, "data": null, "message": "Invalid path: must start with 'user://' or OS.get_user_data_dir()"}
			remote_directory_downloaded.emit(err)
			return err
		var result = await _invoke_js(WavedashJS.downloadRemoteDirectory(path))
		remote_directory_downloaded.emit(result)
		return result
	else:
		var result = _web_unsupported("download_remote_directory")
		remote_directory_downloaded.emit(result)
		return result

## Lists entries in a remote directory without downloading them.
## Path must be under user:// or OS.get_user_data_dir().
## Response shape: { success, data: [<metadata>], message }.
func list_remote_directory(path: String):
	path = _normalize_user_path(path)
	if _is_web and WavedashJS:
		if not _validate_user_data_path(path, "list_remote_directory"):
			var err = {"success": false, "data": null, "message": "Invalid path: must start with 'user://' or OS.get_user_data_dir()"}
			got_remote_directory_listing.emit(err)
			return err
		var result = await _invoke_js(WavedashJS.listRemoteDirectory(path))
		got_remote_directory_listing.emit(result)
		return result
	else:
		var result = _web_unsupported("list_remote_directory")
		got_remote_directory_listing.emit(result)
		return result

func download_remote_file(file_path: String):
	file_path = _normalize_user_path(file_path)
	if _is_web and WavedashJS:
		if not _validate_user_data_path(file_path, "download_remote_file"):
			var err = {"success": false, "data": null, "message": "Invalid path: must start with 'user://' or OS.get_user_data_dir()"}
			remote_file_downloaded.emit(err)
			return err
		var result = await _invoke_js(WavedashJS.downloadRemoteFile(file_path))
		remote_file_downloaded.emit(result)
		return result
	else:
		var result = _web_unsupported("download_remote_file")
		remote_file_downloaded.emit(result)
		return result

func upload_remote_file(file_path: String):
	file_path = _normalize_user_path(file_path)
	if _is_web and WavedashJS:
		if not _validate_user_data_path(file_path, "upload_remote_file"):
			var err = {"success": false, "data": null, "message": "Invalid path: must start with 'user://' or OS.get_user_data_dir()"}
			remote_file_uploaded.emit(err)
			return err
		var result = await _invoke_js(WavedashJS.uploadRemoteFile(file_path))
		remote_file_uploaded.emit(result)
		return result
	else:
		var result = _web_unsupported("upload_remote_file")
		remote_file_uploaded.emit(result)
		return result

## Requests to join a lobby. Returns true if the request was accepted.
## Connect to lobby_joined for the full payload once the server confirms the join.
func join_lobby(lobby_id: String) -> bool:
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.joinLobby(lobby_id))
		return result.get("success", false)
	return false

func leave_lobby(lobby_id: String):
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.leaveLobby(lobby_id))
		if result.get("success", false) and result.get("data", "") == _cached_lobby_id:
			_cached_lobby_id = ""
			_cached_lobby_host_id = ""
		lobby_left.emit(result)
		return result
	else:
		var result = _web_unsupported("leave_lobby")
		lobby_left.emit(result)
		return result

func list_available_lobbies():
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.listAvailableLobbies())
		got_lobbies.emit(result)
		return result
	else:
		var result = _web_unsupported("list_available_lobbies")
		got_lobbies.emit(result)
		return result

func get_lobby_host_id(lobby_id: String) -> String:
	if lobby_id == "":
		return ""
	if _cached_lobby_id == lobby_id and _cached_lobby_host_id != "":
		return _cached_lobby_host_id
	if _is_web and WavedashJS:
		var result = WavedashJS.getLobbyHostId(lobby_id)
		if lobby_id == _cached_lobby_id:
			_cached_lobby_host_id = result if result else ""
		return result if result else ""
	return ""

func get_lobby_data_string(lobby_id: String, key: String) -> String:
	if _is_web and WavedashJS:
		var result = WavedashJS.getLobbyData(lobby_id, key)
		return result if result != null else ""
	return ""

func get_lobby_data_int(lobby_id: String, key: String) -> int:
	if _is_web and WavedashJS:
		var result = WavedashJS.getLobbyData(lobby_id, key)
		return int(result) if result != null else 0
	return 0

func get_lobby_data_float(lobby_id: String, key: String) -> float:
	if _is_web and WavedashJS:
		var result = WavedashJS.getLobbyData(lobby_id, key)
		return float(result) if result != null else 0.0
	return 0.0

func set_lobby_data_string(lobby_id: String, key: String, value: String) -> bool:
	if _is_web and WavedashJS:
		return WavedashJS.setLobbyData(lobby_id, key, value)
	return false

func set_lobby_data_int(lobby_id: String, key: String, value: int) -> bool:
	if _is_web and WavedashJS:
		return WavedashJS.setLobbyData(lobby_id, key, value)
	return false

func set_lobby_data_float(lobby_id: String, key: String, value: float) -> bool:
	if _is_web and WavedashJS:
		return WavedashJS.setLobbyData(lobby_id, key, value)
	return false

func delete_lobby_data(lobby_id: String, key: String) -> bool:
	if _is_web and WavedashJS:
		return WavedashJS.deleteLobbyData(lobby_id, key)
	return false

func get_lobby_users(lobby_id: String) -> Array:
	if _is_web and WavedashJS:
		var result: String = WavedashJS.getLobbyUsers(lobby_id)
		_log("Got lobby users: %s" % str(result))
		var users: Array = JSON.parse_string(result) if result else []
		return users
	return []

func get_num_lobby_users(lobby_id: String) -> int:
	if _is_web and WavedashJS:
		return WavedashJS.getNumLobbyUsers(lobby_id)
	return 0

func send_lobby_chat_message(lobby_id: String, message: String):
	if _is_web and WavedashJS:
		# Fire and forget
		return WavedashJS.sendLobbyMessage(lobby_id, message)
	return false

func invite_user_to_lobby(lobby_id: String, user_id_to_invite: String):
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.inviteUserToLobby(lobby_id, user_id_to_invite))
		sent_lobby_invite.emit(result)
		return result
	else:
		var result = _web_unsupported("invite_user_to_lobby")
		sent_lobby_invite.emit(result)
		return result

## Returns a shareable invite link for the current lobby.
## When copy_to_clipboard is true, the launcher copies the link to the user's clipboard.
## Response shape: { success, data: <url>, message }.
func get_lobby_invite_link(copy_to_clipboard: bool = false):
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.getLobbyInviteLink(copy_to_clipboard))
		got_lobby_invite_link.emit(result)
		return result
	else:
		var result = _web_unsupported("get_lobby_invite_link")
		got_lobby_invite_link.emit(result)
		return result

# User Generated Content (UGC) functions
# TODO: Consider just passing along file data as PackedByteArray if it's small enough (< 5MB)
# Faster, no I/O, saves the file system sync overhead
func create_ugc_item(ugcType: int, title: String = "", description: String = "", visibility: int = Constants.UGC_VISIBILITY_PUBLIC, local_file_path: Variant = null):
	if local_file_path != null:
		local_file_path = _normalize_user_path(local_file_path)
	if _is_web and WavedashJS:
		if local_file_path != null and not _validate_user_data_path(local_file_path, "create_ugc_item"):
			var err = {"success": false, "data": null, "message": "Invalid path: must start with 'user://' or OS.get_user_data_dir()"}
			ugc_item_created.emit(err)
			return err
		var result = await _invoke_js(WavedashJS.createUGCItem(ugcType, title, description, visibility, local_file_path))
		ugc_item_created.emit(result)
		return result
	else:
		var result = _web_unsupported("create_ugc_item")
		ugc_item_created.emit(result)
		return result

func update_ugc_item(ugc_id: String, title: String = "", description: String = "", visibility: int = Constants.UGC_VISIBILITY_PUBLIC, local_file_path: Variant = null):
	if local_file_path != null:
		local_file_path = _normalize_user_path(local_file_path)
	if _is_web and WavedashJS:
		if local_file_path != null and not _validate_user_data_path(local_file_path, "update_ugc_item"):
			var err = {"success": false, "data": null, "message": "Invalid path: must start with 'user://' or OS.get_user_data_dir()"}
			ugc_item_updated.emit(err)
			return err
		var result = await _invoke_js(WavedashJS.updateUGCItem(ugc_id, title, description, visibility, local_file_path))
		ugc_item_updated.emit(result)
		return result
	else:
		var result = _web_unsupported("update_ugc_item")
		ugc_item_updated.emit(result)
		return result

func download_ugc_item(ugc_id: String, local_file_path: String):
	local_file_path = _normalize_user_path(local_file_path)
	if _is_web and WavedashJS:
		if not _validate_user_data_path(local_file_path, "download_ugc_item"):
			var err = {"success": false, "data": null, "message": "Invalid path: must start with 'user://' or OS.get_user_data_dir()"}
			ugc_item_downloaded.emit(err)
			return err
		var result = await _invoke_js(WavedashJS.downloadUGCItem(ugc_id, local_file_path))
		ugc_item_downloaded.emit(result)
		return result
	else:
		var result = _web_unsupported("download_ugc_item")
		ugc_item_downloaded.emit(result)
		return result

func request_stats():
	if _is_web and WavedashJS:
		var result = await _invoke_js(WavedashJS.requestStats())
		current_stats_received.emit(result)
		return result
	else:
		var result = _web_unsupported("request_stats")
		current_stats_received.emit(result)
		return result

func set_stat_int(stat_name: String, val: int, store_now: bool = false) -> bool:
	if _is_web and WavedashJS:
		return WavedashJS.setStat(stat_name, val, store_now)
	return false

func set_stat_float(stat_name: String, val: float, store_now: bool = false) -> bool:
	if _is_web and WavedashJS:
		return WavedashJS.setStat(stat_name, val, store_now)
	return false

func store_stats() -> bool:
	if _is_web and WavedashJS:
		return WavedashJS.storeStats()
	return false

func get_stat_int(stat_name: String) -> int:
	if _is_web and WavedashJS:
		return WavedashJS.getStat(stat_name)
	return 0

func get_stat_float(stat_name: String) -> float:
	if _is_web and WavedashJS:
		return WavedashJS.getStat(stat_name)
	return 0.0

func set_achievement(ach_name: String, store_now: bool = false) -> bool:
	if _is_web and WavedashJS:
		return WavedashJS.setAchievement(ach_name, store_now)
	return false
	
func get_achievement(ach_name:String) -> bool:
	if _is_web and WavedashJS:
		return WavedashJS.getAchievement(ach_name)
	return false

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
	if not _p2p_outgoing_buffer:
		_p2p_outgoing_buffer = WavedashJS.getP2POutgoingMessageBuffer()
		_p2p_outgoing_buffer_size = _p2p_outgoing_buffer.length
	var js_buffer = _p2p_outgoing_buffer
	if payload_size > _p2p_outgoing_buffer_size:
		push_warning("P2P message exceeds maximum payload length ", payload_size, " > ", _p2p_outgoing_buffer_size, " dropping message")
		return false
	# Copy bytes (1 bridge call per byte unfortunately, still faster than base64 encoding as long as payload is < 16KB)
	for i in range(payload_size):
		# gdlint: ignore=unsafe_property_access
		(js_buffer as Variant)[i] = payload[i]
	if target_user_id == "":
		# Broadcast to all peers
		return WavedashJS.broadcastP2PMessage(channel, reliable, js_buffer, payload_size)
	else:
		# Send to specific peer
		return WavedashJS.sendP2PMessage(target_user_id, channel, reliable, js_buffer, payload_size)

# Read all P2P messages from the incoming queue for a specific channel
func drain_p2p_channel(channel: int) -> Array[Dictionary]:
	if not _is_web or not WavedashJS:
		return []
	
	var messages: Array[Dictionary] = []
	var raw_messages: PackedByteArray
	if _has_js_buffer_transfer:
		raw_messages = JavaScriptBridge.call("js_buffer_to_packed_byte_array", WavedashJS.drainP2PChannelToBuffer(channel))
	else:
		raw_messages = _js_eval_to_packed_byte_array("WavedashJS.drainP2PChannelToBuffer(%d)" % channel)
	if raw_messages.is_empty():
		return []
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

## Pre-4.4 fallback for JavaScriptBridge.js_buffer_to_packed_byte_array().
## Godot 4.2+ eval() natively converts Uint8Array returns to PackedByteArray
## via direct WASM memory copy — same mechanism the native method uses.
## Godot 4.0-4.1 eval() can't return PackedByteArray (type mapping bug), so
## we base64-encode on the JS side and decode in GDScript.
## _eval_returns_byte_array is probed once at startup to pick the right path.
func _js_eval_to_packed_byte_array(js_expr: String) -> PackedByteArray:
	if _eval_returns_byte_array:
		var result = JavaScriptBridge.eval(
			"(function() {" +
			"  var buf = %s;" % js_expr +
			"  if (!buf || !buf.byteLength) return null;" +
			"  return buf instanceof Uint8Array ? buf : new Uint8Array(buf.buffer || buf);" +
			"})()"
		)
		if result is PackedByteArray:
			return result
		return PackedByteArray()
	# Godot 4.0-4.1: eval() can't return PackedByteArray, base64 roundtrip.
	var b64 = JavaScriptBridge.eval(
		"(function() {" +
		"  var buf = %s;" % js_expr +
		"  if (!buf || !buf.byteLength) return '';" +
		"  var arr = buf instanceof Uint8Array ? buf : new Uint8Array(buf.buffer || buf);" +
		"  var parts = []; var CHUNK = 0x8000;" +
		"  for (var i = 0; i < arr.length; i += CHUNK)" +
		"    parts.push(String.fromCharCode.apply(null, arr.subarray(i, i + CHUNK)));" +
		"  return btoa(parts.join(''));" +
		"})()"
	)
	if b64 and b64 != "":
		return Marshalls.base64_to_raw(b64)
	return PackedByteArray()

func _create_js_callback(req_id: int) -> JavaScriptObject:
	var cb = JavaScriptBridge.create_callback(func(args):
		var response_json: String = args[0] if args.size() > 0 else ""
		var response: Dictionary = JSON.parse_string(response_json) if response_json else {}
		_pending_results[req_id] = response
		_request_resolved.emit(req_id)
	)
	_active_callbacks[req_id] = cb
	return cb

func _await_request(req_id: int):
	while not _pending_results.has(req_id):
		await _request_resolved
	var result = _pending_results[req_id]
	_pending_results.erase(req_id)
	_active_callbacks.erase(req_id)
	return result

func _invoke_js(js_promise):
	_next_request_id += 1
	var req_id = _next_request_id
	js_promise.then(_create_js_callback(req_id))
	return await _await_request(req_id)


# Handle events broadcasted from JS to Godot
func _dispatch_js_event(args):
	var _game_object_name = args[0]  # Unused in Godot. Needed for Unity
	var method_name = args[1]
	var payload = args[2]
	match method_name:
		Constants.JS_EVENT_LOBBY_MESSAGE:
			var data = JSON.parse_string(payload)
			_log("Lobby message: %s" % str(payload))
			lobby_message.emit(data)
		Constants.JS_EVENT_LOBBY_DATA_UPDATED:
			var data = JSON.parse_string(payload)
			_log("Lobby data updated: %s" % str(payload))
			lobby_data_updated.emit(data)
		Constants.JS_EVENT_LOBBY_USERS_UPDATED:
			var data = JSON.parse_string(payload)
			_log("Lobby users updated: %s" % str(payload))
			# Reset lobby host, might have changed when users shuffled
			_cached_lobby_host_id = ""
			lobby_users_updated.emit(data)
		# All lobby join flows land here
		# 1. create_lobby success -> LOBBY_JOINED
		# 2. join_lobby success -> LOBBY_JOINED
		# 3. External join (ie invite link) -> LOBBY_JOINED
		Constants.JS_EVENT_LOBBY_JOINED:
			var data = JSON.parse_string(payload)
			_log("Lobby joined: %s" % str(payload))
			# Payload: { lobbyId, hostId, users, metadata }
			_cached_lobby_id = data.get("lobbyId", "")
			_cached_lobby_host_id = data.get("hostId", "")
			lobby_joined.emit(data)
		Constants.JS_EVENT_LOBBY_KICKED:
			var data = JSON.parse_string(payload)
			# payload: { lobbyId, reason }
			var reason = data.get("reason", Constants.LOBBY_KICKED_REASON_KICKED)
			_log("Lobby kicked (reason: %s): %s" % [reason, payload])
			_cached_lobby_id = ""
			_cached_lobby_host_id = ""
			lobby_kicked.emit(data)
		Constants.JS_EVENT_LOBBY_INVITE:
			var data = JSON.parse_string(payload)
			_log("Lobby invite: %s" % str(payload))
			lobby_invite.emit(data)
		Constants.JS_EVENT_P2P_CONNECTION_ESTABLISHED:
			var data = JSON.parse_string(payload)
			_log("P2P connection established: %s" % str(payload))
			p2p_connection_established.emit(data)
		Constants.JS_EVENT_P2P_CONNECTION_FAILED:
			var data = JSON.parse_string(payload)
			_log("P2P connection failed: %s" % str(payload))
			p2p_connection_failed.emit(data)
		Constants.JS_EVENT_P2P_PEER_DISCONNECTED:
			var data = JSON.parse_string(payload)
			_log("P2P peer disconnected: %s" % str(payload))
			p2p_peer_disconnected.emit(data)
		Constants.JS_EVENT_P2P_PEER_RECONNECTING:
			var data = JSON.parse_string(payload)
			_log("P2P peer reconnecting: %s" % str(payload))
			p2p_peer_reconnecting.emit(data)
		Constants.JS_EVENT_P2P_PEER_RECONNECTED:
			var data = JSON.parse_string(payload)
			_log("P2P peer reconnected: %s" % str(payload))
			p2p_peer_reconnected.emit(data)
		Constants.JS_EVENT_P2P_PACKET_DROPPED:
			var data = JSON.parse_string(payload)
			_log("P2P packet dropped: %s" % str(payload))
			p2p_packet_dropped.emit(data)
		Constants.JS_EVENT_STATS_STORED:
			var data = JSON.parse_string(payload)
			_log("Stats stored: %s" % str(payload))
			stats_stored.emit(data)
		Constants.JS_EVENT_BACKEND_CONNECTED:
			var data = JSON.parse_string(payload)
			_log("Backend connected: %s" % str(payload))
			backend_connected.emit(data)
		Constants.JS_EVENT_BACKEND_RECONNECTING:
			var data = JSON.parse_string(payload)
			_log("Backend reconnecting: %s" % str(payload))
			backend_reconnecting.emit(data)
		Constants.JS_EVENT_BACKEND_DISCONNECTED:
			var data = JSON.parse_string(payload)
			_log("Backend disconnected: %s" % str(payload))
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
	
	# fromUserId (32 bytes, null-padded)
	var from_user_bytes = data.slice(offset, offset + 32)
	# Find first null byte to avoid Godot's Unicode warning when converting
	var null_pos = from_user_bytes.find(0)
	if null_pos != -1:
		from_user_bytes = from_user_bytes.slice(0, null_pos)
	result["identity"] = from_user_bytes.get_string_from_ascii()
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
