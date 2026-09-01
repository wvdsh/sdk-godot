@tool
extends RefCounted

## Calls the plugin makes dynamically rather than directly, so its scripts still parse on
## Godot 4.0-4.3: a direct call to a method the running engine lacks is a parse error, not
## a runtime one. Each wrapper names the version that added what it stands in for -- once
## the floor passes that version, inline the call and delete the wrapper.

## 4.1 added `static var`, so session state lives on Engine metadata instead. Metadata
## names must be plain identifiers, so the capital marks where the namespace ends.
const SESSION_PREFIX := "Wavedash_"

## has_meta() first: get_meta() treats a null default as "no default" and errors.
static func session_get(key: String, default_value: Variant) -> Variant:
	var name := SESSION_PREFIX + key
	return Engine.get_meta(name) if Engine.has_meta(name) else default_value

## Plain data only -- an Array holding script-defined objects segfaults the engine when
## metadata is released at shutdown. Storing null erases the entry.
static func session_set(key: String, value: Variant) -> void:
	Engine.set_meta(SESSION_PREFIX + key, value)

## os_execute_with_pipe() below is the only thing in the addon needing 4.4.
const DOCK_MIN_VERSION := 0x040400

static func supports_dock() -> bool:
	return Engine.get_version_info().hex >= DOCK_MIN_VERSION

static func dock_min_version_string() -> String:
	return "%d.%d" % [(DOCK_MIN_VERSION >> 16) & 0xFF, (DOCK_MIN_VERSION >> 8) & 0xFF]

## 4.4 added execute_with_pipe()'s `blocking` argument.
static func os_execute_with_pipe(path: String, arguments: PackedStringArray, blocking: bool) -> Dictionary:
	return OS.call("execute_with_pipe", path, arguments, blocking)

## 4.1 added OS.get_process_exit_code().
static func os_get_process_exit_code(pid: int) -> int:
	return int(OS.call("get_process_exit_code", pid))

## 4.1 added FileAccess.set_unix_permissions(). Routed through the ClassDB singleton because
## a static method on a class can't be dispatched by name, and ClassDB.class_call_static()
## is itself 4.2+.
static func set_unix_permissions(path: String, permissions: int) -> int:
	return int(Engine.get_singleton("ClassDB").call(
		"class_call_static", "FileAccess", "set_unix_permissions", path, permissions))

## 4.1 added the FileAccess.UNIX_* flags. 0o700 with the execute bit, 0o600 without.
static func set_owner_only_permissions(path: String, executable: bool) -> int:
	var flag_names := ["UNIX_READ_OWNER", "UNIX_WRITE_OWNER"]
	if executable:
		flag_names.append("UNIX_EXECUTE_OWNER")
	var bits := 0
	for flag_name in flag_names:
		bits |= ClassDB.class_get_integer_constant("FileAccess", flag_name)
	return set_unix_permissions(path, bits)

## 4.3 added Node.is_part_of_edited_scene().
static func is_part_of_edited_scene(node: Node) -> bool:
	return node.call("is_part_of_edited_scene") == true

## 4.4 added Array.find_custom().
static func find_index(items: Array, predicate: Callable) -> int:
	for i in items.size():
		if predicate.call(items[i]):
			return i
	return -1

## 4.2 made EditorInterface a static singleton; before that even naming the class here
## fails to parse.
static func editor_scale() -> float:
	return float(_editor_interface().call("get_editor_scale"))

static func editor_base_control() -> Node:
	return _editor_interface().call("get_base_control") as Node

static func restart_editor(save: bool) -> void:
	_editor_interface().call("restart_editor", save)

static func _editor_interface() -> Object:
	return Engine.get_singleton("EditorInterface")
