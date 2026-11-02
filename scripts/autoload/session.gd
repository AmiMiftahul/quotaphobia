extends Node
## The rules of a run. The host decides everything that matters: other players
## ask through request_* calls, and the host checks each request before acting.
##
## A run goes: ORBIT (the crew waits in the ship, buys gear, and friends can join)
## -> PLAYING (the ship has landed) -> RESULTS -> ORBIT again, until the days run
## out (GAME_OVER) and a new run starts in orbit. LOBBY means not in a game yet.

signal phase_changed
signal stats_changed
signal results_ready(data: Dictionary)
signal terminal_requested
signal shop_replied(ok: bool, message: String)
signal effect_played(kind: String, pos: Vector3)
signal tape_saved(message: String)
signal tape_list_received(item_id: int, entries: Array)
signal tape_entry_received(uid: int, frames: Array, times: PackedFloat32Array, length: float)

enum Phase { LOBBY, PLAYING, RESULTS, GAME_OVER, ORBIT }

const DESPAWN_DELAY := 0.5
const HINT_SECONDS := 7.0
const BANNER_SECONDS := 6.0
const HINT_DISTANCE := 13.0
const EFFECT_SECONDS := 0.25

var phase := Phase.LOBBY
var round_number := 0
var quota := 0
var time_left := 0.0
var in_ship_value := 0
var total_scrap := 0
var rounds_cleared := 0 # Levels cleared. The online leaderboard keeps this column name.
var level_number := 1
var day := 1
var days_per_level := Rules.DAYS_PER_LEVEL
var level_banked := 0 # Scrap value banked on earlier days of this level.
var credits := 0 # Shared by the whole crew, and spent at the terminal.
var next_map := "" # Where the ship lands next, shown while in orbit.
var next_site := "" # How big that place is: one of Rules.SITES.
var site := "" # How big today's facility is.
var player_states := {} # peer id -> { "hp": int, "alive": bool }
var last_results := {}
var map_id := ""
var hint_text := ""
var hint_seconds := 0.0
var banner_seconds := 0.0
var blind_seconds := 0.0 # How long this player's screen stays white from a stun grenade.
var notice_text := "" # A short message across the top of this player's screen.
var notice_seconds := 0.0
var layout: FacilityLayout
var level: Level
var players_root: Node3D
var scrap_root: Node3D
var entity_root: Node3D

# Host-side settings; the tests shorten these.
var results_seconds := Rules.RESULTS_SECONDS
var entities_enabled := true
var forced_maps: Array[String] = [] # Tests pick maps instead of the random order.
var forced_site := "" # Tests can pick the site size, too.
var goal_override := 0 # Tests can set a level's goal directly.
var land_automatically := false # Tests can skip waiting in orbit between days.
var gamble_rig := -1 # Tests can pick a row of Rules.GAMBLE_TABLE instead of rolling.
var gacha_rig := -1 # And a row of Rules.GACHA_TABLE.

var _run_seed := 0
var _crew_size := 1
var _results_timer := 0.0
var _despawn_timer := 0.0
var _tick_timer := 0.0
var _player_spawner: MultiplayerSpawner
var _scrap_spawner: MultiplayerSpawner
var _entity_spawner: MultiplayerSpawner
var _hints_seen := {}
var _hint_check_timer := 0.0
var _crew_gear: Array[Dictionary] = [] # Host: gear kept in the ship between days: {kind, tape}.
var _tapes := {} # Host: camcorder id -> its recordings, oldest first.
var _next_tape_uid := 1
var _next_gear_id := Tools.FIRST_ID
var _ready_at := {} # Host: peer -> time (ms) they may use gear again.
var _pending_uses: Array[int] = [] # Host: peers waiting for the next physics step.
var _fuses := {} # Host: armed grenade -> seconds until it goes off.
var _blast_to_check := Vector3.INF # Where a grenade went off, to test against this player's view.
var _blast_kind := "" # Which kind of grenade it was.
var _recalls := {} # Host: peer -> {"left": seconds, "item": their recall beacon}
var _gacha_left := 0.0 # Host: seconds until the capsule being pulled pops out.
var _gacha_peer := 0
var _gamble_item: Scrap # Host: the scrap inside Scrap Slots right now.
var _gamble_left := 0.0


func _ready() -> void:
	players_root = _make_root("Players")
	scrap_root = _make_root("ScrapItems")
	entity_root = _make_root("Entities")
	_player_spawner = _make_spawner("PlayerSpawner", "Players", _spawn_player)
	_scrap_spawner = _make_spawner("ScrapSpawner", "ScrapItems", _spawn_scrap)
	_entity_spawner = _make_spawner("EntitySpawner", "Entities", _spawn_entity)
	Net.peer_left.connect(_on_peer_left)
	Net.connection_ended.connect(_on_connection_ended.unbind(1))


func _make_root(root_name: String) -> Node3D:
	var root := Node3D.new()
	root.name = root_name
	add_child(root)
	return root


func _make_spawner(spawner_name: String, root_name: String, spawn_function: Callable) -> MultiplayerSpawner:
	var spawner := MultiplayerSpawner.new()
	spawner.name = spawner_name
	add_child(spawner)
	spawner.spawn_path = NodePath("../" + root_name)
	spawner.spawn_function = spawn_function
	return spawner


# --- Spawning: these run on every machine with the same data -----------------

func _spawn_player(data: Dictionary) -> Node:
	var player := Player.new()
	player.setup(data.peer, data.name, data.index, data.pos, data.get("skin", ""))
	player.set_multiplayer_authority(data.peer, true)
	return player


func _spawn_scrap(data: Dictionary) -> Node:
	var item := Scrap.new()
	item.setup(data.id, data)
	return item


func _spawn_entity(data: Dictionary) -> Node:
	var entity: Entity
	match data.kind:
		"stalker": entity = Monster.new()
		"watcher": entity = Watcher.new()
		"listener": entity = Listener.new()
		"mimic": entity = Mimic.new()
		"gas": entity = GasVent.new()
		"patch": entity = Patch.new()
		"sentinel": entity = Sentinel.new()
		"wisp": entity = Wisp.new()
		"gunner": entity = Gunner.new()
		"ghost": entity = Ghost.new()
		"mud": entity = MudCrawler.new()
	entity.setup(layout, data)
	return entity


# --- Helpers usable on every machine ---------------------------------------

## True while players are in a world they can walk around: the ship in orbit, or a facility.
func in_world() -> bool:
	return phase == Phase.ORBIT or phase == Phase.PLAYING


