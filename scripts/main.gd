extends Control
## All the menus and the in-game HUD, built in code and switched by game phase.

var _menu: PanelContainer
var _lobby: PanelContainer
var _hud: Control
var _pause: PanelContainer
var _results: PanelContainer

var _name_edit: LineEdit
var _address_edit: LineEdit
var _menu_status: Label
var _play_button: Button
var _board_label: Label
var _lobby_list: Label
var _start_button: Button
var _top_label: Label
var _banner_label: Label
var _hint_label: Label
var _prompt_label: Label
var _crosshair: Label
var _health_bar: ProgressBar
var _stamina_bar: ProgressBar
var _results_label: Label
var _carry_slots: Array[PanelContainer] = []
var _slot_style: StyleBoxFlat
var _slot_hand_style: StyleBoxFlat
var _phone_panel: PanelContainer
var _phone_view: TextureRect
var _phone_status: Label
var _phone_toast: Label
var _settings_menu: SettingsMenu
var _settings_open := false
var _paused := false
var _pause_settings_button: Button
var _menu_settings_button: Button
var _shop: PanelContainer
var _shop_button: Button
var _shop_list: VBoxContainer
var _shop_status: Label
var _qr_panel: PanelContainer
var _qr_frame: PanelContainer
var _qr_image: TextureRect
var _qr_label: Label
var _shop_open := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# This full-screen layer must let mouse movement through to the player's camera.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_menu()
	_build_lobby()
	_build_hud()
	_build_pause()
	_build_results()
	_build_shop()
	_settings_menu = SettingsMenu.new()
	_settings_menu.visible = false
	_settings_menu.closed.connect(_close_settings)
	add_child(_settings_menu)
	Store.changed.connect(_refresh_shop)
	Store.order_changed.connect(_refresh_order)
	Net.players_changed.connect(_refresh)
	Net.connected.connect(_on_connected)
	Net.connection_ended.connect(_on_connection_ended)
	Session.phase_changed.connect(_refresh)
	Session.results_ready.connect(_on_results)
	Cloud.leaderboard_received.connect(_on_leaderboard)
	_refresh()
	Cloud.fetch_leaderboard()


func _process(_delta: float) -> void:
	if not _hud.visible:
		return
	var seconds := int(ceil(Session.time_left))
	var theme: Dictionary = MapThemes.get_theme(Session.map_id)
	_top_label.text = "%s    Level %d    Day %d of %d    Time %d:%02d    In ship $%d    Goal $%d / $%d" % [
		theme.name, Session.level_number, Session.day, Session.days_per_level, seconds / 60, seconds % 60,
		Session.in_ship_value, Session.level_banked + Session.in_ship_value, Session.quota]
	_banner_label.visible = Session.banner_seconds > 0.0
	_banner_label.text = "%s\n%s\n%s" % [theme.name.to_upper(), theme.tagline, theme.rule]
	_hint_label.visible = Session.hint_seconds > 0.0
	_hint_label.text = Session.hint_text
	_crosshair.visible = Settings.value("crosshair")
	var player := Session.player_node(Net.my_id())
	if player != null:
		_prompt_label.text = player.interact_prompt
		_stamina_bar.value = player.stamina
	_update_phone(player)
	_update_backpack()
	var state: Dictionary = Session.player_states.get(Net.my_id(), {"hp": 0})
	_health_bar.value = state.hp


func _update_backpack() -> void:
	var carried := Session.items_held_by(Net.my_id())
	for index in _carry_slots.size():
		var slot: PanelContainer = _carry_slots[index]
		var label: Label = slot.get_child(0)
		var item: Scrap = carried[index] if index < carried.size() else null
		label.text = "%s\n$%d" % [item.kind, item.value] if item != null else ""
		var in_hand := item != null and not item.stowed
		slot.add_theme_stylebox_override("panel", _slot_hand_style if in_hand else _slot_style)


func _update_phone(player: Player) -> void:
	var phone: PhoneCamera = player.phone if player != null else null
	_phone_panel.visible = phone != null and phone.is_up
	_phone_toast.visible = phone != null and phone.message_seconds > 0.0
	if phone == null:
		return
	_phone_toast.text = phone.message
	if not phone.is_up:
		return
	if _phone_view.texture == null or _phone_view.texture != phone.texture():
		_phone_view.texture = phone.texture()
	if phone.is_recording:
		_phone_status.text = "REC  %.1f / %.0f s" % [phone.record_elapsed, PhoneCamera.RECORD_SECONDS]
		_phone_status.add_theme_color_override("font_color", Color(1.0, 0.3, 0.25))
	else:
		_phone_status.text = "%s: photo    %s: record %.0f s    %s: put away" % [
			Settings.prompt_for("phone_photo"), Settings.prompt_for("phone_record"),
			PhoneCamera.RECORD_SECONDS, Settings.prompt_for("phone")]
		_phone_status.remove_theme_color_override("font_color")


