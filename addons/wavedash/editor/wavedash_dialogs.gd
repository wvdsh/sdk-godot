@tool
extends RefCounted

## Pops an editor dialog, freeing it once it closes. base_control outlives the
## dock, so a merely-hidden dialog stays parented forever.

const WavedashCompat = preload("wavedash_compat.gd")

## An autowrapping Label asked for its minimum size before it knows its width
## assumes one word per line, which balloons the dialog's height.
const CONTENT_MIN_WIDTH := 350

static func show_dialog(dialog: Window) -> void:
	var base := WavedashCompat.editor_base_control()
	for existing in base.get_children():
		if existing is Window and existing.title == dialog.title:
			dialog.queue_free()
			existing.move_to_foreground()
			existing.grab_focus()
			return
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free()
	)
	base.add_child(dialog)
	dialog.popup_centered()
