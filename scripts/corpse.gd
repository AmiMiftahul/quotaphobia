class_name Corpse
extends Node3D
## What's left when a player or creature dies: its own model, sent flying by the blow
## that killed it, cartoon style. It cartwheels through the air with its arms and legs
## flailing, bonks off the ceiling and walls, bounces a few times, then flops over and
## stays there until the ship leaves. Every machine runs the same flight from the same
## push, so nothing has to be sent while it flies.

const GRAVITY := 16.0
const BOUNCE := 0.45 # How much upward speed is kept when it hits the floor.
const BOUNCE_GRIP := 0.55 # And how much sideways speed, so it doesn't skip far along the floor.
const WALL_BOUNCE := 0.15 # A body that slams into a wall mostly drops, rather than flying back.
const CEILING_BOUNCE := 0.3
const FRICTION := 7.0 # Sliding along the floor slows it this much per second.
const RADIUS := 0.4 # How close to a wall its middle can get.
const REST_SPEED := 0.4
const MIN_PUSH := 5.0
const MAX_PUSH := 14.0
const MIN_LIFT := 6.0
const MAX_LIFT := 10.0
const MIN_FLIP := 7.0 # Radians per second it spins head over heels.
const MAX_FLIP := 15.0
const FLAIL_SPEED := 3.0 # Its run animation, sped up: arms and legs windmilling in the air.
const STRAIGHTEN_SECONDS := 0.15 # On landing it rights itself this fast, then flops over.
const SQUASH_SECONDS := 0.25

var velocity := Vector3.ZERO
var resting := false
var floor_y := 0.0 # Where it comes to rest.
var bounces := 0 # Times it has hit the floor, ceiling or a wall.
var ceiling_hits := 0
var spin: Node3D # Holds the body. It turns about the body's middle, not its feet.
var _flip_axis := Vector3.ZERO # In this node's space.
var _flip_rate := 0.0
var _twist_rate := 0.0
var _animator: AnimationPlayer
var _shapeless := false # No death animation: it tumbles, then lands squashed.
var _landed := false
var _straighten_left := 0.0
var _straighten_from := Quaternion.IDENTITY
var _squash_left := 0.0


## Moves the visible parts of `from` into a new corpse, so they outlive it. Parts
## listed in `leave` stay behind. A character body flails, then plays its death animation.
static func make(from: Node3D, push: Vector3, leave: Array = [], rest_height: float = 0.0) -> Corpse:
	var parts: Array[Node] = []
	for child in from.get_children():
		if not child in leave and _is_body_part(child):
			parts.append(child)
	var corpse := Corpse.new()
	corpse.name = "Corpse_%s" % from.name
	var level: Node = Session.level if Session.level != null else from.get_parent()
	level.add_child(corpse)
	corpse.global_transform = Transform3D(Basis(Vector3.UP, from.global_rotation.y), from.global_position)
	corpse.velocity = push
	corpse.floor_y = rest_height
	corpse.spin = Node3D.new()
	corpse.spin.name = "Spin"
	corpse.spin.position.y = _middle_height(from, parts)
	corpse.add_child(corpse.spin)
	for part in parts:
		part.reparent(corpse.spin, true)
		var animator := Assets.find_animation_player(part)
		if animator != null and animator.has_animation("die"):
			corpse._animator = animator
	corpse._shapeless = corpse._animator == null
	if corpse._animator != null:
		corpse._animator.speed_scale = FLAIL_SPEED
		corpse._animator.play("sprint" if corpse._animator.has_animation("sprint") else "die", 0.05)
	# Head over heels in the direction it was knocked, with a bit of a sideways twist.
	# Worked out from the push alone, so it spins the same way on every machine.
	var flat := Vector3(push.x, 0, push.z)
	if flat.length() > 0.05:
		corpse._flip_axis = corpse.basis.inverse() * Vector3.UP.cross(flat.normalized())
	else:
		corpse._flip_axis = Vector3.RIGHT
	corpse._flip_rate = clampf(flat.length() * 1.1, MIN_FLIP, MAX_FLIP)
	corpse._twist_rate = (fposmod(push.x * 7.31 + push.z * 3.17, 2.0) - 1.0) * 5.0
	if corpse._shapeless:
		corpse._twist_rate *= 2.0
	if push.length() > 0.1 and corpse.is_inside_tree():
		Sfx.play_3d("launch", corpse.global_position, -6.0, 25.0, 1.7) # Whoosh.
	return corpse


## Meshes and the models holding them. Never collision, cameras, lights or labels.
static func _is_body_part(node: Node) -> bool:
	if node is Light3D or node is CollisionShape3D or node is Camera3D or node is Label3D:
		return false
	if node is GeometryInstance3D:
		return true
	return node.get_class() == "Node3D" and not node.find_children("*", "GeometryInstance3D", true, false).is_empty()


## How high the middle of the body is above its feet.
static func _middle_height(from: Node3D, parts: Array[Node]) -> float:
	var box := AABB()
	var first := true
	var to_local := from.global_transform.affine_inverse()
	for part in parts:
		var meshes: Array[Node] = part.find_children("*", "VisualInstance3D", true, false)
		if part is VisualInstance3D:
			meshes.append(part)
		for mesh: VisualInstance3D in meshes:
			var local: AABB = (to_local * mesh.global_transform) * mesh.get_aabb()
			box = local if first else box.merge(local)
			first = false
	return 0.8 if first else clampf(box.get_center().y, 0.2, 2.0)


