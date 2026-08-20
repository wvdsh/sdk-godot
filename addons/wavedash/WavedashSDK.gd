# Since this is an autoload, it's already a singleton
# Access it directly via the global WavedashSDK variable
extends Node

#region Events

signal lobby_joined(payload: WavedashTypes.LobbyJoinedPayload)
signal lobby_message(payload: WavedashTypes.LobbyMessage)
## The whole metadata map, re-sent in full on every change rather than as a delta.
## Values are String, number or bool. The platform writes its own keys
## (edgegapServer*) into the same map, so not every key is yours.
signal lobby_data_updated(payload: Dictionary)
signal lobby_users_updated(payload: WavedashTypes.LobbyUsersUpdatedPayload)
signal lobby_kicked(payload: WavedashTypes.LobbyKickedPayload)
signal lobby_invite(payload: WavedashTypes.LobbyInvite)

signal p2p_connection_established(payload: WavedashTypes.P2PConnectionEstablishedPayload)
signal p2p_connection_failed(payload: WavedashTypes.P2PConnectionFailedPayload)
signal p2p_peer_disconnected(payload: WavedashTypes.P2PPeerDisconnectedPayload)
signal p2p_peer_reconnecting(payload: WavedashTypes.P2PPeerReconnectingPayload)
signal p2p_peer_reconnected(payload: WavedashTypes.P2PPeerReconnectedPayload)
signal p2p_packet_dropped(payload: WavedashTypes.P2PPacketDroppedPayload)

signal stats_stored(payload: WavedashTypes.StatsStoredPayload)

signal backend_connected(payload: WavedashTypes.BackendConnectionPayload)
signal backend_reconnecting(payload: WavedashTypes.BackendConnectionPayload)
signal backend_disconnected(payload: WavedashTypes.BackendConnectionPayload)

signal fullscreen_changed(payload: WavedashTypes.FullscreenChangedPayload)
signal mute_changed(payload: WavedashTypes.MuteChangedPayload)

## Content the player was granted outside the game. `content_identifiers` is the newly
## granted set, not the full one, and the JWT is refreshed first, so fetch_entitlement()
## already answers true for each.
signal entitlements_granted(payload: WavedashTypes.EntitlementsGrantedPayload)

## `texture` is null if the fetch failed. Answers a call you made, but stays out
## of the deprecated group below: it has never carried an envelope.
signal user_avatar_loaded(texture: Texture2D, user_id: String)

## `download` is null if it failed. Same exception as above — it never went
## through _invoke_js, so there is no envelope to keep emitting.
signal content_downloaded(download: WavedashTypes.ContentDownload, item_path: String)

#endregion

#region DEPRECATED Events

# Await the call instead; these will be removed in a future major version. The
# payload is still the raw {success, data, message} Dictionary, so 1.x code keeps
# running. Two calls in flight on one signal produce indistinguishable emits.

signal lobby_created(payload)
signal lobby_left(payload)
signal sent_lobby_invite(payload)
signal got_lobby_invite_link(payload)
signal got_lobbies(payload)
signal got_lobby(payload)
signal got_leaderboard(payload)
signal got_leaderboard_entries(payload)
signal posted_leaderboard_score(payload)
signal ugc_item_created(payload)
signal ugc_item_updated(payload)
signal ugc_item_downloaded(payload)
signal ugc_item_deleted(payload)
signal got_ugc_items(payload)
signal remote_file_downloaded(payload)
signal remote_file_uploaded(payload)
signal remote_file_deleted(payload)
signal got_remote_file_exists(payload)
signal remote_directory_downloaded(payload)
signal got_remote_directory_listing(payload)
signal current_stats_received(payload)
signal got_friends(payload)
signal got_user_jwt(payload)
signal user_presence_updated(payload)
signal got_is_entitled(payload)
signal got_entitlements(payload)
signal paywall_resolved(payload)

#endregion

#region Private Members

const Envelope = preload("WavedashEnvelope.gd")
const LobbyCache = preload("WavedashLobbyCache.gd")
const PendingRequests = preload("WavedashPendingRequests.gd")

const _ENGINE_GODOT = "GODOT"

const _FULLSCREEN_DECLINED = (
	"the host would not apply it. Entering fullscreen has to happen inside a "
	+ "user-gesture handler, and there is no launcher to ask outside the Wavedash frame."
)
const _MUTE_DECLINED = (
	"the host would not apply it. The player may have muted from the Wavedash UI, "
	+ "which a game cannot override."
)

# gdlint: ignore=class-variable-name
var WavedashJS : JavaScriptObject
var _is_web : bool = OS.has_feature("web")

var _cached_user : WavedashTypes.SDKUser = null
var _user_id : String = ""
var _username : String = ""
var _entered_tree: bool = false

var _last_error: Error = OK
var _last_error_message: String = ""
var _last_content_identifiers: PackedStringArray = PackedStringArray()

var _builds_origin : String = ""

var _lobby := LobbyCache.new()

var _p2p_outgoing_buffer : JavaScriptObject
var _p2p_outgoing_buffer_size : int = 0

var _has_js_buffer_transfer : bool = false
var _eval_returns_byte_array : bool = false

var _js_callback_receiver : JavaScriptObject

var _pending := PendingRequests.new()
var _reported_once: Dictionary = {}

#endregion

#region Enter Tree

func _enter_tree() -> void:
	_log("_enter_tree() called, platform: %s" % OS.get_name())
	_entered_tree = true
	if _is_web:
		# Read before the WavedashJS guard below: download_content() is a plain fetch
		# against this origin and stays usable even when the interface is missing.
		var origin = JavaScriptBridge.eval("location.origin")
		if origin is String:
			_builds_origin = origin
		WavedashJS = JavaScriptBridge.get_interface("WavedashJS")
		if not WavedashJS:
			push_error("WavedashSDK: WavedashJS not found on window")
			return
		if WavedashJS.engineInstance == null:
			push_error("WavedashSDK: the page never called setEngineInstance(), so no "
				+ "events can reach this game. The Wavedash entrypoint normally does this "
				+ "before starting the engine, so please report it with your game id. If "
				+ "you supplied a custom entrypoint, it must call "
				+ "window.Wavedash.setEngineInstance({ type: 'GODOT' }) before "
				+ "engine.startGame().")
			WavedashJS = null
			return
		_js_callback_receiver = JavaScriptBridge.create_callback(_dispatch_js_event)
		WavedashJS.engineInstance["type"] = _ENGINE_GODOT
		WavedashJS.engineInstance["SendMessage"] = _js_callback_receiver
		JavaScriptBridge.eval("window.WavedashJS.engineInstance.FS = FS;")
		_has_js_buffer_transfer = JavaScriptBridge.has_method("js_buffer_to_packed_byte_array")
		if not _has_js_buffer_transfer:
			_eval_returns_byte_array = JavaScriptBridge.eval("new Uint8Array([1,2,3])") is PackedByteArray

#endregion

#region Error Handling

func _log(msg: String) -> void:
	if OS.is_debug_build():
		print("[WavedashSDK] ", msg)

func _fail_envelope(error: Error, message: String) -> Envelope:
	var env := Envelope.new()
	env.error = error
	env.message = message
	return env

func _succeed_envelope(data) -> Envelope:
	var env := Envelope.new()
	env.error = OK
	env.data = data
	return env

func _web_unsupported(method_name: String) -> Envelope:
	return _fail_envelope(ERR_UNAVAILABLE, "%s is only supported in Web builds" % method_name)

## sdk-js's CONVEX_ID_REGEX, /^[0-9a-z]{31,37}$/.
func _is_convex_id(id: String) -> bool:
	if id.length() < 31 or id.length() > 37:
		return false
	for c in id.to_utf8_buffer():
		var is_digit := c >= 48 and c <= 57
		var is_lower := c >= 97 and c <= 122
		if not (is_digit or is_lower):
			return false
	return true

## Shape only. A bad id must not reach a synchronous call: apiCallSync() rethrows it, and
## the throw unwinds the GDScript function mid-call. Every id-taking call runs this.
func _stamped_bad_id_error(id: String, func_name: String) -> bool:
	if id.is_empty():
		_set_last_error(_fail_envelope(ERR_INVALID_PARAMETER,
			"%s: called with an empty id" % func_name))
		return true
	if not _is_convex_id(id):
		_set_last_error(_fail_envelope(ERR_INVALID_PARAMETER,
			"%s: '%s' is not a valid id (expected 31-37 chars of 0-9a-z)" % [func_name, id]))
		return true
	return false

## A key that holds another type is a caller bug, so it says what is actually there
## rather than answering a silent null.
func _stamped_wrong_type(func_name: String, key: String, wanted: String, held) -> void:
	_set_last_error(_fail_envelope(ERR_INVALID_DATA,
		"%s: '%s' holds %s (%s), not %s" % [
			func_name, key, str(held), type_string(typeof(held)), wanted]))

## The sync bridge yields null when the page threw. None of the JS getters behind these
## can legitimately answer null, so a null is a failed read rather than an absent value.
func _stamped_no_answer(func_name: String) -> void:
	_set_last_error(_fail_envelope(FAILED, "%s: the page did not answer" % func_name))