func is_player_alive(peer: int) -> bool:
	return player_states.has(peer) and player_states[peer].alive


func player_node(peer: int) -> Player:
	return players_root.get_node_or_null("P%d" % peer) as Player


## The item in this player's hands.
func item_held_by(peer: int) -> Scrap:
	for item: Scrap in scrap_root.get_children():
		if item.holder_id == peer and not item.stowed:
			return item
	return null


## Everything this player carries, hands and backpack, always in the same order.
func items_held_by(peer: int) -> Array[Scrap]:
	var items: Array[Scrap] = []
	for item: Scrap in scrap_root.get_children():
		if item.holder_id == peer:
			items.append(item)
	items.sort_custom(func(a: Scrap, b: Scrap) -> bool: return a.item_id < b.item_id)
	return items


func gear_count() -> int:
	var count := 0
	for item: Scrap in scrap_root.get_children():
		if item.is_tool() and not Tools.is_find(item.kind):
			count += 1
	return count


func entity_of_kind(kind: String) -> Entity:
	for entity: Entity in entity_root.get_children():
		if entity.kind == kind:
			return entity
	return null


func show_hint(kind: String) -> void:
	if _hints_seen.has(kind):
		return
	_hints_seen[kind] = true
	if not Settings.value("hints"):
		return
	hint_text = Entity.INFO[kind].hint
	hint_seconds = HINT_SECONDS
	Sfx.play_2d("hint", -14.0)


## How much a player's load slows them down: 0 is not at all.
func carried_weight(peer: int) -> float:
	var total := 0.0
	for item in items_held_by(peer):
		total += item.weight * (Rules.STOWED_WEIGHT_SHARE if item.stowed else 1.0)
	return minf(total, Rules.MAX_CARRY_SLOWDOWN)


# --- Host: runs, orbit and rounds ----------------------------------------------

## Hosting puts the crew straight into the ship, in orbit, where friends can join.
func open_ship() -> void:
	if not multiplayer.is_server() or phase != Phase.LOBBY:
		return
	_new_run()
	_enter_orbit()


## Lands the ship now. From the lobby this also starts a fresh run.
func start_run() -> void:
	if not multiplayer.is_server():
		return
	if phase == Phase.LOBBY:
		_new_run()
		_begin_round(1)
	elif phase == Phase.ORBIT:
		_begin_round(round_number + 1)


func _new_run() -> void:
	_run_seed = randi()
	_crew_size = Net.players.size()
	round_number = 0
	total_scrap = 0
	rounds_cleared = 0
	level_number = 1
	day = 1
	level_banked = 0
	credits = Rules.STARTING_CREDITS
	_crew_gear = []
	quota = _goal_for_level()


func _goal_for_level() -> int:
	return goal_override if goal_override > 0 else Rules.quota(level_number, Net.players.size())


## The goal follows the crew's size until the level's first scrap is banked.
func _refresh_goal() -> void:
	if day == 1 and level_banked == 0:
		quota = _goal_for_level()


func _map_for_round(number: int) -> String:
	var maps: Array[String] = forced_maps if not forced_maps.is_empty() else MapThemes.order_for_run(_run_seed)
	return maps[(number - 1) % maps.size()]


func _site_for_round(number: int) -> String:
	return forced_site if not forced_site.is_empty() else Rules.site_for_day(_run_seed, number)


func _enter_orbit() -> void:
	_clear_entities()
	_refresh_goal()
	next_map = _map_for_round(round_number + 1)
	next_site = _site_for_round(round_number + 1)
	player_states = {}
	for peer: int in Net.players:
		player_states[peer] = {"hp": Rules.PLAYER_MAX_HP, "alive": true}
	_rpc_enter_orbit.rpc(_run_info())
	_spawn_missing_players()
	# Gear kept from earlier days goes back on the rack, with the zap guns recharged.
	_next_gear_id = Tools.FIRST_ID
	var kept := _crew_gear.duplicate()
	_crew_gear = []
	for gear: Dictionary in kept:
		_spawn_gear(gear.kind, gear.tape)


func _run_info() -> Dictionary:
	return {
		"round": round_number, "level": level_number, "day": day, "days": days_per_level,
		"quota": quota, "banked": level_banked, "credits": credits, "total": total_scrap,
		"cleared": rounds_cleared, "next_map": next_map, "next_site": next_site, "states": player_states,
	}


func _spawn_missing_players() -> void:
	var peers: Array = Net.players.keys()
	peers.sort()
	for index in peers.size():
		var peer: int = peers[index]
		if player_node(peer) != null:
			continue
		var spawn_pos := FacilityLayout.cell_center(FacilityLayout.SHIP_CELL) + Vector3(-1.5 + index, 0.1, 1.0)
		_player_spawner.spawn({"peer": peer, "name": Net.players[peer], "index": index, "pos": spawn_pos, "skin": Net.skins.get(peer, "")})


## A camcorder can come back with the footage it already had. Gear goes on the rack
## unless it's given a spot.
func _spawn_gear(kind: String, tape: Array = [], at: Vector3 = Vector3.INF, charges: int = -1) -> void:
	var slot := _next_gear_id - Tools.FIRST_ID
	var spot := Rules.RACK_POS + Vector3(float(slot / 4 % 3) * 0.7, Scrap.FLOOR_HEIGHT, float(slot % 4) * 0.8)
	if at != Vector3.INF:
		spot = at
	if not tape.is_empty():
		_tapes[_next_gear_id] = tape
	_scrap_spawner.spawn({"id": _next_gear_id, "kind": kind, "value": 0, "weight": Tools.CATALOG[kind].weight, "pos": spot, "charges": Tools.CATALOG[kind].charges if charges < 0 else charges, "recordings": tape.size()})
	_next_gear_id += 1


## Called by Net when someone new joins the crew.
func on_player_joined(peer: int) -> void:
	if not multiplayer.is_server() or phase != Phase.ORBIT:
		return
	player_states[peer] = {"hp": Rules.PLAYER_MAX_HP, "alive": true}
	_refresh_goal()
	_rpc_enter_orbit.rpc_id(peer, _run_info())
	_rpc_run_info.rpc(quota, credits, player_states)
	_spawn_missing_players()


