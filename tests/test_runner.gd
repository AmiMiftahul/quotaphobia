extends Node
## Plays the real game over real network connections, driven by tests/run_tests.py.
## Roles: unit, host (idx 0), client (idx 1-3), extra (a fifth player who must be refused),
## late (a friend who joins once the ship is in orbit), and one per feature below.

var role := "unit"
var idx := 0
var port := 24600
var fails := 0
var _arrived := {}
var _released := {}
var _ended_reason := ""
var _shop_reply := ""
var _effects: Array[String] = []
var _tape_messages: Array[String] = []
var _tape_lists: Array = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var parts := arg.split("=")
		match parts[0]:
			"role": role = parts[1]
			"idx": idx = int(parts[1])
			"port": port = int(parts[1])
	Net.connection_ended.connect(func(reason: String) -> void: _ended_reason = reason)
	Session.shop_replied.connect(func(_ok: bool, message: String) -> void: _shop_reply = message)
	Session.effect_played.connect(func(kind: String, _pos: Vector3) -> void: _effects.append(kind))
	Session.tape_saved.connect(func(message: String) -> void: _tape_messages.append(message))
	Session.tape_list_received.connect(func(_item_id: int, entries: Array) -> void: _tape_lists.append(entries))
	# Site sizes are random; tests that rely on a room layout land on a medium site. The
	# days test and the 4-player session keep the real rotation.
	if role not in ["days", "host"]:
		Session.forced_site = "medium"
	match role:
		"unit": await _unit()
		"extra": await _extra()
		"ui": await _ui()
		"levels": await _levels()
		"store": await _store()
		"store_steam": await _store_steam()
		"entities": await _entities()
		"settings": await _settings()
		"video": await _video()
		"carry": await _carry()
		"perf": await _perf()
		"days": await _days()
		"gear": await _gear()
		"slots": await _slots()
		"tape": await _tape()
		"kit": await _kit()
		"beasts": await _beasts()
		"corpses": await _corpses()
		"tape_client": await _tape_client()
		"late": await _late()
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


func gear(kind: String) -> Scrap:
	for scrap: Scrap in Session.scrap_root.get_children():
		if scrap.kind == kind:
			return scrap
	return null


func free_items_outside_ship() -> Array[Scrap]:
	var items: Array[Scrap] = []
	for scrap: Scrap in Session.scrap_root.get_children():
		if scrap.holder_id == 0 and not Rules.in_ship(scrap.position) and not scrap.is_tool():
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
		var map: String = MapThemes.ORDER[seed_value % 4]
		var site: String = Rules.SITES[seed_value % 3]
		var layout := FacilityLayout.new(seed_value, Rules.site_grid(number, site), number, required, map, site)
		var again := FacilityLayout.new(seed_value, Rules.site_grid(number, site), number, required, map, site)
		deterministic = deterministic and layout.fingerprint() == again.fingerprint()
		for cell in layout.all_cells():
			connected_ok = connected_ok and not layout.path(FacilityLayout.ENTRY_CELL, cell).is_empty()
		var total := 0
		for spawn in layout.scrap_spawns:
			total += spawn.value
			ship_clear = ship_clear and not Rules.in_ship(spawn.pos)
		winnable = winnable and total >= required
	check("every room is reachable (200 facilities, every size)", connected_ok)
	check("same seed builds the same facility", deterministic)
	check("every round has enough scrap to meet quota", winnable)
	check("scrap never spawns inside the ship", ship_clear)
	var different := FacilityLayout.new(1, 6, 1, 100).fingerprint() != FacilityLayout.new(2, 6, 1, 100).fingerprint()
	check("different seeds build different facilities", different)
	check("the goal grows every level", Rules.quota(2, 4) > Rules.quota(1, 4))
	var always_reachable := true
	for level_no in range(1, 13):
		for crew in range(1, 5):
			var goal := Rules.quota(level_no, crew)
			var toughness := Rules.difficulty(level_no)
			var daily := 0
			for spawn in FacilityLayout.new(level_no * 7 + crew, Rules.grid_size(toughness), toughness, ceili(goal / 3.0)).scrap_spawns:
				daily += spawn.value
			always_reachable = always_reachable and daily * Rules.DAYS_PER_LEVEL >= goal
	check("four days always hold enough scrap to reach the goal", always_reachable)
	check("quota grows with crew size", Rules.quota(1, 4) > Rules.quota(1, 1))
	check("secret database keys are refused", Cloud._is_secret_key("sb_secret_abc"))
	check("ship boundary", Rules.in_ship(Vector3(0, 0, -10)) and not Rules.in_ship(Vector3(0, 0, 0)))

	# Art and sound: everything must load, and nothing may block a walkway.
	check("the game has its name", ProjectSettings.get_setting("application/config/name") == "Quotaphobia")
	var icon_path: String = ProjectSettings.get_setting("application/config/icon")
	var icon_image := Image.load_from_file(ProjectSettings.globalize_path(icon_path))
	check("the game has its icon", icon_image != null and icon_image.get_size() == Vector2i(256, 256))
	check("the icon's corners are see-through", icon_image.get_pixel(2, 2).a == 0.0)
	var old_name_found := false
	for code_file in ["res://scripts/main.gd", "res://project.godot"]:
		old_name_found = old_name_found or FileAccess.get_file_as_string(code_file).to_lower().contains("scrap shift")
	check("the old name is gone", not old_name_found)
	check("every sound file loads", Sfx.missing_streams().is_empty())
	var referenced := ""
	for path in ["res://scripts/map_themes.gd", "res://scripts/facility_layout.gd", "res://scripts/level.gd", "res://scripts/player.gd", "res://scripts/monster.gd"]:
		referenced += FileAccess.get_file_as_string(path)
	for folder in ["res://scripts/entities"]:
		for file_name in DirAccess.get_files_at(folder):
			if file_name.ends_with(".gd"):
				referenced += FileAccess.get_file_as_string(folder.path_join(file_name))
	var unused_models := []
	for file_name in DirAccess.get_files_at("res://assets/models/factory"):
		if file_name.ends_with(".glb") and not referenced.contains('"%s"' % file_name.get_basename()):
			unused_models.append(file_name)
	check("no unused models are shipped %s" % str(unused_models), unused_models.is_empty())
	var models_ok := true
	var names: Array = []
	names.append_array(FacilityLayout.SCRAP_MODELS.values())
	for model: String in names:
		models_ok = models_ok and not Assets.mesh_parts(Assets.FACTORY % model).is_empty()
	for map: String in MapThemes.ORDER:
		for model: String in MapThemes.get_theme(map).props:
			models_ok = models_ok and not Assets.mesh_parts(Assets.FACTORY % model).is_empty()
	for model: String in Player.MODELS:
		models_ok = models_ok and ResourceLoader.exists(Assets.CHARACTERS % model)
	check("every model loads", models_ok)
	var walkways_clear := true
	var scrap_clear := true
	for seed_value in 200:
		var layout := FacilityLayout.new(seed_value, 8, 4, 500, MapThemes.ORDER[seed_value % 4])
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

	# Maps: each must really differ, and be fair.
	var all_kinds := {}
	var door_totals := {}
	var far_enough := true
	var maps_ok := true
	for map: String in MapThemes.ORDER:
		var theme := MapThemes.get_theme(map)
		var has_hostile := false
		var has_friend := false
		for kind: String in theme.roster:
			all_kinds[kind] = true
			if Entity.INFO[kind].hostile:
				has_hostile = true
			else:
				has_friend = true
		maps_ok = maps_ok and has_hostile and has_friend
		door_totals[map] = 0
		for seed_value in 40:
			var layout := FacilityLayout.new(seed_value, 6, 3, 200, map)
			for cell in layout.all_cells():
				for dir: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
					if layout.has_cell(cell + dir) and layout.is_open(cell, cell + dir):
						door_totals[map] += 1
			for entity in layout.entity_spawns:
				if entity.kind in ["patch", "wisp"]:
					continue
				var rooms := layout.path(FacilityLayout.ENTRY_CELL, FacilityLayout.cell_at(entity.pos)).size()
				far_enough = far_enough and rooms >= FacilityLayout.MIN_ENTITY_ROOMS
	check("every map has threats and helpers", maps_ok)
	check("every entity kind appears on some map", all_kinds.size() == Entity.INFO.size())
	check("threats never start right next to the ship", far_enough)
	check("the Bio Lab is tighter than the Cryo Vault (%d vs %d doors)" % [door_totals.biolab, door_totals.cryo], door_totals.biolab < door_totals.cryo)
	var late := FacilityLayout.new(5, 8, 7, 500, "cryo")
	var early := FacilityLayout.new(5, 8, 1, 100, "cryo")
	check("threats grow with the rounds", late.entity_spawns.size() > early.entity_spawns.size())
	var sorted_order := MapThemes.order_for_run(123)
	var same_order := sorted_order == MapThemes.order_for_run(123)
	sorted_order.sort()
	var expected_order := MapThemes.ORDER.duplicate()
	expected_order.sort()
	check("each run visits all four maps, in the same order for everyone", same_order and sorted_order == expected_order)
	check("the Listener hears sprinting far, walking near, stillness never", Listener.heard_from(6.5) > Listener.heard_from(4.0) and Listener.heard_from(4.0) > 0.0 and Listener.heard_from(0.0) == 0.0)

	# Site sizes: every three days bring one of each, never the same size twice in a row.
	var rotation_ok := true
	for run_seed in 300:
		var previous := ""
		var first_three := {}
		for number in range(1, 13):
			var site := Rules.site_for_day(run_seed, number)
			rotation_ok = rotation_ok and site != previous and site == Rules.site_for_day(run_seed, number)
			previous = site
			if number <= 3:
				first_three[site] = true
		rotation_ok = rotation_ok and first_three.size() == 3
	check("every 3 days hold one site of each size, never the same size twice in a row", rotation_ok)
	var grids_ok := true
	for toughness in range(1, 20):
		var small := Rules.site_grid(toughness, "small")
		var large := Rules.site_grid(toughness, "large")
		grids_ok = grids_ok and small >= Rules.MIN_GRID and small < Rules.site_grid(toughness, "medium") and Rules.site_grid(toughness, "medium") < large and large <= Rules.MAX_GRID
	check("small sites are smaller than usual, and large ones bigger", grids_ok)
	check("bigger sites give the crew more time", Rules.round_seconds("small") < Rules.round_seconds("medium") and Rules.round_seconds("medium") < Rules.round_seconds("large"))

	# Big open halls.
	var halls_ok := true
	var walls_gone := true
	var rooms_walled := true
	var pillars_ok := true
	var hall_rooms := {"small": 0, "medium": 0, "large": 0}
	var scrap_count := {"small": 0, "medium": 0, "large": 0}
	var biggest_hall := 0
	for seed_value in 150:
		var site: String = Rules.SITES[seed_value % 3]
		var toughness := seed_value % 9 + 1
		var layout := FacilityLayout.new(seed_value, Rules.site_grid(toughness, site), toughness, Rules.quota(toughness, 4), MapThemes.ORDER[seed_value % 4], site)
		var whole := Rect2i(0, 0, layout.size, layout.size)
		var corners := 0
		for index in layout.halls.size():
			var block := layout.halls[index]
			biggest_hall = maxi(biggest_hall, block.get_area())
			halls_ok = halls_ok and whole.encloses(block) and not block.has_point(FacilityLayout.ENTRY_CELL) and block.get_area() >= 2
			for other_index in layout.halls.size():
				halls_ok = halls_ok and (other_index == index or not layout.halls[other_index].intersects(block))
			corners += (block.size.x - 1) * (block.size.y - 1)
			hall_rooms[site] += block.get_area()
		for cell in layout.all_cells():
			for dir: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var next: Vector2i = cell + dir
				if not layout.has_cell(next):
					continue
				var same_hall := layout.hall_at(cell) >= 0 and layout.hall_at(cell) == layout.hall_at(next)
				walls_gone = walls_gone and (not same_hall or (layout.is_merged(cell, next) and layout.is_open(cell, next)))
				rooms_walled = rooms_walled and (same_hall or not layout.is_merged(cell, next))
		pillars_ok = pillars_ok and layout.pillars.size() == corners
		for pillar in layout.pillars:
			var offset := pillar - FacilityLayout.cell_center(FacilityLayout.cell_at(pillar + Vector3(0.1, 0, 0.1)))
			pillars_ok = pillars_ok and absf(offset.x) - Level.PILLAR_WIDTH * 0.5 > Level.DOOR_WIDTH * 0.5 and absf(offset.z) - Level.PILLAR_WIDTH * 0.5 > Level.DOOR_WIDTH * 0.5
			for prop in layout.props:
				pillars_ok = pillars_ok and prop.pos.distance_to(pillar) > 3.0
		scrap_count[site] += layout.scrap_spawns.size()
	check("halls fit the facility, never overlap and never take the entry room", halls_ok)
	check("there are no walls inside a hall", walls_gone)
	check("ordinary rooms keep their walls", rooms_walled)
	check("pillars stand where hall rooms meet, clear of walkways and props", pillars_ok)
	check("large sites have far more hall space than small ones (%d vs %d)" % [hall_rooms.large, hall_rooms.small], hall_rooms.large > hall_rooms.small * 2 and hall_rooms.medium > hall_rooms.small)
	check("large sites can have halls of 6 rooms or more", biggest_hall >= 6)
	check("larger sites hold more scrap", scrap_count.large > scrap_count.medium and scrap_count.medium > scrap_count.small)
	var open_halls := {"cryo": 0, "biolab": 0}
	for seed_value in 40:
		for map: String in open_halls:
			open_halls[map] += FacilityLayout.new(seed_value, 7, 3, 200, map, "large").halls.size()
	check("the Cryo Vault has more open halls than the tight Bio Lab", open_halls.cryo > open_halls.biolab)

	# The shop and the gacha.
	var catalog_ok := true
	for kind: String in Tools.ORDER:
		var model := Tools.build_model(kind)
		catalog_ok = catalog_ok and Tools.CATALOG.has(kind) and Tools.CATALOG[kind].price > 0 and model.get_child_count() > 0
		model.free()
	for kind: String in Tools.FINDS:
		var model := Tools.build_model(kind)
		catalog_ok = catalog_ok and Tools.is_find(kind) and not kind in Tools.ORDER and model.get_child_count() > 0
		model.free()
	check("every piece of gear has a price, a description and a model", catalog_ok and Tools.CATALOG.size() == Tools.ORDER.size() + Tools.FINDS.size())
	check("found items are never sold or won", not Tools.FINDS.any(func(kind: String) -> bool: return kind in Tools.ORDER or kind in Tools.GACHA_GEAR or kind in Tools.GACHA_RARE))

	# Scrap kinds and things to find.
	var scrap_ok := FacilityLayout.SCRAP_INFO.size() == FacilityLayout.SCRAP_MODELS.size()
	for kind: String in FacilityLayout.SCRAP_MODELS:
		scrap_ok = scrap_ok and FacilityLayout.SCRAP_INFO.has(kind) and not Assets.mesh_parts(Assets.FACTORY % FacilityLayout.SCRAP_MODELS[kind]).is_empty()
	check("every kind of scrap has a model, a price range and a weight", scrap_ok and FacilityLayout.SCRAP_MODELS.size() >= 10)
	var kinds_seen := {}
	var finds_seen := {}
	var golden := 0
	var mimics_plain := true
	var finds_ok := true
	var light_total := 0
	var heavy_total := 0
	for seed_value in 200:
		var layout := FacilityLayout.new(seed_value, 7, 3, 300, MapThemes.ORDER[seed_value % 4], Rules.SITES[seed_value % 3])
		for spawn in layout.scrap_spawns:
			kinds_seen[spawn.kind] = true
			if spawn.kind == FacilityLayout.RARE_SCRAP:
				golden += 1
			var info: Dictionary = FacilityLayout.SCRAP_INFO[spawn.kind]
			finds_ok = finds_ok and spawn.weight >= info.weight[0] and spawn.weight <= info.weight[1]
		for entity in layout.entity_spawns:
			mimics_plain = mimics_plain and entity.get("scrap_kind", "") != FacilityLayout.RARE_SCRAP
		finds_ok = finds_ok and layout.finds.size() == 1 + layout.size / 2
		for find in layout.finds:
			finds_seen[find.kind] = true
			var offset: Vector3 = find.pos - FacilityLayout.cell_center(FacilityLayout.cell_at(find.pos))
			finds_ok = finds_ok and Tools.is_find(find.kind) and FacilityLayout.cell_at(find.pos) != FacilityLayout.ENTRY_CELL and layout.has_cell(FacilityLayout.cell_at(find.pos))
			finds_ok = finds_ok and not (absf(offset.x) > FacilityLayout.SCRAP_CLEARANCE and absf(offset.z) > FacilityLayout.SCRAP_CLEARANCE)
	check("every kind of scrap turns up (%d of %d)" % [kinds_seen.size(), FacilityLayout.SCRAP_MODELS.size()], kinds_seen.size() == FacilityLayout.SCRAP_MODELS.size())
	check("golden cogs are rare (%d found)" % golden, golden > 0 and golden < 400)
	check("a Mimic never pretends to be a golden cog", mimics_plain)
	check("every facility hides useful items, more in bigger ones, clear of props and the entry", finds_ok and finds_seen.size() == Tools.FINDS.size())

	# The new creatures stay beatable at full strength.
	var full_power := Rules.threat_power(99)
	check("a Gunner never kills a healthy player in one shot", roundi(Gunner.DAMAGE * full_power.damage) < Rules.PLAYER_MAX_HP)
	check("you can always walk away from a Ghost", Ghost.SPEED * full_power.speed < Player.WALK_SPEED)
	check("even wading through mud, you outpace a Mud Crawler", MudCrawler.SPEED * full_power.speed < Player.WALK_SPEED * MudCrawler.SLOW)
	check("a Gunner gives you time to duck out of sight", Gunner.AIM_SECONDS >= 1.0)
	check("a Gunner's dropped shotgun is a real prize", Gunner.SHELLS > 0 and Gunner.SHELLS <= Tools.CATALOG[Tools.SHOTGUN].charges)
	var pools_ok := true
	for kind: String in Tools.GACHA_GEAR + Tools.GACHA_RARE:
		pools_ok = pools_ok and Tools.is_gear(kind)
	check("gacha capsules only hold real gear", pools_ok)
	var gacha_chance := 0.0
	var gacha_worth := 0.0
	for row: Array in Rules.GACHA_TABLE:
		gacha_chance += row[0]
		gacha_worth += row[0] * _gacha_worth(row[1])
	check("the gacha odds add up to 100%%", is_equal_approx(gacha_chance, 1.0))
	check("a pull is worth a bit less than it costs ($%.2f of $%d)" % [gacha_worth, Rules.GACHA_PRICE], gacha_worth < Rules.GACHA_PRICE and gacha_worth > Rules.GACHA_PRICE * 0.85)
	check("the jackpot is rare and huge", Rules.GACHA_TABLE.back()[1] == "jackpot" and Rules.GACHA_TABLE.back()[0] <= 0.01 and Rules.GACHA_JACKPOT >= Rules.GACHA_PRICE * 20)
	check("the gacha and Scrap Slots both stand in the ship", Rules.in_ship(Rules.GACHA_POS) and Rules.in_ship(Session.gacha_tray()) and Rules.GACHA_POS.distance_to(Rules.GAMBLE_POS) > 5.0 and Rules.GACHA_POS.distance_to(Rules.TERMINAL_POS) > Rules.INTERACT_RANGE * 1.5)
	check("a scooter is faster than sprinting, but hunters can still hear it", Tools.SCOOTER_SPEED > Player.SPRINT_SPEED and Listener.heard_from(Tools.SCOOTER_SPEED) >= Listener.heard_from(Player.SPRINT_SPEED))
	check("a flashbang is quicker and wider than a stun grenade, but stuns for less", Tools.FLASH_FUSE < Tools.FUSE_SECONDS and Tools.FLASH_RADIUS > Tools.BLAST_RADIUS and Tools.FLASH_STUN < Tools.BLAST_STUN)
	check("a shotgun blast never kills a healthy crewmate outright", Tools.SHOTGUN_CREW_DAMAGE < Rules.PLAYER_MAX_HP)

	# Camcorder footage: the host only keeps real, small recordings.
	var jpeg := Image.create(32, 18, false, Image.FORMAT_RGB8).save_jpg_to_buffer(0.8)
	var at_zero := PackedFloat32Array([0.0])
	check("a photo is accepted", Session.valid_recording("photo", [jpeg], at_zero, 0.0))
	check("a clip is accepted", Session.valid_recording("clip", [jpeg, jpeg, jpeg], PackedFloat32Array([0.0, 0.1, 0.2]), 0.3))
	check("a photo is one picture", not Session.valid_recording("photo", [jpeg, jpeg], PackedFloat32Array([0.0, 0.0]), 0.0))
	check("anything that isn't a JPEG is refused", not Session.valid_recording("photo", [PackedByteArray([1, 2, 3, 4, 5])], at_zero, 0.0) and not Session.valid_recording("photo", ["text"], at_zero, 0.0))
	check("clips can't be longer than %d seconds" % Tools.CLIP_SECONDS, not Session.valid_recording("clip", [jpeg], at_zero, Tools.CLIP_SECONDS + 1.0))
	var many: Array = []
	var many_times := PackedFloat32Array()
	for frame in 80:
		many.append(jpeg)
		many_times.append(frame * 0.05)
	check("clips can't have too many frames", not Session.valid_recording("clip", many, many_times, 4.0))
	check("clip timings must be in order", not Session.valid_recording("clip", [jpeg, jpeg], PackedFloat32Array([0.2, 0.1]), 0.3))
	check("every frame needs a time", not Session.valid_recording("clip", [jpeg, jpeg], at_zero, 0.3))
	var huge := jpeg.duplicate()
	huge.resize(Tools.MAX_FRAME_BYTES + 1)
	check("oversized pictures are refused", not Session.valid_recording("photo", [huge], at_zero, 0.0))
	check("only photos and clips are kept", not Session.valid_recording("song", [jpeg], at_zero, 0.0))

	# Balance: hunters grow stronger each level, but never out of reach.
	var first := Rules.threat_power(1)
	check("level 1 hunters are at their base strength", first.speed == 1.0 and first.damage == 1.0 and first.stun == 1.0 and first.extra_hits == 0)
	var grows := true
	for level_no in range(2, 15):
		var before := Rules.threat_power(level_no - 1)
		var now := Rules.threat_power(level_no)
		grows = grows and now.speed >= before.speed and now.damage >= before.damage and now.stun <= before.stun and now.extra_hits >= before.extra_hits
	check("hunters never get weaker as levels go up", grows)
	check("hunters get stronger by level 4", Rules.threat_power(4).speed > 1.0 and Rules.threat_power(4).damage > 1.0 and Rules.threat_power(4).extra_hits == 1)
	var top := Rules.threat_power(99)
	check("hunters stop getting stronger after level 8", top == Rules.threat_power(Rules.MAX_THREAT_STEP + 1) and top != Rules.threat_power(Rules.MAX_THREAT_STEP))
	check("at full strength a sprint still outruns the Stalker", Monster.CHASE_SPEED * top.speed < Player.SPRINT_SPEED)
	check("at full strength a sprint still outruns a rushing Listener", Listener.RUSH_SPEED * top.speed < Player.SPRINT_SPEED)
	check("at full strength no single hit kills a healthy player", roundi(maxi(Rules.MONSTER_DAMAGE, maxi(Watcher.DAMAGE, Listener.DAMAGE)) * top.damage) < Rules.PLAYER_MAX_HP)
	check("at full strength stuns still last", top.stun >= 0.6)
	check("a shovel never stun-locks: each hit wears off before the next swing", Tools.SHOVEL_STUN < Tools.SHOVEL_COOLDOWN)

	# Scrap Slots: the odds add up, and on average a bet breaks even.
	var total_chance := 0.0
	var average := 0.0
	var biggest := 0.0
	for row: Array in Rules.GAMBLE_TABLE:
		total_chance += row[0]
		average += row[0] * row[1]
		biggest = maxf(biggest, row[1])
	check("the slot odds add up to 100%%", is_equal_approx(total_chance, 1.0))
	check("a slot bet breaks even on average (%.3f)" % average, absf(average - 1.0) < 0.01)
	check("the slots can bust or pay six times over", Rules.GAMBLE_TABLE[0][1] == 0.0 and biggest == 6.0)
	await wait(0.01)


