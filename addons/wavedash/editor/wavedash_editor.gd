@tool
extends Control

## Hosts the shared output log and wires the rows together. Each row owns its own
## concern.

const WavedashCompat = preload("wavedash_compat.gd")

const MAX_LOG_PARAGRAPHS := 2000

## For the main-toolbar dev button, which is gated on the same answer but lives
## outside this scene. Connected in WavedashPlugin.
signal gate_changed

func _ready() -> void:
	# Setup here would dirty the open scene and bake session state into a shipped .tscn.
	if WavedashCompat.is_part_of_edited_scene(self):
		return
	%CliRow.log_line.connect(append_log)
	%AuthRow.log_line.connect(append_log)
	%PresetRow.log_line.connect(append_log)
	%ProjectRow.log_line.connect(append_log)
	%BuildUploadRow.log_line.connect(append_log)
	# Account and CLI state reach BuildUploadRow through ProjectRow, whose
	# refresh() always ends by emitting status_changed. Wiring them to
	# BuildUploadRow as well would refresh it twice per change.
	%AuthRow.status_changed.connect(%ProjectRow.refresh)
	%CliRow.status_changed.connect(%ProjectRow.refresh)
	%PresetRow.status_changed.connect(_on_gate_changed)
	%ProjectRow.status_changed.connect(_on_gate_changed)
	_connect_export_template_refresh()

## Installing export templates changes the gate's answer and emits no signal, but the
## manager is a permanent node under base_control, so its visibility stands in for one.
func _connect_export_template_refresh() -> void:
	for child in WavedashCompat.editor_base_control().get_children():
		if child.get_class() == "ExportTemplateManager":
			child.visibility_changed.connect(_on_gate_changed)
			return

func _on_gate_changed() -> void:
	%BuildUploadRow.refresh()
	gate_changed.emit()

## Public because the main-toolbar dev button, which isn't in this scene, also
## routes its output here.
##
## add_text(), not `text +=`: the latter reparses the whole buffer per line.
func append_log(text: String) -> void:
	%OutputLog.add_text(text + "\n")
	while %OutputLog.get_paragraph_count() > MAX_LOG_PARAGRAPHS:
		%OutputLog.remove_paragraph(0)