func _open_captures_folder() -> void:
	var folder := PhoneCamera.capture_folder()
	DirAccess.make_dir_recursive_absolute(folder)
	OS.shell_open(folder)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and Session.phase == Session.Phase.PLAYING and not _settings_open:
		_set_paused(not _paused)
	elif event is InputEventMouseButton and event.pressed and _hud.visible and not _paused:
		_update_mouse()


func _refresh() -> void:
	var online := Net.is_online()
	var phase := Session.phase
	_menu.visible = not online and not _shop_open and not _settings_open
	_shop.visible = not online and _shop_open and not Store.order.has("status")
	_settings_menu.visible = _settings_open
	_qr_panel.visible = not online and _shop_open and Store.order.has("status")
	_shop_button.visible = Store.payments_allowed()
	_lobby.visible = online and phase == Session.Phase.LOBBY
	_hud.visible = online and phase == Session.Phase.PLAYING
	_results.visible = online and (phase == Session.Phase.RESULTS or phase == Session.Phase.GAME_OVER)
	if phase != Session.Phase.PLAYING or not online:
		_paused = false
	_pause.visible = _paused and not _settings_open
	var lines := PackedStringArray()
	var peers: Array = Net.players.keys()
	peers.sort()
	for peer: int in peers:
		lines.append(("%s (host)" if peer == 1 else "%s") % Net.players[peer])
	_lobby_list.text = "\n".join(lines) if not lines.is_empty() else "Joining..."
	_start_button.visible = online and multiplayer.is_server()
	_update_mouse()
	_update_focus()


func _set_paused(paused: bool) -> void:
	_paused = paused
	_refresh()


func _update_mouse() -> void:
	var in_game := _hud.visible and not _paused and not _settings_open
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if in_game else Input.MOUSE_MODE_VISIBLE


## Keeps controller and keyboard focus on the open menu, and off everything in play.
func _update_focus() -> void:
	var owner_control := get_viewport().gui_get_focus_owner()
	if _settings_open:
		if owner_control == null or not owner_control.is_visible_in_tree() or not _settings_menu.is_ancestor_of(owner_control):
			_settings_menu.focus_first()
		return
	var panel: Control = null
	for candidate: Control in [_menu, _lobby, _pause, _shop, _qr_panel]:
		if candidate.visible:
			panel = candidate
	if panel == null:
		get_viewport().gui_release_focus()
	elif owner_control == null or not panel.is_ancestor_of(owner_control):
		var buttons := panel.find_children("*", "Button", true, false)
		for button: Button in buttons:
			if button.is_visible_in_tree():
				button.grab_focus()
				break


func _open_settings() -> void:
	_settings_open = true
	_refresh()


func _close_settings() -> void:
	_settings_open = false
	get_viewport().gui_release_focus()
	_refresh()


func _on_host_pressed() -> void:
	var error := Net.host(_name_edit.text)
	if error != OK:
		_menu_status.text = "Could not host: %s. Is another copy already hosting?" % error_string(error)
		return
	_menu_status.text = ""
	_refresh()


## One click: host a private game and start the first round straight away.
func _on_play_now_pressed() -> void:
	_on_host_pressed()
	if Net.is_online():
		Session.start_run()


func _on_join_pressed() -> void:
	var address := _address_edit.text.strip_edges()
	var error := Net.join(_name_edit.text, address if not address.is_empty() else "127.0.0.1")
	if error != OK:
		_menu_status.text = "Could not join: %s" % error_string(error)
		return
	_menu_status.text = "Connecting..."
	_refresh()


func _on_connected() -> void:
	_menu_status.text = ""


func _on_connection_ended(reason: String) -> void:
	_menu_status.text = reason
	_refresh()
	Cloud.fetch_leaderboard()


func _on_results(data: Dictionary) -> void:
	var days_left: int = data.days - data.day
	var headline := "Day over. %d %s left to reach the goal." % [days_left, "day" if days_left == 1 else "days"]
	if data.cleared:
		headline = "Goal reached! Level %d is next." % (data.level + 1)
	elif data.run_over:
		headline = "Out of days. The run is over."
	var today := "Banked today: $%d" % data.collected
	if data.survivors == 0:
		today = "Nobody made it back. Today's scrap is lost."
	_results_label.text = "%s\n\nLevel %d, day %d of %d\n%s\nGoal: $%d of $%d\nSurvivors: %d\nRun total: $%d" % [
		headline, data.level, data.day, data.days, today, data.banked, data.quota, data.survivors, data.total_scrap]


