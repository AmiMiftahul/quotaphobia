class_name Corpse
extends Node3D
## What's left when a player or creature dies: its own model, knocked flying by the
## blow that killed it. It arcs through the air, bounces off walls, slides to a stop
## on the floor and stays there until the ship leaves. Every machine runs the same
## short flight from the same push, so nothing has to be sent while it flies.

const GRAVITY := 16.0
const BOUNCE := 0.3 # How much speed is kept when it hits the floor.
const WALL_BOUNCE := 0.15 # A body that slams into a wall mostly drops, rather than flying back.
const FRICTION := 7.0 # Sliding along the floor slows it this much per second.
const RADIUS := 0.4 # How close to a wall its middle can get.
const REST_SPEED := 0.4
const MIN_PUSH := 3.0
const MAX_PUSH := 10.0

var velocity := Vector3.ZERO
var resting := false
var floor_y := 0.0 # Where it comes to rest.
var _tumble := Vector3.ZERO # Spin, for bodies with no death animation of their own.
var _shapeless := false # No death animation: it tumbles, then lands squashed.
var _landed := false


## Moves the visible parts of `from` into a new corpse, so they outlive it. Parts
## listed in `leave` stay behind. A character body plays its death animation.
static func make(from: Node3D, push: Vector3, leave: Array = [], rest_height: float = 0.0) -> Corpse:
	var corpse := Corpse.new()
	corpse.name = "Corpse_%s" % from.name
	var level: Node = Session.level if Session.level != null else from.get_parent()
	level.add_child(corpse)
	corpse.global_transform = Transform3D(Basis(Vector3.UP, from.global_rotation.y), from.global_position)
	corpse.velocity = push
	corpse.floor_y = rest_height
	var animated := false
	for child in from.get_children():
		if child in leave or not _is_body_part(child):
			continue
		child.reparent(corpse, true)
		var animator := Assets.find_animation_player(child)
		if animator != null and animator.has_animation("die"):
			animator.speed_scale = 1.0
			animator.play("die", 0.1)
			animated = true
	# Something with no way to fall over tumbles instead.
	if not animated:
		corpse._shapeless = true
		corpse._tumble = Vector3(randf_range(-6.0, 6.0), randf_range(-3.0, 3.0), randf_range(-6.0, 6.0))
	return corpse


## Meshes and the models holding them. Never collision, cameras, lights or labels.
static func _is_body_part(node: Node) -> bool:
	if node is Light3D or node is CollisionShape3D or node is Camera3D or node is Label3D:
		return false
	if node is GeometryInstance3D:
		return true
	return node.get_class() == "Node3D" and not node.find_children("*", "GeometryInstance3D", true, false).is_empty()


## The push a killing blow gives: away from where it came from, and up. Harder blows
## throw further. With no known source it flies off in a random direction.
static func push_from(victim: Vector3, source: Vector3, strength: float) -> Vector3:
	var away := victim - source
	away.y = 0.0
	if source == Vector3.INF or away.length() < 0.05:
		away = Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU)
	var speed := clampf(MIN_PUSH * strength, MIN_PUSH, MAX_PUSH)
	return away.normalized() * speed + Vector3.UP * clampf(2.5 + speed * 0.4, 3.0, 6.5)


func _physics_process(delta: float) -> void:
	if resting:
		return
	velocity.y -= GRAVITY * delta
	var step := velocity * delta
	_stop_at_walls(step)
	step = velocity * delta
	position += step
	if _tumble != Vector3.ZERO:
		rotation += _tumble * delta
	if position.y <= floor_y:
		position.y = floor_y
		if not _landed and is_inside_tree():
			_landed = true
			Sfx.play_3d("drop", global_position, 0.0, 22.0)
		velocity.y = -velocity.y * BOUNCE if velocity.y < -2.5 else 0.0
		var slide := Vector2(velocity.x, velocity.z)
		slide = slide.move_toward(Vector2.ZERO, FRICTION * delta)
		velocity.x = slide.x
		velocity.z = slide.y
		_tumble = _tumble.move_toward(Vector3.ZERO, 20.0 * delta)
		if velocity.length() < REST_SPEED:
			_settle()


## Walls and props turn it back instead of letting it fly through.
func _stop_at_walls(step: Vector3) -> void:
	var flat := Vector3(step.x, 0, step.z)
	if flat.length() < 0.0001 or not is_inside_tree():
		return
	var from := global_position + Vector3(0, 0.5, 0)
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
	flat_velocity = flat_velocity.bounce(normal) * WALL_BOUNCE
	velocity.x = flat_velocity.x
	velocity.z = flat_velocity.z


## Comes to rest wherever it stopped. A character has already fallen over in its
## death animation; anything else that tumbled ends up the right way up, squashed flat.
func _settle() -> void:
	resting = true
	velocity = Vector3.ZERO
	position.y = floor_y
	if _shapeless:
		rotation = Vector3(0.0, rotation.y, 0.0)
		scale = Vector3(1.25, 0.4, 1.25)
	_tumble = Vector3.ZERO
