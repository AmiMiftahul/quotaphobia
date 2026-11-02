class_name Tools
extends RefCounted
## The gear the crew buys at the ship's terminal, and what each piece does. Every
## use is worked out on the host, which then tells everyone what happened.

const SHOVEL := "Shovel"
const STUN_GRENADE := "Stun grenade"
const ZAP_GUN := "Zap gun"
const CAMCORDER := "Camcorder"
const SHOTGUN := "Shotgun"
const FLASHBANG := "Flashbang"
const ADRENALINE := "Adrenaline shot"
const SCOOTER := "Hover scooter"
const BEACON := "Recall beacon"
# Found in the facility, never sold.
const MEDKIT := "Med kit"
const FLARE := "Flare"
const BATTERY := "Battery"
const FINDS: Array[String] = [MEDKIT, FLARE, BATTERY]
const ORDER: Array[String] = [SHOVEL, STUN_GRENADE, FLASHBANG, ZAP_GUN, SHOTGUN, ADRENALINE, SCOOTER, BEACON, CAMCORDER]
# What a gacha capsule can hold: everyday gear, or a rare piece.
const GACHA_GEAR: Array[String] = [SHOVEL, STUN_GRENADE, FLASHBANG, ADRENALINE]
const GACHA_RARE: Array[String] = [ZAP_GUN, SHOTGUN, SCOOTER, BEACON, CAMCORDER]
const CATALOG := {
	SHOVEL: {
		"price": 30, "weight": 0.08, "charges": 0,
		"about": "Swing it to bonk a hunter. Each hit staggers it for a moment, and enough hits finish it off. It bonks crewmates too.",
	},
	STUN_GRENADE: {
		"price": 25, "weight": 0.03, "charges": 0,
		"about": "Throw it, then look away. The bang stuns every hunter in sight of it for 6 seconds. One use.",
	},
	ZAP_GUN: {
		"price": 70, "weight": 0.06, "charges": 3,
		"about": "Aim at a hunter and zap it to freeze it for 5 seconds. 3 charges, refilled every time you're back in orbit.",
	},
	SHOTGUN: {
		"price": 110, "weight": 0.12, "charges": 3,
		"about": "Fires a blast up to 18 m. One shot takes 3 hits off a hunter and stuns it, so a Stalker drops in two. It hurts crewmates badly too. 3 shells, refilled in orbit.",
	},
	FLASHBANG: {
		"price": 15, "weight": 0.02, "charges": 0,
		"about": "Throw it and it bangs almost at once: every hunter within 13 m that can see it is stunned for 3.5 seconds. Cheap, fast, and blinding for anyone looking. One use.",
	},
	ADRENALINE: {
		"price": 20, "weight": 0.01, "charges": 0,
		"about": "Inject it for 12 seconds of 40% more speed and stamina that never runs out. One use.",
	},
	SCOOTER: {
		"price": 80, "weight": 0.1, "charges": 0,
		"about": "Left click to hop on and ride at 8 m/s without using stamina. It's loud, so Listeners hear you, and you can't jump. Click again to step off.",
	},
	BEACON: {
		"price": 50, "weight": 0.03, "charges": 0,
		"about": "Hold it up and after 2 seconds you're beamed back into the ship with everything you carry. Only works on the ground. One use.",
	},
	MEDKIT: {
		"price": 0, "weight": 0.04, "charges": 0, "found": true,
		"about": "Found in the facility. Patches you up for 50 health. One use.",
	},
	FLARE: {
		"price": 0, "weight": 0.02, "charges": 0, "found": true,
		"about": "Found in the facility. Throw it and it burns bright red for 30 seconds. Ghosts won't come near it.",
	},
	BATTERY: {
		"price": 0, "weight": 0.03, "charges": 0, "found": true,
		"about": "Found in the facility. Refills every zap gun and shotgun you carry. One use.",
	},
	CAMCORDER: {
		"price": 40, "weight": 0.05, "charges": 0,
		"about": "Takes photos and 5-second clips, and keeps the last 12 on it. Anyone holding it can play them back. Footage stays on it between days, as long as it comes home.",
	},
}
const FIRST_ID := 1000000 # Gear ids start here, far above any facility's scrap count.

