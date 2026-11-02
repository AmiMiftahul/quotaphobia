class_name Gunner
extends Entity
## A soldier with a shotgun. It patrols; when it sees you it stops and takes aim with
## a red laser, then fires. Get out of its sight while it aims and the shot misses.
## It takes 3 shovel hits, and drops its shotgun when it goes down.

const PATROL_SPEED := 2.2
const SIGHT_RANGE := 16.0
const SIGHT_CONE := 0.5 # Dot product: about 60 degrees either side of where it faces.
const AIM_SECONDS := 1.2
const RELOAD_SECONDS := 3.0
const DAMAGE := 45
const SHELLS := 2 # Left in the shotgun it drops.
const AIMING := 1
const LASER_LENGTH := 16.0
const GUN_HEIGHT := 1.45

var _aim_left := 0.0
var _reload_left := 0.0
var _target: Player
var _laser: MeshInstance3D


func _build(_data: Dictionary) -> void:
	grace = Rules.MONSTER_GRACE_SECONDS
	_step_bank = "monster_step"
	_step_distance = 3.0
	_add_character_body("character-male-b", 2.9, Color(0.22, 0.27, 0.16))
	_add_eyes(Color(1.0, 0.25, 0.1), 1.95, 0.1, 0.32, 0.05)
	var gun := Tools.build_model(Tools.SHOTGUN)
	gun.scale = Vector3.ONE * 1.4
	gun.position = Vector3(0.28, GUN_HEIGHT - 0.2, -0.35)
	add_child(gun)
	var beam := CylinderMesh.new()
	beam.top_radius = 0.012
	beam.bottom_radius = 0.012
	beam.height = LASER_LENGTH
	beam.radial_segments = 4
	beam.rings = 1
	var red := StandardMaterial3D.new()
	red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	red.albedo_color = Color(1.0, 0.1, 0.05)
	beam.material = red
	_laser = MeshInstance3D.new()
	_laser.mesh = beam
	_laser.rotation.x = PI * 0.5
	_laser.position = Vector3(0.28, GUN_HEIGHT, -0.6 - LASER_LENGTH * 0.5)
	_laser.visible = false
	add_child(_laser)


func _on_state_changed(_old_state: int) -> void:
	_laser.visible = net_state == AIMING
	if net_state == AIMING:
		Sfx.play_3d("switch", position, 2.0, 25.0) # The shotgun being racked.


func stun(seconds: float) -> void:
	super.stun(seconds)
	net_state = 0


func _host_tick(delta: float) -> void:
	_reload_left -= delta
	if net_state == AIMING:
		_keep_aiming(delta)
		return
	if _reload_left <= 0.0:
		var seen := _player_in_sight()
		if seen != null:
			_target = seen
			_aim_left = AIM_SECONDS
			_waypoints.clear()
			net_state = AIMING
			return
	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_SECONDS
		if _waypoints.is_empty():
			_route_to_random_room()
	_follow_path(PATROL_SPEED, delta)


func _keep_aiming(delta: float) -> void:
	if not is_instance_valid(_target) or not Session.is_player_alive(_target.peer_id):
		net_state = 0
		return
	var to_target := _target.net_pos - position
	rotation.y = atan2(-to_target.x, -to_target.z)
	_aim_left -= delta
	if _aim_left > 0.0:
		return
	# Bang. It only hits if you're still in its sight.
	net_state = 0
	_reload_left = RELOAD_SECONDS
	var muzzle := position + Vector3(0, GUN_HEIGHT, 0)
	if can_see(_target, false):
		Session.play_effect("shot", muzzle, _target.net_pos + Vector3(0, 1.2, 0), 0)
		Session.damage_player(_target.peer_id, scaled_damage(DAMAGE))
	else:
		Session.play_effect("shot", muzzle, muzzle + Vector3.FORWARD.rotated(Vector3.UP, rotation.y) * SIGHT_RANGE * 0.5, 0)


func _player_in_sight() -> Player:
	for player in _targets():
		if can_see(player, true):
			return player
	return null


## In range, in the open, and (unless it's already aiming) in front of it.
func can_see(player: Player, need_facing: bool) -> bool:
	if Rules.in_ship(player.net_pos):
		return false
	var offset := player.net_pos - position
	offset.y = 0.0
	if offset.length() > SIGHT_RANGE:
		return false
	if need_facing and offset.length() > 0.5 and Vector3.FORWARD.rotated(Vector3.UP, rotation.y).dot(offset.normalized()) < SIGHT_CONE:
		return false
	var query := PhysicsRayQueryParameters3D.create(position + Vector3(0, GUN_HEIGHT, 0), player.net_pos + Vector3(0, 1.2, 0), 1)
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()