## The page declares these bool, so anything else is a failed read rather than something
## to coerce: bool("false") is true.
func _bool_box(result: Variant, func_name: String) -> WavedashTypes.BoolOptional:
	if result == null:
		_stamped_no_answer(func_name)
		return null
	if not (result is bool):
		_set_last_error(_fail_envelope(ERR_INVALID_DATA,
			"%s: the page answered %s (%s), not a bool" % [
				func_name, str(result), type_string(typeof(result))]))
		return null
	clear_last_error()
	var box := WavedashTypes.BoolOptional.new()
	box.bool_value = result
	return box

func _invalid_path_error(path: String, func_name: String) -> Envelope:
	return _fail_envelope(ERR_FILE_BAD_PATH,
		"%s: path must start with 'user://' or %s. Got: '%s'"
			% [func_name, OS.get_user_data_dir(), path])

func _set_last_error(env: Envelope) -> void:
	_last_error = env.error
	_last_error_message = env.message if not env.ok() else ""
	if not env.ok() and _last_error_message.is_empty():
		_last_error_message = error_string(_last_error)
	if not env.ok() and _should_report(env.error, _last_error_message):
		push_error("[WavedashSDK] " + _last_error_message)
	# Cleared here so a stale list cannot outlive the error it belonged to;
	# download_content refills it after stamping.
	_last_content_identifiers = PackedStringArray()

## ERR_UNAVAILABLE and ERR_DOES_NOT_EXIST are read in loops, so they reach the console
## once per message. The slot is still written every call.
func _should_report(code: Error, message: String) -> bool:
	if not (code == ERR_UNAVAILABLE or code == ERR_DOES_NOT_EXIST):
		return true
	if _reported_once.has(message):
		return false
	_reported_once[message] = true
	return true

## True when it stamped, so the caller bails. Async paths build the same envelope and
## hand it to _emit_response() instead, so the deprecated signal carries it too.
func _stamped_unavailable_error(func_name: String) -> bool:
	if is_available():
		return false
	_set_last_error(_web_unsupported(func_name))
	return true

func _emit_response(env: Envelope, sig: Signal) -> void:
	_set_last_error(env)
	sig.emit(env.to_legacy_dict())

## The outcome of the most recently completed call: OK, or an @GlobalScope.Error.
##
## One slot shared by every call, so read it on the line after the await that
## produced it. Signal handlers should read `success`/`message` off the payload
## instead — by the time one runs, the slot may belong to a different call.
func get_last_error() -> Error:
	return _last_error

## Why the last call failed, in human-readable form. "" when the last call
## succeeded, and never empty when get_last_error() is not OK.
func get_last_error_message() -> String:
	return _last_error_message

## What the player must own for the last download_content() call to be allowed.
## Only ever non-empty right after that call fails with ERR_UNAUTHORIZED; pass one
## of these to trigger_paywall(). Read it on the line after the await, like
## get_last_error().
func get_last_content_identifiers() -> PackedStringArray:
	return _last_content_identifiers

## Reset the error state to OK. Never required: any call that can stamp an error
## also clears it on success, so the next such call overwrites this either way.
func clear_last_error() -> void:
	_last_error = OK
	_last_error_message = ""
	_last_content_identifiers = PackedStringArray()

#endregion

#region Initialization

## Initializes the SDK. False if the page refused — already initialised, or it
## rejected the config. init() is also what flushes the event queue, so a refusal
## means no event ever reaches the game.
func init(config: WavedashTypes.WavedashConfig = null) -> bool:
	assert(_entered_tree, "WavedashSDK.init() called before WavedashSDK was added to the tree")
	if _stamped_unavailable_error("init"):
		return false
	var payload: Dictionary = {} if config == null else config.to_dict()
	if WavedashJS.init(JSON.stringify(payload)) != true:
		_set_last_error(_fail_envelope(FAILED,
			"init() was refused by the page: already initialised, or the config was rejected"))
		return false
	clear_last_error()
	return true

## Whether the SDK can reach the host page: a Web build with WavedashJS present on
## the window. A build-level fact, so ask it once at startup and branch on it.
func is_available() -> bool:
	return _is_web and WavedashJS != null

## Signal that the game is ready to receive events (LobbyJoined, LobbyMessage, etc).
## Called automatically by init() unless deferEvents is set to true in the config.
## If deferEvents is true, call this manually after your pre-game setup is complete.
func ready_for_events() -> void:
	if is_available():
		WavedashJS.readyForEvents()
		clear_last_error()

## Returns the launch params that were passed via URL when the game was launched.
## {"lobby": "lobbyId123"}
##
## An open record upstream, so there is no shape to generate. Values are Strings;
## "lobby" is the only key the platform guarantees.
##
## The one place in the SDK where an empty answer is not distinguishable from a
## failed one: {} means launched with no params, and equally off-web or a blob that
## did not parse. A Dictionary cannot be null, so there is nothing to hand back
## instead. Ask is_available() once at startup rather than reading {} as an error.
func get_launch_params() -> Dictionary:
	if _stamped_unavailable_error("get_launch_params"):
		return {}
	var result = WavedashJS.getLaunchParams()
	if not result:
		clear_last_error()
		return {}
	# JSON.new().parse() rather than parse_string(): the latter ERR_PRINTs on junk,
	# which would double up with the stamp below.
	var json := JSON.new()
	if json.parse(str(result)) != OK or not (json.data is Dictionary):
		_set_last_error(_fail_envelope(FAILED,
			"get_launch_params: the page did not return a JSON object"))
		return {}
	clear_last_error()
	return json.data
#endregion

#region Overlay, Fullscreen and Mute

func toggle_overlay() -> void:
	if is_available():
		WavedashJS.toggleOverlay()
		clear_last_error()

## Mirrored from the Wavedash host page, which owns the real fullscreen target.
## Null when the page could not answer.
func try_get_fullscreen() -> WavedashTypes.BoolOptional:
	if _stamped_unavailable_error("try_get_fullscreen"):
		return null
	return _bool_box(WavedashJS.isFullscreen(), "try_get_fullscreen")

## Off-web, a rejected promise, and a host that would not apply the change are all
## failures: each stamps and answers false.
func _host_change_applied(env: Envelope, func_name: String, declined: String) -> bool:
	if not env.ok():
		_set_last_error(env)
		return false
	if not bool(env.data):
		_set_last_error(_fail_envelope(FAILED, "%s: %s" % [func_name, declined]))
		return false
	clear_last_error()
	return true

## Ask the host page to enter (true) or exit (false) fullscreen.
## Entering must happen inside a user-gesture handler (e.g. an InputEvent
## triggered by a keypress or mouse click) for the browser to permit it.
## True when the change was applied; false means it was not, and the error slot says why.
func request_fullscreen(fullscreen: bool) -> bool:
	if _stamped_unavailable_error("request_fullscreen"):
		return false
	var env := await _invoke_js_raw(WavedashJS.requestFullscreen(fullscreen), "request_fullscreen")
	return _host_change_applied(env, "request_fullscreen", _FULLSCREEN_DECLINED)

## Toggle fullscreen. Like request_fullscreen(true), this must run inside a
## user-gesture handler when entering fullscreen.
## True when the change was applied; false means it was not, and the error slot says why.
func request_fullscreen_toggle() -> bool:
	if _stamped_unavailable_error("request_fullscreen_toggle"):
		return false
	var env := await _invoke_js_raw(WavedashJS.toggleFullscreen(), "request_fullscreen_toggle")
	return _host_change_applied(env, "request_fullscreen_toggle", _FULLSCREEN_DECLINED)

## Mirrored from the Wavedash host page, which owns the mute control.
## Null when the page could not answer.
func try_get_muted() -> WavedashTypes.BoolOptional:
	if _stamped_unavailable_error("try_get_muted"):
		return null
	return _bool_box(WavedashJS.isMuted(), "try_get_muted")

## Ask the host to mute (true) or unmute (false).
## True when the change was applied; false means it was not, and the error slot says why —
## most often that the player muted from the Wavedash UI, which a game cannot override.
func request_mute(muted: bool) -> bool:
	if _stamped_unavailable_error("request_mute"):
		return false
	var env := await _invoke_js_raw(WavedashJS.requestMute(muted), "request_mute")
	return _host_change_applied(env, "request_mute", _MUTE_DECLINED)

## Toggle mute.
## True when the change was applied; false means it was not, and the error slot says why.
func request_mute_toggle() -> bool:
	if _stamped_unavailable_error("request_mute_toggle"):
		return false
	var env := await _invoke_js_raw(WavedashJS.toggleMute(), "request_mute_toggle")
	return _host_change_applied(env, "request_mute_toggle", _MUTE_DECLINED)

#endregion

#region User and Friends

func _fetch_user() -> WavedashTypes.SDKUser:
	if _cached_user != null:
		return _cached_user
	if _stamped_unavailable_error("get_user"):
		return null
	return _read_user()

func _read_user() -> WavedashTypes.SDKUser:
	var parsed = JSON.parse_string(WavedashJS.getUser())
	if not (parsed is Dictionary):
		push_warning("[WavedashSDK] getUser() did not return a JSON object")
		return null
	# An empty object is a failed fetch, not a user with a blank id, so leave the
	# cache unset and retry on the next call.
	if parsed.is_empty():
		return null
	_cached_user = WavedashTypes.SDKUser.from_dict(parsed)
	_user_id = _cached_user.id
	_username = _cached_user.username
	return _cached_user

