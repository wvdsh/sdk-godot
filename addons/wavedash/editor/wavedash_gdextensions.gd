@tool
extends RefCounted

## GDExtension exposes nothing about per-platform libraries, so the Web check reads the
## .gdextension file. A [libraries] key is a dot-separated list of feature tags in no fixed
## order, and a Web build carries the "web" tag.

const NO_WEB_BUILD_WARNING := "These GDExtensions were not built for Web, so they're left out of the export and may break in the browser: %s"

static func with_web_build() -> Array[String]:
	return _loaded_where(true)

static func without_web_build() -> Array[String]:
	return _loaded_where(false)

static func no_web_build_warning() -> String:
	var paths := without_web_build()
	return "" if paths.is_empty() else NO_WEB_BUILD_WARNING % ", ".join(paths)

static func _loaded_where(has_web_build: bool) -> Array[String]:
	var paths: Array[String] = []
	for path in GDExtensionManager.get_loaded_extensions():
		if _declares_web_library(path) == has_web_build:
			paths.append(path)
	return paths

static func _declares_web_library(path: String) -> bool:
	var config := ConfigFile.new()
	if config.load(path) != OK or not config.has_section("libraries"):
		return false
	for key in config.get_section_keys("libraries"):
		if "web" in key.split("."):
			return true
	return false
