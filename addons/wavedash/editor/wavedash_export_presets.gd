@tool
extends RefCounted

## Tracks which of the project's own Godot Web export presets is the Wavedash
## target, and can seed a default one. The pointer lives in ProjectSettings, so
## there's no bespoke storage to keep in sync.

const WavedashCompat = preload("wavedash_compat.gd")
const EXPORT_PRESETS_PATH := "res://export_presets.cfg"
const ACTIVE_PRESET_SETTING := "wavedash/active_export_preset"

## Hardcoded: get_binary_extensions() isn't exposed to scripting.
const WEB_EXTENSION := "html"

## Keyed on content, not mtime: get_modified_time() resolves to whole seconds, so
## a write in the same second as the cached read would be invisible to it.
const CONFIG_KEY := "export_presets_config"
const CONFIG_MD5_KEY := "export_presets_md5"

## Shared instance -- treat as read-only. Mutating it poisons every later read.
static func _load_config() -> ConfigFile:
	var md5 := FileAccess.get_md5(EXPORT_PRESETS_PATH)
	var cached: ConfigFile = WavedashCompat.session_get(CONFIG_KEY, null)
	if cached != null and md5 != "" and md5 == WavedashCompat.session_get(CONFIG_MD5_KEY, ""):
		return cached
	var config := ConfigFile.new()
	if config.load(EXPORT_PRESETS_PATH) != OK:
		WavedashCompat.session_set(CONFIG_KEY, null)
		WavedashCompat.session_set(CONFIG_MD5_KEY, null)
		return null
	WavedashCompat.session_set(CONFIG_KEY, config)
	WavedashCompat.session_set(CONFIG_MD5_KEY, md5)
	return config

static func _is_preset_section(section: String) -> bool:
	return section.begins_with("preset.") and not section.ends_with(".options")

static func _find_active_preset_section(config: ConfigFile) -> String:
	var preset_name := get_active_preset()
	if preset_name == "":
		return ""
	for section in config.get_sections():
		if _is_preset_section(section) and config.get_value(section, "name", "") == preset_name:
			return section
	return ""

## Every Web preset, filtered no further: no field reliably separates an asset pack from a
## game, and hiding a preset means you can't select it to find out why it won't build.
## WavedashGate reports that instead.
static func get_available_presets() -> Array[String]:
	var names: Array[String] = []
	var config := _load_config()
	if config == null:
		return names
	for section in config.get_sections():
		if not _is_preset_section(section):
			continue
		if config.get_value(section, "platform", "") == "Web":
			names.append(config.get_value(section, "name", ""))
	return names

## Raw and unresolved, which is what makes it usable for validation: a bare
## filename here means the build lands in the project root.
static func get_active_preset_export_path() -> String:
	var config := _load_config()
	if config == null:
		return ""
	var section := _find_active_preset_section(config)
	return config.get_value(section, "export_path", "") if section != "" else ""

static func get_active_preset() -> String:
	var available := get_available_presets()
	var active: String = ProjectSettings.get_setting(ACTIVE_PRESET_SETTING, "")
	if active in available:
		return active
	return available[0] if not available.is_empty() else ""

static func set_active_preset(preset_name: String) -> void:
	ProjectSettings.set_setting(ACTIVE_PRESET_SETTING, preset_name)
	ProjectSettings.save()

## The upload_dir the active preset implies. Godot stores export_path relative to the
## project root, which is also where wavedash.toml lives and what the CLI resolves
## against -- so the value carries over as-is, ".." segments included.
static func derive_upload_dir() -> String:
	var export_path := get_active_preset_export_path()
	if export_path == "":
		return ""
	return export_path.trim_prefix("res://").get_base_dir().simplify_path()

## Where the picker starts.
static func suggested_export_path() -> String:
	var app_name: String = ProjectSettings.get_setting("application/config/name", "game")
	return "build/%s.%s" % [app_name, WEB_EXTENSION]

## The relative-to-project-root form Godot stores. Its own conversion
## (String::path_to_file) isn't scriptable, so paths outside the project stay absolute.
static func localize_export_path(global_path: String) -> String:
	return ProjectSettings.localize_path(global_path).trim_prefix("res://")

## globalize_path() alone won't do: it returns a project-relative path unchanged, and
## "res://".path_join() would corrupt an absolute one.
static func globalize_export_path(export_path: String) -> String:
	if export_path.is_absolute_path():
		return ProjectSettings.globalize_path(export_path)
	return ProjectSettings.globalize_path("res://").path_join(export_path)

## Adds a Web preset with the settings docs.wavedash.com recommends, makes it active,
## and returns its name (numerically suffixed if taken). Builds its own ConfigFile
## because _load_config()'s is shared.
static func create_default_web_preset(export_path: String) -> String:
	var config := ConfigFile.new()
	config.load(EXPORT_PRESETS_PATH)  # ok if this file doesn't exist yet

	var preset_name := _unique_preset_name(config, "Wavedash")
	var section := "preset.%d" % _next_preset_index(config)

	config.set_value(section, "name", preset_name)
	config.set_value(section, "platform", "Web")
	config.set_value(section, "export_path", export_path)
	# Godot defaults every key left out except these, which its own preset loader reads with
	# no fallback -- omitting any of them errors on every project load. `runnable` only
	# nominates the Play button's target, so it stays false.
	config.set_value(section, "runnable", false)
	config.set_value(section, "export_filter", "all_resources")
	config.set_value(section, "include_filter", "")
	config.set_value(section, "exclude_filter", "")
	# The one option whose Godot default (false) is wrong for Wavedash.
	config.set_value(section + ".options", "variant/thread_support", true)

	config.save(EXPORT_PRESETS_PATH)

	set_active_preset(preset_name)
	return preset_name

static func _next_preset_index(config: ConfigFile) -> int:
	var max_index := -1
	for section in config.get_sections():
		if _is_preset_section(section):
			var suffix := section.substr("preset.".length())
			if suffix.is_valid_int():
				max_index = max(max_index, suffix.to_int())
	return max_index + 1

static func _unique_preset_name(config: ConfigFile, base_name: String) -> String:
	var existing := {}
	for section in config.get_sections():
		if _is_preset_section(section):
			existing[config.get_value(section, "name", "")] = true
	if not existing.has(base_name):
		return base_name
	var i := 2
	while existing.has("%s %d" % [base_name, i]):
		i += 1
	return "%s %d" % [base_name, i]
