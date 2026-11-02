class_name Tools
extends RefCounted
## The gear the crew buys at the ship's terminal, and what each piece does. Every
## use is worked out on the host, which then tells everyone what happened.

const SHOVEL := "Shovel"
const STUN_GRENADE := "Stun grenade"
const ZAP_GUN := "Zap gun"
const ORDER: Array[String] = [SHOVEL, STUN_GRENADE, ZAP_GUN]
const CATALOG := {
	SHOVEL: {
		"price": 30, "weight": 0.08, "charges": 0,
		"about": "Swing it to bonk a hunter. Every hit stuns it, and enough hits finish it off. It bonks crewmates too.",
	},
	STUN_GRENADE: {
		"price": 25, "weight": 0.03, "charges": 0,
		"about": "Throw it, then look away. The bang stuns every hunter in sight of it for 6 seconds. One use.",
	},
	ZAP_GUN: {
		"price": 70, "weight": 0.06, "charges": 3,
		"about": "Aim at a hunter and zap it to freeze it for 5 seconds. 3 charges, refilled every time you're back in orbit.",
	},
}
const FIRST_ID := 1000000 # Gear ids start here, far above any facility's scrap count.

const SHOVEL_RANGE := 2.4
const SHOVEL_CONE := 0.5 # Dot product: about 60 degrees either side of where you face.
const SHOVEL_STUN := 2.0
const SHOVEL_CREW_DAMAGE := 20
const SHOVEL_COOLDOWN := 0.7
const ZAP_RANGE := 15.0
const ZAP_CONE := 0.92 # About 23 degrees: you have to actually aim.
const ZAP_STUN := 5.0
const ZAP_COOLDOWN := 0.6
const THROW_DISTANCE := 7.0
const THROW_COOLDOWN := 0.5
const FUSE_SECONDS := 1.5
const BLAST_RADIUS := 9.0
const BLAST_STUN := 6.0
const BLIND_SECONDS := 2.5

const WOOD := Color(0.55, 0.36, 0.2)
const METAL := Color(0.62, 0.64, 0.68)
const DARK := Color(0.12, 0.12, 0.14)
const OLIVE := Color(0.25, 0.36, 0.16)
const YELLOW := Color(0.95, 0.72, 0.12)
const ZAP_BLUE := Color(0.35, 0.75, 1.0)


static func is_gear(kind: String) -> bool:
	return CATALOG.has(kind)


# --- What happens: these run on the host, in the physics step, so walls can be checked ---

## Uses the item and returns how long until this player can use something again.
static func use(player: Player, item: Scrap) -> float:
	match item.kind:
		SHOVEL:
			_swing(player, item)
			return SHOVEL_COOLDOWN
		ZAP_GUN:
			_zap(player, item)
			return ZAP_COOLDOWN
		STUN_GRENADE:
			_throw(player, item)
			return THROW_COOLDOWN
	return 0.0


static func _swing(player: Player, item: Scrap) -> void:
	Session.play_effect("swing", player.net_pos, player.net_pos, item.item_id)
	var hunter := _hunter_in_front(player, SHOVEL_RANGE, SHOVEL_CONE, true)
	if hunter != null:
		Session.play_effect("bonk", hunter.position, hunter.position, 0)
		hunter.hurt(SHOVEL_STUN)
		return
	var crewmate := _crewmate_in_front(player)
	if crewmate != null:
		Session.play_effect("bonk", crewmate.net_pos, crewmate.net_pos, 0)
		Session.damage_player(crewmate.peer_id, SHOVEL_CREW_DAMAGE)


static func _zap(player: Player, item: Scrap) -> void:
	if item.charges <= 0:
		Session.play_effect("empty", player.net_pos, player.net_pos, item.item_id)
		return
	var hunter := _hunter_in_front(player, ZAP_RANGE, ZAP_CONE, false)
	if hunter == null:
		# A miss costs nothing, so a wasted press never empties the gun.
		Session.play_effect("fizzle", player.net_pos, player.net_pos, item.item_id)
		return
	item.charges -= 1
	hunter.stun(ZAP_STUN)
	Session.play_effect("zap", player.net_pos + Vector3(0, 1.2, 0), hunter.position + Vector3(0, 1.0, 0), item.item_id)


static func _throw(player: Player, item: Scrap) -> void:
	var facing := _facing(player)
	var eye := player.net_pos + Vector3(0, 1.4, 0)
	var land := eye + facing * THROW_DISTANCE
	var hit := _space(player).intersect_ray(PhysicsRayQueryParameters3D.create(eye, land, 1))
	if not hit.is_empty():
		land = hit.position - facing * 0.4
	Session.throw_item(player.peer_id, item, Vector3(land.x, Scrap.FLOOR_HEIGHT, land.z))