func _on_leaderboard(rows: Array) -> void:
	if not Cloud.is_configured():
		_board_label.text = "Leaderboard is offline."
		return
	if rows.is_empty():
		_board_label.text = "No leaderboard scores available."
		return
	var lines := PackedStringArray(["Top crews"])
	for index in rows.size():
		var row: Dictionary = rows[index]
		lines.append("%d. %s  $%d  (%d levels, crew of %d)" % [
			index + 1, row.display_name, row.total_scrap, row.rounds_cleared, row.crew_size])
	_board_label.text = "\n".join(lines)


# --- Shop ---------------------------------------------------------------------

func _on_shop_pressed() -> void:
	_shop_open = true
	_shop_status.text = "Loading..."
	_refresh()
	await Store.refresh()
	_shop_status.text = "" if not Store.products.is_empty() else "The shop isn't available right now."


func _on_shop_closed() -> void:
	_shop_open = false
	_refresh()


func _refresh_shop() -> void:
	for child in _shop_list.get_children():
		_shop_list.remove_child(child)
		child.queue_free()
	if not Store.equipped.is_empty():
		_button(_shop_list, "Use the standard crew look", Store.equip.bind(""))
	for product: Dictionary in Store.products:
		var product_id: String = product.id
		if not Store.SKIN_MODELS.has(product_id):
			continue
		var row := HBoxContainer.new()
		_shop_list.add_child(row)
		var name_label := _label(row, "%s  %s" % [product.name, Store.format_price(int(product.price_idr))])
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if Store.equipped == product_id:
			_label(row, "In use").autowrap_mode = TextServer.AUTOWRAP_OFF
		elif Store.owned.has(product_id):
			_button(row, "Use", Store.equip.bind(product_id))
		else:
			_button(row, "Buy with QRIS", Store.buy.bind(product_id))


func _refresh_order() -> void:
	_qr_image.texture = Store.qr_texture
	_qr_frame.visible = Store.qr_texture != null and Store.order.get("status", "") == "pending"
	var amount := ""
	if Store.order.has("amount_idr"):
		amount = Store.format_price(Store.order.amount_idr) + "\n"
	_qr_label.text = amount + Store.order.get("message", "")
	_refresh()


# --- UI construction --------------------------------------------------------

func _panel() -> Array:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(480, 0)
	add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)
	return [panel, box]


func _label(parent: Node, text: String, font_size: int = 16) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(Sfx.play_2d.bind("click", -14.0))
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _build_menu() -> void:
	var parts := _panel()
	_menu = parts[0]
	var box: VBoxContainer = parts[1]
	_label(box, "SCRAP SHIFT", 36)
	_label(box, "Your name")
	_name_edit = LineEdit.new()
	_name_edit.text = "Player"
	_name_edit.max_length = 16
	box.add_child(_name_edit)
	_play_button = _button(box, "Play now", _on_play_now_pressed)
	_button(box, "Host a game with friends", _on_host_pressed)
	_label(box, "Host's address (leave empty for this computer)")
	_address_edit = LineEdit.new()
	_address_edit.placeholder_text = "127.0.0.1"
	box.add_child(_address_edit)
	_button(box, "Join a game", _on_join_pressed)
	_shop_button = _button(box, "Shop", _on_shop_pressed)
	_menu_settings_button = _button(box, "Settings", _open_settings)
	_button(box, "My photos and videos", _open_captures_folder)
	_button(box, "Quit", get_tree().quit)
	_menu_status = _label(box, "")
	_board_label = _label(box, "Loading leaderboard...", 14)


func _build_lobby() -> void:
	var parts := _panel()
	_lobby = parts[0]
	var box: VBoxContainer = parts[1]
	_label(box, "Crew (up to %d)" % Rules.MAX_PLAYERS, 24)
	_lobby_list = _label(box, "")
	_start_button = _button(box, "Start the shift", Session.start_run)
	_button(box, "Leave", Net.leave)


func _build_hud() -> void:
	_hud = Control.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hud)
	_top_label = _label(_hud, "", 22)
	_top_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_top_label.position = Vector2(20, 14)
	_prompt_label = _label(_hud, "", 20)
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_constant_override("outline_size", 6)
	_prompt_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_prompt_label.anchor_right = 1.0
	_prompt_label.anchor_top = 0.58
	_prompt_label.anchor_bottom = 0.58
	_banner_label = _label(_hud, "", 24)
	_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_label.anchor_right = 1.0
	_banner_label.anchor_top = 0.14
	_banner_label.anchor_bottom = 0.14
	_hint_label = _label(_hud, "", 20)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.anchor_left = 0.15
	_hint_label.anchor_right = 0.85
	_hint_label.anchor_top = 0.72
	_hint_label.anchor_bottom = 0.72
	_hint_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_hint_label.add_theme_constant_override("outline_size", 6)
	_hint_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_banner_label.add_theme_constant_override("outline_size", 6)
	_banner_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_crosshair = _label(_hud, "+", 20)
	_crosshair.autowrap_mode = TextServer.AUTOWRAP_OFF
	_crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_crosshair.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_crosshair.grow_vertical = Control.GROW_DIRECTION_BOTH
	_build_phone_panel()
	_build_backpack_slots()
	_health_bar = _bar(Vector2(20, -70), Rules.PLAYER_MAX_HP, Color(0.8, 0.2, 0.2))
	_stamina_bar = _bar(Vector2(20, -40), 1.0, Color(0.3, 0.7, 0.3))
	_stamina_bar.step = 0.01