const SHOVEL_RANGE := 2.4
const SHOVEL_CONE := 0.5 # Dot product: about 60 degrees either side of where you face.
# A hit staggers for less time than a swing takes, so a hunter always gets a moment to
# strike back. A shovel fight is winnable, but it costs health.
const SHOVEL_STUN := 0.6
const SHOVEL_CREW_DAMAGE := 20
const SHOVEL_COOLDOWN := 0.9
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
const SHOTGUN_RANGE := 18.0
const SHOTGUN_CONE := 0.95 # About 18 degrees.
const SHOTGUN_BLOWS := 3 # Shovel hits' worth of damage, per shot.
const SHOTGUN_STUN := 1.5
const SHOTGUN_CREW_DAMAGE := 60
const SHOTGUN_COOLDOWN := 1.0
const FLASH_FUSE := 0.6
const FLASH_RADIUS := 13.0
const FLASH_STUN := 3.5
const FLASH_BLIND := 4.0
const ADRENALINE_SECONDS := 12.0
const ADRENALINE_SPEED := 1.4
const SCOOTER_SPEED := 8.0
const BEACON_SECONDS := 2.0
const BEACON_SPOT := Vector3(0.0, 0.1, -9.0) # Where the beam puts you down, in the ship.
const BEACON_GREEN := Color(0.4, 1.0, 0.55)
const MEDKIT_HEAL := 50
const FLARE_SECONDS := 30.0
const FLARE_RADIUS := 8.0 # Ghosts keep at least this far from a burning flare.
const FLARE_RED := Color(1.0, 0.25, 0.15)
# What the camcorder stores. A clip is a run of small JPEG pictures, so it can travel
# between players without a video codec.
const TAPE_LIMIT := 12 # Recordings kept; a new one pushes out the oldest.
const CLIP_SECONDS := 5.0
const CLIP_FPS := 12.0
const CLIP_SIZE := Vector2i(320, 180)
const SNAPSHOT_SIZE := Vector2i(640, 360)
const MAX_FRAME_BYTES := 200000 # The host refuses anything bigger: no flooding the crew.
const MAX_RECORDING_BYTES := 3000000

const WOOD := Color(0.55, 0.36, 0.2)
const METAL := Color(0.62, 0.64, 0.68)
const DARK := Color(0.12, 0.12, 0.14)
const OLIVE := Color(0.25, 0.36, 0.16)
const YELLOW := Color(0.95, 0.72, 0.12)
const ZAP_BLUE := Color(0.35, 0.75, 1.0)
const LENS := Color(0.2, 0.3, 0.45)


static func is_gear(kind: String) -> bool:
	return CATALOG.has(kind)


## Picked up in the facility rather than bought. It doesn't count toward the crew's gear limit.
static func is_find(kind: String) -> bool:
	return CATALOG.has(kind) and CATALOG[kind].get("found", false)


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
		STUN_GRENADE, FLASHBANG, FLARE:
			_throw(player, item)
			return THROW_COOLDOWN
		MEDKIT:
			if Session.player_states[player.peer_id].hp >= Rules.PLAYER_MAX_HP:
				Session.play_effect("fizzle", player.net_pos, player.net_pos, item.item_id)
				return THROW_COOLDOWN
			Session.play_effect("patched", player.net_pos, player.net_pos, item.item_id)
			Session.use_up(item)
			Session.heal_player(player.peer_id, MEDKIT_HEAL)
			return THROW_COOLDOWN
		BATTERY:
			_recharge(player, item)
			return THROW_COOLDOWN
		SHOTGUN:
			_fire(player, item)
			return SHOTGUN_COOLDOWN
		ADRENALINE:
			Session.play_effect("inject", player.net_pos, player.net_pos, item.item_id)
			Session.use_up(item)
			Session.boost_player(player.peer_id, ADRENALINE_SECONDS)
			return THROW_COOLDOWN
		BEACON:
			Session.start_recall(player, item)
			return BEACON_SECONDS
	return 0.0


## How long a thrown piece of gear takes to go off, or for a flare, to burn out.
static func fuse_for(kind: String) -> float:
	match kind:
		FLASHBANG: return FLASH_FUSE
		FLARE: return FLARE_SECONDS
	return FUSE_SECONDS


## Fills every zap gun and shotgun this player carries. Nothing to fill, nothing used.
static func _recharge(player: Player, item: Scrap) -> void:
	var filled := false
	for gear: Scrap in Session.items_held_by(player.peer_id):
		var most: int = CATALOG[gear.kind].charges if gear.is_tool() else 0
		if most > 0 and gear.charges < most:
			gear.charges = most
			filled = true
	if not filled:
		Session.play_effect("fizzle", player.net_pos, player.net_pos, item.item_id)
		return
	Session.play_effect("recharge", player.net_pos, player.net_pos, item.item_id)
	Session.use_up(item)