# --- Each entity, and the way players are meant to beat it --------------------

func _fresh_round(map: String) -> void:
	Session.forced_maps = [map]
	Session._clear_entities()
	Session._begin_round(1)
	await until(func() -> bool: return me() != null and Session.phase == Session.Phase.PLAYING, 3.0)
	await get_tree().physics_frame
	_park_everything()
	me().bot_move = Vector2.ZERO


## Moves every entity far away, so each test sees only the one it wakes up.
func _park_everything() -> void:
	var index := 0
	for entity: Entity in Session.entity_root.get_children():
		index += 1
		entity.position = Vector3(1000.0 + index * 50.0, entity.position.y, 1000.0)


func _wake(entity: Entity, pos: Vector3) -> void:
	entity.position = Vector3(pos.x, entity.position.y, pos.z)
	entity.net_pos = entity.position
	entity._waypoints.clear()
	entity.grace = 0.0
	entity.enabled = true


## Two side-by-side rooms with a solid wall between them, or nothing if there are none.
func _find_wall() -> Array[Vector2i]:
	for cell in Session.layout.all_cells():
		var beside: Vector2i = cell + Vector2i(1, 0)
		if Session.layout.has_cell(beside) and not Session.layout.is_open(cell, beside):
			return [cell, beside]
	return []


func _hp() -> int:
	return Session.player_states[Net.my_id()].hp


func _face(forward_z: bool) -> void:
	me().rotation.y = PI if forward_z else 0.0


