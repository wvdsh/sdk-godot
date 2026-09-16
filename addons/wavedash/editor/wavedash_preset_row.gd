@tool
extends HBoxContainer

const WavedashExportPresets = preload("wavedash_export_presets.gd")
const WavedashDialogs = preload("wavedash_dialogs.gd")
const WavedashIconTheme = preload("wavedash_icon_theme.gd")
const PresetIcon = preload("assets/package_white.svg")
const CreateIcon = preload("assets/package_plus_white.svg")
const WavedashCompat = preload("wavedash_compat.gd")
const WavedashGdextensions = preload("wavedash_gdextensions.gd")

## Long enough to cover EditorExport's own 0.8s save timer.
const EXPORT_PRESETS_SAVE_DELAY := 1.0
const ROOT_EXPORT_PATH_REJECTED := "Exporting into \"%s\" would cause Wavedash to upload your whole project."

const CREATE_NEW_ID := "__create_new__"

signal log_line(text: String)
signal status_changed

@onready var _in_edited_scene := WavedashCompat.is_part_of_edited_scene(self)

@onready var _dropdown: OptionButton = $Controls/Dropdown
@onready var _create_button: Button = $Controls/CreateButton
@onready var _edit_button: Button = $Controls/EditButton

func _ready() -> void:
	if _in_edited_scene:
		return
	_dropdown.item_selected.connect(_on_preset_selected)
	_create_button.pressed.connect(_on_create_pressed)
	_edit_button.pressed.connect(_open_export_dialog)
	visibility_changed.connect(_refresh)
	WavedashIconTheme.apply_to_button(_create_button)
	WavedashIconTheme.apply_to_button(_edit_button)
	_dropdown.resized.connect(_square_edit_button)
	_refresh()
	_connect_export_dialog_refresh()

func _notification(what: int) -> void:
	if _in_edited_scene:
		return
	if what == NOTIFICATION_THEME_CHANGED and _create_button:
		WavedashIconTheme.apply_to_button(_create_button)
		WavedashIconTheme.apply_to_button(_edit_button)
		WavedashIconTheme.apply_to_dropdown(_dropdown)

## There's no signal for "export presets changed"; Project > Export's visibility_changed stands in for one.
func _connect_export_dialog_refresh() -> void:
	for child in WavedashCompat.editor_base_control().get_children():
		if child.get_class() == "ProjectExportDialog":
			child.visibility_changed.connect(_refresh)
			child.visibility_changed.connect(_refresh_once_saved)
			return

## Godot debounces its export_presets.cfg write, so a refresh on close can land before the file is rewritten.
func _refresh_once_saved() -> void:
	var before := FileAccess.get_md5(WavedashExportPresets.EXPORT_PRESETS_PATH)
	await get_tree().create_timer(EXPORT_PRESETS_SAVE_DELAY).timeout
	if is_inside_tree() and FileAccess.get_md5(WavedashExportPresets.EXPORT_PRESETS_PATH) != before:
		_refresh()

func _refresh() -> void:
	var names := WavedashExportPresets.get_available_presets()
	_dropdown.visible = not names.is_empty()
	_create_button.visible = names.is_empty()
	_dropdown.clear()
	for i in names.size():
		_dropdown.add_icon_item(PresetIcon, names[i])
		_dropdown.set_item_metadata(i, names[i])
	_dropdown.add_separator()
	_dropdown.add_icon_item(CreateIcon, "Create New Wavedash Export...")
	_dropdown.set_item_metadata(_dropdown.item_count - 1, CREATE_NEW_ID)
	_select_active()
	WavedashIconTheme.apply_to_dropdown(_dropdown)
	status_changed.emit()

## OptionButton shows whatever was picked, actions included.
func _select_active() -> void:
	var active_name := WavedashExportPresets.get_active_preset()
	for i in _dropdown.item_count:
		if _dropdown.get_item_metadata(i) == active_name:
			_dropdown.select(i)
			return

func _on_preset_selected(index: int) -> void:
	var id: String = _dropdown.get_item_metadata(index)
	if id == CREATE_NEW_ID:
		_on_create_pressed()
	else:
		WavedashExportPresets.set_active_preset(id)
		status_changed.emit()
	_select_active()

## The row is as tall as the dropdown's text line, and the icon alone is shorter than that.
func _square_edit_button() -> void:
	_edit_button.custom_minimum_size.x = _dropdown.size.y

## Popping the ProjectExportDialog node directly shows an empty preset list; only Godot's own menu handler fills it.
func _open_export_dialog() -> void:
	if not WavedashCompat.activate_editor_menu_item("Export..."):
		log_line.emit("Couldn't find Project > Export in the editor menu.")

func _on_create_pressed() -> void:
	var root_dir := ProjectSettings.globalize_path("res://")
	var suggested := WavedashExportPresets.globalize_export_path(WavedashExportPresets.suggested_export_path())
	var start_dir := suggested.get_base_dir()
	if not DirAccess.dir_exists_absolute(start_dir):
		start_dir = root_dir

	var dialog := EditorFileDialog.new()
	dialog.title = "Choose Wavedash Export Path"
	dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	dialog.add_filter("*.%s" % WavedashExportPresets.WEB_EXTENSION, "Web Export")
	dialog.ok_button_text = "Select"
	dialog.current_dir = start_dir
	dialog.current_file = suggested.get_file()
	dialog.file_selected.connect(_confirm_create)
	WavedashDialogs.show_file_dialog(dialog)

## Godot only reads export_presets.cfg at project open, and opening Project > Export while its in-memory
## list is stale overwrites the file. A reload is also the only way to register a preset from scripting.
func _confirm_create(global_path: String) -> void:
	var export_path := WavedashExportPresets.localize_export_path(global_path)
	if WavedashExportPresets.export_dir_contains_project(export_path):
		_reject_root_export_path(export_path)
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Create Wavedash Export?"
	dialog.dialog_text = "Creates a Web export preset for \"%s\". The project is saved and reloaded so Godot picks it up." % export_path
	dialog.dialog_text += _gdextension_note()
	dialog.get_ok_button().text = "Create and Reload"
	dialog.confirmed.connect(func() -> void:
		var preset_name := WavedashExportPresets.create_default_web_preset(export_path)
		log_line.emit("Created Web export preset '%s' exporting to \"%s\" -- reloading project..." % [preset_name, export_path])
		WavedashCompat.restart_editor(true)
	)
	WavedashDialogs.show_dialog(dialog)

func _gdextension_note() -> String:
	var note := ""
	var web := WavedashGdextensions.with_web_build()
	if not web.is_empty():
		note += "\n\nExtensions Support will be on for: %s" % ", ".join(web)
	var warning := WavedashGdextensions.no_web_build_warning()
	if warning != "":
		note += "\n\n" + warning
	return note

func _reject_root_export_path(export_path: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Choose a Build Folder"
	dialog.dialog_text = ROOT_EXPORT_PATH_REJECTED % WavedashExportPresets.export_dir(export_path)
	dialog.get_ok_button().text = "Choose Another Path"
	dialog.add_cancel_button("Cancel")
	dialog.confirmed.connect(_on_create_pressed)
	WavedashDialogs.show_dialog(dialog)