## [radius, stun seconds, blind seconds] for whatever just went bang.
static func blast_for(kind: String) -> Array:
	if kind == FLASHBANG:
		return [FLASH_RADIUS, FLASH_STUN, FLASH_BLIND]
	return [BLAST_RADIUS, BLAST_STUN, BLIND_SECONDS]


static func _swing(player: Player, item: Scrap) -> void:
	Session.play_effect("swing", player.net_pos, player.net_pos, item.item_id)
	var hunter := _hunter_in_front(player, SHOVEL_RANGE, SHOVEL_CONE, true)
	if hunter != null:
		Session.play_effect("bonk", hunter.position, hunter.position, 0)
		hunter.hurt(SHOVEL_STUN)
		return
	var crewmate := _crewmate_in_front(player, SHOVEL_RANGE, SHOVEL_CONE)
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


## One shell, whatever it hits. A shot that hits nothing still uses it.
static func _fire(player: Player, item: Scrap) -> void:
	if item.charges <= 0:
		Session.play_effect("empty", player.net_pos, player.net_pos, item.item_id)
		return
	item.charges -= 1
	var muzzle := player.net_pos + Vector3(0, 1.3, 0)
	var hunter := _hunter_in_front(player, SHOTGUN_RANGE, SHOTGUN_CONE, true)
	var crewmate := _crewmate_in_front(player, SHOTGUN_RANGE, SHOTGUN_CONE)
	var hunter_distance := _flat_distance(player, hunter.position) if hunter != null else INF
	if crewmate != null and _flat_distance(player, crewmate.net_pos) < hunter_distance:
		Session.play_effect("shot", muzzle, crewmate.net_pos + Vector3(0, 1.2, 0), item.item_id)
		Session.damage_player(crewmate.peer_id, SHOTGUN_CREW_DAMAGE)
		return
	if hunter == null:
		# Nothing in the way: the blast flies until it hits a wall.
		var far := muzzle + _facing(player) * SHOTGUN_RANGE
		var hit := _space(player).intersect_ray(PhysicsRayQueryParameters3D.create(muzzle, far, 1))
		Session.play_effect("shot", muzzle, hit.position if not hit.is_empty() else far, item.item_id)
		return
	Session.play_effect("shot", muzzle, hunter.position + Vector3(0, 1.0, 0), item.item_id)
	if hunter.max_hits() <= 0:
		hunter.stun(SHOTGUN_STUN * 2.0) # Nothing hurts a Watcher, but a blast still rocks it.
	else:
		hunter.hurt(SHOTGUN_STUN, SHOTGUN_BLOWS)


static func _throw(player: Player, item: Scrap) -> void:
	var facing := _facing(player)
	var eye := player.net_pos + Vector3(0, 1.4, 0)
	var land := eye + facing * THROW_DISTANCE
	var hit := _space(player).intersect_ray(PhysicsRayQueryParameters3D.create(eye, land, 1))
	if not hit.is_empty():
		land = hit.position - facing * 0.4
	Session.throw_item(player.peer_id, item, Vector3(land.x, Scrap.FLOOR_HEIGHT, land.z))


## A stun grenade or flashbang going off. Hunters behind a wall are safe from it.
static func explode(item: Scrap) -> void:
	var center := item.position + Vector3(0, 0.6, 0)
	var space := item.get_world_3d().direct_space_state
	var blast := blast_for(item.kind)
	for entity: Entity in Session.entity_root.get_children():
		if not _is_hunter(entity, false):
			continue
		var target := entity.position + Vector3(0, 1.0, 0)
		if center.distance_to(target) > blast[0]:
			continue
		if space.intersect_ray(PhysicsRayQueryParameters3D.create(center, target, 1)).is_empty():
			entity.stun(blast[1])
	Session.play_effect("flashbang" if item.kind == FLASHBANG else "boom", item.position, item.position, item.item_id)


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


