extends Node

var WavedashJS:JavaScriptObject

# Register each callback
signal lobby_joined(lobby_data)
var lobby_joined_callback_ref = JavaScriptBridge.create_callback(_on_lobby_joined)

func _ready():
	if OS.get_name() == "Web":
		WavedashJS = JavaScriptBridge.get_interface("WavedashJS")
		if not WavedashJS:
			print("WavedashSDK: WavedashJS not found on window")

func init(config: Dictionary):
	if OS.get_name() == "Web" and WavedashJS:
		WavedashJS.init(JSON.stringify(config))

func get_user():
	if OS.get_name() == "Web" and WavedashJS:
		return JSON.parse_string(WavedashJS.getUser())
	return null

func join_lobby(lobby_id: String):
	if OS.get_name() == "Web" and WavedashJS:
		WavedashJS.joinLobby(lobby_id).then(lobby_joined_callback_ref)

func _on_lobby_joined(args):
	var lobby_json = args[0] if args.size() > 0 else null
	var lobby_data = JSON.parse_string(lobby_json) if lobby_json else {}
	lobby_joined.emit(lobby_data)