func _begin_round(number: int) -> void:
	_crew_size = maxi(_crew_size, Net.players.size())
	_refresh_goal()
	var states := {}
	for peer: int in Net.players:
		states[peer] = {"hp": Rules.PLAYER_MAX_HP, "alive": true}
	var level_seed: int = hash([_run_seed, number])
	_rpc_load_round.rpc(level_seed, number, quota, states, total_scrap, rounds_cleared, _map_for_round(number), level_number, day, days_per_level, level_banked, _site_for_round(number))
	# The crew lands where they stood in the ship, holding what they picked up in orbit.
	_spawn_missing_players()
	for index in layout.scrap_spawns.size():
		var data: Dictionary = layout.scrap_spawns[index].duplicate()
		data["id"] = index + 1
		_scrap_spawner.spawn(data)
	# Useful things lying around the facility.
	for find: Dictionary in layout.finds:
		_spawn_gear(find.kind, [], find.pos)
	for data: Dictionary in layout.entity_spawns:
		var spawn := data.duplicate()
		spawn["level"] = level_number # Hunters grow stronger with each level.
		_entity_spawner.spawn(spawn)
	for entity: Entity in entity_root.get_children():
		entity.enabled = entities_enabled


func _process(delta: float) -> void:
	blind_seconds = maxf(0.0, blind_seconds - delta)
	notice_seconds = maxf(0.0, notice_seconds - delta)
	if phase == Phase.PLAYING:
		time_left = maxf(0.0, time_left - delta)
		hint_seconds = maxf(0.0, hint_seconds - delta)
		_check_for_new_entities(delta)
	if in_world():
		banner_seconds = maxf(0.0, banner_seconds - delta)
	if not Net.is_online() or not multiplayer.is_server():
		return
	if _gacha_left > 0.0 and in_world():
		_gacha_left -= delta
		if _gacha_left <= 0.0:
			_finish_gacha()
	match phase:
		Phase.PLAYING:
			_tick_recalls(delta)
			_tick_timer -= delta
			if _tick_timer <= 0.0:
				_tick_timer = 1.0
				_rpc_tick.rpc(time_left, _ship_value())
			if _gamble_item != null:
				_gamble_left -= delta
				if _gamble_left <= 0.0:
					_finish_gamble()
			if time_left <= 0.0:
				_end_round()
		Phase.RESULTS, Phase.GAME_OVER:
			if _despawn_timer > 0.0:
				_despawn_timer -= delta
				if _despawn_timer <= 0.0:
					_clear_entities()
			_results_timer -= delta
			if _results_timer <= 0.0:
				if phase == Phase.GAME_OVER:
					_new_run()
				_enter_orbit()
				if land_automatically and round_number > 0:
					_begin_round(round_number + 1)


## Gear is used in the physics step, where walls can be tested.
func _physics_process(delta: float) -> void:
	if _blast_to_check != Vector3.INF:
		_check_blinding(_blast_to_check)
		_blast_to_check = Vector3.INF
	if not Net.is_online() or not multiplayer.is_server():
		return
	var uses := _pending_uses.duplicate()
	_pending_uses.clear()
	for peer: int in uses:
		var node := player_node(peer)
		var item := item_held_by(peer)
		if node != null and item != null and item.is_tool() and is_player_alive(peer) and in_world():
			_ready_at[peer] = Time.get_ticks_msec() + int(Tools.use(node, item) * 1000.0)
	for grenade: Scrap in _fuses.keys():
		if not is_instance_valid(grenade) or not grenade.is_inside_tree():
			_fuses.erase(grenade)
			continue
		_fuses[grenade] -= delta
		if _fuses[grenade] <= 0.0:
			_fuses.erase(grenade)
			if grenade.kind != Tools.FLARE: # A flare just burns out.
				Tools.explode(grenade)
			use_up(grenade)


## The first time you get near each kind, the HUD tells you how to deal with it.
## Mimics are the exception: telling you about one would spoil the surprise.
func _check_for_new_entities(delta: float) -> void:
	_hint_check_timer -= delta
	if _hint_check_timer > 0.0 or hint_seconds > 0.0:
		return
	_hint_check_timer = 0.3
	var me := player_node(Net.my_id())
	if me == null or not is_player_alive(me.peer_id):
		return
	for entity: Entity in entity_root.get_children():
		if entity.kind != "mimic" and not _hints_seen.has(entity.kind) and me.position.distance_to(entity.position) < HINT_DISTANCE:
			show_hint(entity.kind)
			return


func _ship_value() -> int:
	var value := 0
	for item: Scrap in scrap_root.get_children():
		if Rules.in_ship(item.position):
			value += item.value
	return value


func _end_round() -> void:
	# A capsule still rolling pops out before take-off, so nobody loses their pull.
	if _gacha_left > 0.0:
		_finish_gacha()
	var survivors := 0
	for peer: int in player_states:
		var node := player_node(peer)
		if is_player_alive(peer) and node != null and Rules.in_ship(node.net_pos):
			survivors += 1
	# If nobody makes it home, nobody can sell what was collected.
	var collected := _ship_value() if survivors > 0 else 0
	var banked := level_banked + collected
	var cleared := banked >= quota
	credits += collected
	_keep_gear_in_ship()
	var data := {
		"level": level_number,
		"day": day,
		"days": days_per_level,
		"quota": quota,
		"collected": collected,
		"banked": banked,
		"survivors": survivors,
		"cleared": cleared,
		"run_over": not cleared and day >= days_per_level,
		"total_scrap": total_scrap + collected,
		"rounds_cleared": rounds_cleared + (1 if cleared else 0),
		"crew_size": _crew_size,
		"credits": credits,
		"gear_kept": _crew_gear.size(),
	}
	# What the next day will be. Scrap counts toward this level's goal until it's met.
	if cleared:
		level_number += 1
		day = 1
		level_banked = 0
		quota = _goal_for_level()
	else:
		day += 1
		level_banked = banked
	_rpc_results.rpc(data)
	# Everyone stops sending movement now; players are removed once the last
	# updates have landed, so nothing arrives for a node that's already gone.
	_despawn_timer = DESPAWN_DELAY
	_results_timer = maxf(results_seconds, DESPAWN_DELAY + 0.1)


## Gear on the ship's floor, or in the hands of someone who made it back, is kept.
func _keep_gear_in_ship() -> void:
	_crew_gear = []
	for item: Scrap in scrap_root.get_children():
		if not item.is_tool() or item.armed:
			continue
		var kept := Rules.in_ship(item.position)
		if item.holder_id != 0:
			var holder := player_node(item.holder_id)
			kept = holder != null and is_player_alive(item.holder_id) and Rules.in_ship(holder.net_pos)
		if kept:
			_crew_gear.append({"kind": item.kind, "tape": _tapes.get(item.item_id, [])})


