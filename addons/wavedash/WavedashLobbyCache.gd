## A host id is only meaningful for the lobby id it was read with.
extends RefCounted

var _lobby_id: String = ""
var _host_id: String = ""

func joined(lobby_id: String, host_id: String) -> void:
	_lobby_id = lobby_id
	_host_id = host_id

func left(lobby_id: String) -> void:
	if lobby_id == _lobby_id:
		forget()

func forget() -> void:
	_lobby_id = ""
	_host_id = ""

func host_expired() -> void:
	_host_id = ""

func host_for(lobby_id: String) -> String:
	return _host_id if lobby_id == _lobby_id else ""

func remember_host(lobby_id: String, host_id: String) -> void:
	if lobby_id == _lobby_id:
		_host_id = host_id
