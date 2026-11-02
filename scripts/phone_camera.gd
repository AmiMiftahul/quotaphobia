class_name PhoneCamera
extends Node
## The phone in the local player's hand. It has its own camera, so photos and
## videos show the game world without the HUD. It only draws while it's raised,
## so it costs nothing the rest of the time.

const PHOTO_SIZE := Vector2i(1280, 720)
const VIDEO_SIZE := Vector2i(640, 360)
const VIDEO_FPS := 15.0
const RECORD_SECONDS := 5.0
const JPEG_QUALITY := 0.85
const MIN_SAVED_SECONDS := 0.5 # Anything shorter was an accident, so it isn't kept.
const MESSAGE_SECONDS := 4.0

var is_up := false
var is_recording := false
var record_elapsed := 0.0
var message := ""
var message_seconds := 0.0
var last_saved_path := ""
var frames_captured := 0

var _player: Player
var _viewport: SubViewport
var _camera: Camera3D
var _photo_busy := false
var _next_frame_at := 0.0
var _frames: Array = []
var _frame_times: PackedFloat32Array = []
var _tasks: PackedInt64Array = []


func setup(player: Player) -> void:
	_player = player
	_viewport = SubViewport.new()
	_viewport.size = PHOTO_SIZE
	_viewport.gui_disable_input = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_camera = Camera3D.new()
	_camera.far = 60.0
	_camera.fov = 65.0
	_viewport.add_child(_camera)


## Where photos and videos go. Tests use their own folder.
static func capture_folder() -> String:
	if OS.is_debug_build():
		var in_test := false
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("captures="):
				return arg.trim_prefix("captures=")
			if arg.begins_with("role="):
				in_test = true
		if in_test:
			return OS.get_user_data_dir().path_join("test_captures")
	return OS.get_user_data_dir().path_join("captures")


func texture() -> ViewportTexture:
	return _viewport.get_texture()


func raise() -> void:
	is_up = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_player.net_phone_up = true
	Sfx.play_2d("switch", -14.0)


func put_away() -> void:
	if not is_up:
		return
	if is_recording:
		_finish_recording()
	is_up = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_player.net_phone_up = false
	Sfx.play_2d("switch", -14.0)


func take_photo() -> void:
	if not is_up or is_recording or _photo_busy:
		return
	_photo_busy = true
	_player.net_flashes += 1
	Sfx.play_2d("click", -4.0)
	if not _can_capture():
		_photo_busy = false
		return
	# Wait for a frame with the flash in it.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if not is_inside_tree() or not is_up:
		_photo_busy = false
		return
	var image := _viewport.get_texture().get_image()
	_photo_busy = false
	var folder := capture_folder()
	DirAccess.make_dir_recursive_absolute(folder)
	var path := _new_path(folder, "photo", "png")
	if image != null and image.save_png(path) == OK:
		last_saved_path = path
		_show_message("Photo saved")
	else:
		_show_message("Couldn't save that photo")


func start_recording() -> void:
	if not is_up or is_recording or _photo_busy:
		return
	is_recording = true
	record_elapsed = 0.0
	_next_frame_at = 0.0
	_frames = []
	_frame_times = PackedFloat32Array()
	_tasks = PackedInt64Array()
	frames_captured = 0
	_player.net_recording = true
	Sfx.play_2d("wisp_warn", -6.0)


func _process(delta: float) -> void:
	if message_seconds > 0.0:
		message_seconds -= delta
	if not is_up:
		return
	_camera.global_transform = _player.eye_transform()
	if not is_recording:
		return
	record_elapsed += delta
	if record_elapsed >= RECORD_SECONDS:
		record_elapsed = RECORD_SECONDS
		_finish_recording()
	elif record_elapsed >= _next_frame_at:
		_next_frame_at += 1.0 / VIDEO_FPS
		_capture_frame()


func _exit_tree() -> void:
	# The round can end, or the player can leave, in the middle of a clip.
	if is_recording:
		_finish_recording()


func _capture_frame() -> void:
	if not _can_capture():
		return
	var image := _viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return
	var index := _frames.size()
	_frames.append(PackedByteArray())
	_frame_times.append(record_elapsed)
	frames_captured += 1
	# Shrinking and compressing happen off the main thread, so the game stays smooth.
	_tasks.append(WorkerThreadPool.add_task(_encode_frame.bind(image, index)))


func _encode_frame(image: Image, index: int) -> void:
	image.convert(Image.FORMAT_RGB8)
	image.resize(VIDEO_SIZE.x, VIDEO_SIZE.y, Image.INTERPOLATE_BILINEAR)
	_frames[index] = image.save_jpg_to_buffer(JPEG_QUALITY)


func _finish_recording() -> void:
	is_recording = false
	_player.net_recording = false
	for task in _tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks = PackedInt64Array()
	Sfx.play_2d("wisp_warn", -6.0)
	if _frames.is_empty() or record_elapsed < MIN_SAVED_SECONDS:
		_show_message("Too short to keep")
		return
	var durations := durations_for(_frame_times, record_elapsed)
	var video := MovWriter.build(_frames, durations, VIDEO_SIZE.x, VIDEO_SIZE.y)
	_frames = []
	var folder := capture_folder()
	DirAccess.make_dir_recursive_absolute(folder)
	var path := _new_path(folder, "video", "mov")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_show_message("Couldn't save that video")
		return
	file.store_buffer(video)
	file.close()
	last_saved_path = path
	_show_message("Video saved")


## How long each frame stays on screen, so the clip plays at real speed even if
## the game slowed down while recording.
static func durations_for(times: PackedFloat32Array, total_seconds: float) -> PackedInt32Array:
	var durations := PackedInt32Array()
	var total_ticks := roundi(total_seconds * MovWriter.TIMESCALE)
	var used := 0
	for index in times.size():
		var ends_at := total_ticks
		if index + 1 < times.size():
			ends_at = roundi(times[index + 1] * MovWriter.TIMESCALE)
		var ticks := maxi(ends_at - used, 1)
		durations.append(ticks)
		used += ticks
	return durations


func _can_capture() -> bool:
	return DisplayServer.get_name() != "headless"


func _show_message(text: String) -> void:
	message = text
	message_seconds = MESSAGE_SECONDS


## A name that can't overwrite an earlier photo, even within the same second.
func _new_path(folder: String, kind: String, extension: String) -> String:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path := folder.path_join("%s_%s.%s" % [kind, stamp, extension])
	var attempt := 2
	while FileAccess.file_exists(path):
		path = folder.path_join("%s_%s_%d.%s" % [kind, stamp, attempt, extension])
		attempt += 1
	return path
