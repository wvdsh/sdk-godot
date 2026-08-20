# Appended verbatim to the end of the generated WavedashTypes.gd, so these read as
# WavedashTypes.<Name> alongside the generated models rather than as extra global
# class names.
#
# This is the home for types the generator cannot derive: sdk-js declares no method
# to build them from, either because the call is synchronous (so there is no
# WavedashResponse<T> to monomorphize) or because it never crosses the bridge at all.
# Anything sdk-js *does* declare belongs in the IR, not here — adding it by hand
# means it stops tracking upstream.
#
# Indented at column 0 like the generated classes: `class X` at the top level of a
# file with a class_name becomes an inner class of it.


## Widths the avatar CDN will transform to, and what each is sized for. Suggestions,
## not a closed set — get_user_avatar_url() passes the int straight through, so any
## width works and these are the ones worth reaching for first.
const AVATAR_SIZE_SMALL = 64  # lists, chat bubbles
const AVATAR_SIZE_MEDIUM = 128  # profile cards
const AVATAR_SIZE_LARGE = 256  # large displays

## A file download_content() saved. It returns one of these or null.
class ContentDownload extends RefCounted:
	## Relative to your build root, as passed in — e.g. "dlc/full.pck".
	var item_path: String = ""

	## Where it landed, ready to hand to ProjectSettings.load_resource_pack().
	var local_path: String = ""

	var size_bytes: int = 0

