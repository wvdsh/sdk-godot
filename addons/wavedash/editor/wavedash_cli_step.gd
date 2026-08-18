@tool
extends "wavedash_process_step.gd"

## One Wavedash CLI command. `args` is set by whoever builds the step, so the
## argument list can be checked without launching anything.

const WavedashCli = preload("wavedash_cli.gd")
const WavedashCliRunner = preload("wavedash_cli_runner.gd")

## Reads in messages about this command, e.g. "wavedash build push aborted".
var noun := "wavedash"
var args := PackedStringArray()

func _args() -> PackedStringArray:
	return args

## Resolution and the stale-path retry belong to WavedashCliRunner.
func _spawn() -> WavedashOSProcess:
	return WavedashCliRunner.start_streaming(self, args)

func _on_line(line: String) -> void:
	super(line)
	if line.contains(WavedashCli.AUTH_FAILURE_SIGNATURE):
		output_line.emit("Your Wavedash sign-in looks invalid -- use Log Out then Sign In again in the Wavedash Account row to reconnect.")
