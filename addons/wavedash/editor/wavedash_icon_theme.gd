@tool
extends RefCounted

## Tints and scales this addon's button icons to follow the editor theme.
##
## Source SVGs must be white: Button multiplies its icon by the theme's
## icon_*_color, so anything darker can't reach an arbitrary colour. (Lucide's
## stock stroke="currentColor" imports as pure black, invisible here.)

const WavedashCompat = preload("wavedash_compat.gd")

const ICON_SIZE_PX := 16
const PRESSED_BRIGHTNESS := 1.15

static func apply_to_button(button: Button) -> void:
	button.add_theme_constant_override("icon_max_width", _scaled_icon_width())
	# The theme's own icon colours are opacity-only, since it recolours built-in
	# icons at import time instead -- a pass this addon opts out of. Tracking the
	# label keeps a white icon legible in the light theme.
	var normal := button.get_theme_color("font_color")
	button.add_theme_color_override("icon_normal_color", normal)
	button.add_theme_color_override("icon_focused_color", normal)
	button.add_theme_color_override("icon_hover_color", button.get_theme_color("font_hover_color"))
	button.add_theme_color_override("icon_disabled_color", button.get_theme_color("font_disabled_color"))
	var accent := pressed_accent(button)
	button.add_theme_color_override("icon_pressed_color", accent)
	button.add_theme_color_override("icon_hover_pressed_color", accent)

## Re-run after repopulating: new items arrive unmodulated. The face icon and the
## popup cap separately, and PopupMenu tints per item rather than by theme colour.
static func apply_to_dropdown(dropdown: OptionButton) -> void:
	apply_to_button(dropdown)
	var popup := dropdown.get_popup()
	popup.add_theme_constant_override("icon_max_width", _scaled_icon_width())
	var tint := popup.get_theme_color("font_color")
	for i in popup.item_count:
		if popup.get_item_icon(i) != null:
			popup.set_item_icon_modulate(i, tint)

static func _scaled_icon_width() -> int:
	return roundi(ICON_SIZE_PX * WavedashCompat.editor_scale())

## The theme's stock pressed colour is accent * up to 3.5, which clips above 1.0
## and blows the icon out; plain accent reads too dim.
static func pressed_accent(control: Control) -> Color:
	var accent := control.get_theme_color("accent_color", "Editor") * PRESSED_BRIGHTNESS
	accent.a = 1.0
	return accent
