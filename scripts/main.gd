extends Control
## All the menus and the in-game HUD, built in code and switched by game phase.

const ACCENT := Color(1.0, 0.6, 0.22)
const ACCENT_DARK := Color(0.78, 0.3, 0.07)
const INK := Color(0.07, 0.06, 0.09)
const VERSION := "0.1"

var _menu: Control
var _menu_main: VBoxContainer
var _menu_join: VBoxContainer
var _menu_credits: VBoxContainer
var _backdrop: MenuBackdrop
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
var _crew_panel: PanelContainer
var _crew_label: Label
var _blind: ColorRect
var _terminal: PanelContainer
var _terminal_credits: Label
var _terminal_message: Label
var _terminal_buttons := {} # gear kind -> its Buy button
var _terminal_open := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# This full-screen layer must let mouse movement through to the player's camera.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = _make_theme()
	_build_menu()
	_build_lobby()
	_build_hud()
	_build_pause()
	_build_results()
	_build_shop()
	_build_terminal()
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
	Session.phase_changed.connect(_close_terminal_if_gone)
	Session.results_ready.connect(_on_results)
	Session.terminal_requested.connect(_open_terminal)
	Session.shop_replied.connect(_on_shop_replied)
	Session.stats_changed.connect(_refresh_terminal)
	Cloud.leaderboard_received.connect(_on_leaderboard)
	_refresh()
	Cloud.fetch_leaderboard()


func _process(_delta: float) -> void:
	if not _hud.visible:
		return
	var in_orbit := Session.phase == Session.Phase.ORBIT
	if in_orbit:
		var next: Dictionary = MapThemes.get_theme(Session.next_map)
		_top_label.text = "IN ORBIT    Level %d    Day %d of %d    Goal $%d / $%d    Credits $%d" % [
			Session.level_number, Session.day, Session.days_per_level, Session.level_banked, Session.quota, Session.credits]
		_banner_label.text = "IN ORBIT\nNext stop: %s\nBuy gear at the terminal, then pull the lever at the console to land." % next.name
		_update_crew_panel()
	else:
		var seconds := int(ceil(Session.time_left))
		var theme: Dictionary = MapThemes.get_theme(Session.map_id)
		_top_label.text = "%s    Level %d    Day %d of %d    Time %d:%02d    In ship $%d    Goal $%d / $%d" % [
			theme.name, Session.level_number, Session.day, Session.days_per_level, seconds / 60, seconds % 60,
			Session.in_ship_value, Session.level_banked + Session.in_ship_value, Session.quota]
		_banner_label.text = "%s\n%s\n%s" % [theme.name.to_upper(), theme.tagline, theme.rule]
	_crew_panel.visible = in_orbit
	# The terminal covers the middle of the screen, so nothing else is shown behind it.
	_banner_label.visible = Session.banner_seconds > 0.0 and not _terminal_open
	_prompt_label.visible = not _terminal_open
	_crosshair.visible = Settings.value("crosshair") and not _terminal_open
	_blind.visible = Session.blind_seconds > 0.0
	_blind.color.a = clampf(Session.blind_seconds / Tools.BLIND_SECONDS, 0.0, 1.0)
	_close_terminal_if_gone()
	_hint_label.visible = Session.hint_seconds > 0.0 and not _terminal_open
	_hint_label.text = Session.hint_text
	var player := Session.player_node(Net.my_id())
	if player != null:
		_prompt_label.text = player.interact_prompt
		_stamina_bar.value = player.stamina
	_update_phone(player)
	_update_backpack()
	var state: Dictionary = Session.player_states.get(Net.my_id(), {"hp": 0})
	_health_bar.value = state.hp


func _update_crew_panel() -> void:
	var lines := PackedStringArray(["CREW %d / %d" % [Net.players.size(), Rules.MAX_PLAYERS]])
	var peers: Array = Net.players.keys()
	peers.sort()
	for peer: int in peers:
		lines.append(("%s (host)" if peer == 1 else "%s") % Net.players[peer])
	if multiplayer.is_server():
		var addresses := Net.local_addresses()
		if not addresses.is_empty():
			lines.append("")
			lines.append("Friends join with:\n%s" % addresses[0])
	_crew_label.text = "\n".join(lines)


