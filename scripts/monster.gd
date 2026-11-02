class_name Monster
extends Node3D
## The hunter. All of its decisions run on the host; other players just see the
## result. It travels room to room through door centres, so it can't clip walls.

const PATROL_SPEED := 2.5
const CHASE_SPEED := 4.4
const SIGHT_RANGE := 18.0
const SIGHT_ROOMS := 3 # Route length, counting its own room, at which it notices you.
const THINK_SECONDS := 0.4
const MODEL := "character-male-c"
const MODEL_SCALE := 3.8
const STEP_DISTANCE := 2.6
const ATTACK_SHOW_SECONDS := 0.8

var net_pos := Vector3.ZERO
var net_yaw := 0.0
var net_chasing := false:
	set(chasing):
		if chasing and not net_chasing and is_inside_tree():
			Sfx.play_3d("monster_growl", position, 4.0, 35.0)
		net_chasing = chasing
var net_attacks := 0:
	set(count):
		if count != net_attacks and is_inside_tree():
			Sfx.play_3d("hit", position, -6.0, 20.0)
			_attack_show = ATTACK_SHOW_SECONDS
		net_attacks = count
var enabled := true
var grace := Rules.MONSTER_GRACE_SECONDS
var current_animation := ""

var _layout: FacilityLayout
var _waypoints: Array[Vector3] = []
var _think_timer := 0.0
var _attack_timer := 0.0
var _attack_show := 0.0
var _animator: AnimationPlayer
var _last_position := Vector3.ZERO
var _step_progress := 0.0
var _rng := RandomNumberGenerator.new()


func setup(layout: FacilityLayout, spawn_pos: Vector3) -> void:
	_layout = layout
	position = spawn_pos
	net_pos = spawn_pos
	_last_position = spawn_pos
	name = "Monster"
	var body := Assets.instance(Assets.CHARACTERS % MODEL)
	body.scale = Vector3.ONE * MODEL_SCALE
	body.rotation.y = PI # The model faces +Z; the game treats -Z as forward.
	add_child(body)
	# A huge black silhouette made from a normal crew model.
	var shadow := Level._material(Color(0.015, 0.012, 0.015))
	shadow.roughness = 1.0
	Assets.override_material(body, shadow)
	_animator = Assets.find_animation_player(body)
	Assets.set_looping(_animator, ["idle", "walk", "sprint"])
	for side: float in [-0.28, 0.28]:
		var eye_mesh := SphereMesh.new()
		eye_mesh.radius = 0.09
		eye_mesh.height = 0.18
		var eye_material := Level._material(Color.RED)
		eye_material.emission_enabled = true
		eye_material.emission = Color.RED
		eye_material.emission_energy_multiplier = 6.0
		eye_mesh.material = eye_material
		var eye := MeshInstance3D.new()
		eye.mesh = eye_mesh
		eye.position = Vector3(side, 1.75, -0.72)
		add_child(eye)
	NetSync.attach(self, [^":net_pos", ^":net_yaw"], [^":net_chasing", ^":net_attacks"])


func _physics_process(delta: float) -> void:
	if Session.phase != Session.Phase.PLAYING:
		return
	if not multiplayer.is_server():
		position = position.lerp(net_pos, minf(1.0, delta * 12.0))
		rotation.y = lerp_angle(rotation.y, net_yaw, minf(1.0, delta * 12.0))
		_animate_and_step(delta)
		return
	if not enabled:
		net_pos = position
		_animate_and_step(delta)
		return
	if grace > 0.0:
		grace -= delta
		_animate_and_step(delta)
		return
	_attack_timer -= delta
	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_SECONDS
		_think()
	if _attack_timer <= 0.0:
		_follow_path(delta)
		_try_attack()
	net_pos = position
	net_yaw = rotation.y
	_animate_and_step(delta)


func _animate_and_step(delta: float) -> void:
	var moved := position - _last_position
	moved.y = 0.0
	_last_position = position
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
	_step_progress += moved.length()
	if _step_progress >= STEP_DISTANCE:
		_step_progress = 0.0
		Sfx.play_3d("monster_step", position, 2.0, 28.0)


func _think() -> void:
	var target := _find_target()
	var here := FacilityLayout.cell_at(position)
	if target != null:
		net_chasing = true
		_waypoints = _route(here, FacilityLayout.cell_at(target.net_pos))
		_waypoints.append(Vector3(target.net_pos.x, 0.0, target.net_pos.z))
	elif net_chasing or _waypoints.is_empty():
		net_chasing = false
		var destination := Vector2i(_rng.randi_range(0, _layout.size - 1), _rng.randi_range(0, _layout.size - 1))
		_waypoints = _route(here, destination)


func _find_target() -> Player:
	var best: Player = null
	var best_rooms := SIGHT_ROOMS + 1
	var here := FacilityLayout.cell_at(position)
	for player: Player in Session.players_root.get_children():
		if not Session.is_player_alive(player.peer_id) or Rules.in_ship(player.net_pos):
			continue
		if position.distance_to(player.net_pos) > SIGHT_RANGE:
			continue
		var rooms := _layout.path(here, FacilityLayout.cell_at(player.net_pos)).size()
		if rooms > 0 and rooms < best_rooms:
			best_rooms = rooms
			best = player
	return best


## Door, room centre, door, room centre... so each straight line stays inside one room.
func _route(from: Vector2i, to: Vector2i) -> Array[Vector3]:
	var points: Array[Vector3] = []
	var cells := _layout.path(from, to)
	for index in range(1, cells.size()):
		var previous := FacilityLayout.cell_center(cells[index - 1])
		var next := FacilityLayout.cell_center(cells[index])
		points.append((previous + next) * 0.5)
		points.append(next)
	return points


func _follow_path(delta: float) -> void:
	if _waypoints.is_empty():
		return
	var target := _waypoints[0]
	var to_target := target - position
	to_target.y = 0.0
	var step := (CHASE_SPEED if net_chasing else PATROL_SPEED) * delta
	if to_target.length() <= step:
		position = Vector3(target.x, position.y, target.z)
		_waypoints.pop_front()
		return
	position += to_target.normalized() * step
	rotation.y = atan2(-to_target.x, -to_target.z)


func _try_attack() -> void:
	for player: Player in Session.players_root.get_children():
		if not Session.is_player_alive(player.peer_id) or Rules.in_ship(player.net_pos):
			continue
		var offset := player.net_pos - position
		offset.y = 0.0
		if offset.length() < Rules.MONSTER_ATTACK_RANGE:
			_attack_timer = Rules.MONSTER_ATTACK_COOLDOWN
			net_attacks += 1
			Session.damage_player(player.peer_id, Rules.MONSTER_DAMAGE)
			return
