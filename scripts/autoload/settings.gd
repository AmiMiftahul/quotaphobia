extends Node
## Every player preference: reading, checking, saving and applying them. Controls
## live here too, so keyboard and controller bindings are in one place.

signal changed
signal device_changed

const FILE := "user://settings.cfg"
const SAVE_DELAY := 0.5
const BASE_LOOK_SPEED := 3.0 # Radians per second with the stick fully over, at 100%.

const WINDOW_MODES := ["windowed", "fullscreen", "exclusive"]
const RESOLUTIONS := ["1280x720", "1600x900", "1920x1080", "2560x1440"]
const FPS_LIMITS := [0, 30, 60, 120, 144]
const MSAA_LEVELS := [0, 2, 4]

const DEFAULTS := {
	"window_mode": "windowed",
	"resolution": "1280x720",
	"vsync": true,
	"max_fps": 0,
	"render_scale": 1.0,
	"msaa": 0,
	"shadows": true,
	"brightness": 1.0,
	"fov": 75.0,
	"master": 0.8,
	"music": 1.0,
	"sfx": 1.0,
	"mouse_sensitivity": 1.0,
	"invert_y": false,
	"pad_sensitivity": 1.0,
	"pad_invert_y": false,
	"deadzone": 0.2,
	"vibration": true,
	"hints": true,
	"crosshair": true,
}
# The allowed range of each number. A damaged or hand-edited file can't go past these.
const RANGES := {
	"render_scale": [0.5, 1.0],
	"brightness": [0.5, 1.5],
	"fov": [60.0, 110.0],
	"master": [0.0, 1.0],
	"music": [0.0, 1.0],
	"sfx": [0.0, 1.0],
	"mouse_sensitivity": [0.2, 3.0],
	"pad_sensitivity": [0.2, 3.0],
	"deadzone": [0.05, 0.6],
}
const CHOICES := {
	"window_mode": WINDOW_MODES,
	"resolution": RESOLUTIONS,
	"max_fps": FPS_LIMITS,
	"msaa": MSAA_LEVELS,
}

# Things players can rebind: [action, what the menu calls it].
const REBINDABLE := [
	["move_forward", "Move forward"],
	["move_back", "Move back"],
	["move_left", "Move left"],
	["move_right", "Move right"],
	["sprint", "Sprint"],
	["jump", "Jump"],
	["interact", "Pick up / interact"],
	["drop", "Drop"],
	["cycle_item", "Switch item"],
	["flashlight", "Flashlight"],
	["phone", "Phone"],
	["use_item", "Use item / take photo"],
	["phone_record", "Record 5 seconds"],
]
# On a controller, moving is always the left stick and looking the right stick.
const PAD_REBINDABLE := [
	["sprint", "Sprint"],
	["jump", "Jump"],
	["interact", "Pick up / interact"],
	["drop", "Drop"],
	["cycle_item", "Switch item"],
	["flashlight", "Flashlight"],
	["phone", "Phone"],
	["use_item", "Use item / take photo"],
	["phone_record", "Record 5 seconds"],
]
const DEFAULT_KEYS := {
	"move_forward": "key:87", "move_back": "key:83", "move_left": "key:65", "move_right": "key:68",
	"sprint": "key:4194325", "jump": "key:32", "interact": "key:69", "drop": "key:71", "flashlight": "key:70",
	"phone": "key:80", "use_item": "mouse:1", "phone_record": "key:82", "cycle_item": "key:81",
}
const DEFAULT_PAD := {
	"sprint": "axis:5", "jump": "joy:0", "interact": "joy:2", "drop": "joy:1", "flashlight": "joy:3",
	"phone": "joy:11", "use_item": "joy:10", "phone_record": "joy:9", "cycle_item": "joy:13",
}
const STICK_ACTIONS := {
	"move_forward": [JOY_AXIS_LEFT_Y, -1.0], "move_back": [JOY_AXIS_LEFT_Y, 1.0],
	"move_left": [JOY_AXIS_LEFT_X, -1.0], "move_right": [JOY_AXIS_LEFT_X, 1.0],
	"look_up": [JOY_AXIS_RIGHT_Y, -1.0], "look_down": [JOY_AXIS_RIGHT_Y, 1.0],
	"look_left": [JOY_AXIS_RIGHT_X, -1.0], "look_right": [JOY_AXIS_RIGHT_X, 1.0],
}
# Names follow the Xbox layout, which is how Godot reports every controller.
const PAD_BUTTON_NAMES := {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_BACK: "Back", JOY_BUTTON_GUIDE: "Guide", JOY_BUTTON_START: "Start",
	JOY_BUTTON_LEFT_STICK: "Left stick click", JOY_BUTTON_RIGHT_STICK: "Right stick click",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_DPAD_UP: "D-pad up", JOY_BUTTON_DPAD_DOWN: "D-pad down",
	JOY_BUTTON_DPAD_LEFT: "D-pad left", JOY_BUTTON_DPAD_RIGHT: "D-pad right",
}
const MOUSE_NAMES := {
	MOUSE_BUTTON_LEFT: "Left click", MOUSE_BUTTON_RIGHT: "Right click", MOUSE_BUTTON_MIDDLE: "Middle click",
	MOUSE_BUTTON_XBUTTON1: "Mouse 4", MOUSE_BUTTON_XBUTTON2: "Mouse 5",
}

