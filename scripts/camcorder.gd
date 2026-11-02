class_name Camcorder
extends Node
## The camcorder in the local player's hands. It films from your eyes, then sends each
## photo or clip to the host, which keeps the footage on that camcorder. Playing back
## asks the host for it, so whoever holds the camcorder can watch everything on it,
## whoever filmed it.

const MESSAGE_SECONDS := 3.0
const PHOTO_QUALITY := 0.85
const CLIP_QUALITY := 0.75
const MIN_CLIP_SECONDS := 0.5 # Anything shorter was an accident, so it isn't kept.
const END_PAUSE := 0.8 # A clip holds its last frame this long before it loops.
const CACHE_LIMIT := 6 # Recordings kept ready to play on this machine.

var is_recording := false
var record_elapsed := 0.0
var viewing := false
var view_index := 0
var listing: Array = [] # What's on the camcorder in your hands, oldest first: {uid, kind, by, length}.
var list_ready := false
var play_time := 0.0
var message := ""
var message_seconds := 0.0
var uploads := 0 # Recordings sent to the host. The tests count these.

var _player: Player
var _viewport: SubViewport
var _camera: Camera3D
var _item_id := 0 # The camcorder being filmed with, or watched.
var _photo_busy := false
var _next_frame_at := 0.0
var _frames: Array = []
var _times := PackedFloat32Array()
var _tasks := PackedInt64Array()
var _cache := {} # uid -> {"textures": Array[Texture2D], "times": PackedFloat32Array, "length": float}
var _cache_order: Array[int] = []
var _asked := {} # uids requested from the host and not here yet
var _list_count := -1 # How many recordings the camcorder had when the list was asked for.


func setup(player: Player) -> void:
	_player = player
	_viewport = SubViewport.new()
	_viewport.size = Tools.SNAPSHOT_SIZE
	_viewport.gui_disable_input = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_camera = Camera3D.new()
	_camera.far = 60.0
	_camera.fov = 62.0
	_camera.cull_mask = 0xFFFFF & ~Scrap.HELD_LAYER
	_viewport.add_child(_camera)
	Session.tape_list_received.connect(_on_list)
	Session.tape_entry_received.connect(_on_entry)
	Session.tape_saved.connect(_show_message)


## The camcorder in your hands, if that's what you're holding.
func held() -> Scrap:
	var item := Session.item_held_by(_player.peer_id)
	return item if item != null and item.kind == Tools.CAMCORDER else null


## The live picture while filming.
func texture() -> ViewportTexture:
	return _viewport.get_texture()


# --- Filming ----------------------------------------------------------------------

func take_photo() -> void:
	var item := held()
	if item == null or is_recording or _photo_busy:
		return
	close_viewer()
	_photo_busy = true
	_player.net_flashes += 1
	Sfx.play_2d("click", -4.0)
	_camera.global_transform = _player.eye_transform()
	var image: Image
	if _can_render():
		# Wait for a frame with the flash in it.
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		if not is_inside_tree():
			return
		image = _viewport.get_texture().get_image()
		if not is_recording:
			_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	else:
		image = _stand_in(Tools.SNAPSHOT_SIZE, uploads)
	_photo_busy = false
	if image == null or image.is_empty() or held() != item:
		return
	image.convert(Image.FORMAT_RGB8)
	_send(item.item_id, "photo", [image.save_jpg_to_buffer(PHOTO_QUALITY)], PackedFloat32Array([0.0]), 0.0)


func start_clip() -> void:
	var item := held()
	if item == null or is_recording or _photo_busy:
		return
	close_viewer()
	is_recording = true
	_item_id = item.item_id
	record_elapsed = 0.0
	_next_frame_at = 0.0
	_frames = []
	_times = PackedFloat32Array()
	_tasks = PackedInt64Array()
	_player.net_recording = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	Sfx.play_2d("wisp_warn", -6.0)


## Stops a clip early and keeps what was filmed.
func stop_clip() -> void:
	if is_recording:
		_finish_clip()


func _process(delta: float) -> void:
	if message_seconds > 0.0:
		message_seconds -= delta
	if viewing:
		_keep_viewing(delta)
	if not is_recording:
		return
	var item := held()
	if item == null or item.item_id != _item_id or not _player.is_alive():
		_finish_clip()
		return
	_camera.global_transform = _player.eye_transform()
	record_elapsed += delta
	if record_elapsed >= Tools.CLIP_SECONDS:
		record_elapsed = Tools.CLIP_SECONDS
		_finish_clip()
	elif record_elapsed >= _next_frame_at:
		_next_frame_at += 1.0 / Tools.CLIP_FPS
		_capture_frame()


func _exit_tree() -> void:
	# The day can end, or the player can leave, in the middle of a clip.
	if is_recording:
		is_recording = false
		for task in _tasks:
			WorkerThreadPool.wait_for_task_completion(task)
		_tasks = PackedInt64Array()


func _capture_frame() -> void:
	var image: Image
	if _can_render():
		image = _viewport.get_texture().get_image()
	else:
		image = _stand_in(Tools.CLIP_SIZE, _frames.size())
	if image == null or image.is_empty():
		return
	var index := _frames.size()
	_frames.append(PackedByteArray())
	_times.append(record_elapsed)
	# Shrinking and compressing happen off the main thread, so the game stays smooth.
	_tasks.append(WorkerThreadPool.add_task(_encode_frame.bind(image, index)))


