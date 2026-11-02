class_name Watcher
extends Entity
## A pale statue. It freezes while any living player can see it, and rushes when
## nobody can. Beat it by keeping someone's eyes on it while the crew moves past.

const SPEED := 6.0
const DAMAGE := 50
const NOTICE_ROOMS := 4
const VIEW_DISTANCE := 30.0
const VIEW_CONE := 0.45 # Dot product: about 60 degrees either side of straight ahead.
const MOVING := 1


func _build(_data: Dictionary) -> void:
	grace = Rules.MONSTER_GRACE_SECONDS
	_step_bank = "watcher_step"
	_step_distance = 3.0
	_add_character_body("character-male-e", 3.2, Color(0.82, 0.84, 0.86))


func stun(seconds: float) -> void:
	super.stun(seconds)
	net_state = 0


func _host_tick(delta: float) -> void:
	if is_seen():
		net_state = 0
		return
	var target := _nearest_target(NOTICE_ROOMS, 1000.0)
	if target == null:
		net_state = 0
		return
	net_state = MOVING
	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_SECONDS
		_route_to_point(target.net_pos)
	if _attack_timer <= 0.0:
		_follow_path(SPEED, delta)
		_try_attack(Rules.MONSTER_ATTACK_RANGE, DAMAGE)


## Line of sight is tested against the real walls and props.
func is_seen() -> bool:
	var space := get_world_3d().direct_space_state
	var chest := position + Vector3(0, 1.3, 0)
	for player: Player in Session.players_root.get_children():
		if not Session.is_player_alive(player.peer_id):
			continue
		var eye := player.net_pos + Vector3(0, 1.6, 0)
		var offset := chest - eye
		if offset.length() > VIEW_DISTANCE:
			continue
		var facing := Vector3.FORWARD.rotated(Vector3.UP, player.net_yaw)
		if facing.dot(offset.normalized()) < VIEW_CONE:
			continue
		var query := PhysicsRayQueryParameters3D.create(eye, chest, 1)
		if space.intersect_ray(query).is_empty():
			return true
	return false


func _animate_and_step(delta: float) -> void:
	super._animate_and_step(delta)
	# A frozen Watcher is completely still, mid-stride if need be.
	_animator.speed_scale = 1.0 if net_state == MOVING else 0.0