## Returns the current Wavedash user, or `null` when there isn't one to return:
## off-web, before the SDK has finished loading, or if the fetch failed. Cached
## after the first successful call.
func get_user() -> WavedashTypes.SDKUser:
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
		if _stamped_bad_id_error(user_id, "get_username"):
			return ""
		if _stamped_unavailable_error("get_username"):
			return ""
		# Narrow before testing: on 4.0 `not <String>` is an invalid operand pair,
		# which aborts the caller in a debug export and is skipped in release.
		var result = WavedashJS.getUsername(user_id)
		var username: String = result if result is String else ""
		if username.is_empty():
			_set_last_error(_fail_envelope(ERR_DOES_NOT_EXIST,
				"get_username: no user cached for '%s'" % user_id))
			return ""
		clear_last_error()
		return username
	if _username == "":
		_fetch_user()
	return _username

## Returns the current user's gameplay JWT, fetching it if not already cached.
## Use this to authenticate requests to your game's own backend, if you have one.
## `string_value` is the JWT string.
func fetch_user_jwt() -> WavedashTypes.StringOptional:
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.getUserJwt())
	else:
		env = _web_unsupported("fetch_user_jwt")
	_emit_response(env, got_user_jwt)
	if not env.ok():
		return null
	return WavedashTypes.StringOptional.from_data(env.data)

## Returns the CDN URL for a cached user's avatar with size transformation.
## Users are cached when seen via friends list or lobby membership.
## Returns empty string if user not cached or has no avatar.
func get_user_avatar_url(user_id_to_fetch: String, size: int = WavedashTypes.AVATAR_SIZE_MEDIUM) -> String:
	if _stamped_bad_id_error(user_id_to_fetch, "get_user_avatar_url"):
		return ""
	if _stamped_unavailable_error("get_user_avatar_url"):
		return ""
	var result = WavedashJS.getUserAvatarUrl(user_id_to_fetch, size)
	var url: String = result if result is String else ""
	if url.is_empty():
		_set_last_error(_fail_envelope(ERR_DOES_NOT_EXIST,
			"get_user_avatar_url: no avatar cached for '%s'" % user_id_to_fetch))
		return ""
	clear_last_error()
	return url
## Dispatched on magic bytes: the CDN serves whatever the source object was, so
## probing each loader in turn logs an engine error for every miss.
func _load_image(image: Image, body: PackedByteArray) -> Error:
	if body.size() >= 8 and body[0] == 0x89 and body[1] == 0x50 and body[2] == 0x4E and body[3] == 0x47:
		return image.load_png_from_buffer(body)
	if body.size() >= 3 and body[0] == 0xFF and body[1] == 0xD8 and body[2] == 0xFF:
		return image.load_jpg_from_buffer(body)
	if body.size() >= 12 and body[0] == 0x52 and body[1] == 0x49 and body[2] == 0x46 and body[3] == 0x46:
		return image.load_webp_from_buffer(body)
	var err := image.load_png_from_buffer(body)
	if err != OK:
		err = image.load_jpg_from_buffer(body)
	if err != OK:
		err = image.load_webp_from_buffer(body)
	return err

## Null if the user isn't cached or the fetch failed. Also emits user_avatar_loaded.
func fetch_user_avatar(user_id_to_fetch: String, size: int = WavedashTypes.AVATAR_SIZE_MEDIUM) -> Texture2D:
	var url = get_user_avatar_url(user_id_to_fetch, size)
	if url.is_empty():
		user_avatar_loaded.emit(null, user_id_to_fetch)
		return null

	var http = HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	var error = http.request(url)
	if error != OK:
		_set_last_error(_fail_envelope(ERR_CANT_CONNECT,
			"fetch_user_avatar: could not start the request for '%s'" % user_id_to_fetch))
		http.queue_free()
		user_avatar_loaded.emit(null, user_id_to_fetch)
		return null

	var response = await http.request_completed
	http.queue_free()
	var result: int = response[0]
	var response_code: int = response[1]
	var body: PackedByteArray = response[3]

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_set_last_error(_fail_envelope(ERR_CANT_CONNECT,
			"fetch_user_avatar: fetch failed for '%s' (result %d, HTTP %d)"
				% [user_id_to_fetch, result, response_code]))
		user_avatar_loaded.emit(null, user_id_to_fetch)
		return null

	var image := Image.new()
	var err := _load_image(image, body)
	if err != OK:
		_set_last_error(_fail_envelope(ERR_FILE_CORRUPT,
			"fetch_user_avatar: '%s' decoded as neither PNG, JPG nor WebP" % user_id_to_fetch))
		user_avatar_loaded.emit(null, user_id_to_fetch)
		return null

	var texture = ImageTexture.create_from_image(image)
	clear_last_error()
	user_avatar_loaded.emit(texture, user_id_to_fetch)
	return texture

## Lists the current user's friends.
## `friends` is an Array[WavedashTypes.Friend].
## Friends are automatically cached for avatar lookups via get_user_avatar_url/fetch_user_avatar.
func list_friends() -> WavedashTypes.FriendListOptional:
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.listFriends())
	else:
		env = _web_unsupported("list_friends")
	_emit_response(env, got_friends)
	if not env.ok():
		return null
	return WavedashTypes.FriendListOptional.from_data(env.data)

#endregion

#region Leaderboards

func fetch_leaderboard(leaderboard_name: String) -> WavedashTypes.Leaderboard:
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.getLeaderboard(leaderboard_name))
	else:
		env = _web_unsupported("fetch_leaderboard")
	_emit_response(env, got_leaderboard)
	if not env.ok():
		return null
	return WavedashTypes.Leaderboard.from_dict(env.data)

func fetch_or_create_leaderboard(
	leaderboard_name: String,
	sort_method: WavedashTypes.LeaderboardSortOrder,
	display_type: WavedashTypes.LeaderboardDisplayType
) -> WavedashTypes.Leaderboard:
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.getOrCreateLeaderboard(leaderboard_name, sort_method, display_type))
	else:
		env = _web_unsupported("fetch_or_create_leaderboard")
	_emit_response(env, got_leaderboard)
	if not env.ok():
		return null
	return WavedashTypes.Leaderboard.from_dict(env.data)

func list_my_leaderboard_entries(leaderboard_id: String) -> WavedashTypes.LeaderboardEntryListOptional:
	if _stamped_bad_id_error(leaderboard_id, "list_my_leaderboard_entries"):
		return null
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.getMyLeaderboardEntries(leaderboard_id))
	else:
		env = _web_unsupported("list_my_leaderboard_entries")
	_emit_response(env, got_leaderboard_entries)
	if not env.ok():
		return null
	return WavedashTypes.LeaderboardEntryListOptional.from_data(env.data)

## -1 if an error occurred. Check `count < 0`, not truthiness: `0` is a leaderboard with
## no entries, which is a real answer.
func get_leaderboard_entry_count(leaderboard_id: String) -> int:
	if _stamped_bad_id_error(leaderboard_id, "get_leaderboard_entry_count"):
		return -1
	if _stamped_unavailable_error("get_leaderboard_entry_count"):
		return -1
	var result = WavedashJS.getLeaderboardEntryCount(leaderboard_id)
	clear_last_error()
	return int(result) if result != null else -1

func list_leaderboard_entries_around_player(leaderboard_id: String, count_ahead: int, count_behind: int, friends_only: bool) -> WavedashTypes.LeaderboardEntryListOptional:
	if _stamped_bad_id_error(leaderboard_id, "list_leaderboard_entries_around_player"):
		return null
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.listLeaderboardEntriesAroundUser(leaderboard_id, count_ahead, count_behind, friends_only))
	else:
		env = _web_unsupported("list_leaderboard_entries_around_player")
	_emit_response(env, got_leaderboard_entries)
	if not env.ok():
		return null
	return WavedashTypes.LeaderboardEntryListOptional.from_data(env.data)

func list_leaderboard_entries(leaderboard_id: String, offset: int, limit: int, friends_only: bool) -> WavedashTypes.LeaderboardEntryListOptional:
	if _stamped_bad_id_error(leaderboard_id, "list_leaderboard_entries"):
		return null
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.listLeaderboardEntries(leaderboard_id, offset, limit, friends_only))
	else:
		env = _web_unsupported("list_leaderboard_entries")
	_emit_response(env, got_leaderboard_entries)
	if not env.ok():
		return null
	return WavedashTypes.LeaderboardEntryListOptional.from_data(env.data)

## Submit a score. Pass ugc_id to attach a UGC item (e.g. a replay), or "" for none;
## store anything large as UGC rather than in metadata, which takes String, int, float
## and bool values only.
##
## Metadata belongs to the score it was submitted with: a written score replaces it,
## an empty dictionary clears it, and a score keep_best rejects leaves it untouched.
func post_leaderboard_score(leaderboard_id: String, score: float, keep_best: bool, ugc_id: String = "", metadata: Dictionary = {}) -> WavedashTypes.UpsertedLeaderboardEntry:
	if _stamped_bad_id_error(leaderboard_id, "post_leaderboard_score"):
		return null
	# Empty means no UGC attached, so only a supplied one is checked.
	if not ugc_id.is_empty() and _stamped_bad_id_error(ugc_id, "post_leaderboard_score"):
		return null
	var env: Envelope
	if is_available():
		if not metadata.is_empty():
			# metadata is the fifth argument, so ugc_id can no longer be omitted by
			# arity; the page reads null as omitted. JSON as a string because a
			# Dictionary does not marshal.
			var js_ugc_id = ugc_id if not ugc_id.is_empty() else null
			env = await _invoke_js(WavedashJS.uploadLeaderboardScore(
				leaderboard_id, score, keep_best, js_ugc_id, JSON.stringify(metadata)))
		elif ugc_id.is_empty():
			env = await _invoke_js(WavedashJS.uploadLeaderboardScore(leaderboard_id, score, keep_best))
		else:
			env = await _invoke_js(WavedashJS.uploadLeaderboardScore(leaderboard_id, score, keep_best, ugc_id))
	else:
		env = _web_unsupported("post_leaderboard_score")
	_emit_response(env, posted_leaderboard_score)
	if not env.ok():
		return null
	return WavedashTypes.UpsertedLeaderboardEntry.from_dict(env.data)

