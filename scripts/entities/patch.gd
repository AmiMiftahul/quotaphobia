class_name Patch
extends Entity
## A friendly medical drone. It flies to hurt crew members and heals anyone close
## by, until its limited charge runs out.

const SPEED := 3.2
const HOVER := 1.4
const HEAL_RANGE := 3.0
const HEAL_PER_TICK := 10
const TICK_SECONDS := 1.0
const SEEK_ROOMS := 5
const STARTING_CHARGE := 150
const HEALING := 1
const EMPTY := 2

var charge := STARTING_CHARGE

var _light: OmniLight3D
var _heal_timer := 0.0


func _build(_data: Dictionary) -> void:
	position.y = HOVER
	net_pos.y = HOVER
	_last_position.y = HOVER
	var model := Assets.instance(Assets.FACTORY % "cog-a")
	# Stood on edge, so it reads as a round drone from any height.
	model.scale = Vector3.ONE * 1.3
	model.rotation.x = PI * 0.5
	add_child(model)
	var cross := SphereMesh.new()
	cross.radius = 0.3
	cross.height = 0.6
	var material := Level._material(Color(0.3, 1.0, 0.5))
	material.emission_enabled = true
	material.emission = Color(0.3, 1.0, 0.5)
	material.emission_energy_multiplier = 3.0
	cross.material = material
	var core := MeshInstance3D.new()
	core.mesh = cross
	add_child(core)
	_light = _make_light(Color(0.35, 1.0, 0.55), 1.8, 8.0, 0.0)


func _on_state_changed(old_state: int) -> void:
	_light.visible = net_state != EMPTY
	if net_state == HEALING and old_state != HEALING:
		Sfx.play_3d("heal", position, -2.0, 18.0)


func _process(delta: float) -> void:
	rotate_y(delta * 2.0)


func _host_tick(delta: float) -> void:
	if charge <= 0:
		net_state = EMPTY
		return
	var hurt := _nearest_hurt_player()
	if hurt == null:
		net_state = 0
		if _waypoints.is_empty():
			_route_to_random_room()
		_follow_path(SPEED * 0.6, delta)
		return
	var offset := hurt.net_pos - position
	offset.y = 0.0
	if offset.length() > HEAL_RANGE:
		net_state = 0
		_think_timer -= delta
		if _think_timer <= 0.0:
			_think_timer = THINK_SECONDS
			_route_to_point(hurt.net_pos)
		_follow_path(SPEED, delta)
		return
	net_state = HEALING
	_heal_timer -= delta
	if _heal_timer <= 0.0:
		_heal_timer = TICK_SECONDS
		charge -= HEAL_PER_TICK
		Session.heal_player(hurt.peer_id, HEAL_PER_TICK)


func _nearest_hurt_player() -> Player:
	var best: Player = null
	var best_rooms := SEEK_ROOMS + 1
	for player: Player in Session.players_root.get_children():
		if not Session.is_player_alive(player.peer_id):
			continue
		if Session.player_states[player.peer_id].hp >= Rules.PLAYER_MAX_HP:
			continue
		var offset := player.net_pos - position
		offset.y = 0.0
		if offset.length() <= HEAL_RANGE:
			return player
		var rooms := _rooms_to(player.net_pos)
		if rooms > 0 and rooms < best_rooms:
			best_rooms = rooms
			best = player
	return best