var values := DEFAULTS.duplicate()
var keys := DEFAULT_KEYS.duplicate()
var pad := DEFAULT_PAD.duplicate()
var using_pad := false
var rumble_count := 0

var _file := FILE
var _persist := true
var _save_timer := 0.0
var _music_bus := -1
var _sfx_bus := -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.is_debug_build():
		# Automated tests must never change the real player's settings.
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("role="):
				_persist = false
			elif arg.begins_with("settings_file="):
				_file = arg.trim_prefix("settings_file=")
				_persist = true
	_make_audio_buses()
	if _persist:
		load_from_file()
	_add_controller_menu_controls()
	apply_bindings()
	apply_all()


func value(setting: String) -> Variant:
	return values[setting]


func set_value(setting: String, new_value: Variant) -> void:
	values[setting] = _checked(setting, new_value)
	_apply_one(setting)
	_save_timer = SAVE_DELAY
	changed.emit()


func reset_to_defaults() -> void:
	values = DEFAULTS.duplicate()
	keys = DEFAULT_KEYS.duplicate()
	pad = DEFAULT_PAD.duplicate()
	apply_bindings()
	apply_all()
	save()
	changed.emit()


func _checked(setting: String, new_value: Variant) -> Variant:
	var fallback: Variant = DEFAULTS[setting]
	match typeof(fallback):
		TYPE_BOOL:
			return new_value if new_value is bool else fallback
		TYPE_FLOAT:
			if not (new_value is float or new_value is int) or is_nan(float(new_value)):
				return fallback
			var limits: Array = RANGES[setting]
			return clampf(float(new_value), limits[0], limits[1])
	return new_value if new_value in CHOICES[setting] else fallback


# --- Saving ---------------------------------------------------------------------

func save() -> void:
	_save_timer = 0.0
	if not _persist:
		return
	var file := ConfigFile.new()
	for setting: String in values:
		file.set_value("settings", setting, values[setting])
	for action: String in keys:
		file.set_value("keyboard", action, keys[action])
	for action: String in pad:
		file.set_value("controller", action, pad[action])
	var error := file.save(_file)
	if error != OK:
		push_warning("Could not save settings: %s" % error_string(error))


func load_from_file() -> void:
	values = DEFAULTS.duplicate()
	keys = DEFAULT_KEYS.duplicate()
	pad = DEFAULT_PAD.duplicate()
	var file := ConfigFile.new()
	if file.load(_file) != OK:
		return
	# Early versions saved just one volume number.
	if file.has_section_key("audio", "volume"):
		values.master = _checked("master", file.get_value("audio", "volume"))
	for setting: String in DEFAULTS:
		if file.has_section_key("settings", setting):
			values[setting] = _checked(setting, file.get_value("settings", setting))
	for action: String in DEFAULT_KEYS:
		var binding: Variant = file.get_value("keyboard", action, file.get_value("keyboard", _old_name(action), ""))
		if binding is String and _is_valid_binding(binding, "keyboard"):
			keys[action] = binding
	for action: String in DEFAULT_PAD:
		var binding: Variant = file.get_value("controller", action, file.get_value("controller", _old_name(action), ""))
		if binding is String and _is_valid_binding(binding, "controller"):
			pad[action] = binding


