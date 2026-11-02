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
var _board_label: Label
var _lobby_list: Label
var _start_button: Button
var _top_label: Label
var _prompt_label: Label
var _crosshair: Label
var _health_bar: ProgressBar
var _stamina_bar: ProgressBar
var _results_label: Label
var _volume_sliders: Array[HSlider] = []
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
	_top_label.text = "Round %d    Time %d:%02d    In ship $%d / quota $%d" % [
		Session.round_number, seconds / 60, seconds % 60, Session.in_ship_value, Session.quota]
	var player := Session.player_node(Net.my_id())
	if player != null:
		_prompt_label.text = player.interact_prompt
		_stamina_bar.value = player.stamina
	var state: Dictionary = Session.player_states.get(Net.my_id(), {"hp": 0})
	_health_bar.value = state.hp


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and Session.phase == Session.Phase.PLAYING:
		_pause.visible = not _pause.visible
		_update_mouse()
	elif event is InputEventMouseButton and event.pressed and _hud.visible and not _pause.visible:
		_update_mouse()


func _refresh() -> void:
	var online := Net.is_online()
	var phase := Session.phase
	_menu.visible = not online and not _shop_open
	_shop.visible = not online and _shop_open and not Store.order.has("status")
	_qr_panel.visible = not online and _shop_open and Store.order.has("status")
	_shop_button.visible = Store.payments_allowed()
	_lobby.visible = online and phase == Session.Phase.LOBBY
	_hud.visible = online and phase == Session.Phase.PLAYING
	_results.visible = online and (phase == Session.Phase.RESULTS or phase == Session.Phase.GAME_OVER)
	if phase != Session.Phase.PLAYING or not online:
		_pause.visible = false
	var lines := PackedStringArray()
	var peers: Array = Net.players.keys()
	peers.sort()
	for peer: int in peers:
		lines.append(("%s (host)" if peer == 1 else "%s") % Net.players[peer])
	_lobby_list.text = "\n".join(lines) if not lines.is_empty() else "Joining..."
	_start_button.visible = online and multiplayer.is_server()
	_update_mouse()


func _update_mouse() -> void:
	var in_game := _hud.visible and not _pause.visible
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if in_game else Input.MOUSE_MODE_VISIBLE


func _on_host_pressed() -> void:
	var error := Net.host(_name_edit.text)
	if error != OK:
		_menu_status.text = "Could not host: %s. Is another copy already hosting?" % error_string(error)
		return
	_menu_status.text = ""
	_refresh()


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
	var headline: String = "Quota met! Next round is coming up." if data.cleared else "Run over. Back to the lobby soon."
	_results_label.text = "%s\n\nRound %d\nCollected $%d of $%d\nSurvivors: %d\nRun total: $%d" % [
		headline, data.round, data.collected, data.quota, data.survivors, data.total_scrap]


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
		lines.append("%d. %s  $%d  (%d rounds, crew of %d)" % [
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


func _volume_slider(parent: Node) -> HSlider:
	_label(parent, "Volume")
	var slider := HSlider.new()
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = Sfx.volume
	slider.value_changed.connect(_on_volume_changed)
	slider.drag_ended.connect(_on_volume_drag_ended.unbind(1))
	parent.add_child(slider)
	_volume_sliders.append(slider)
	return slider


func _on_volume_changed(value: float) -> void:
	Sfx.set_volume(value)
	for slider in _volume_sliders:
		slider.set_value_no_signal(value)


func _on_volume_drag_ended() -> void:
	Sfx.save_volume()


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
	_button(box, "Host a game", _on_host_pressed)
	_label(box, "Host's address (leave empty for this computer)")
	_address_edit = LineEdit.new()
	_address_edit.placeholder_text = "127.0.0.1"
	box.add_child(_address_edit)
	_button(box, "Join a game", _on_join_pressed)
	_shop_button = _button(box, "Shop", _on_shop_pressed)
	_volume_slider(box)
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
	_prompt_label.anchor_right = 1.0
	_prompt_label.anchor_top = 0.58
	_prompt_label.anchor_bottom = 0.58
	_crosshair = _label(_hud, "+", 20)
	_crosshair.autowrap_mode = TextServer.AUTOWRAP_OFF
	_crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_crosshair.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_crosshair.grow_vertical = Control.GROW_DIRECTION_BOTH
	_health_bar = _bar(Vector2(20, -70), Rules.PLAYER_MAX_HP, Color(0.8, 0.2, 0.2))
	_stamina_bar = _bar(Vector2(20, -40), 1.0, Color(0.3, 0.7, 0.3))
	_stamina_bar.step = 0.01


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
	_volume_slider(box)
	_button(box, "Resume", func() -> void:
		_pause.visible = false
		_update_mouse())
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
