@tool
extends RefCounted

## GDExtension exposes nothing about per-platform libraries, so the Web check reads the
## .gdextension file. A [libraries] key is a dot-separated list of feature tags in no fixed
## order, and a Web build carries the "web" tag.

const NO_WEB_BUILD_WARNING := "These GDExtensions were not built for Web, so they're left out of the export and may break in the browser: %s"
const NO_MATCHING_LIBRARY_WARNING := "These GDExtensions have no Web library for a %s release export, so they're left out. Toggle Thread Support in Export Presets or update them: %s"

## What a Wavedash export advertises, minus the thread tag the preset decides.
const WEB_EXPORT_FEATURES := ["web", "wasm32", "release", "template", "template_release", "single"]

static func with_web_build() -> Array[String]:
	return _loaded_where(true)

static func without_web_build() -> Array[String]:
	return _loaded_where(false)

static func no_web_build_warning() -> String:
	var paths := without_web_build()
	return "" if paths.is_empty() else NO_WEB_BUILD_WARNING % ", ".join(paths)

static func no_matching_library_warning(threaded: bool) -> String:
	var features := WEB_EXPORT_FEATURES.duplicate()
	features.append("threads" if threaded else "nothreads")
	var paths: Array[String] = []
	for path in with_web_build():
		if not _has_library_for(path, features):
			paths.append(path)
	if paths.is_empty():
		return ""
	return NO_MATCHING_LIBRARY_WARNING % ["threaded" if threaded else "non-threaded", ", ".join(paths)]

## Godot's own rule: a library key is a list of feature tags, and every tag must be an export feature.
static func _has_library_for(path: String, features: Array) -> bool:
	var config := ConfigFile.new()
	if config.load(path) != OK or not config.has_section("libraries"):
		return false
	for key in config.get_section_keys("libraries"):
		var tags := Array(key.split("."))
		if "web" in tags and tags.all(func(tag: String) -> bool: return tag in features):
			return true
	return false

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
