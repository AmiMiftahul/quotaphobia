class_name Ghost
extends Entity
## A floating spirit that drifts straight through walls toward the nearest player. A
## flashlight beam on it drives it back, and a burning flare keeps it away. If it
## reaches you it strikes once, then fades and comes back somewhere far off.

const SPEED := 2.4
const FLEE_SPEED := 3.2
const HOVER := 1.4
const NOTICE_DISTANCE := 26.0
const BEAM_RANGE := 12.0
const BEAM_CONE := 0.9 # Dot product: the middle of the flashlight's beam.
const TOUCH_RANGE := 1.0
const DAMAGE := 30
const RETURN_GRACE := 6.0 # After a strike it stays away this long.
const FLEEING := 1
const BODY_COLOR := Color(0.75, 0.9, 1.0, 0.45)

var _body: Node3D
var _time := 0.0


func _build(_data: Dictionary) -> void:
	grace = Rules.MONSTER_GRACE_SECONDS
	position.y = HOVER
	net_pos.y = HOVER
	_last_position.y = HOVER
	_body = Node3D.new()
	add_child(_body)
	var glass := StandardMaterial3D.new()
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glass.albedo_color = BODY_COLOR
	var head := SphereMesh.new()
	head.radius = 0.35
	head.height = 0.7
	head.material = glass
	var tail := CylinderMesh.new()
	tail.top_radius = 0.33
	tail.bottom_radius = 0.02
	tail.height = 0.9
	tail.material = glass
	for part: Array in [[head, Vector3(0, 0.3, 0)], [tail, Vector3(0, -0.2, 0)]]:
		var shape := MeshInstance3D.new()
		shape.mesh = part[0]
		shape.position = part[1]
		_body.add_child(shape)
	var before := get_child_count()
	_add_eyes(Color(0.2, 0.9, 1.0), 0.38, 0.12, 0.3, 0.06)
	# The eyes bob with the body.
	for eye in get_children().slice(before):
		eye.reparent(_body, false)
	_make_light(Color(0.6, 0.85, 1.0), 0.8, 6.0, 0.2)


func _on_state_changed(_old_state: int) -> void:
	if net_state == FLEEING:
		Sfx.play_3d("listener_call", position, -2.0, 20.0)


func _process(delta: float) -> void:
	# A slow bob, on every machine, so it never looks like it's standing on anything.
	_time += delta
	_body.position.y = sin(_time * 2.0) * 0.12


func _host_tick(delta: float) -> void:
	var target := _nearest_player()
	if target == null:
		net_state = 0
		return
	var away_from := _light_on_me()
	if away_from != Vector3.INF:
		net_state = FLEEING
		var away := position - away_from
		away.y = 0.0
		_move(away.normalized() * FLEE_SPEED * _power.speed * delta)
		return
	net_state = 0
	var toward := target.net_pos - position
	toward.y = 0.0
	if toward.length() < TOUCH_RANGE:
		Session.damage_player(target.peer_id, scaled_damage(DAMAGE))
		net_attacks += 1
		_fade_away(target)
		return
	_move(toward.normalized() * minf(SPEED * _power.speed * delta, toward.length()))
	rotation.y = atan2(-toward.x, -toward.z)


## Walls don't stop it, but the ship does.
func _move(step: Vector3) -> void:
	var next := position + step
	next.y = HOVER
	if not Rules.in_ship(next):
		position = next


## After a strike it vanishes and comes back in the room farthest from its victim.
func _fade_away(victim: Player) -> void:
	var best := FacilityLayout.cell_center(_layout.monster_spawn)
	for cell in _layout.all_cells():
		var spot := FacilityLayout.cell_center(cell)
		if spot.distance_to(victim.net_pos) > best.distance_to(victim.net_pos):
			best = spot
	position = Vector3(best.x, HOVER, best.z)
	_last_position = position
	grace = RETURN_GRACE


func _nearest_player() -> Player:
	var best: Player = null
	var best_distance := NOTICE_DISTANCE
	for player in _targets():
		var distance := position.distance_to(player.net_pos)
		if distance < best_distance:
			best_distance = distance
			best = player
	return best


## Where the light that's driving it off is, or INF if nothing is.
func _light_on_me() -> Vector3:
	for item: Scrap in Session.scrap_root.get_children():
		if item.kind == Tools.FLARE and item.armed and item.position.distance_to(position) < Tools.FLARE_RADIUS:
			return item.position
	var space := get_world_3d().direct_space_state
	for player: Player in Session.players_root.get_children():
		if not player.net_flashlight or not Session.is_player_alive(player.peer_id):
			continue
		var eye := player.net_pos + Vector3(0, 1.6, 0)
		var offset := position - eye
		if offset.length() > BEAM_RANGE:
			continue
		var flat := Vector3(offset.x, 0, offset.z)
		var facing := Vector3.FORWARD.rotated(Vector3.UP, player.net_yaw)
		if flat.length() > 0.5 and facing.dot(flat.normalized()) < BEAM_CONE:
			continue
		if space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, position, 1)).is_empty():
			return player.net_pos
	return Vector3.INF
