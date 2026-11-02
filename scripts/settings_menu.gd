class_name SettingsMenu
extends PanelContainer
## The settings screen. Every control changes the setting straight away, so players
## see or hear the result as they adjust it. LB and RB switch tabs on a controller.

signal closed

const CAPTURE_TIMEOUT_SECONDS := 6.0

var tabs: TabContainer
var capturing_action := ""

var _capture_device := ""
var _capture_button: Button
var _capture_time := 0.0
var _rows := {}
var _bind_buttons := {}
var _resolution_row: OptionButton


func _ready() -> void:
	custom_minimum_size = Vector2(680, 560)
	set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	# Solid, so the text stays readable over the game.
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.11, 0.11, 0.13, 0.98)
	background.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", background)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)
	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 26)
	box.add_child(title)
	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(tabs)
	_build_display()
	_build_audio()
	_build_controls()
	_build_controller()
	_build_gameplay()
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	box.add_child(buttons)
	var reset := _button(buttons, "Reset to defaults", Settings.reset_to_defaults)
	reset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var back := _button(buttons, "Back", close)
	back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	Settings.changed.connect(refresh)
	refresh()


func close() -> void:
	_stop_capture()
	Settings.save()
	closed.emit()


## Makes every control show the current value.
func refresh() -> void:
	for setting: String in _rows:
		var control: Control = _rows[setting]
		if control is HSlider:
			control.set_value_no_signal(Settings.value(setting))
			_update_slider_label(setting)
		elif control is CheckButton:
			control.set_pressed_no_signal(Settings.value(setting))
		elif control is OptionButton:
			control.select(Settings.CHOICES[setting].find(Settings.value(setting)))
	for key: String in _bind_buttons:
		if capturing_action + _capture_device != key.get_slice("/", 0) + key.get_slice("/", 1):
			var parts := key.split("/")
			var table: Dictionary = Settings.keys if parts[1] == "keyboard" else Settings.pad
			_bind_buttons[key].text = Settings.binding_name(table[parts[0]])
	_resolution_row.disabled = Settings.value("window_mode") != "windowed"


# --- Tabs -----------------------------------------------------------------------

func _tab(tab_name: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)
	return box


func _build_display() -> void:
	var box := _tab("Display")
	_option(box, "Window", "window_mode", ["Windowed", "Fullscreen", "Exclusive fullscreen"])
	_resolution_row = _option(box, "Window size", "resolution", Settings.RESOLUTIONS)
	_toggle(box, "V-Sync (prevents screen tearing)", "vsync")
	_option(box, "Frame rate limit", "max_fps", ["No limit", "30", "60", "120", "144"])
	_slider(box, "Render quality", "render_scale", 0.05, "%")
	_option(box, "Anti-aliasing", "msaa", ["Off", "2x", "4x"])
	_toggle(box, "Flashlight shadows", "shadows")
	_slider(box, "Brightness", "brightness", 0.05, "%")
	_slider(box, "Field of view", "fov", 1.0, "°")


func _build_audio() -> void:
	var box := _tab("Audio")
	_slider(box, "Master volume", "master", 0.05, "%")
	_slider(box, "Ambience", "music", 0.05, "%")
	_slider(box, "Sound effects", "sfx", 0.05, "%")


func _build_controls() -> void:
	var box := _tab("Controls")
	_slider(box, "Mouse sensitivity", "mouse_sensitivity", 0.05, "%")
	_toggle(box, "Invert mouse up and down", "invert_y")
	for entry: Array in Settings.REBINDABLE:
		_bind_row(box, entry[0], entry[1], "keyboard")
	_note(box, "Press a button above, then the new key or mouse button. Esc cancels. Esc is always the pause key.")


func _build_controller() -> void:
	var box := _tab("Controller")
	_slider(box, "Look sensitivity", "pad_sensitivity", 0.05, "%")
	_toggle(box, "Invert look up and down", "pad_invert_y")
	_slider(box, "Stick dead zone", "deadzone", 0.05, "%")
	_toggle(box, "Vibration", "vibration")
	for entry: Array in Settings.PAD_REBINDABLE:
		_bind_row(box, entry[0], entry[1], "controller")
	_note(box, "Left stick moves, right stick looks, Start pauses. Button names follow the Xbox layout.")


func _build_gameplay() -> void:
	var box := _tab("Gameplay")
	_toggle(box, "Show creature hints", "hints")
	_toggle(box, "Show crosshair", "crosshair")


