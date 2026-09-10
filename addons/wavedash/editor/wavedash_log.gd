@tool
extends RefCounted

const PREFIX := "[Wavedash] "
const SEE_DOCK := " (open the Wavedash dock for full output)"

static func console(text: String) -> void:
	print(PREFIX + text)

static func console_started(text: String) -> void:
	print(PREFIX + text + SEE_DOCK)

static func error(text: String) -> void:
	push_error(PREFIX + text)

static func warning(text: String) -> void:
	push_warning(PREFIX + text)

## Only print_rich() marks output as BBCode, which is what makes [url] clickable.
static func console_link(text: String, url: String) -> void:
	print_rich("%s%s[url]%s[/url]" % [PREFIX, text, url])