#endregion

#region Remote File Storage

func _normalize_user_path(path: String) -> String:
	if path.begins_with("user://"):
		var subpath = path.substr(7)
		if subpath.is_empty():
			return OS.get_user_data_dir()
		return OS.get_user_data_dir().rstrip("/") + "/" + subpath
	return path

func _validate_user_data_path(path: String) -> bool:
	# No push_error here: the caller turns a false into _invalid_path_error(), and
	# _set_last_error() is what reports it. Printing here too would double up.
	if not path.begins_with(OS.get_user_data_dir()):
		return false
	return true

func download_remote_directory(path: String) -> WavedashTypes.StringOptional:
	path = _normalize_user_path(path)
	var env: Envelope
	if is_available():
		if _validate_user_data_path(path):
			env = await _invoke_js(WavedashJS.downloadRemoteDirectory(path))
		else:
			env = _invalid_path_error(path, "download_remote_directory")
	else:
		env = _web_unsupported("download_remote_directory")
	_emit_response(env, remote_directory_downloaded)
	if not env.ok():
		return null
	return WavedashTypes.StringOptional.from_data(env.data)

## Lists entries in a remote directory without downloading them. `remote_file_metadatas`
## holds them. Path must be under user:// or OS.get_user_data_dir().
func list_remote_directory(path: String) -> WavedashTypes.RemoteFileMetadataListOptional:
	path = _normalize_user_path(path)
	var env: Envelope
	if is_available():
		if _validate_user_data_path(path):
			env = await _invoke_js(WavedashJS.listRemoteDirectory(path))
		else:
			env = _invalid_path_error(path, "list_remote_directory")
	else:
		env = _web_unsupported("list_remote_directory")
	_emit_response(env, got_remote_directory_listing)
	if not env.ok():
		return null
	return WavedashTypes.RemoteFileMetadataListOptional.from_data(env.data)

func download_remote_file(file_path: String) -> WavedashTypes.StringOptional:
	file_path = _normalize_user_path(file_path)
	var env: Envelope
	if is_available():
		if _validate_user_data_path(file_path):
			env = await _invoke_js(WavedashJS.downloadRemoteFile(file_path))
		else:
			env = _invalid_path_error(file_path, "download_remote_file")
	else:
		env = _web_unsupported("download_remote_file")
	_emit_response(env, remote_file_downloaded)
	if not env.ok():
		return null
	return WavedashTypes.StringOptional.from_data(env.data)

## Does this file exist in remote storage? A HEAD request, so you can branch on whether a
## save is there without paying for the download. Not a required preflight —
## download_remote_file() answers null with "404 (Not Found)" on its own.
##
## `bool_value` is true when it exists; false means it is not there. Only null is a failed
## check, so read the field rather than testing the box — a box holding false is truthy.
## Path must be under user:// or OS.get_user_data_dir().
func check_remote_file(file_path: String) -> WavedashTypes.BoolOptional:
	file_path = _normalize_user_path(file_path)
	var env: Envelope
	if is_available():
		if _validate_user_data_path(file_path):
			env = await _invoke_js(WavedashJS.remoteFileExists(file_path))
		else:
			env = _invalid_path_error(file_path, "check_remote_file")
	else:
		env = _web_unsupported("check_remote_file")
	_emit_response(env, got_remote_file_exists)
	if not env.ok():
		return null
	return WavedashTypes.BoolOptional.from_data(env.data)

func upload_remote_file(file_path: String) -> WavedashTypes.StringOptional:
	file_path = _normalize_user_path(file_path)
	var env: Envelope
	if is_available():
		if _validate_user_data_path(file_path):
			env = await _invoke_js(WavedashJS.uploadRemoteFile(file_path))
		else:
			env = _invalid_path_error(file_path, "upload_remote_file")
	else:
		env = _web_unsupported("upload_remote_file")
	_emit_response(env, remote_file_uploaded)
	if not env.ok():
		return null
	return WavedashTypes.StringOptional.from_data(env.data)

## Deletes a remote file from cloud storage.
## Path must be under user:// or OS.get_user_data_dir().
## `string_value` is the deleted file's path.
func delete_remote_file(file_path: String) -> WavedashTypes.StringOptional:
	file_path = _normalize_user_path(file_path)
	var env: Envelope
	if is_available():
		if _validate_user_data_path(file_path):
			env = await _invoke_js(WavedashJS.deleteRemoteFile(file_path))
		else:
			env = _invalid_path_error(file_path, "delete_remote_file")
	else:
		env = _web_unsupported("delete_remote_file")
	_emit_response(env, remote_file_deleted)
	if not env.ok():
		return null
	return WavedashTypes.StringOptional.from_data(env.data)

#endregion

#region Lobbies

## Creates a lobby. `string_value` is the new lobby's id. Leave `max_players` at 0 to accept
## the platform default — it is then omitted rather than sent, since sdk-js counts
## only `undefined` as absent and rejects the JS null that GDScript null marshals to.
func create_lobby(visibility: WavedashTypes.LobbyVisibility, max_players: int = 0) -> WavedashTypes.StringOptional:
	var env: Envelope
	if is_available():
		if max_players <= 0:
			env = await _invoke_js(WavedashJS.createLobby(visibility))
		else:
			env = await _invoke_js(WavedashJS.createLobby(visibility, max_players))
	else:
		env = _web_unsupported("create_lobby")
	_emit_response(env, lobby_created)
	if not env.ok():
		return null
	var response := WavedashTypes.StringOptional.from_data(env.data)
	_lobby.joined(response.string_value, _user_id)
	return response

## False if the request was refused. A command, so there is no third answer to box: the
## page either took the request or it did not.
## Connect to lobby_joined for the full payload once the server confirms the join.
func join_lobby(lobby_id: String) -> bool:
	if _stamped_bad_id_error(lobby_id, "join_lobby"):
		return false
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.joinLobby(lobby_id))
	else:
		env = _web_unsupported("join_lobby")
	# No signal: lobby_joined is the server's confirmation event, not this answer.
	_set_last_error(env)
	return env.ok()

func leave_lobby(lobby_id: String) -> WavedashTypes.StringOptional:
	if _stamped_bad_id_error(lobby_id, "leave_lobby"):
		return null
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.leaveLobby(lobby_id))
	else:
		env = _web_unsupported("leave_lobby")
	_emit_response(env, lobby_left)
	if not env.ok():
		return null
	var response := WavedashTypes.StringOptional.from_data(env.data)
	_lobby.left(response.string_value)
	return response

func list_available_lobbies() -> WavedashTypes.LobbyListOptional:
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.listAvailableLobbies())
	else:
		env = _web_unsupported("list_available_lobbies")
	_emit_response(env, got_lobbies)
	if not env.ok():
		return null
	return WavedashTypes.LobbyListOptional.from_data(env.data)

## Fetches a lobby by ID, including its visibility, player count and metadata.
## Returns the lobby itself, so read it directly — there is no box to unwrap.
func fetch_lobby(lobby_id: String) -> WavedashTypes.Lobby:
	if _stamped_bad_id_error(lobby_id, "fetch_lobby"):
		return null
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.getLobby(lobby_id))
	else:
		env = _web_unsupported("fetch_lobby")
	_emit_response(env, got_lobby)
	if not env.ok():
		return null
	return WavedashTypes.Lobby.from_dict(env.data)

func get_lobby_host_id(lobby_id: String) -> String:
	if _stamped_bad_id_error(lobby_id, "get_lobby_host_id"):
		return ""
	var cached := _lobby.host_for(lobby_id)
	if not cached.is_empty():
		clear_last_error()
		return cached
	if _stamped_unavailable_error("get_lobby_host_id"):
		return ""
	var result = WavedashJS.getLobbyHostId(lobby_id)
	var host_id: String = result if result is String else ""
	_lobby.remember_host(lobby_id, host_id)
	if host_id.is_empty():
		_set_last_error(_fail_envelope(ERR_DOES_NOT_EXIST,
			"get_lobby_host_id: no host cached for '%s'" % lobby_id))
		return ""
	clear_last_error()
	return host_id
func try_get_lobby_data_string(lobby_id: String, key: String) -> WavedashTypes.StringOptional:
	var result = _lobby_data_value(lobby_id, key, "try_get_lobby_data_string")
	if result == null:
		return null
	if not (result is String):
		_stamped_wrong_type("try_get_lobby_data_string", key, "String", result)
		return null
	var box := WavedashTypes.StringOptional.new()
	box.string_value = result
	return box

## A fractional value answers null: an int cannot round-trip it.
func try_get_lobby_data_int(lobby_id: String, key: String) -> WavedashTypes.IntOptional:
	var result = _lobby_data_value(lobby_id, key, "try_get_lobby_data_int")
	if result == null:
		return null
	# A JS number crosses the bridge as a float, so whole ones arrive as 12.0.
	if not (result is int or (result is float and result == floor(result))):
		_stamped_wrong_type("try_get_lobby_data_int", key, "int", result)
		return null
	var box := WavedashTypes.IntOptional.new()
	box.int_value = int(result)
	return box