static func _crewmate_in_front(player: Player, reach: float, cone: float) -> Player:
	var best: Player = null
	var best_distance := reach
	for other: Player in Session.players_root.get_children():
		if other == player or not Session.is_player_alive(other.peer_id):
			continue
		var distance := _flat_distance(player, other.net_pos)
		if distance < best_distance and _in_front(player, other.net_pos, cone) and _clear_line(player, other.net_pos + Vector3(0, 1.2, 0)):
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
		MEDKIT:
			_part(root, _box(Vector3(0.3, 0.2, 0.12)), Vector3(0, 0.1, 0), Color(0.92, 0.92, 0.9))
			_part(root, _box(Vector3(0.14, 0.04, 0.124)), Vector3(0, 0.1, 0), Color(0.85, 0.1, 0.1))
			_part(root, _box(Vector3(0.04, 0.14, 0.124)), Vector3(0, 0.1, 0), Color(0.85, 0.1, 0.1))
			_part(root, _box(Vector3(0.1, 0.03, 0.03)), Vector3(0, 0.215, 0), DARK)
		FLARE:
			var stick := _part(root, _cylinder(0.025, 0.26), Vector3(0, 0.03, 0), FLARE_RED)
			stick.rotation.x = PI * 0.5
			var cap := _part(root, _cylinder(0.028, 0.05), Vector3(0, 0.03, -0.15), DARK)
			cap.rotation.x = PI * 0.5
		BATTERY:
			_part(root, _cylinder(0.05, 0.16), Vector3(0, 0.08, 0), DARK)
			_part(root, _cylinder(0.052, 0.06), Vector3(0, 0.13, 0), YELLOW)
			_part(root, _cylinder(0.02, 0.03), Vector3(0, 0.175, 0), METAL)
		CAMCORDER:
			_part(root, _box(Vector3(0.11, 0.13, 0.26)), Vector3(0, 0.1, 0), DARK)
			var lens := _part(root, _cylinder(0.045, 0.08), Vector3(0, 0.11, -0.16), LENS)
			lens.rotation.x = PI * 0.5
			_part(root, _box(Vector3(0.015, 0.08, 0.12)), Vector3(-0.065, 0.11, 0.0), METAL) # The flip-out screen.
			var light := _part(root, _sphere(0.014), Vector3(0.03, 0.18, -0.1), Color.RED)
			light.name = "RecLight"
			var glow: StandardMaterial3D = light.mesh.material
			glow.emission_enabled = true
			glow.emission = Color.RED
			glow.emission_energy_multiplier = 4.0
			light.visible = false
		SHOTGUN:
			_part(root, _box(Vector3(0.07, 0.09, 0.4)), Vector3(0, 0.12, 0.12), WOOD) # The stock.
			var barrel := _part(root, _cylinder(0.03, 0.62), Vector3(0, 0.15, -0.36), DARK)
			barrel.rotation.x = PI * 0.5
			var pump := _part(root, _cylinder(0.04, 0.16), Vector3(0, 0.1, -0.28), WOOD)
			pump.rotation.x = PI * 0.5
		FLASHBANG:
			_part(root, _cylinder(0.05, 0.16), Vector3(0, 0.08, 0), METAL)
			_part(root, _cylinder(0.052, 0.04), Vector3(0, 0.1, 0), YELLOW)
			_part(root, _box(Vector3(0.02, 0.1, 0.04)), Vector3(0.055, 0.12, 0), DARK)
		ADRENALINE:
			var tube := _part(root, _cylinder(0.025, 0.18), Vector3(0, 0.09, 0), Color(0.9, 0.2, 0.25))
			tube.rotation.x = PI * 0.5
			var needle := _part(root, _cylinder(0.005, 0.07), Vector3(0, 0.09, -0.12), METAL)
			needle.rotation.x = PI * 0.5
			_part(root, _box(Vector3(0.06, 0.02, 0.02)), Vector3(0, 0.09, 0.1), DARK)
		SCOOTER:
			_part(root, _box(Vector3(0.36, 0.06, 1.0)), Vector3(0, 0.06, 0), DARK) # The deck.
			var glow := _part(root, _box(Vector3(0.3, 0.02, 0.9)), Vector3(0, 0.02, 0), ZAP_BLUE)
			var material: StandardMaterial3D = glow.mesh.material
			material.emission_enabled = true
			material.emission = ZAP_BLUE
			material.emission_energy_multiplier = 2.0
			_part(root, _cylinder(0.025, 0.9), Vector3(0, 0.5, -0.42), METAL) # The handlebar post.
			var bar := _part(root, _cylinder(0.02, 0.4), Vector3(0, 0.94, -0.42), DARK)
			bar.rotation.z = PI * 0.5
		BEACON:
			_part(root, _box(Vector3(0.12, 0.16, 0.08)), Vector3(0, 0.08, 0), DARK)
			_part(root, _cylinder(0.008, 0.16), Vector3(0.04, 0.24, 0), METAL)
			var lamp := _part(root, _sphere(0.03), Vector3(0, 0.17, -0.045), BEACON_GREEN)
			lamp.name = "Lamp"
			var shine: StandardMaterial3D = lamp.mesh.material
			shine.emission_enabled = true
			shine.emission = BEACON_GREEN
			shine.emission_energy_multiplier = 3.0
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
