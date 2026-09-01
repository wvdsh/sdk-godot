@tool
extends RefCounted

## Reads and writes the CLI's own `~/.wavedash/credentials.json` directly, which
## is why signing in needs no CLI installed: `auth login` only does browser OAuth
## or a `--token` flag, and `auth status` makes no server call anyway.

const WavedashCompat = preload("wavedash_compat.gd")

const DEV_PORTAL_KEYS_URL := "https://wavedash.com/dev-portal/keys"

## Enough of the key to recognise which one it is, matching the shape the CLI's
## own `auth status` prints: wd_000000...zzz
const KEY_PREVIEW_HEAD := 9
const KEY_PREVIEW_TAIL := 3
## Below this, masking would reveal most of the key, so no preview is offered.
const KEY_PREVIEW_MIN_HIDDEN := 8

static func get_credentials_path() -> String:
	var home := OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")
	return home.path_join(".wavedash").path_join("credentials.json")

## WAVEDASH_TOKEN takes precedence over the file, matching the CLI. Returns only a
## masked `key_preview`, so the key itself stays inside this file.
static func check_status() -> Dictionary:
	var env_token := OS.get_environment("WAVEDASH_TOKEN")
	if env_token != "":
		return {"authenticated": true, "email": "", "key_preview": mask_key(env_token)}
	var creds := _read_credentials_file()
	var api_key: String = creds.get("api_key", "")
	return {
		"authenticated": api_key != "",
		"email": creds.get("email", ""),
		"key_preview": mask_key(api_key),
	}

## "" for input too short to mask. Real keys never are (wd_ + 64 hex) -- this is
## for a truncated paste or a placeholder WAVEDASH_TOKEN, where the head and tail
## would overlap and echo the value back ("wd_tiny...iny").
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

## Read-modify-write, so signing in doesn't destroy the CLI's other fields (the
## email this addon displays, most visibly). The read must precede the open,
## which truncates.
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
	# Best-effort parity with the CLI's own restrictive permissions.
	WavedashCompat.set_owner_only_permissions(dir_path, true)
	WavedashCompat.set_owner_only_permissions(path, false)
	return OK

## Idempotent. Doesn't touch WAVEDASH_TOKEN, which would keep authenticating
## regardless and isn't this plugin's to unset.
static func log_out() -> Error:
	var path := get_credentials_path()
	if not FileAccess.file_exists(path):
		return OK
	return DirAccess.remove_absolute(path)