## A stun grenade going off. Hunters behind a wall are safe from it.
static func explode(item: Scrap) -> void:
	var center := item.position + Vector3(0, 0.6, 0)
	var space := item.get_world_3d().direct_space_state
	for entity: Entity in Session.entity_root.get_children():
		if not _is_hunter(entity, false):
			continue
		var target := entity.position + Vector3(0, 1.0, 0)
		if center.distance_to(target) > BLAST_RADIUS:
			continue
		if space.intersect_ray(PhysicsRayQueryParameters3D.create(center, target, 1)).is_empty():
			entity.stun(BLAST_STUN)
	Session.play_effect("boom", item.position, item.position, item.item_id)


## Mimics only count for the shovel: zapping or blasting a box would give it away.
static func _is_hunter(entity: Entity, mimics_too: bool) -> bool:
	if not entity.is_hostile() or entity.kind == "gas":
		return false
	return mimics_too or entity.kind != "mimic"


static func _hunter_in_front(player: Player, reach: float, cone: float, mimics_too: bool) -> Entity:
	var best: Entity = null
	var best_distance := reach
	for entity: Entity in Session.entity_root.get_children():
		# Zapping a hunter that's already stunned would waste a charge.
		if not _is_hunter(entity, mimics_too) or (not mimics_too and entity.net_stunned):
			continue
		var distance := _flat_distance(player, entity.position)
		if distance < best_distance and _in_front(player, entity.position, cone) and _clear_line(player, entity.position + Vector3(0, 1.0, 0)):
			best_distance = distance
			best = entity
	return best


static func _crewmate_in_front(player: Player) -> Player:
	var best: Player = null
	var best_distance := SHOVEL_RANGE
	for other: Player in Session.players_root.get_children():
		if other == player or not Session.is_player_alive(other.peer_id):
			continue
		var distance := _flat_distance(player, other.net_pos)
		if distance < best_distance and _in_front(player, other.net_pos, SHOVEL_CONE) and _clear_line(player, other.net_pos + Vector3(0, 1.2, 0)):
			best_distance = distance
			best = other
	return best


static func _facing(player: Player) -> Vector3:
	return Vector3.FORWARD.rotated(Vector3.UP, player.net_yaw)


static func _flat_distance(player: Player, pos: Vector3) -> float:
	return Vector2(pos.x - player.net_pos.x, pos.z - player.net_pos.z).length()


static func _in_front(player: Player, pos: Vector3, cone: float) -> bool:
	var offset := pos - player.net_pos
	offset.y = 0.0
	# Something right on top of you counts, whichever way you face.
	return offset.length() < 0.4 or _facing(player).dot(offset.normalized()) >= cone


static func _clear_line(player: Player, to: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(player.net_pos + Vector3(0, 1.4, 0), to, 1)
	return _space(player).intersect_ray(query).is_empty()


static func _space(player: Player) -> PhysicsDirectSpaceState3D:
	return player.get_world_3d().direct_space_state


# --- What they look like: simple shapes, so they can't be mistaken for scrap ---

## Built standing up, with the business end toward -Z.
static func build_model(kind: String) -> Node3D:
	var root := Node3D.new()
	match kind:
		SHOVEL:
			_part(root, _cylinder(0.03, 1.0), Vector3(0, 0.62, 0), WOOD)
			_part(root, _box(Vector3(0.2, 0.05, 0.05)), Vector3(0, 1.13, 0), DARK)
			_part(root, _box(Vector3(0.26, 0.3, 0.03)), Vector3(0, 0.15, 0), METAL)
		STUN_GRENADE:
			_part(root, _sphere(0.09), Vector3(0, 0.09, 0), OLIVE)
			_part(root, _cylinder(0.035, 0.07), Vector3(0, 0.2, 0), METAL)
			_part(root, _box(Vector3(0.02, 0.12, 0.05)), Vector3(0.05, 0.17, 0), METAL)
		ZAP_GUN:
			_part(root, _box(Vector3(0.12, 0.13, 0.38)), Vector3(0, 0.17, 0), YELLOW)
			_part(root, _box(Vector3(0.08, 0.16, 0.08)), Vector3(0, 0.06, 0.11), DARK)
			var barrel := _part(root, _cylinder(0.035, 0.2), Vector3(0, 0.17, -0.28), ZAP_BLUE)
			barrel.rotation.x = PI * 0.5
			barrel.name = "Barrel"
			var material: StandardMaterial3D = barrel.mesh.material
			material.emission_enabled = true
			material.emission = ZAP_BLUE
	return root


static func _part(root: Node3D, mesh: PrimitiveMesh, pos: Vector3, color: Color) -> MeshInstance3D:
	mesh.material = Level._material(color)
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.position = pos
	root.add_child(part)
	return part


static func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh


static func _cylinder(radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 10
	mesh.rings = 1
	return mesh


static func _sphere(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	return mesh