func _clear_entities() -> void:
	_fuses.clear()
	_recalls.clear()
	_tapes.clear()
	_gamble_item = null
	for root: Node3D in [players_root, scrap_root, entity_root]:
		for child in root.get_children():
			root.remove_child(child)
			child.queue_free()


func damage_player(peer: int, amount: int) -> void:
	if not multiplayer.is_server() or not is_player_alive(peer):
		return
	var hp: int = player_states[peer].hp - amount
	var alive := hp > 0
	_rpc_player_state.rpc(peer, maxi(hp, 0), alive)
	if not alive:
		_release_all_items(peer)
		_end_round_if_wiped()


func heal_player(peer: int, amount: int) -> void:
	if not multiplayer.is_server() or not is_player_alive(peer):
		return
	_rpc_player_state.rpc(peer, mini(player_states[peer].hp + amount, Rules.PLAYER_MAX_HP), true)


## How much of your speed you keep here: less in a Mud Crawler's mud.
func mud_factor(pos: Vector3) -> float:
	for entity: Entity in entity_root.get_children():
		if entity is MudCrawler and entity.is_muddy(pos):
			return MudCrawler.SLOW
	return 1.0


## Called on the host when the crew's gear finishes something off.
func kill_entity(entity: Entity) -> void:
	if not multiplayer.is_server() or entity.get_parent() != entity_root:
		return
	play_effect("kill", entity.position, entity.position, 0)
	if entity.kind == "gunner":
		# The Gunner's shotgun is left behind, with what shells it had.
		_spawn_gear(Tools.SHOTGUN, [], Vector3(entity.position.x, Scrap.FLOOR_HEIGHT, entity.position.z), Gunner.SHELLS)
	entity_root.remove_child(entity)
	entity.queue_free()


## Host: tells every machine to show and play something that just happened.
func play_effect(kind: String, from: Vector3, to: Vector3, item_id: int) -> void:
	_rpc_effect.rpc(kind, from, to, item_id)


## Host: a stun grenade leaves the thrower's hand, arcs through the air and lands.
func throw_item(peer: int, item: Scrap, land: Vector3) -> void:
	var start := item.position
	_drop_hand_item(peer)
	item.armed = true
	item.position = start
	_fuses[item] = Tools.fuse_for(item.kind)
	play_effect("throw", start, land, item.item_id)
	var arc := func(progress: float) -> void:
		item.position = start.lerp(land, progress) + Vector3(0, sin(progress * PI) * 1.2, 0)
	item.create_tween().tween_method(arc, 0.0, 1.0, 0.5)


## Host: one-use gear is gone once used. The next item in the backpack comes out.
func use_up(item: Scrap) -> void:
	var holder := item.holder_id
	_fuses.erase(item)
	if item.get_parent() == scrap_root:
		scrap_root.remove_child(item)
	item.queue_free()
	if holder != 0 and item_held_by(holder) == null:
		var remaining := items_held_by(holder)
		if not remaining.is_empty():
			remaining[0].stowed = false


## Host: adrenaline for one player. Their own machine moves them, so it gets the boost.
func boost_player(peer: int, seconds: float) -> void:
	_rpc_boost.rpc_id(peer, seconds)


## Host: a recall beacon starts charging. It only works on the ground, outside the ship.
func start_recall(player: Player, item: Scrap) -> void:
	if phase != Phase.PLAYING or Rules.in_ship(player.net_pos) or _recalls.has(player.peer_id):
		play_effect("fizzle", player.net_pos, player.net_pos, item.item_id)
		return
	_recalls[player.peer_id] = {"left": Tools.BEACON_SECONDS, "item": item}
	play_effect("beacon", player.net_pos, player.net_pos, item.item_id)


func _tick_recalls(delta: float) -> void:
	for peer: int in _recalls.keys():
		var recall: Dictionary = _recalls[peer]
		recall.left -= delta
		if recall.left > 0.0:
			continue
		_recalls.erase(peer)
		var item: Scrap = recall.item
		var node := player_node(peer)
		# Dying or letting go of the beacon while it charges cancels the beam.
		if node == null or not is_player_alive(peer) or not is_instance_valid(item) or item.holder_id != peer:
			continue
		play_effect("teleport", node.net_pos, Tools.BEACON_SPOT, 0)
		use_up(item)
		_rpc_recall.rpc_id(peer, Tools.BEACON_SPOT)


## Shows a short message on this player's screen.
func notice(text: String, seconds: float = 3.5) -> void:
	notice_text = text
	notice_seconds = seconds


func _put_on_floor(item: Scrap, at: Vector3) -> void:
	item.holder_id = 0
	item.stowed = false
	item.position = Vector3(at.x, Scrap.FLOOR_HEIGHT, at.z)


## Drops the item in hand, and the next one from the backpack takes its place.
func _drop_hand_item(peer: int) -> void:
	var item := item_held_by(peer)
	if item == null:
		return
	var node := player_node(peer)
	_put_on_floor(item, node.net_pos if node != null else item.position)
	var remaining := items_held_by(peer)
	if not remaining.is_empty():
		remaining[0].stowed = false


## Everything falls in a small ring around the player, so it can all be picked up.
func _release_all_items(peer: int) -> void:
	var items := items_held_by(peer)
	var node := player_node(peer)
	for index in items.size():
		var at: Vector3 = node.net_pos if node != null else items[index].position
		var angle := TAU * index / maxi(items.size(), 1)
		_put_on_floor(items[index], at + Vector3(cos(angle), 0, sin(angle)) * (0.0 if items.size() == 1 else 0.5))


func _end_round_if_wiped() -> void:
	if phase != Phase.PLAYING:
		return
	for peer: int in player_states:
		if is_player_alive(peer):
			return
	_end_round()


func _on_peer_left(peer: int) -> void:
	if not in_world():
		player_states.erase(peer)
		return
	_release_all_items(peer)
	var node := player_node(peer)
	if node != null:
		players_root.remove_child(node)
		node.queue_free()
	player_states.erase(peer)
	_rpc_forget_player.rpc(peer)
	if phase == Phase.ORBIT:
		_refresh_goal()
		_rpc_run_info.rpc(quota, credits, player_states)
	_end_round_if_wiped()


# --- Requests from players. Never trust these: always re-check on the host ---

@rpc("any_peer", "call_local", "reliable")
func request_start() -> void:
	if multiplayer.is_server() and multiplayer.get_remote_sender_id() == 1:
		start_run()


