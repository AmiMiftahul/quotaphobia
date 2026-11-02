class_name Entity
extends Node3D
## What every creature and helper shares. All decisions run on the host, in
## _host_tick; other players follow the synced position and state. Things travel
## room to room through door centres, so they can't clip walls.

const THINK_SECONDS := 0.4
# "hits": shovel blows that finish it off. 0 means no weapon can hurt it.
const INFO := {
	"stalker": {"hostile": true, "hits": 4, "hint": "THE STALKER: outrun it, break away, or reach the ship."},
	"watcher": {"hostile": true, "hits": 3, "hint": "THE WATCHER: it only moves when nobody can see it. Keep your eyes on it."},
	"listener": {"hostile": true, "hits": 3, "hint": "THE LISTENER: it's blind and hunts by sound. Don't sprint. Stand still to hide."},
	"mimic": {"hostile": true, "hits": 1, "hint": "A MIMIC: it looks like scrap. Real scrap shows a pick-up prompt. This didn't."},
	"gas": {"hostile": true, "hits": 0, "hint": "TOXIC VENT: it opens and closes. Wait until it's clear, then cross."},
	"patch": {"hostile": false, "hits": 0, "hint": "PATCH: a friendly drone. Stay close to it to heal. Its charge runs out."},
	"sentinel": {"hostile": false, "hits": 0, "hint": "SENTINEL: a friendly pylon. Lead hunters past it and it stuns them."},
	"wisp": {"hostile": false, "hits": 0, "hint": "WISP: a friendly light. It leads you to scrap and turns red near danger."},
}

var kind := ""
var net_pos := Vector3.ZERO
var net_yaw := 0.0
var net_state := 0:
	set(new_state):
		var old_state := net_state
		net_state = new_state
		if new_state != old_state and is_inside_tree():
			_on_state_changed(old_state)
var net_stunned := false:
	set(stunned):
		if stunned and not net_stunned and is_inside_tree():
			Sfx.play_3d("stun", position, -2.0, 25.0)
		net_stunned = stunned
var net_attacks := 0:
	set(count):
		if count != net_attacks and is_inside_tree():
			Sfx.play_3d("hit", position, -6.0, 20.0)
			_attack_show = ATTACK_SHOW_SECONDS
		net_attacks = count
var enabled := true
var grace := 0.0
var current_animation := ""

const ATTACK_SHOW_SECONDS := 0.8

var _layout: FacilityLayout
var _waypoints: Array[Vector3] = []
var _think_timer := 0.0
var _attack_timer := 0.0
var _attack_show := 0.0
var _stun_timer := 0.0
var _hits_taken := 0
var _animator: AnimationPlayer
var _last_position := Vector3.ZERO
var _step_progress := 0.0
var _step_bank := ""
var _step_distance := 2.6
var _rng := RandomNumberGenerator.new()


func setup(layout: FacilityLayout, data: Dictionary) -> void:
	_layout = layout
	kind = data.kind
	name = "%s%d" % [kind.capitalize(), data.index]
	position = data.pos
	net_pos = data.pos
	_last_position = data.pos
	_rng.seed = hash([kind, data.index, data.pos])
	_build(data)
	var on_change: Array[NodePath] = [^":net_state", ^":net_stunned", ^":net_attacks"]
	on_change.append_array(_extra_synced())
	NetSync.attach(self, [^":net_pos", ^":net_yaw"], on_change)


func is_hostile() -> bool:
	return INFO[kind].hostile


## Called on the host, by Sentinels and the crew's gear.
func stun(seconds: float) -> void:
	_stun_timer = seconds
	net_stunned = true
	_waypoints.clear()


## Called on the host when a shovel lands. Each blow stuns; the last one finishes it.
func hurt(stun_seconds: float) -> void:
	if INFO[kind].hits <= 0:
		return
	_hits_taken += 1
	if _hits_taken >= INFO[kind].hits:
		Session.kill_entity(self)
	else:
		stun(stun_seconds)


func hits_left() -> int:
	return INFO[kind].hits - _hits_taken


func _physics_process(delta: float) -> void:
	if Session.phase != Session.Phase.PLAYING:
		return
	if not multiplayer.is_server():
		position = position.lerp(net_pos, minf(1.0, delta * 12.0))
		rotation.y = lerp_angle(rotation.y, net_yaw, minf(1.0, delta * 12.0))
		_animate_and_step(delta)
		return
	if enabled and grace > 0.0:
		grace -= delta
	elif enabled and _stun_timer > 0.0:
		_stun_timer -= delta
		if _stun_timer <= 0.0:
			net_stunned = false
	elif enabled:
		_attack_timer -= delta
		_host_tick(delta)
	net_pos = position
	net_yaw = rotation.y
	_animate_and_step(delta)


# --- Things each kind fills in ---------------------------------------------------

