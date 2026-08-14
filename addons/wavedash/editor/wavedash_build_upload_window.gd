@tool
extends AcceptDialog

## Build-push popup. Publishing is left to the wavedash.com builds page.
##
## get_ok_button() is reserved for the final "Done" close action: AcceptDialog
## auto-hides whenever its own OK button is pressed, whatever `confirmed`'s
## listeners do, so the multi-second push needs a separate PushButton.

const WavedashGate = preload("wavedash_gate.gd")
const WavedashToml = preload("wavedash_toml.gd")
const WavedashProjectApi = preload("wavedash_project_api.gd")
const WavedashStepSequence = preload("wavedash_step_sequence.gd")
const WavedashBuildPushStep = preload("wavedash_build_push_step.gd")
const WavedashIconTheme = preload("wavedash_icon_theme.gd")
const WavedashCompat = preload("wavedash_compat.gd")

signal log_line(text: String)

@onready var _gate_message: Label = $Content/GateMessage
@onready var _message_row: HBoxContainer = $Content/MessageRow
@onready var _message_edit: LineEdit = $Content/MessageRow/MessageEdit
@onready var _push_button: Button = $Content/PushButton
@onready var _progress_bar: ProgressBar = $Content/ProgressBar
@onready var _status_label: Label = $Content/StatusLabel
@onready var _result_container: VBoxContainer = $Content/ResultContainer
@onready var _build_id_label: Label = $Content/ResultContainer/BuildIdLabel
@onready var _play_button: Button = $Content/ResultContainer/PlayButton
@onready var _manage_builds_button: Button = $Content/ResultContainer/ManageBuildsButton

const VIEW_GATE := 0
const VIEW_FORM := 1
const VIEW_PUSHING := 2
const VIEW_RESULT := 3

var _sequence: WavedashStepSequence
var _push: WavedashBuildPushStep
var _playtest_url := ""

## Setup here would dirty the open scene and bake session state into a shipped .tscn.
@onready var _in_edited_scene := WavedashCompat.is_part_of_edited_scene(self)

func _ready() -> void:
	if _in_edited_scene:
		return
	get_ok_button().text = "Done"
	get_ok_button().visible = false
	_push_button.pressed.connect(_on_push_pressed)
	WavedashIconTheme.apply_to_button(_push_button)
	_play_button.pressed.connect(_on_play_pressed)
	_manage_builds_button.pressed.connect(_on_manage_builds_pressed)
	_sequence = WavedashStepSequence.new()
	add_child(_sequence)
	_sequence.configure(WavedashStepSequence.upload())
	_sequence.output_line.connect(func(text: String) -> void: log_line.emit(text))
	_sequence.state_changed.connect(_on_state_changed)
	_sequence.progress_changed.connect(_on_progress_changed)
	_push = _sequence.find_step(WavedashBuildPushStep)
	_push.succeeded.connect(_on_push_succeeded)
	_refresh()

func _notification(what: int) -> void:
	if _in_edited_scene:
		return
	if what == NOTIFICATION_THEME_CHANGED and _push_button:
		WavedashIconTheme.apply_to_button(_push_button)

func _refresh() -> void:
	var gate := WavedashGate.check_can_build().detailed_description
	if gate != "":
		_gate_message.text = gate
		_set_view(VIEW_GATE)
	else:
		_set_view(VIEW_FORM)

func _set_view(view: int) -> void:
	_gate_message.visible = view == VIEW_GATE
	_message_row.visible = view == VIEW_FORM or view == VIEW_PUSHING
	_push_button.visible = view == VIEW_FORM or view == VIEW_PUSHING
	_progress_bar.visible = view == VIEW_PUSHING
	_status_label.visible = view == VIEW_PUSHING
	_result_container.visible = view == VIEW_RESULT
	get_ok_button().visible = view == VIEW_RESULT
	_push_button.disabled = view == VIEW_PUSHING
	_message_edit.editable = view == VIEW_FORM

## The view only advances once the export is actually running -- a refused launch
## would otherwise leave this stuck on a progress view nothing will ever update.
func _on_push_pressed() -> void:
	if _sequence.is_running():
		return
	_push.message = _message_edit.text.strip_edges()
	if not _sequence.start():
		return
	_set_view(VIEW_PUSHING)

## State.IDLE here is the failure path; success goes through _on_push_succeeded()
## and shows the result view instead of resetting the form.
func _on_state_changed(state: WavedashStepSequence.State) -> void:
	match state:
		WavedashStepSequence.State.EXPORTING, WavedashStepSequence.State.ACTIVE:
			_status_label.text = "%s..." % _sequence.current_label()
			_progress_bar.value = 0
		WavedashStepSequence.State.IDLE:
			if not _result_container.visible:
				_set_view(VIEW_FORM)

## `description` is what makes a resetting percentage make sense, so show it
## whenever there is one.
func _on_progress_changed(percent: int, description: String) -> void:
	_progress_bar.value = percent
	var verb := _sequence.current_label()
	if description != "":
		_status_label.text = "%s: %d%% -- %s" % [verb, percent, description]
	else:
		_status_label.text = "%s: %d%%" % [verb, percent]

func _on_push_succeeded(build_id: String, playtest_url: String) -> void:
	_build_id_label.text = "Build pushed, with id: %s" % build_id
	_playtest_url = playtest_url
	_play_button.tooltip_text = playtest_url
	_play_button.visible = playtest_url != ""
	var toml := WavedashToml.read()
	_manage_builds_button.visible = toml.exists and toml.game_id != ""
	_set_view(VIEW_RESULT)

## Deliberately leaves the dialog open, unlike Manage Builds -- the result view
## is unreachable again without pushing another build.
func _on_play_pressed() -> void:
	OS.shell_open(_playtest_url)

## Slugs are resolved on the click, not when the result appears: the lookup is
## 1+N blocking CLI spawns and froze the editor right as the result arrived.
func _on_manage_builds_pressed() -> void:
	OS.shell_open(_builds_page_url())
	hide()

func _builds_page_url() -> String:
	var toml := WavedashToml.read()
	var found := WavedashProjectApi.find_project_with_team(toml.game_id)
	if found.team == null or found.team.slug == "" or found.project.slug == "":
		return "https://wavedash.com/dev-portal"
	return "https://wavedash.com/dev-portal/%s/%s/builds" % [found.team.slug, found.project.slug]