func try_get_lobby_data_float(lobby_id: String, key: String) -> WavedashTypes.FloatOptional:
	var result = _lobby_data_value(lobby_id, key, "try_get_lobby_data_float")
	if result == null:
		return null
	if not (result is int or result is float):
		_stamped_wrong_type("try_get_lobby_data_float", key, "float", result)
		return null
	var box := WavedashTypes.FloatOptional.new()
	box.float_value = float(result)
	return box

func try_get_lobby_data_bool(lobby_id: String, key: String) -> WavedashTypes.BoolOptional:
	var result = _lobby_data_value(lobby_id, key, "try_get_lobby_data_bool")
	if result == null:
		return null
	if not (result is bool):
		_stamped_wrong_type("try_get_lobby_data_bool", key, "bool", result)
		return null
	var box := WavedashTypes.BoolOptional.new()
	box.bool_value = result
	return box

func _lobby_data_value(lobby_id: String, key: String, func_name: String) -> Variant:
	if _stamped_bad_id_error(lobby_id, func_name):
		return null
	if _stamped_unavailable_error(func_name):
		return null
	var raw = _read_lobby_data(lobby_id, key)
	if raw == null:
		_set_last_error(_fail_envelope(ERR_DOES_NOT_EXIST,
			"%s: lobby '%s' has no '%s' in its metadata" % [func_name, lobby_id, key]))
		return null
	clear_last_error()
	return raw

func _read_lobby_data(lobby_id: String, key: String) -> Variant:
	return WavedashJS.getLobbyData(lobby_id, key)

## A false from the page is a refused write, so it stamps — the same as every other
## command, including the host-page change requests.
func _lobby_write_applied(raw, func_name: String, lobby_id: String) -> bool:
	if not (raw is bool and raw):
		_set_last_error(_fail_envelope(FAILED,
			("%s: the page would not write to lobby '%s'. You may not be its host, "
				+ "or it may no longer exist.") % [func_name, lobby_id]))
		return false
	clear_last_error()
	return true

func set_lobby_data_string(lobby_id: String, key: String, value: String) -> bool:
	if _stamped_bad_id_error(lobby_id, "set_lobby_data_string"):
		return false
	if _stamped_unavailable_error("set_lobby_data_string"):
		return false
	return _lobby_write_applied(WavedashJS.setLobbyData(lobby_id, key, value),
		"set_lobby_data_string", lobby_id)

func set_lobby_data_int(lobby_id: String, key: String, value: int) -> bool:
	if _stamped_bad_id_error(lobby_id, "set_lobby_data_int"):
		return false
	if _stamped_unavailable_error("set_lobby_data_int"):
		return false
	return _lobby_write_applied(WavedashJS.setLobbyData(lobby_id, key, value),
		"set_lobby_data_int", lobby_id)

func set_lobby_data_float(lobby_id: String, key: String, value: float) -> bool:
	if _stamped_bad_id_error(lobby_id, "set_lobby_data_float"):
		return false
	if _stamped_unavailable_error("set_lobby_data_float"):
		return false
	return _lobby_write_applied(WavedashJS.setLobbyData(lobby_id, key, value),
		"set_lobby_data_float", lobby_id)

func set_lobby_data_bool(lobby_id: String, key: String, value: bool) -> bool:
	if _stamped_bad_id_error(lobby_id, "set_lobby_data_bool"):
		return false
	if _stamped_unavailable_error("set_lobby_data_bool"):
		return false
	return _lobby_write_applied(WavedashJS.setLobbyData(lobby_id, key, value),
		"set_lobby_data_bool", lobby_id)

func clear_lobby_data(lobby_id: String, key: String) -> bool:
	if _stamped_bad_id_error(lobby_id, "clear_lobby_data"):
		return false
	if _stamped_unavailable_error("clear_lobby_data"):
		return false
	return _lobby_write_applied(WavedashJS.deleteLobbyData(lobby_id, key),
		"clear_lobby_data", lobby_id)
## Null when the list could not be read; an empty list means an empty lobby.
func try_get_lobby_users(lobby_id: String) -> WavedashTypes.LobbyUserListOptional:
	if _stamped_bad_id_error(lobby_id, "try_get_lobby_users"):
		return null
	if _stamped_unavailable_error("try_get_lobby_users"):
		return null
	# Untyped: a null return would fail a typed assignment before the is-Array
	# check below.
	var result = WavedashJS.getLobbyUsers(lobby_id)
	_log("Got lobby users: %s" % str(result))
	var parsed = JSON.parse_string(result) if result else []
	if not (parsed is Array):
		_set_last_error(_fail_envelope(FAILED,
			"try_get_lobby_users: the page did not return a JSON array"))
		return null
	clear_last_error()
	var box := WavedashTypes.LobbyUserListOptional.new()
	for item in parsed:
		if item is Dictionary:
			box.lobby_users.append(WavedashTypes.LobbyUser.from_dict(item))
	return box

## -1 when the count could not be read, the same sentinel as
## get_leaderboard_entry_count(). A real count is never negative, so check `count < 0`
## rather than truthiness — `0` is an empty lobby, which is a real answer.
func get_num_lobby_users(lobby_id: String) -> int:
	if _stamped_bad_id_error(lobby_id, "get_num_lobby_users"):
		return -1
	if _stamped_unavailable_error("get_num_lobby_users"):
		return -1
	var result = WavedashJS.getNumLobbyUsers(lobby_id)
	clear_last_error()
	return int(result) if result != null else -1

func send_lobby_chat_message(lobby_id: String, message: String) -> bool:
	if _stamped_bad_id_error(lobby_id, "send_lobby_chat_message"):
		return false
	if _stamped_unavailable_error("send_lobby_chat_message"):
		return false
	# Fire and forget: the page answers whether it accepted the message, not whether
	# it was delivered. A false is a refusal worth stamping, like a lobby write —
	# not a considered "no" the way request_mute()'s false is.
	var sent = WavedashJS.sendLobbyMessage(lobby_id, message)
	if not (sent is bool and sent):
		_set_last_error(_fail_envelope(FAILED,
			("send_lobby_chat_message: the page would not send the message. "
				+ "It may be empty, or longer than the platform allows.")))
		return false
	clear_last_error()
	return true

## Sends a lobby invite notification to a user, who sees it as a lobby_invite event.
## False if the invite was not sent.
func invite_user_to_lobby(lobby_id: String, user_id_to_invite: String) -> bool:
	if _stamped_bad_id_error(lobby_id, "invite_user_to_lobby"):
		return false
	if _stamped_bad_id_error(user_id_to_invite, "invite_user_to_lobby"):
		return false
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.inviteUserToLobby(lobby_id, user_id_to_invite))
	else:
		env = _web_unsupported("invite_user_to_lobby")
	_emit_response(env, sent_lobby_invite)
	return env.ok()

## A shareable invite link for the lobby you are in. It takes no lobby id because a link
## can only be minted for your own lobby. Null if you are not in one, and null outside a
## Wavedash parent frame, where there is no launcher to mint it.
##
## When copy_to_clipboard is true, the launcher copies the link to the user's clipboard.
## `string_value` is the invite URL.
func fetch_lobby_invite_link(copy_to_clipboard: bool = false) -> WavedashTypes.StringOptional:
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.getLobbyInviteLink(copy_to_clipboard))
	else:
		env = _web_unsupported("fetch_lobby_invite_link")
	_emit_response(env, got_lobby_invite_link)
	if not env.ok():
		return null
	return WavedashTypes.StringOptional.from_data(env.data)

#endregion

#region User Generated Content

# TODO: Consider just passing along file data as PackedByteArray if it's small enough (< 5MB)
# Faster, no I/O, saves the file system sync overhead
## Creates a UGC item. `string_value` is the new item's id.
func create_ugc_item(
	ugc_type: WavedashTypes.UGCType,
	title: String = "",
	description: String = "",
	visibility: WavedashTypes.UGCVisibility = WavedashTypes.UGCVisibility.PUBLIC,
	local_file_path: String = ""
) -> WavedashTypes.StringOptional:
	if not local_file_path.is_empty():
		local_file_path = _normalize_user_path(local_file_path)
	var env: Envelope
	if is_available():
		if local_file_path.is_empty():
			env = await _invoke_js(WavedashJS.createUGCItem(ugc_type, title, description, visibility))
		elif not _validate_user_data_path(local_file_path):
			env = _invalid_path_error(local_file_path, "create_ugc_item")
		else:
			env = await _invoke_js(WavedashJS.createUGCItem(ugc_type, title, description, visibility, local_file_path))
	else:
		env = _web_unsupported("create_ugc_item")
	_emit_response(env, ugc_item_created)
	if not env.ok():
		return null
	return WavedashTypes.StringOptional.from_data(env.data)