func _update_backpack() -> void:
	var carried := Session.items_held_by(Net.my_id())
	for index in _carry_slots.size():
		var slot: PanelContainer = _carry_slots[index]
		var label: Label = slot.get_child(0)
		var item: Scrap = carried[index] if index < carried.size() else null
		label.text = item.describe().replace(" (", "\n(") if item != null else ""
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
			Settings.prompt_for("use_item"), Settings.prompt_for("phone_record"),
			PhoneCamera.RECORD_SECONDS, Settings.prompt_for("phone")]
		_phone_status.remove_theme_color_override("font_color")


func _open_captures_folder() -> void:
	var folder := PhoneCamera.capture_folder()
	DirAccess.make_dir_recursive_absolute(folder)
	OS.shell_open(folder)


func _unhandled_input(event: InputEvent) -> void:
	if _menu.visible and not _menu_main.visible and event.is_action_pressed("ui_cancel"):
		_show_menu_page(_menu_main)
		get_viewport().set_input_as_handled()
	elif _terminal_open and (event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")):
		_close_terminal()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("pause") and Session.in_world() and not _settings_open:
		_set_paused(not _paused)
	elif event is InputEventMouseButton and event.pressed and _hud.visible and not _paused:
		_update_mouse()


func _refresh() -> void:
	var online := Net.is_online()
	var phase := Session.phase
	_menu.visible = not online and not _shop_open and not _settings_open
	_set_backdrop(not online)
	_shop.visible = not online and _shop_open and not Store.order.has("status")
	_settings_menu.visible = _settings_open
	_qr_panel.visible = not online and _shop_open and Store.order.has("status")
	_shop_button.visible = Store.payments_allowed()
	_lobby.visible = online and phase == Session.Phase.LOBBY
	_hud.visible = online and Session.in_world()
	_results.visible = online and (phase == Session.Phase.RESULTS or phase == Session.Phase.GAME_OVER)
	if not Session.in_world() or not online:
		_paused = false
		_terminal_open = false
	_pause.visible = _paused and not _settings_open
	_terminal.visible = _terminal_open and not _paused and not _settings_open
	var lines := PackedStringArray()
	var peers: Array = Net.players.keys()
	peers.sort()
	for peer: int in peers:
		lines.append(("%s (host)" if peer == 1 else "%s") % Net.players[peer])
	_lobby_list.text = "\n".join(lines) if not lines.is_empty() else "Joining..."
	_update_mouse()
	_update_focus()


## The ship behind the menu exists only while offline: in play, the real level takes over.
func _set_backdrop(wanted: bool) -> void:
	if wanted and _backdrop == null:
		_backdrop = MenuBackdrop.new()
		add_child(_backdrop)
		move_child(_backdrop, 0)
	elif not wanted and _backdrop != null:
		remove_child(_backdrop)
		_backdrop.queue_free()
		_backdrop = null


func _show_menu_page(page: VBoxContainer) -> void:
	for each: VBoxContainer in [_menu_main, _menu_join, _menu_credits]:
		each.visible = each == page
	get_viewport().gui_release_focus()
	_update_focus()


func _set_paused(paused: bool) -> void:
	_paused = paused
	_refresh()


func _update_mouse() -> void:
	var in_game := _hud.visible and not _paused and not _settings_open and not _terminal_open
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if in_game else Input.MOUSE_MODE_VISIBLE


## Keeps controller and keyboard focus on the open menu, and off everything in play.
func _update_focus() -> void:
	var owner_control := get_viewport().gui_get_focus_owner()
	if _settings_open:
		if owner_control == null or not owner_control.is_visible_in_tree() or not _settings_menu.is_ancestor_of(owner_control):
			_settings_menu.focus_first()
		return
	var panel: Control = null
	for candidate: Control in [_menu, _lobby, _pause, _shop, _qr_panel, _terminal]:
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


## One click: host a game and wait in the ship, where friends can join you.
func _on_host_pressed() -> void:
	var error := Net.host(_name_edit.text)
	if error != OK:
		_menu_status.text = "Could not host: %s. Is another copy already hosting?" % error_string(error)
		return
	_menu_status.text = ""
	Session.open_ship()
	_refresh()


func _on_join_pressed() -> void:
	_show_menu_page(_menu_main)
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
	var gear := "Gear kept in the ship: %d" % data.gear_kept
	if data.run_over:
		gear = "A new run starts with fresh credits and no gear."
	_results_label.text = "%s\n\nLevel %d, day %d of %d\n%s\nGoal: $%d of $%d\nSurvivors: %d\nRun total: $%d\nCredits: $%d\n%s" % [
		headline, data.level, data.day, data.days, today, data.banked, data.quota, data.survivors, data.total_scrap, data.credits, gear]


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


# --- The ship's terminal --------------------------------------------------------

func _open_terminal() -> void:
	if not Session.in_world() or _paused or _settings_open:
		return
	_terminal_open = true
	_terminal_message.text = ""
	_refresh_terminal()
	Sfx.play_2d("console", -10.0)
	_refresh()


func _close_terminal() -> void:
	if not _terminal_open:
		return
	_terminal_open = false
	get_viewport().gui_release_focus()
	_refresh()


## Walking away, dying or the ship taking off all close the terminal.
func _close_terminal_if_gone() -> void:
	if not _terminal_open:
		return
	var me := Session.player_node(Net.my_id())
	if not Session.in_world() or me == null or not me.is_alive() or me.position.distance_to(Rules.TERMINAL_POS) > Rules.SERVER_RANGE:
		_close_terminal()


func _refresh_terminal() -> void:
	_terminal_credits.text = "Crew credits: $%d    Gear owned: %d / %d" % [Session.credits, Session.gear_count(), Rules.TOOL_LIMIT]
	for kind: String in _terminal_buttons:
		var button: Button = _terminal_buttons[kind]
		var price: int = Tools.CATALOG[kind].price
		button.disabled = Session.credits < price
		button.text = "Buy  $%d" % price


func _buy(kind: String) -> void:
	_terminal_message.text = "Ordering..."
	Session.request_buy.rpc_id(1, kind)


func _on_shop_replied(ok: bool, message: String) -> void:
	_terminal_message.text = message
	_terminal_message.add_theme_color_override("font_color", Color(0.55, 1.0, 0.6) if ok else Color(1.0, 0.45, 0.4))
	_refresh_terminal()


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


## The title screen: the ship behind, the game's name and buttons down the left, and
## the leaderboard on the right.
func _build_menu() -> void:
	_menu = Control.new()
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_menu)
	# Darkens the left side, so the buttons read clearly over the scene.
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.02, 0.015, 0.03, 0.92))
	gradient.set_color(1, Color(0.02, 0.015, 0.03, 0.0))
	var shade_texture := GradientTexture2D.new()
	shade_texture.gradient = gradient
	shade_texture.fill_to = Vector2(1, 0)
	var shade := TextureRect.new()
	shade.texture = shade_texture
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.anchor_bottom = 1.0
	shade.anchor_right = 0.62
	_menu.add_child(shade)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	column.position = Vector2(72, 56)
	column.custom_minimum_size = Vector2(380, 0)
	_menu.add_child(column)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 14)
	column.add_child(title_row)
	var icon := TextureRect.new()
	icon.texture = load("res://assets/icon/icon.png")
	icon.custom_minimum_size = Vector2(72, 72)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	title_row.add_child(icon)
	var title := _label(title_row, "QUOTAPHOBIA", 50)
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	title.add_theme_color_override("font_color", ACCENT)
	title.add_theme_color_override("font_outline_color", Color(0.25, 0.05, 0.0))
	title.add_theme_constant_override("outline_size", 10)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var tagline := _label(column, "Meet the quota. Don't meet what's down there.", 17)
	tagline.add_theme_color_override("font_color", Color(0.85, 0.8, 0.75))
	_spacer(column, 18)

	_menu_main = VBoxContainer.new()
	_menu_main.add_theme_constant_override("separation", 8)
	column.add_child(_menu_main)
	_small_heading(_menu_main, "YOUR NAME")
	_name_edit = LineEdit.new()
	_name_edit.text = "Player"
	_name_edit.max_length = 16
	_menu_main.add_child(_name_edit)
	_spacer(_menu_main, 6)
	_play_button = _button(_menu_main, "Play", _on_host_pressed)
	_play_button.add_theme_font_size_override("font_size", 26)
	_play_button.custom_minimum_size.y = 56
	_play_button.tooltip_text = "Start in your ship. Friends can join any time it's in orbit."
	_button(_menu_main, "Join a friend", func() -> void: _show_menu_page(_menu_join))
	_shop_button = _button(_menu_main, "Shop", _on_shop_pressed)
	_menu_settings_button = _button(_menu_main, "Settings", _open_settings)
	_button(_menu_main, "Photos and videos", _open_captures_folder)
	_button(_menu_main, "Credits", func() -> void: _show_menu_page(_menu_credits))
	_button(_menu_main, "Quit", get_tree().quit)

	_menu_join = VBoxContainer.new()
	_menu_join.add_theme_constant_override("separation", 8)
	_menu_join.visible = false
	column.add_child(_menu_join)
	_small_heading(_menu_join, "JOIN A FRIEND")
	_label(_menu_join, "Type the address shown in the top-right corner of your friend's screen while their ship is in orbit. Leave it empty to join a game on this computer.", 16)
	_address_edit = LineEdit.new()
	_address_edit.placeholder_text = "127.0.0.1"
	_menu_join.add_child(_address_edit)
	var join := _button(_menu_join, "Join", _on_join_pressed)
	join.add_theme_font_size_override("font_size", 24)
	_button(_menu_join, "Back", func() -> void: _show_menu_page(_menu_main))

	_menu_credits = VBoxContainer.new()
	_menu_credits.add_theme_constant_override("separation", 8)
	_menu_credits.visible = false
	column.add_child(_menu_credits)
	_small_heading(_menu_credits, "CREDITS")
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(440, 380)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_menu_credits.add_child(scroll)
	var credits := _label(scroll, _credits_text(), 14)
	credits.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(_menu_credits, "Back", func() -> void: _show_menu_page(_menu_main))

	_menu_status = _label(column, "")
	_menu_status.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))

	# The leaderboard, as a card on the right.
	var board := PanelContainer.new()
	board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(board)
	_board_label = _label(board, "Loading leaderboard...", 15)
	# Without wrapping, the card is exactly as big as what it says.
	_board_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	# Pinned to the top-right corner; it grows left and down to fit what it says.
	board.anchor_left = 1.0
	board.anchor_right = 1.0
	board.offset_right = -40.0
	board.offset_left = -40.0
	board.offset_top = 56.0
	board.offset_bottom = 56.0
	board.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	var version := _label(_menu, "Version %s    Made with Godot Engine" % VERSION, 13)
	version.autowrap_mode = TextServer.AUTOWRAP_OFF
	version.add_theme_color_override("font_color", Color(0.7, 0.68, 0.66))
	version.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 24)
	version.grow_vertical = Control.GROW_DIRECTION_BEGIN