func _build_backpack_slots() -> void:
	_slot_style = StyleBoxFlat.new()
	_slot_style.bg_color = Color(0.05, 0.05, 0.06, 0.65)
	_slot_style.set_corner_radius_all(4)
	_slot_style.set_content_margin_all(3)
	_slot_hand_style = _slot_style.duplicate()
	_slot_hand_style.bg_color = Color(0.45, 0.3, 0.08, 0.85)
	_slot_hand_style.set_border_width_all(2)
	_slot_hand_style.border_color = Color(1.0, 0.8, 0.35)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 4)
	_hud.add_child(row)
	for index in Rules.CARRY_LIMIT:
		var slot := PanelContainer.new()
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.custom_minimum_size = Vector2(86, 58)
		row.add_child(slot)
		var label := _label(slot, "", 11)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_carry_slots.append(slot)
	row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE)
	row.grow_vertical = Control.GROW_DIRECTION_BEGIN
	row.position.x = 256.0
	row.position.y -= 16.0


func _build_phone_panel() -> void:
	_phone_panel = PanelContainer.new()
	_phone_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var casing := StyleBoxFlat.new()
	casing.bg_color = Color(0.04, 0.04, 0.05)
	casing.set_corner_radius_all(14)
	casing.set_content_margin_all(10)
	_phone_panel.add_theme_stylebox_override("panel", casing)
	_hud.add_child(_phone_panel)
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_phone_panel.add_child(box)
	_phone_view = TextureRect.new()
	_phone_view.custom_minimum_size = Vector2(400, 225)
	_phone_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_phone_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_phone_view)
	_phone_status = _label(box, "", 14)
	_phone_status.autowrap_mode = TextServer.AUTOWRAP_OFF
	_phone_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_phone_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	_phone_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_phone_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_phone_panel.visible = false
	_phone_toast = _label(_hud, "", 20)
	_phone_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_phone_toast.anchor_right = 1.0
	_phone_toast.anchor_top = 0.08
	_phone_toast.anchor_bottom = 0.08
	_phone_toast.visible = false


func _bar(at: Vector2, maximum: float, color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.max_value = maximum
	bar.value = maximum
	bar.show_percentage = false
	bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bar.position = at
	bar.size = Vector2(220, 20)
	bar.custom_minimum_size = Vector2(220, 20)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	bar.add_theme_stylebox_override("fill", fill)
	_hud.add_child(bar)
	return bar


func _build_pause() -> void:
	var parts := _panel()
	_pause = parts[0]
	var box: VBoxContainer = parts[1]
	_label(box, "Paused (the shift keeps running)", 22)
	_button(box, "Resume", _set_paused.bind(false))
	_pause_settings_button = _button(box, "Settings", _open_settings)
	_button(box, "Leave game", Net.leave)


func _build_shop() -> void:
	var parts := _panel()
	_shop = parts[0]
	var box: VBoxContainer = parts[1]
	_label(box, "Shop", 28)
	_label(box, "New looks for your crew member. They don't affect gameplay.")
	_shop_list = VBoxContainer.new()
	box.add_child(_shop_list)
	_shop_status = _label(box, "")
	_button(box, "Back", _on_shop_closed)
	var qr_parts := _panel()
	_qr_panel = qr_parts[0]
	var qr_box: VBoxContainer = qr_parts[1]
	_label(qr_box, "Pay with QRIS", 24)
	_qr_image = TextureRect.new()
	_qr_image.custom_minimum_size = Vector2(300, 300)
	_qr_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_qr_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_qr_image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# Phone cameras need a white margin around a QR code to be able to scan it.
	_qr_frame = PanelContainer.new()
	var white := StyleBoxFlat.new()
	white.bg_color = Color.WHITE
	white.set_content_margin_all(24)
	_qr_frame.add_theme_stylebox_override("panel", white)
	_qr_frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_qr_frame.add_child(_qr_image)
	qr_box.add_child(_qr_frame)
	_qr_label = _label(qr_box, "")
	_button(qr_box, "Close", Store.close_order)


func _build_results() -> void:
	var parts := _panel()
	_results = parts[0]
	_results_label = _label(parts[1], "", 20)
