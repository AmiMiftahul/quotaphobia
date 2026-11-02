extends Node
## The rules of a run. The host decides everything that matters: other players
## ask through request_* calls, and the host checks each request before acting.

signal phase_changed
signal stats_changed
signal results_ready(data: Dictionary)

enum Phase { LOBBY, PLAYING, RESULTS, GAME_OVER }

const DESPAWN_DELAY := 0.5

var phase := Phase.LOBBY
var round_number := 0
var quota := 0
var time_left := 0.0
var in_ship_value := 0
var total_scrap := 0
var rounds_cleared := 0
var player_states := {} # peer id -> { "hp": int, "alive": bool }
var last_results := {}
var layout: FacilityLayout
var level: Level
var players_root: Node3D
var scrap_root: Node3D
var monster_root: Node3D

# Host-side settings; the tests shorten these.
var results_seconds := Rules.RESULTS_SECONDS
var monster_enabled := true

var _run_seed := 0
var _crew_size := 1
var _results_timer := 0.0
var _despawn_timer := 0.0
var _tick_timer := 0.0
var _player_spawner: MultiplayerSpawner
var _scrap_spawner: MultiplayerSpawner
var _monster_spawner: MultiplayerSpawner


func _ready() -> void:
	_setup_input()
	players_root = _make_root("Players")
	scrap_root = _make_root("ScrapItems")
	monster_root = _make_root("Monsters")
	_player_spawner = _make_spawner("PlayerSpawner", "Players", _spawn_player)
	_scrap_spawner = _make_spawner("ScrapSpawner", "ScrapItems", _spawn_scrap)
	_monster_spawner = _make_spawner("MonsterSpawner", "Monsters", _spawn_monster)
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


func _setup_input() -> void:
	var keys := {
		"move_forward": KEY_W, "move_back": KEY_S, "move_left": KEY_A, "move_right": KEY_D,
		"sprint": KEY_SHIFT, "jump": KEY_SPACE, "interact": KEY_E, "drop": KEY_G, "flashlight": KEY_F,
	}
	for action: String in keys:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var event := InputEventKey.new()
		event.physical_keycode = keys[action]
		InputMap.action_add_event(action, event)


# --- Spawning: these run on every machine with the same data -----------------

func _spawn_player(data: Dictionary) -> Node:
	var player := Player.new()
	player.setup(data.peer, data.name, data.index, data.pos)
	player.set_multiplayer_authority(data.peer, true)
	return player


func _spawn_scrap(data: Dictionary) -> Node:
	var item := Scrap.new()
	item.setup(data.id, data)
	return item


func _spawn_monster(data: Dictionary) -> Node:
	var monster := Monster.new()
	monster.setup(layout, data.pos)
	return monster


# --- Helpers usable on every machine ---------------------------------------

func is_player_alive(peer: int) -> bool:
	return player_states.has(peer) and player_states[peer].alive


func player_node(peer: int) -> Player:
	return players_root.get_node_or_null("P%d" % peer) as Player


func item_held_by(peer: int) -> Scrap:
	for item: Scrap in scrap_root.get_children():
		if item.holder_id == peer:
			return item
	return null


func carried_weight(peer: int) -> float:
	var item := item_held_by(peer)
	return item.weight if item != null else 0.0


# --- Host: starting and finishing rounds -----------------------------------

func start_run() -> void:
	if not multiplayer.is_server() or phase != Phase.LOBBY:
		return
	_run_seed = randi()
	_crew_size = Net.players.size()
	total_scrap = 0
	rounds_cleared = 0
	_begin_round(1)


func _begin_round(number: int) -> void:
	var crew := Net.players.size()
	var states := {}
	for peer: int in Net.players:
		states[peer] = {"hp": Rules.PLAYER_MAX_HP, "alive": true}
	var level_seed: int = hash([_run_seed, number])
	_rpc_load_round.rpc(level_seed, number, Rules.quota(number, crew), states, total_scrap, rounds_cleared)
	var peers: Array = Net.players.keys()
	peers.sort()
	for index in peers.size():
		var spawn_pos := FacilityLayout.cell_center(FacilityLayout.SHIP_CELL) + Vector3(-1.5 + index, 0.1, 1.0)
		_player_spawner.spawn({"peer": peers[index], "name": Net.players[peers[index]], "index": index, "pos": spawn_pos})
	for index in layout.scrap_spawns.size():
		var data: Dictionary = layout.scrap_spawns[index].duplicate()
		data["id"] = index + 1
		_scrap_spawner.spawn(data)
	_monster_spawner.spawn({"pos": FacilityLayout.cell_center(layout.monster_spawn)})
	var monster := monster_root.get_child(0) as Monster
	monster.enabled = monster_enabled


func _process(delta: float) -> void:
	if phase == Phase.PLAYING:
		time_left = maxf(0.0, time_left - delta)
	if not Net.is_online() or not multiplayer.is_server():
		return
	match phase:
		Phase.PLAYING:
			_tick_timer -= delta
			if _tick_timer <= 0.0:
				_tick_timer = 1.0
				_rpc_tick.rpc(time_left, _ship_value())
			if time_left <= 0.0:
				_end_round()
		Phase.RESULTS, Phase.GAME_OVER:
			if _despawn_timer > 0.0:
				_despawn_timer -= delta
				if _despawn_timer <= 0.0:
					_clear_entities()
			_results_timer -= delta
			if _results_timer <= 0.0:
				if phase == Phase.RESULTS:
					_begin_round(round_number + 1)
				else:
					_rpc_to_lobby.rpc()


