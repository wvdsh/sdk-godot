@tool
extends RefCounted

## Pops an editor dialog, freeing it once it closes. base_control outlives the
## dock, so a merely-hidden dialog stays parented forever.

const WavedashCompat = preload("wavedash_compat.gd")

## An autowrapping Label asked for its minimum size before it knows its width
## assumes one word per line, which balloons the dialog's height.
const CONTENT_MIN_WIDTH := 350

static func show_dialog(dialog: Window) -> void:
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free()
	)
	if _add_to_editor(dialog):
		dialog.popup_centered()

## popup_file_dialog() routes to the OS dialog when the editor is set to use native
## ones, which never makes the Window visible -- so freeing follows the result signals.
static func show_file_dialog(dialog: EditorFileDialog) -> void:
	dialog.file_selected.connect(func(_path: String) -> void: dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	if _add_to_editor(dialog):
		dialog.popup_file_dialog()

## False if a dialog with this title is already open, which is raised instead.
static func _add_to_editor(dialog: Window) -> bool:
	var base := WavedashCompat.editor_base_control()
	for existing in base.get_children():
		if existing is Window and existing.title == dialog.title:
			dialog.queue_free()
			existing.move_to_foreground()
			existing.grab_focus()
			return false
	base.add_child(dialog)
	return true
