@tool
extends RefCounted

## The one way to invoke the CLI: run()/run_json() wait for an answer,
## start_streaming() hands back a live process instead.
##
## Both retry once with a re-resolved path. resolve_executable() already drops a
## cached path whose file is gone, so this covers the case it cannot see: present but
## unspawnable. Re-resolving revalidates candidates with --version, skipping it.

const WavedashCli = preload("wavedash_cli.gd")
const WavedashOSProcess = preload("wavedash_os_process.gd")

## `ok` only when the executable was found and exited 0; the other flags separate
## that from a real command failure.
class Result:
	var ok := false
	var cli_missing := false
	var blocked_outside_editor := false
	var exit_code := -1
	var output := ""

class JsonResult extends Result:
	var data: Variant = null

const NOT_FOUND_EXIT_CODE := -1
const SPAWN_ATTEMPTS := 2

## `host` parents the process. Null when nothing could be started.
static func start_streaming(host: Node, args: PackedStringArray) -> WavedashOSProcess:
	if not Engine.is_editor_hint():
		push_error(WavedashCli.BLOCKED_MESSAGE)
		return null
	var process := WavedashOSProcess.new()
	host.add_child(process)
	for attempt in SPAWN_ATTEMPTS:
		var exe := WavedashCli.resolve_executable()
		if exe == "":
			break
		if process.start(exe, args):
			return process
		WavedashCli.report_unrunnable()
	process.queue_free()
	return null

static func run(args: PackedStringArray) -> Result:
	var result := Result.new()
	_execute(args, result)
	return result

## Same as run(), but parses `output` as JSON on success.
static func run_json(args: PackedStringArray) -> JsonResult:
	var result := JsonResult.new()
	_execute(args, result)
	if result.ok:
		# Not JSON.parse_string(): it prints an engine error on bad input, and a
		# CLI that returned prose instead of JSON is a normal outcome here.
		var json := JSON.new()
		if json.parse(_json_body(result.output)) == OK:
			result.data = json.data
	return result

## stderr is captured alongside stdout, so the CLI's notices land in the text
## being parsed -- "Update available: ... Run: wavedash update" most notably,
## intermittently and on either side of the JSON. Hence the span from the first
## opening delimiter to the last matching closer.
static func _json_body(output: String) -> String:
	var open_at := -1
	var closer := ""
	for delimiters in [["{", "}"], ["[", "]"]]:
		var opened_at := output.find(delimiters[0])
		if opened_at != -1 and (open_at == -1 or opened_at < open_at):
			open_at = opened_at
			closer = delimiters[1]
	if open_at == -1:
		return output
	var close_at := output.rfind(closer)
	return output.substr(open_at, close_at - open_at + 1) if close_at > open_at else output.substr(open_at)

## Fills in whichever result type it's handed, so callers don't copy fields
## between two of them.
static func _execute(args: PackedStringArray, result: Result) -> void:
	if not Engine.is_editor_hint():
		result.blocked_outside_editor = true
		push_error(WavedashCli.BLOCKED_MESSAGE)
		return
	var output := []
	for attempt in SPAWN_ATTEMPTS:
		var exe := WavedashCli.resolve_executable()
		if exe == "":
			result.cli_missing = true
			return
		output.clear()
		result.exit_code = OS.execute(exe, args, output, true)
		if result.exit_code != NOT_FOUND_EXIT_CODE:
			break
		WavedashCli.report_unrunnable()
	result.output = "\n".join(output).strip_edges()
	result.ok = result.exit_code == 0