## Early versions had a photo button; it became the button that uses gear, too.
func _old_name(action: String) -> String:
	return "phone_photo" if action == "use_item" else action


func _process(delta: float) -> void:
	if _save_timer > 0.0:
		_save_timer -= delta
		if _save_timer <= 0.0:
			save()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and _save_timer > 0.0:
		save()


# --- Applying to the engine --------------------------------------------------------

func apply_all() -> void:
	for setting: String in values:
		_apply_one(setting)


func _apply_one(setting: String) -> void:
	match setting:
		"window_mode", "resolution":
			_apply_window()
		"vsync":
			if _has_window():
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if values.vsync else DisplayServer.VSYNC_DISABLED)
		"max_fps":
			Engine.max_fps = values.max_fps
		"render_scale":
			get_tree().root.scaling_3d_scale = values.render_scale
		"msaa":
			var levels := {0: Viewport.MSAA_DISABLED, 2: Viewport.MSAA_2X, 4: Viewport.MSAA_4X}
			get_tree().root.msaa_3d = levels[values.msaa]
		"master":
			_set_bus_volume(0, values.master)
		"music":
			_set_bus_volume(_music_bus, values.music)
		"sfx":
			_set_bus_volume(_sfx_bus, values.sfx)
		"deadzone":
			for action: String in STICK_ACTIONS:
				InputMap.action_set_deadzone(action, values.deadzone)


func _has_window() -> bool:
	return DisplayServer.get_name() != "headless"


func _apply_window() -> void:
	if not _has_window():
		return
	match values.window_mode:
		"fullscreen":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		"exclusive":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			var parts: PackedStringArray = values.resolution.split("x")
			var wanted := Vector2i(int(parts[0]), int(parts[1]))
			# Never open a window bigger than the screen it's on.
			var screen := DisplayServer.screen_get_usable_rect()
			wanted = Vector2i(mini(wanted.x, screen.size.x), mini(wanted.y, screen.size.y))
			DisplayServer.window_set_size(wanted)
			DisplayServer.window_set_position(screen.position + (screen.size - wanted) / 2)


func _make_audio_buses() -> void:
	_music_bus = _add_bus("Music")
	_sfx_bus = _add_bus("SFX")


func _add_bus(bus_name: String) -> int:
	var index := AudioServer.get_bus_index(bus_name)
	if index >= 0:
		return index
	AudioServer.add_bus()
	index = AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, bus_name)
	AudioServer.set_bus_send(index, "Master")
	return index


func _set_bus_volume(bus: int, linear: float) -> void:
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(linear, 0.0001)))
	AudioServer.set_bus_mute(bus, linear <= 0.0)


# --- Controls -----------------------------------------------------------------------

func apply_bindings() -> void:
	for action: String in DEFAULT_KEYS:
		_reset_action(action)
		InputMap.action_add_event(action, event_from_binding(keys[action]))
		if pad.has(action):
			InputMap.action_add_event(action, event_from_binding(pad[action]))
	if not InputMap.has_action("pause"):
		InputMap.add_action("pause")
		var escape := InputEventKey.new()
		escape.physical_keycode = KEY_ESCAPE
		InputMap.action_add_event("pause", escape)
		var start := InputEventJoypadButton.new()
		start.button_index = JOY_BUTTON_START
		InputMap.action_add_event("pause", start)
	for action: String in STICK_ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		if action.begins_with("look"):
			InputMap.action_erase_events(action)
		var stick := InputEventJoypadMotion.new()
		stick.axis = STICK_ACTIONS[action][0]
		stick.axis_value = STICK_ACTIONS[action][1]
		InputMap.action_add_event(action, stick)
		InputMap.action_set_deadzone(action, values.deadzone)


## Godot's built-in menu actions only know the keyboard, so teach them the controller.
func _add_controller_menu_controls() -> void:
	var buttons := {
		"ui_accept": JOY_BUTTON_A, "ui_cancel": JOY_BUTTON_B,
		"ui_up": JOY_BUTTON_DPAD_UP, "ui_down": JOY_BUTTON_DPAD_DOWN,
		"ui_left": JOY_BUTTON_DPAD_LEFT, "ui_right": JOY_BUTTON_DPAD_RIGHT,
	}
	for action: String in buttons:
		var button := InputEventJoypadButton.new()
		button.button_index = buttons[action]
		if not InputMap.action_has_event(action, button):
			InputMap.action_add_event(action, button)
	var stick := {
		"ui_up": [JOY_AXIS_LEFT_Y, -1.0], "ui_down": [JOY_AXIS_LEFT_Y, 1.0],
		"ui_left": [JOY_AXIS_LEFT_X, -1.0], "ui_right": [JOY_AXIS_LEFT_X, 1.0],
	}
	for action: String in stick:
		var motion := InputEventJoypadMotion.new()
		motion.axis = stick[action][0]
		motion.axis_value = stick[action][1]
		if not InputMap.action_has_event(action, motion):
			InputMap.action_add_event(action, motion)