@rpc("any_peer", "call_local", "reliable")
func request_pickup(item_id: int) -> void:
	if not multiplayer.is_server() or not in_world():
		return
	var peer := multiplayer.get_remote_sender_id()
	var node := player_node(peer)
	var item := scrap_root.get_node_or_null("Scrap%d" % item_id) as Scrap
	if node == null or item == null or not is_player_alive(peer):
		return
	var carried := items_held_by(peer)
	if item.holder_id != 0 or item.armed or item.locked or carried.size() >= Rules.CARRY_LIMIT:
		return
	if node.net_pos.distance_to(item.position) > Rules.SERVER_RANGE:
		return
	# What was in your hands goes in the backpack.
	for other in carried:
		other.stowed = true
	item.holder_id = peer
	item.stowed = false


@rpc("any_peer", "call_local", "reliable")
func request_drop() -> void:
	if multiplayer.is_server() and in_world():
		_drop_hand_item(multiplayer.get_remote_sender_id())


## Puts the item in hand away and takes out the next one.
@rpc("any_peer", "call_local", "reliable")
func request_cycle_item() -> void:
	if not multiplayer.is_server() or not in_world():
		return
	var peer := multiplayer.get_remote_sender_id()
	var carried := items_held_by(peer)
	var hand := item_held_by(peer)
	if carried.size() < 2 or hand == null or not is_player_alive(peer):
		return
	var next := carried[(carried.find(hand) + 1) % carried.size()]
	hand.stowed = true
	next.stowed = false


## Swing, zap or throw whatever gear is in your hands.
@rpc("any_peer", "call_local", "reliable")
func request_use_item() -> void:
	if not multiplayer.is_server() or not in_world():
		return
	var peer := multiplayer.get_remote_sender_id()
	if Time.get_ticks_msec() < _ready_at.get(peer, 0) or peer in _pending_uses:
		return
	_pending_uses.append(peer)


## The console: in orbit it lands the ship, on the ground it takes off.
@rpc("any_peer", "call_local", "reliable")
func request_launch() -> void:
	if not multiplayer.is_server() or not in_world():
		return
	var peer := multiplayer.get_remote_sender_id()
	var node := player_node(peer)
	if node == null or not is_player_alive(peer):
		return
	if node.net_pos.distance_to(Rules.CONSOLE_POS) > Rules.SERVER_RANGE:
		return
	if phase == Phase.ORBIT:
		_begin_round(round_number + 1)
	else:
		_end_round()


## Feeding the scrap in your hands to Scrap Slots.
@rpc("any_peer", "call_local", "reliable")
func request_gamble() -> void:
	if not multiplayer.is_server() or phase != Phase.PLAYING:
		return
	var peer := multiplayer.get_remote_sender_id()
	var node := player_node(peer)
	var item := item_held_by(peer)
	if node == null or item == null or item.is_tool() or not is_player_alive(peer):
		return
	if node.net_pos.distance_to(Rules.GAMBLE_POS) > Rules.SERVER_RANGE or gamble_busy():
		return
	_drop_hand_item(peer)
	# It sits on the machine's tray, locked in, while the reels spin.
	item.position = gamble_tray()
	item.locked = true
	_gamble_item = item
	_gamble_left = Rules.GAMBLE_SECONDS
	_rpc_gamble_spin.rpc()


func gamble_busy() -> bool:
	return _gamble_item != null and is_instance_valid(_gamble_item)


## Where scrap waits in front of the machine, and where winnings come back out.
func gamble_tray() -> Vector3:
	return Vector3(Rules.GAMBLE_POS.x + 1.05, Scrap.FLOOR_HEIGHT, Rules.GAMBLE_POS.z)


func _finish_gamble() -> void:
	var item := _gamble_item
	_gamble_item = null
	if not is_instance_valid(item) or item.get_parent() != scrap_root:
		return
	var multiplier := _roll_gamble()
	if multiplier <= 0.0:
		_rpc_gamble_result.rpc(0.0, 0)
		scrap_root.remove_child(item)
		item.queue_free()
		return
	item.value = mini(roundi(item.value * multiplier), Rules.GAMBLE_MAX_VALUE)
	item.locked = false
	_rpc_gamble_result.rpc(multiplier, item.value)


func _roll_gamble() -> float:
	if gamble_rig >= 0:
		return Rules.GAMBLE_TABLE[gamble_rig][1]
	var roll := randf()
	for row: Array in Rules.GAMBLE_TABLE:
		roll -= row[0]
		if roll < 0.0:
			return row[1]
	return Rules.GAMBLE_TABLE.back()[1]


## A pull at the capsule gacha, paid from the crew's credits. Works in orbit too.
@rpc("any_peer", "call_local", "reliable")
func request_gacha() -> void:
	if not multiplayer.is_server() or not in_world():
		return
	var peer := multiplayer.get_remote_sender_id()
	var node := player_node(peer)
	if node == null or not is_player_alive(peer) or gacha_busy():
		return
	if node.net_pos.distance_to(Rules.GACHA_POS) > Rules.SERVER_RANGE:
		return
	if credits < Rules.GACHA_PRICE:
		_rpc_notice.rpc_id(peer, "Not enough credits: a pull costs $%d" % Rules.GACHA_PRICE)
		return
	credits -= Rules.GACHA_PRICE
	_rpc_run_info.rpc(quota, credits, player_states)
	_gacha_left = Rules.GACHA_SECONDS
	_gacha_peer = peer
	_rpc_gacha_spin.rpc()


func gacha_busy() -> bool:
	return _gacha_left > 0.0


## Where a capsule's gear rolls out, in front of the machine.
func gacha_tray() -> Vector3:
	return Vector3(Rules.GACHA_POS.x - 1.05, Scrap.FLOOR_HEIGHT, Rules.GACHA_POS.z)


func _finish_gacha() -> void:
	_gacha_left = 0.0
	var prize := _roll_gacha()
	var text := ""
	match prize:
		"dud":
			text = "Empty capsule.\nBetter luck next time!"
		"refund":
			credits += Rules.GACHA_REFUND
			text = "Coin capsule!\n$%d back" % Rules.GACHA_REFUND
		"gear", "rare":
			var pool: Array[String] = Tools.GACHA_GEAR if prize == "gear" else Tools.GACHA_RARE
			var kind := pool[randi() % pool.size()]
			if gear_count() >= Rules.TOOL_LIMIT:
				credits += Tools.CATALOG[kind].price
				text = "%s!\nThe crew's gear is full, so: $%d" % [kind.to_upper(), Tools.CATALOG[kind].price]
			else:
				_spawn_gear(kind, [], gacha_tray())
				text = "%s%s!\nIt's on the tray" % ["RARE: " if prize == "rare" else "", kind.to_upper()]
		"gold":
			credits += Rules.GACHA_GOLD
			text = "GOLD CAPSULE!\n+$%d" % Rules.GACHA_GOLD
		"jackpot":
			credits += Rules.GACHA_JACKPOT
			text = "JACKPOT!!!\n+$%d" % Rules.GACHA_JACKPOT
	_rpc_run_info.rpc(quota, credits, player_states)
	_rpc_gacha_result.rpc(prize, text, Net.players.get(_gacha_peer, "Someone"))


