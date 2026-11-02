class_name MudCrawler
extends Entity
## A slow heap of living mud. It oozes after anyone nearby and leaves puddles that
## slow down whoever wades through them. Touching it hurts. Shovels and shotguns
## break it up.

const SPEED := 1.3
const NOTICE_ROOMS := 3
const NOTICE_DISTANCE := 20.0
const TOUCH_RANGE := 1.3
const DAMAGE := 12
const PUDDLE_SPACING := 1.5
const PUDDLE_COUNT := 14 # The oldest puddle dries up as each new one forms.
const PUDDLE_RADIUS := 1.1
const SLOW := 0.5 # Your speed while in mud.
const MUD_COLOR := Color(0.28, 0.19, 0.1)

var net_trail := PackedVector3Array():
	set(trail):
		net_trail = trail
		_show_puddles()

var _puddles: Array[MeshInstance3D] = []
var _last_puddle := Vector3.INF


func _build(_data: Dictionary) -> void:
	grace = Rules.MONSTER_GRACE_SECONDS
	var heap := SphereMesh.new()
	heap.radius = 0.75
	heap.height = 0.9
	heap.material = Level._material(MUD_COLOR)
	var body := MeshInstance3D.new()
	body.mesh = heap
	body.position.y = 0.35
	add_child(body)
	for lump: Vector3 in [Vector3(0.45, 0.25, 0.3), Vector3(-0.4, 0.2, -0.35), Vector3(0.1, 0.65, -0.1)]:
		var blob := SphereMesh.new()
		blob.radius = 0.3
		blob.height = 0.5
		blob.material = heap.material
		var part := MeshInstance3D.new()
		part.mesh = blob
		part.position = lump
		add_child(part)
	_add_eyes(Color(1.0, 0.85, 0.2), 0.7, 0.18, 0.62, 0.06)
	var puddle_mesh := CylinderMesh.new()
	puddle_mesh.top_radius = PUDDLE_RADIUS
	puddle_mesh.bottom_radius = PUDDLE_RADIUS
	puddle_mesh.height = 0.02
	puddle_mesh.radial_segments = 14
	puddle_mesh.rings = 1
	var wet := Level._material(MUD_COLOR.darkened(0.3))
	wet.roughness = 0.2
	puddle_mesh.material = wet
	for index in PUDDLE_COUNT:
		var puddle := MeshInstance3D.new()
		puddle.mesh = puddle_mesh
		puddle.top_level = true
		puddle.visible = false
		add_child(puddle)
		_puddles.append(puddle)


func _extra_synced() -> Array[NodePath]:
	return [^":net_trail"]


func _host_tick(delta: float) -> void:
	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_SECONDS
		var target := _nearest_target(NOTICE_ROOMS, NOTICE_DISTANCE)
		if target != null:
			_route_to_point(target.net_pos)
		elif _waypoints.is_empty():
			_route_to_random_room()
	_follow_path(SPEED, delta)
	_try_attack(TOUCH_RANGE, DAMAGE)
	if _last_puddle == Vector3.INF or position.distance_to(_last_puddle) >= PUDDLE_SPACING:
		_last_puddle = position
		var trail := net_trail.duplicate()
		trail.append(Vector3(position.x, 0.0, position.z))
		while trail.size() > PUDDLE_COUNT:
			trail.remove_at(0)
		net_trail = trail


## True when this spot is in the mud: on a puddle, or right next to the crawler.
func is_muddy(pos: Vector3) -> bool:
	var flat := Vector2(pos.x, pos.z)
	if flat.distance_to(Vector2(position.x, position.z)) < TOUCH_RANGE + 0.3:
		return true
	for puddle in net_trail:
		if flat.distance_to(Vector2(puddle.x, puddle.z)) < PUDDLE_RADIUS:
			return true
	return false


func _show_puddles() -> void:
	if not is_inside_tree():
		return
	for index in _puddles.size():
		var puddle := _puddles[index]
		puddle.visible = index < net_trail.size()
		if puddle.visible:
			puddle.global_position = net_trail[index] + Vector3(0, 0.02, 0)
