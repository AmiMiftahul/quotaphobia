class_name Scrap
extends Node3D
## A sellable item. Only the host changes who holds it. While held, every machine
## places it in front of the holder, so it needs no extra network traffic.

const MODEL_SCALE := 0.6

var item_id := 0
var value := 0
var weight := 0.0
var kind := ""
var holder_id := 0:
	set(new_holder):
		if new_holder != holder_id and is_inside_tree():
			Sfx.play_3d("pickup" if new_holder != 0 else "drop", position, -4.0, 18.0)
		holder_id = new_holder


func setup(id: int, data: Dictionary) -> void:
	item_id = id
	value = data.value
	weight = data.weight
	kind = data.kind
	position = data.pos
	name = "Scrap%d" % id
	var model := Assets.instance(Assets.FACTORY % FacilityLayout.SCRAP_MODELS[kind])
	model.scale = Vector3.ONE * MODEL_SCALE
	model.position.y = -0.25 - Assets.bounds(Assets.FACTORY % FacilityLayout.SCRAP_MODELS[kind]).position.y * MODEL_SCALE
	add_child(model)
	# A faint warm glow, so scrap can be spotted in the dark.
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow.albedo_color = Color(1.0, 0.75, 0.25, 0.18)
	_set_overlay(model, glow)
	NetSync.attach(self, [], [^":position", ^":holder_id"])


func _process(_delta: float) -> void:
	if holder_id == 0:
		return
	var holder := Session.player_node(holder_id)
	if holder != null:
		position = holder.position + holder.forward() * 0.6 + Vector3(0, 1.0, 0)


func _set_overlay(node: Node, material: Material) -> void:
	if node is MeshInstance3D:
		node.material_overlay = material
	for child in node.get_children():
		_set_overlay(child, material)