func _roll_gacha() -> String:
	if gacha_rig >= 0:
		return Rules.GACHA_TABLE[gacha_rig][1]
	var roll := randf()
	for row: Array in Rules.GACHA_TABLE:
		roll -= row[0]
		if roll < 0.0:
			return row[1]
	return Rules.GACHA_TABLE.back()[1]


## Buying gear at the terminal, with the crew's shared credits.
@rpc("any_peer", "call_local", "reliable")
func request_buy(kind: String) -> void:
	if not multiplayer.is_server() or not in_world():
		return
	var peer := multiplayer.get_remote_sender_id()
	var node := player_node(peer)
	if node == null or not is_player_alive(peer) or not Tools.is_gear(kind):
		return
	if node.net_pos.distance_to(Rules.TERMINAL_POS) > Rules.SERVER_RANGE:
		return
	var price: int = Tools.CATALOG[kind].price
	if credits < price:
		_rpc_shop_reply.rpc_id(peer, false, "Not enough credits. Bank more scrap to earn them.")
		return
	if gear_count() >= Rules.TOOL_LIMIT:
		_rpc_shop_reply.rpc_id(peer, false, "The crew already owns %d pieces of gear. That's the limit." % Rules.TOOL_LIMIT)
		return
	credits -= price
	_spawn_gear(kind)
	_rpc_run_info.rpc(quota, credits, player_states)
	play_effect("buy", Rules.TERMINAL_POS, Rules.TERMINAL_POS, 0)
	_rpc_shop_reply.rpc_id(peer, true, "%s bought. It's on the gear rack." % kind)


## A photo or clip from the camcorder in this player's hands. Footage is big, so it
## travels on its own channel and never holds up movement or gameplay messages.
@rpc("any_peer", "call_local", "reliable", 2)
func request_store_tape(item_id: int, kind: String, frames: Array, times: PackedFloat32Array, length: float) -> void:
	if not multiplayer.is_server() or not in_world():
		return
	var peer := multiplayer.get_remote_sender_id()
	var item := _camcorder_held(peer, item_id)
	if item == null:
		return
	if not valid_recording(kind, frames, times, length):
		_rpc_tape_saved.rpc_id(peer, "That recording couldn't be saved")
		return
	var tape: Array = _tapes.get(item_id, [])
	tape.append({"uid": _next_tape_uid, "kind": kind, "by": Net.players.get(peer, "?"), "frames": frames, "times": times, "length": length})
	_next_tape_uid += 1
	var recorded_over := tape.size() > Tools.TAPE_LIMIT
	while tape.size() > Tools.TAPE_LIMIT:
		tape.pop_front()
	_tapes[item_id] = tape
	item.recordings = tape.size()
	var saved := "%s saved on the camcorder (%d/%d)." % ["Photo" if kind == "photo" else "Clip", tape.size(), Tools.TAPE_LIMIT]
	_rpc_tape_saved.rpc_id(peer, saved + (" The oldest one was recorded over." if recorded_over else ""))


## What's on the camcorder in this player's hands, without the footage itself.
@rpc("any_peer", "call_local", "reliable")
func request_tape_list(item_id: int) -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	if _camcorder_held(peer, item_id) == null:
		return
	var entries := []
	for entry: Dictionary in _tapes.get(item_id, []):
		entries.append({"uid": entry.uid, "kind": entry.kind, "by": entry.by, "length": entry.length})
	_rpc_tape_list.rpc_id(peer, item_id, entries)


## One recording's footage, for the player holding that camcorder.
@rpc("any_peer", "call_local", "reliable")
func request_tape_entry(item_id: int, uid: int) -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	if _camcorder_held(peer, item_id) == null:
		return
	for entry: Dictionary in _tapes.get(item_id, []):
		if entry.uid == uid:
			_rpc_tape_entry.rpc_id(peer, uid, entry.frames, entry.times, entry.length)
			return


func _camcorder_held(peer: int, item_id: int) -> Scrap:
	var item := item_held_by(peer)
	if item == null or item.item_id != item_id or item.kind != Tools.CAMCORDER or not is_player_alive(peer):
		return null
	return item


## Checks a recording before the host keeps it: the right number of JPEG pictures,
## none too big, with sensible timings.
static func valid_recording(kind: String, frames: Array, times: PackedFloat32Array, length: float) -> bool:
	var most_frames := ceili(Tools.CLIP_SECONDS * Tools.CLIP_FPS) + 2
	if kind == "photo":
		if frames.size() != 1 or times != PackedFloat32Array([0.0]) or length != 0.0:
			return false
	elif kind == "clip":
		if frames.is_empty() or frames.size() > most_frames or times.size() != frames.size():
			return false
		if not (length > 0.0 and length <= Tools.CLIP_SECONDS + 0.25):
			return false
		for index in times.size():
			if times[index] < 0.0 or times[index] > length or (index > 0 and times[index] < times[index - 1]):
				return false
	else:
		return false
	var total := 0
	for frame: Variant in frames:
		if not frame is PackedByteArray:
			return false
		var bytes: PackedByteArray = frame
		if bytes.size() < 4 or bytes.size() > Tools.MAX_FRAME_BYTES or bytes[0] != 0xFF or bytes[1] != 0xD8:
			return false
		total += bytes.size()
	return total <= Tools.MAX_RECORDING_BYTES


# --- Messages from the host to everyone --------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_enter_orbit(info: Dictionary) -> void:
	_apply_run_info(info)
	round_number = info.round
	next_map = info.next_map
	next_site = info.next_site
	map_id = ""
	hint_seconds = 0.0
	banner_seconds = BANNER_SECONDS
	if round_number == 0:
		_hints_seen = {}
	_free_level()
	layout = null
	level = Level.new()
	level.name = "Level"
	add_child(level)
	level.build_orbit(MapThemes.get_theme(next_map))
	_set_phase(Phase.ORBIT)


