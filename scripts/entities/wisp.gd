class_name Wisp
extends Entity
## A friendly light that drifts ahead of the nearest player, toward the closest
## scrap. It turns red and chirps when a hunter is close. It's a ghost: walls
## don't stop it, so it can always keep up.

const SPEED := 7.0
const HOVER := 1.6
const LEAD_DISTANCE := 3.0
const DANGER_DISTANCE := 13.0
const WARNING := 1
const CALM_COLOR := Color(0.55, 0.85, 1.0)
const DANGER_COLOR := Color(1.0, 0.15, 0.1)

var _light: OmniLight3D
var _orb: StandardMaterial3D


func _build(_data: Dictionary) -> void:
	position.y = HOVER
	net_pos.y = HOVER
	_last_position.y = HOVER
	var mesh := SphereMesh.new()
	mesh.radius = 0.16
	mesh.height = 0.32
	_orb = StandardMaterial3D.new()
	_orb.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_orb.albedo_color = CALM_COLOR
	mesh.material = _orb
	var orb := MeshInstance3D.new()
	orb.mesh = mesh
	add_child(orb)
	_light = _make_light(CALM_COLOR, 1.4, 9.0, 0.0)


func _on_state_changed(old_state: int) -> void:
	var color := DANGER_COLOR if net_state == WARNING else CALM_COLOR
	_orb.albedo_color = color
	_light.light_color = color
	if net_state == WARNING and old_state != WARNING:
		Sfx.play_3d("wisp_warn", position, 0.0, 25.0)


func _host_tick(delta: float) -> void:
	net_state = WARNING if _hunter_nearby() else 0
	var leader := _nearest_player()
	if leader == null:
		return
	var aim := leader.net_pos + _direction_to_scrap(leader) * LEAD_DISTANCE
	aim.y = HOVER
	position = position.move_toward(aim, SPEED * delta)


func _hunter_nearby() -> bool:
	for entity: Entity in Session.entity_root.get_children():
		if entity.is_hostile() and entity.kind not in ["mimic", "gas"] and position.distance_to(entity.position) < DANGER_DISTANCE:
			return true
	return false


func _nearest_player() -> Player:
	var best: Player = null
	var best_distance := INF
	for player: Player in Session.players_root.get_children():
		if not Session.is_player_alive(player.peer_id):
			continue
		var distance := position.distance_to(player.net_pos)
		if distance < best_distance:
			best_distance = distance
			best = player
	return best


## Toward the next door on the way to the nearest free scrap outside the ship.
func _direction_to_scrap(leader: Player) -> Vector3:
	var goal: Scrap = null
	var best_distance := INF
	for item: Scrap in Session.scrap_root.get_children():
		if item.holder_id != 0 or Rules.in_ship(item.position):
			continue
		var distance := leader.net_pos.distance_to(item.position)
		if distance < best_distance:
			best_distance = distance
			goal = item
	if goal == null:
		return Vector3.ZERO
	var point := goal.position
	var here := FacilityLayout.cell_at(leader.net_pos)
	if Rules.in_ship(leader.net_pos):
		point = FacilityLayout.cell_center(FacilityLayout.ENTRY_CELL)
	else:
		var cells := _layout.path(here, FacilityLayout.cell_at(goal.position))
		if cells.size() >= 2:
			point = (FacilityLayout.cell_center(cells[0]) + FacilityLayout.cell_center(cells[1])) * 0.5
	var direction := point - leader.net_pos
	direction.y = 0.0
	return direction.normalized()
