@tool
extends RefCounted

## Both retry once with a re-resolved path, for a cached path that exists but no longer spawns.

const WavedashCli = preload("wavedash_cli.gd")
const WavedashOSProcess = preload("wavedash_os_process.gd")

class Result:
	var ok := false
	var exit_code := -1
	var output := ""

class JsonResult extends Result:
	var data: Variant = null

const NOT_FOUND_EXIT_CODE := -1
const SPAWN_ATTEMPTS := 2

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

static func run_json(args: PackedStringArray) -> JsonResult:
	var result := JsonResult.new()
	_execute(args, result)
	if result.ok:
		# Not JSON.parse_string(): it prints an engine error on bad input, and prose instead of JSON is normal here.
		var json := JSON.new()
		if json.parse(_json_body(result.output)) == OK:
			result.data = json.data
	return result

## stderr is captured alongside stdout, so CLI notices such as "Update available" land on either side of the JSON.
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

static func _execute(args: PackedStringArray, result: Result) -> void:
	if not Engine.is_editor_hint():
		push_error(WavedashCli.BLOCKED_MESSAGE)
		return
	var output := []
	for attempt in SPAWN_ATTEMPTS:
		var exe := WavedashCli.resolve_executable()
		if exe == "":
			return
		output.clear()
		result.exit_code = OS.execute(exe, args, output, true)
		if result.exit_code != NOT_FOUND_EXIT_CODE:
			break
		WavedashCli.report_unrunnable()
	result.output = "\n".join(output).strip_edges()
	result.ok = result.exit_code == 0