func _encode_frame(image: Image, index: int) -> void:
	image.convert(Image.FORMAT_RGB8)
	if image.get_size() != Tools.CLIP_SIZE:
		image.resize(Tools.CLIP_SIZE.x, Tools.CLIP_SIZE.y, Image.INTERPOLATE_BILINEAR)
	_frames[index] = image.save_jpg_to_buffer(CLIP_QUALITY)


func _finish_clip() -> void:
	is_recording = false
	_player.net_recording = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	for task in _tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks = PackedInt64Array()
	Sfx.play_2d("wisp_warn", -6.0)
	var item := held()
	var frames := _frames
	_frames = []
	if item == null or item.item_id != _item_id:
		_show_message("You let go of the camcorder, so that clip was lost")
	elif frames.is_empty() or record_elapsed < MIN_CLIP_SECONDS:
		_show_message("Too short to keep")
	else:
		var times := PackedFloat32Array()
		for time in _times:
			times.append(time - _times[0]) # The first frame plays straight away.
		_send(item.item_id, "clip", frames, times, record_elapsed)


func _send(item_id: int, kind: String, frames: Array, times: PackedFloat32Array, length: float) -> void:
	uploads += 1
	_show_message("Saving to the camcorder...")
	Session.request_store_tape.rpc_id(1, item_id, kind, frames, times, length)


## A headless test machine has nothing to film, so it records plain colours instead.
func _stand_in(size: Vector2i, number: int) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGB8)
	image.fill(Color.from_hsv(fmod(number * 0.13, 1.0), 0.6, 0.8))
	return image


func _can_render() -> bool:
	return DisplayServer.get_name() != "headless"


func _show_message(text: String) -> void:
	message = text
	message_seconds = MESSAGE_SECONDS


# --- Playing back -------------------------------------------------------------------

func toggle_viewer() -> void:
	if viewing:
		close_viewer()
	else:
		open_viewer()


func open_viewer() -> void:
	var item := held()
	if item == null or is_recording or _photo_busy:
		return
	viewing = true
	_item_id = item.item_id
	listing = []
	list_ready = false
	view_index = -1
	play_time = 0.0
	_ask_for_list(item)
	Sfx.play_2d("switch", -12.0)


func close_viewer() -> void:
	if not viewing:
		return
	viewing = false
	Sfx.play_2d("switch", -12.0)


## Steps through the recordings, wrapping around at either end.
func show_next(step: int) -> void:
	if not viewing or listing.is_empty():
		return
	view_index = posmod(view_index + step, listing.size())
	play_time = 0.0
	_fetch_current()


func current() -> Dictionary:
	return listing[view_index] if viewing and view_index >= 0 and view_index < listing.size() else {}


## The picture to show right now, or null while it's still on its way.
func current_texture() -> Texture2D:
	var entry := current()
	if entry.is_empty() or not _cache.has(entry.uid):
		return null
	var footage: Dictionary = _cache[entry.uid]
	var textures: Array = footage.textures
	if textures.is_empty():
		return null
	var at := fmod(play_time, footage.length + END_PAUSE)
	var frame := 0
	for index in footage.times.size():
		if footage.times[index] <= at:
			frame = index
	return textures[mini(frame, textures.size() - 1)]


func is_loading() -> bool:
	var entry := current()
	return not list_ready or (not entry.is_empty() and not _cache.has(entry.uid))


func _keep_viewing(delta: float) -> void:
	var item := held()
	if item == null or item.item_id != _item_id:
		close_viewer()
		return
	play_time += delta
	# Someone else's recording may have just landed on it.
	if list_ready and item.recordings != _list_count:
		_ask_for_list(item)


func _ask_for_list(item: Scrap) -> void:
	_list_count = item.recordings
	Session.request_tape_list.rpc_id(1, item.item_id)


func _on_list(item_id: int, entries: Array) -> void:
	if not viewing or item_id != _item_id:
		return
	var showing := current()
	var newest_before: int = listing.back().uid if not listing.is_empty() else -1
	listing = entries
	list_ready = true
	if listing.is_empty():
		view_index = -1
		return
	# Open on the newest recording, and jump to a new one when it arrives.
	var index := -1
	if not showing.is_empty() and listing.back().uid == newest_before:
		index = listing.map(func(entry: Dictionary) -> int: return entry.uid).find(showing.uid)
	if index < 0:
		index = listing.size() - 1
		play_time = 0.0
	view_index = index
	_fetch_current()


func _fetch_current() -> void:
	var entry := current()
	if entry.is_empty() or _cache.has(entry.uid) or _asked.has(entry.uid):
		return
	_asked[entry.uid] = true
	Session.request_tape_entry.rpc_id(1, _item_id, entry.uid)


func _on_entry(uid: int, frames: Array, times: PackedFloat32Array, length: float) -> void:
	_asked.erase(uid)
	var textures: Array[Texture2D] = []
	var kept_times := PackedFloat32Array()
	for index in frames.size():
		var image := Image.new()
		if frames[index] is PackedByteArray and image.load_jpg_from_buffer(frames[index]) == OK:
			textures.append(ImageTexture.create_from_image(image))
			kept_times.append(times[index] if index < times.size() else 0.0)
	_cache[uid] = {"textures": textures, "times": kept_times, "length": length}
	_cache_order.erase(uid)
	_cache_order.append(uid)
	while _cache_order.size() > CACHE_LIMIT:
		_cache.erase(_cache_order.pop_front())