## Updates an existing UGC item. Set only the fields you are changing — one left at its
## default is not sent, so `""` cannot blank a stored value. `string_value` is its id.
func update_ugc_item(ugc_id: String, updates: WavedashTypes.UpdateUGCItemArgs = null) -> WavedashTypes.StringOptional:
	if _stamped_bad_id_error(ugc_id, "update_ugc_item"):
		return null
	# Normalise on the serialised copy, not on `updates` — the caller owns that object.
	var payload: Dictionary = {} if updates == null else updates.to_dict()
	if payload.has("filePath"):
		payload["filePath"] = _normalize_user_path(payload["filePath"])
	var env: Envelope
	if is_available():
		if payload.has("filePath") and not _validate_user_data_path(payload["filePath"]):
			env = _invalid_path_error(payload["filePath"], "update_ugc_item")
		else:
			env = await _invoke_js(WavedashJS.updateUGCItem(ugc_id, JSON.stringify(payload)))
	else:
		env = _web_unsupported("update_ugc_item")
	_emit_response(env, ugc_item_updated)
	if not env.ok():
		return null
	return WavedashTypes.StringOptional.from_data(env.data)

## Deletes a UGC item: removes the item from the game's UGC collection and frees up the
## user's storage quota by the size of the deleted upload.
## `string_value` is the deleted item's id.
func delete_ugc_item(ugc_id: String) -> WavedashTypes.StringOptional:
	if _stamped_bad_id_error(ugc_id, "delete_ugc_item"):
		return null
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.deleteUGCItem(ugc_id))
	else:
		env = _web_unsupported("delete_ugc_item")
	_emit_response(env, ugc_item_deleted)
	if not env.ok():
		return null
	return WavedashTypes.StringOptional.from_data(env.data)

## Lists UGC items with optional filters and pagination.
## Set any of `created_by`, `ugc_type`, `title_search`, `num_items` on the args for
## the first page. For a subsequent page set ONLY `continue_cursor`.
func list_ugc_items(args: WavedashTypes.ListUGCItemsArgs = null) -> WavedashTypes.PaginatedUGCItems:
	var env: Envelope
	if is_available():
		var payload: Dictionary = {} if args == null else args.to_dict()
		env = await _invoke_js(WavedashJS.listUGCItems(JSON.stringify(payload)))
	else:
		env = _web_unsupported("list_ugc_items")
	_emit_response(env, got_ugc_items)
	if not env.ok():
		return null
	return WavedashTypes.PaginatedUGCItems.from_dict(env.data)

func download_ugc_item(ugc_id: String, local_file_path: String) -> WavedashTypes.StringOptional:
	if _stamped_bad_id_error(ugc_id, "download_ugc_item"):
		return null
	local_file_path = _normalize_user_path(local_file_path)
	var env: Envelope
	if is_available():
		if _validate_user_data_path(local_file_path):
			env = await _invoke_js(WavedashJS.downloadUGCItem(ugc_id, local_file_path))
		else:
			env = _invalid_path_error(local_file_path, "download_ugc_item")
	else:
		env = _web_unsupported("download_ugc_item")
	_emit_response(env, ugc_item_downloaded)
	if not env.ok():
		return null
	return WavedashTypes.StringOptional.from_data(env.data)

#endregion

#region Stats and Achievements

## Pulls this game's stats and achievements down so the try_get_* readers can answer.
## False if the fetch failed, which is the only outcome besides success.
func request_stats() -> bool:
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.requestStats())
	else:
		env = _web_unsupported("request_stats")
	_emit_response(env, current_stats_received)
	return env.ok()

func set_stat_int(stat_name: String, val: int, store_now: bool = false) -> bool:
	if _stamped_unavailable_error("set_stat_int"):
		return false
	var result = WavedashJS.setStat(stat_name, val, store_now)
	if not (result is bool and result):
		_set_last_error(_fail_envelope(FAILED, "set_stat_int: Stats may not have loaded yet, or the name is not one of this game's stats"))
		return false
	clear_last_error()
	return true

func set_stat_float(stat_name: String, val: float, store_now: bool = false) -> bool:
	if _stamped_unavailable_error("set_stat_float"):
		return false
	var result = WavedashJS.setStat(stat_name, val, store_now)
	if not (result is bool and result):
		_set_last_error(_fail_envelope(FAILED, "set_stat_float: Stats may not have loaded yet, or the name is not one of this game's stats"))
		return false
	clear_last_error()
	return true

func store_stats() -> bool:
	if _stamped_unavailable_error("store_stats"):
		return false
	var result = WavedashJS.storeStats()
	if not (result is bool and result):
		_set_last_error(_fail_envelope(FAILED, "store_stats: Stats may not have loaded yet"))
		return false
	clear_last_error()
	return true

## Null when the stat could not be read, and null for a fractional one: an int cannot
## round-trip 12.5, so it is not coerced. Use try_get_stat_float() for those.
func try_get_stat_int(stat_name: String) -> WavedashTypes.IntOptional:
	if _stamped_unavailable_error("try_get_stat_int"):
		return null
	var result = WavedashJS.getStat(stat_name)
	if result == null:
		_stamped_no_answer("try_get_stat_int")
		return null
	# A JS number crosses the bridge as a float, so whole ones arrive as 12.0.
	if not (result is int or (result is float and result == floor(result))):
		_stamped_wrong_type("try_get_stat_int", stat_name, "int", result)
		return null
	clear_last_error()
	var box := WavedashTypes.IntOptional.new()
	box.int_value = int(result)
	return box

## Null when the stat could not be read, or when it does not hold a number.
func try_get_stat_float(stat_name: String) -> WavedashTypes.FloatOptional:
	if _stamped_unavailable_error("try_get_stat_float"):
		return null
	var result = WavedashJS.getStat(stat_name)
	if result == null:
		_stamped_no_answer("try_get_stat_float")
		return null
	if not (result is int or result is float):
		_stamped_wrong_type("try_get_stat_float", stat_name, "float", result)
		return null
	clear_last_error()
	var box := WavedashTypes.FloatOptional.new()
	box.float_value = float(result)
	return box

func set_achievement(ach_name: String, store_now: bool = false) -> bool:
	if _stamped_unavailable_error("set_achievement"):
		return false
	var result = WavedashJS.setAchievement(ach_name, store_now)
	if not (result is bool and result):
		_set_last_error(_fail_envelope(FAILED, "set_achievement: Stats may not have loaded yet, or the name is not one of this game's achievements"))
		return false
	clear_last_error()
	return true

## Null when the achievement could not be read.
func try_get_achievement(ach_name: String) -> WavedashTypes.BoolOptional:
	if _stamped_unavailable_error("try_get_achievement"):
		return null
	return _bool_box(WavedashJS.getAchievement(ach_name), "try_get_achievement")

#endregion

#region User Presence

## Updates rich user presence so friends can see what the player is doing in game.
##   "status"  — the primary line (e.g. "Traveling in a group")
##   "details" — secondary context beneath it (e.g. current zone or mode)
## Empty dictionary clears every field. Values must be String, int, float, bool or
## null; a nested Dictionary or Array is rejected JS-side.
##
## False when the update did not happen. The page resolves false rather than rejecting on
## its own errors, so that case arrives on a successful envelope and is stamped here.
func update_user_presence(data: Dictionary) -> bool:
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.updateUserPresence(JSON.stringify(data)))
	else:
		env = _web_unsupported("update_user_presence")
	_emit_response(env, user_presence_updated)
	if not env.ok():
		return false
	# After _emit_response, which clears the slot on a successful envelope.
	if not (env.data is bool and env.data):
		_set_last_error(_fail_envelope(FAILED,
			"update_user_presence: the page could not write the update. A value may not be "
				+ "a String, int, float, bool or null."))
		return false
	return true

#endregion

#region Entitlements and Paywalls

## Whether the player owns the given paid content. A UX hint for driving in-game
## UI, not a security check — the builds server re-gates paid bytes on every
## request. `bool_value` is true when the player owns the content, and false is a real
## answer — they do not. Only null is a failed check.
func fetch_entitlement(content_identifier: String) -> WavedashTypes.BoolOptional:
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.isEntitled(content_identifier))
	else:
		env = _web_unsupported("fetch_entitlement")
	_emit_response(env, got_is_entitled)
	if not env.ok():
		return null
	return WavedashTypes.BoolOptional.from_data(env.data)

## Every paid-content identifier the player owns, for gating several items without
## a call each. A UX hint, not a security check — see fetch_entitlement().
## `strings` is an Array[String] of owned content identifiers.
func list_entitlements() -> WavedashTypes.StringListOptional:
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.getEntitlements())
	else:
		env = _web_unsupported("list_entitlements")
	_emit_response(env, got_entitlements)
	if not env.ok():
		return null
	return WavedashTypes.StringListOptional.from_data(env.data)

## Opens the Wavedash paywall for the given content, or resolves immediately if the player
## already owns it. The JWT is refreshed on a successful purchase.
## `bool_value` is true when the player owns it after the flow; false is a real answer —
## they closed the paywall without buying — not a failure.
func trigger_paywall(content_identifier: String) -> WavedashTypes.BoolOptional:
	var env: Envelope
	if is_available():
		env = await _invoke_js(WavedashJS.triggerPaywall(content_identifier))
	else:
		env = _web_unsupported("trigger_paywall")
	_emit_response(env, paywall_resolved)
	if not env.ok():
		return null
	return WavedashTypes.BoolOptional.from_data(env.data)

#endregion

#region Content Downloads

