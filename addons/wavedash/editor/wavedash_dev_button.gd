@tool
extends Button

## Main-toolbar "Dev on Wavedash" button: exports the active preset, then runs
## `wavedash dev` against it, becoming a stop control while a session is running.

const WavedashStepSequence = preload("wavedash_step_sequence.gd")
const WavedashGate = preload("wavedash_gate.gd")
const WavedashIcon = preload("assets/wavedash_white.svg")
const WavedashIconTheme = preload("wavedash_icon_theme.gd")
const WavedashCompat = preload("wavedash_compat.gd")

signal log_line(text: String)

var _sequence: WavedashStepSequence

const IDLE_TOOLTIP := "Run the project in your browser with a local Wavedash server with all SDK features"

## Setup here would dirty the open scene and bake session state into a shipped .tscn.
@onready var _in_edited_scene := WavedashCompat.is_part_of_edited_scene(self)

func _ready() -> void:
	if _in_edited_scene:
		return
	icon = WavedashIcon
	_apply_theme_aware_icon_styling()
	# On only so button_pressed can render the latched look; not user-toggleable.
	toggle_mode = true
	_sequence = WavedashStepSequence.new()
	add_child(_sequence)
	_sequence.configure(WavedashStepSequence.dev())
	_sequence.output_line.connect(func(text: String) -> void: log_line.emit(text))
	_sequence.state_changed.connect(_on_state_changed)
	pressed.connect(_on_pressed)
	refresh_tooltip()

## Public: the dock re-runs this whenever anything the gate reads changes. Stays
## clickable when blocked -- the export step reports the reason to the
## console and the dock log on the attempt, which beats an unexplained dead button.
func refresh_tooltip() -> void:
	if _sequence.is_running():
		return
	var blocker := WavedashGate.check_can_build().detailed_description
	tooltip_text = blocker if blocker != "" else IDLE_TOOLTIP

func _notification(what: int) -> void:
	if _in_edited_scene:
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme_aware_icon_styling()

## add_theme_*_override() re-triggers NOTIFICATION_THEME_CHANGED on this node,
## re-entering the styling function.
var _applying_icon_style := false

func _apply_theme_aware_icon_styling() -> void:
	if _applying_icon_style:
		return
	_applying_icon_style = true
	var color := get_theme_color("font_color", "Editor")
	for property in ["icon_normal_color", "icon_hover_color", "icon_disabled_color", "icon_focused_color"]:
		add_theme_color_override(property, color)
	var accent := WavedashIconTheme.pressed_accent(self)
	for property in ["icon_pressed_color", "icon_hover_pressed_color"]:
		add_theme_color_override(property, accent)
	var size_px := WavedashIconTheme.ICON_SIZE_PX
	add_theme_constant_override("icon_max_width", roundi(size_px * WavedashCompat.editor_scale()))
	_square_up_margins()
	_applying_icon_style = false

func _square_up_margins() -> void:
	for state in ["normal", "hover", "pressed", "disabled", "hover_pressed"]:
		# Clear before reading: this overrides the property it reads from.
		if has_theme_stylebox_override(state):
			remove_theme_stylebox_override(state)
		var box: StyleBox = get_theme_stylebox(state).duplicate()
		var side := maxf(box.content_margin_left, box.content_margin_top)
		box.content_margin_left = side
		box.content_margin_right = side
		box.content_margin_top = side
		box.content_margin_bottom = side
		add_theme_stylebox_override(state, box)

func _on_pressed() -> void:
	if _sequence.is_running():
		_sequence.stop()
	else:
		_sequence.start()
	_sync_pressed_from_state()

## The only place button_pressed is written. toggle_mode makes Godot flip it on
## every click, which otherwise leaves it latched when the gate refuses start().
func _sync_pressed_from_state() -> void:
	button_pressed = _sequence.is_running()

func _on_state_changed(state: WavedashStepSequence.State) -> void:
	match state:
		WavedashStepSequence.State.IDLE:
			refresh_tooltip()
		WavedashStepSequence.State.EXPORTING:
			tooltip_text = "Exporting... (click to stop)"
		WavedashStepSequence.State.ACTIVE:
			tooltip_text = "Stop local dev server"
	_sync_pressed_from_state()
