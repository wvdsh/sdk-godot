@tool
extends RefCounted

## Both retry once with a re-resolved path, for a cached path that exists but no longer spawns.

const WavedashCli = preload("wavedash_cli.gd")
const WavedashOSProcess = preload("wavedash_os_process.gd")
const WavedashCompat = preload("wavedash_compat.gd")
const WavedashLog = preload("wavedash_log.gd")

class Result:
	var ok := false
	var exit_code := -1
	var output := ""

class JsonResult extends Result:
	var data: Variant = null

const NOT_FOUND_EXIT_CODE := -1
const TIMED_OUT_EXIT_CODE := -2
const SPAWN_ATTEMPTS := 2
const POLL_MSEC := 10

const STATUS_TIMEOUT_MSEC := 5_000
const LIST_TIMEOUT_MSEC := 5_000
const CREATE_TIMEOUT_MSEC := 10_000

static func auth_status() -> JsonResult:
	return _run_json(["auth", "status", "--json"], STATUS_TIMEOUT_MSEC)

static func team_list() -> JsonResult:
	return _run_json(["team", "list", "--json"], LIST_TIMEOUT_MSEC)

static func project_list(team_id: String) -> JsonResult:
	return _run_json(["project", "list", "--team-id", team_id, "--json"], LIST_TIMEOUT_MSEC)

static func team_create(name: String) -> Result:
	return _run(["team", "create", "--name", name], CREATE_TIMEOUT_MSEC)

static func project_create(title: String, team_id: String) -> Result:
	return _run(["project", "create", "--title", title, "--team-id", team_id], CREATE_TIMEOUT_MSEC)

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

static func _run(args: PackedStringArray, timeout_msec: int) -> Result:
	var result := Result.new()
	_execute(args, timeout_msec, result)
	return result

static func _run_json(args: PackedStringArray, timeout_msec: int) -> JsonResult:
	var result := JsonResult.new()
	_execute(args, timeout_msec, result)
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

static func _execute(args: PackedStringArray, timeout_msec: int, result: Result) -> void:
	if not Engine.is_editor_hint():
		push_error(WavedashCli.BLOCKED_MESSAGE)
		return
	var output := PackedStringArray()
	for attempt in SPAWN_ATTEMPTS:
		var exe := WavedashCli.resolve_executable()
		if exe == "":
			return
		output.clear()
		result.exit_code = _run_bounded(exe, args, timeout_msec, output)
		if result.exit_code != NOT_FOUND_EXIT_CODE:
			break
		WavedashCli.report_unrunnable()
	if result.exit_code == TIMED_OUT_EXIT_CODE:
		WavedashLog.warning("wavedash %s gave no answer within %d seconds and was stopped." % [" ".join(args), timeout_msec / 1000])
	result.output = "\n".join(output).strip_edges()
	result.ok = result.exit_code == 0

## Blocks like OS.execute() would, but never past the deadline: the process is killed instead.
static func _run_bounded(exe: String, args: PackedStringArray, timeout_msec: int, output: PackedStringArray) -> int:
	var process := WavedashCompat.os_execute_with_pipe(exe, args, false)
	if process.is_empty():
		return NOT_FOUND_EXIT_CODE
	var pid: int = process.pid
	var deadline := Time.get_ticks_msec() + timeout_msec
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() >= deadline:
			OS.kill(pid)
			return TIMED_OUT_EXIT_CODE
		output.append_array(WavedashOSProcess.read_available_lines(process.stdio))
		output.append_array(WavedashOSProcess.read_available_lines(process.stderr))
		OS.delay_msec(POLL_MSEC)
	output.append_array(WavedashOSProcess.read_available_lines(process.stdio))
	output.append_array(WavedashOSProcess.read_available_lines(process.stderr))
	return WavedashCompat.os_get_process_exit_code(pid)
