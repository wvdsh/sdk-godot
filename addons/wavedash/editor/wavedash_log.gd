@tool
extends RefCounted

## Milestone-only logging to Godot's Output panel. The dock's log carries every
## raw line; this carries start/hand-off/finish/failure so a long run is visible
## without the dock open.

const PREFIX := "[Wavedash] "
const SEE_DOCK := " (open the Wavedash dock for full output)"

static func console(text: String) -> void:
	print(PREFIX + text)

static func console_started(text: String) -> void:
	print(PREFIX + text + SEE_DOCK)

## Red in the Output panel, and listed in the Debugger's Errors tab.
static func error(text: String) -> void:
	push_error(PREFIX + text)

## Yellow in the Output panel. For things that let the action proceed but are
## likely to make it do the wrong thing.
static func warning(text: String) -> void:
	push_warning(PREFIX + text)

## print_rich, not print: only print_rich marks output as BBCode, which is what
## makes the Output panel turn [url] into a real clickable link.
static func console_link(text: String, url: String) -> void:
	print_rich("%s%s[url]%s[/url]" % [PREFIX, text, url])
