@tool
extends RefCounted

## Reads and writes the CLI's own credentials.json, so signing in needs no CLI installed.

const WavedashCompat = preload("wavedash_compat.gd")
const WavedashCliRunner = preload("wavedash_cli_runner.gd")

const DEV_PORTAL_KEYS_URL := "https://wavedash.com/dev-portal/keys"

const IDENTITY_KEY := "auth_identity"

const KEY_PREVIEW_HEAD := 9
const KEY_PREVIEW_TAIL := 3
const KEY_PREVIEW_MIN_HIDDEN := 8

static func get_credentials_path() -> String:
	var home := OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")
	return home.path_join(".wavedash").path_join("credentials.json")

## WAVEDASH_TOKEN takes precedence over the file, matching the CLI.
static func check_status() -> Dictionary:
	var env_token := OS.get_environment("WAVEDASH_TOKEN")
	if env_token != "":
		return {"authenticated": true, "key_preview": mask_key(env_token)}
	var api_key: String = _read_credentials_file().get("api_key", "")
	return {"authenticated": api_key != "", "key_preview": mask_key(api_key)}

## From `auth status --json`: {source, username, email}. Empty without a CLI that has the flag, or when
## the key is rejected or the server unreachable; callers fall back to the key preview. Held for the
## session since it's a network round trip.
static func fetch_identity() -> Dictionary:
	var cached = WavedashCompat.session_get(IDENTITY_KEY, null)
	if cached != null:
		return cached
	var result := WavedashCliRunner.auth_status()
	var identity: Dictionary = result.data if result.ok and result.data is Dictionary else {}
	WavedashCompat.session_set(IDENTITY_KEY, identity)
	return identity

static func invalidate_identity() -> void:
	WavedashCompat.session_set(IDENTITY_KEY, null)

## "" for input too short to mask, where head and tail would overlap and echo the value back.
static func mask_key(key: String) -> String:
	if key.length() < KEY_PREVIEW_HEAD + KEY_PREVIEW_TAIL + KEY_PREVIEW_MIN_HIDDEN:
		return ""
	return "%s...%s" % [key.substr(0, KEY_PREVIEW_HEAD), key.right(KEY_PREVIEW_TAIL)]

static func _read_credentials_file() -> Dictionary:
	var path := get_credentials_path()
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var content := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(content)
	return parsed if parsed is Dictionary else {}

## Read-modify-write so the CLI's other fields survive; the read must precede the open, which truncates.
static func save_token(token: String) -> Error:
	var path := get_credentials_path()
	var dir_path := path.get_base_dir()
	var err := DirAccess.make_dir_recursive_absolute(dir_path)
	if err != OK and not DirAccess.dir_exists_absolute(dir_path):
		return err
	var credentials := _read_credentials_file()
	credentials["api_key"] = token
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(credentials))
	file.close()
	WavedashCompat.set_owner_only_permissions(dir_path, true)
	WavedashCompat.set_owner_only_permissions(path, false)
	return OK

## Doesn't touch WAVEDASH_TOKEN, which isn't this plugin's to unset.
static func log_out() -> Error:
	var path := get_credentials_path()
	if not FileAccess.file_exists(path):
		return OK
	return DirAccess.remove_absolute(path)