## The Godot license asks for its notice to ship with the game; this is where it lives.
func _credits_text() -> String:
	return "\n".join([
		"QUOTAPHOBIA, version %s" % VERSION,
		"",
		"Art and sound by Kenney (kenney.nl), released under CC0.",
		"The game icon and ambient hum were made for this game.",
		"",
		"Made with Godot Engine (godotengine.org), used under the MIT license:",
		"",
		Engine.get_license_text(),
	])


func _small_heading(parent: Node, text: String) -> Label:
	var heading := _label(parent, text, 13)
	heading.add_theme_color_override("font_color", ACCENT)
	return heading


func _spacer(parent: Node, height: float) -> void:
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, height)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(gap)


## One look for every menu and panel: dark glass, warm orange like the game's icon.
func _make_theme() -> Theme:
	var look := Theme.new()
	var normal := _box(Color(INK, 0.82), Color(1, 1, 1, 0.08))
	var hover := _box(ACCENT_DARK, ACCENT)
	var pressed := _box(Color(0.55, 0.2, 0.04), ACCENT)
	var focus := _box(Color(0, 0, 0, 0), ACCENT)
	focus.draw_center = false
	focus.set_border_width_all(2)
	var disabled := _box(Color(INK, 0.5), Color(1, 1, 1, 0.04))
	for state: String in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		var style: StyleBoxFlat = {"normal": normal, "hover": hover, "pressed": pressed, "focus": focus, "disabled": disabled, "hover_pressed": pressed}[state]
		look.set_stylebox(state, "Button", style)
	look.set_color("font_color", "Button", Color(0.95, 0.93, 0.9))
	look.set_color("font_hover_color", "Button", Color.WHITE)
	look.set_color("font_pressed_color", "Button", Color.WHITE)
	look.set_color("font_focus_color", "Button", Color.WHITE)
	look.set_color("font_disabled_color", "Button", Color(0.55, 0.53, 0.52))
	look.set_font_size("font_size", "Button", 19)
	look.set_stylebox("panel", "PanelContainer", _box(Color(0.05, 0.04, 0.07, 0.9), Color(ACCENT, 0.25)))
	var field := _box(Color(0.02, 0.02, 0.03, 0.85), Color(1, 1, 1, 0.15))
	look.set_stylebox("normal", "LineEdit", field)
	var field_focus := _box(Color(0.02, 0.02, 0.03, 0.9), ACCENT)
	look.set_stylebox("focus", "LineEdit", field_focus)
	look.set_font_size("font_size", "LineEdit", 18)
	return look


