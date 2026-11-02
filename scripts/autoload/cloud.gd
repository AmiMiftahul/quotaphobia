extends Node
## Talks to the Supabase database for run history and the leaderboard. A failure
## here must never affect play, so every function just reports success or failure.

signal leaderboard_received(rows: Array)

const SESSION_FILE := "user://cloud_session.cfg"
const TIMEOUT_SECONDS := 8.0

var last_submit_ok := false
var submit_count := 0

var _url := CloudConfig.SUPABASE_URL
var _key := CloudConfig.PUBLISHABLE_KEY
var _session_file := SESSION_FILE
var _access_token := ""
var _refresh_token := ""
var _expires_at := 0.0


func _ready() -> void:
	if OS.is_debug_build():
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("cloud_url="):
				_url = arg.trim_prefix("cloud_url=")
			elif arg.begins_with("cloud_key="):
				_key = arg.trim_prefix("cloud_key=")
			elif arg.begins_with("cloud_session="):
				_session_file = arg.trim_prefix("cloud_session=")
	_url = _url.trim_suffix("/")
	_load_session()


func is_configured() -> bool:
	return not _url.is_empty() and not _key.is_empty() and not _is_secret_key(_key)


static func _is_secret_key(key: String) -> bool:
	return key.begins_with("sb_secret_")


func submit_run(display_name: String, rounds_cleared: int, total_scrap: int, crew_size: int) -> bool:
	last_submit_ok = false
	if not is_configured() or not await _ensure_signed_in():
		submit_count += 1
		return false
	var body := JSON.stringify({
		"display_name": display_name,
		"rounds_cleared": rounds_cleared,
		"total_scrap": total_scrap,
		"crew_size": crew_size,
	})
	var headers := _headers()
	headers.append("Authorization: Bearer " + _access_token)
	headers.append("Prefer: return=minimal")
	var result := await _send("/rest/v1/runs", HTTPClient.METHOD_POST, headers, body)
	last_submit_ok = result.ok
	submit_count += 1
	return result.ok


func fetch_leaderboard(limit: int = 10) -> Array:
	var rows: Array = []
	if is_configured():
		var path := "/rest/v1/runs?select=display_name,rounds_cleared,total_scrap,crew_size&order=total_scrap.desc&limit=%d" % limit
		var result := await _send(path, HTTPClient.METHOD_GET, _headers(), "")
		if result.ok and result.data is Array:
			rows = result.data
	leaderboard_received.emit(rows)
	return rows


## Anonymous accounts give each install its own identity with no sign-up screen.
func _ensure_signed_in() -> bool:
	var now := Time.get_unix_time_from_system()
	if not _access_token.is_empty() and now < _expires_at - 60.0:
		return true
	if not _refresh_token.is_empty():
		var body := JSON.stringify({"refresh_token": _refresh_token})
		var refreshed := await _send("/auth/v1/token?grant_type=refresh_token", HTTPClient.METHOD_POST, _headers(), body)
		if _store_session(refreshed):
			return true
	var created := await _send("/auth/v1/signup", HTTPClient.METHOD_POST, _headers(), "{}")
	return _store_session(created)


func _store_session(result: Dictionary) -> bool:
	if not result.ok or not result.data is Dictionary or not result.data.has("access_token"):
		return false
	_access_token = result.data.access_token
	_refresh_token = result.data.get("refresh_token", "")
	_expires_at = Time.get_unix_time_from_system() + float(result.data.get("expires_in", 3600))
	var file := ConfigFile.new()
	file.set_value("session", "refresh_token", _refresh_token)
	file.save(_session_file)
	return true


func _load_session() -> void:
	var file := ConfigFile.new()
	if file.load(_session_file) == OK:
		_refresh_token = file.get_value("session", "refresh_token", "")


func _headers() -> PackedStringArray:
	return PackedStringArray(["apikey: " + _key, "Content-Type: application/json"])


func _send(path: String, method: HTTPClient.Method, headers: PackedStringArray, body: String) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = TIMEOUT_SECONDS
	add_child(request)
	var error := request.request(_url + path, headers, method, body)
	if error != OK:
		request.queue_free()
		push_warning("Cloud request could not start: %s" % error_string(error))
		return {"ok": false, "data": null}
	var response: Array = await request.request_completed
	request.queue_free()
	var ok: bool = response[0] == HTTPRequest.RESULT_SUCCESS and response[1] >= 200 and response[1] < 300
	if not ok:
		push_warning("Cloud request to %s failed (result %d, HTTP %d)." % [path.get_slice("?", 0), response[0], response[1]])
	var text: String = response[3].get_string_from_utf8()
	return {"ok": ok, "data": JSON.parse_string(text) if not text.is_empty() else null}
