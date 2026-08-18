@tool
extends AcceptDialog

## Team/game picker that writes wavedash.toml's game_id. Godot version and build
## folder are derived, never asked for.

const WavedashGate = preload("wavedash_gate.gd")
const WavedashExportPresets = preload("wavedash_export_presets.gd")
const WavedashProjectApi = preload("wavedash_project_api.gd")
const WavedashToml = preload("wavedash_toml.gd")
const WavedashLog = preload("wavedash_log.gd")
const WavedashIconTheme = preload("wavedash_icon_theme.gd")
const CreateTeamIcon = preload("assets/user_round_plus_white.svg")
const CreateGameIcon = preload("assets/file_plus_corner_white.svg")
const TeamIcon = preload("assets/users_white.svg")
const GameIcon = preload("assets/gamepad_2_white.svg")
const WavedashCompat = preload("wavedash_compat.gd")

signal initialized

const CREATE_NEW_ID := "__create_new__"

@onready var _gate_message: Label = $Content/GateMessage
@onready var _team_row: HBoxContainer = $Content/TeamRow
@onready var _team_dropdown: OptionButton = $Content/TeamRow/Dropdown
@onready var _team_create_row: HBoxContainer = $Content/TeamCreateRow
@onready var _team_create_edit: LineEdit = $Content/TeamCreateRow/NameEdit
@onready var _team_create_button: Button = $Content/TeamCreateRow/CreateButton
@onready var _game_row: HBoxContainer = $Content/GameRow
@onready var _game_dropdown: OptionButton = $Content/GameRow/Dropdown
@onready var _game_create_row: HBoxContainer = $Content/GameCreateRow
@onready var _game_create_edit: LineEdit = $Content/GameCreateRow/NameEdit
@onready var _game_create_button: Button = $Content/GameCreateRow/CreateButton

var _teams: Array[WavedashProjectApi.Team] = []
var _projects: Array[WavedashProjectApi.Project] = []
var _selected_team_id := ""
var _selected_project_id := ""

## Setup here would dirty the open scene and bake session state into a shipped .tscn.
@onready var _in_edited_scene := WavedashCompat.is_part_of_edited_scene(self)

func _ready() -> void:
	if _in_edited_scene:
		return
	get_ok_button().text = "Connect"
	confirmed.connect(_on_initialize)
	_team_dropdown.item_selected.connect(_on_team_selected)
	_game_dropdown.item_selected.connect(_on_game_selected)
	_team_create_button.pressed.connect(_on_create_team_pressed)
	_game_create_button.pressed.connect(_on_create_project_pressed)
	_apply_icons()
	_refresh()

func _apply_icons() -> void:
	_team_create_button.icon = CreateTeamIcon
	WavedashIconTheme.apply_to_button(_team_create_button)
	_game_create_button.icon = CreateGameIcon
	WavedashIconTheme.apply_to_button(_game_create_button)

func _notification(what: int) -> void:
	if _in_edited_scene:
		return
	if what == NOTIFICATION_THEME_CHANGED and _team_create_button:
		_apply_icons()

func _refresh() -> void:
	var gate := WavedashGate.check_common().detailed_description
	if gate != "":
		_show_gate_message(gate)
		return
	_show_picker()
	_teams = WavedashProjectApi.list_teams()
	_populate_team_dropdown()
	var existing := WavedashToml.read()
	var preselected := false
	if existing.exists and existing.game_id != "":
		preselected = _preselect_existing(existing.game_id)
	if not preselected:
		_apply_team_default(not _teams.is_empty(), 0)
	_update_initialize_enabled()

func _show_gate_message(message: String) -> void:
	_gate_message.text = message
	_gate_message.visible = true
	_team_row.visible = false
	_team_create_row.visible = false
	_game_row.visible = false
	_game_create_row.visible = false
	get_ok_button().disabled = true

func _show_picker() -> void:
	_gate_message.visible = false
	_team_row.visible = true
	_game_row.visible = true
	_team_create_row.visible = false
	_game_create_row.visible = false

## Populates only; the right default differs by caller.
func _populate_team_dropdown() -> void:
	_team_dropdown.clear()
	for i in _teams.size():
		_team_dropdown.add_icon_item(TeamIcon, _teams[i].name)
		_team_dropdown.set_item_metadata(i, _teams[i].id)
	_team_dropdown.add_icon_item(CreateTeamIcon, "Create New Team...")
	_team_dropdown.set_item_metadata(_teams.size(), CREATE_NEW_ID)
	WavedashIconTheme.apply_to_dropdown(_team_dropdown)

