class_name Level
extends Node3D
## Turns a FacilityLayout into a place. What you see comes from the art packs,
## drawn in efficient batches; what you bump into is a set of invisible boxes
## measured to match those models.

const WALL_HEIGHT := 4.25
const WALL_THICKNESS := 1.4 # The wall models stick out 0.7 m on each side.
const DOOR_WIDTH := 2.8 # The clear opening of the gate model.
const DOOR_HEIGHT := 3.6
const GATE_WIDTH := 4.2

const SHIP_TINT := Color(1.0, 1.0, 1.0)
const CEILING_SHADE := Color(0.7, 0.7, 0.7)
const AMBIENCE_MIN_SECONDS := 6.0
const AMBIENCE_MAX_SECONDS := 16.0

var _body: StaticBody3D
var _batches := {} # [path, tint] -> Array[Transform3D]
var _flicker_lights: Array[OmniLight3D] = []
var _flicker_time := 0.0
var _theme: Dictionary
var environment: Environment
var _ambience_timer := AMBIENCE_MIN_SECONDS
var _ambience_cells: Array[Vector2i] = []


func build(layout: FacilityLayout) -> void:
	_theme = layout.theme
	_ambience_cells = layout.all_cells()
	_body = StaticBody3D.new()
	add_child(_body)
	_add_environment()
	var half := FacilityLayout.CELL * 0.5
	var extent := layout.size * FacilityLayout.CELL
	var middle := Vector3(extent * 0.5 - half, 0.0, extent * 0.5 - half)
	_solid(middle + Vector3(0, -0.25, 0), Vector3(extent, 0.5, extent))
	_solid(middle + Vector3(0, WALL_HEIGHT + 0.25, 0), Vector3(extent, 0.5, extent))
	_add_ship_shell()

	var cells := layout.all_cells()
	cells.append(FacilityLayout.SHIP_CELL)
	var done := {}
	for cell in cells:
		var is_ship: bool = cell == FacilityLayout.SHIP_CELL
		_add_floor_and_ceiling(cell, SHIP_TINT if is_ship else _theme.wall_tint, SHIP_TINT * CEILING_SHADE if is_ship else _theme.ceiling_tint)
		for dir in FacilityLayout.DIRS:
			var other: Vector2i = cell + dir
			var key := Vector4i(mini(cell.x, other.x), mini(cell.y, other.y), maxi(cell.x, other.x), maxi(cell.y, other.y))
			if done.has(key):
				continue
			done[key] = true
			_add_wall(layout, cell, dir)

	for prop: Dictionary in layout.props:
		_add_prop(Assets.FACTORY % prop.model, prop.pos, prop.turns * PI * 0.5, prop.scale)
	for pos: Vector3 in layout.floor_details:
		_place(Assets.SPACE % "cables", Transform3D(Basis.IDENTITY, pos), _theme.wall_tint)

	for cell in layout.light_cells:
		_add_light(FacilityLayout.cell_center(cell) + Vector3(0, WALL_HEIGHT - 0.4, 0), _theme.light_color, _theme.light_energy, 8.0, _theme.flicker > 0.0 or _theme.pulse)
	_add_ship_fittings()
	_flush_batches()


## The ship alone, sealed, in orbit above the next place it will land.
func build_orbit(next_theme: Dictionary) -> void:
	_theme = MapThemes.ORBIT
	_body = StaticBody3D.new()
	add_child(_body)
	_add_environment()
	_add_ship_shell()
	var ship := FacilityLayout.SHIP_CELL
	_add_floor_and_ceiling(ship, SHIP_TINT, SHIP_TINT * CEILING_SHADE)
	for dir in FacilityLayout.DIRS:
		_add_wall(null, ship, dir)
	_add_window(next_theme.light_color)
	_add_ship_fittings()
	_flush_batches()


func _add_ship_shell() -> void:
	var ship_center := FacilityLayout.cell_center(FacilityLayout.SHIP_CELL)
	_solid(ship_center + Vector3(0, -0.25, 0), Vector3(10, 0.5, 10))
	_solid(ship_center + Vector3(0, WALL_HEIGHT + 0.25, 0), Vector3(10, 0.5, 10))


## The console, the terminal and the gear rack, the same on every map.
func _add_ship_fittings() -> void:
	var ship_center := FacilityLayout.cell_center(FacilityLayout.SHIP_CELL)
	_add_light(ship_center + Vector3(0, WALL_HEIGHT - 0.4, 0), Color(0.85, 0.95, 1.0), 1.5, 12.0, false)
	# The launch console, with warning lights on each side.
	_add_prop(Assets.FACTORY % "machine-window", Rules.CONSOLE_POS, 0.0, 1.2)
	for side: float in [-2.2, 2.2]:
		_add_prop(Assets.FACTORY % "warning-orange", Rules.CONSOLE_POS + Vector3(side, 0, -0.3), 0.0, 1.5)
	# The terminal against the right-hand wall, its screen facing into the ship.
	_add_prop(Assets.FACTORY % "screen-small", Rules.TERMINAL_POS + Vector3(0.35, 0, 0), -PI * 0.5, 1.6)
	_add_light(Rules.TERMINAL_POS + Vector3(-0.6, 1.4, 0), Color(0.4, 1.0, 0.6), 0.6, 3.0, false)
	# Signs high on the side walls, facing into the ship, so they never block your view.
	var wall_x := FacilityLayout.CELL * 0.5 - WALL_THICKNESS * 0.5 - 0.02
	_add_sign("TERMINAL", Vector3(wall_x, 2.7, Rules.TERMINAL_POS.z), -PI * 0.5, Color(0.5, 1.0, 0.65))
	_add_sign("GEAR RACK", Vector3(-wall_x, 2.7, Rules.RACK_POS.z + 1.2), PI * 0.5, Color(0.5, 0.85, 1.0))
	add_child(Sfx.make_ship_hum(ship_center + Vector3(0, 2, 0)))