func _entities() -> void:
	check("host opens", Net.host("Host", port) == OK)
	Session.entities_enabled = false
	Session.forced_maps = ["foundry"]
	Session.start_run()
	await until(func() -> bool: return me() != null, 3.0)
	var room := FacilityLayout.cell_center(FacilityLayout.ENTRY_CELL)

	# THE WATCHER: frozen while watched, moves when not.
	await _fresh_round("cryo")
	var watcher := Session.entity_of_kind("watcher") as Watcher
	me().teleport(room + Vector3(0, 0.1, 3.0))
	_face(false)
	await wait(0.2)
	_wake(watcher, room + Vector3(0, 0, -3.0))
	# Hints appear one at a time, so clear any from the spawn moment.
	Session.hint_seconds = 0.0
	Session._hints_seen = {}
	Session._hint_check_timer = 0.0
	await wait(0.2)
	check("a nearby entity shows its hint", Session.hint_text.begins_with("THE WATCHER") and Session.hint_seconds > 0.0)
	var watched_at := watcher.position
	await wait(0.6)
	check("the Watcher can't move while you look at it", watcher.is_seen() and watcher.position == watched_at and watcher.net_state == 0)
	_face(true)
	await wait(0.3)
	check("the Watcher moves as soon as you look away", not watcher.is_seen() and watcher.net_state == Watcher.MOVING and watcher.position.distance_to(me().position) < watched_at.distance_to(me().position))
	var hp_before := _hp()
	check("the Watcher hurts you if you never look back", await until(func() -> bool: return _hp() < hp_before, 4.0))

	# Walls block sight: facing it through a wall doesn't count as watching.
	var near_room := Vector2i(-1, -1)
	var far_room := Vector2i(-1, -1)
	# A map with many doors may have no suitable wall, so build another until one does.
	for attempt in 20:
		await _fresh_round("cryo")
		var wall := _find_wall()
		if not wall.is_empty():
			near_room = wall[0]
			far_room = wall[1]
			break
	watcher = Session.entity_of_kind("watcher") as Watcher
	check("found a solid wall to test with", near_room.x >= 0)
	me().teleport(FacilityLayout.cell_center(near_room) + Vector3(2.5, 0.1, 0))
	me().rotation.y = -PI * 0.5
	await wait(0.2)
	watcher.position = FacilityLayout.cell_center(far_room) + Vector3(-2.5, 0, 0)
	check("you can't watch a Watcher through a wall", not watcher.is_seen())

	# THE LISTENER: stillness is safe, noise is not.
	await _fresh_round("reactor")
	var listener := Session.entity_of_kind("listener") as Listener
	me().teleport(room + Vector3(0, 0.1, 3.5))
	_face(false)
	await wait(0.2)
	_wake(listener, room + Vector3(0, 0, -2.5))
	await wait(0.8)
	check("the Listener can't hear you standing still", listener.net_state == 0)
	me().bot_move = Vector2(1, 0)
	check("the Listener hears you walking close by", await until(func() -> bool: return listener.net_state == Listener.RUSHING, 2.0))
	me().bot_move = Vector2.ZERO

	# Sprinting is heard from much further away, through the real speed check.
	await _fresh_round("reactor")
	listener = Session.entity_of_kind("listener") as Listener
	var far_cell := Vector2i.ZERO
	for cell in Session.layout.all_cells():
		var rooms := Session.layout.path(FacilityLayout.ENTRY_CELL, cell).size()
		var distance := FacilityLayout.cell_center(cell).distance_to(room)
		if rooms >= 2 and distance >= Listener.WALK_HEARD_FROM + 2.0 and distance < Listener.SPRINT_HEARD_FROM - 4.0:
			far_cell = cell
			break
	me().teleport(room + Vector3(0, 0.1, 0))
	await wait(0.1)
	_wake(listener, FacilityLayout.cell_center(far_cell))
	listener.grace = 0.0
	var walking_heard := false
	for tick in 20:
		await get_tree().physics_frame
		me().teleport(me().position + Vector3(4.0 / 60.0 * (1 if tick % 40 < 20 else -1), 0, 0))
		walking_heard = walking_heard or listener.net_state == Listener.RUSHING
	check("the Listener can't hear walking from far away", not walking_heard)
	var sprint_heard := false
	for tick in 20:
		await get_tree().physics_frame
		me().teleport(me().position - Vector3(6.5 / 60.0, 0, 0))
		sprint_heard = sprint_heard or listener.net_state == Listener.RUSHING
	check("the Listener hears sprinting from far away", sprint_heard)

	# A MIMIC: no prompt, one bite, then it's gone.
	await _fresh_round("foundry")
	var mimic := Session.entity_of_kind("mimic") as Mimic
	var mimics_before := Session.entity_root.get_child_count()
	_wake(mimic, room + Vector3(0, 0.25, -3.0))
	mimic.position.y = 0.25
	me().teleport(room + Vector3(0, 0.1, 0.0))
	_face(false)
	await wait(0.3)
	check("a Mimic never offers a pick-up prompt", not me().interact_prompt.begins_with("E: pick up"))
	check("a Mimic waits while you're not close", _hp() == Rules.PLAYER_MAX_HP)
	me().teleport(room + Vector3(0, 0.1, -2.0))
	check("a Mimic bites when you step close", await until(func() -> bool: return _hp() == Rules.PLAYER_MAX_HP - Mimic.DAMAGE, 2.0))
	check("a bite explains what happened", Session.hint_text.begins_with("A MIMIC"))
	check("a Mimic disappears after its bite", await until(func() -> bool: return Session.entity_root.get_child_count() == mimics_before - 1, 3.0))
	await wait(1.2)
	check("a Mimic only bites once", _hp() == Rules.PLAYER_MAX_HP - Mimic.DAMAGE)

	# A TOXIC VENT: harmless while closed, or from outside the cloud.
	await _fresh_round("biolab")
	var vent := Session.entity_of_kind("gas") as GasVent
	_wake(vent, room)
	vent._cycle = GasVent.ON_SECONDS + 0.1
	me().teleport(room + Vector3(0, 0.1, 0))
	await wait(0.8)
	check("a closed vent is safe to cross", vent.net_state == 0 and _hp() == Rules.PLAYER_MAX_HP)
	check("a vent reopens on its timer", await until(func() -> bool: return vent.net_state == GasVent.VENTING, 7.0))
	check("an open vent hurts you", await until(func() -> bool: return _hp() < Rules.PLAYER_MAX_HP, 2.0))
	await _fresh_round("biolab")
	vent = Session.entity_of_kind("gas") as GasVent
	_wake(vent, room)
	vent._cycle = 0.0
	me().teleport(room + Vector3(0, 0.1, GasVent.RADIUS + 0.5))
	await wait(1.5)
	check("standing outside the cloud is safe", vent.net_state == GasVent.VENTING and _hp() == Rules.PLAYER_MAX_HP)

	# PATCH: comes to you, heals you, runs out.
	await _fresh_round("biolab")
	var patch := Session.entity_of_kind("patch") as Patch
	me().teleport(room + Vector3(0, 0.1, 2.0))
	await wait(0.2)
	Session.damage_player(Net.my_id(), 30)
	await wait(0.1)
	_wake(patch, room + Vector3(0, 0, -3.0))
	check("Patch heals a hurt player", await until(func() -> bool: return _hp() > Rules.PLAYER_MAX_HP - 30, 6.0))
	check("healing stops at full health", await until(func() -> bool: return _hp() == Rules.PLAYER_MAX_HP, 6.0))
	var charge_when_full := patch.charge
	check("healing uses up charge", charge_when_full < Patch.STARTING_CHARGE)
	await wait(1.5)
	check("Patch saves its charge when nobody's hurt", patch.charge == charge_when_full)
	Session.damage_player(Net.my_id(), 30)
	patch.charge = 0
	await wait(1.5)
	check("an empty Patch can't heal", _hp() == Rules.PLAYER_MAX_HP - 30 and patch.net_state == Patch.EMPTY)

	# SENTINEL: stuns a real hunter, then recharges. Vents and Mimics don't set it off.
	await _fresh_round("foundry")
	var sentinel := Session.entity_of_kind("sentinel") as Sentinel
	var stalker := Session.entity_of_kind("stalker") as Monster
	me().teleport(FacilityLayout.cell_center(FacilityLayout.SHIP_CELL) + Vector3(0, 0.1, 0))
	_wake(sentinel, room + Vector3(1.8, 0, 1.8))
	var bait := Session.entity_of_kind("mimic") as Mimic
	bait.position = room + Vector3(-2, 0.25, 1.8)
	await wait(0.4)
	check("a Sentinel ignores Mimics", sentinel.net_state == Sentinel.READY)
	_wake(stalker, room + Vector3(-1.5, 0, -1.5))
	check("a Sentinel stuns a hunter in range", await until(func() -> bool: return stalker.net_stunned, 2.0))
	var stunned_at := stalker.position
	await wait(1.5)
	check("a stunned hunter can't move", stalker.net_stunned and stalker.position == stunned_at)
	check("a Sentinel must recharge after firing", sentinel.net_state == Sentinel.RECHARGING)
	check("a stun wears off", await until(func() -> bool: return not stalker.net_stunned, 4.0))

	# The Sentinel's stun can't reach through walls.
	var wall_room := Vector2i(-1, -1)
	var wall_beside := Vector2i(-1, -1)
	for attempt in 20:
		await _fresh_round("foundry")
		var wall := _find_wall()
		if not wall.is_empty():
			wall_room = wall[0]
			wall_beside = wall[1]
			break
	check("found a solid wall for the Sentinel", wall_room.x >= 0)
	sentinel = Session.entity_of_kind("sentinel") as Sentinel
	stalker = Session.entity_of_kind("stalker") as Monster
	stalker.enabled = false
	_wake(sentinel, FacilityLayout.cell_center(wall_room) + Vector3(2.5, 0, 0))
	sentinel.position = FacilityLayout.cell_center(wall_room) + Vector3(2.5, 0, 0)
	stalker.position = FacilityLayout.cell_center(wall_beside) + Vector3(-2.5, 0, 0)
	await wait(0.4)
	check("a Sentinel can't stun through a wall", not stalker.net_stunned and sentinel.net_state == Sentinel.READY)

	# WISP: stays with you, leads toward scrap, warns of hunters.
	await _fresh_round("reactor")
	var wisp := Session.entity_of_kind("wisp") as Wisp
	me().teleport(room + Vector3(0, 0.1, 0))
	_wake(wisp, room + Vector3(4, 0, 0))
	await wait(1.5)
	check("a Wisp stays close to you", wisp.position.distance_to(me().position) < 6.0)
	check("a Wisp is calm with no hunters near", wisp.net_state == 0)
	var direction: Vector3 = wisp._direction_to_scrap(me())
	check("a Wisp points somewhere useful", direction.length() > 0.5)
	var lurker := Session.entity_of_kind("listener") as Listener
	lurker.position = wisp.position + Vector3(4, 0, 0)
	check("a Wisp warns when a hunter is near", await until(func() -> bool: return wisp.net_state == Wisp.WARNING, 2.0))
	lurker.position = Vector3(1000, 0, 1000)
	check("a Wisp calms down when the hunter leaves", await until(func() -> bool: return wisp.net_state == 0, 2.0))

	# The ship is always safe, whatever is standing at the door.
	await _fresh_round("foundry")
	stalker = Session.entity_of_kind("stalker") as Monster
	me().teleport(Vector3(0, 0.1, -6.0))
	_wake(stalker, Vector3(0, 0, -5.5))
	await wait(1.0)
	check("nothing can hurt you inside the ship", _hp() == Rules.PLAYER_MAX_HP)

	# The cold map's rule really slows stamina recovery.
	await _fresh_round("cryo")
	me().teleport(Vector3(0, 0.1, -9.0))
	me().stamina = 0.0
	await wait(1.0)
	var cold_gain := me().stamina
	await _fresh_round("foundry")
	me().teleport(Vector3(0, 0.1, -9.0))
	me().stamina = 0.0
	await wait(1.0)
	check("the Cryo Vault slows stamina recovery (%.2f vs %.2f)" % [cold_gain, me().stamina], cold_gain < me().stamina * 0.75)

	# Scrap on the Reactor is worth more for the risk.
	var plain_total := 0
	var rich_total := 0
	for spawn in FacilityLayout.new(9, 6, 2, 0, "foundry").scrap_spawns:
		plain_total += spawn.value
	for spawn in FacilityLayout.new(9, 6, 2, 0, "reactor").scrap_spawns:
		rich_total += spawn.value
	check("the Reactor's scrap is worth more", rich_total > plain_total)
	Net.leave()


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
	Net.listen_port = port
	var main: Control = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await _shot("1_menu")
	check("the menu shows at launch", main._menu.visible and not main._lobby.visible)
	check("the ship shows behind the menu", main._backdrop != null and main._backdrop.is_inside_tree() and main._backdrop._camera.current)
	var menu_screen := get_viewport().get_visible_rect()
	var buttons_fit := true
	for button: Button in main._menu.find_children("*", "Button", true, false):
		if button.is_visible_in_tree():
			buttons_fit = buttons_fit and menu_screen.encloses(button.get_global_rect())
	check("every menu button is on screen", buttons_fit)
	check("the menu starts with Play selected, for controllers", get_viewport().gui_get_focus_owner() == main._play_button)
	_menu_button(main, "Credits").pressed.emit()
	await wait(0.2)
	check("Credits show the Godot license notice", main._menu_credits.visible and not main._menu_main.visible and main._credits_text().contains("Permission is hereby granted"))
	await _shot("1b_credits")
	await _press(KEY_ESCAPE)
	check("Esc goes back to the main menu", main._menu_main.visible and not main._menu_credits.visible)
	_menu_button(main, "Join a friend").pressed.emit()
	await wait(0.2)
	check("Join a friend opens the address box", main._menu_join.visible and main._address_edit.is_visible_in_tree())
	await _shot("1c_join")
	_menu_button(main, "Back").pressed.emit()
	await wait(0.1)
	check("Back returns to the main menu", main._menu_main.visible and not main._menu_join.visible)

	main._name_edit.text = "  A very long player name indeed  "
	Session.entities_enabled = false
	Session.forced_maps = ["foundry"]
	Session.days_per_level = 1
	Session.results_seconds = 3.0
	main._play_button.pressed.emit()
	check("Play puts the crew in the ship, in orbit", await until(func() -> bool: return Session.phase == Session.Phase.ORBIT and me() != null, 3.0))
	await wait(0.3)
	check("long names are trimmed", Net.players[1].length() <= 16 and not Net.players[1].begins_with(" "))
	check("the ship is the lobby: the game shows, not a menu", main._hud.visible and not main._lobby.visible and not main._menu.visible)
	check("the menu's backdrop is gone once you're playing", main._backdrop == null)
	check("the crew list shows in orbit", main._crew_panel.visible and main._crew_label.text.begins_with("CREW 1 / 4"))
	check("the HUD says the ship is in orbit, with the crew's credits", main._top_label.text.begins_with("IN ORBIT") and main._top_label.text.contains("Credits $60"))
	check("the banner says where the ship lands next", main._banner_label.visible and main._banner_label.text.contains("Rust Foundry"))
	check("orbit has no facility and no creatures", Session.layout == null and Session.level != null and Session.entity_root.get_child_count() == 0)
	check("mouse is captured in the ship", Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	var screen := get_viewport().get_visible_rect()
	check("the crew list fits on screen", screen.encloses(main._crew_panel.get_global_rect()))
	check("the orbit HUD text fits on screen", screen.encloses(main._top_label.get_global_rect()))
	me().rotation.y = PI
	me().teleport(Vector3(0, 0.1, -11.0))
	await _shot("2_orbit_window")
	me().rotation.y = 0.0
	me().teleport(Vector3(0, 0.1, -7.0))
	await _shot("2a_orbit")

	# The terminal, with the real E key and the real buttons.
	me().rotation.y = -PI * 0.5
	me().teleport(Rules.TERMINAL_POS + Vector3(-1.4, 0.1, 0))
	await wait(0.3)
	check("the terminal prompt shows", me().interact_prompt.begins_with("E: use the terminal"))
	await _shot("2b_terminal_in_ship")
	await _press(KEY_E)
	check("E opens the terminal and frees the mouse", main._terminal.visible and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	check("the terminal lists all the gear", main._terminal_buttons.size() == Tools.ORDER.size() and main._terminal_credits.text.contains("$60"))
	check("the terminal fits on screen", get_viewport().get_visible_rect().encloses(main._terminal.get_global_rect()))
	check("gear the crew can't afford can't be bought", main._terminal_buttons[Tools.ZAP_GUN].disabled and not main._terminal_buttons[Tools.SHOVEL].disabled)
	check("the terminal fits on screen", screen.encloses(main._terminal.get_global_rect()))
	await _shot("2c_terminal")
	main._terminal_buttons[Tools.SHOVEL].pressed.emit()
	check("buying a shovel spends the crew's credits", await until(func() -> bool: return Session.credits == 30, 2.0))
	check("the terminal confirms the purchase", main._terminal_message.text.contains("bought"))
	check("the terminal shows what's left", main._terminal_credits.text.contains("$30"))
	var shovel := gear(Tools.SHOVEL)
	check("the shovel appears in the ship", shovel != null and Rules.in_ship(shovel.position))
	await _press(KEY_ESCAPE)
	check("Esc closes the terminal without pausing", not main._terminal.visible and not main._pause.visible and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	me().rotation.y = 0.0
	me().teleport(Vector3(shovel.position.x, 0.1, shovel.position.z + 1.5))
	await wait(0.3)
	check("gear shows a pick-up prompt", me().interact_prompt.begins_with("E: pick up Shovel"))
	await _press(KEY_E)
	check("gear can be picked up in orbit", await until(func() -> bool: return shovel.holder_id == 1, 2.0))
	check("held gear says how to use it", await until(func() -> bool: return me().interact_prompt.begins_with("Left click: swing the shovel"), 1.0))
	await _shot("2d_holding_shovel")

	# Pulling the lever lands the ship.
	me().rotation.y = 0.0
	me().teleport(Rules.CONSOLE_POS + Vector3(0, 0.1, 1.6))
	await wait(0.3)
	check("the console offers to land", me().interact_prompt.begins_with("E: pull the lever and land on Rust Foundry"))
	await _press(KEY_E)
	check("pulling the lever lands the ship", await until(func() -> bool: return Session.phase == Session.Phase.PLAYING, 3.0))
	check("the crew lands holding their gear", is_instance_valid(shovel) and shovel.holder_id == 1)
	await wait(0.2)
	check("the HUD shows the facility, not orbit", not main._crew_panel.visible and main._top_label.text.begins_with("Rust Foundry"))
	check("mouse is captured for looking around", Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	me().teleport(Vector3(0, 0.1, -9.0))
	await wait(0.2)
	await _press(KEY_G)
	check("gear can be put down in the ship", await until(func() -> bool: return shovel.holder_id == 0, 2.0))
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
	var monster := Session.entity_of_kind("stalker") as Monster
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
	Settings.set_value("master", 0.5)
	check("volume setting changes the output", is_equal_approx(db_to_linear(AudioServer.get_bus_volume_db(0)), 0.5))
	Settings.set_value("master", 0.8)

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

	await _ui_phone(main)
	await _ui_backpack(main)
	await _ui_camcorder(main)
	await _ui_hall()
	await _ui_kit(main)
	await _ui_settings(main)

	# A real left click swings the shovel at the Stalker.
	me().rotation.y = 0.0
	me().teleport(Vector3(shovel.position.x, 0.1, shovel.position.z + 1.5))
	await wait(0.3)
	await _press(KEY_E)
	await until(func() -> bool: return shovel.holder_id == 1, 2.0)
	var stalker := Session.entity_of_kind("stalker")
	var hits_before := stalker.hits_left()
	stalker.position = Vector3(me().position.x, 0.0, me().position.z - 1.6)
	stalker.net_pos = stalker.position
	stalker.rotation.y = PI
	await wait(0.2)
	await _click(MOUSE_BUTTON_LEFT)
	check("left click swings the shovel and hits the Stalker", await until(func() -> bool: return stalker.hits_left() == hits_before - 1 and stalker.net_stunned, 2.0))
	check("the swing and the hit are heard", Sfx.play_count.get("swing", 0) >= 1 and Sfx.play_count.get("bonk", 0) >= 1)
	await _shot("9_shovel_hit")
	stalker.position = Vector3(40, 0, 40)
	stalker.net_pos = stalker.position
	me().teleport(Vector3(0, 0.1, -9.0))
	await wait(0.2)
	await _press(KEY_G)
	await until(func() -> bool: return shovel.holder_id == 0, 2.0)

	# Scrap Slots, with the real E key.
	var chip: Scrap = free_items_outside_ship()[0]
	me().rotation.y = 0.0
	me().teleport(Vector3(chip.position.x, 0.1, chip.position.z + 1.5))
	await wait(0.3)
	await _press(KEY_E)
	await until(func() -> bool: return chip.holder_id == 1, 2.0)
	var chip_value := chip.value
	me().rotation.y = PI * 0.5
	me().teleport(Vector3(Rules.GAMBLE_POS.x + 1.9, 0.1, Rules.GAMBLE_POS.z))
	await wait(0.3)
	check("Scrap Slots offers a bet", me().interact_prompt.begins_with("E: gamble"))
	await _shot("10_slots")
	Session.gamble_rig = 3
	await _press(KEY_E)
	check("E feeds the scrap to the machine", await until(func() -> bool: return chip.locked, 2.0))
	await wait(0.6)
	await _shot("10b_slots_spinning")
	check("the machine pays out on screen", await until(func() -> bool: return not chip.locked, 5.0) and chip.value == chip_value * 3)
	await wait(0.2)
	await _shot("10c_slots_jackpot")
	Session.gamble_rig = -1

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

	check("the results show the crew's credits", main._results_label.text.contains("Credits: $%d" % Session.last_results.credits))

	# The random scrap may have met the quota. If so the ship goes back to orbit with
	# the shovel, and the timer running out with nothing in the ship ends the run instead.
	if Session.last_results.cleared:
		check("the results say the gear was kept", main._results_label.text.contains("Gear kept in the ship: 1"))
		check("after a good day the ship returns to orbit", await until(func() -> bool: return Session.phase == Session.Phase.ORBIT, 8.0))
		check("gear left in the ship is still there", gear(Tools.SHOVEL) != null)
		check("banked scrap became credits", Session.credits == 30 + Session.last_results.collected)
		await wait(0.3)
		me().rotation.y = 0.0
		me().teleport(Rules.CONSOLE_POS + Vector3(0, 0.1, 1.6))
		await wait(0.3)
		await _press(KEY_E)
		check("the lever lands the ship again", await until(func() -> bool: return Session.round_number == 2 and Session.phase == Session.Phase.PLAYING, 3.0))
		Session.time_left = 0.5

	# End of the run: a new one starts in orbit, from scratch.
	check("the crew is back in orbit for a new run", await until(func() -> bool: return Session.phase == Session.Phase.ORBIT and Session.round_number == 0, 10.0))
	check("a new run has fresh credits and no gear", Session.credits == Rules.STARTING_CREDITS and Session.gear_count() == 0)
	await wait(0.3)
	check("the crew list shows after the run", main._crew_panel.visible)

	# Every map: how it looks, and its frame rate at the largest size (a large site, 10 x 10 rooms).
	Session.forced_site = "large"
	for map: String in MapThemes.ORDER:
		Session.forced_maps = [map]
		Session._clear_entities()
		Session.level_number = 3 # Tough enough for the largest facility.
		Session._begin_round(4)
		Session.entities_enabled = true
		await until(func() -> bool: return me() != null, 3.0)
		for entity: Entity in Session.entity_root.get_children():
			entity.grace = 60.0
		await _shot("map_%s_banner" % map)
		var screen_rect := get_viewport().get_visible_rect()
		check("%s banner fits on screen" % map, main._banner_label.visible and screen_rect.encloses(main._banner_label.get_global_rect()))
		me().teleport(FacilityLayout.cell_center(Vector2i(3, 3)) + Vector3(0, 0.1, 0))
		await wait(3.0)
		var slowest := 10000.0
		for tick in 120:
			await get_tree().process_frame
			slowest = minf(slowest, 1.0 / maxf(get_process_delta_time(), 0.0001))
		var draws := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		print("PERF %s: average %d fps, slowest frame %d fps, %d draw calls" % [map, Engine.get_frames_per_second(), slowest, draws])
		check("%s holds at least 30 fps" % map, Engine.get_frames_per_second() >= 30)
		check("%s has residents" % map, Session.layout.entity_spawns.size() > 0)
		await _shot("map_%s" % map)
		# Each entity kind on this map, up close.
		var shown := {}
		for entity: Entity in Session.entity_root.get_children():
			if shown.has(entity.kind):
				continue
			shown[entity.kind] = true
			# Everything else moves out of the picture.
			var home: Vector3 = Vector3.ZERO
			for spawn: Dictionary in Session.layout.entity_spawns:
				if spawn.kind == entity.kind:
					home = spawn.pos
					break
			_park_everything()
			var cell := FacilityLayout.cell_at(home)
			var spot := FacilityLayout.cell_center(cell)
			entity.position = Vector3(spot.x, entity.position.y, spot.z - 2.0)
			entity.net_pos = entity.position
			entity.rotation.y = PI
			entity.net_yaw = PI
			if entity is GasVent:
				entity.net_state = GasVent.VENTING
			Session.hint_seconds = 0.0
			Session.banner_seconds = 0.0
			me().rotation.y = 0.0
			me().teleport(spot + Vector3(0, 0.1, 3.0))
			await _shot("entity_%s_%s" % [map, entity.kind])
	Session.forced_site = "medium"
	Session.entities_enabled = false
	Net.leave()
	await wait(0.2)
	check("leaving returns to the menu", main._menu.visible and main._backdrop != null)

	# One click from the menu back into the ship.
	Session.forced_maps = ["cryo"]
	main._play_button.pressed.emit()
	check("Play goes straight into the ship", await until(func() -> bool: return Session.phase == Session.Phase.ORBIT and me() != null, 3.0))
	check("Play shows the game, not a menu", main._hud.visible and not main._menu.visible and not main._lobby.visible)
	check("the next stop follows the run's maps", Session.next_map == "cryo")
	Net.leave()
	await wait(0.2)
	check("leaving returns to the menu", main._menu.visible and main._backdrop != null)


func _menu_button(main: Control, text: String) -> Button:
	for button: Button in main._menu.find_children("*", "Button", true, false):
		if button.text == text and button.is_visible_in_tree():
			return button
	return null


func _pad_button(button: JoyButton) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventJoypadButton.new()
		event.button_index = button
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().process_frame
		await get_tree().process_frame


func _pad_stick(axis: JoyAxis, amount: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.axis = axis
	event.axis_value = amount
	Input.parse_input_event(event)
	await get_tree().process_frame


func _click(button: MouseButton) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().process_frame
		await get_tree().process_frame


## The phone, using the real keys, and real saved files.
func _ui_phone(main: Control) -> void:
	var phone: PhoneCamera = me().phone
	check("the phone starts put away", not phone.is_up and not main._phone_panel.visible)
	var before_click := me().net_flashes
	await _click(MOUSE_BUTTON_LEFT)
	await _press(KEY_R)
	await wait(0.2)
	check("photo and record do nothing while it's put away", me().net_flashes == before_click and not phone.is_recording)
	await _press(KEY_P)
	await wait(0.5)
	check("P raises the phone", phone.is_up and main._phone_panel.visible)
	var hud_screen := get_viewport().get_visible_rect()
	check("the phone fits on screen", hud_screen.encloses(main._phone_panel.get_global_rect()))
	check("the phone shows how to use it", main._phone_status.text.contains("Left click") and main._phone_status.text.contains("R: record 5 s"))
	await _shot("phone_up")

	# A real photo, taken facing into the dark so the flash has something to do.
	var standing_at := me().position
	var facing := me().rotation.y
	me().teleport(FacilityLayout.cell_center(Session.layout.monster_spawn) + Vector3(0, 0.1, 0))
	await wait(0.3)
	await RenderingServer.frame_post_draw
	var unlit := _average_brightness(phone.texture().get_image())
	await _click(MOUSE_BUTTON_LEFT)
	check("left click takes a photo", await until(func() -> bool: return phone.last_saved_path.ends_with(".png"), 3.0))
	var photo := Image.load_from_file(phone.last_saved_path)
	var lit := _average_brightness(photo)
	check("the flash really brightens the photo (%.3f to %.3f)" % [unlit, lit], lit > unlit * 1.1)
	me().teleport(standing_at)
	me().rotation.y = facing
	check("the photo is a real 1280 x 720 image", photo != null and photo.get_size() == PhoneCamera.PHOTO_SIZE)
	var colors := {}
	for sample in 200:
		colors[photo.get_pixel(sample * 6 % photo.get_width(), sample * 3 % photo.get_height())] = true
	check("the photo isn't a blank picture (%d colours sampled)" % colors.size(), colors.size() > 10)
	print("PHOTO %s" % phone.last_saved_path)
	check("the flash fires", me().net_flashes == before_click + 1)
	check("saving is confirmed", main._phone_toast.visible or await until(func() -> bool: return main._phone_toast.visible, 1.0))
	await wait(0.2)
	check("the HUD says the photo was saved", main._phone_toast.text == "Photo saved")

	# Two photos in one second never overwrite each other.
	var first_photo := phone.last_saved_path
	await _click(MOUSE_BUTTON_LEFT)
	await until(func() -> bool: return phone.last_saved_path != first_photo, 3.0)
	check("a second photo gets its own file", phone.last_saved_path != first_photo and FileAccess.file_exists(first_photo) and FileAccess.file_exists(phone.last_saved_path))

	# A real 5-second recording while moving, so the frames differ.
	var fps_samples: Array[int] = []
	await _press(KEY_R)
	check("R starts recording", phone.is_recording and me().net_recording)
	var flashes_during := me().net_flashes
	await wait(0.3)
	await _click(MOUSE_BUTTON_LEFT)
	check("no photos during a recording", me().net_flashes == flashes_during)
	await _shot("phone_recording")
	check("the screen shows it's recording", main._phone_status.text.begins_with("REC"))
	me().rotation.y = 0.0
	var started_at := Time.get_ticks_msec()
	while phone.is_recording and Time.get_ticks_msec() - started_at < 8000:
		me().rotate_y(0.01)
		fps_samples.append(Engine.get_frames_per_second())
		await get_tree().process_frame
	check("recording stops by itself", not phone.is_recording and not me().net_recording)
	check("the recording lasted 5 seconds", is_equal_approx(phone.record_elapsed, 5.0))
	check("a video file was saved", phone.last_saved_path.ends_with(".mov") and FileAccess.file_exists(phone.last_saved_path))
	check("about 15 frames a second were captured (%d)" % phone.frames_captured, phone.frames_captured >= 60 and phone.frames_captured <= 78)
	var slowest_fps: int = fps_samples.min() if not fps_samples.is_empty() else 0
	print("PHONE_FPS slowest %d while recording" % slowest_fps)
	check("the game stays smooth while recording (slowest %d fps)" % slowest_fps, slowest_fps >= 30)
	print("VIDEO %s" % phone.last_saved_path)

	# Putting the phone away mid-clip keeps what was filmed; a tiny clip isn't kept.
	var full_clip := phone.last_saved_path
	await _press(KEY_R)
	await wait(1.5)
	await _press(KEY_P)
	check("putting the phone away stops recording", not phone.is_up and not phone.is_recording)
	check("the part already filmed is saved", phone.last_saved_path != full_clip and phone.last_saved_path.ends_with(".mov"))
	print("SHORT_VIDEO %s" % phone.last_saved_path)
	var short_clip := phone.last_saved_path
	await _press(KEY_P)
	await _press(KEY_R)
	await _press(KEY_P)
	check("an accidental tap isn't saved", phone.last_saved_path == short_clip and phone.message == "Too short to keep")
	check("the phone hides when put away", not main._phone_panel.visible or await until(func() -> bool: return not main._phone_panel.visible, 1.0))
	# Without a folder chosen for the test, clean up what it filmed.
	var folder := PhoneCamera.capture_folder()
	if folder.ends_with("test_captures"):
		for file_name in DirAccess.get_files_at(folder):
			DirAccess.remove_absolute(folder.path_join(file_name))
		DirAccess.remove_absolute(folder)


## The camcorder, with real keys and real pictures.
func _ui_camcorder(main: Control) -> void:
	var hand_before := Session.item_held_by(Net.my_id())
	var camcorder := _give(Tools.CAMCORDER)
	var cam := me().camcorder
	await wait(0.2)
	check("the prompt shows the camcorder's buttons", me().interact_prompt.contains("Left click: photo") and me().interact_prompt.contains("R: record a clip") and me().interact_prompt.contains("V: watch (0 saved)"))
	await _click(MOUSE_BUTTON_LEFT)
	check("left click takes a camcorder photo", await until(func() -> bool: return camcorder.recordings == 1, 3.0))
	check("the HUD confirms it", await until(func() -> bool: return main._phone_toast.visible and main._phone_toast.text.begins_with("Photo saved on the camcorder"), 2.0))
	await _press(KEY_R)
	check("R starts filming, and its screen shows what it sees", cam.is_recording and await until(func() -> bool: return main._cam_panel.visible and main._cam_status.text.begins_with("REC"), 1.0))
	await wait(0.5)
	await _shot("camcorder_recording")
	var started_at := Time.get_ticks_msec()
	while cam.is_recording and Time.get_ticks_msec() - started_at < 8000:
		me().rotate_y(0.02)
		await get_tree().process_frame
	check("a clip stops by itself after 5 seconds", not cam.is_recording and is_equal_approx(cam.record_elapsed, Tools.CLIP_SECONDS))
	check("the clip is saved on the camcorder", await until(func() -> bool: return camcorder.recordings == 2, 5.0))
	await _press(KEY_V)
	check("V plays it back", await until(func() -> bool: return main._cam_panel.visible and main._cam_view.texture != null and main._cam_status.text.begins_with("PLAY"), 5.0))
	var first_look: Image = main._cam_view.texture.get_image()
	check("playback is a real picture (%.3f bright)" % _average_brightness(first_look), first_look.get_size() == Tools.CLIP_SIZE and _average_brightness(first_look) > 0.02)
	check("the camcorder screen fits on screen", get_viewport().get_visible_rect().encloses(main._cam_panel.get_global_rect()))
	check("the camcorder screen doesn't cover the prompt", not main._cam_panel.get_global_rect().intersects(Rect2(main._prompt_label.get_global_rect().get_center() - Vector2(main._prompt_label.get_theme_font("font").get_multiline_string_size(main._prompt_label.text, HORIZONTAL_ALIGNMENT_CENTER, -1, 20).x * 0.5, 0), Vector2(main._prompt_label.get_theme_font("font").get_multiline_string_size(main._prompt_label.text, HORIZONTAL_ALIGNMENT_CENTER, -1, 20).x, 1))))
	await wait(1.0)
	await _shot("camcorder_playback")
	check("the clip moves as it plays", main._cam_view.texture.get_image().get_data() != first_look.get_data())
	await _click(MOUSE_BUTTON_LEFT)
	check("left click steps to the photo", await until(func() -> bool: return main._cam_status.text.begins_with("PHOTO  1 / 2"), 3.0))
	var photo: Image = main._cam_view.texture.get_image()
	var colors := {}
	for sample in 200:
		colors[photo.get_pixel(sample * 6 % photo.get_width(), sample * 3 % photo.get_height())] = true
	check("the photo is a real %d x %d picture (%d colours sampled)" % [Tools.SNAPSHOT_SIZE.x, Tools.SNAPSHOT_SIZE.y, colors.size()], photo.get_size() == Tools.SNAPSHOT_SIZE and colors.size() > 10)
	await _shot("camcorder_photo")
	await _press(KEY_V)
	check("V again stops watching", not cam.viewing and await until(func() -> bool: return not main._cam_panel.visible, 1.0))
	Session.scrap_root.remove_child(camcorder)
	camcorder.queue_free()
	for other in Session.items_held_by(Net.my_id()):
		other.stowed = other != hand_before


## The scooter and the gacha, with real clicks and keys.
func _ui_kit(main: Control) -> void:
	var hand_before := Session.item_held_by(Net.my_id())
	var board := _give(Tools.SCOOTER)
	me().teleport(Vector3(0, 0.1, -9.0))
	await wait(0.2)
	await _click(MOUSE_BUTTON_LEFT)
	check("a left click hops on the scooter", me().net_riding)
	await wait(0.3)
	await _shot("scooter")
	await _click(MOUSE_BUTTON_LEFT)
	check("another steps off", not me().net_riding)
	Session.scrap_root.remove_child(board)
	board.queue_free()
	for other in Session.items_held_by(Net.my_id()):
		other.stowed = other != hand_before
	# A rigged jackpot, so it can be seen.
	me().rotation.y = -PI * 0.5
	me().teleport(Vector3(Rules.GACHA_POS.x - 2.2, 0.1, Rules.GACHA_POS.z))
	var credits_before := Session.credits
	Session.credits = maxi(Session.credits, 100)
	Session.gacha_rig = Rules.GACHA_TABLE.size() - 1
	await wait(0.3)
	await _shot("gacha")
	await _press(KEY_E)
	check("E pulls the gacha", Session.gacha_busy())
	await until(func() -> bool: return not Session.gacha_busy(), 4.0)
	await wait(0.3)
	check("a jackpot is announced on screen", main._phone_toast.visible and main._phone_toast.text.contains("JACKPOT"))
	await _shot("gacha_jackpot")
	Session.gacha_rig = -1
	# A crewmate knocked flying, seen with real graphics.
	Session.player_states[999] = {"hp": 100, "alive": true}
	var victim: Player = Session._spawn_player({"peer": 999, "name": "Crewmate", "index": 1, "pos": Vector3(0, 0, -9.5)})
	Session.players_root.add_child(victim)
	me().rotation.y = 0.0
	me().teleport(Vector3(0, 0.1, -5.6))
	await wait(0.3)
	Session.damage_player(999, Rules.PLAYER_MAX_HP, Vector3(0, 0, -8.5))
	await wait(0.15)
	await _shot("corpse_flying")
	await wait(0.2)
	await _shot("corpse_flying_spin")
	check("a body lands and lies still", await until(func() -> bool: return victim.corpse().resting, 5.0))
	await wait(1.0)
	await _shot("corpse_landed")
	check("the landed body is on screen", me()._camera.is_position_in_frustum(victim.corpse().global_position + Vector3(0, 0.3, 0)))
	Session.players_root.remove_child(victim)
	victim.queue_free()
	victim.corpse().queue_free()
	Session.player_states.erase(999)
	Session.credits = credits_before # Later checks count on the crew's real credits.


## A look across one of the facility's big halls.
func _ui_hall() -> void:
	if Session.layout.halls.is_empty():
		check("this facility has a hall to look at", false)
		return
	var block := Session.layout.halls[0]
	var from := FacilityLayout.cell_center(block.position)
	var toward := Session.layout.hall_center(0) - from
	if toward.length() < 0.1:
		toward = Vector3.RIGHT
	me().teleport(from - toward.normalized() * 3.5 + Vector3(0, 0.1, 0))
	me().rotation.y = atan2(-toward.x, -toward.z)
	await wait(0.5)
	await _shot("hall")
	check("a hall is open space: no wall between its rooms", Session.layout.is_merged(block.position, block.position + (Vector2i(1, 0) if block.size.x > 1 else Vector2i(0, 1))))


func _average_brightness(image: Image) -> float:
	var total := 0.0
	var samples := 0
	for y in range(0, image.get_height(), 40):
		for x in range(0, image.get_width(), 40):
			total += image.get_pixel(x, y).v
			samples += 1
	return total / samples


## The backpack, with real keys.
func _ui_backpack(main: Control) -> void:
	var taken := 0
	for attempt in 3:
		var next: Scrap = free_items_outside_ship()[attempt]
		me().rotation.y = 0.0
		me().teleport(Vector3(next.position.x, 0.1, next.position.z + 1.5))
		await wait(0.2)
		await _press(KEY_E)
		await wait(0.2)
		taken = Session.items_held_by(1).size()
	check("E keeps adding to the backpack (carrying %d)" % taken, taken >= 2)
	await wait(0.1)
	var slot_text: String = main._carry_slots[0].get_child(0).text
	check("the HUD lists what you carry", not slot_text.is_empty() and slot_text.contains("$"))
	var screen_area := get_viewport().get_visible_rect()
	var row_rect: Rect2 = main._carry_slots[0].get_parent().get_global_rect()
	check("the backpack bar fits on screen", screen_area.encloses(row_rect))
	check("the backpack bar stays clear of the health bars", not row_rect.intersects(main._health_bar.get_global_rect()) and not row_rect.intersects(main._stamina_bar.get_global_rect()))
	await _press(KEY_P)
	await wait(0.2)
	check("the backpack bar stays clear of the phone", not row_rect.intersects(main._phone_panel.get_global_rect()))
	await _shot("backpack_and_phone")
	await _press(KEY_P)
	var hand := Session.item_held_by(1)
	var in_hand := Session.item_held_by(1)
	var on_screen: Vector2 = me()._camera.unproject_position(in_hand.global_position)
	check("your own item sits low and to the right, clear of the crosshair (%s)" % on_screen, on_screen.x > 760.0 and on_screen.y > 420.0)
	check("your own item is still on screen", get_viewport().get_visible_rect().has_point(on_screen))
	check("the prompt offers switching items", me().interact_prompt.contains("Q: switch item") or await until(func() -> bool: return me().interact_prompt.contains("Q: switch item"), 1.0))
	await _shot("backpack")
	await _press(KEY_Q)
	check("Q switches the item in hand", await until(func() -> bool: return Session.item_held_by(1) != hand, 2.0))
	me().teleport(Vector3(0, 0.1, -9.0))
	await wait(0.2)
	for count in Rules.CARRY_LIMIT:
		await _press(KEY_G)
		await wait(0.1)
	check("G empties the backpack one item at a time", Session.items_held_by(1).is_empty())
	await wait(1.1)


## The settings screen and everything it controls, with real input.
func _ui_settings(main: Control) -> void:
	await _press(KEY_ESCAPE)
	main._pause_settings_button.pressed.emit()
	await wait(0.2)
	var menu: SettingsMenu = main._settings_menu
	check("settings open from the pause menu", menu.visible and not main._pause.visible)
	check("the mouse is free in settings", Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	check("settings has five tabs", menu.tabs.get_tab_count() == 5)
	var screen := get_viewport().get_visible_rect()
	check("settings fits on screen", screen.encloses(menu.get_global_rect()))
	for index in menu.tabs.get_tab_count():
		menu.tabs.current_tab = index
		await _shot("settings_%s" % menu.tabs.get_tab_title(index).to_lower())
		check("the %s tab fits on screen" % menu.tabs.get_tab_title(index), screen.encloses(menu.get_global_rect()))

	# Rebinding a key with a real key press, and cancelling.
	menu.tabs.current_tab = 2
	await wait(0.1)
	menu._bind_buttons["interact/keyboard"].pressed.emit()
	check("a rebind waits for a key", menu.capturing_action == "interact" and menu._bind_buttons["interact/keyboard"].text.contains("Press"))
	await _press(KEY_ESCAPE)
	check("Esc cancels a rebind without closing settings", menu.capturing_action == "" and menu.visible and Settings.keys.interact == Settings.DEFAULT_KEYS.interact)
	menu._bind_buttons["interact/keyboard"].pressed.emit()
	await _press(KEY_T)
	check("pressing a key rebinds it", Settings.keys.interact == "key:%d" % KEY_T and menu._bind_buttons["interact/keyboard"].text == "T")

	# Esc steps back one menu at a time.
	await _press(KEY_ESCAPE)
	check("Esc leaves settings for the pause menu", not menu.visible and main._pause.visible)
	await _press(KEY_ESCAPE)
	check("Esc again returns to the game", not main._pause.visible and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)

	# The new key really works, and the old one doesn't. The prompt follows.
	var item: Scrap = free_items_outside_ship()[0]
	me().rotation.y = 0.0
	me().teleport(Vector3(item.position.x, 0.1, item.position.z + 1.5))
	await wait(0.3)
	check("the prompt shows the new key", me().interact_prompt.begins_with("T: pick up"))
	await _press(KEY_E)
	await wait(0.2)
	check("the old key no longer works", item.holder_id == 0)
	await _press(KEY_T)
	check("the new key works", await until(func() -> bool: return item.holder_id == 1, 2.0))
	await _press(KEY_G)
	await until(func() -> bool: return item.holder_id == 0, 2.0)
	Settings.rebind("interact", "keyboard", Settings.DEFAULT_KEYS.interact)

	# Mouse sensitivity and invert.
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(100, 0)
	me().rotation.y = 0.0
	Input.parse_input_event(motion)
	await wait(0.1)
	var normal_turn := absf(me().rotation.y)
	Settings.set_value("mouse_sensitivity", 2.0)
	me().rotation.y = 0.0
	Input.parse_input_event(motion)
	await wait(0.1)
	check("mouse sensitivity changes turning speed", is_equal_approx(absf(me().rotation.y), normal_turn * 2.0))
	Settings.set_value("mouse_sensitivity", 1.0)
	var nod := InputEventMouseMotion.new()
	nod.relative = Vector2(0, 50)
	me()._turn(0.0, -me()._pitch)
	Input.parse_input_event(nod)
	await wait(0.1)
	var normal_pitch: float = me()._pitch
	Settings.set_value("invert_y", true)
	me()._turn(0.0, normal_pitch)
	Input.parse_input_event(nod)
	await wait(0.1)
	check("invert mouse flips looking up and down", normal_pitch < 0.0 and me()._pitch > 0.0)
	Settings.set_value("invert_y", false)
	me()._turn(0.0, me()._pitch)

	# Display and gameplay settings reach the game.
	Settings.set_value("fov", 95.0)
	check("field of view reaches the camera", is_equal_approx(me()._camera.fov, 95.0))
	await _shot("fov_95")
	Settings.set_value("fov", 75.0)
	Settings.set_value("brightness", 1.4)
	check("brightness reaches the picture", is_equal_approx(Session.level.environment.adjustment_brightness, 1.4))
	await _shot("brightness_140")
	Settings.set_value("brightness", 1.0)
	Settings.set_value("shadows", false)
	check("flashlight shadows can be turned off", not me()._flashlight.shadow_enabled)
	Settings.set_value("shadows", true)
	Settings.set_value("render_scale", 0.5)
	check("render quality reaches the renderer", is_equal_approx(get_tree().root.scaling_3d_scale, 0.5))
	await _shot("render_50")
	Settings.set_value("render_scale", 1.0)
	Settings.set_value("msaa", 4)
	check("anti-aliasing reaches the renderer", get_tree().root.msaa_3d == Viewport.MSAA_4X)
	Settings.set_value("msaa", 0)
	Settings.set_value("max_fps", 60)
	check("the frame limit reaches the engine", Engine.max_fps == 60)
	Settings.set_value("max_fps", 0)
	Settings.set_value("crosshair", false)
	await wait(0.1)
	check("the crosshair can be hidden", not main._crosshair.visible)
	Settings.set_value("crosshair", true)

	# Each volume reaches its own channel.
	Settings.set_value("music", 0.0)
	check("ambience can be silenced alone", AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")) and not AudioServer.is_bus_mute(AudioServer.get_bus_index("SFX")))
	Settings.set_value("music", 1.0)

	# The real window.
	var windowed_size := DisplayServer.window_get_size()
	Settings.set_value("resolution", "1600x900")
	await wait(0.5)
	var usable := DisplayServer.screen_get_usable_rect().size
	check("window size changes (now %s)" % DisplayServer.window_get_size(), DisplayServer.window_get_size() == Vector2i(mini(1600, usable.x), mini(900, usable.y)))
	Settings.set_value("window_mode", "fullscreen")
	await wait(1.5)
	check("fullscreen works", DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN)
	await _shot("fullscreen")
	screen = get_viewport().get_visible_rect()
	check("the HUD still fits in fullscreen", screen.encloses(main._top_label.get_global_rect()) and screen.encloses(main._stamina_bar.get_global_rect()))
	Settings.set_value("window_mode", "windowed")
	await wait(1.5)
	Settings.set_value("resolution", "1280x720")
	await wait(0.5)
	check("windowed mode comes back at its size", DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED and DisplayServer.window_get_size() == windowed_size)

	# A controller, from the look stick to the menus.
	me().rotation.y = 0.0
	me().teleport(Vector3(0, 0.1, -9.0))
	await wait(0.1)
	await _pad_stick(JOY_AXIS_RIGHT_X, 1.0)
	await wait(0.3)
	await _pad_stick(JOY_AXIS_RIGHT_X, 0.0)
	check("the right stick looks around (turned %.2f)" % me().rotation.y, me().rotation.y < -0.3)
	check("using a controller is noticed", Settings.using_pad)
	var settled := me().rotation.y
	await wait(0.2)
	check("releasing the stick stops turning", is_equal_approx(me().rotation.y, settled))
	await _pad_stick(JOY_AXIS_RIGHT_X, 0.05)
	await wait(0.2)
	check("stick drift inside the dead zone is ignored", is_equal_approx(me().rotation.y, settled))
	await _pad_stick(JOY_AXIS_RIGHT_X, 0.0)
	me().rotation.y = 0.0
	me().teleport(Vector3(0, 0.1, -9.0))
	await wait(0.1)
	var start_z := me().position.z
	await _pad_stick(JOY_AXIS_LEFT_Y, -1.0)
	await wait(0.4)
	await _pad_stick(JOY_AXIS_LEFT_Y, 0.0)
	check("the left stick moves the player", me().position.z < start_z - 0.5)
	await wait(0.1)
	item = free_items_outside_ship()[0]
	me().rotation.y = 0.0
	me().teleport(Vector3(item.position.x, 0.1, item.position.z + 1.5))
	await wait(0.3)
	check("prompts switch to controller buttons", me().interact_prompt.begins_with("X: pick up"))
	await _pad_button(JOY_BUTTON_X)
	check("the X button picks up", await until(func() -> bool: return Session.item_held_by(1) != null, 2.0))
	check("the drop prompt shows B", me().interact_prompt.begins_with("B: drop") or await until(func() -> bool: return me().interact_prompt.begins_with("B: drop"), 1.0))
	await _pad_button(JOY_BUTTON_B)
	check("the B button drops, and doesn't pause", await until(func() -> bool: return Session.item_held_by(1) == null, 2.0) and not main._pause.visible)
	var lamp: bool = me().net_flashlight
	await _pad_button(JOY_BUTTON_Y)
	check("the Y button toggles the flashlight", me().net_flashlight != lamp)
	await _pad_button(JOY_BUTTON_Y)

	# Menus with a controller: Start, focus, tabs, B to go back, and rebinding.
	await _pad_button(JOY_BUTTON_START)
	check("Start pauses", main._pause.visible)
	var focused := get_viewport().gui_get_focus_owner()
	check("the pause menu has controller focus", focused != null and main._pause.is_ancestor_of(focused))
	await _shot("pause_focus")
	# Using only the controller: D-pad down to Settings, then A to open it.
	var first_focus := focused
	await _pad_button(JOY_BUTTON_DPAD_DOWN)
	await wait(0.1)
	focused = get_viewport().gui_get_focus_owner()
	check("the D-pad moves between menu buttons", focused != first_focus and focused == main._pause_settings_button)
	await _pad_button(JOY_BUTTON_A)
	await wait(0.2)
	check("the A button presses the focused button", menu.visible)
	focused = get_viewport().gui_get_focus_owner()
	check("settings has controller focus", focused != null and menu.is_ancestor_of(focused))
	var tab_before := menu.tabs.current_tab
	await _pad_button(JOY_BUTTON_RIGHT_SHOULDER)
	check("RB moves to the next tab", menu.tabs.current_tab == (tab_before + 1) % 5)
	await _shot("settings_focus")
	focused = get_viewport().gui_get_focus_owner()
	check("focus follows into the new tab", focused != null and menu.tabs.get_current_tab_control().is_ancestor_of(focused))
	menu.tabs.current_tab = 3
	await wait(0.1)
	menu._bind_buttons["drop/controller"].pressed.emit()
	await _pad_button(JOY_BUTTON_LEFT_SHOULDER)
	check("a controller button can be rebound", Settings.pad.drop == "joy:%d" % JOY_BUTTON_LEFT_SHOULDER)
	Settings.rebind("drop", "controller", Settings.DEFAULT_PAD.drop)
	await _pad_button(JOY_BUTTON_B)
	check("B leaves settings", not menu.visible and main._pause.visible)
	await _pad_button(JOY_BUTTON_START)
	check("Start resumes", not main._pause.visible and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)

	# Back to the keyboard, and prompts follow.
	await _press(KEY_F)
	await _press(KEY_F)
	check("prompts return to keyboard keys", not Settings.using_pad)
	me().rotation.y = 0.0
	me().teleport(Vector3(0, 0.1, -9.0))


# --- Speed: every map at its largest, with the frame rate limit off ---------------

func _perf() -> void:
	print("PERF_START game ready after %d ms" % Time.get_ticks_msec())
	Net.listen_port = port
	Settings.set_value("vsync", false)
	Settings.set_value("max_fps", 0)
	var main: Control = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	check("host opens", Net.host("Host", port) == OK)
	Session.forced_maps = ["foundry"]
	Session.start_run()
	await until(func() -> bool: return me() != null, 3.0)
	for map: String in MapThemes.ORDER:
		Session.forced_maps = [map]
		Session._clear_entities()
		Session.level_number = 5 # The largest facility, with the most creatures.
		Session._run_seed = 12345 # The same facility every time, so runs can be compared.
		var built_at := Time.get_ticks_usec()
		Session._begin_round(3)
		var build_ms := (Time.get_ticks_usec() - built_at) / 1000.0
		Session.time_left = 300.0
		await until(func() -> bool: return me() != null, 3.0)
		me().teleport(FacilityLayout.cell_center(Vector2i(3, 3)) + Vector3(0, 0.1, 0))
		for entity: Entity in Session.entity_root.get_children():
			entity.grace = 0.0
		me().teleport(FacilityLayout.cell_center(Vector2i(0, 0)) + Vector3(0, 0.1, -9.0))
		me().rotation.y = PI
		await wait(1.5)
		var frames := 0
		var slowest := 0.0
		var started := Time.get_ticks_usec()
		var slow_frames := 0
		while Time.get_ticks_usec() - started < 4000000:
			await get_tree().process_frame
			frames += 1
			slowest = maxf(slowest, get_process_delta_time())
			if get_process_delta_time() > 1.0 / 60.0:
				slow_frames += 1
		var seconds := (Time.get_ticks_usec() - started) / 1000000.0
		print("PERF %s: %.0f fps, slowest frame %.1f ms, %d frames over 16.7 ms, %d triangles, %d draw calls, level built in %.0f ms, %.0f MB video memory" % [
			map, frames / seconds, slowest * 1000.0, slow_frames,
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME), build_ms,
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0])
	Net.leave()


# --- The backpack's rules -------------------------------------------------------

func _carry() -> void:
	check("host opens", Net.host("Host", port) == OK)
	Session.entities_enabled = false
	Session.forced_maps = ["foundry"]
	Session.goal_override = 100000
	Session.start_run()
	await until(func() -> bool: return me() != null, 3.0)
	await wait(0.2)
	var host_id := Net.my_id()
	check("you start with nothing", Session.items_held_by(host_id).is_empty() and Session.carried_weight(host_id) == 0.0)
	check("the backpack adds five to the one in your hands", Rules.CARRY_LIMIT == 6)
	var items: Array[Scrap] = free_items_outside_ship()
	check("there's more scrap than you can carry", items.size() > Rules.CARRY_LIMIT)
	for index in Rules.CARRY_LIMIT:
		me().teleport(items[index].position)
		await wait(0.05)
		Session.request_pickup.rpc_id(1, items[index].item_id)
		check("item %d can be carried" % (index + 1), Session.items_held_by(host_id).size() == index + 1)
		check("the newest item goes in your hands", Session.item_held_by(host_id) == items[index])
	var stowed_count := 0
	for item in Session.items_held_by(host_id):
		if item.stowed:
			stowed_count += 1
	check("exactly five are in the backpack", stowed_count == 5)

	# Number seven doesn't fit, and the prompt says so.
	var extra: Scrap = items[Rules.CARRY_LIMIT]
	me().rotation.y = 0.0
	me().teleport(Vector3(extra.position.x, 0.1, extra.position.z + 1.5))
	await wait(0.2)
	Session.request_pickup.rpc_id(1, extra.item_id)
	check("a seventh item is refused", extra.holder_id == 0 and Session.items_held_by(host_id).size() == Rules.CARRY_LIMIT)
	check("the prompt says you're full", me().interact_prompt.contains("full"))

	# Weight.
	var full_load := Session.carried_weight(host_id)
	check("a full load slows you (%.2f)" % full_load, full_load > 0.0)
	check("you can always still move", full_load <= Rules.MAX_CARRY_SLOWDOWN and 1.0 - full_load >= 0.4)
	me().teleport(room_for_walk())
	await wait(0.1)
	var loaded_from := me().position
	me().bot_move = Vector2(0, 1)
	await wait(0.5)
	me().bot_move = Vector2.ZERO
	var loaded_distance := me().position.distance_to(loaded_from)
	check("a full load really moves (%.2f m)" % loaded_distance, loaded_distance > 0.2)

	# Everything follows you.
	me().teleport(Vector3(0, 0.1, -9.0))
	await wait(0.2)
	for item in Session.items_held_by(host_id):
		check("carried items stay with you", item.position.distance_to(me().position) < 2.0)
	var in_ship_total := 0
	for item in Session.items_held_by(host_id):
		in_ship_total += item.value
	check("everything carried into the ship counts", Session._ship_value() == in_ship_total)

	# Switching goes all the way round.
	var order: Array = []
	for step in Rules.CARRY_LIMIT:
		order.append(Session.item_held_by(host_id))
		Session.request_cycle_item.rpc_id(1)
	var unique_hands := {}
	for item: Scrap in order:
		unique_hands[item] = true
	check("switching reaches every item", unique_hands.size() == Rules.CARRY_LIMIT)
	check("switching comes back round", Session.item_held_by(host_id) == order[0])
	var in_hand_count := 0
	for item in Session.items_held_by(host_id):
		if not item.stowed:
			in_hand_count += 1
	check("only one item is ever in your hands", in_hand_count == 1)

	# Dropping takes one at a time, and the next comes to hand.
	var dropped := Session.item_held_by(host_id)
	Session.request_drop.rpc_id(1)
	check("drop leaves one on the floor", dropped.holder_id == 0 and dropped.visible)
	check("the next item comes to hand", Session.item_held_by(host_id) != null and Session.items_held_by(host_id).size() == Rules.CARRY_LIMIT - 1)

	# Dying spills everything, within reach and in sight.
	me().teleport(FacilityLayout.cell_center(FacilityLayout.ENTRY_CELL) + Vector3(0, 0.1, 0))
	await wait(0.2)
	var spilled := Session.items_held_by(host_id)
	var death_spot := me().net_pos
	Net.players[99] = "Stand-in"
	Session.player_states[99] = {"hp": 100, "alive": true}
	Session.damage_player(host_id, Rules.PLAYER_MAX_HP)
	check("dying drops everything", Session.items_held_by(host_id).is_empty())
	var spill_ok := true
	var positions := {}
	for item in spilled:
		spill_ok = spill_ok and item.visible and not item.stowed and Vector2(item.position.x - death_spot.x, item.position.z - death_spot.z).length() < 1.0
		positions[item.position] = true
	check("dropped items stay close and visible", spill_ok)
	check("dropped items don't all stack up", positions.size() == spilled.size())
	Net.leave()


func room_for_walk() -> Vector3:
	return FacilityLayout.cell_center(FacilityLayout.ENTRY_CELL) + Vector3(0, 0.1, -3.0)


# --- Four days to reach each level's goal ---------------------------------------

## Finishes the day with exactly `value` worth of scrap banked, or with the crew dead.
func _end_day(value: int, everyone_dies: bool = false) -> void:
	await until(func() -> bool: return Session.phase == Session.Phase.PLAYING and me() != null, 5.0)
	await wait(0.1)
	var banked := 0
	for item: Scrap in Session.scrap_root.get_children():
		if banked < value:
			item.value = mini(item.value, value - banked)
			item.position = Vector3(0, 0.25, -9.0)
			banked += item.value
		else:
			item.position = Vector3(1000, 0.25, 1000)
	if everyone_dies:
		me().teleport(FacilityLayout.cell_center(FacilityLayout.ENTRY_CELL) + Vector3(0, 0.1, 0))
		await wait(0.2)
		Session.damage_player(Net.my_id(), Rules.PLAYER_MAX_HP)
	else:
		me().teleport(Vector3(0, 0.1, -9.0))
		await wait(0.2)
		Session._end_round()
	await until(func() -> bool: return Session.phase != Session.Phase.PLAYING, 3.0)


func _days() -> void:
	check("host opens", Net.host("Host", port) == OK)
	Session.entities_enabled = false
	Session.results_seconds = 0.7
	Session.land_automatically = true
	Session.forced_maps = []
	Session.goal_override = 100
	var main: Control = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await wait(0.1)
	Session.start_run()
	check("a run starts on level 1, day 1", Session.level_number == 1 and Session.day == 1 and Session.days_per_level == 4)
	await until(func() -> bool: return me() != null, 3.0)
	var first_map := Session.map_id
	var first_site := Session.site

	# Scrap adds up across days, and the day moves on.
	await _end_day(40)
	var results: Dictionary = Session.last_results
	check("day 1: the run carries on", Session.phase == Session.Phase.RESULTS and results.run_over == false and results.cleared == false)
	check("day 1: the amounts are reported", results.collected == 40 and results.banked == 40 and results.day == 1 and results.days == 4)
	check("banked scrap becomes credits", results.credits == Rules.STARTING_CREDITS + 40 and Session.credits == Rules.STARTING_CREDITS + 40)
	check("the results say how many days are left", main._results_label.text.begins_with("Day over. 3 days left"))
	check("the results show progress toward the goal", main._results_label.text.contains("Goal: $40 of $100"))
	await until(func() -> bool: return Session.phase == Session.Phase.PLAYING and Session.day == 2, 5.0)
	check("day 2 begins on its own", Session.day == 2 and Session.level_number == 1)
	check("day 1's scrap still counts", Session.level_banked == 40)
	await wait(0.1)
	check("the HUD shows the day", main._top_label.text.contains("Level 1") and main._top_label.text.contains("Day 2 of 4"))
	check("the HUD shows banked scrap toward the goal", main._top_label.text.contains("Goal $40 / $100"))
	check("each day is a different map", Session.map_id != first_map)
	check("the clock restarts each day, with the time this site gets", Session.time_left > Rules.round_seconds(Session.site) - 5.0 and Session.time_left <= Rules.round_seconds(Session.site))
	check("the banner names the site's size", main._banner_label.text.contains(Rules.SITE_INFO[Session.site].name.to_upper()))
	check("the facility is the size its site says", Session.layout.size == Rules.site_grid(Rules.difficulty(1), Session.site) and Session.layout.site == Session.site)
	var sites_seen := {first_site: true, Session.site: true}
	check("day 2 is a different size from day 1 (%s, %s)" % [first_site, Session.site], Session.site != first_site)

	# A dead crew loses that day's scrap and the day, but not the run.
	await _end_day(30, true)
	results = Session.last_results
	check("a wipe doesn't end the run", Session.phase == Session.Phase.RESULTS and results.run_over == false)
	check("a wipe loses that day's scrap", results.collected == 0 and results.banked == 40)
	check("a wipe earns no credits", results.credits == Rules.STARTING_CREDITS + 40)
	check("the results explain a wipe", main._results_label.text.contains("Nobody made it back") and main._results_label.text.begins_with("Day over. 2 days left"))
	await until(func() -> bool: return Session.phase == Session.Phase.PLAYING and Session.day == 3, 5.0)
	check("a wipe still uses up the day", Session.day == 3 and Session.level_banked == 40)
	sites_seen[Session.site] = true
	check("three days visit a small, a medium and a large site", sites_seen.size() == 3)
	check("everyone is back the next day", Session.is_player_alive(Net.my_id()))

	# Reaching the goal moves on straight away, even with days to spare.
	await _end_day(60)
	results = Session.last_results
	check("reaching the goal clears the level", results.cleared == true and results.banked == 100 and results.run_over == false)
	check("one level is recorded as cleared", Session.rounds_cleared == 1)
	check("the results celebrate the level", main._results_label.text.begins_with("Goal reached! Level 2 is next."))
	await until(func() -> bool: return Session.phase == Session.Phase.PLAYING and Session.level_number == 2, 5.0)
	check("the next level starts on day 1", Session.level_number == 2 and Session.day == 1)
	check("the next level starts from zero", Session.level_banked == 0)

	# Falling short after day 4 ends the run. Exactly four days, no more.
	for day_number in range(1, 4):
		check("level 2, day %d is played" % day_number, Session.day == day_number)
		await _end_day(10)
		check("level 2, day %d doesn't end the run" % day_number, Session.phase == Session.Phase.RESULTS)
		await until(func() -> bool: return Session.phase == Session.Phase.PLAYING and Session.day == day_number + 1, 5.0)
	check("the wording handles one day left", Session.last_results.day == 3 and main._results_label.text.begins_with("Day over. 1 day left"))
	check("day 4 is the last chance", Session.day == 4 and Session.level_banked == 30)
	await _end_day(10)
	results = Session.last_results
	check("missing the goal on day 4 ends the run", Session.phase == Session.Phase.GAME_OVER and results.run_over == true and results.cleared == false)
	check("the run total includes every day", results.total_scrap == 40 + 60 + 40)
	check("the results say the run is over", main._results_label.text.begins_with("Out of days."))
	check("the crew returns to orbit for a new run", await until(func() -> bool: return Session.phase == Session.Phase.ORBIT, 5.0))
	check("a finished run waits in orbit instead of landing", Session.round_number == 0 and Session.credits == Rules.STARTING_CREDITS)

	# Reaching the goal on the very last day still counts.
	Session.start_run()
	await until(func() -> bool: return me() != null, 3.0)
	check("a new run starts fresh", Session.level_number == 1 and Session.day == 1 and Session.level_banked == 0 and Session.rounds_cleared == 0)
	for day_number in range(1, 4):
		await _end_day(30)
		await until(func() -> bool: return Session.phase == Session.Phase.PLAYING and Session.day == day_number + 1, 5.0)
	await _end_day(10)
	results = Session.last_results
	check("reaching the goal on day 4 still clears the level", results.cleared == true and results.day == 4 and results.run_over == false)
	check("the goal grows with each level", Rules.quota(2, 1) > Rules.quota(1, 1))
	Net.leave()


# --- Video files ------------------------------------------------------------------

## Writes a clip with known contents, for Apple's video framework to check.
func _video() -> void:
	var path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("video="):
			path = arg.trim_prefix("video=")
	var frames: Array = []
	var times := PackedFloat32Array()
	for index in 75:
		var image := Image.create(PhoneCamera.VIDEO_SIZE.x, PhoneCamera.VIDEO_SIZE.y, false, Image.FORMAT_RGB8)
		image.fill(Color.from_hsv(0.0, 0.0, float(index) / 74.0))
		frames.append(image.save_jpg_to_buffer(0.85))
		times.append(index / 15.0)
	var durations := PhoneCamera.durations_for(times, 5.0)
	var total := 0
	for ticks in durations:
		total += ticks
	check("frame timings add up to exactly 5 seconds", total == 5 * MovWriter.TIMESCALE)
	var uneven := PhoneCamera.durations_for(PackedFloat32Array([0.0, 0.5, 0.6, 4.0]), 5.0)
	var uneven_total := 0
	for ticks in uneven:
		uneven_total += ticks
	check("timings stay true when frames arrive unevenly", uneven_total == 5 * MovWriter.TIMESCALE and uneven[0] == 300)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(MovWriter.build(frames, durations, PhoneCamera.VIDEO_SIZE.x, PhoneCamera.VIDEO_SIZE.y))
	file.close()
	check("a test clip was written", FileAccess.get_file_as_bytes(path).size() > 1000)


# --- Settings: saving, safety limits and rebinding rules ------------------------

func _settings() -> void:
	var path := OS.get_user_data_dir().path_join("test_settings_%d.cfg" % OS.get_process_id())
	Settings._file = path
	Settings._persist = true
	check("settings start at their defaults", Settings.value("fov") == Settings.DEFAULTS.fov)

	# Limits.
	Settings.set_value("fov", 9999.0)
	check("numbers are held to their limits", Settings.value("fov") == 110.0)
	Settings.set_value("fov", NAN)
	check("nonsense numbers are refused", Settings.value("fov") == Settings.DEFAULTS.fov)
	Settings.set_value("window_mode", "banana")
	check("nonsense choices are refused", Settings.value("window_mode") == "windowed")
	Settings.set_value("vsync", "yes please")
	check("nonsense on/off values are refused", Settings.value("vsync") == true)

	# Saving and loading.
	Settings.set_value("fov", 90.0)
	Settings.set_value("master", 0.25)
	Settings.set_value("invert_y", true)
	Settings.rebind("jump", "keyboard", "key:%d" % KEY_C)
	Settings.save()
	Settings.reset_to_defaults()
	Settings._persist = true
	var reset_ok: bool = Settings.value("fov") == Settings.DEFAULTS.fov and Settings.keys.jump == Settings.DEFAULT_KEYS.jump
	check("reset restores every default", reset_ok)
	Settings.set_value("fov", 90.0)
	Settings.set_value("master", 0.25)
	Settings.set_value("invert_y", true)
	Settings.rebind("jump", "keyboard", "key:%d" % KEY_C)
	Settings.save()
	Settings.values = Settings.DEFAULTS.duplicate()
	Settings.keys = Settings.DEFAULT_KEYS.duplicate()
	Settings.load_from_file()
	check("settings survive a restart", Settings.value("fov") == 90.0 and Settings.value("master") == 0.25 and Settings.value("invert_y") == true and Settings.keys.jump == "key:%d" % KEY_C)

	# Damaged files.
	var damaged := FileAccess.open(path, FileAccess.WRITE)
	damaged.store_string("this is not a settings file {{{")
	damaged.close()
	Settings.load_from_file()
	check("a damaged file falls back to defaults", Settings.value("fov") == Settings.DEFAULTS.fov and Settings.keys.jump == Settings.DEFAULT_KEYS.jump)
	var odd := ConfigFile.new()
	odd.set_value("settings", "fov", "wide")
	odd.set_value("settings", "master", 40.0)
	odd.set_value("settings", "window_mode", 7)
	odd.set_value("keyboard", "jump", "nonsense")
	odd.set_value("keyboard", "drop", "key:%d" % KEY_ESCAPE)
	odd.set_value("controller", "jump", "joy:999")
	odd.save(path)
	Settings.load_from_file()
	check("bad values in a file are repaired", Settings.value("fov") == Settings.DEFAULTS.fov and Settings.value("master") == 1.0 and Settings.value("window_mode") == "windowed")
	check("bad bindings in a file are ignored", Settings.keys.jump == Settings.DEFAULT_KEYS.jump and Settings.keys.drop == Settings.DEFAULT_KEYS.drop and Settings.pad.jump == Settings.DEFAULT_PAD.jump)
	var old := ConfigFile.new()
	old.set_value("audio", "volume", 0.35)
	old.save(path)
	Settings.load_from_file()
	check("the old volume setting carries over", is_equal_approx(Settings.value("master"), 0.35))
	Settings.apply_bindings()

	# Rebinding rules.
	Settings.reset_to_defaults()
	Settings.rebind("jump", "keyboard", Settings.DEFAULT_KEYS.drop)
	check("taking a used key swaps the two actions", Settings.keys.jump == Settings.DEFAULT_KEYS.drop and Settings.keys.drop == Settings.DEFAULT_KEYS.jump)
	var event := InputEventKey.new()
	event.physical_keycode = KEY_G
	check("the swap reaches the game's input", event.is_action("jump") and not event.is_action("drop"))
	var unique := {}
	for action: String in Settings.keys:
		unique[Settings.keys[action]] = true
	check("no key ever does two things", unique.size() == Settings.keys.size())
	Settings.reset_to_defaults()
	var escape := InputEventKey.new()
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	check("Esc can't be rebound", Settings.binding_from_event(escape, "keyboard") == "")
	var start := InputEventJoypadButton.new()
	start.button_index = JOY_BUTTON_START
	start.pressed = true
	check("Start can't be rebound", Settings.binding_from_event(start, "controller") == "")
	var stick := InputEventJoypadMotion.new()
	stick.axis = JOY_AXIS_LEFT_X
	stick.axis_value = 1.0
	check("sticks can't be bound to buttons", Settings.binding_from_event(stick, "controller") == "")
	var trigger := InputEventJoypadMotion.new()
	trigger.axis = JOY_AXIS_TRIGGER_LEFT
	trigger.axis_value = 1.0
	check("triggers can be bound", Settings.binding_from_event(trigger, "controller") == "axis:%d" % JOY_AXIS_TRIGGER_LEFT)
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_RIGHT
	mouse.pressed = true
	check("mouse buttons can be bound", Settings.binding_from_event(mouse, "keyboard") == "mouse:%d" % MOUSE_BUTTON_RIGHT)
	check("binding names read naturally", Settings.binding_name("axis:5") == "RT" and Settings.binding_name("joy:0") == "A" and Settings.binding_name("mouse:2") == "Right click" and Settings.binding_name("key:%d" % KEY_E) == "E")

	# Audio channels, vibration and hints.
	check("audio has separate channels", AudioServer.get_bus_index("Music") > 0 and AudioServer.get_bus_index("SFX") > 0)
	check("ambience uses its own channel", Sfx._ambient.bus == "Music")
	Settings.set_value("sfx", 0.5)
	check("the effects volume reaches its channel", is_equal_approx(db_to_linear(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("SFX"))), 0.5))
	Settings.set_value("vibration", false)
	Settings.rumble(1.0, 1.0, 0.1)
	check("vibration can be turned off", Settings.rumble_count == 0)
	Settings.set_value("vibration", true)
	Settings.rumble(1.0, 1.0, 0.1)
	check("vibration is on by default", Settings.rumble_count == 1)
	Settings.set_value("hints", false)
	Session.show_hint("stalker")
	check("hints can be turned off", Session.hint_seconds == 0.0)
	Settings.set_value("hints", true)
	DirAccess.remove_absolute(path)
	check("tests leave the real settings alone", not FileAccess.file_exists(path))


# --- Measures how loud each sound is, one at a time, at master volume 100% ------

func _peak_over(seconds: float) -> float:
	var loudest := -200.0
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		loudest = maxf(loudest, AudioServer.get_bus_peak_volume_left_db(0, 0))
		await get_tree().process_frame
	return loudest


func _levels() -> void:
	Settings.set_value("master", 1.0)
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
		Session.land_automatically = true
		Session.entities_enabled = false
		Session.forced_maps = ["foundry", "reactor"]
		Session.goal_override = 60
		Session.days_per_level = 1
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
	var find_total := Session.layout.finds.size()
	check("all scrap and useful items appear for everyone", await until(func() -> bool: return Session.scrap_root.get_child_count() == scrap_total + find_total))
	check("every creature and helper appears", await until(func() -> bool: return Session.entity_root.get_child_count() == Session.layout.entity_spawns.size()))
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

	# A backpack, seen by everyone: Bot3 carries two things, then puts them back.
	var pack_items: Array[Scrap] = free_items_outside_ship()
	var first_pack: Scrap = pack_items[0]
	var second_pack: Scrap = pack_items[1]
	if idx == 3:
		me().teleport(first_pack.position)
		await wait(0.3)
		Session.request_pickup.rpc_id(1, first_pack.item_id)
		await until(func() -> bool: return first_pack.holder_id == bot3, 3.0)
		me().teleport(second_pack.position)
		await wait(0.3)
		Session.request_pickup.rpc_id(1, second_pack.item_id)
	check("everyone sees a player carry two items", await until(func() -> bool: return Session.items_held_by(bot3).size() == 2))
	check("everyone agrees what's in the backpack", await until(func() -> bool: return first_pack.stowed and not second_pack.stowed))
	check("a stowed item can't be seen", not first_pack.visible and second_pack.visible)
	if idx != 3:
		check("other players see the backpack", await until(func() -> bool: return Session.player_node(bot3)._backpack_model.visible, 2.0))
	await barrier("packed", 4)
	if idx == 3:
		Session.request_cycle_item.rpc_id(1)
	check("everyone sees the switch", await until(func() -> bool: return not first_pack.stowed and second_pack.stowed))
	await barrier("switched", 4)
	if idx == 3:
		Session.request_drop.rpc_id(1)
		await wait(0.2)
		Session.request_drop.rpc_id(1)
	check("everyone sees the items dropped", await until(func() -> bool: return Session.items_held_by(bot3).is_empty()))
	check("dropped items can be seen again", first_pack.visible and second_pack.visible)
	await barrier("unpacked", 4)

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
		var monster := Session.entity_of_kind("stalker") as Monster
		var victim := Session.player_node(bot2)
		var cell := FacilityLayout.cell_at(victim.net_pos)
		monster.position = FacilityLayout.cell_center(cell)
		monster.grace = 0.0
		monster.enabled = true
	check("the monster kills the player, seen by everyone",
		await until(func() -> bool: return not Session.is_player_alive(bot2), 20.0))
	check("a dead player's scrap falls to the floor",
		await until(func() -> bool: return item(carried_id).holder_id == 0))
	var hunter := Session.entity_of_kind("stalker") as Monster
	check("everyone sees the monster attack", await until(func() -> bool: return hunter.net_attacks >= 2, 3.0))
	check("everyone hears the monster attack", await until(func() -> bool: return Sfx.play_count.get("hit", 0) >= 2, 3.0))
	check("everyone hears the monster start hunting", await until(func() -> bool: return Sfx.play_count.get("monster_growl", 0) >= 1, 3.0))
	if idx != 2:
		check("the dead player's body plays the death animation", await until(func() -> bool: return Session.player_node(bot2).current_animation == "die", 3.0))
	var fallen := Session.player_node(bot2).corpse()
	check("everyone sees the body knocked flying", fallen != null and fallen.get_parent() == Session.level)
	check("everyone sees it land and lie still", await until(func() -> bool: return fallen.resting, 5.0) and is_equal_approx(fallen.position.y, 0.0))
	check("the body lies inside the facility", Session.layout.has_cell(FacilityLayout.cell_at(fallen.position)) or Rules.in_ship(fallen.position))
	print("CORPSE_SPOT %.2f %.2f" % [fallen.position.x, fallen.position.z])
	if role == "host":
		var monster := Session.entity_of_kind("stalker") as Monster
		monster.enabled = false
		monster.position = Vector3(20, 0, 20)
	check("everyone sees the monster in the same place",
		await until(func() -> bool:
			return Session.entity_of_kind("stalker").position.distance_to(Vector3(20, 0, 20)) < 0.3))
	await barrier("killed", 4)

	# A Mimic's bite, seen by everyone, and it disappears for everyone.
	var mimic_count := Session.entity_root.get_child_count()
	if role == "host":
		var mimic := Session.entity_of_kind("mimic") as Mimic
		mimic.position = Vector3(10, 0.25, 0)
		mimic.net_pos = mimic.position
		mimic.grace = 0.0
		mimic.enabled = true
	if idx == 1:
		me().teleport(Vector3(10, 0.1, 0))
	check("everyone sees the Mimic bite", await until(func() -> bool: return Session.player_states[bot1].hp == Rules.PLAYER_MAX_HP - Mimic.DAMAGE))
	check("the Mimic vanishes for everyone", await until(func() -> bool: return Session.entity_root.get_child_count() == mimic_count - 1))
	await barrier("mimic", 4)

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
	check("round 2 is the next map", Session.map_id == "reactor")
	check("round 2's residents appear for everyone", await until(func() -> bool: return Session.entity_root.get_child_count() == Session.layout.entity_spawns.size()))
	await barrier("round2", 3)

	# A phone being used is seen by everyone.
	if idx == 1:
		me().phone.raise()
		me().phone.start_recording()
		me().phone.take_photo()
		me().net_flashes += 1
	var filmer := Session.player_node(bot1)
	check("everyone sees a phone being held up", await until(func() -> bool: return filmer.net_phone_up))
	check("everyone sees the recording light", await until(func() -> bool: return filmer.net_recording))
	check("everyone sees the camera flash", await until(func() -> bool: return filmer.net_flashes >= 1))
	if idx != 1:
		check("other players see the phone model", filmer._phone_model.visible and filmer._recording_light.visible)
	await barrier("phone_seen", 3)
	if idx == 1:
		check("a player's own body doesn't show their phone", not me()._phone_model.visible)
		me().phone.put_away()
	check("everyone sees the phone put away", await until(func() -> bool: return not filmer.net_phone_up and not filmer.net_recording))
	await barrier("phone_away", 3)

	# A helper's state reaches everyone.
	if role == "host":
		Session.entity_of_kind("wisp").net_state = Wisp.WARNING
	check("everyone sees the Wisp's warning", await until(func() -> bool: return Session.entity_of_kind("wisp").net_state == Wisp.WARNING))
	await barrier("wisp", 3)

	# Time runs out with nothing collected: game over, scores saved, back to lobby.
	if role == "host":
		Session.time_left = 1.0
	check("the timer ends the run", await until(func() -> bool: return Session.phase == Session.Phase.GAME_OVER))
	check("a failed round is not counted as cleared", Session.last_results.cleared == false and Session.rounds_cleared == 1)
	check("the map changed for round 2", Session.map_id == "reactor" or Session.phase != Session.Phase.PLAYING)
	check("the run's end is reported to everyone", Session.last_results.run_over == true)
	check("the crew returns to orbit for a new run", await until(func() -> bool: return Session.phase == Session.Phase.ORBIT))
	check("the facility is gone and the ship is in orbit", Session.layout == null and Session.level != null and Session.entity_root.get_child_count() == 0)
	check("everyone is back on board", await until(func() -> bool: return Session.players_root.get_child_count() == 3))
	check("this player's run was saved to the database", await until(func() -> bool: return Cloud.submit_count >= 1) and Cloud.last_submit_ok)
	var rows: Array = await Cloud.fetch_leaderboard()
	check("the leaderboard can be read", rows.size() >= 1)
	Cloud._access_token = ""
	check("an expired login renews itself", await Cloud._ensure_signed_in() and Cloud._access_token == "token-refreshed")
	await barrier("over", 3)
	if role == "host":
		print("ORBIT_OPEN")
	await _scenario_orbit()
	if role == "host":
		await wait(0.5)
		Net.leave()
	else:
		check("clients are told the host left", await until(func() -> bool: return _ended_reason == "The host left the game."))
		check("clients return to the menu", not Net.is_online())


# --- After the run: a friend joins the ship in orbit, and the crew gears up --------

## A friend who joins late, while the ship waits in orbit between runs.
func _late() -> void:
	check("a friend can start connecting", Net.join("Late", "127.0.0.1", port) == OK)
	check("a friend can join while the ship is in orbit", await until(func() -> bool: return Session.phase == Session.Phase.ORBIT and me() != null, 30.0))
	check("the late friend sees the whole crew", await until(func() -> bool: return Net.players.size() == 4 and Session.players_root.get_child_count() == 4))
	check("the late friend is on board the ship", Session.level != null and Rules.in_ship(me().position))
	check("the late friend gets the run's state", Session.credits == Rules.STARTING_CREDITS and Session.day == 1 and Session.level_number == 1)
	await _scenario_orbit()
	check("clients are told the host left", await until(func() -> bool: return _ended_reason == "The host left the game."))
	check("clients return to the menu", not Net.is_online())


func _scenario_orbit() -> void:
	check("a late friend joins the crew in orbit", await until(func() -> bool: return Net.players.size() == 4 and Session.players_root.get_child_count() == 4, 60.0))
	var late := peer_named("Late")
	check("everyone gets the late friend's state", await until(func() -> bool: return Session.is_player_alive(late), 3.0))
	await barrier("late_joined", 4)
	var bot1 := peer_named("Bot1")
	var bot2 := peer_named("Bot2")
	check("a new run starts with fresh credits", Session.credits == Rules.STARTING_CREDITS)

	# Buying happens at the terminal, from the crew's shared credits.
	if idx == 2:
		me().teleport(Vector3(-3.0, 0.1, -7.0))
		await wait(0.3)
		Session.request_buy.rpc_id(1, Tools.SHOVEL)
		await wait(0.5)
		check("gear can't be bought from across the ship", Session.credits == Rules.STARTING_CREDITS and gear(Tools.SHOVEL) == null)
	await barrier("far_buy", 4)
	if idx == 1:
		me().teleport(Rules.TERMINAL_POS + Vector3(-1.2, 0.1, 0))
		await wait(0.3)
		Session.request_buy.rpc_id(1, Tools.SHOVEL)
		check("the buyer is told it worked", await until(func() -> bool: return _shop_reply.contains("bought"), 3.0))
	check("everyone sees the credits spent", await until(func() -> bool: return Session.credits == Rules.STARTING_CREDITS - Tools.CATALOG[Tools.SHOVEL].price))
	check("everyone sees the shovel arrive", await until(func() -> bool: return gear(Tools.SHOVEL) != null))
	check("everyone hears the terminal", await until(func() -> bool: return "buy" in _effects, 3.0))
	await barrier("bought", 4)
	if idx == 1:
		Session.request_buy.rpc_id(1, Tools.ZAP_GUN)
		check("the terminal refuses what the crew can't afford", await until(func() -> bool: return _shop_reply.begins_with("Not enough credits"), 3.0))
	await barrier("too_dear", 4)
	check("a refused purchase costs nothing", Session.credits == Rules.STARTING_CREDITS - Tools.CATALOG[Tools.SHOVEL].price and gear(Tools.ZAP_GUN) == null)

	# Crewmates can bonk each other with a shovel: everyone sees and hears it.
	var shovel := gear(Tools.SHOVEL)
	if idx == 1:
		me().teleport(Vector3(shovel.position.x, 0.1, shovel.position.z))
		await wait(0.3)
		Session.request_pickup.rpc_id(1, shovel.item_id)
	check("everyone sees who took the shovel", await until(func() -> bool: return shovel.holder_id == bot1))
	await barrier("armed", 4)
	if idx == 2:
		me().teleport(Vector3(0, 0.1, -10.0))
	elif idx == 1:
		me().rotation.y = 0.0
		me().teleport(Vector3(0, 0.1, -8.7))
	else:
		# Everyone else stands well clear of the swing.
		me().teleport(Vector3(3.0 if role == "host" else -3.0, 0.1, -6.0))
	await barrier("lined_up", 4)
	# Swing only once every machine sees everyone in place: a busy computer can deliver
	# "I've moved" before the move itself, and a stale position would take the hit.
	var spots := {"Host": Vector3(3.0, 0, -6.0), "Late": Vector3(-3.0, 0, -6.0), "Bot1": Vector3(0, 0, -8.7), "Bot2": Vector3(0, 0, -10.0)}
	var all_in_place := func() -> bool:
		for node: Player in Session.players_root.get_children():
			if Vector2(node.net_pos.x - spots[node.display_name].x, node.net_pos.z - spots[node.display_name].z).length() > 0.1:
				return false
		return true
	check("everyone sees the crew line up", await until(all_in_place, 5.0))
	await barrier("seen_lined_up", 4)
	if idx == 1:
		Session.request_use_item.rpc_id(1)
	check("everyone sees a crewmate get bonked", await until(func() -> bool: return Session.player_states[bot2].hp == Rules.PLAYER_MAX_HP - Tools.SHOVEL_CREW_DAMAGE))
	check("everyone hears the bonk", await until(func() -> bool: return "bonk" in _effects, 3.0))
	if idx != 1:
		check("everyone sees the swing", await until(func() -> bool: return Session.player_node(bot1).current_animation == "attack-melee-right", 2.0))
	await barrier("bonked", 4)
	# Mashing the button doesn't swing any faster than the shovel can.
	if idx == 1:
		await wait(1.0) # Past the first swing's cooldown, so exactly one of these lands.
		for press in 4:
			Session.request_use_item.rpc_id(1)
			await get_tree().physics_frame
	var after_mash := Rules.PLAYER_MAX_HP - 2 * Tools.SHOVEL_CREW_DAMAGE
	check("mashing the button lands one swing", await until(func() -> bool: return Session.player_states[bot2].hp <= after_mash, 5.0))
	await wait(1.0)
	check("mashing the button swings only once", Session.player_states[bot2].hp == after_mash)
	await barrier("mashed", 4)

	# The friend who joined late lands the ship, and the gear comes along.
	if role == "late":
		me().rotation.y = 0.0
		me().teleport(Rules.CONSOLE_POS + Vector3(0, 0.1, 1.5))
		await wait(0.3)
		Session.request_launch.rpc_id(1)
	check("a friend who joined in orbit can land the ship", await until(func() -> bool: return Session.phase == Session.Phase.PLAYING))
	check("the shovel lands in its owner's hands", is_instance_valid(shovel) and shovel.holder_id == bot1)
	check("all four land together", await until(func() -> bool: return Session.players_root.get_child_count() == 4))
	check("everyone lands at full health", await until(func() -> bool: return Session.player_states[bot2].hp == Rules.PLAYER_MAX_HP))
	print("FACILITY_R3 %d" % Session.layout.fingerprint())
	await barrier("landed", 4)

	# Scrap Slots: a player gambles, and everyone sees the same result.
	var bet: Scrap = item(1)
	var stake := bet.value
	if role == "host":
		Session.gamble_rig = 2 # A x2 win, so the outcome is known.
	await barrier("rigged", 4)
	if idx == 1:
		me().teleport(Vector3(bet.position.x, 0.1, bet.position.z))
		await wait(0.3)
		Session.request_pickup.rpc_id(1, bet.item_id)
		await until(func() -> bool: return bet.holder_id == bot1, 3.0)
		me().rotation.y = PI * 0.5
		me().teleport(Vector3(Rules.GAMBLE_POS.x + 1.9, 0.1, Rules.GAMBLE_POS.z))
		await wait(0.3)
		Session.request_gamble.rpc_id(1)
	check("everyone sees the scrap go into the machine", await until(func() -> bool: return bet.locked and bet.holder_id == 0, 5.0))
	check("everyone sees the reels spin", await until(func() -> bool: return "spin" in _effects, 3.0))
	check("everyone sees the win", await until(func() -> bool: return bet.value == stake * 2 and not bet.locked, 6.0))
	check("everyone hears the win", await until(func() -> bool: return "win" in _effects, 3.0))
	await barrier("gambled", 4)


# --- The crew's gear, against every kind of creature --------------------------------

## Hands this player a piece of gear straight from the rack.
const FACE_OFF_Z := 3.0


func _give(kind: String) -> Scrap:
	Session._spawn_gear(kind)
	var given: Scrap = Session.scrap_root.get_node("Scrap%d" % (Session._next_gear_id - 1))
	for other in Session.items_held_by(Net.my_id()):
		other.stowed = true
	given.holder_id = Net.my_id()
	given.stowed = false
	return given


func _use_gear() -> void:
	await wait(1.0) # Longer than any piece of gear needs between uses.
	Session.request_use_item.rpc_id(1)
	await get_tree().physics_frame
	await get_tree().physics_frame


## Stands this player in the entry room, facing the ship, with `entity` this far ahead
## (negative is behind). Everything stays inside the room, clear of its walls.
func _face_off(entity: Entity, ahead: float, sideways: float = 0.0) -> void:
	me().rotation.y = 0.0
	me().teleport(Vector3(0, 0.1, FACE_OFF_Z))
	entity.position = Vector3(sideways, entity.position.y, FACE_OFF_Z - ahead)
	entity.net_pos = entity.position
	entity._stun_timer = 0.0
	entity.net_stunned = false
	await get_tree().physics_frame
	await get_tree().physics_frame


func _all(kind: String) -> Array[Entity]:
	var found: Array[Entity] = []
	for entity: Entity in Session.entity_root.get_children():
		if entity.kind == kind:
			found.append(entity)
	return found


func _gear() -> void:
	check("host opens", Net.host("Host", port) == OK)
	Session.entities_enabled = false
	Session.forced_maps = ["foundry"]
	Session.results_seconds = 0.7
	Session.goal_override = 5000
	Session.open_ship()
	check("hosting opens the ship in orbit", await until(func() -> bool: return Session.phase == Session.Phase.ORBIT and me() != null, 3.0))
	check("a run starts with credits to spend", Session.credits == Rules.STARTING_CREDITS)
	check("orbit is the ship on its own", Session.level != null and Session.layout == null and Session.entity_root.get_child_count() == 0)
	check("the crew starts with no gear", Session.gear_count() == 0)
	check("the clock doesn't run in orbit", Session.time_left == 0.0)
	await wait(0.1)

	# Buying.
	Session.request_buy.rpc_id(1, Tools.SHOVEL)
	check("gear can only be bought at the terminal", Session.credits == 60 and Session.gear_count() == 0)
	me().teleport(Rules.TERMINAL_POS + Vector3(-1.2, 0.1, 0))
	await wait(0.1)
	Session.request_buy.rpc_id(1, "Gold bar")
	check("made-up gear can't be bought", Session.credits == 60 and Session.gear_count() == 0)
	Session.request_buy.rpc_id(1, Tools.SHOVEL)
	check("a shovel costs its price", Session.credits == 30 and Session.gear_count() == 1 and _shop_reply.contains("bought"))
	Session.request_buy.rpc_id(1, Tools.STUN_GRENADE)
	check("so does a stun grenade", Session.credits == 5 and Session.gear_count() == 2)
	Session.request_buy.rpc_id(1, Tools.ZAP_GUN)
	check("gear the crew can't afford is refused", Session.credits == 5 and Session.gear_count() == 2 and _shop_reply.begins_with("Not enough credits"))
	var on_rack := true
	for bought: Scrap in Session.scrap_root.get_children():
		on_rack = on_rack and Rules.in_ship(bought.position) and bought.holder_id == 0
	check("bought gear waits in the ship", on_rack)
	check("gear has no sale value", Session._ship_value() == 0)
	Session.credits = 10000
	for attempt in Rules.TOOL_LIMIT + 2:
		Session.request_buy.rpc_id(1, Tools.STUN_GRENADE)
	check("the crew can't own more gear than the limit", Session.gear_count() == Rules.TOOL_LIMIT and _shop_reply.contains("limit"))
	var spots := {}
	for bought: Scrap in Session.scrap_root.get_children():
		spots[Vector2(snappedf(bought.position.x, 0.01), snappedf(bought.position.z, 0.01))] = true
	check("each piece of gear has its own spot", spots.size() == Rules.TOOL_LIMIT)
	for extra: Scrap in Session.scrap_root.get_children():
		if extra.kind == Tools.STUN_GRENADE and extra != gear(Tools.STUN_GRENADE):
			Session.scrap_root.remove_child(extra)
			extra.queue_free()
	Session.credits = 5

	# Landing with gear in hand.
	var shovel := gear(Tools.SHOVEL)
	me().teleport(Vector3(shovel.position.x, 0.1, shovel.position.z))
	await wait(0.1)
	Session.request_pickup.rpc_id(1, shovel.item_id)
	check("gear can be picked up in orbit", shovel.holder_id == 1)
	Session.request_launch.rpc_id(1)
	check("the ship can't be landed from across the room", Session.phase == Session.Phase.ORBIT)
	me().teleport(Rules.CONSOLE_POS + Vector3(0, 0.1, 1.5))
	await wait(0.1)
	Session.request_launch.rpc_id(1)
	check("the console lands the ship", await until(func() -> bool: return Session.phase == Session.Phase.PLAYING, 3.0))
	check("gear in hand lands with you", is_instance_valid(shovel) and shovel.holder_id == 1 and shovel.get_parent() == Session.scrap_root)
	check("gear left on the rack is still in the ship", gear(Tools.STUN_GRENADE) != null and Rules.in_ship(gear(Tools.STUN_GRENADE).position))
	check("scrap appears beside the gear", item(1) != null and not item(1).is_tool())
	me().teleport(Vector3(0, 0.1, -9.0))
	await wait(0.1)
	check("the prompt says how to use the shovel", me().interact_prompt.begins_with("Left click: swing the shovel"))

	# THE SHOVEL, against the Stalker.
	_park_everything()
	var stalker := Session.entity_of_kind("stalker")
	var full := stalker.hits_left()
	await _face_off(stalker, 1.8)
	await _use_gear()
	check("a shovel hit stuns the Stalker", stalker.net_stunned and stalker.hits_left() == full - 1)
	check("the hit is heard", "bonk" in _effects and "swing" in _effects)
	await _face_off(stalker, 3.4)
	await _use_gear()
	check("a shovel only reaches arm's length", stalker.hits_left() == full - 1 and not stalker.net_stunned)
	await _face_off(stalker, -1.0)
	await _use_gear()
	check("a shovel only hits what's in front of you", stalker.hits_left() == full - 1)
	await _face_off(stalker, 1.8)
	await wait(1.0)
	for press in 3:
		Session.request_use_item.rpc_id(1)
	await get_tree().physics_frame
	for press in 3:
		Session.request_use_item.rpc_id(1)
		await get_tree().physics_frame
	check("mashing the button only swings once", stalker.hits_left() == full - 2)
	while is_instance_valid(stalker) and stalker.get_parent() != null and stalker.hits_left() > 0:
		await _use_gear()
	check("enough hits finish off the Stalker", Session.entity_of_kind("stalker") == null and "kill" in _effects)

	# A Mimic goes down in one, and helpers are never hit.
	var mimic := Session.entity_of_kind("mimic")
	await _face_off(mimic, 1.8)
	await _use_gear()
	check("one shovel hit finishes a Mimic", not is_instance_valid(mimic) or mimic.get_parent() == null)
	var sentinel := Session.entity_of_kind("sentinel")
	var bonks := _effects.count("bonk")
	await _face_off(sentinel, 1.8)
	await _use_gear()
	check("the shovel never hits a friendly helper", _effects.count("bonk") == bonks and sentinel.get_parent() == Session.entity_root)
	_park_everything()

	# A crewmate in the way gets bonked. Peer 999 stands in for them.
	Session.player_states[999] = {"hp": 100, "alive": true}
	var crewmate: Player = Session._spawn_player({"peer": 999, "name": "Crewmate", "index": 1, "pos": Vector3(0, 0, FACE_OFF_Z - 1.5)})
	Session.players_root.add_child(crewmate)
	me().rotation.y = 0.0
	me().teleport(Vector3(0, 0.1, FACE_OFF_Z))
	await _use_gear()
	check("a shovel bonks a crewmate in front of you", Session.player_states[999].hp == 100 - Tools.SHOVEL_CREW_DAMAGE)
	Session.players_root.remove_child(crewmate)
	crewmate.queue_free()
	Session.player_states.erase(999)

	# Tougher levels make tougher hunters; helpers stay the same.
	Session.level_number = 8
	await _fresh_round("foundry")
	var strong := Session.entity_of_kind("stalker")
	check("a level 8 Stalker takes more shovel hits", strong.max_hits() == Entity.INFO.stalker.hits + 2)
	check("a level 8 Mimic still goes down in one", Session.entity_of_kind("mimic").max_hits() == 1)
	strong.stun(1.0)
	check("a level 8 hunter shakes off stuns sooner", is_equal_approx(strong._stun_timer, 0.65))
	strong.net_stunned = false
	strong._stun_timer = 0.0
	check("helpers don't change with the level", Session.entity_of_kind("sentinel")._power.speed == 1.0)
	me().rotation.y = 0.0
	me().teleport(Vector3(0, 0.1, FACE_OFF_Z))
	await get_tree().physics_frame
	_wake(strong, Vector3(0, 0, FACE_OFF_Z - 1.0))
	check("a level 8 Stalker hits harder", await until(func() -> bool: return _hp() < Rules.PLAYER_MAX_HP, 3.0) and Rules.PLAYER_MAX_HP - _hp() == roundi(Rules.MONSTER_DAMAGE * Rules.threat_power(8).damage))
	strong.enabled = false
	Session.level_number = 1

	# THE ZAP GUN, against the Watcher.
	await _fresh_round("cryo")
	var stone := _give(Tools.SHOVEL)
	var statue := Session.entity_of_kind("watcher")
	await _face_off(statue, 1.8)
	await _use_gear()
	check("nothing can hurt a Watcher", statue.get_parent() == Session.entity_root and statue.hits_left() == 0)
	Session.scrap_root.remove_child(stone)
	stone.queue_free()
	var zap := _give(Tools.ZAP_GUN)
	check("a zap gun comes charged", zap.charges == Tools.CATALOG[Tools.ZAP_GUN].charges)
	var watcher := Session.entity_of_kind("watcher")
	await _face_off(watcher, 7.0)
	await _use_gear()
	check("a zap freezes the hunter you aim at", watcher.net_stunned and zap.charges == 2 and "zap" in _effects)
	await _use_gear()
	check("an already-frozen hunter isn't zapped again", zap.charges == 2)
	await _face_off(watcher, 4.0, 4.0)
	await _use_gear()
	check("a zap that misses costs nothing", not watcher.net_stunned and zap.charges == 2 and "fizzle" in _effects)
	var wall := _find_wall()
	if not wall.is_empty():
		me().rotation.y = -PI * 0.5
		me().teleport(FacilityLayout.cell_center(wall[0]) + Vector3(0, 0.1, 0))
		watcher.position = FacilityLayout.cell_center(wall[1])
		watcher.net_pos = watcher.position
		await get_tree().physics_frame
		await _use_gear()
		check("a zap can't go through walls", not watcher.net_stunned and zap.charges == 2)
	await _face_off(watcher, 7.0)
	await _use_gear()
	await _face_off(watcher, 7.0)
	await _use_gear()
	check("each zap uses a charge", zap.charges == 0)
	await _face_off(watcher, 7.0)
	await _use_gear()
	check("an empty zap gun does nothing", not watcher.net_stunned and "empty" in _effects)
	check("the HUD says it's empty", me().interact_prompt.contains("empty"))

	# THE STUN GRENADE, against the Listeners.
	await _fresh_round("reactor")
	var grenade := _give(Tools.STUN_GRENADE)
	var listeners := _all("listener")
	await _face_off(listeners[0], 6.0)
	listeners[1].position = Vector3(0, listeners[1].position.y, FACE_OFF_Z - 22.0)
	listeners[1].net_pos = listeners[1].position
	await _use_gear()
	check("a thrown grenade leaves your hands", grenade.holder_id == 0 and grenade.armed and Session.item_held_by(1) == null)
	Session.request_pickup.rpc_id(1, grenade.item_id)
	check("a live grenade can't be picked up", grenade.holder_id == 0)
	await wait(0.6)
	check("the grenade lands ahead of you", grenade.position.distance_to(Vector3(0, Scrap.FLOOR_HEIGHT, FACE_OFF_Z - Tools.THROW_DISTANCE)) < 0.3)
	check("nothing is stunned before the bang", not listeners[0].net_stunned)
	check("the bang comes after the fuse", await until(func() -> bool: return gear(Tools.STUN_GRENADE) == null, 3.0))
	await get_tree().physics_frame # Each player's view of the bang is checked on the next physics step.
	check("the bang stuns a hunter nearby", listeners[0].net_stunned)
	check("hunters out of range aren't stunned", not listeners[1].net_stunned)
	check("the grenade is used up", gear(Tools.STUN_GRENADE) == null and "boom" in _effects)
	check("looking at the bang blinds you", Session.blind_seconds > 1.0)
	wall = _find_wall()
	if not wall.is_empty():
		_give(Tools.STUN_GRENADE)
		var near := listeners[0]
		var behind := listeners[1]
		for entity: Entity in [near, behind]:
			entity._stun_timer = 0.0
			entity.net_stunned = false
		me().rotation.y = -PI * 0.5
		me().teleport(FacilityLayout.cell_center(wall[0]) + Vector3(-3.0, 0.1, 0))
		near.position = FacilityLayout.cell_center(wall[0]) + Vector3(1.0, 0, 2.0)
		behind.position = FacilityLayout.cell_center(wall[1]) + Vector3(-1.5, 0, 0)
		for entity: Entity in [near, behind]:
			entity.position.y = 0.0
			entity.net_pos = entity.position
		await _use_gear()
		await until(func() -> bool: return gear(Tools.STUN_GRENADE) == null, 3.0)
		check("a grenade stuns hunters on its side of a wall", near.net_stunned)
		check("a wall shields hunters from the bang", not behind.net_stunned)

	# Vents can't be fought.
	await _fresh_round("biolab")
	_give(Tools.SHOVEL)
	var vent := Session.entity_of_kind("gas")
	var bonked := _effects.count("bonk")
	await _face_off(vent, 1.5)
	await _use_gear()
	check("a shovel does nothing to a gas vent", _effects.count("bonk") == bonked and vent.get_parent() == Session.entity_root)

	# Gear left in the ship is kept for tomorrow; gear left outside is lost.
	await _fresh_round("foundry")
	var lost := _give(Tools.STUN_GRENADE)
	me().teleport(Vector3(0, 0.1, 2.0))
	await wait(0.1)
	Session.request_drop.rpc_id(1)
	check("gear can be left outside", lost.holder_id == 0 and not Rules.in_ship(lost.position))
	var kept := _give(Tools.SHOVEL)
	me().teleport(Vector3(1.0, 0.1, -9.0))
	await wait(0.1)
	Session.request_drop.rpc_id(1)
	var used := _give(Tools.ZAP_GUN)
	used.charges = 0
	var banked: Scrap = item(1)
	banked.position = Vector3(-1.0, Scrap.FLOOR_HEIGHT, -9.0)
	var credits_before := Session.credits
	await wait(0.1)
	Session._end_round()
	check("the results count the gear kept", Session.last_results.gear_kept == 2)
	check("banked scrap becomes credits", Session.credits == credits_before + banked.value)
	check("the ship goes back to orbit after the day", await until(func() -> bool: return Session.phase == Session.Phase.ORBIT, 5.0))
	check("gear left in the ship is back on the rack", gear(Tools.SHOVEL) != null and gear(Tools.ZAP_GUN) != null)
	check("gear left outside is gone", gear(Tools.STUN_GRENADE) == null and Session.gear_count() == 2)
	check("the zap gun is recharged in orbit", gear(Tools.ZAP_GUN).charges == Tools.CATALOG[Tools.ZAP_GUN].charges)
	check("nobody holds anything in orbit until they pick it up", Session.items_held_by(1).is_empty())

	# A run that ends takes everything with it.
	Session.day = Session.days_per_level
	Session.start_run()
	await until(func() -> bool: return Session.phase == Session.Phase.PLAYING, 3.0)
	await wait(0.1)
	Session._end_round()
	check("the last day's failure ends the run", Session.phase == Session.Phase.GAME_OVER)
	check("a new run starts in orbit", await until(func() -> bool: return Session.phase == Session.Phase.ORBIT, 5.0))
	check("a new run has fresh credits and no gear", Session.credits == Rules.STARTING_CREDITS and Session.gear_count() == 0)
	Net.leave()


# --- Scrap Slots: put scrap in, lose it or win big ----------------------------------

func _slots() -> void:
	check("host opens", Net.host("Host", port) == OK)
	Session.entities_enabled = false
	Session.forced_maps = ["foundry"]
	Session.goal_override = 5000
	Session.results_seconds = 0.7
	Session.open_ship()
	await until(func() -> bool: return Session.phase == Session.Phase.ORBIT and me() != null, 3.0)
	check("Scrap Slots is in the ship", Session.level.gamble_station != null and Rules.in_ship(Rules.GAMBLE_POS) and Rules.in_ship(Session.gamble_tray()))
	var at_machine := Vector3(Rules.GAMBLE_POS.x + 1.9, 0.1, Rules.GAMBLE_POS.z)
	me().rotation.y = PI * 0.5
	me().teleport(at_machine)
	await wait(0.1)
	check("in orbit the machine asks for scrap from the facility", me().interact_prompt.contains("bring scrap back"))
	Session.start_run()
	await until(func() -> bool: return Session.phase == Session.Phase.PLAYING, 3.0)
	await wait(0.1)
	check("the machine is in the ship on the ground too", Session.level.gamble_station != null)
	check("with empty hands it says what it wants", me().interact_prompt.contains("hold a piece of scrap"))

	# Too far away, nothing happens.
	var bet := item(1)
	var stake := bet.value
	bet.holder_id = 1
	me().teleport(Vector3(0, 0.1, -12.0))
	await wait(0.1)
	Session.request_gamble.rpc_id(1)
	check("you can't gamble from across the ship", bet.holder_id == 1 and not bet.locked)
	me().rotation.y = PI * 0.5
	me().teleport(at_machine)
	await wait(0.1)
	check("the machine offers the bet", me().interact_prompt.begins_with("E: gamble %s" % bet.kind))

	# A x2 win.
	Session.gamble_rig = 2
	var started := Time.get_ticks_msec()
	Session.request_gamble.rpc_id(1)
	check("the machine takes the scrap from your hands", bet.holder_id == 0 and bet.locked and Session.item_held_by(1) == null)
	check("the scrap waits on the machine's tray", bet.position.distance_to(Session.gamble_tray()) < 0.01)
	check("the reels spin", "spin" in _effects and Session.level.gamble_station.is_spinning())
	Session.request_pickup.rpc_id(1, bet.item_id)
	check("scrap in the machine can't be grabbed back", bet.holder_id == 0 and bet.locked)
	var second := item(2)
	second.holder_id = 1
	Session.request_gamble.rpc_id(1)
	check("one bet at a time", second.holder_id == 1 and not second.locked)
	await wait(0.2)
	check("the prompt says it's busy", me().interact_prompt.contains("spinning"))
	check("the result waits for the spin", bet.value == stake)
	await until(func() -> bool: return not bet.locked, 5.0)
	var seconds := (Time.get_ticks_msec() - started) / 1000.0
	check("a spin takes about %.1f seconds (%.2f)" % [Rules.GAMBLE_SECONDS, seconds], seconds > Rules.GAMBLE_SECONDS - 0.1 and seconds < Rules.GAMBLE_SECONDS + 0.5)
	check("a win multiplies the scrap's value", bet.value == stake * 2 and "win" in _effects)
	check("winnings come back out on the tray, in the ship", Rules.in_ship(bet.position) and bet.get_parent() == Session.scrap_root)
	check("winnings count toward the goal", Session._ship_value() >= bet.value)
	await wait(0.1)
	check("the won scrap can be picked up", me().interact_prompt.contains("pick up %s" % bet.kind))

	# A bust.
	Session.gamble_rig = 0
	Session.request_gamble.rpc_id(1)
	check("a bust destroys the scrap", await until(func() -> bool: return item(2) == null, 5.0) and "bust" in _effects)

	# A jackpot, and the ceiling on value.
	Session.gamble_rig = 4
	Session.request_pickup.rpc_id(1, bet.item_id)
	var doubled := bet.value
	Session.request_gamble.rpc_id(1)
	await until(func() -> bool: return not bet.locked, 5.0)
	check("a jackpot pays six times", bet.value == mini(doubled * 6, Rules.GAMBLE_MAX_VALUE) and "jackpot" in _effects)
	bet.value = 5000
	Session.request_pickup.rpc_id(1, bet.item_id)
	Session.request_gamble.rpc_id(1)
	await until(func() -> bool: return not bet.locked, 5.0)
	check("no scrap can be worth more than $%d" % Rules.GAMBLE_MAX_VALUE, bet.value == Rules.GAMBLE_MAX_VALUE)

	# Gear isn't accepted. (The scrap on the tray moves aside, so its pick-up prompt doesn't win.)
	bet.position = Vector3(0, Scrap.FLOOR_HEIGHT, -12.0)
	var shovel := _give(Tools.SHOVEL)
	await wait(0.1)
	check("the machine says it only takes scrap", me().interact_prompt.contains("only takes scrap"))
	Session.request_gamble.rpc_id(1)
	check("gear can't be gambled", shovel.holder_id == 1 and not shovel.locked)

	# The real odds, over many spins.
	Session.gamble_rig = -1
	var busts := 0
	var paid := 0.0
	var spins := 20000
	var seen := {}
	for spin in spins:
		var multiplier := Session._roll_gamble()
		seen[multiplier] = true
		paid += multiplier
		if multiplier == 0.0:
			busts += 1
	check("about half of all bets bust (%.3f)" % (float(busts) / spins), absf(float(busts) / spins - 0.5) < 0.02)
	check("bets break even over many spins (%.3f)" % (paid / spins), absf(paid / spins - 1.0) < 0.06)
	check("every outcome really happens", seen.size() == Rules.GAMBLE_TABLE.size())

	# The day ending mid-spin breaks nothing.
	var last := item(3)
	last.holder_id = 1
	for other in Session.items_held_by(1):
		other.stowed = other != last
	Session.request_gamble.rpc_id(1)
	check("a bet can start right before take-off", last.locked)
	Session._end_round()
	check("the day ends cleanly mid-spin", Session.phase == Session.Phase.RESULTS)
	check("the ship returns to orbit afterwards", await until(func() -> bool: return Session.phase == Session.Phase.ORBIT, 5.0))
	check("the machine is idle again in orbit", not Session.level.gamble_station.is_spinning() and not Session.gamble_busy())
	Net.leave()


# --- The camcorder: one player films, another picks it up and watches --------------

func _tape() -> void:
	check("host opens", Net.host("Host", port) == OK)
	Session.entities_enabled = false
	Session.forced_maps = ["foundry"]
	Session.goal_override = 5000
	Session.results_seconds = 0.7
	Session.open_ship()
	check("a friend joins to share the camcorder", await until(func() -> bool: return Net.players.size() == 2 and Session.players_root.get_child_count() == 2, 30.0))
	var friend := peer_named("Client")
	me().teleport(Rules.TERMINAL_POS + Vector3(-1.2, 0.1, 0))
	await wait(0.1)
	Session.request_buy.rpc_id(1, Tools.CAMCORDER)
	var camcorder := gear(Tools.CAMCORDER)
	check("a camcorder can be bought", camcorder != null and Session.credits == Rules.STARTING_CREDITS - Tools.CATALOG[Tools.CAMCORDER].price)
	check("a new camcorder is empty", camcorder.recordings == 0 and camcorder.describe() == "Camcorder (0/12 saved)")
	camcorder.holder_id = friend
	await barrier("given", 2)

	# The friend films, watches, then puts it down (see _tape_client).
	await barrier("filmed", 2)
	var tape: Array = Session._tapes.get(camcorder.item_id, [])
	check("the host keeps the friend's photo and clip", tape.size() == 2 and tape[0].kind == "photo" and tape[1].kind == "clip")
	if tape.size() == 2:
		var clip: Dictionary = tape[1]
		var rate: float = clip.frames.size() / clip.length
		check("a clip keeps about %d pictures a second (%.1f)" % [Tools.CLIP_FPS, rate], absf(rate - Tools.CLIP_FPS) < 2.5)
		check("footage remembers who filmed it", clip.by == "Client" and tape[0].by == "Client")
	check("the friend put the camcorder down", camcorder.holder_id == 0)

	# The host picks it up and watches what the friend filmed.
	me().teleport(Vector3(camcorder.position.x, 0.1, camcorder.position.z))
	await wait(0.1)
	Session.request_pickup.rpc_id(1, camcorder.item_id)
	check("someone else can pick it up", camcorder.holder_id == 1)
	var cam := me().camcorder
	cam.open_viewer()
	check("they can watch the friend's footage", await until(func() -> bool: return cam.list_ready and cam.current_texture() != null, 5.0))
	check("all of it, starting with the newest", cam.listing.size() == 2 and cam.current().kind == "clip" and cam.current().by == "Client")
	cam.close_viewer()
	await barrier("host_has_it", 2)
	await barrier("friend_refused", 2)

	# Twelve recordings at most: then the oldest is recorded over.
	for shot in Tools.TAPE_LIMIT - 1:
		var replies := _tape_messages.size()
		cam.take_photo()
		await until(func() -> bool: return _tape_messages.size() > replies, 3.0)
	tape = Session._tapes.get(camcorder.item_id, [])
	check("a camcorder holds %d recordings" % Tools.TAPE_LIMIT, camcorder.recordings == Tools.TAPE_LIMIT and tape.size() == Tools.TAPE_LIMIT)
	check("a full camcorder records over the oldest", tape[0].kind == "clip" and _tape_messages.back().contains("12/12") and _tape_messages.back().contains("recorded over"))
	var uids: Array = tape.map(func(entry: Dictionary) -> int: return entry.uid)

	# Footage brought home is kept for tomorrow.
	Session.start_run()
	await until(func() -> bool: return Session.phase == Session.Phase.PLAYING, 3.0)
	check("the camcorder lands in your hands", is_instance_valid(camcorder) and camcorder.holder_id == 1)
	me().teleport(Vector3(0, 0.1, -9.0))
	await wait(0.1)
	Session._end_round()
	await until(func() -> bool: return Session.phase == Session.Phase.ORBIT, 5.0)
	var kept := gear(Tools.CAMCORDER)
	check("a camcorder brought home keeps its footage", kept != null and kept.recordings == Tools.TAPE_LIMIT and Session._tapes.get(kept.item_id, []).map(func(entry: Dictionary) -> int: return entry.uid) == uids)
	await barrier("home", 2)

	# Left outside, it's gone, and its footage with it.
	me().teleport(Vector3(kept.position.x, 0.1, kept.position.z))
	await wait(0.1)
	Session.request_pickup.rpc_id(1, kept.item_id)
	Session.start_run()
	await until(func() -> bool: return Session.phase == Session.Phase.PLAYING, 3.0)
	me().teleport(Vector3(0, 0.1, 2.0))
	await wait(0.1)
	Session.request_drop.rpc_id(1)
	Session._end_round()
	await until(func() -> bool: return Session.phase == Session.Phase.ORBIT, 5.0)
	check("a camcorder left outside is lost, footage and all", gear(Tools.CAMCORDER) == null and Session._tapes.is_empty())
	await barrier("done", 2)
	Net.leave()


func _tape_client() -> void:
	check("a friend can join", Net.join("Client", "127.0.0.1", port) == OK)
	await until(func() -> bool: return Session.phase == Session.Phase.ORBIT and me() != null, 30.0)
	await barrier("given", 2)
	check("the camcorder is in the friend's hands", await until(func() -> bool: return gear(Tools.CAMCORDER) != null and gear(Tools.CAMCORDER).holder_id == Net.my_id(), 5.0))
	var camcorder := gear(Tools.CAMCORDER)
	var cam := me().camcorder
	await wait(0.1)
	check("the prompt explains the camcorder", me().interact_prompt.contains("photo") and me().interact_prompt.contains("record a clip") and me().interact_prompt.contains("watch (0 saved)"))

	# Filming.
	cam.take_photo()
	check("a photo is saved on the camcorder", await until(func() -> bool: return camcorder.recordings == 1 and not _tape_messages.is_empty(), 5.0))
	check("the friend is told it's saved", _tape_messages.back() == "Photo saved on the camcorder (1/12).")
	check("a photo flashes", me().net_flashes == 1)
	cam.start_clip()
	await wait(0.1)
	check("filming lights the red light", cam.is_recording and me().net_recording and camcorder._model.get_node("RecLight").visible)
	check("the prompt says how to stop", me().interact_prompt.contains("stop recording"))
	await wait(1.4)
	cam.stop_clip()
	check("a clip is saved on the camcorder", await until(func() -> bool: return camcorder.recordings == 2, 5.0))
	check("the red light goes off", not me().net_recording)
	cam.start_clip()
	await get_tree().physics_frame
	cam.stop_clip()
	check("a clip that's too short isn't kept", cam.message == "Too short to keep" and camcorder.recordings == 2)

	# Watching.
	cam.open_viewer()
	check("playback opens on the newest recording", await until(func() -> bool: return cam.list_ready and cam.current_texture() != null, 5.0) and cam.current().kind == "clip" and cam.view_index == 1)
	var opening := cam.current_texture()
	await wait(0.4)
	check("a clip plays", cam.current_texture() != null and cam.current_texture() != opening)
	cam.play_time = cam.current().length + Camcorder.END_PAUSE + 0.01
	check("a clip loops", cam.current_texture() == opening)
	cam.show_next(1)
	check("next shows the photo", await until(func() -> bool: return cam.current_texture() != null, 5.0) and cam.current().kind == "photo" and cam.view_index == 0)
	cam.show_next(-1)
	check("going back needs no new download", cam.current_texture() == opening and cam._asked.is_empty())
	await wait(0.1)
	check("the prompt says how to step through", me().interact_prompt.contains("next") and me().interact_prompt.contains("stop watching"))

	# The host refuses footage it shouldn't keep.
	var replies := _tape_messages.size()
	Session.request_store_tape.rpc_id(1, camcorder.item_id, "photo", [PackedByteArray([1, 2, 3, 4])], PackedFloat32Array([0.0]), 0.0)
	check("junk footage is refused", await until(func() -> bool: return _tape_messages.size() > replies, 3.0) and _tape_messages.back().contains("couldn't be saved"))
	var jpeg := Image.create(32, 18, false, Image.FORMAT_RGB8).save_jpg_to_buffer(0.8)
	Session.request_store_tape.rpc_id(1, camcorder.item_id + 1, "photo", [jpeg], PackedFloat32Array([0.0]), 0.0)
	await wait(0.4)
	check("nothing is saved to a camcorder you aren't holding", camcorder.recordings == 2 and _tape_messages.size() == replies + 1)

	# Letting go of it ends playback.
	Session.request_drop.rpc_id(1)
	check("dropping the camcorder stops playback", await until(func() -> bool: return not cam.viewing, 3.0))
	await barrier("filmed", 2)
	await barrier("host_has_it", 2)
	var lists := _tape_lists.size()
	Session.request_tape_list.rpc_id(1, camcorder.item_id)
	Session.request_tape_entry.rpc_id(1, camcorder.item_id, 1)
	await wait(0.5)
	check("only the holder can see what's on it", _tape_lists.size() == lists)
	await barrier("friend_refused", 2)
	await barrier("home", 2)
	check("everyone sees the footage count after the day", gear(Tools.CAMCORDER) != null and gear(Tools.CAMCORDER).recordings == Tools.TAPE_LIMIT)
	await barrier("done", 2)
	check("the friend is told the host left", await until(func() -> bool: return _ended_reason == "The host left the game.", 10.0))



## What a gacha prize is worth on average, in credits.
func _gacha_worth(prize: String) -> float:
	match prize:
		"refund": return Rules.GACHA_REFUND
		"gold": return Rules.GACHA_GOLD
		"jackpot": return Rules.GACHA_JACKPOT
		"gear", "rare":
			var pool: Array[String] = Tools.GACHA_GEAR if prize == "gear" else Tools.GACHA_RARE
			var total := 0.0
			for kind in pool:
				total += Tools.CATALOG[kind].price
			return total / pool.size()
	return 0.0


func _remove_all_gear() -> void:
	for thing: Scrap in Session.scrap_root.get_children():
		if thing.is_tool():
			Session.scrap_root.remove_child(thing)
			thing.queue_free()


## Flat speed this player is moving at right now.
func _speed() -> float:
	return Vector2(me().velocity.x, me().velocity.z).length()


# --- More gear, and the capsule gacha ------------------------------------------------

func _kit() -> void:
	check("host opens", Net.host("Host", port) == OK)
	Session.entities_enabled = false
	Session.forced_maps = ["foundry"]
	Session.goal_override = 5000
	Session.results_seconds = 0.7
	Session.open_ship()
	await until(func() -> bool: return Session.phase == Session.Phase.ORBIT and me() != null, 3.0)
	check("the gacha is in the ship", Session.level.gacha_station != null)

	# The terminal sells all of it.
	Session.credits = 10000
	me().teleport(Rules.TERMINAL_POS + Vector3(-1.2, 0.1, 0))
	await wait(0.1)
	for kind: String in [Tools.SHOTGUN, Tools.FLASHBANG, Tools.ADRENALINE, Tools.SCOOTER, Tools.BEACON]:
		var before := Session.credits
		Session.request_buy.rpc_id(1, kind)
		check("the terminal sells the %s for $%d" % [kind, Tools.CATALOG[kind].price], Session.credits == before - Tools.CATALOG[kind].price and gear(kind) != null)
	_remove_all_gear()
	await wait(0.1)

	# THE GACHA.
	var at_gacha := Vector3(Rules.GACHA_POS.x - 1.9, 0.1, Rules.GACHA_POS.z)
	me().rotation.y = -PI * 0.5
	me().teleport(at_gacha)
	await wait(0.1)
	check("the gacha offers a pull", me().interact_prompt.begins_with("E: pull the gacha for $%d" % Rules.GACHA_PRICE))
	Session.credits = 20
	await wait(0.1)
	check("the gacha says when the crew can't afford it", me().interact_prompt.contains("$%d a pull" % Rules.GACHA_PRICE))
	Session.request_gacha.rpc_id(1)
	check("a pull the crew can't afford is refused", Session.credits == 20 and not Session.gacha_busy() and Session.notice_text.begins_with("Not enough credits"))
	Session.credits = 1000
	me().teleport(Vector3(0, 0.1, -12.0))
	await wait(0.1)
	Session.request_gacha.rpc_id(1)
	check("you can't pull from across the ship", Session.credits == 1000 and not Session.gacha_busy())
	me().teleport(at_gacha)
	await wait(0.1)
	var expected := {"dud": 0, "refund": Rules.GACHA_REFUND, "gold": Rules.GACHA_GOLD, "jackpot": Rules.GACHA_JACKPOT}
	for row_index in Rules.GACHA_TABLE.size():
		var prize: String = Rules.GACHA_TABLE[row_index][1]
		Session.gacha_rig = row_index
		var before := Session.credits
		var gear_before := Session.gear_count()
		var started := Time.get_ticks_msec()
		Session.request_gacha.rpc_id(1)
		Session.request_gacha.rpc_id(1)
		check("%s: a pull costs $%d, once" % [prize, Rules.GACHA_PRICE], Session.credits == before - Rules.GACHA_PRICE and Session.gacha_busy() and "gacha" in _effects)
		if row_index == 0:
			await wait(0.2)
			check("the prompt says the capsule is rolling", me().interact_prompt.contains("rolling"))
		await until(func() -> bool: return not Session.gacha_busy(), 5.0)
		var seconds := (Time.get_ticks_msec() - started) / 1000.0
		check("%s: the capsule rolls for about %.0f seconds (%.2f)" % [prize, Rules.GACHA_SECONDS, seconds], absf(seconds - Rules.GACHA_SECONDS) < 0.4)
		check("%s: everyone sees the result" % prize, ("gacha_" + prize) in _effects)
		if expected.has(prize):
			check("%s: pays $%d" % [prize, expected[prize]], Session.credits == before - Rules.GACHA_PRICE + expected[prize] and Session.gear_count() == gear_before)
		else:
			var won: Scrap = null
			for thing: Scrap in Session.scrap_root.get_children():
				if thing.is_tool() and thing.position.distance_to(Session.gacha_tray()) < 0.01:
					won = thing
			var pool: Array[String] = Tools.GACHA_GEAR if prize == "gear" else Tools.GACHA_RARE
			check("%s: a piece of gear rolls out on the tray" % prize, won != null and won.kind in pool and Session.gear_count() == gear_before + 1 and Session.credits == before - Rules.GACHA_PRICE)
			if won != null:
				won.position = Vector3(0, Scrap.FLOOR_HEIGHT, -12.0) # Out of the way of the prompt.
		if prize == "jackpot":
			check("the whole crew is told about a jackpot", Session.notice_text.contains("JACKPOT") and Session.notice_text.contains("Host won $%d" % Rules.GACHA_JACKPOT))
	# Gear won with the crew's gear already full becomes credits instead.
	while Session.gear_count() < Rules.TOOL_LIMIT:
		Session._spawn_gear(Tools.FLASHBANG)
	Session.gacha_rig = 2
	var full_before := Session.credits
	Session.request_gacha.rpc_id(1)
	await until(func() -> bool: return not Session.gacha_busy(), 5.0)
	check("gear won over the limit is paid out instead", Session.gear_count() == Rules.TOOL_LIMIT and Session.credits > full_before - Rules.GACHA_PRICE)
	_remove_all_gear()
	var pulls := 20000
	var worth := 0.0
	var seen := {}
	Session.gacha_rig = -1
	for pull in pulls:
		var prize := Session._roll_gacha()
		seen[prize] = true
		worth += _gacha_worth(prize)
	check("over many pulls the gacha keeps a little ($%.2f per $%d pull)" % [worth / pulls, Rules.GACHA_PRICE], worth / pulls < Rules.GACHA_PRICE * 1.02 and worth / pulls > Rules.GACHA_PRICE * 0.8)
	check("every gacha prize really comes up", seen.size() == Rules.GACHA_TABLE.size())
	# A pull just before take-off still pays out.
	Session.start_run()
	await until(func() -> bool: return Session.phase == Session.Phase.PLAYING, 3.0)
	me().teleport(at_gacha)
	await wait(0.1)
	Session.gacha_rig = Rules.GACHA_TABLE.size() - 1
	var before_takeoff := Session.credits
	Session.request_gacha.rpc_id(1)
	Session._end_round()
	check("a capsule rolling at take-off still pays out", Session.credits >= before_takeoff - Rules.GACHA_PRICE + Rules.GACHA_JACKPOT and not Session.gacha_busy())
	await until(func() -> bool: return Session.phase == Session.Phase.ORBIT, 5.0)
	Session.gacha_rig = -1

	# THE SHOTGUN.
	await _fresh_round("foundry")
	var gun := _give(Tools.SHOTGUN)
	check("a shotgun comes loaded", gun.charges == 3 and gun.describe() == "Shotgun (3/3)")
	var stalker := Session.entity_of_kind("stalker")
	var full := stalker.hits_left()
	await _face_off(stalker, 6.0)
	await _use_gear()
	check("one blast takes %d hits off the Stalker" % Tools.SHOTGUN_BLOWS, stalker.hits_left() == full - Tools.SHOTGUN_BLOWS and stalker.net_stunned and gun.charges == 2 and "shot" in _effects)
	await _face_off(stalker, 6.0)
	await _use_gear()
	check("a second blast finishes it", Session.entity_of_kind("stalker") == null and gun.charges == 1)
	_park_everything()
	var shots := _effects.count("shot")
	await _use_gear()
	check("a blast that hits nothing still uses a shell", gun.charges == 0 and _effects.count("shot") == shots + 1)
	await _use_gear()
	check("an empty shotgun only clicks", "empty" in _effects and gun.charges == 0)
	await wait(0.1)
	check("the HUD says it's empty", me().interact_prompt.contains("empty until orbit"))
	gun.charges = 3
	Session.player_states[999] = {"hp": 100, "alive": true}
	var crewmate: Player = Session._spawn_player({"peer": 999, "name": "Crewmate", "index": 1, "pos": Vector3(0, 0, FACE_OFF_Z - 5.0)})
	Session.players_root.add_child(crewmate)
	me().rotation.y = 0.0
	me().teleport(Vector3(0, 0.1, FACE_OFF_Z))
	await _use_gear()
	check("a blast hurts a crewmate in the way badly", Session.player_states[999].hp == 100 - Tools.SHOTGUN_CREW_DAMAGE)
	Session.players_root.remove_child(crewmate)
	crewmate.queue_free()
	Session.player_states.erase(999)
	await _fresh_round("cryo")
	gun = _give(Tools.SHOTGUN)
	var watcher := Session.entity_of_kind("watcher")
	await _face_off(watcher, 6.0)
	await _use_gear()
	check("a blast can't kill a Watcher, but it rocks it", watcher.get_parent() == Session.entity_root and watcher.net_stunned)

	# THE FLASHBANG.
	await _fresh_round("reactor")
	_give(Tools.FLASHBANG)
	var listener: Entity = _all("listener")[0]
	await _face_off(listener, 6.0)
	await wait(1.0)
	var thrown_at := Time.get_ticks_msec()
	Session.request_use_item.rpc_id(1)
	check("the flashbang goes off almost at once", await until(func() -> bool: return gear(Tools.FLASHBANG) == null, 3.0) and (Time.get_ticks_msec() - thrown_at) / 1000.0 < Tools.FUSE_SECONDS)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check("it stuns a hunter in sight for %.1f seconds" % Tools.FLASH_STUN, listener.net_stunned and listener._stun_timer > Tools.FLASH_STUN - 0.3 and listener._stun_timer <= Tools.FLASH_STUN)
	check("it blinds you harder than a stun grenade", Session.blind_seconds > Tools.BLIND_SECONDS and "flashbang" in _effects)

	# ADRENALINE.
	await _fresh_round("foundry")
	_give(Tools.ADRENALINE)
	me().rotation.y = 0.0
	me().teleport(Vector3(0, 0.1, 3.0))
	await _use_gear()
	check("the shot is used up and the boost begins", gear(Tools.ADRENALINE) == null and me().boost_left > Tools.ADRENALINE_SECONDS - 0.5 and "inject" in _effects)
	check("the HUD says so", Session.notice_text.begins_with("Adrenaline!"))
	me().bot_move = Vector2(0, -1)
	for frame in 6:
		await get_tree().physics_frame
	check("adrenaline makes you %d%% faster (%.2f m/s)" % [roundi((Tools.ADRENALINE_SPEED - 1.0) * 100.0), _speed()], absf(_speed() - Player.WALK_SPEED * Tools.ADRENALINE_SPEED) < 0.1)
	me().boost_left = 0.0
	for frame in 3:
		await get_tree().physics_frame
	check("and wears off", absf(_speed() - Player.WALK_SPEED) < 0.1)
	me().bot_move = Vector2.ZERO

	# THE HOVER SCOOTER.
	var board := _give(Tools.SCOOTER)
	me().teleport(Vector3(0, 0.1, 3.0))
	await wait(0.1)
	check("the prompt offers a ride", me().interact_prompt.contains("ride the scooter"))
	me().toggle_ride()
	check("you can hop on", me().net_riding)
	me().bot_move = Vector2(0, -1)
	for frame in 6:
		await get_tree().physics_frame
	var ride_speed := Tools.SCOOTER_SPEED * (1.0 - Session.carried_weight(1))
	check("the scooter goes %.1f m/s (%.2f)" % [ride_speed, _speed()], absf(_speed() - ride_speed) < 0.1)
	check("the board is under your feet", Vector2(board.position.x - me().position.x, board.position.z - me().position.z).length() < 0.05)
	me().bot_move = Vector2.ZERO
	me().teleport(Vector3(0, 0.1, 3.0))
	await wait(0.1)
	check("the prompt offers to step off", me().interact_prompt.contains("step off"))
	Session.request_drop.rpc_id(1)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check("dropping the scooter puts you back on your feet", not me().net_riding and board.holder_id == 0)

	# THE RECALL BEACON.
	await _fresh_round("foundry")
	var loot := item(1)
	loot.holder_id = 1
	_give(Tools.BEACON)
	me().teleport(Vector3(0, 0.1, 3.0))
	await _use_gear()
	check("the beacon charges up first", not Rules.in_ship(me().position) and "beacon" in _effects and gear(Tools.BEACON) != null)
	check("then beams you into the ship", await until(func() -> bool: return Rules.in_ship(me().position), 3.0))
	await wait(0.1)
	check("the beacon is used up, and you keep what you carry", gear(Tools.BEACON) == null and loot.holder_id == 1 and not loot.stowed and "teleport" in _effects)
	await wait(1.5)
	_give(Tools.BEACON)
	var fizzles := _effects.count("fizzle")
	await _use_gear()
	check("in the ship the beacon does nothing and isn't used up", gear(Tools.BEACON) != null and _effects.count("fizzle") == fizzles + 1)
	me().teleport(Vector3(0, 0.1, 3.0))
	await wait(1.5)
	await _use_gear()
	Session.request_drop.rpc_id(1)
	await wait(Tools.BEACON_SECONDS + 0.4)
	check("letting go of the beacon while it charges cancels the beam", not Rules.in_ship(me().position) and gear(Tools.BEACON) != null)
	Net.leave()



# --- The Gunner, the Ghost, the Mud Crawler, and things to find ----------------------

func _beasts() -> void:
	check("host opens", Net.host("Host", port) == OK)
	Session.entities_enabled = false
	Session.forced_maps = ["foundry"]
	Session.goal_override = 5000
	Session.results_seconds = 0.7
	Session.start_run()
	await until(func() -> bool: return me() != null, 3.0)
	var room := FacilityLayout.cell_center(FacilityLayout.ENTRY_CELL)

	# THE GUNNER: it aims, then fires. Duck out of sight and it misses.
	await _fresh_round("foundry")
	var gunner := Session.entity_of_kind("gunner") as Gunner
	check("the Rust Foundry has a Gunner", gunner != null)
	me().teleport(room + Vector3(0, 0.1, 3.0))
	_face(false)
	_wake(gunner, room + Vector3(0, 0, -3.0))
	gunner.rotation.y = PI
	var hp := _hp()
	check("the Gunner takes aim when it sees you", await until(func() -> bool: return gunner.net_state == Gunner.AIMING, 2.0))
	check("its red laser shows where it aims", gunner._laser.visible)
	await wait(Gunner.AIM_SECONDS * 0.5)
	check("it gives you a moment before it fires", _hp() == hp)
	check("then it fires, and the shot hurts", await until(func() -> bool: return _hp() < hp, 2.0) and hp - _hp() == roundi(Gunner.DAMAGE * Rules.threat_power(1).damage) and "shot" in _effects)
	check("it lowers the gun to reload", gunner.net_state == 0 and not gunner._laser.visible)
	var wall := _find_wall()
	if not wall.is_empty():
		gunner.position = FacilityLayout.cell_center(wall[0])
		gunner.net_pos = gunner.position
		gunner.rotation.y = -PI * 0.5
		gunner._reload_left = 0.0
		me().teleport(FacilityLayout.cell_center(wall[0]) + Vector3(3.0, 0.1, 0))
		check("it aims again once reloaded", await until(func() -> bool: return gunner.net_state == Gunner.AIMING, 2.0))
		hp = _hp()
		var shots := _effects.count("shot")
		me().teleport(FacilityLayout.cell_center(wall[1]) + Vector3(0, 0.1, 0))
		await until(func() -> bool: return _effects.count("shot") > shots, 3.0)
		check("ducking behind a wall makes it miss", _effects.count("shot") == shots + 1 and _hp() == hp)
	me().teleport(FacilityLayout.cell_center(FacilityLayout.cell_at(gunner.position)) + Vector3(0, 0.1, 2.5))
	gunner._reload_left = 0.0
	gunner.rotation.y = PI
	await until(func() -> bool: return gunner.net_state == Gunner.AIMING, 2.0)
	gunner.stun(1.0)
	check("a stun spoils its aim", gunner.net_state == 0 and not gunner._laser.visible)
	var spot := gunner.position
	for hit in Entity.INFO.gunner.hits:
		gunner.hurt(0.5)
	check("three shovel hits finish a Gunner", Session.entity_of_kind("gunner") == null and "kill" in _effects)
	await get_tree().physics_frame
	var dropped := gear(Tools.SHOTGUN)
	check("it drops its shotgun, with %d shells" % Gunner.SHELLS, dropped != null and dropped.charges == Gunner.SHELLS and Vector2(dropped.position.x - spot.x, dropped.position.z - spot.z).length() < 0.01)

	# THE GHOST: walls don't stop it, light does.
	await _fresh_round("cryo")
	var ghost := Session.entity_of_kind("ghost") as Ghost
	check("the Cryo Vault has a Ghost", ghost != null and absf(ghost.position.y - Ghost.HOVER) < 0.01)
	me().net_flashlight = false
	wall = _find_wall()
	if not wall.is_empty():
		me().teleport(FacilityLayout.cell_center(wall[0]) + Vector3(0, 0.1, 0))
		_wake(ghost, FacilityLayout.cell_center(wall[1]))
		check("a Ghost drifts straight through walls", await until(func() -> bool: return FacilityLayout.cell_at(ghost.position) == wall[0], 6.0))
	else:
		me().teleport(room + Vector3(0, 0.1, 3.0))
		_wake(ghost, room + Vector3(0, 0, -3.0))
	hp = _hp()
	check("its touch hurts", await until(func() -> bool: return _hp() < hp, 6.0) and hp - _hp() == roundi(Ghost.DAMAGE * Rules.threat_power(1).damage))
	check("then it fades and comes back far away", ghost.position.distance_to(me().position) > 12.0 and ghost.grace > 0.0)
	me().teleport(room + Vector3(0, 0.1, 3.0))
	_face(false)
	me().net_flashlight = true
	_wake(ghost, room + Vector3(0, 0, -3.0))
	var start_gap := ghost.position.distance_to(me().position)
	check("your flashlight beam drives it back", await until(func() -> bool: return ghost.net_state == Ghost.FLEEING, 1.0))
	await wait(0.5)
	check("it backs away from the light", ghost.position.distance_to(me().position) > start_gap)
	_face(true)
	await wait(0.6)
	check("look away and it comes again", ghost.net_state == 0 and ghost.position.distance_to(me().position) < start_gap + 3.0)
	me().net_flashlight = false
	_face(false)
	var flare := _give(Tools.FLARE)
	_wake(ghost, room + Vector3(0, 0, -4.5))
	await _use_gear()
	check("a thrown flare burns", flare != null and flare.armed and flare.holder_id == 0)
	await wait(0.6)
	check("a burning flare keeps a Ghost away", ghost.net_state == Ghost.FLEEING)
	Session.request_pickup.rpc_id(1, flare.item_id)
	check("a burning flare can't be picked up", flare.holder_id == 0)
	var booms := _effects.count("boom") + _effects.count("flashbang")
	Session._fuses[flare] = 0.05
	var flare_id := flare.item_id
	check("it burns out without a bang", await until(func() -> bool: return item(flare_id) == null, 2.0) and _effects.count("boom") + _effects.count("flashbang") == booms)
	ghost.hurt(1.0)
	check("nothing can hurt a Ghost", ghost.get_parent() == Session.entity_root)
	me().teleport(Vector3(0, 0.1, -9.0))
	_wake(ghost, room + Vector3(0, 0, -1.0))
	await wait(1.5)
	check("a Ghost never comes into the ship", not Rules.in_ship(ghost.position))
	me().net_flashlight = true

	# THE MUD CRAWLER: slow, but its mud slows you more.
	await _fresh_round("biolab")
	var mud := Session.entity_of_kind("mud") as MudCrawler
	check("the Bio Lab has a Mud Crawler", mud != null)
	me().teleport(room + Vector3(0, 0.1, 3.0))
	_wake(mud, room + Vector3(0, 0, -2.0))
	var gap := mud.position.distance_to(me().position)
	check("it oozes toward you", await until(func() -> bool: return mud.position.distance_to(me().position) < gap - 1.0, 3.0))
	check("it leaves a trail of mud", await until(func() -> bool: return mud.net_trail.size() >= 2, 3.0))
	hp = _hp()
	check("its touch hurts", await until(func() -> bool: return _hp() < hp, 6.0) and hp - _hp() == roundi(MudCrawler.DAMAGE * Rules.threat_power(1).damage))
	mud.enabled = false
	me().teleport(mud.net_trail[0] + Vector3(0, 0.1, 0))
	me().bot_move = Vector2(1, 0)
	for frame in 4:
		await get_tree().physics_frame
	check("mud slows you down (%.2f m/s)" % _speed(), absf(_speed() - Player.WALK_SPEED * MudCrawler.SLOW) < 0.1)
	me().teleport(room + Vector3(-3.0, 0.1, 0.0)) # Clear of the mud, and of the props in the corners.
	for frame in 4:
		await get_tree().physics_frame
	check("out of the mud you're quick again", absf(_speed() - Player.WALK_SPEED) < 0.1)
	me().bot_move = Vector2.ZERO
	for hit in Entity.INFO.mud.hits:
		mud.hurt(0.5)
	check("four shovel hits break up a Mud Crawler", Session.entity_of_kind("mud") == null)

	# THINGS TO FIND.
	await _fresh_round("foundry")
	var found := 0
	for thing: Scrap in Session.scrap_root.get_children():
		if Tools.is_find(thing.kind):
			found += 1
	check("useful items lie around the facility (%d)" % found, found == Session.layout.finds.size() and found > 0)
	check("found items don't count toward the crew's gear limit", Session.gear_count() == 0)
	check("new kinds of scrap appear", Session.scrap_root.get_children().any(func(thing: Scrap) -> bool: return thing.kind in ["Glass valve", "Cargo case", "Conveyor grate", "Piston"]))
	for thing: Scrap in Session.scrap_root.get_children():
		if Tools.is_find(thing.kind):
			Session.scrap_root.remove_child(thing)
			thing.queue_free()
	me().teleport(room + Vector3(0, 0.1, 3.0))
	Session.player_states[1].hp = 40
	_give(Tools.MEDKIT)
	await wait(0.1)
	check("the prompt offers to patch you up", me().interact_prompt.contains("patch yourself up"))
	await _use_gear()
	check("a med kit heals %d" % Tools.MEDKIT_HEAL, _hp() == 40 + Tools.MEDKIT_HEAL and gear(Tools.MEDKIT) == null)
	Session.player_states[1].hp = Rules.PLAYER_MAX_HP
	_give(Tools.MEDKIT)
	await _use_gear()
	check("at full health a med kit isn't wasted", gear(Tools.MEDKIT) != null)
	_give(Tools.SHOTGUN).charges = 0
	_give(Tools.ZAP_GUN).charges = 1
	_give(Tools.BATTERY)
	await _use_gear()
	check("a battery refills every gun you carry", gear(Tools.SHOTGUN).charges == Tools.CATALOG[Tools.SHOTGUN].charges and gear(Tools.ZAP_GUN).charges == Tools.CATALOG[Tools.ZAP_GUN].charges and gear(Tools.BATTERY) == null)
	_give(Tools.BATTERY)
	await _use_gear()
	check("with nothing to refill a battery isn't wasted", gear(Tools.BATTERY) != null)
	var golden: Scrap = null
	for thing: Scrap in Session.scrap_root.get_children():
		if not thing.is_tool():
			golden = thing
			break
	Session.scrap_root.remove_child(golden)
	golden.free()
	Session._scrap_spawner.spawn({"id": 9000, "kind": FacilityLayout.RARE_SCRAP, "value": 200, "weight": 0.08, "pos": room + Vector3(0, Scrap.FLOOR_HEIGHT, 0)})
	check("a golden cog is worth a lot", item(9000) != null and item(9000).describe() == "Golden cog ($200)")
	Net.leave()



# --- Corpses: knocked flying, falling over, and staying put ------------------------

## The corpse lying in the level whose name contains `part`, or null.
func _corpse_of(part: String) -> Corpse:
	if Session.level == null:
		return null
	for child in Session.level.get_children():
		if child is Corpse and child.name.contains(part):
			return child
	return null


func _corpses() -> void:
	check("host opens", Net.host("Host", port) == OK)
	Session.entities_enabled = false
	Session.forced_maps = ["foundry"]
	Session.goal_override = 5000
	Session.results_seconds = 0.7
	Session.start_run()
	await until(func() -> bool: return me() != null, 3.0)
	var room := FacilityLayout.cell_center(FacilityLayout.ENTRY_CELL)

	# A Stalker finished off with a shovel flies away from the swing and falls over.
	await _fresh_round("foundry")
	var stalker := Session.entity_of_kind("stalker")
	var start := room + Vector3(0, 0, -1.0)
	me().rotation.y = 0.0
	me().teleport(room + Vector3(0, 0.1, 1.0))
	_wake(stalker, start)
	stalker.enabled = false
	stalker._hits_taken = stalker.max_hits() - 1
	_give(Tools.SHOVEL)
	await _use_gear()
	check("the Stalker is gone from the hunt", Session.entity_of_kind("stalker") == null)
	var body := _corpse_of("Stalker")
	check("it leaves a corpse", body != null and body.get_child_count() > 0)
	var animator := Assets.find_animation_player(body)
	check("it flails its arms and legs as it flies", animator != null and animator.current_animation == "sprint" and animator.speed_scale > 1.0)
	await wait(0.2)
	check("the blow knocks it high up and away from you (%.1f m up)" % body.position.y, body.position.y > 0.8 and body.position.z < start.z)
	check("it spins head over heels in the air", not body.spin.quaternion.is_equal_approx(Quaternion.IDENTITY))
	check("it lands and lies still", await until(func() -> bool: return body.resting, 5.0) and is_equal_approx(body.position.y, 0.0))
	check("it bounces when it lands (%d)" % body.bounces, body.bounces >= 2)
	check("then it flops over in its death animation", animator.assigned_animation == "die" and is_equal_approx(animator.speed_scale, 1.0))
	var landed := body.position
	var shovel_throw := Vector2(landed.x - start.x, landed.z - start.z).length()
	check("it lands further from you than it stood (%.1f m)" % shovel_throw, landed.z < start.z and shovel_throw > 0.5)
	await wait(1.0)
	check("a corpse stays where it lands", body.position == landed and body.get_parent() == Session.level)

	# A shotgun throws a body much further than a shovel does.
	await _fresh_round("foundry")
	stalker = Session.entity_of_kind("stalker")
	me().rotation.y = 0.0
	me().teleport(room + Vector3(0, 0.1, 4.0))
	_wake(stalker, room + Vector3(0, 0, 2.0))
	stalker.enabled = false
	stalker._hits_taken = stalker.max_hits() - 1
	var shotgun_start := stalker.position
	_give(Tools.SHOTGUN)
	await _use_gear()
	body = _corpse_of("Stalker")
	check("a shotgun kill leaves a corpse too", body != null)
	await until(func() -> bool: return body.resting, 5.0)
	var shotgun_throw := Vector2(body.position.x - shotgun_start.x, body.position.z - shotgun_start.z).length()
	check("a shotgun throws a body further than a shovel (%.1f m vs %.1f m)" % [shotgun_throw, shovel_throw], shotgun_throw > shovel_throw + 1.0)
	check("a flying body never goes through a wall", Session.layout.has_cell(FacilityLayout.cell_at(body.position)) and FacilityLayout.cell_at(body.position) == FacilityLayout.cell_at(shotgun_start) or Rules.in_ship(body.position))

	# The Gunner's corpse doesn't keep its gun: that's dropped for the crew. A Mud
	# Crawler, with nothing to fall over with, tumbles and lands squashed flat.
	await _fresh_round("foundry")
	var gunner := Session.entity_of_kind("gunner")
	_wake(gunner, room + Vector3(0, 0, -2.0))
	gunner.enabled = false
	for hit in gunner.max_hits():
		gunner.hurt(0.1, 1, room + Vector3(0, 0, 2.0))
	body = _corpse_of("Gunner")
	check("a Gunner leaves a corpse without its gun", body != null and gear(Tools.SHOTGUN) != null and body.find_children("Barrel*", "", true, false).is_empty() and not body.find_children("*", "MeshInstance3D", true, false).any(func(mesh: MeshInstance3D) -> bool: return mesh.mesh is CylinderMesh and mesh.mesh.height > 10.0))
	await _fresh_round("biolab")
	var mud := Session.entity_of_kind("mud") as MudCrawler
	_wake(mud, room + Vector3(0, 0, -2.0))
	mud.net_trail = PackedVector3Array([room + Vector3(1, 0, -3)])
	mud.enabled = false
	for hit in mud.max_hits():
		mud.hurt(0.1, 1, room + Vector3(0, 0, 2.0))
	body = _corpse_of("Mud")
	check("a Mud Crawler leaves a corpse, and its mud dries up", body != null and not body.find_children("*", "MeshInstance3D", true, false).any(func(mesh: MeshInstance3D) -> bool: return mesh.top_level))
	check("with no death animation it tumbles, then lands squashed flat", body._shapeless and await until(func() -> bool: return body.resting, 5.0) and body.scale.y < 0.5 and body.rotation.x == 0.0)
	check("no mud slows anyone once it's dead", is_equal_approx(Session.mud_factor(room + Vector3(1, 0, -3)), 1.0))

	# Players: a killing blow knocks the body away from whatever struck it.
	await _fresh_round("foundry")
	Session.player_states[999] = {"hp": 100, "alive": true}
	var crewmate: Player = Session._spawn_player({"peer": 999, "name": "Crewmate", "index": 1, "pos": room + Vector3(0, 0, -1.0)})
	Session.players_root.add_child(crewmate)
	await get_tree().physics_frame
	var stood := crewmate.position
	Session.damage_player(999, 30, room + Vector3(0, 0, 3.0))
	check("a hit that doesn't kill leaves no corpse", crewmate.corpse() == null and crewmate._body.get_parent() == crewmate)
	Session.damage_player(999, 80, room + Vector3(0, 0, 3.0))
	body = crewmate.corpse()
	check("a killed crewmate's body becomes a corpse", body != null and body.is_ancestor_of(crewmate._body))
	check("the body flails as it flies", crewmate._animator.current_animation == "sprint")
	await until(func() -> bool: return body.resting, 5.0)
	check("the body flops over in its death animation", crewmate._animator.assigned_animation == "die")
	check("it's knocked away from the blow", body.position.z < stood.z - 0.5)
	var kept_at := body.position
	crewmate.position = room + Vector3(3, 0, 3)
	await wait(0.3)
	check("the body stays put when the player's spectating somewhere else", body.position == kept_at)
	# A body that slams into something drops near it, rather than flying back.
	var thrown: Player = Session._spawn_player({"peer": 998, "name": "Thrown", "index": 2, "pos": Vector3(0, 0, -11.0)})
	Session.player_states[998] = {"hp": 100, "alive": true}
	Session.players_root.add_child(thrown)
	await get_tree().physics_frame
	Session.damage_player(998, Rules.PLAYER_MAX_HP, Vector3(0, 0, -6.5))
	await until(func() -> bool: return thrown.corpse().resting, 5.0)
	check("a body thrown into the console drops near it (%.1f)" % thrown.corpse().position.z, thrown.corpse().position.z < -11.5 and Rules.in_ship(thrown.corpse().position))
	check("a body hit that hard bonks its head on the ceiling", thrown.corpse().ceiling_hits >= 1)
	Session.players_root.remove_child(thrown)
	thrown.queue_free()
	Session.player_states.erase(998)

	# Your own death: you see your body from a crewmate's view. (Someone else is still
	# alive, so the day doesn't end the moment you fall.)
	Session.player_states[999] = {"hp": 100, "alive": true}
	me().teleport(room + Vector3(0, 0.1, 2.0))
	await get_tree().physics_frame
	Session.damage_player(1, Rules.PLAYER_MAX_HP, room + Vector3(0, 0, 4.0))
	check("your own body becomes a visible corpse", me().corpse() != null and me()._body.visible)
	check("the body lands and stays", await until(func() -> bool: return me().corpse().resting, 5.0))
	Session.players_root.remove_child(crewmate)
	crewmate.queue_free()
	Session.player_states.erase(999)

	# Corpses are cleared away with the facility when the ship leaves.
	Session._end_round()
	check("corpses go with the facility", await until(func() -> bool: return Session.phase == Session.Phase.ORBIT, 5.0) and _corpse_of("") == null)
	Net.leave()
