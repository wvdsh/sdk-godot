@tool
extends HBoxContainer

## "Export preset: <dropdown>" row. Also drives the Create Wavedash Export button, a
## sibling below this row so it can span the dock's full width. Whether the chosen preset
## can actually build is reported by WavedashBuildUploadRow, not here.

const WavedashExportPresets = preload("wavedash_export_presets.gd")
const WavedashDialogs = preload("wavedash_dialogs.gd")
const WavedashIconTheme = preload("wavedash_icon_theme.gd")
const PresetIcon = preload("assets/package_white.svg")
const CreatePresetIcon = preload("assets/package_plus_white.svg")
const WavedashCompat = preload("wavedash_compat.gd")

signal log_line(text: String)
signal status_changed

## Setup here would dirty the open scene and bake session state into a shipped .tscn.
@onready var _in_edited_scene := WavedashCompat.is_part_of_edited_scene(self)

@onready var _dropdown: OptionButton = $Dropdown
@onready var _none_found_label: Label = $NoneFoundLabel
@onready var _create_button: Button = %CreateDefaultButton

func _ready() -> void:
	if _in_edited_scene:
		return
	_dropdown.item_selected.connect(_on_preset_selected)
	_create_button.pressed.connect(_on_create_default_pressed)
	visibility_changed.connect(_refresh)
	_create_button.icon = CreatePresetIcon
	WavedashIconTheme.apply_to_button(_create_button)
	_refresh()
	_connect_export_dialog_refresh()

func _notification(what: int) -> void:
	if _in_edited_scene:
		return
	if what == NOTIFICATION_THEME_CHANGED and _create_button:
		WavedashIconTheme.apply_to_button(_create_button)
		WavedashIconTheme.apply_to_dropdown(_dropdown)

## There's no signal for "export presets changed", and EditorExport isn't exposed
## to scripting. Project > Export's dialog does already exist as a node under
## base_control, so its visibility_changed stands in for one.
func _connect_export_dialog_refresh() -> void:
	for child in WavedashCompat.editor_base_control().get_children():
		if child.get_class() == "ProjectExportDialog":
			child.visibility_changed.connect(_refresh)
			return

func _refresh() -> void:
	var names := WavedashExportPresets.get_available_presets()
	_dropdown.visible = not names.is_empty()
	_none_found_label.visible = names.is_empty()
	_dropdown.clear()
	var active_name := WavedashExportPresets.get_active_preset()
	for i in names.size():
		_dropdown.add_icon_item(PresetIcon, names[i])
		if names[i] == active_name:
			_dropdown.select(i)
	WavedashIconTheme.apply_to_dropdown(_dropdown)
	status_changed.emit()

## Changing preset changes whether a build is possible, so announce it rather
## than rebuilding the dropdown from inside its own item_selected handler.
func _on_preset_selected(index: int) -> void:
	WavedashExportPresets.set_active_preset(_dropdown.get_item_text(index))
	status_changed.emit()

## Creates and reloads in one step, with no deferrable gap: Godot only reads
## export_presets.cfg at project open, and opening Project > Export while its
## in-memory list is stale makes it overwrite the file, deleting the new preset.
## A full reload is also the only way to register a preset from scripting.
func _on_create_default_pressed() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Create Wavedash Export?"
	dialog.dialog_text = "Creates a Wavedash export preset and reloads the project so Godot picks it up. Unsaved changes will be saved first."
	dialog.get_ok_button().text = "Create and Reload"
	dialog.confirmed.connect(func() -> void:
		var preset_name := WavedashExportPresets.create_default_web_preset()
		log_line.emit("Created default Web export preset '%s' -- reloading project..." % preset_name)
		WavedashCompat.restart_editor(true)
	)
	WavedashDialogs.show_dialog(dialog)