## Null when the path is usable.
func _invalid_item_path_error(item_path: String, func_name: String) -> Envelope:
	if item_path.is_empty():
		return _fail_envelope(ERR_INVALID_PARAMETER,
			"%s: item_path must not be empty" % func_name)
	if item_path.is_absolute_path():
		return _fail_envelope(ERR_INVALID_PARAMETER,
			"%s: item_path must be relative to your build root (e.g. 'dlc/full.pck'), got '%s'"
				% [func_name, item_path])
	for segment in item_path.split("/", false):
		if segment == "..":
			return _fail_envelope(ERR_INVALID_PARAMETER,
				"%s: item_path must not contain '..' segments, got '%s'" % [func_name, item_path])
	return null

## Per segment, so the result cannot leave this origin: uri_encode() escapes "/",
## collapsing anything host- or scheme-shaped into one path segment.
func _content_url(item_path: String) -> String:
	var segments := PackedStringArray()
	for segment in item_path.split("/", false):
		segments.append(segment.uri_encode())
	return "%s/%s" % [_builds_origin, "/".join(segments)]

func _paywalled_error(item_path: String, body: PackedByteArray) -> Envelope:
	var names := PackedStringArray()
	# JSON.parse_string() would ERR_PRINT on the HTML error page a proxy returns
	# instead of our JSON body; parse() reports the same failure silently.
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) == OK and json.data is Dictionary:
		var identifiers = json.data.get("contentIdentifiers", [])
		if identifiers is Array:
			for identifier in identifiers:
				names.append(str(identifier))
	var message := "download_content: '%s' is locked" % item_path
	if not names.is_empty():
		message = ("download_content: '%s' is locked, player does not own: %s"
			% [item_path, ", ".join(names)])
	var env := _fail_envelope(ERR_UNAUTHORIZED, message)
	# A failed envelope has no payload of its own, so the identifiers ride on `data`
	# for download_content() to move into the slot once it has stamped.
	env.data = names
	return env

func _fetch_content(item_path: String, local_path: String) -> Envelope:
	if not _is_web:
		return _web_unsupported("download_content")
	var path_error := _invalid_item_path_error(item_path, "download_content")
	if path_error != null:
		return path_error
	if _builds_origin.is_empty():
		return _fail_envelope(ERR_UNCONFIGURED,
			"download_content: could not determine the origin this build is served from")

	var dest_path := local_path
	if dest_path.is_empty():
		dest_path = "user://" + item_path

	var url := _content_url(item_path)
	_log("download_content: fetching %s" % url)

	var http = HTTPRequest.new()
	add_child(http)
	var error := http.request(url)
	if error != OK:
		http.queue_free()
		return _fail_envelope(ERR_CANT_CONNECT,
			"download_content: could not start the request for '%s' (%s)"
				% [item_path, error_string(error)])

	var response = await http.request_completed
	http.queue_free()
	var result: int = response[0]
	var response_code: int = response[1]
	var body: PackedByteArray = response[3]

	if result != HTTPRequest.RESULT_SUCCESS:
		return _fail_envelope(ERR_CONNECTION_ERROR,
			"download_content: network error fetching '%s' (result %d)" % [item_path, result])
	if response_code == HTTPClient.RESPONSE_FORBIDDEN:
		return _paywalled_error(item_path, body)
	if response_code != HTTPClient.RESPONSE_OK:
		return _fail_envelope(ERR_QUERY_FAILED,
			"download_content: failed to fetch '%s' (HTTP %d)" % [item_path, response_code])

	var dir_path := dest_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		var dir_error := DirAccess.make_dir_recursive_absolute(dir_path)
		if dir_error != OK:
			return _fail_envelope(ERR_CANT_CREATE,
				"download_content: could not create directory '%s' (%s)"
					% [dir_path, error_string(dir_error)])

	var file := FileAccess.open(dest_path, FileAccess.WRITE)
	if file == null:
		return _fail_envelope(ERR_FILE_CANT_WRITE,
			"download_content: could not open '%s' for writing (%s)"
				% [dest_path, error_string(FileAccess.get_open_error())])
	file.store_buffer(body)
	file.close()

	_log("download_content: saved %d bytes to %s" % [body.size(), dest_path])
	var download := WavedashTypes.ContentDownload.new()
	download.item_path = item_path
	download.local_path = dest_path
	download.size_bytes = body.size()
	# gdlint: ignore=max-returns
	return _succeed_envelope(download)

## Downloads a file that shipped with your build but isn't loaded yet, saving it
## under user://. `item_path` is relative to your build root (e.g. "dlc/full.pck");
## `local_path` overrides the default destination of "user://" + item_path.
##
## Null if it failed. ERR_UNAUTHORIZED means the file is paywalled, and
## get_last_content_identifiers() lists what the player must own — pass one to
## trigger_paywall(). Mount a downloaded .pck with ProjectSettings.load_resource_pack().
func download_content(item_path: String, local_path: String = "") -> WavedashTypes.ContentDownload:
	var env := await _fetch_content(item_path, local_path)
	_set_last_error(env)
	var download: WavedashTypes.ContentDownload = null
	if env.ok():
		download = env.data
	elif env.data is PackedStringArray:
		# Must follow the stamp above: _set_last_error() clears this.
		_last_content_identifiers = env.data
	content_downloaded.emit(download, item_path)
	return download

#endregion

#region P2P Messaging

## Sends to one peer, or to every peer when target_user_id is empty. False if it did not
## go: the page only sends to a peer that is ready to receive.
func send_p2p_message(target_user_id: String, payload: PackedByteArray, channel: int = 0, reliable: bool = true) -> bool:
	# This one reaches for WavedashJS directly further down, so without the guard an
	# off-web call hard-errors on an unassigned JavaScriptObject — reachable from F5.
	if _stamped_unavailable_error("send_p2p_message"):
		return false
	# Empty is the broadcast address, so only a malformed one is a bug. Synchronous, so
	# the shape check stays: apiCallSync() rethrows a bad id and aborts the caller.
	if not target_user_id.is_empty() and _stamped_bad_id_error(target_user_id, "send_p2p_message"):
		return false
	if payload.size() == 0:
		_set_last_error(_fail_envelope(ERR_INVALID_PARAMETER, "send_p2p_message: empty payload"))
		return false

	# Byte-by-byte into a pre-allocated JS buffer looks wasteful and is not: Godot cannot
	# hand a PackedByteArray across the barrier, and base64 or a SharedArrayBuffer both
	# cost more below ~16KB. TODO: a direct view into the WASM heap, if Godot ever allows it.
	var payload_size = payload.size()
	if not _p2p_outgoing_buffer:
		_p2p_outgoing_buffer = WavedashJS.getP2POutgoingMessageBuffer()
		_p2p_outgoing_buffer_size = _p2p_outgoing_buffer.length
	var js_buffer = _p2p_outgoing_buffer
	if payload_size > _p2p_outgoing_buffer_size:
		_set_last_error(_fail_envelope(ERR_INVALID_PARAMETER,
			"send_p2p_message: payload is %d bytes, buffer holds %d"
				% [payload_size, _p2p_outgoing_buffer_size]))
		return false
	# Copy bytes (1 bridge call per byte unfortunately, still faster than base64 encoding as long as payload is < 16KB)
	for i in range(payload_size):
		# gdlint: ignore=unsafe_property_access
		(js_buffer as Variant)[i] = payload[i]
	var sent
	if target_user_id == "":
		# Broadcast to all peers
		sent = WavedashJS.broadcastP2PMessage(channel, reliable, js_buffer, payload_size)
	else:
		# Send to specific peer
		sent = WavedashJS.sendP2PMessage(target_user_id, channel, reliable, js_buffer, payload_size)
	clear_last_error()
	return bool(sent) if sent != null else false

## Read all P2P messages from the incoming queue for a specific channel.
##
## Empty is the normal answer on most frames, and is not distinguishable from a
## failed read: the page hands back an empty buffer either way, so there is nothing
## to detect even if this returned null. Ask is_available() once at startup rather
## than checking per drain — this runs every frame.
func drain_p2p_channel(channel: int) -> Array[WavedashTypes.P2PMessage]:
	if _stamped_unavailable_error("drain_p2p_channel"):
		return []

	clear_last_error()
	var messages: Array[WavedashTypes.P2PMessage] = []
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
			push_warning("P2P framing is out of sync at ", read_offset + message_length,
				" > ", raw_messages.size(), "; dropping this and any remaining messages in the batch")
			break
		var message = raw_messages.slice(read_offset, read_offset + message_length)
		read_offset += message_length
		var decoded := _decode_p2p_packet(message)
		if decoded != null:
			messages.append(decoded)
		else:
			push_warning("P2P message is malformed, dropping message")

	return messages

func _decode_p2p_packet(data: PackedByteArray) -> WavedashTypes.P2PMessage:
	# Binary format: [fromUserId(32)][channel(4)][dataLength(4)][payload(...)]
	if data.size() < 40:  # Minimum size for header
		return null

	var msg := WavedashTypes.P2PMessage.new()
	var offset = 0

	# fromUserId (32 bytes, null-padded)
	var from_user_bytes = data.slice(offset, offset + 32)
	# Find first null byte to avoid Godot's Unicode warning when converting
	var null_pos = from_user_bytes.find(0)
	if null_pos != -1:
		from_user_bytes = from_user_bytes.slice(0, null_pos)
	msg.from_user_id = from_user_bytes.get_string_from_ascii()
	offset += 32

	# channel (4 bytes, little-endian)
	msg.channel = data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)
	offset += 4

	# dataLength (4 bytes, little-endian)
	var payload_length = data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)
	offset += 4

	# payload (variable length)
	if payload_length > 0 and offset + payload_length <= data.size():
		msg.payload = data.slice(offset, offset + payload_length)

	return msg

