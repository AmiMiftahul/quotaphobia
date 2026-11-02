class_name Monster
extends Entity
## The Stalker: a huge black figure that patrols, spots players and runs them down.

const PATROL_SPEED := 2.5
const CHASE_SPEED := 4.4
const SIGHT_RANGE := 18.0
const SIGHT_ROOMS := 3 # Route length, counting its own room, at which it notices you.

var net_chasing := false:
	set(chasing):
		if chasing and not net_chasing and is_inside_tree():
			Sfx.play_3d("monster_growl", position, 4.0, 35.0)
		net_chasing = chasing


func _build(_data: Dictionary) -> void:
	grace = Rules.MONSTER_GRACE_SECONDS
	_step_bank = "monster_step"
	_add_character_body("character-male-c", 3.8, Color(0.015, 0.012, 0.015))
	_add_eyes(Color.RED, 1.75, 0.28, 0.72)


func _extra_synced() -> Array[NodePath]:
	return [^":net_chasing"]


func stun(seconds: float) -> void:
	super.stun(seconds)
	net_chasing = false


func _host_tick(delta: float) -> void:
	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_SECONDS
		var target := _nearest_target(SIGHT_ROOMS, SIGHT_RANGE)
		if target != null:
			net_chasing = true
			_route_to_point(target.net_pos)
		elif net_chasing or _waypoints.is_empty():
			net_chasing = false
			_route_to_random_room()
	if _attack_timer <= 0.0:
		_follow_path(CHASE_SPEED if net_chasing else PATROL_SPEED, delta)
		_try_attack(Rules.MONSTER_ATTACK_RANGE, Rules.MONSTER_DAMAGE)
