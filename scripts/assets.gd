class_name Assets
extends RefCounted
## Helpers for the 3D model packs.

const SPACE := "res://assets/models/space/%s.glb"
const FACTORY := "res://assets/models/factory/%s.glb"
const CHARACTERS := "res://assets/models/characters/%s.glb"

static var _parts_cache := {}


static func instance(path: String) -> Node3D:
	return load(path).instantiate()


## Each mesh in a model, with its placement inside the model.
static func mesh_parts(path: String) -> Array:
	if not _parts_cache.has(path):
		var parts := []
		var root := instance(path)
		_collect(root, Transform3D.IDENTITY, parts)
		root.free()
		_parts_cache[path] = parts
	return _parts_cache[path]


static func bounds(path: String) -> AABB:
	var result := AABB()
	var first := true
	for part: Dictionary in mesh_parts(path):
		var box: AABB = part.transform * (part.mesh as Mesh).get_aabb()
		result = box if first else result.merge(box)
		first = false
	return result


static func find_animation_player(node: Node) -> AnimationPlayer:
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
		var found := find_animation_player(child)
		if found != null:
			return found
	return null


static func set_looping(player: AnimationPlayer, names: Array) -> void:
	for animation_name: String in names:
		if player.has_animation(animation_name):
			player.get_animation(animation_name).loop_mode = Animation.LOOP_LINEAR


static func override_material(node: Node, material: Material) -> void:
	if node is MeshInstance3D:
		node.material_override = material
	for child in node.get_children():
		override_material(child, material)


static func _collect(node: Node, parent: Transform3D, parts: Array) -> void:
	var here := parent
	if node is Node3D:
		here = parent * node.transform
	if node is MeshInstance3D and node.mesh != null:
		parts.append({"mesh": node.mesh, "transform": here})
	for child in node.get_children():
		_collect(child, here, parts)
