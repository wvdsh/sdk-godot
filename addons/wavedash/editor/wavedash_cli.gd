@tool
extends RefCounted

## Locates, checks, and (re)installs the Wavedash CLI binary.

## A path plus arguments, ready to pass straight to OS.execute or
## WavedashOSProcess.start().
class ShellCommand:
	var path := ""
	var arguments := PackedStringArray()

const WavedashCompat = preload("wavedash_compat.gd")
const BLOCKED_MESSAGE := "Wavedash CLI tooling is editor-only, it will not work in an exported/running game."

## Every CLI 401 produces this exact string, whatever the command.
const AUTH_FAILURE_SIGNATURE := "Authentication failed. Run"

const EXECUTABLE_KEY := "cli_executable"
## resolve_executable() already runs --version to validate a candidate, so the
## string it printed is kept rather than spawning the process a second time.
const VERSION_KEY := "cli_version"

## The installers add their bin dir to PATH, but PATH changes don't reach an
## already-running editor -- so a CLI installed this session is only findable here.
static func _fallback_install_dirs() -> Array[String]:
	var cargo_home := OS.get_environment("CARGO_HOME")
	if cargo_home == "":
		var home := OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")
		cargo_home = home.path_join(".cargo")
	return [cargo_home.path_join("bin")]

## Searched manually so a missing CLI never reaches OS.execute at all: a failed
## spawn logs an engine-level error that can't be suppressed from script.
static func _path_dirs() -> Array[String]:
	var separator := ";" if OS.get_name() == "Windows" else ":"
	var dirs: Array[String] = []
	for dir in OS.get_environment("PATH").split(separator):
		if dir != "":
			dirs.append(dir)
	return dirs

static func _binary_filename() -> String:
	return "wavedash.exe" if OS.get_name() == "Windows" else "wavedash"

## Absolute path to the CLI binary, or "" if not found. A "not found" result is
## never cached, so a mid-session install is picked up on the next call.
##
## A cached hit is confirmed to still exist before being handed back -- an uninstall
## or a moved binary would otherwise keep resolving to a dead path for the rest of
## the session. That check is a stat, not the --version spawn a fresh resolve needs.
static func resolve_executable() -> String:
	if not Engine.is_editor_hint():
		push_error(BLOCKED_MESSAGE)
		return ""
	var cached: String = WavedashCompat.session_get(EXECUTABLE_KEY, "")
	if cached != "":
		if FileAccess.file_exists(cached):
			return cached
		_forget_resolution()
	for dir in _path_dirs() + _fallback_install_dirs():
		var candidate: String = dir.path_join(_binary_filename())
		if FileAccess.file_exists(candidate):
			var output := []
			if OS.execute(candidate, ["--version"], output, true) == 0:
				WavedashCompat.session_set(EXECUTABLE_KEY, candidate)
				WavedashCompat.session_set(VERSION_KEY, "\n".join(output).strip_edges())
				return candidate
	return ""

## A path this file handed out wouldn't spawn -- present, but not runnable. Callers
## report the situation; what to do about the cache is this file's business.
static func report_unrunnable() -> void:
	_forget_resolution()

## Searches again from scratch and returns the result, for after an install or update
## and for when the user asks to re-check.
static func recheck_installation() -> String:
	_forget_resolution()
	return resolve_executable()

static func _forget_resolution() -> void:
	WavedashCompat.session_set(EXECUTABLE_KEY, null)
	WavedashCompat.session_set(VERSION_KEY, null)

static func is_installed() -> bool:
	return resolve_executable() != ""

static func get_version_string(executable: String = "") -> String:
	if not Engine.is_editor_hint():
		push_error(BLOCKED_MESSAGE)
		return ""
	var exe := executable if executable != "" else resolve_executable()
	if exe == "":
		return ""
	var cached_version: String = WavedashCompat.session_get(VERSION_KEY, "")
	if exe == WavedashCompat.session_get(EXECUTABLE_KEY, "") and cached_version != "":
		return cached_version
	var output := []
	OS.execute(exe, ["--version"], output, true)
	return "\n".join(output).strip_edges()

static func get_install_shell_command() -> ShellCommand:
	var cmd := ShellCommand.new()
	if OS.get_name() == "Windows":
		cmd.path = "powershell.exe"
		cmd.arguments = PackedStringArray([
			"-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
			"irm https://wavedash.com/cli/install.ps1 | iex",
		])
	else:
		cmd.path = "/bin/sh"
		cmd.arguments = PackedStringArray(["-c", "curl -fsSL https://wavedash.com/cli/install.sh | sh"])
	return cmd

static func get_install_command_display_string() -> String:
	var cmd := get_install_shell_command()
	return "%s %s" % [cmd.path, " ".join(cmd.arguments)]