func _box(fill: Color, border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(6)
	box.content_margin_left = 16
	box.content_margin_right = 16
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	return box


func _build_lobby() -> void:
	var parts := _panel()
	_lobby = parts[0]
	var box: VBoxContainer = parts[1]
	_label(box, "Boarding the ship...", 24)
	_lobby_list = _label(box, "")
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
	_build_crew_panel()
	# A stun grenade you looked at turns the screen white for a moment.
	_blind = ColorRect.new()
	_blind.color = Color(1, 1, 1, 0)
	_blind.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blind.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blind.visible = false
	_hud.add_child(_blind)
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


func _build_crew_panel() -> void:
	_crew_panel = PanelContainer.new()
	_crew_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_crew_panel)
	_crew_label = _label(_crew_panel, "", 18)
	_crew_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_crew_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	_crew_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_crew_panel.position.y = 56.0
	_crew_panel.visible = false


func _build_terminal() -> void:
	var parts := _panel()
	_terminal = parts[0]
	_terminal.custom_minimum_size = Vector2(620, 0)
	# Solid, like a real screen, so the game behind it can't make it hard to read.
	var screen := StyleBoxFlat.new()
	screen.bg_color = Color(0.03, 0.07, 0.05, 0.97)
	screen.border_color = Color(0.35, 0.85, 0.5)
	screen.set_border_width_all(2)
	screen.set_corner_radius_all(6)
	_terminal.add_theme_stylebox_override("panel", screen)
	var box: VBoxContainer = parts[1]
	_label(box, "SHIP TERMINAL", 28)
	_label(box, "Gear is paid for with the crew's credits. Every dollar of scrap you bank earns one.")
	_terminal_credits = _label(box, "", 18)
	for kind: String in Tools.ORDER:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		box.add_child(row)
		var about := _label(row, "%s\n%s" % [kind.to_upper(), Tools.CATALOG[kind].about], 15)
		about.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var buy := _button(row, "Buy", _buy.bind(kind))
		buy.custom_minimum_size = Vector2(110, 0)
		buy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_terminal_buttons[kind] = buy
	_terminal_message = _label(box, "")
	_button(box, "Close", _close_terminal)


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