#endregion

#region JavaScript Bridge

## Pre-4.4 fallback for JavaScriptBridge.js_buffer_to_packed_byte_array(). 4.2+ eval()
## converts Uint8Array returns natively; 4.0-4.1 cannot, so those base64 round-trip.
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

## Always returns an Envelope, including for junk: a failed typed assignment would
## abort and leave the caller parked in _await_request() forever. `error` is derived
## from `success`, never copied from the JSON, so a page cannot forge it.
func _parse_envelope(response_json: String) -> Envelope:
	var parsed = JSON.parse_string(response_json) if response_json else {}
	if not (parsed is Dictionary):
		push_warning("[WavedashSDK] response was not a JSON object: %s" % response_json)
		return _fail_envelope(FAILED, "response was not a JSON object")
	var env := Envelope.new()
	env.error = OK if parsed.get("success", false) else FAILED
	env.data = parsed.get("data", null)
	var message = parsed.get("message", "")
	env.message = message if message is String else ""
	if not env.ok() and env.message.is_empty():
		env.message = error_string(env.error)
	return env

func _create_js_callback(req_id: int) -> JavaScriptObject:
	var cb = JavaScriptBridge.create_callback(func(args):
		var response_json: String = args[0] if args.size() > 0 else ""
		_pending.resolve(req_id, _parse_envelope(response_json))
	)
	_pending.hold(req_id, cb)
	return cb

## Without this a rejection never fires the resolution handler and take() waits forever.
func _create_js_rejection_callback(req_id: int, func_name: String) -> JavaScriptObject:
	var cb = JavaScriptBridge.create_callback(func(args):
		var reason: String = str(args[0]) if args.size() > 0 else "the page gave no reason"
		_pending.resolve(req_id, _fail_envelope(FAILED, "%s: %s" % [func_name, reason]))
	)
	_pending.hold(req_id, cb)
	return cb

func _await_request(req_id: int) -> Envelope:
	return await _pending.take(req_id)

## Awaits a JS promise resolving to a {success, data, message} envelope. Two hangs are
## turned into errors: a worker builds the promise against the wrong global scope so
## .then() never fires, and a rejected promise would never resolve the request either.
func _invoke_js(js_promise) -> Envelope:
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		return _fail_envelope(ERR_UNAVAILABLE,
			"WavedashSDK must be called from the main thread: a worker has its own "
			+ "JS scope and cannot reach the page's WavedashJS")
	var req_id := _pending.open()
	# No call name to pass: every caller here is an apiCall(), whose own message names the
	# method. _invoke_js_raw() has one because its promise comes from a bare manager call.
	js_promise.then(
		_create_js_callback(req_id),
		_create_js_rejection_callback(req_id, "an awaited call"))
	return await _await_request(req_id)

## For JS calls resolving to a raw boolean rather than an envelope. These bypass apiCall()
## upstream, so the promise really can reject — requestFromParent() rejects on a response
## timeout and on a missing parent origin.
func _invoke_js_raw(js_promise, func_name: String) -> Envelope:
	var req_id := _pending.open()
	var cb = JavaScriptBridge.create_callback(func(args):
		_pending.resolve(req_id, _succeed_envelope(args[0] if args.size() > 0 else false))
	)
	_pending.hold(req_id, cb)
	js_promise.then(cb, _create_js_rejection_callback(req_id, func_name))
	return await _pending.take(req_id)

#endregion

#region Event Dispatch

## A payload that isn't a JSON object decodes to {}, so from_dict() falls back to
## each field's default rather than erroring on the typed assignment.
func _parse_event_payload(event_name: String, payload: String) -> Dictionary:
	var parsed = JSON.parse_string(payload) if payload else null
	if parsed is Dictionary:
		return parsed
	push_warning("[WavedashSDK] %s payload was not a JSON object, treating as empty: %s" % [event_name, str(payload)])
	return {}

func _dispatch_js_event(args) -> void:
	if args.size() < 3:
		push_warning("[WavedashSDK] malformed event from JS: %d args" % args.size())
		return
	# gdlint: ignore=function-variable-name
	var _game_object_name = args[0]  # Unused in Godot. Needed for Unity
	var method_name: String = args[1]
	var payload: String = args[2]
	var data := _parse_event_payload(method_name, payload)
	match method_name:
		WavedashTypes.JS_EVENT_LOBBY_MESSAGE:
			_log("Lobby message: %s" % str(payload))
			lobby_message.emit(WavedashTypes.LobbyMessage.from_dict(data))
		WavedashTypes.JS_EVENT_LOBBY_DATA_UPDATED:
			_log("Lobby data updated: %s" % str(payload))
			lobby_data_updated.emit(data)
		WavedashTypes.JS_EVENT_LOBBY_USERS_UPDATED:
			_log("Lobby users updated: %s" % str(payload))
			_lobby.host_expired()
			lobby_users_updated.emit(WavedashTypes.LobbyUsersUpdatedPayload.from_dict(data))
		# All lobby join flows land here
		# 1. create_lobby success -> LOBBY_JOINED
		# 2. join_lobby success -> LOBBY_JOINED
		# 3. External join (ie invite link) -> LOBBY_JOINED
		WavedashTypes.JS_EVENT_LOBBY_JOINED:
			_log("Lobby joined: %s" % str(payload))
			# Payload: { lobbyId, hostId, users, metadata }
			var joined := WavedashTypes.LobbyJoinedPayload.from_dict(data)
			_lobby.joined(joined.lobby_id, joined.host_id)
			lobby_joined.emit(joined)
		WavedashTypes.JS_EVENT_LOBBY_KICKED:
			# payload: { lobbyId, reason }
			var kicked := WavedashTypes.LobbyKickedPayload.from_dict(data)
			_log("Lobby kicked (reason: %s): %s" % [WavedashTypes.lobby_kicked_reason_to_string(kicked.reason), payload])
			_lobby.forget()
			lobby_kicked.emit(kicked)
		WavedashTypes.JS_EVENT_LOBBY_INVITE:
			_log("Lobby invite: %s" % str(payload))
			lobby_invite.emit(WavedashTypes.LobbyInvite.from_dict(data))
		WavedashTypes.JS_EVENT_P2P_CONNECTION_ESTABLISHED:
			_log("P2P connection established: %s" % str(payload))
			p2p_connection_established.emit(WavedashTypes.P2PConnectionEstablishedPayload.from_dict(data))
		WavedashTypes.JS_EVENT_P2P_CONNECTION_FAILED:
			_log("P2P connection failed: %s" % str(payload))
			p2p_connection_failed.emit(WavedashTypes.P2PConnectionFailedPayload.from_dict(data))
		WavedashTypes.JS_EVENT_P2P_PEER_DISCONNECTED:
			_log("P2P peer disconnected: %s" % str(payload))
			p2p_peer_disconnected.emit(WavedashTypes.P2PPeerDisconnectedPayload.from_dict(data))
		WavedashTypes.JS_EVENT_P2P_PEER_RECONNECTING:
			_log("P2P peer reconnecting: %s" % str(payload))
			p2p_peer_reconnecting.emit(WavedashTypes.P2PPeerReconnectingPayload.from_dict(data))
		WavedashTypes.JS_EVENT_P2P_PEER_RECONNECTED:
			_log("P2P peer reconnected: %s" % str(payload))
			p2p_peer_reconnected.emit(WavedashTypes.P2PPeerReconnectedPayload.from_dict(data))
		WavedashTypes.JS_EVENT_P2P_PACKET_DROPPED:
			_log("P2P packet dropped: %s" % str(payload))
			p2p_packet_dropped.emit(WavedashTypes.P2PPacketDroppedPayload.from_dict(data))
		WavedashTypes.JS_EVENT_STATS_STORED:
			_log("Stats stored: %s" % str(payload))
			stats_stored.emit(WavedashTypes.StatsStoredPayload.from_dict(data))
		WavedashTypes.JS_EVENT_BACKEND_CONNECTED:
			_log("Backend connected: %s" % str(payload))
			backend_connected.emit(WavedashTypes.BackendConnectionPayload.from_dict(data))
		WavedashTypes.JS_EVENT_BACKEND_RECONNECTING:
			_log("Backend reconnecting: %s" % str(payload))
			backend_reconnecting.emit(WavedashTypes.BackendConnectionPayload.from_dict(data))
		WavedashTypes.JS_EVENT_BACKEND_DISCONNECTED:
			_log("Backend disconnected: %s" % str(payload))
			backend_disconnected.emit(WavedashTypes.BackendConnectionPayload.from_dict(data))
		WavedashTypes.JS_EVENT_FULLSCREEN_CHANGED:
			_log("Fullscreen changed: %s" % str(payload))
			fullscreen_changed.emit(WavedashTypes.FullscreenChangedPayload.from_dict(data))
		WavedashTypes.JS_EVENT_ENTITLEMENTS_GRANTED:
			_log("Entitlements granted: %s" % str(payload))
			entitlements_granted.emit(WavedashTypes.EntitlementsGrantedPayload.from_dict(data))
		WavedashTypes.JS_EVENT_MUTE_CHANGED:
			_log("Mute changed: %s" % str(payload))
			mute_changed.emit(WavedashTypes.MuteChangedPayload.from_dict(data))
		_:
			push_warning("[WavedashSDK] Received unknown event from JS: " + method_name)

#endregion