func _add_sign(text: String, pos: Vector3, facing: float, color: Color) -> void:
	var sign_label := Label3D.new()
	sign_label.text = text
	sign_label.modulate = color
	sign_label.pixel_size = 0.006
	sign_label.font_size = 48
	sign_label.outline_size = 8
	sign_label.position = pos
	sign_label.rotation.y = facing
	add_child(sign_label)


## Stars, and the curve of the planet below, tinted like the facility's lights.
func _add_window(planet_color: Color) -> void:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded;
uniform vec3 planet_color;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void fragment() {
	vec2 cell = floor(UV * vec2(90.0, 45.0));
	vec3 color = vec3(0.01, 0.012, 0.03) + vec3(step(0.985, hash(cell)) * hash(cell + 7.0));
	float planet = smoothstep(1.02, 1.0, distance(UV * vec2(2.0, 1.0), vec2(1.0, 1.9)));
	color = mix(color, planet_color * (0.25 + 0.5 * UV.y), planet);
	ALBEDO = color;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("planet_color", Vector3(planet_color.r, planet_color.g, planet_color.b))
	var quad := QuadMesh.new()
	quad.size = Vector2(4.4, 2.2)
	quad.material = material
	var window := MeshInstance3D.new()
	window.mesh = quad
	# On the inside of the wall where the door opens when the ship has landed.
	var line_z := FacilityLayout.cell_center(FacilityLayout.SHIP_CELL).z + FacilityLayout.CELL * 0.5
	window.position = Vector3(0, 2.0, line_z - WALL_THICKNESS * 0.5 - 0.02)
	window.rotation.y = PI
	add_child(window)


func _process(delta: float) -> void:
	_flicker_time += delta
	for index in _flicker_lights.size():
		var level := 1.0
		if _theme.pulse:
			# A slow alarm sweep that goes nearly dark between beats.
			level = 0.06 + 0.94 * pow(0.5 + 0.5 * sin(_flicker_time * 2.2 + index * 0.6), 2.0)
		else:
			var seed_time := _flicker_time * 7.0 + index * 13.7
			# More flicker means the light drops out more often.
			if sin(seed_time) * sin(seed_time * 0.37) > 1.0 - _theme.flicker * 0.7:
				level = 0.2
		_flicker_lights[index].light_energy = _theme.light_energy * level
	_ambience_timer -= delta
	if _ambience_timer <= 0.0 and not _ambience_cells.is_empty():
		_ambience_timer = randf_range(AMBIENCE_MIN_SECONDS, AMBIENCE_MAX_SECONDS)
		var room := _ambience_cells[randi() % _ambience_cells.size()]
		Sfx.play_3d(_theme.ambience, FacilityLayout.cell_center(room) + Vector3(0, 2, 0), -6.0, 45.0)


func _add_floor_and_ceiling(cell: Vector2i, tint: Color, ceiling_tint: Color) -> void:
	var center := FacilityLayout.cell_center(cell)
	var scale_basis := Basis.from_scale(Vector3(1.25, 1.0, 1.25))
	var upside_down := Basis(Vector3.RIGHT, PI) * scale_basis
	for x: float in [-2.5, 2.5]:
		for z: float in [-2.5, 2.5]:
			var pos := center + Vector3(x, 0, z)
			_place(Assets.SPACE % "template-floor", Transform3D(scale_basis, pos), tint)
			_place(Assets.SPACE % "template-floor", Transform3D(upside_down, pos + Vector3(0, WALL_HEIGHT, 0)), ceiling_tint)


func _add_wall(layout: FacilityLayout, cell: Vector2i, dir: Vector2i) -> void:
	var other: Vector2i = cell + dir
	var size := FacilityLayout.CELL
	var line := FacilityLayout.cell_center(cell) + Vector3(dir.x, 0, dir.y) * size * 0.5
	var along_x := dir.x == 0
	var axis := Vector3.RIGHT if along_x else Vector3.BACK
	var has_door := layout != null and layout.is_open(cell, other)

	# What you bump into.
	if has_door:
		var side := (size - DOOR_WIDTH) * 0.5
		var shift := (size + DOOR_WIDTH) * 0.25
		for sign_value: float in [-1.0, 1.0]:
			_solid(line + axis * shift * sign_value + Vector3(0, WALL_HEIGHT * 0.5, 0), _wall_size(side, WALL_HEIGHT, along_x))
		var lintel := WALL_HEIGHT - DOOR_HEIGHT
		_solid(line + Vector3(0, DOOR_HEIGHT + lintel * 0.5, 0), _wall_size(DOOR_WIDTH, lintel, along_x))
	else:
		_solid(line + Vector3(0, WALL_HEIGHT * 0.5, 0), _wall_size(size, WALL_HEIGHT, along_x))

	# What you see: a wall face on each side that has a room, facing into it.
	var into_cell := Vector3(-dir.x, 0, -dir.y)
	_add_wall_face(line, axis, into_cell, has_door, _tint_for(cell))
	if (layout != null and layout.has_cell(other)) or other == FacilityLayout.SHIP_CELL:
		_add_wall_face(line, axis, -into_cell, has_door, _tint_for(other))
	if has_door:
		var ship_door: bool = cell == FacilityLayout.SHIP_CELL or other == FacilityLayout.SHIP_CELL
		var turn := Basis.IDENTITY if along_x else Basis(Vector3.UP, PI * 0.5)
		_place(Assets.SPACE % "gate", Transform3D(turn, line), SHIP_TINT if ship_door else _theme.wall_tint)


func _add_wall_face(line: Vector3, axis: Vector3, facing: Vector3, has_door: bool, tint: Color) -> void:
	# The wall model is 4 m wide and extends along its own -Z, so -Z points into the room.
	var turn := Basis(Vector3.UP, atan2(-facing.x, -facing.z))
	if has_door:
		var length := (FacilityLayout.CELL - GATE_WIDTH) * 0.5
		var offset := (GATE_WIDTH + length) * 0.5
		var stretched := turn * Basis.from_scale(Vector3(length / 4.0, 1.0, 1.0))
		for sign_value: float in [-1.0, 1.0]:
			_place(Assets.SPACE % "template-wall", Transform3D(stretched, line + axis * offset * sign_value), tint)
	else:
		var stretched := turn * Basis.from_scale(Vector3(1.25, 1.0, 1.0))
		for sign_value: float in [-1.0, 1.0]:
			_place(Assets.SPACE % "template-wall", Transform3D(stretched, line + axis * 2.5 * sign_value), tint)


func _tint_for(cell: Vector2i) -> Color:
	return SHIP_TINT if cell == FacilityLayout.SHIP_CELL else _theme.wall_tint


func _add_prop(path: String, pos: Vector3, angle: float, prop_scale: float) -> void:
	var turn := Basis(Vector3.UP, angle)
	_place(path, Transform3D(turn * Basis.from_scale(Vector3.ONE * prop_scale), pos), Color.WHITE)
	var box := Assets.bounds(path)
	var shape := BoxShape3D.new()
	shape.size = box.size * prop_scale
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.transform = Transform3D(turn, pos + turn * (box.get_center() * prop_scale))
	_body.add_child(collision)


func _wall_size(length: float, height: float, along_x: bool) -> Vector3:
	if along_x:
		return Vector3(length, height, WALL_THICKNESS)
	return Vector3(WALL_THICKNESS, height, length)


func _solid(center: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position = center
	_body.add_child(collision)


func _place(path: String, placement: Transform3D, tint: Color) -> void:
	var key := [path, tint]
	if not _batches.has(key):
		_batches[key] = []
	_batches[key].append(placement)


## Hundreds of copies of a model become one draw call, which keeps the frame rate up.
func _flush_batches() -> void:
	for key: Array in _batches:
		var placements: Array = _batches[key]
		for part: Dictionary in Assets.mesh_parts(key[0]):
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.mesh = part.mesh
			multimesh.instance_count = placements.size()
			for index in placements.size():
				multimesh.set_instance_transform(index, placements[index] * part.transform)
			var instance := MultiMeshInstance3D.new()
			instance.multimesh = multimesh
			instance.material_override = _tinted(part.mesh, key[1])
			add_child(instance)
	_batches.clear()


func _tinted(mesh: Mesh, tint: Color) -> Material:
	var source := mesh.surface_get_material(0) as BaseMaterial3D
	if source == null or tint == Color.WHITE:
		return source
	var material: BaseMaterial3D = source.duplicate()
	material.albedo_color = source.albedo_color * tint
	return material


func _add_light(pos: Vector3, color: Color, energy: float, light_range: float, flicker: bool) -> void:
	var light := OmniLight3D.new()
	light.position = pos
	light.light_color = color
	light.light_energy = energy
	light.omni_range = light_range
	add_child(light)
	if flicker:
		_flicker_lights.append(light)


func _add_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = _theme.ambient_color
	env.ambient_light_energy = _theme.ambient_energy
	env.fog_enabled = true
	env.fog_light_color = _theme.fog_color
	env.fog_density = _theme.fog_density
	env.adjustment_enabled = true
	environment = env
	_apply_brightness()
	Settings.changed.connect(_apply_brightness)
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


func _apply_brightness() -> void:
	environment.adjustment_brightness = Settings.value("brightness")


static func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	return mat