# --- Rows -----------------------------------------------------------------------

func _row(parent: Node, text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	return row


func _note(parent: Node, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 13)
	parent.add_child(label)


func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(Sfx.play_2d.bind("click", -14.0))
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _slider(parent: Node, text: String, setting: String, step: float, unit: String) -> void:
	var row := _row(parent, text)
	var slider := HSlider.new()
	slider.custom_minimum_size = Vector2(220, 0)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.min_value = Settings.RANGES[setting][0]
	slider.max_value = Settings.RANGES[setting][1]
	slider.step = step
	slider.value_changed.connect(_on_slider_changed.bind(setting))
	row.add_child(slider)
	var amount := Label.new()
	amount.custom_minimum_size = Vector2(58, 0)
	amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	amount.set_meta("unit", unit)
	row.add_child(amount)
	_rows[setting] = slider
	slider.set_meta("amount", amount)


func _on_slider_changed(new_value: float, setting: String) -> void:
	Settings.set_value(setting, new_value)


func _update_slider_label(setting: String) -> void:
	var slider: HSlider = _rows[setting]
	var amount: Label = slider.get_meta("amount")
	if amount.get_meta("unit") == "%":
		amount.text = "%d%%" % roundi(slider.value * 100.0)
	else:
		amount.text = "%d%s" % [roundi(slider.value), amount.get_meta("unit")]


func _toggle(parent: Node, text: String, setting: String) -> void:
	var row := _row(parent, text)
	var toggle := CheckButton.new()
	toggle.toggled.connect(func(on: bool) -> void: Settings.set_value(setting, on))
	row.add_child(toggle)
	_rows[setting] = toggle


func _option(parent: Node, text: String, setting: String, names: Array) -> OptionButton:
	var row := _row(parent, text)
	var option := OptionButton.new()
	option.custom_minimum_size = Vector2(220, 0)
	for option_name: String in names:
		option.add_item(option_name)
	option.item_selected.connect(func(index: int) -> void: Settings.set_value(setting, Settings.CHOICES[setting][index]))
	row.add_child(option)
	_rows[setting] = option
	return option


func _bind_row(parent: Node, action: String, text: String, device: String) -> void:
	var row := _row(parent, text)
	var button := Button.new()
	button.custom_minimum_size = Vector2(220, 0)
	button.pressed.connect(_start_capture.bind(action, device))
	row.add_child(button)
	_bind_buttons["%s/%s" % [action, device]] = button


# --- Rebinding ------------------------------------------------------------------

func _start_capture(action: String, device: String) -> void:
	_stop_capture()
	capturing_action = action
	_capture_device = device
	_capture_button = _bind_buttons["%s/%s" % [action, device]]
	_capture_button.text = "Press a key..." if device == "keyboard" else "Press a button..."
	_capture_time = CAPTURE_TIMEOUT_SECONDS


func _stop_capture() -> void:
	capturing_action = ""
	_capture_device = ""
	_capture_button = null
	refresh()


func _process(delta: float) -> void:
	if capturing_action.is_empty():
		return
	_capture_time -= delta
	if _capture_time <= 0.0:
		_stop_capture()


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if not capturing_action.is_empty():
		_capture_input(event)
		return
	if event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_LEFT_SHOULDER:
		_switch_tab(-1)
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_RIGHT_SHOULDER:
		_switch_tab(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close()


func _capture_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_stop_capture()
		return
	var binding := Settings.binding_from_event(event, _capture_device)
	if binding.is_empty():
		return
	get_viewport().set_input_as_handled()
	var action := capturing_action
	var device := _capture_device
	_stop_capture()
	Settings.rebind(action, device, binding)


func _switch_tab(direction: int) -> void:
	tabs.current_tab = posmod(tabs.current_tab + direction, tabs.get_tab_count())
	focus_first()


## Puts controller and keyboard focus on the first control in the open tab.
func focus_first() -> void:
	var first := _first_focusable(tabs.get_current_tab_control())
	if first != null:
		first.grab_focus()


func _first_focusable(node: Node) -> Control:
	for child in node.get_children():
		if child is Control and child.focus_mode == Control.FOCUS_ALL and not child is ScrollContainer and child.is_visible_in_tree():
			return child
		var found := _first_focusable(child)
		if found != null:
			return found
	return null
