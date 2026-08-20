## Request ids and pending envelopes for awaited JS calls.
extends RefCounted

signal resolved(request_id: int)

const Envelope = preload("WavedashEnvelope.gd")

var _next_id: int = 0
var _results: Dictionary = {}
var _callbacks: Dictionary = {}

func open() -> int:
	_next_id += 1
	return _next_id

## GDScript holds the only reference to the callback, so dropping it before the page
## fires would collect it out from under an in-flight call. A request holds more than
## one once it has a rejection handler as well as a resolution handler.
func hold(request_id: int, callback: JavaScriptObject) -> void:
	if not _callbacks.has(request_id):
		_callbacks[request_id] = []
	_callbacks[request_id].append(callback)

func resolve(request_id: int, env: Envelope) -> void:
	_results[request_id] = env
	resolved.emit(request_id)

func take(request_id: int) -> Envelope:
	while not _results.has(request_id):
		await resolved
	var result: Envelope = _results[request_id]
	_results.erase(request_id)
	_callbacks.erase(request_id)
	return result
