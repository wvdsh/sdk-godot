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
		"Not connected to a game on Wavedash -- use the Wavedash Project row in the dock first.")

static func no_export_templates() -> Blocker:
	return Blocker.make(
		"Install export templates: Editor > Manage Export Templates.",
		"Godot's Web export templates aren't installed for this editor version. Install them with Editor > Manage Export Templates > Download and Install, then try again.")

static func game_not_found() -> Blocker:
	return Blocker.make(
		"Wavedash game not found.",
		"wavedash.toml's game_id doesn't match any game this account can see -- it may have been deleted, or belong to a team you're no longer a member of. Reconnect from the Wavedash Project row.")

const NO_EXPORT_PATH := "This preset has no export path set. Open Project > Export and set one inside a folder (for example build/game.html) before building."
## Takes the offending path twice: as-is, then as the suggested subfolder.
const EXPORT_PATH_IS_ROOT := "This preset exports to the project root (\"%s\"). Set an export path inside a folder (for example build/%s) before building, or Wavedash would upload your whole project."

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
	if export_path.get_base_dir() == "":
		return EXPORT_PATH_IS_ROOT % [export_path, export_path]
	return ""
