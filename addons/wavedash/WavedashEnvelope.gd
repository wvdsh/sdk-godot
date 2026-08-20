## The {success, data, message} result every JS call resolves to.
extends RefCounted

var error: Error = FAILED
var message: String = ""
var data

func ok() -> bool:
	return error == OK

func to_legacy_dict() -> Dictionary:
	return {"success": ok(), "data": data, "message": message}
