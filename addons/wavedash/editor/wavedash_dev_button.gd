@tool
extends Button

const WavedashStepSequence = preload("wavedash_step_sequence.gd")
const WavedashGate = preload("wavedash_gate.gd")
const WavedashIcon = preload("assets/wavedash_white.svg")
const WavedashIconTheme = preload("wavedash_icon_theme.gd")
const WavedashCompat = preload("wavedash_compat.gd")

signal log_line(text: String)

var _sequence: WavedashStepSequence

const IDLE_TOOLTIP := "Run in the browser against a local Wavedash server"

@onready var _in_edited_scene := WavedashCompat.is_part_of_edited_scene(self)

func _ready() -> void:
	if _in_edited_scene:
		return
	icon = WavedashIcon
	_apply_theme_aware_icon_styling()
	# Only so button_pressed can render the latched look; not user-toggleable.
	toggle_mode = true
	_sequence = WavedashStepSequence.new()
	add_child(_sequence)
	_sequence.configure(WavedashStepSequence.dev())
	_sequence.output_line.connect(func(text: String) -> void: log_line.emit(text))
	_sequence.state_changed.connect(_on_state_changed)
	pressed.connect(_on_pressed)
	refresh_tooltip()

## Stays clickable when blocked: the export step reports the reason on the attempt.
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

## add_theme_*_override() re-triggers NOTIFICATION_THEME_CHANGED on this node.
var _applying_icon_style := false

func _apply_theme_aware_icon_styling() -> void:
	if _applying_icon_style:
		return
	_applying_icon_style = true
	WavedashIconTheme.apply_to_button(self)
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

## toggle_mode flips button_pressed on every click, which would leave it latched when start() is refused.
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
