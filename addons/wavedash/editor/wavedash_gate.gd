@tool
extends RefCounted

## The single place that decides whether a Wavedash action is allowed, so the dev
## button and the build-push button can't drift apart. One function per action,
## each composing the one it depends on.

const WavedashAuth = preload("wavedash_auth.gd")
const WavedashCli = preload("wavedash_cli.gd")
const WavedashExportPresets = preload("wavedash_export_presets.gd")
const WavedashProjectApi = preload("wavedash_project_api.gd")
const WavedashToml = preload("wavedash_toml.gd")
## One reason a Wavedash action is unavailable. NONE carries empty strings, so
## callers can read `detailed_description`/`summary_description` without a null check.
class Blocker:
	static func none() -> Blocker:
		return make("", "")

	var summary_description := ""  ## For the dock's status line.
	var detailed_description := ""  ## For logs, dialogs and tooltips.

	static func make(summary_description: String, detailed_description: String) -> Blocker:
		var blocker := Blocker.new()
		blocker.summary_description = summary_description
		blocker.detailed_description = detailed_description
		return blocker

	## For the cases where one wording serves both.
	static func make_uniform(message: String) -> Blocker:
		return make(message, message)

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

static func no_export_templates() -> Blocker:
	return Blocker.make(
		"Install export templates: Editor > Manage Export Templates.",
		"Web export templates aren't installed. Install them under Editor > Manage Export Templates.")

static func game_not_found() -> Blocker:
	return Blocker.make(
		"Wavedash game not found.",
		"The game in wavedash.toml isn't visible to this account. Reconnect from the Wavedash dock.")

const NO_EXPORT_PATH := "Preset has no export path. Set one in Export Presets."
const EXPORT_PATH_IS_ROOT := "Preset exports into \"%s\", which would cause Wavedash to upload your whole project."
const EXPORT_DIR_MISSING := "Export folder \"%s\" doesn't exist."

## What every Wavedash action needs, including connecting a game.
static func check_common() -> Blocker:
	if not WavedashAuth.check_status().authenticated:
		return not_logged_in()
	if not WavedashCli.is_installed():
		return no_cli()
	return Blocker.none()

## check_common() plus what an export needs, for both the dev run and the push. Ordered to
## match the dock, so the reason reported is the topmost row still needing attention.
static func check_can_build() -> Blocker:
	var common := check_common()
	if common.is_blocking():
		return common
	var toml := WavedashToml.read()
	if not toml.exists or toml.game_id == "":
		return no_game()
	# Session-cached, and WavedashProjectRow warms it before this runs.
	if WavedashProjectApi.find_project(toml.game_id) == null:
		return game_not_found()
	if WavedashExportPresets.get_active_preset() == "":
		return no_preset()
	var path_problem := check_export_path()
	if path_problem != "":
		return Blocker.make_uniform(path_problem)
	if not _has_web_export_templates():
		return no_export_templates()
	return Blocker.none()

## The release template is the one `--export-release` needs. An engine that can't answer
## doesn't block the build -- the export step reports whatever goes wrong itself.
static func _has_web_export_templates() -> bool:
	var platform := ClassDB.instantiate("EditorExportPlatformWeb")
	if platform == null:
		return true
	var found = platform.call("find_export_template", "web_release.zip")
	return not (found is Dictionary) or found.get("result", OK) == OK

## Public on its own because WavedashPresetRow judges a preset without caring about
## the rest. A bare filename is rejected because it puts the build in the project
## root, which would make a push upload the entire project.
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
