@tool
extends RefCounted

## Owns res://wavedash.toml. Manages only game_id/upload_dir/[godot].version;
## every other line passes through verbatim. Tracks line positions rather than
## parsing a schema, so entrypoint, other engine sections, and whatever a future
## CLI adds all survive a round trip.

const Self_ = preload("wavedash_toml.gd")
const DEFAULT_PATH := "res://wavedash.toml"

var exists: bool = false
var game_id: String = ""
var upload_dir: String = ""
var godot_version: String = ""

## Empty for a never-read instance, in which case write() generates from scratch.
var _lines: PackedStringArray = []
var _game_id_line := -1
var _upload_dir_line := -1
var _godot_section_line := -1
var _godot_version_line := -1

static func read(path: String = DEFAULT_PATH) -> Self_:
	var result := Self_.new()
	if not FileAccess.file_exists(path):
		return result
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return result
	result.exists = true
	var content := file.get_as_text()
	file.close()
	result._lines = content.split("\n")
	# Drop the empty entry a trailing newline produces, so write() can add
	# exactly one back instead of accumulating a blank line per round trip.
	if result._lines.size() > 0 and result._lines[result._lines.size() - 1] == "":
		result._lines.remove_at(result._lines.size() - 1)

	var section := ""
	for i in result._lines.size():
		var line := result._lines[i].strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		if line.begins_with("[") and line.ends_with("]"):
			section = line.substr(1, line.length() - 2)
			if section == "godot":
				result._godot_section_line = i
			continue
		var equals_at := line.find("=")
		if equals_at == -1:
			continue
		var key := line.substr(0, equals_at).strip_edges()
		var value := _unquote(line.substr(equals_at + 1).strip_edges())
		if section == "" and key == "game_id":
			result.game_id = value
			result._game_id_line = i
		elif section == "" and key == "upload_dir":
			result.upload_dir = value
			result._upload_dir_line = i
		elif section == "godot" and key == "version":
			result.godot_version = value
			result._godot_version_line = i
	return result

## Must undo exactly what _quote() does, or a read-then-write round trip would
## double every backslash.
static func _unquote(value: String) -> String:
	if value.length() < 2 or not value.begins_with("\"") or not value.ends_with("\""):
		return value
	# Park escaped backslashes while unescaping quotes, so `\\` followed by `"`
	# can't be misread as an escaped quote.
	var sentinel := char(0xFFFF)
	return value.substr(1, value.length() - 2) \
		.replace("\\\\", sentinel) \
		.replace("\\\"", "\"") \
		.replace(sentinel, "\\")

## TOML basic-string escaping. Paths are the realistic source of a backslash
## here, and an unescaped one would silently corrupt the file the CLI reads.
static func _quote(value: String) -> String:
	return "\"%s\"" % value.replace("\\", "\\\\").replace("\"", "\\\"")

static func _assignment_line(key: String, value: String) -> String:
	return "%s = %s" % [key, _quote(value)]

func write(path: String = DEFAULT_PATH) -> Error:
	var lines := _lines.duplicate()

	# [godot] edits use read()'s original line indices, so they must happen
	# before the top-of-file inserts below shift everything.
	if _godot_version_line >= 0:
		lines[_godot_version_line] = _assignment_line("version", godot_version)
	elif _godot_section_line >= 0:
		lines.insert(_godot_section_line + 1, _assignment_line("version", godot_version))
	else:
		# Blank line first unless the file already ends in one.
		if not lines.is_empty() and lines[lines.size() - 1] != "":
			lines.append("")
		lines.append("[godot]")
		lines.append(_assignment_line("version", godot_version))

	if _game_id_line >= 0:
		lines[_game_id_line] = _assignment_line("game_id", game_id)
	if _upload_dir_line >= 0:
		lines[_upload_dir_line] = _assignment_line("upload_dir", upload_dir)

	if _upload_dir_line == -1:
		lines.insert(0, _assignment_line("upload_dir", upload_dir))
	if _game_id_line == -1:
		lines.insert(0, _assignment_line("game_id", game_id))

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string("\n".join(lines) + "\n")
	file.close()
	return OK