@rpc("authority", "call_local", "reliable")
func _rpc_run_info(new_quota: int, new_credits: int, states: Dictionary) -> void:
	quota = new_quota
	credits = new_credits
	player_states = states
	stats_changed.emit()


func _apply_run_info(info: Dictionary) -> void:
	level_number = info.level
	day = info.day
	days_per_level = info.days
	quota = info.quota
	level_banked = info.banked
	credits = info.credits
	total_scrap = info.total
	rounds_cleared = info.cleared
	player_states = info.states


@rpc("authority", "call_local", "reliable")
func _rpc_load_round(level_seed: int, number: int, new_quota: int, states: Dictionary, total: int, cleared: int, map: String, new_level: int, new_day: int, days: int, banked: int, new_site: String) -> void:
	round_number = number
	level_number = new_level
	day = new_day
	days_per_level = days
	level_banked = banked
	map_id = map
	site = new_site
	banner_seconds = BANNER_SECONDS
	hint_seconds = 0.0
	if number == 1:
		_hints_seen = {}
	quota = new_quota
	player_states = states
	total_scrap = total
	rounds_cleared = cleared
	time_left = Rules.round_seconds(new_site)
	in_ship_value = 0
	_free_level()
	# Each day offers well over a third of the goal, so a level can always be won in time.
	var toughness := Rules.difficulty(new_level)
	layout = FacilityLayout.new(level_seed, Rules.site_grid(toughness, new_site), toughness, ceili(new_quota / 3.0), map, new_site)
	level = Level.new()
	level.name = "Level"
	add_child(level)
	level.build(layout)
	Sfx.play_2d("round_start", -12.0)
	_set_phase(Phase.PLAYING)


@rpc("authority", "call_local", "reliable")
func _rpc_tick(new_time_left: float, value: int) -> void:
	time_left = new_time_left
	in_ship_value = value
	stats_changed.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_player_state(peer: int, hp: int, alive: bool) -> void:
	var old_hp: int = player_states[peer].hp if player_states.has(peer) else hp
	player_states[peer] = {"hp": hp, "alive": alive}
	if peer == Net.my_id() and hp < old_hp:
		Sfx.play_2d("hit", -4.0)
		Settings.rumble(0.4, 0.8, 0.3)
	stats_changed.emit()


@rpc("authority", "reliable")
func _rpc_forget_player(peer: int) -> void:
	player_states.erase(peer)
	stats_changed.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_shop_reply(ok: bool, message: String) -> void:
	Sfx.play_2d("buy" if ok else "deny", -8.0)
	shop_replied.emit(ok, message)


@rpc("authority", "call_local", "reliable")
func _rpc_notice(message: String) -> void:
	Sfx.play_2d("deny", -8.0)
	notice(message)


@rpc("authority", "call_local", "reliable")
func _rpc_boost(seconds: float) -> void:
	var me := player_node(Net.my_id())
	if me != null:
		me.boost_left = seconds
		notice("Adrenaline! %d seconds of speed" % roundi(seconds))


## The recall beacon's beam. Only the player's own machine can move them.
@rpc("authority", "call_local", "reliable")
func _rpc_recall(spot: Vector3) -> void:
	var me := player_node(Net.my_id())
	if me != null:
		me.teleport(spot)
		notice("Beamed back to the ship")


@rpc("authority", "call_local", "reliable")
func _rpc_gacha_spin() -> void:
	Sfx.play_3d("console", Rules.GACHA_POS, 0.0, 16.0)
	if level != null:
		level.gacha_station.spin()
	effect_played.emit("gacha", Rules.GACHA_POS)


@rpc("authority", "call_local", "reliable")
func _rpc_gacha_result(prize: String, text: String, winner: String) -> void:
	if level != null:
		level.gacha_station.show_result(prize, text)
	match prize:
		"dud":
			Sfx.play_3d("lose", Rules.GACHA_POS, -4.0, 16.0)
		"gold", "jackpot":
			Sfx.play_3d("jackpot", Rules.GACHA_POS, 6.0, 30.0)
			_flash(Rules.GACHA_POS + Vector3(-1.0, 2.0, 0), Color(1.0, 0.85, 0.3), 10.0 if prize == "jackpot" else 6.0)
			notice("%s! %s won $%d for the crew!" % ["JACKPOT" if prize == "jackpot" else "Gold capsule", winner,
				Rules.GACHA_JACKPOT if prize == "jackpot" else Rules.GACHA_GOLD], 5.0)
		_:
			Sfx.play_3d("win", Rules.GACHA_POS, 0.0, 20.0)
	effect_played.emit("gacha_" + prize, Rules.GACHA_POS)


@rpc("authority", "call_local", "reliable")
func _rpc_tape_saved(message: String) -> void:
	tape_saved.emit(message)


@rpc("authority", "call_local", "reliable")
func _rpc_tape_list(item_id: int, entries: Array) -> void:
	tape_list_received.emit(item_id, entries)


@rpc("authority", "call_local", "reliable", 2)
func _rpc_tape_entry(uid: int, frames: Array, times: PackedFloat32Array, length: float) -> void:
	tape_entry_received.emit(uid, frames, times, length)


@rpc("authority", "call_local", "reliable")
func _rpc_gamble_spin() -> void:
	Sfx.play_3d("switch", Rules.GAMBLE_POS, 0.0, 16.0)
	if level != null:
		level.gamble_station.spin()
	effect_played.emit("spin", Rules.GAMBLE_POS)


@rpc("authority", "call_local", "reliable")
func _rpc_gamble_result(multiplier: float, value: int) -> void:
	if level != null:
		level.gamble_station.show_result(multiplier, value)
	var kind := "bust" if multiplier <= 0.0 else ("jackpot" if multiplier >= 3.0 else "win")
	match kind:
		"bust":
			Sfx.play_3d("lose", Rules.GAMBLE_POS, 0.0, 20.0)
		"win":
			Sfx.play_3d("win", Rules.GAMBLE_POS, 0.0, 20.0)
		"jackpot":
			Sfx.play_3d("jackpot", Rules.GAMBLE_POS, 6.0, 30.0)
			_flash(Rules.GAMBLE_POS + Vector3(1.0, 2.0, 0), Color(1.0, 0.85, 0.3), 8.0)
	effect_played.emit(kind, Rules.GAMBLE_POS)


