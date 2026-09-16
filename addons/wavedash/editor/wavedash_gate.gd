@tool
extends RefCounted

const WavedashAuth = preload("wavedash_auth.gd")
const WavedashCli = preload("wavedash_cli.gd")
const WavedashExportPresets = preload("wavedash_export_presets.gd")
const WavedashToml = preload("wavedash_toml.gd")
const WavedashCompat = preload("wavedash_compat.gd")
const WavedashProjectApi = preload("wavedash_project_api.gd")

class Blocker:
	static func none() -> Blocker:
		return make("", "")

	var summary_description := ""
	var detailed_description := ""

	static func make(summary_description: String, detailed_description: String) -> Blocker:
		var blocker := Blocker.new()
		blocker.summary_description = summary_description
		blocker.detailed_description = detailed_description
		return blocker

	func is_blocking() -> bool:
		return detailed_description != ""

static func not_logged_in() -> Blocker:
	return Blocker.make(
		"Log in to Wavedash first.",
		"Sign in to Wavedash first -- use the Wavedash Account row in the dock.")

static func no_cli() -> Blocker:
	return Blocker.make(
		"Install the Wavedash CLI first.",
		"Install the Wavedash CLI first -- use the Wavedash CLI row in the dock.")

static func no_preset() -> Blocker:
	return Blocker.make(
		"Choose an export preset first.",
		"Set up a Web export preset first -- use the Export preset row in the dock.")

static func no_game() -> Blocker:
	return Blocker.make(
		"Connect a game on Wavedash first.",
		"Not connected to a Wavedash game. Connect from the Wavedash dock.")

static func game_not_found() -> Blocker:
	return Blocker.make(
		"Wavedash game not found.",
		"The game in wavedash.toml isn't visible to this account. Reconnect from the Wavedash dock.")

static func no_export_templates() -> Blocker:
	return Blocker.make(
		"Install export templates: Editor > Manage Export Templates.",
		"Web export templates aren't installed. Install them under Editor > Manage Export Templates.")

const WEB_EXPORT_TEMPLATES_KEY := "web_export_templates"

const NO_EXPORT_PATH := "Preset has no export path. Set one in Export Presets."
const EXPORT_PATH_IS_ROOT := "Preset exports into \"%s\", which would cause Wavedash to upload your whole project."
const EXPORT_DIR_MISSING := "Export folder \"%s\" doesn't exist."

static func check_common() -> Blocker:
	if not WavedashAuth.check_status().authenticated:
		return not_logged_in()
	if not WavedashCli.is_installed():
		return no_cli()
	return Blocker.none()

static func check_can_build() -> Blocker:
	var common := check_common()
	if common.is_blocking():
		return common
	var toml := WavedashToml.read()
	if not toml.exists or toml.game_id == "":
		return no_game()
	if WavedashProjectApi.is_known_missing(toml.game_id):
		return game_not_found()
	if WavedashExportPresets.get_active_preset() == "":
		return no_preset()
	var path_problem := check_export_path()
	if path_problem != "":
		return Blocker.make(path_problem, path_problem)
	if not _has_web_export_templates():
		return no_export_templates()
	return Blocker.none()

static func forget_export_templates() -> void:
	WavedashCompat.session_set(WEB_EXPORT_TEMPLATES_KEY, null)

## Cached: instantiating the platform rasterises its logos every time.
static func _has_web_export_templates() -> bool:
	var cached = WavedashCompat.session_get(WEB_EXPORT_TEMPLATES_KEY, null)
	if cached != null:
		return cached
	var installed := WavedashCompat.has_web_export_template("web_release.zip")
	WavedashCompat.session_set(WEB_EXPORT_TEMPLATES_KEY, installed)
	return installed

static func check_export_path() -> String:
	if WavedashExportPresets.get_active_preset() == "":
		return ""
	var export_path := WavedashExportPresets.get_active_preset_export_path()
	if export_path == "":
		return NO_EXPORT_PATH
	if WavedashExportPresets.export_dir_contains_project(export_path):
		return EXPORT_PATH_IS_ROOT % WavedashExportPresets.export_dir(export_path)
	# Godot's exporter refuses a missing folder rather than creating one.
	var export_dir := WavedashExportPresets.derive_upload_dir()
	if not DirAccess.dir_exists_absolute(WavedashExportPresets.globalize_export_path(export_dir)):
		return EXPORT_DIR_MISSING % export_dir
	return ""
