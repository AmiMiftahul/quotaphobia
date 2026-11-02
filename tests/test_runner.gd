extends Node
## Plays the real game over real network connections, driven by tests/run_tests.py.
## Roles: unit, host (idx 0), client (idx 1-3), extra (a fifth player who must be refused).

var role := "unit"
var idx := 0
var port := 24600
var fails := 0
var _arrived := {}
var _released := {}
var _ended_reason := ""


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var parts := arg.split("=")
		match parts[0]:
			"role": role = parts[1]
			"idx": idx = int(parts[1])
			"port": port = int(parts[1])
	Net.connection_ended.connect(func(reason: String) -> void: _ended_reason = reason)
	match role:
		"unit": await _unit()
		"extra": await _extra()
		"ui": await _ui()
		"levels": await _levels()
		"store": await _store()
		"store_steam": await _store_steam()
		_: await _scenario()
	print("RESULT %s%d fails=%d" % [role, idx, fails])
	get_tree().quit(1 if fails > 0 else 0)


func check(label: String, condition: bool) -> void:
	print(("PASS " if condition else "FAIL ") + "%s%d: %s" % [role, idx, label])
	if not condition:
		fails += 1


func until(condition: Callable, timeout: float = 15.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while not condition.call():
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().physics_frame
	return true


func wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## Everyone waits here until all `count` players have arrived.
func barrier(step: String, count: int) -> void:
	if multiplayer.is_server():
		_mark(step, 1)
		await until(func() -> bool: return _arrived[step].size() >= count, 40.0)
		_rpc_release.rpc(step)
	else:
		_rpc_arrive.rpc_id(1, step)
		await until(func() -> bool: return _released.has(step), 40.0)


func _mark(step: String, peer: int) -> void:
	if not _arrived.has(step):
		_arrived[step] = {}
	_arrived[step][peer] = true


@rpc("any_peer", "reliable")
func _rpc_arrive(step: String) -> void:
	_mark(step, multiplayer.get_remote_sender_id())


@rpc("authority", "reliable")
func _rpc_release(step: String) -> void:
	_released[step] = true


func me() -> Player:
	return Session.player_node(Net.my_id())


func peer_named(player_name: String) -> int:
	for peer: int in Net.players:
		if Net.players[peer] == player_name:
			return peer
	return 0


func item(id: int) -> Scrap:
	return Session.scrap_root.get_node_or_null("Scrap%d" % id) as Scrap


func free_items_outside_ship() -> Array[Scrap]:
	var items: Array[Scrap] = []
	for scrap: Scrap in Session.scrap_root.get_children():
		if scrap.holder_id == 0 and not Rules.in_ship(scrap.position):
			items.append(scrap)
	return items


# --- Rules with no network ---------------------------------------------------

func _unit() -> void:
	var connected_ok := true
	var deterministic := true
	var winnable := true
	var ship_clear := true
	for seed_value in 200:
		var number := seed_value % 12 + 1
		var crew := seed_value % 4 + 1
		var required := Rules.quota(number, crew)
		var layout := FacilityLayout.new(seed_value, Rules.grid_size(number), number, required)
		var again := FacilityLayout.new(seed_value, Rules.grid_size(number), number, required)
		deterministic = deterministic and layout.fingerprint() == again.fingerprint()
		for cell in layout.all_cells():
			connected_ok = connected_ok and not layout.path(FacilityLayout.ENTRY_CELL, cell).is_empty()
		var total := 0
		for spawn in layout.scrap_spawns:
			total += spawn.value
			ship_clear = ship_clear and not Rules.in_ship(spawn.pos)
		winnable = winnable and total >= required
	check("every room is reachable (200 facilities)", connected_ok)
	check("same seed builds the same facility", deterministic)
	check("every round has enough scrap to meet quota", winnable)
	check("scrap never spawns inside the ship", ship_clear)
	var different := FacilityLayout.new(1, 6, 1, 100).fingerprint() != FacilityLayout.new(2, 6, 1, 100).fingerprint()
	check("different seeds build different facilities", different)
	check("quota grows every round", Rules.quota(2, 4) > Rules.quota(1, 4))
	check("quota grows with crew size", Rules.quota(1, 4) > Rules.quota(1, 1))
	check("secret database keys are refused", Cloud._is_secret_key("sb_secret_abc"))
	check("ship boundary", Rules.in_ship(Vector3(0, 0, -10)) and not Rules.in_ship(Vector3(0, 0, 0)))

	# Art and sound: everything must load, and nothing may block a walkway.
	check("every sound file loads", Sfx.missing_streams().is_empty())
	var models_ok := true
	var names: Array = []
	names.append_array(FacilityLayout.PROP_MODELS.keys())
	names.append_array(FacilityLayout.SCRAP_MODELS.values())
	for model: String in names:
		models_ok = models_ok and not Assets.mesh_parts(Assets.FACTORY % model).is_empty()
	for model: String in Player.MODELS:
		models_ok = models_ok and ResourceLoader.exists(Assets.CHARACTERS % model)
	check("every model loads", models_ok)
	var walkways_clear := true
	var scrap_clear := true
	for seed_value in 100:
		var layout := FacilityLayout.new(seed_value, 8, 4, 500)
		for prop in layout.props:
			var offset: Vector3 = prop.pos - FacilityLayout.cell_center(FacilityLayout.cell_at(prop.pos))
			var box := Assets.bounds(Assets.FACTORY % prop.model)
			var reach: float = maxf(box.size.x, box.size.z) * 0.5 * prop.scale
			# Doors and the routes between them run along each room's centre lines.
			walkways_clear = walkways_clear and absf(offset.x) - reach > Level.DOOR_WIDTH * 0.5 and absf(offset.z) - reach > Level.DOOR_WIDTH * 0.5
		for spawn in layout.scrap_spawns:
			var offset: Vector3 = spawn.pos - FacilityLayout.cell_center(FacilityLayout.cell_at(spawn.pos))
			scrap_clear = scrap_clear and not (absf(offset.x) > FacilityLayout.SCRAP_CLEARANCE and absf(offset.z) > FacilityLayout.SCRAP_CLEARANCE)
	check("props never block doors or walkways", walkways_clear)
	check("scrap never lands inside a prop", scrap_clear)
	await wait(0.01)


# --- The real menus, keyboard input and graphics, in a real window -------------

func _shot(file_name: String) -> void:
	await wait(0.4)
	var folder := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("shots="):
			folder = arg.trim_prefix("shots=")
	# With no window, nothing is ever drawn, so there's nothing to wait for.
	if folder.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(folder.path_join(file_name + ".png"))


func _press(keycode: Key) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = keycode
		event.keycode = keycode
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().process_frame
		await get_tree().process_frame


func _ui() -> void:
	var main: Control = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await _shot("1_menu")
	check("the menu shows at launch", main._menu.visible and not main._lobby.visible)

	main._name_edit.text = "  A very long player name indeed  "
	main._on_host_pressed()
	await wait(0.2)
	check("hosting opens the lobby", main._lobby.visible and not main._menu.visible)
	check("long names are trimmed", Net.players[1].length() <= 16 and not Net.players[1].begins_with(" "))
	check("the host sees the start button", main._start_button.visible)
	await _shot("2_lobby")

	Session.monster_enabled = false
	Session.results_seconds = 3.0
	main._start_button.pressed.emit()
	check("start button begins the round", await until(func() -> bool: return Session.phase == Session.Phase.PLAYING))
	check("the player appears", await until(func() -> bool: return me() != null))
	check("HUD replaces the menus", main._hud.visible and not main._lobby.visible)
	check("mouse is captured for looking around", Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	await _shot("3_ship")

	# Real keyboard: walking.
	var start := me().position
	Input.action_press("move_forward")
	await wait(1.0)
	Input.action_release("move_forward")
	check("W key walks forward", me().position.distance_to(start) > 1.0)
	me().teleport(Vector3(0, 0.1, -9.0))

	# Real mouse: looking.
	var yaw := me().rotation.y
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(200, 0)
	Input.parse_input_event(motion)
	await wait(0.1)
	check("moving the mouse turns the player", absf(me().rotation.y - yaw) > 0.1)
	me().rotation.y = 0.0

	# Real keyboard: pick up (E) with the prompt showing, then drop (G) in the ship.
	var target: Scrap = free_items_outside_ship()[0]
	me().teleport(Vector3(target.position.x, 0.1, target.position.z + 1.5))
	await wait(0.3)
	check("the pick-up prompt shows", me().interact_prompt.begins_with("E: pick up"))
	await _shot("4_scrap_in_facility")
	var screen := get_viewport().get_visible_rect()
	check("the HUD text stays on one line", main._top_label.size.y < 60.0)
	check("the HUD text fits on screen", screen.encloses(main._top_label.get_global_rect()))
	check("the prompt is fully on screen", screen.encloses(main._prompt_label.get_global_rect()))
	check("the prompt is centred", absf(main._prompt_label.get_global_rect().get_center().x - screen.get_center().x) < 2.0)
	check("the crosshair is in the centre", main._crosshair.get_global_rect().get_center().distance_to(screen.get_center()) < 4.0)
	check("the health bar is on screen", screen.encloses(main._health_bar.get_global_rect()))
	check("the stamina bar is on screen", screen.encloses(main._stamina_bar.get_global_rect()))
	await _press(KEY_E)
	check("E picks up scrap", await until(func() -> bool: return target.holder_id == 1, 3.0))
	await wait(0.1)
	check("carrying shows the drop prompt", me().interact_prompt.begins_with("G: drop"))
	me().teleport(Vector3(0, 0.1, -9.0))
	await wait(0.2)
	await _press(KEY_G)
	check("G drops scrap", await until(func() -> bool: return target.holder_id == 0, 3.0))
	check("HUD shows the ship's total", await until(func() -> bool: return main._top_label.text.contains("In ship $%d" % target.value), 3.0))

	# Flashlight.
	var lit := me().net_flashlight
	await _press(KEY_F)
	check("F toggles the flashlight", me().net_flashlight != lit)
	await _press(KEY_F)

	# The monster, seen for real.
	var monster := Session.monster_root.get_child(0) as Monster
	var room := FacilityLayout.cell_center(Session.layout.monster_spawn)
	monster.position = room + Vector3(0, 0, -3)
	monster.rotation.y = PI
	me().rotation.y = 0.0
	me().teleport(room + Vector3(0, 0.1, 1.5))
	await wait(0.2)
	await _shot("5_monster")

	# A crewmate, as other players see them. Peer 999 is a stand-in for this picture only.
	monster.position = Vector3(40, 0, 40)
	Session.player_states[999] = {"hp": 100, "alive": true}
	var crewmate: Player = Session._spawn_player({"peer": 999, "name": "Crewmate", "index": 1, "pos": Vector3(0, 0, -11.5)})
	Session.players_root.add_child(crewmate)
	crewmate.rotation.y = PI
	crewmate.net_yaw = PI
	me().rotation.y = 0.0
	me().teleport(Vector3(0, 0.1, -8.0))
	await _shot("5b_crewmate_in_ship")
	check("an idle crewmate plays the idle animation", crewmate.current_animation == "idle" and crewmate._animator.is_playing())
	crewmate.net_pos = Vector3(3, 0, -11.5)
	await until(func() -> bool: return crewmate.current_animation == "walk", 2.0)
	var skeleton: Skeleton3D = crewmate._body.find_children("*", "Skeleton3D", true, false)[0]
	var before: Array = []
	for bone in skeleton.get_bone_count():
		before.append(skeleton.get_bone_pose(bone))
	await wait(0.15)
	var bones_moved := 0
	for bone in skeleton.get_bone_count():
		if not skeleton.get_bone_pose(bone).is_equal_approx(before[bone]):
			bones_moved += 1
	check("the walk animation really moves the skeleton (%d bones)" % bones_moved, bones_moved > 3)
	await _shot("5d_crewmate_walking")
	Session.players_root.remove_child(crewmate)
	crewmate.queue_free()
	Session.player_states.erase(999)
	me().rotation.y = PI
	me().teleport(Vector3(0, 0.1, -11.0))
	await _shot("5c_ship_door")
	check("ambient hum plays during a round", Sfx._ambient.playing)
	check("ambient hum is set to loop", Sfx._ambient.stream.loop_mode == AudioStreamWAV.LOOP_FORWARD)
	var loudest := -200.0
	for tick in 60:
		loudest = maxf(loudest, AudioServer.get_bus_peak_volume_left_db(0, 0))
		await get_tree().process_frame
	check("sound really reaches the audio output (peak %.0f dB)" % loudest, loudest > -50.0)
	Sfx.set_volume(0.5)
	check("volume setting changes the output", is_equal_approx(db_to_linear(AudioServer.get_bus_volume_db(0)), 0.5))
	Sfx.set_volume(0.8)

	# A player can physically walk out of the ship's door, and back in.
	me().rotation.y = PI
	me().teleport(Vector3(0, 0.1, -8.0))
	me().bot_move = Vector2(0, -1)
	var walked_out: bool = await until(func() -> bool: return me().position.z > -3.0, 6.0)
	me().bot_move = Vector2.ZERO
	check("a player can walk out through the door (at %s)" % me().position, walked_out)
	me().bot_move = Vector2(0, 1)
	var walked_back: bool = await until(func() -> bool: return Rules.in_ship(me().position), 6.0)
	me().bot_move = Vector2.ZERO
	check("a player can walk back into the ship (at %s)" % me().position, walked_back)

	# The monster patrols between rooms on its own, and stays out of the ship.
	me().teleport(Vector3(0, 0.1, -9.0))
	monster.position = FacilityLayout.cell_center(Session.layout.monster_spawn)
	monster.grace = 0.0
	monster.enabled = true
	var rooms_seen := {}
	var stayed_inside := true
	for tick in 240:
		var cell := FacilityLayout.cell_at(monster.position)
		rooms_seen[cell] = true
		stayed_inside = stayed_inside and Session.layout.has_cell(cell)
		await get_tree().create_timer(0.1).timeout
	monster.enabled = false
	check("the monster patrols through several rooms (%d seen)" % rooms_seen.size(), rooms_seen.size() >= 2)
	check("the monster stays inside the facility", stayed_inside)

	# Pause menu.
	await _press(KEY_ESCAPE)
	check("Esc opens the pause menu and frees the mouse", main._pause.visible and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	await _shot("6_pause")
	await _press(KEY_ESCAPE)
	check("Esc closes the pause menu", not main._pause.visible and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)

	# Losing all health, seen from the HUD.
	Session.damage_player(1, Rules.MONSTER_DAMAGE)
	await wait(0.2)
	check("the health bar drops", main._health_bar.value == Rules.PLAYER_MAX_HP - Rules.MONSTER_DAMAGE)

	# The launch console, with the real E key.
	me().rotation.y = 0.0
	me().teleport(Rules.CONSOLE_POS + Vector3(0, 0.1, 1.6))
	await wait(0.3)
	check("the launch prompt shows", me().interact_prompt.begins_with("E: launch"))
	await _shot("7_console")
	await _press(KEY_E)
	check("E at the console ends the round", await until(func() -> bool: return Session.phase != Session.Phase.PLAYING, 3.0))
	check("the results screen shows", main._results.visible and not main._results_label.text.is_empty())
	check("the mouse is freed on results", Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	await _shot("8_results")

	# The random scrap may have met the quota. If so the next round starts, and the
	# timer running out with nothing in the ship ends the run instead.
	if Session.last_results.cleared:
		check("a met quota starts the next round", await until(func() -> bool: return Session.round_number == 2 and Session.phase == Session.Phase.PLAYING, 8.0))
		Session.time_left = 0.5

	# End of the run, then leaving.
	check("the crew gets back to the lobby", await until(func() -> bool: return Session.phase == Session.Phase.LOBBY, 8.0))
	check("the lobby shows after the run", main._lobby.visible)

	# Frame rate in the largest facility the game can build (8 x 8 rooms).
	Session._begin_round(4)
	await until(func() -> bool: return me() != null, 3.0)
	me().teleport(FacilityLayout.cell_center(Vector2i(3, 3)) + Vector3(0, 0.1, 0))
	await wait(3.0)
	var slowest := 10000.0
	for tick in 120:
		await get_tree().process_frame
		slowest = minf(slowest, 1.0 / maxf(get_process_delta_time(), 0.0001))
	var draws := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	print("PERF average %d fps, slowest frame %d fps, %d draw calls" % [Engine.get_frames_per_second(), slowest, draws])
	check("the largest facility holds at least 30 fps", Engine.get_frames_per_second() >= 30)
	await _shot("9_large_facility")
	Net.leave()
	await wait(0.2)
	check("leaving returns to the menu", main._menu.visible)


# --- Measures how loud each sound is, one at a time, at master volume 100% ------

func _peak_over(seconds: float) -> float:
	var loudest := -200.0
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		loudest = maxf(loudest, AudioServer.get_bus_peak_volume_left_db(0, 0))
		await get_tree().process_frame
	return loudest


func _levels() -> void:
	Sfx.set_volume(1.0)
	await wait(0.5)
	Sfx.set_ambient(true)
	print("LEVEL ambient %.1f dB" % await _peak_over(4.0))
	Sfx.set_ambient(false)
	await wait(0.5)
	var hum := Sfx.make_ship_hum(Vector3.ZERO)
	var listener := Camera3D.new()
	var world := Node3D.new()
	add_child(world)
	world.add_child(listener)
	listener.make_current()
	listener.position = Vector3(0, 0, 4)
	world.add_child(hum)
	print("LEVEL ship_hum_4m %.1f dB" % await _peak_over(3.0))
	world.remove_child(hum)
	hum.free()
	# [bank, volume the game uses, distance if it plays in 3D]
	var uses: Array = [
		["step", -14.0, -1.0], ["step", -8.0, 5.0], ["pickup", -4.0, 2.0], ["drop", -4.0, 2.0],
		["monster_step", 2.0, 8.0], ["monster_growl", 4.0, 10.0], ["hit", -4.0, -1.0], ["launch", -8.0, -1.0],
		["round_start", -12.0, -1.0], ["click", -14.0, -1.0], ["switch", -12.0, -1.0], ["win", -10.0, -1.0], ["lose", -10.0, -1.0],
	]
	for use: Array in uses:
		await wait(0.4)
		if use[2] < 0.0:
			Sfx.play_2d(use[0], use[1])
		else:
			Sfx.play_3d(use[0], listener.position + Vector3(use[2], 0, 0), use[1])
		print("LEVEL %s at %.0f dB, %.0f m: %.1f dB" % [use[0], use[1], use[2], await _peak_over(1.0)])


# --- The shop, through the real menu, against a fake payment server -----------

func _mock_payment(status: String, order_id: String) -> void:
	var url := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("cloud_url="):
			url = arg.trim_prefix("cloud_url=")
	var request := HTTPRequest.new()
	add_child(request)
	request.request("%s/mock/payment/%s/%s" % [url, status, order_id], [], HTTPClient.METHOD_POST)
	await request.request_completed
	request.queue_free()


func _store() -> void:
	Store.poll_seconds = 0.2
	var main: Control = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await wait(0.2)
	check("the shop button shows outside Steam", main._shop_button.visible)
	check("prices are written the Indonesian way", Store.format_price(1500000) == "Rp 1.500.000" and Store.format_price(15000) == "Rp 15.000" and Store.format_price(500) == "Rp 500")

	main._shop_button.pressed.emit()
	check("the shop lists the products", await until(func() -> bool: return Store.products.size() == 3 and main._shop_list.get_child_count() == 3))
	check("the shop replaces the menu", main._shop.visible and not main._menu.visible)
	check("nothing is owned to begin with", Store.owned.is_empty())

	# Equipping something you haven't paid for does nothing.
	Store.equip("skin_medic")
	check("unpaid items can't be used", Store.equipped == "")

	# Buying: pressing the real Buy button.
	var buy_button := main._shop_list.get_child(0).get_child(1) as Button
	check("each item has a buy button", buy_button.text == "Buy with QRIS")
	buy_button.pressed.emit()
	check("a QR code appears", await until(func() -> bool: return Store.qr_texture != null and main._qr_frame.visible))
	check("the QR screen shows the price", main._qr_panel.visible and main._qr_label.text.contains("Rp 15.000"))
	var first_order: String = Store.order.order_id
	Store.buy("skin_pilot")
	check("a second order can't start during the first", Store.order.order_id == first_order)
	await wait(0.6)
	check("nothing unlocks while the payment is pending", Store.order.status == "pending" and Store.owned.is_empty())
	await _shot("10_qr")

	# The server says paid.
	await _mock_payment("paid", first_order)
	check("a paid order is noticed automatically", await until(func() -> bool: return Store.order.get("status", "") == "paid"))
	check("the QR code goes away after paying", not main._qr_frame.visible)
	check("the item becomes owned", await until(func() -> bool: return Store.owned.has("skin_engineer")))
	main._qr_panel.find_children("*", "Button", true, false)[0].pressed.emit()
	await wait(0.2)
	check("closing returns to the shop", main._shop.visible and not main._qr_panel.visible)

	# Using what you bought, and it being remembered.
	var use_button := main._shop_list.get_child(0).get_child(1) as Button
	check("an owned item offers Use", use_button.text == "Use")
	use_button.pressed.emit()
	check("using it equips it", Store.equipped == "skin_engineer")
	await get_tree().process_frame
	check("the standard look can be chosen again", (main._shop_list.get_child(0) as Button).text.contains("standard"))
	await _shot("11_shop")

	# Buying what you already own is refused by the server, with a clear message.
	Store.close_order()
	Store.buy("skin_engineer")
	check("buying twice is refused", await until(func() -> bool: return Store.order.get("status", "") == "error"))
	check("the refusal explains why", Store.order.message == "You already own this.")
	Store.close_order()

	# A QR code that expires unlocks nothing.
	Store.buy("skin_medic")
	await until(func() -> bool: return Store.order.get("status", "") == "pending")
	await _mock_payment("expired", Store.order.order_id)
	check("an expired QR code is reported", await until(func() -> bool: return Store.order.get("status", "") == "expired"))
	check("an expired QR code unlocks nothing", not Store.owned.has("skin_medic"))
	Store.close_order()

	# Losing what you owned (a refund) un-equips it.
	Store.buy("skin_pilot")
	await until(func() -> bool: return Store.order.get("status", "") == "pending")
	check("each item uses the server's price", Store.order.amount_idr == 25000)
	Store.close_order()
	Store.equipped = "skin_pilot"
	await Store.refresh()
	check("a look you don't own is removed", Store.equipped == "")
	main._on_shop_closed()
	check("back returns to the menu", main._menu.visible and not main._shop.visible)
	Store.equip("")


func _store_steam() -> void:
	var main: Control = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await wait(0.2)
	check("a Steam build is recognised", Store.is_steam_build())
	check("a Steam build hides the QRIS shop", not main._shop_button.visible)
	check("a Steam build refuses QRIS payments", not Store.payments_allowed())
	Store.buy("skin_engineer")
	await wait(1.0)
	check("a Steam build never starts a Midtrans order", Store.order.is_empty())


# --- A fifth player must be turned away with a clear reason -------------------

func _extra() -> void:
	Net.join("Extra", "127.0.0.1", port)
	var ended: bool = await until(func() -> bool: return not _ended_reason.is_empty())
	check("fifth player is refused", ended and _ended_reason == "That game is full.")


# --- The full four-player session ---------------------------------------------

func _scenario() -> void:
	# LOBBY
	# Bot1 wears a bought look; Bot2 tries a look that doesn't exist.
	if idx == 1:
		Store.equipped = "skin_medic"
	elif idx == 2:
		Store.equipped = "hacked_skin"
	if role == "host":
		check("host can open a game", Net.host("Host", port) == OK)
		Session.results_seconds = 2.0
		Session.monster_enabled = false
	else:
		check("client can start connecting", Net.join("Bot%d" % idx, "127.0.0.1", port) == OK)
	check("all four players are in the lobby", await until(func() -> bool: return Net.players.size() == 4))
	check("names arrive correctly", peer_named("Host") == 1 and peer_named("Bot3") != 0)
	if role == "host":
		print("LOBBY_FULL")
		check("host refused the fifth player", await until(func() -> bool: return Net.rejected_count >= 1, 30.0))
		await wait(0.5)
		check("crew is still four after the refusal", Net.players.size() == 4)
	await barrier("lobby", 4)

	# Only the host may start.
	if idx == 1:
		Session.request_start.rpc_id(1)
	await wait(0.5)
	check("a client cannot start the game", Session.phase == Session.Phase.LOBBY)
	await barrier("no_start", 4)

	# ROUND 1
	if role == "host":
		Session.start_run()
	check("round 1 starts for everyone", await until(func() -> bool: return Session.phase == Session.Phase.PLAYING))
	check("four players appear", await until(func() -> bool: return Session.players_root.get_child_count() == 4))
	var scrap_total := Session.layout.scrap_spawns.size()
	check("all scrap appears", await until(func() -> bool: return Session.scrap_root.get_child_count() == scrap_total))
	check("the monster appears", await until(func() -> bool: return Session.monster_root.get_child_count() == 1))
	check("everyone sees a player's bought look", Session.player_node(peer_named("Bot1")).model_name == Store.SKIN_MODELS.skin_medic)
	check("made-up looks fall back to the standard crew", Session.player_node(peer_named("Bot2")).model_name in Player.MODELS)
	print("FACILITY_R1 %d" % Session.layout.fingerprint())
	var first_fingerprint := Session.layout.fingerprint()
	await barrier("round1", 4)

	# Walking uses real physics, and walls must stop you.
	var start := me().position
	me().bot_move = Vector2(0, -1)
	var seen_walking := {}
	var others_walking: bool = await until(func() -> bool:
		for peer: int in Net.players:
			if peer != Net.my_id() and Session.player_node(peer).current_animation == "walk":
				seen_walking[peer] = true
		return seen_walking.size() == Net.players.size() - 1, 3.0)
	check("everyone sees other players' walk animation", others_walking)
	check("footsteps play while walking", await until(func() -> bool: return Sfx.play_count.get("step", 0) > 0, 3.0))
	await wait(3.0)
	me().bot_move = Vector2.ZERO
	check("walking moves the player", me().position.distance_to(start) > 1.0)
	check("the ship wall stops the player", me().position.z > -15.0)
	check("the floor holds the player up", me().position.y > -0.5 and me().position.y < 0.5)
	await barrier("walk", 4)

	# Everyone sees everyone else's position.
	me().teleport(Vector3(-3.0 + idx * 2.0, 0.1, -8.0))
	await barrier("spread", 4)
	var all_seen: bool = await until(func() -> bool:
		for peer: int in Net.players:
			var expected := -3.0 + (0 if peer == 1 else int(Net.players[peer].trim_prefix("Bot"))) * 2.0
			if absf(Session.player_node(peer).position.x - expected) > 0.3:
				return false
		return true)
	check("every player sees every other player move", all_seen)
	await barrier("seen", 4)

	# Picking up, with cheating attempts.
	var bot1 := peer_named("Bot1")
	var bot2 := peer_named("Bot2")
	var bot3 := peer_named("Bot3")
	if idx == 1:
		Session.request_pickup.rpc_id(1, 1)
		await wait(0.5)
		check("scrap out of reach cannot be taken", item(1).holder_id == 0)
		me().teleport(item(1).position)
		await wait(0.3)
		Session.request_pickup.rpc_id(1, 1)
	check("everyone sees who picked up the scrap", await until(func() -> bool: return item(1).holder_id == bot1))
	check("everyone hears the pick-up", await until(func() -> bool: return Sfx.play_count.get("pickup", 0) > 0, 3.0))
	await barrier("picked", 4)
	if idx == 2:
		me().teleport(item(1).position)
		await wait(0.3)
		Session.request_pickup.rpc_id(1, 1)
		await wait(0.5)
		check("you can't steal scrap from a player's hands", item(1).holder_id == bot1)
	await barrier("no_steal", 4)

	# Two players grab the same item at the same moment: exactly one may win.
	if idx == 2 or idx == 3:
		me().teleport(item(2).position)
		await wait(0.3)
	await barrier("race_ready", 4)
	if idx == 2 or idx == 3:
		Session.request_pickup.rpc_id(1, 2)
	await until(func() -> bool: return item(2).holder_id != 0)
	await wait(0.3)
	check("a contested item has exactly one winner", item(2).holder_id == bot2 or item(2).holder_id == bot3)
	await barrier("race", 4)
	if Net.my_id() == item(2).holder_id:
		Session.request_drop.rpc_id(1)
	check("dropped scrap is free again", await until(func() -> bool: return item(2).holder_id == 0))
	await barrier("dropped", 4)

	# Banking scrap in the ship until the quota is met.
	if idx == 1:
		var safety := 40
		me().teleport(Vector3(0, 0.1, -8.0))
		await wait(0.3)
		Session.request_drop.rpc_id(1)
		await until(func() -> bool: return item(1).holder_id == 0)
		await wait(1.2)
		while Session.in_ship_value < Session.quota and safety > 0:
			safety -= 1
			var next: Scrap = free_items_outside_ship()[0]
			me().teleport(next.position)
			await wait(0.2)
			Session.request_pickup.rpc_id(1, next.item_id)
			await until(func() -> bool: return next.holder_id == bot1, 3.0)
			me().teleport(Vector3(0, 0.1, -8.0))
			await wait(0.2)
			Session.request_drop.rpc_id(1)
			await until(func() -> bool: return next.holder_id == 0, 3.0)
			await wait(1.2)
		check("scrap dropped in the ship counts toward quota", Session.in_ship_value >= Session.quota)
	await barrier("banked", 4)
	await wait(1.2)
	check("everyone sees the ship's total", Session.in_ship_value >= Session.quota)

	# The monster hunts a real target on its own, and everyone sees the death.
	if idx == 2:
		var target: Scrap = free_items_outside_ship()[0]
		me().teleport(target.position)
		await wait(0.3)
		Session.request_pickup.rpc_id(1, target.item_id)
		await until(func() -> bool: return target.holder_id == bot2, 3.0)
	await barrier("bait", 4)
	var carried_id := 0
	for scrap: Scrap in Session.scrap_root.get_children():
		if scrap.holder_id == bot2:
			carried_id = scrap.item_id
	check("the victim is carrying scrap", carried_id != 0)
	if role == "host":
		var monster := Session.monster_root.get_child(0) as Monster
		var victim := Session.player_node(bot2)
		var cell := FacilityLayout.cell_at(victim.net_pos)
		monster.position = FacilityLayout.cell_center(cell)
		monster.grace = 0.0
		monster.enabled = true
	check("the monster kills the player, seen by everyone",
		await until(func() -> bool: return not Session.is_player_alive(bot2), 20.0))
	check("a dead player's scrap falls to the floor",
		await until(func() -> bool: return item(carried_id).holder_id == 0))
	var hunter := Session.monster_root.get_child(0) as Monster
	check("everyone sees the monster attack", await until(func() -> bool: return hunter.net_attacks >= 2, 3.0))
	check("everyone hears the monster attack", await until(func() -> bool: return Sfx.play_count.get("hit", 0) >= 2, 3.0))
	check("everyone hears the monster start hunting", await until(func() -> bool: return Sfx.play_count.get("monster_growl", 0) >= 1, 3.0))
	if idx != 2:
		check("the dead player's body plays the death animation", await until(func() -> bool: return Session.player_node(bot2).current_animation == "die", 3.0))
	if role == "host":
		var monster := Session.monster_root.get_child(0) as Monster
		monster.enabled = false
		monster.position = Vector3(20, 0, 20)
	check("everyone sees the monster in the same place",
		await until(func() -> bool:
			return Session.monster_root.get_child(0).position.distance_to(Vector3(20, 0, 20)) < 0.3))
	await barrier("killed", 4)

	# A player disconnects while holding something.
	if idx == 3:
		var target: Scrap = free_items_outside_ship()[0]
		me().teleport(target.position)
		await wait(0.3)
		Session.request_pickup.rpc_id(1, target.item_id)
		await until(func() -> bool: return target.holder_id == bot3, 3.0)
		await barrier("before_quit", 4)
		Net.leave()
		check("leaving returns the player to the menu", not Net.is_online())
		await wait(0.2)
		check("leaving clears the game world", Session.players_root.get_child_count() == 0 and Session.level == null)
		print("RESULT %s%d fails=%d" % [role, idx, fails])
		get_tree().quit(1 if fails > 0 else 0)
		return
	await barrier("before_quit", 4)
	check("remaining players see the crew shrink", await until(func() -> bool:
		return Net.players.size() == 3 and Session.players_root.get_child_count() == 3))
	check("the leaver's scrap is released", await until(func() -> bool: return Session.item_held_by(bot3) == null))
	await barrier("after_quit", 3)

	# The launch console: too far away first, then for real.
	if idx == 1:
		Session.request_launch.rpc_id(1)
		await wait(0.5)
		check("the ship can't be launched from across the room", Session.phase == Session.Phase.PLAYING)
		me().teleport(Rules.CONSOLE_POS + Vector3(0, 0.1, 1.5))
		await wait(0.3)
		Session.request_launch.rpc_id(1)
	if role == "host":
		me().teleport(Vector3(1, 0.1, -8.0))
	check("round 1 ends as cleared", await until(func() -> bool: return Session.last_results.get("cleared", false)))
	check("one round is recorded as cleared", Session.rounds_cleared == 1)

	# ROUND 2: the dead come back, and the facility is new.
	check("round 2 starts automatically", await until(func() -> bool: return Session.round_number == 2 and Session.phase == Session.Phase.PLAYING))
	check("dead players return", Session.is_player_alive(bot2))
	check("three players appear in round 2", await until(func() -> bool: return Session.players_root.get_child_count() == 3))
	check("round 2 is a different facility", Session.layout.fingerprint() != first_fingerprint)
	print("FACILITY_R2 %d" % Session.layout.fingerprint())
	await barrier("round2", 3)

	# Time runs out with nothing collected: game over, scores saved, back to lobby.
	if role == "host":
		Session.time_left = 1.0
	check("the timer ends the run", await until(func() -> bool: return Session.phase == Session.Phase.GAME_OVER))
	check("a failed round is not counted as cleared", Session.last_results.cleared == false and Session.rounds_cleared == 1)
	check("the crew returns to the lobby", await until(func() -> bool: return Session.phase == Session.Phase.LOBBY))
	check("the world is cleared after the run", Session.players_root.get_child_count() == 0 and Session.level == null)
	check("this player's run was saved to the database", await until(func() -> bool: return Cloud.submit_count >= 1) and Cloud.last_submit_ok)
	var rows: Array = await Cloud.fetch_leaderboard()
	check("the leaderboard can be read", rows.size() >= 1)
	Cloud._access_token = ""
	check("an expired login renews itself", await Cloud._ensure_signed_in() and Cloud._access_token == "token-refreshed")
	await barrier("over", 3)

	# The host leaves.
	if role == "host":
		await wait(0.5)
		Net.leave()
	else:
		check("clients are told the host left", await until(func() -> bool: return _ended_reason == "The host left the game."))
		check("clients return to the menu", not Net.is_online())
