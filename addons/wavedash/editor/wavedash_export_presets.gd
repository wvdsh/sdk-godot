@tool
extends RefCounted

const WavedashCompat = preload("wavedash_compat.gd")
const WavedashGdextensions = preload("wavedash_gdextensions.gd")
const EXPORT_PRESETS_PATH := "res://export_presets.cfg"
const ACTIVE_PRESET_SETTING := "wavedash/active_export_preset"

## Hardcoded: get_binary_extensions() isn't exposed to scripting.
const WEB_EXTENSION := "html"

## Keyed on content, not mtime: get_modified_time() resolves to whole seconds.
const CONFIG_KEY := "export_presets_config"
const CONFIG_MD5_KEY := "export_presets_md5"

## Shared instance, treat as read-only.
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

static func get_active_preset_export_path() -> String:
	return _get_active_preset_value("", "export_path", "")

static func get_active_preset_option(option: String, default_value: Variant) -> Variant:
	return _get_active_preset_value(".options", option, default_value)

static func _get_active_preset_value(subsection: String, key: String, default_value: Variant) -> Variant:
	var config := _load_config()
	if config == null:
		return default_value
	var section := _find_active_preset_section(config)
	if section == "":
		return default_value
	return config.get_value(section + subsection, key, default_value)

static func get_active_preset() -> String:
	var available := get_available_presets()
	var active: String = ProjectSettings.get_setting(ACTIVE_PRESET_SETTING, "")
	if active in available:
		return active
	return available[0] if not available.is_empty() else ""

static func set_active_preset(preset_name: String) -> void:
	ProjectSettings.set_setting(ACTIVE_PRESET_SETTING, preset_name)
	ProjectSettings.save()

## Godot stores export_path relative to the project root, which is also what the CLI resolves upload_dir against.
static func derive_upload_dir() -> String:
	var export_path := get_active_preset_export_path()
	if export_path == "":
		return ""
	return export_path.trim_prefix("res://").get_base_dir().simplify_path()

static func suggested_export_path() -> String:
	var app_name: String = ProjectSettings.get_setting("application/config/name", "game")
	return "build/%s.%s" % [app_name, WEB_EXTENSION]

static func localize_export_path(global_path: String) -> String:
	return ProjectSettings.localize_path(global_path).trim_prefix("res://")

static func export_dir(export_path: String) -> String:
	return globalize_export_path(export_path.get_base_dir()).simplify_path().trim_suffix("/")

static func export_dir_contains_project(export_path: String) -> bool:
	var dir := export_dir(export_path)
	var project_dir := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	return project_dir == dir or project_dir.begins_with(dir + "/")

## globalize_path() returns a project-relative path unchanged, and "res://".path_join() would corrupt an absolute one.
static func globalize_export_path(export_path: String) -> String:
	if export_path.is_absolute_path():
		return ProjectSettings.globalize_path(export_path)
	return ProjectSettings.globalize_path("res://").path_join(export_path)

## Builds its own ConfigFile because _load_config()'s is shared.
static func create_default_web_preset(export_path: String) -> String:
	var config := ConfigFile.new()
	config.load(EXPORT_PRESETS_PATH)

	var preset_name := _unique_preset_name(config, "Wavedash")
	var section := "preset.%d" % _next_preset_index(config)

	config.set_value(section, "name", preset_name)
	config.set_value(section, "platform", "Web")
	config.set_value(section, "export_path", export_path)
	# Godot's preset loader reads these four keys with no fallback; omitting any errors on every project load.
	# `runnable` only nominates the Play button's target.
	config.set_value(section, "runnable", false)
	config.set_value(section, "export_filter", "all_resources")
	config.set_value(section, "include_filter", "")
	config.set_value(section, "exclude_filter", "")
	config.set_value(section + ".options", "variant/thread_support", true)
	if not WavedashGdextensions.with_web_build().is_empty():
		config.set_value(section + ".options", "variant/extensions_support", true)

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