func _reset_action(action: String) -> void:
	if InputMap.has_action(action):
		InputMap.action_erase_events(action)
	else:
		InputMap.add_action(action)


## Binds an action. If another action already uses that input, the two swap, so
## no action is ever left without a binding and no input ever does two things.
func rebind(action: String, device: String, binding: String) -> void:
	var table: Dictionary = keys if device == "keyboard" else pad
	var previous: String = table[action]
	for other: String in table:
		if other != action and table[other] == binding:
			table[other] = previous
	table[action] = binding
	apply_bindings()
	save()
	changed.emit()


## What the given press would be saved as, or "" if it can't be bound to that device.
func binding_from_event(event: InputEvent, device: String) -> String:
	if device == "keyboard":
		if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode != KEY_ESCAPE:
			return "key:%d" % event.physical_keycode
		if event is InputEventMouseButton and event.pressed and MOUSE_NAMES.has(event.button_index):
			return "mouse:%d" % event.button_index
	else:
		if event is InputEventJoypadButton and event.pressed and event.button_index != JOY_BUTTON_START:
			return "joy:%d" % event.button_index
		# Triggers count as buttons. The sticks are reserved for moving and looking.
		if event is InputEventJoypadMotion and event.axis in [JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT] and event.axis_value > 0.6:
			return "axis:%d" % event.axis
	return ""


func event_from_binding(binding: String) -> InputEvent:
	var parts := binding.split(":")
	var code := int(parts[1])
	match parts[0]:
		"key":
			var key := InputEventKey.new()
			key.physical_keycode = code as Key
			return key
		"mouse":
			var mouse := InputEventMouseButton.new()
			mouse.button_index = code as MouseButton
			return mouse
		"joy":
			var button := InputEventJoypadButton.new()
			button.button_index = code as JoyButton
			return button
	var trigger := InputEventJoypadMotion.new()
	trigger.axis = code as JoyAxis
	trigger.axis_value = 1.0
	return trigger


func binding_name(binding: String) -> String:
	var parts := binding.split(":")
	var code := int(parts[1])
	match parts[0]:
		"key":
			return OS.get_keycode_string(code as Key)
		"mouse":
			return MOUSE_NAMES.get(code, "Mouse %d" % code)
		"joy":
			return PAD_BUTTON_NAMES.get(code, "Button %d" % code)
	return "LT" if code == JOY_AXIS_TRIGGER_LEFT else "RT"


## What to press for this action on whichever device the player last touched.
func prompt_for(action: String) -> String:
	if using_pad and pad.has(action):
		return binding_name(pad[action])
	return binding_name(keys[action])


func _is_valid_binding(binding: String, device: String) -> bool:
	var parts := binding.split(":")
	if parts.size() != 2 or not parts[1].is_valid_int():
		return false
	var code := int(parts[1])
	if device == "keyboard":
		return (parts[0] == "key" and code > 0 and code != KEY_ESCAPE) or (parts[0] == "mouse" and MOUSE_NAMES.has(code))
	return (parts[0] == "joy" and PAD_BUTTON_NAMES.has(code) and code != JOY_BUTTON_START) or (parts[0] == "axis" and code in [JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT])


func rumble(weak: float, strong: float, seconds: float) -> void:
	if not values.vibration:
		return
	rumble_count += 1
	for device in Input.get_connected_joypads():
		Input.start_joy_vibration(device, weak, strong, seconds)


func _input(event: InputEvent) -> void:
	var pad_event: bool = event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.4)
	var keyboard_event: bool = event is InputEventKey or event is InputEventMouseButton or event is InputEventMouseMotion
	if (pad_event and not using_pad) or (keyboard_event and using_pad):
		using_pad = pad_event
		device_changed.emit()