func _on_team_selected(index: int) -> void:
	var team_id: String = _team_dropdown.get_item_metadata(index)
	if team_id == CREATE_NEW_ID:
		_team_create_row.visible = true
		_team_create_edit.grab_focus()
		return
	_team_create_row.visible = false
	_selected_team_id = team_id
	_selected_project_id = ""
	_projects = WavedashProjectApi.list_projects(team_id)
	_populate_game_dropdown()
	_apply_game_default(not _projects.is_empty(), 0)
	_update_initialize_enabled()

func _populate_game_dropdown() -> void:
	_game_dropdown.clear()
	for i in _projects.size():
		_game_dropdown.add_icon_item(GameIcon, _projects[i].title)
		_game_dropdown.set_item_metadata(i, _projects[i].id)
	_game_dropdown.add_icon_item(CreateGameIcon, "Create New Game...")
	_game_dropdown.set_item_metadata(_projects.size(), CREATE_NEW_ID)
	WavedashIconTheme.apply_to_dropdown(_game_dropdown)

func _on_game_selected(index: int) -> void:
	var project_id: String = _game_dropdown.get_item_metadata(index)
	if project_id == CREATE_NEW_ID:
		_game_create_row.visible = true
		_game_create_edit.grab_focus()
		return
	_game_create_row.visible = false
	_selected_project_id = project_id
	_update_initialize_enabled()

## An OptionButton displays an item without firing item_selected, so a default has
## to be applied explicitly or it's shown but never acted on. With no real items,
## the create entry isn't a selection either, so reveal the create row instead.
func _select_default(has_real_items: bool, index: int, dropdown: OptionButton, on_selected: Callable, create_row: HBoxContainer, create_edit: LineEdit) -> void:
	if has_real_items:
		dropdown.select(index)
		on_selected.call(index)
	else:
		create_row.visible = true
		create_edit.grab_focus()

func _apply_team_default(has_real_items: bool, index: int) -> void:
	_select_default(has_real_items, index, _team_dropdown, _on_team_selected, _team_create_row, _team_create_edit)

func _apply_game_default(has_real_items: bool, index: int) -> void:
	_select_default(has_real_items, index, _game_dropdown, _on_game_selected, _game_create_row, _game_create_edit)

func _on_create_team_pressed() -> void:
	var name := _team_create_edit.text.strip_edges()
	if name == "":
		return
	var team := WavedashProjectApi.create_team(name)
	if team == null:
		return
	_teams.append(team)
	_team_create_edit.text = ""
	_populate_team_dropdown()
	_apply_team_default(true, _teams.size() - 1)

func _on_create_project_pressed() -> void:
	var title := _game_create_edit.text.strip_edges()
	if title == "" or _selected_team_id == "":
		return
	var project := WavedashProjectApi.create_project(title, _selected_team_id)
	if project == null:
		return
	_projects.append(project)
	_game_create_edit.text = ""
	_populate_game_dropdown()
	_apply_game_default(true, _projects.size() - 1)

func _update_initialize_enabled() -> void:
	get_ok_button().disabled = _selected_team_id == "" or _selected_project_id == ""

## Searches team-by-team because no "get game by id" command exists. Returns
## whether it found a match, so the caller knows if it still needs a default.
func _preselect_existing(game_id: String) -> bool:
	var found := WavedashProjectApi.find_project_with_team(game_id)
	if found.team == null:
		return false
	var team_id: String = found.team.id
	var project_id: String = found.project.id
	var projects := WavedashProjectApi.list_projects(team_id)
	var team_index := WavedashCompat.find_index(_teams, func(t: WavedashProjectApi.Team) -> bool: return t.id == team_id)
	var project_index := WavedashCompat.find_index(projects, func(p: WavedashProjectApi.Project) -> bool: return p.id == project_id)
	if team_index == -1 or project_index == -1:
		return false
	_selected_team_id = team_id
	_projects = projects
	# Selected directly rather than via _select_default(), which would call
	# _on_team_selected() and re-fetch the project list already in hand.
	_team_dropdown.select(team_index)
	_populate_game_dropdown()
	_apply_game_default(true, project_index)
	return true

func _on_initialize() -> void:
	var toml := WavedashToml.read()
	toml.game_id = _selected_project_id
	toml.upload_dir = WavedashExportPresets.derive_upload_dir()
	var version_info := Engine.get_version_info()
	toml.godot_version = "%d.%d" % [version_info.major, version_info.minor]
	var err := toml.write()
	if err != OK:
		# The OK button already auto-hid this dialog, so the console is all that's
		# left to report through.
		WavedashLog.error("Failed to write wavedash.toml: %s" % error_string(err))
		return
	initialized.emit()