## The push a killing blow gives: away from where it came from, and up. Harder blows
## throw further. With no known source it flies off in a random direction.
static func push_from(victim: Vector3, source: Vector3, strength: float) -> Vector3:
	var away := victim - source
	away.y = 0.0
	if source == Vector3.INF or away.length() < 0.05:
		away = Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU)
	var speed := clampf(MIN_PUSH * strength, MIN_PUSH, MAX_PUSH)
	return away.normalized() * speed + Vector3.UP * clampf(3.5 + speed * 0.45, MIN_LIFT, MAX_LIFT)


func _physics_process(delta: float) -> void:
	_animate(delta)
	if resting:
		return
	velocity.y -= GRAVITY * delta
	_stop_at_walls(velocity * delta)
	_stop_at_ceiling(velocity * delta)
	position += velocity * delta
	if not _landed:
		spin.rotate(_flip_axis, _flip_rate * delta)
		spin.rotate(Vector3.UP, _twist_rate * delta)
	if position.y <= floor_y:
		position.y = floor_y
		if not _landed:
			_land()
		if velocity.y < -2.5:
			_impact(-velocity.y)
			velocity.y = -velocity.y * BOUNCE
			velocity.x *= BOUNCE_GRIP
			velocity.z *= BOUNCE_GRIP
		else:
			velocity.y = 0.0
		var slide := Vector2(velocity.x, velocity.z).move_toward(Vector2.ZERO, FRICTION * delta)
		velocity.x = slide.x
		velocity.z = slide.y
		if velocity.length() < REST_SPEED:
			_settle()


## The first time it touches down it stops spinning, rights itself and flops over.
func _land() -> void:
	_landed = true
	_straighten_from = spin.quaternion
	_straighten_left = STRAIGHTEN_SECONDS
	if _animator != null:
		_animator.speed_scale = 1.0
		_animator.play("die", 0.1)


## A thud, louder and lower for harder hits, and a quick squash.
func _impact(speed: float) -> void:
	bounces += 1
	_squash_left = SQUASH_SECONDS
	if is_inside_tree():
		Sfx.play_3d("hit", global_position, clampf(speed - 8.0, -10.0, 2.0), 22.0, 0.8 + 0.12 * bounces)


func _animate(delta: float) -> void:
	if _straighten_left > 0.0:
		_straighten_left = maxf(_straighten_left - delta, 0.0)
		spin.quaternion = _straighten_from.slerp(Quaternion.IDENTITY, 1.0 - _straighten_left / STRAIGHTEN_SECONDS)
	var squash := 0.0
	if _squash_left > 0.0:
		_squash_left = maxf(_squash_left - delta, 0.0)
		squash = sin(_squash_left / SQUASH_SECONDS * PI) * 0.35
	elif not _landed:
		squash = -0.12 # Stretched out while it flies.
	spin.scale = Vector3(1.0 + squash * 0.8, 1.0 - squash, 1.0 + squash * 0.8)


## Walls and props turn it back instead of letting it fly through.
func _stop_at_walls(step: Vector3) -> void:
	var flat := Vector3(step.x, 0, step.z)
	if flat.length() < 0.0001 or not is_inside_tree():
		return
	var from := global_position + Vector3(0, minf(spin.position.y, 0.9), 0)
	var to := from + flat + flat.normalized() * RADIUS
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, 1))
	if hit.is_empty():
		return
	var normal: Vector3 = hit.normal
	normal.y = 0.0
	if normal.length() < 0.01:
		return
	normal = normal.normalized()
	var flat_velocity := Vector3(velocity.x, 0, velocity.z)
	if flat_velocity.dot(normal) > 0.0:
		return # Already heading away from it.
	_impact(absf(flat_velocity.dot(normal)) * 0.6)
	flat_velocity = flat_velocity.bounce(normal) * WALL_BOUNCE
	velocity.x = flat_velocity.x
	velocity.z = flat_velocity.z


## Thrown hard enough, it bonks its head on the ceiling and comes straight back down.
func _stop_at_ceiling(step: Vector3) -> void:
	if velocity.y <= 0.0 or not is_inside_tree():
		return
	var from := global_position + Vector3(0, spin.position.y, 0)
	var to := from + Vector3(0, spin.position.y + step.y + 0.1, 0)
	if not get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, 1)).is_empty():
		ceiling_hits += 1
		_impact(velocity.y)
		velocity.y = -velocity.y * CEILING_BOUNCE
		if is_inside_tree():
			Sfx.play_3d("bonk", global_position + Vector3(0, spin.position.y * 2.0, 0), -4.0, 20.0)


## Comes to rest wherever it stopped. A character has already flopped over in its
## death animation; anything else ends up the right way up, squashed flat.
func _settle() -> void:
	resting = true
	velocity = Vector3.ZERO
	position.y = floor_y
	if _shapeless:
		_straighten_left = 0.0
		spin.quaternion = Quaternion.IDENTITY
		scale = Vector3(1.25, 0.4, 1.25)
