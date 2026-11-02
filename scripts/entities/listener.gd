class_name Listener
extends Entity
## Blind. It hears movement: sprinting from far away, walking only up close, and
## standing still not at all. It rushes to the last sound it heard, so beat it by
## walking, freezing, or making noise and then slipping away.

const SEARCH_SPEED := 2.0
const RUSH_SPEED := 5.2
const SPRINT_HEARD_FROM := 22.0
const WALK_HEARD_FROM := 7.0
const DAMAGE := 50
const ATTACK_RANGE := 1.1
const RUSHING := 1

var _last_positions := {}


func _build(_data: Dictionary) -> void:
	grace = Rules.MONSTER_GRACE_SECONDS
	_step_bank = "monster_step"
	_add_character_body("character-female-d", 3.3, Color(0.2, 0.05, 0.08))


static func heard_from(speed: float) -> float:
	if speed > 5.0:
		return SPRINT_HEARD_FROM
	if speed > 0.3:
		return WALK_HEARD_FROM
	return 0.0


func _on_state_changed(old_state: int) -> void:
	if net_state == RUSHING and old_state != RUSHING:
		Sfx.play_3d("listener_call", position, 2.0, 35.0)


func _host_tick(delta: float) -> void:
	var heard := false
	var closest := INF
	for player: Player in Session.players_root.get_children():
		var last: Vector3 = _last_positions.get(player.peer_id, player.net_pos)
		_last_positions[player.peer_id] = player.net_pos
		if not Session.is_player_alive(player.peer_id) or Rules.in_ship(player.net_pos):
			continue
		var moved := player.net_pos - last
		moved.y = 0.0
		var distance := position.distance_to(player.net_pos)
		if distance <= heard_from(moved.length() / maxf(delta, 0.001)) and distance < closest and _rooms_to(player.net_pos) > 0:
			closest = distance
			heard = true
			_route_to_point(player.net_pos)
	if heard:
		net_state = RUSHING
	elif _waypoints.is_empty():
		net_state = 0
		_route_to_random_room()
	if _attack_timer <= 0.0:
		_follow_path(RUSH_SPEED if net_state == RUSHING else SEARCH_SPEED, delta)
		_try_attack(ATTACK_RANGE, DAMAGE)