func _ship_value() -> int:
	var value := 0
	for item: Scrap in scrap_root.get_children():
		if Rules.in_ship(item.position):
			value += item.value
	return value


func _end_round() -> void:
	var survivors := 0
	for peer: int in player_states:
		var node := player_node(peer)
		if is_player_alive(peer) and node != null and Rules.in_ship(node.net_pos):
			survivors += 1
	# If nobody makes it home, nobody can sell what was collected.
	var collected := _ship_value() if survivors > 0 else 0
	var cleared := survivors > 0 and collected >= quota
	var data := {
		"round": round_number,
		"quota": quota,
		"collected": collected,
		"survivors": survivors,
		"cleared": cleared,
		"total_scrap": total_scrap + collected,
		"rounds_cleared": rounds_cleared + (1 if cleared else 0),
		"crew_size": _crew_size,
	}
	_rpc_results.rpc(data)
	# Everyone stops sending movement now; players are removed once the last
	# updates have landed, so nothing arrives for a node that's already gone.
	_despawn_timer = DESPAWN_DELAY
	_results_timer = maxf(results_seconds, DESPAWN_DELAY + 0.1)


func _clear_entities() -> void:
	for root: Node3D in [players_root, scrap_root, monster_root]:
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
		_release_item(peer)
		_end_round_if_wiped()


func _release_item(peer: int) -> void:
	var item := item_held_by(peer)
	if item == null:
		return
	var node := player_node(peer)
	var at := node.net_pos if node != null else item.position
	item.holder_id = 0
	item.position = Vector3(at.x, 0.25, at.z)


func _end_round_if_wiped() -> void:
	if phase != Phase.PLAYING:
		return
	for peer: int in player_states:
		if is_player_alive(peer):
			return
	_end_round()


func _on_peer_left(peer: int) -> void:
	if phase != Phase.PLAYING:
		player_states.erase(peer)
		return
	_release_item(peer)
	var node := player_node(peer)
	if node != null:
		players_root.remove_child(node)
		node.queue_free()
	_rpc_forget_player.rpc(peer)
	_end_round_if_wiped()


# --- Requests from players. Never trust these: always re-check on the host ---

@rpc("any_peer", "call_local", "reliable")
func request_start() -> void:
	if multiplayer.is_server() and multiplayer.get_remote_sender_id() == 1:
		start_run()


@rpc("any_peer", "call_local", "reliable")
func request_pickup(item_id: int) -> void:
	if not multiplayer.is_server() or phase != Phase.PLAYING:
		return
	var peer := multiplayer.get_remote_sender_id()
	var node := player_node(peer)
	var item := scrap_root.get_node_or_null("Scrap%d" % item_id) as Scrap
	if node == null or item == null or not is_player_alive(peer):
		return
	if item.holder_id != 0 or item_held_by(peer) != null:
		return
	if node.net_pos.distance_to(item.position) > Rules.SERVER_RANGE:
		return
	item.holder_id = peer


@rpc("any_peer", "call_local", "reliable")
func request_drop() -> void:
	if multiplayer.is_server() and phase == Phase.PLAYING:
		_release_item(multiplayer.get_remote_sender_id())


@rpc("any_peer", "call_local", "reliable")
func request_launch() -> void:
	if not multiplayer.is_server() or phase != Phase.PLAYING:
		return
	var peer := multiplayer.get_remote_sender_id()
	var node := player_node(peer)
	if node == null or not is_player_alive(peer):
		return
	if node.net_pos.distance_to(Rules.CONSOLE_POS) > Rules.SERVER_RANGE:
		return
	_end_round()


# --- Messages from the host to everyone --------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_load_round(level_seed: int, number: int, new_quota: int, states: Dictionary, total: int, cleared: int) -> void:
	round_number = number
	quota = new_quota
	player_states = states
	total_scrap = total
	rounds_cleared = cleared
	time_left = Rules.ROUND_SECONDS
	in_ship_value = 0
	_free_level()
	layout = FacilityLayout.new(level_seed, Rules.grid_size(number), number, new_quota)
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
	player_states[peer] = {"hp": hp, "alive": alive}
	if peer == Net.my_id():
		Sfx.play_2d("hit", -4.0)
	stats_changed.emit()


@rpc("authority", "reliable")
func _rpc_forget_player(peer: int) -> void:
	player_states.erase(peer)
	stats_changed.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_results(data: Dictionary) -> void:
	last_results = data
	total_scrap = data.total_scrap
	rounds_cleared = data.rounds_cleared
	var own_player := player_node(Net.my_id())
	if own_player != null:
		own_player.get_node("Sync").public_visibility = false
	_free_level()
	Sfx.play_2d("launch", -8.0)
	Sfx.play_2d("win" if data.cleared else "lose", -10.0)
	_set_phase(Phase.RESULTS if data.cleared else Phase.GAME_OVER)
	results_ready.emit(data)
	if not data.cleared:
		Cloud.submit_run(Net.local_name, data.rounds_cleared, data.total_scrap, data.crew_size)


@rpc("authority", "call_local", "reliable")
func _rpc_to_lobby() -> void:
	_set_phase(Phase.LOBBY)


func _set_phase(new_phase: Phase) -> void:
	phase = new_phase
	Sfx.set_ambient(phase == Phase.PLAYING)
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
	_set_phase(Phase.LOBBY)
