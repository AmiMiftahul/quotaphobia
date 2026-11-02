class_name Scrap
extends Node3D
## Anything the crew can carry: scrap to sell, or gear bought at the terminal. Only
## the host changes who holds it. While held, every machine places it in front of
## the holder, so it needs no extra network traffic.

const MODEL_SCALE := 0.6
const FLOOR_HEIGHT := 0.25
const SWING_SECONDS := 0.3
const SCRAP_GLOW := Color(1.0, 0.75, 0.25, 0.18)
const GEAR_GLOW := Color(0.4, 0.8, 1.0, 0.16)

var item_id := 0
var value := 0
var weight := 0.0
var kind := ""
var holder_id := 0:
	set(new_holder):
		if new_holder != holder_id and is_inside_tree():
			Sfx.play_3d("pickup" if new_holder != 0 else "drop", position, -4.0, 18.0)
		holder_id = new_holder
var stowed := false: # In the holder's backpack, rather than their hands.
	set(in_backpack):
		stowed = in_backpack
		visible = not in_backpack
var charges := 0: # Zap gun shots left.
	set(count):
		charges = count
		_show_charges()
var armed := false: # A thrown stun grenade, about to go off.
	set(is_armed):
		armed = is_armed
		if _armed_light != null:
			_armed_light.visible = is_armed

var _model: Node3D
var _armed_light: OmniLight3D
var _swing_left := 0.0
var _blink := 0.0


func setup(id: int, data: Dictionary) -> void:
	item_id = id
	value = data.value
	weight = data.weight
	kind = data.kind
	position = data.pos
	name = "Scrap%d" % id
	if is_tool():
		_model = Tools.build_model(kind)
		add_child(_model)
		add_glow(_model, GEAR_GLOW)
		_armed_light = OmniLight3D.new()
		_armed_light.light_color = Color(1.0, 0.15, 0.1)
		_armed_light.light_energy = 2.0
		_armed_light.omni_range = 3.0
		_armed_light.visible = false
		add_child(_armed_light)
		_pose(false)
	else:
		var model := Assets.instance(Assets.FACTORY % FacilityLayout.SCRAP_MODELS[kind])
		model.scale = Vector3.ONE * MODEL_SCALE
		model.position.y = -FLOOR_HEIGHT - Assets.bounds(Assets.FACTORY % FacilityLayout.SCRAP_MODELS[kind]).position.y * MODEL_SCALE
		add_child(model)
		add_glow(model)
	charges = data.get("charges", 0)
	NetSync.attach(self, [], [^":position", ^":holder_id", ^":stowed", ^":charges", ^":armed"])


func is_tool() -> bool:
	return Tools.is_gear(kind)


## How the HUD names it: scrap shows its price, gear what's left in it.
func describe() -> String:
	if kind == Tools.ZAP_GUN:
		return "%s (%d/%d)" % [kind, charges, Tools.CATALOG[kind].charges]
	if is_tool():
		return kind
	return "%s ($%d)" % [kind, value]


## Played on every machine when the holder uses it.
func swing() -> void:
	_swing_left = SWING_SECONDS


## A faint glow, so items can be spotted in the dark: warm for scrap, cool for gear.
static func add_glow(model: Node, color: Color = SCRAP_GLOW) -> void:
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow.albedo_color = color
	_set_overlay(model, glow)


func _process(delta: float) -> void:
	if armed:
		_blink += delta
		_armed_light.light_energy = 3.0 if fmod(_blink, 0.3) < 0.15 else 0.4
	if holder_id == 0:
		if _model != null:
			_pose(false)
		return
	var holder := Session.player_node(holder_id)
	if holder == null:
		return
	if holder.is_local_player:
		# Low and to the right, so your own item never blocks your view.
		var right := holder.forward().cross(Vector3.UP)
		position = holder.position + holder.forward() * 1.0 + right * 0.55 + Vector3(0, 1.1, 0)
	else:
		position = holder.position + holder.forward() * 0.6 + Vector3(0, 1.0, 0)
	if _model != null:
		rotation.y = holder.rotation.y
		_swing_left = maxf(0.0, _swing_left - delta)
		_pose(true)


## Gear lies flat on the floor and is held upright, chopping forward when swung.
func _pose(held: bool) -> void:
	if not held:
		_model.rotation = Vector3(-PI * 0.5, 0, 0) if kind == Tools.SHOVEL else Vector3.ZERO
		_model.position.y = -FLOOR_HEIGHT + (0.03 if kind == Tools.SHOVEL else 0.0)
		return
	var chop := sin((1.0 - _swing_left / SWING_SECONDS) * PI) if _swing_left > 0.0 else 0.0
	var lean := -0.5 if kind == Tools.SHOVEL else 0.0
	_model.rotation = Vector3(lean - chop * 1.3, 0, 0)
	_model.position.y = -0.55 if kind == Tools.SHOVEL else -0.15


func _show_charges() -> void:
	if _model == null or kind != Tools.ZAP_GUN:
		return
	var barrel: MeshInstance3D = _model.get_node("Barrel")
	var material: StandardMaterial3D = barrel.mesh.material
	material.emission_energy_multiplier = 2.5 if charges > 0 else 0.0


static func _set_overlay(node: Node, material: Material) -> void:
	if node is MeshInstance3D:
		node.material_overlay = material
	for child in node.get_children():
		_set_overlay(child, material)
