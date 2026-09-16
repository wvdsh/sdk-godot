@tool
extends Control

const WavedashCompat = preload("wavedash_compat.gd")
const WavedashGate = preload("wavedash_gate.gd")

signal gate_changed

func _ready() -> void:
	if WavedashCompat.is_part_of_edited_scene(self):
		return
	%CliRow.log_line.connect(append_log)
	%AuthRow.log_line.connect(append_log)
	%PresetRow.log_line.connect(append_log)
	%ProjectRow.log_line.connect(append_log)
	%BuildUploadRow.log_line.connect(append_log)
	$VBoxContainer/OutputRow/ClearButton.pressed.connect(%OutputLog.clear)
	# Account and CLI state reach BuildUploadRow through ProjectRow, whose refresh() ends by emitting
	# status_changed. Wiring them to BuildUploadRow as well would refresh it twice per change.
	%AuthRow.status_changed.connect(%ProjectRow.refresh)
	%CliRow.status_changed.connect(%ProjectRow.refresh)
	%PresetRow.status_changed.connect(_on_gate_changed)
	%ProjectRow.status_changed.connect(_on_gate_changed)
	_connect_export_template_refresh()

## Installing export templates changes the gate's answer and emits no signal; the manager's visibility stands in.
func _connect_export_template_refresh() -> void:
	for child in WavedashCompat.editor_base_control().get_children():
		if child.get_class() == "ExportTemplateManager":
			child.visibility_changed.connect(_on_export_templates_changed)
			return

func _on_export_templates_changed() -> void:
	WavedashGate.forget_export_templates()
	_on_gate_changed()

func _on_gate_changed() -> void:
	%BuildUploadRow.refresh()
	gate_changed.emit()

## add_text(), not `text +=`: the latter reparses the whole buffer per line.
func append_log(text: String) -> void:
	%OutputLog.add_text(text + "\n")