## Sounds and flashes for what the crew's gear just did, on every machine.
@rpc("authority", "call_local", "reliable")
func _rpc_effect(kind: String, from: Vector3, to: Vector3, item_id: int) -> void:
	var item: Scrap = null
	if item_id != 0:
		item = scrap_root.get_node_or_null("Scrap%d" % item_id) as Scrap
	match kind:
		"swing":
			Sfx.play_3d("swing", from, -4.0, 15.0)
			if item != null:
				item.swing()
				var holder := player_node(item.holder_id)
				if holder != null:
					holder.show_attack()
		"bonk":
			Sfx.play_3d("bonk", from, 2.0, 30.0)
			Settings.rumble(0.3, 0.6, 0.15)
		"kill":
			Sfx.play_3d("monster_growl", from, 2.0, 35.0)
			_flash(from + Vector3(0, 1.0, 0), Color(1.0, 0.5, 0.3), 4.0)
		"zap":
			Sfx.play_3d("zap", from, 0.0, 30.0)
			_beam(from, to, Tools.ZAP_BLUE)
			_flash(to, Tools.ZAP_BLUE, 5.0)
		"shot":
			Sfx.play_3d("shot", from, 4.0, 45.0)
			_beam(from, to, Color(1.0, 0.85, 0.5))
			_flash(from, Color(1.0, 0.8, 0.5), 6.0)
			Settings.rumble(0.4, 0.9, 0.2)
		"inject":
			Sfx.play_3d("inject", from, -4.0, 12.0)
		"patched":
			Sfx.play_3d("heal", from, -2.0, 15.0)
		"recharge":
			Sfx.play_3d("zap", from, -6.0, 15.0)
			_flash(from + Vector3(0, 1.2, 0), Tools.ZAP_BLUE, 2.0)
		"beacon":
			Sfx.play_3d("beacon", from, 0.0, 25.0)
			_flash(from + Vector3(0, 1.2, 0), Tools.BEACON_GREEN, 3.0)
		"teleport":
			Sfx.play_3d("teleport", from, 2.0, 30.0)
			Sfx.play_3d("teleport", to, 2.0, 30.0)
			_flash(from + Vector3(0, 1.0, 0), Tools.BEACON_GREEN, 8.0)
			_flash(to + Vector3(0, 1.0, 0), Tools.BEACON_GREEN, 8.0)
		"flashbang":
			Sfx.play_3d("boom", from, 8.0, 50.0)
			_flash(from + Vector3(0, 0.8, 0), Color(1.0, 1.0, 1.0), 24.0)
			_blast_to_check = from + Vector3(0, 0.6, 0)
			_blast_kind = Tools.FLASHBANG
		"fizzle", "empty":
			Sfx.play_3d("deny", from, -8.0, 12.0)
		"throw":
			Sfx.play_3d("switch", from, -4.0, 15.0)
		"boom":
			Sfx.play_3d("boom", from, 6.0, 45.0)
			_flash(from + Vector3(0, 0.8, 0), Color(1.0, 1.0, 0.95), 16.0)
			_blast_to_check = from + Vector3(0, 0.6, 0)
			_blast_kind = Tools.STUN_GRENADE
		"buy":
			Sfx.play_3d("console", from, -4.0, 15.0)
	effect_played.emit(kind, from)


func _flash(pos: Vector3, color: Color, energy: float) -> void:
	if level == null:
		return
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = energy
	light.omni_range = 10.0
	light.position = pos
	level.add_child(light)
	get_tree().create_timer(EFFECT_SECONDS).timeout.connect(light.queue_free)


## A zap or a shotgun blast: a thin glowing line from the gun to what it hit.
func _beam(from: Vector3, to: Vector3, color: Color) -> void:
	if level == null or from.is_equal_approx(to):
		return
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.04
	mesh.bottom_radius = 0.04
	mesh.height = from.distance_to(to)
	mesh.radial_segments = 6
	mesh.rings = 1
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	mesh.material = material
	var bolt := MeshInstance3D.new()
	bolt.mesh = mesh
	level.add_child(bolt)
	# A cylinder stands along Y; turn it to run from the gun to the target.
	var along := (to - from).normalized()
	var side := along.cross(Vector3.UP) if absf(along.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	bolt.global_transform = Transform3D(Basis(side.normalized(), along, side.normalized().cross(along)), (from + to) * 0.5)
	get_tree().create_timer(EFFECT_SECONDS).timeout.connect(bolt.queue_free)


## A stun grenade or flashbang blinds this player if they can see it go off, more so facing it.
func _check_blinding(blast: Vector3) -> void:
	var strength := Tools.blast_for(_blast_kind)
	var me := player_node(Net.my_id())
	if me == null or not is_player_alive(me.peer_id):
		return
	var eye := me.position + Vector3(0, 1.6, 0)
	var offset := blast - eye
	if offset.length() > strength[0]:
		return
	var query := PhysicsRayQueryParameters3D.create(eye, blast, 1)
	if not me.get_world_3d().direct_space_state.intersect_ray(query).is_empty():
		return
	var facing := me.forward().dot(Vector3(offset.x, 0, offset.z).normalized())
	blind_seconds = strength[2] * (1.0 if facing > 0.3 else 0.4)


@rpc("authority", "call_local", "reliable")
func _rpc_results(data: Dictionary) -> void:
	last_results = data
	total_scrap = data.total_scrap
	rounds_cleared = data.rounds_cleared
	credits = data.credits
	var own_player := player_node(Net.my_id())
	if own_player != null:
		own_player.get_node("Sync").public_visibility = false
	_free_level()
	Sfx.play_2d("launch", -8.0)
	if data.cleared:
		Sfx.play_2d("win", -10.0)
	elif data.run_over:
		Sfx.play_2d("lose", -10.0)
	_set_phase(Phase.GAME_OVER if data.run_over else Phase.RESULTS)
	results_ready.emit(data)
	if data.run_over:
		Cloud.submit_run(Net.local_name, data.rounds_cleared, data.total_scrap, data.crew_size)


func _set_phase(new_phase: Phase) -> void:
	phase = new_phase
	Sfx.set_ambient(phase == Phase.PLAYING, layout.theme.hum_pitch if layout != null else 1.0)
	phase_changed.emit()
	stats_changed.emit()


func _free_level() -> void:
	if level != null:
		remove_child(level)
		level.queue_free()
		level = null


func _on_connection_ended() -> void:
	_clear_entities()
	_free_level()
	layout = null
	player_states = {}
	_pending_uses.clear()
	_ready_at.clear()
	_tapes.clear()
	_crew_gear = []
	_gacha_left = 0.0
	_set_phase(Phase.LOBBY)