func _build(_data: Dictionary) -> void:
	pass


func _host_tick(_delta: float) -> void:
	pass


func _extra_synced() -> Array[NodePath]:
	return []


func _on_state_changed(_old_state: int) -> void:
	pass


# --- Shared by the kinds that need them -------------------------------------------

func _add_character_body(model: String, model_scale: float, color: Color) -> void:
	var body := Assets.instance(Assets.CHARACTERS % model)
	body.scale = Vector3.ONE * model_scale
	body.rotation.y = PI # The models face +Z; the game treats -Z as forward.
	add_child(body)
	var material := Level._material(color)
	material.roughness = 1.0
	Assets.override_material(body, material)
	_animator = Assets.find_animation_player(body)
	Assets.set_looping(_animator, ["idle", "walk", "sprint", "crouch"])


func _add_eyes(color: Color, height: float, spread: float, forward_offset: float, eye_size: float = 0.09) -> void:
	for side: float in [-spread, spread]:
		var mesh := SphereMesh.new()
		mesh.radius = eye_size
		mesh.height = eye_size * 2.0
		mesh.radial_segments = 10
		mesh.rings = 5
		var material := Level._material(color)
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 6.0
		mesh.material = material
		var eye := MeshInstance3D.new()
		eye.mesh = mesh
		eye.position = Vector3(side, height, -forward_offset)
		add_child(eye)


func _make_light(color: Color, energy: float, light_range: float, height: float) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = energy
	light.omni_range = light_range
	light.position.y = height
	add_child(light)
	return light


func _animate_and_step(delta: float) -> void:
	var moved := position - _last_position
	moved.y = 0.0
	_last_position = position
	if _animator != null:
		var speed := moved.length() / maxf(delta, 0.001)
		var wanted := "idle"
		if _attack_show > 0.0:
			_attack_show -= delta
			wanted = "attack-melee-right"
		elif speed > 3.5:
			wanted = "sprint"
		elif speed > 0.3:
			wanted = "walk"
		if wanted != current_animation:
			current_animation = wanted
			_animator.play(wanted, 0.15)
	if _step_bank.is_empty():
		return
	_step_progress += moved.length()
	if _step_progress >= _step_distance:
		_step_progress = 0.0
		Sfx.play_3d(_step_bank, position, 2.0, 28.0)


## Alive players outside the ship. The ship is always safe.
func _targets() -> Array[Player]:
	var result: Array[Player] = []
	for player: Player in Session.players_root.get_children():
		if Session.is_player_alive(player.peer_id) and not Rules.in_ship(player.net_pos):
			result.append(player)
	return result


func _rooms_to(pos: Vector3) -> int:
	return _layout.path(FacilityLayout.cell_at(position), FacilityLayout.cell_at(pos)).size()


func _nearest_target(max_rooms: int, max_distance: float) -> Player:
	var best: Player = null
	var best_rooms := max_rooms + 1
	for player in _targets():
		if position.distance_to(player.net_pos) > max_distance:
			continue
		var rooms := _rooms_to(player.net_pos)
		if rooms > 0 and rooms < best_rooms:
			best_rooms = rooms
			best = player
	return best


## Door, room centre, door, room centre... so each straight line stays inside one room.
func _route(to: Vector2i) -> Array[Vector3]:
	var points: Array[Vector3] = []
	var cells := _layout.path(FacilityLayout.cell_at(position), to)
	for index in range(1, cells.size()):
		var previous := FacilityLayout.cell_center(cells[index - 1])
		var next := FacilityLayout.cell_center(cells[index])
		points.append((previous + next) * 0.5)
		points.append(next)
	return points


func _route_to_point(pos: Vector3) -> void:
	_waypoints = _route(FacilityLayout.cell_at(pos))
	_waypoints.append(Vector3(pos.x, position.y, pos.z))


func _route_to_random_room() -> void:
	var room := Vector2i(_rng.randi_range(0, _layout.size - 1), _rng.randi_range(0, _layout.size - 1))
	_waypoints = _route(room)


func _follow_path(speed: float, delta: float) -> void:
	if _waypoints.is_empty():
		return
	var target := _waypoints[0]
	var to_target := target - position
	to_target.y = 0.0
	var step := speed * delta
	if to_target.length() <= step:
		position = Vector3(target.x, position.y, target.z)
		_waypoints.pop_front()
		return
	position += to_target.normalized() * step
	rotation.y = atan2(-to_target.x, -to_target.z)


func _try_attack(attack_range: float, damage: int) -> bool:
	if _attack_timer > 0.0:
		return false
	for player in _targets():
		var offset := player.net_pos - position
		offset.y = 0.0
		if offset.length() < attack_range:
			_attack_timer = Rules.MONSTER_ATTACK_COOLDOWN
			net_attacks += 1
			Session.damage_player(player.peer_id, damage)
			return true
	return false
