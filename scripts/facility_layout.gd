class_name FacilityLayout
extends RefCounted
## Pure data for one facility. The same seed gives the same layout on every
## machine, so the host only has to send a number, not a whole map.

const CELL := 10.0
const SHIP_CELL := Vector2i(0, -1)
const ENTRY_CELL := Vector2i(0, 0)
const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
# Each kind of scrap and the model that shows it.
const SCRAP_MODELS := {
	"Steel gear": "cog-a",
	"Old crate": "box-small",
	"Warning beacon": "warning-traffic",
	"Control screen": "screen-small",
	"Valve pipe": "pipe-large-valve",
	"Spare lever": "lever-single",
	"Glass valve": "pipe-glass-large-valve",
	"Cargo case": "box-wide",
	"Conveyor grate": "conveyor-bars-sides",
	"Piston": "piston-round",
	"Golden cog": "cog-a",
}
# [lowest, highest] value on the first round, and [lightest, heaviest] weight. Small
# things are light and cheap; big ones are worth more but slow you down.
const SCRAP_INFO := {
	"Steel gear": {"value": [15, 35], "weight": [0.05, 0.12]},
	"Old crate": {"value": [20, 45], "weight": [0.2, 0.35]},
	"Warning beacon": {"value": [25, 50], "weight": [0.15, 0.25]},
	"Control screen": {"value": [35, 70], "weight": [0.1, 0.2]},
	"Valve pipe": {"value": [20, 40], "weight": [0.15, 0.3]},
	"Spare lever": {"value": [10, 25], "weight": [0.05, 0.1]},
	"Glass valve": {"value": [40, 80], "weight": [0.15, 0.3]},
	"Cargo case": {"value": [25, 55], "weight": [0.25, 0.4]},
	"Conveyor grate": {"value": [20, 40], "weight": [0.15, 0.3]},
	"Piston": {"value": [35, 65], "weight": [0.2, 0.35]},
	"Golden cog": {"value": [160, 260], "weight": [0.06, 0.1]},
}
const RARE_SCRAP := "Golden cog"
const RARE_CHANCE := 0.03
# What can be found lying around, and how often: [kind, share].
const FIND_TABLE := [["Med kit", 0.4], ["Flare", 0.35], ["Battery", 0.25]]
const PROP_CORNER := 3.2 # Props sit in room corners, clear of doors and walkways.
const SCRAP_CLEARANCE := 2.2 # Scrap never lands where a prop could be.
const MIN_ENTITY_ROOMS := 3 # Route length from the entry, so nothing starts on top of the crew.
# Big open halls are blocks of rooms with no walls between them. Large sites can also
# have the biggest ones.
const HALL_SHAPES: Array[Vector2i] = [Vector2i(2, 2), Vector2i(2, 2), Vector2i(2, 2), Vector2i(2, 1), Vector2i(1, 2)]
const BIG_HALL_SHAPES: Array[Vector2i] = [Vector2i(3, 2), Vector2i(2, 3), Vector2i(3, 3)]
const HALL_TRIES := 40

var size := 0
var map_id := "foundry"
var site := "medium"
var halls: Array[Rect2i] = []
var pillars: Array[Vector3] = [] # Where four rooms of a hall meet, holding up the roof.
var theme: Dictionary
var monster_spawn := Vector2i.ZERO
var light_cells: Array[Vector2i] = []
var scrap_spawns: Array[Dictionary] = []
var props: Array[Dictionary] = []
var floor_details: Array[Vector3] = []
var entity_spawns: Array[Dictionary] = []
var finds: Array[Dictionary] = [] # Useful items lying around: {kind, pos}.
var _open := {}
var _hall_of := {} # cell -> its index in halls
var _pillar_corners := {} # Grid corners with a pillar on them. Corner (x, y) is the top-left of cell (x, y).
var _rng := RandomNumberGenerator.new()


func _init(seed_value: int, grid_size: int, round_number: int, required_value: int, map: String = "foundry", site_size: String = "medium") -> void:
	_rng.seed = seed_value
	size = grid_size
	map_id = map
	site = site_size
	theme = MapThemes.get_theme(map)
	_carve_maze()
	_add_loops()
	_merge_halls()
	_open[_edge_key(SHIP_CELL, ENTRY_CELL)] = true
	monster_spawn = _farthest_cell_from_entry()
	for cell in all_cells():
		if _rng.randf() < theme.light_chance:
			light_cells.append(cell)
	_place_props()
	_place_scrap(round_number, required_value)
	_place_entities(round_number)
	_place_finds()


func has_cell(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < size and cell.y < size


func all_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for y in size:
		for x in size:
			cells.append(Vector2i(x, y))
	return cells


func is_open(a: Vector2i, b: Vector2i) -> bool:
	return _open.has(_edge_key(a, b))


## True when both rooms belong to the same hall, so there's no wall between them at all.
func is_merged(a: Vector2i, b: Vector2i) -> bool:
	return _hall_of.has(a) and _hall_of.get(b, -1) == _hall_of[a]


## Which hall a room is part of, or -1 for an ordinary room.
func hall_at(cell: Vector2i) -> int:
	return _hall_of.get(cell, -1)


## The middle of a hall, on the floor.
func hall_center(index: int) -> Vector3:
	var block := halls[index]
	return (cell_center(block.position) + cell_center(block.end - Vector2i.ONE)) * 0.5


static func cell_center(cell: Vector2i) -> Vector3:
	return Vector3(cell.x * CELL, 0.0, cell.y * CELL)


static func cell_at(pos: Vector3) -> Vector2i:
	return Vector2i(floori((pos.x + CELL * 0.5) / CELL), floori((pos.z + CELL * 0.5) / CELL))


## Shortest room-by-room route, ship excluded. Empty if there is none.
func path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if not has_cell(from) or not has_cell(to):
		return result
	var came_from := {from: from}
	var queue: Array[Vector2i] = [from]
	while not queue.is_empty():
		var current: Vector2i = queue.pop_front()
		if current == to:
			break
		for dir in DIRS:
			var next: Vector2i = current + dir
			if has_cell(next) and is_open(current, next) and not came_from.has(next):
				came_from[next] = current
				queue.append(next)
	if not came_from.has(to):
		return result
	var step := to
	while step != from:
		result.push_front(step)
		step = came_from[step]
	result.push_front(from)
	return result


## Used by the tests to prove that every machine built the same facility.
func fingerprint() -> int:
	var edges: Array = _open.keys()
	edges.sort()
	var scrap: Array = []
	for item in scrap_spawns:
		scrap.append([item.pos, item.value, item.kind])
	var prop_data: Array = []
	for prop in props:
		prop_data.append([prop.model, prop.pos, prop.turns])
	var entities: Array = []
	for entity in entity_spawns:
		entities.append([entity.kind, entity.pos])
	var found: Array = []
	for find in finds:
		found.append([find.kind, find.pos])
	return hash([map_id, site, size, edges, halls, pillars, scrap, monster_spawn, prop_data, entities, found])


func _edge_key(a: Vector2i, b: Vector2i) -> Vector4i:
	if a.x < b.x or (a.x == b.x and a.y < b.y):
		return Vector4i(a.x, a.y, b.x, b.y)
	return Vector4i(b.x, b.y, a.x, a.y)


func _carve_maze() -> void:
	var visited := {ENTRY_CELL: true}
	var stack: Array[Vector2i] = [ENTRY_CELL]
	while not stack.is_empty():
		var current: Vector2i = stack.back()
		var options: Array[Vector2i] = []
		for dir in DIRS:
			var next: Vector2i = current + dir
			if has_cell(next) and not visited.has(next):
				options.append(next)
		if options.is_empty():
			stack.pop_back()
			continue
		var chosen := options[_rng.randi_range(0, options.size() - 1)]
		_open[_edge_key(current, chosen)] = true
		visited[chosen] = true
		stack.append(chosen)


## Extra doors so players have escape routes instead of only dead ends.
func _add_loops() -> void:
	for cell in all_cells():
		for dir: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
			var next: Vector2i = cell + dir
			if has_cell(next) and not is_open(cell, next) and _rng.randf() < theme.loop_chance:
				_open[_edge_key(cell, next)] = true


## Turns some blocks of rooms into big open halls. Blocks never overlap, and the entry
## room stays an ordinary room, so the ship always opens onto the same kind of place.
func _merge_halls() -> void:
	var wanted := roundi(Rules.SITE_INFO[site].halls * theme.hall_scale)
	var shapes: Array[Vector2i] = HALL_SHAPES.duplicate()
	if site == "large":
		shapes.append_array(BIG_HALL_SHAPES)
	for attempt in HALL_TRIES:
		if halls.size() >= wanted:
			break
		var shape := shapes[_rng.randi_range(0, shapes.size() - 1)]
		if shape.x > size or shape.y > size:
			continue
		var block := Rect2i(Vector2i(_rng.randi_range(0, size - shape.x), _rng.randi_range(0, size - shape.y)), shape)
		if block.has_point(ENTRY_CELL) or halls.any(func(other: Rect2i) -> bool: return other.intersects(block)):
			continue
		var index := halls.size()
		halls.append(block)
		for y in range(block.position.y, block.end.y):
			for x in range(block.position.x, block.end.x):
				var cell := Vector2i(x, y)
				_hall_of[cell] = index
				for dir: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
					if block.has_point(cell + dir):
						_open[_edge_key(cell, cell + dir)] = true
		for y in range(block.position.y + 1, block.end.y):
			for x in range(block.position.x + 1, block.end.x):
				_pillar_corners[Vector2i(x, y)] = true
				pillars.append(cell_center(Vector2i(x, y)) - Vector3(CELL, 0, CELL) * 0.5)


func _farthest_cell_from_entry() -> Vector2i:
	var best := ENTRY_CELL
	var best_length := 0
	for cell in all_cells():
		var length := path(ENTRY_CELL, cell).size()
		if length > best_length:
			best_length = length
			best = cell
	return best


func _place_props() -> void:
	var names: Array = theme.props.keys()
	for cell in all_cells():
		if cell == ENTRY_CELL:
			continue
		for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			# The floor around a pillar stays clear, so halls feel open.
			var grid_corner := cell + Vector2i(1 if corner.x > 0 else 0, 1 if corner.y > 0 else 0)
			if _rng.randf() < theme.prop_chance and not _pillar_corners.has(grid_corner):
				var model: String = names[_rng.randi_range(0, names.size() - 1)]
				props.append({
					"model": model,
					"scale": theme.props[model],
					"pos": cell_center(cell) + Vector3(corner.x, 0, corner.y) * PROP_CORNER,
					"turns": _rng.randi_range(0, 3),
				})
		if _rng.randf() < 0.3:
			floor_details.append(cell_center(cell) + Vector3(_rng.randf_range(-2.0, 2.0), 0.01, _rng.randf_range(-2.0, 2.0)))


func _random_room_offset() -> Vector3:
	while true:
		var offset := Vector3(_rng.randf_range(-3.5, 3.5), 0.25, _rng.randf_range(-3.5, 3.5))
		if absf(offset.x) <= SCRAP_CLEARANCE or absf(offset.z) <= SCRAP_CLEARANCE:
			return offset
	return Vector3.ZERO


func _place_scrap(round_number: int, required_value: int) -> void:
	var total := 0
	# Bigger sites hold more scrap than usual for the round, smaller ones less.
	var usual := Rules.grid_size(round_number)
	var count := maxi(4, roundi((8 + 2 * round_number) * float(size * size) / (usual * usual)))
	var kinds: Array = common_scrap()
	# Always leave 50% more value than the quota, so every round can be won.
	while scrap_spawns.size() < count or total < int(required_value * 1.5):
		var cell := ENTRY_CELL
		while cell == ENTRY_CELL:
			cell = Vector2i(_rng.randi_range(0, size - 1), _rng.randi_range(0, size - 1))
		var kind: String = RARE_SCRAP if _rng.randf() < RARE_CHANCE else kinds[_rng.randi_range(0, kinds.size() - 1)]
		var info: Dictionary = SCRAP_INFO[kind]
		var value := int(_rng.randi_range(info.value[0], info.value[1]) * (1.0 + 0.1 * (round_number - 1)) * theme.scrap_value)
		scrap_spawns.append({
			"pos": cell_center(cell) + _random_room_offset(),
			"value": value,
			"weight": _rng.randf_range(info.weight[0], info.weight[1]),
			"kind": kind,
		})
		total += value


## Every scrap kind but the rare one. Mimics only ever pretend to be these.
static func common_scrap() -> Array:
	var kinds: Array = SCRAP_MODELS.keys()
	kinds.erase(RARE_SCRAP)
	return kinds


## A few useful things lie around each facility: more in bigger ones.
func _place_finds() -> void:
	for index in 1 + size / 2:
		var cell := ENTRY_CELL
		while cell == ENTRY_CELL:
			cell = Vector2i(_rng.randi_range(0, size - 1), _rng.randi_range(0, size - 1))
		var roll := _rng.randf()
		var kind: String = FIND_TABLE.back()[0]
		for row: Array in FIND_TABLE:
			roll -= row[1]
			if roll < 0.0:
				kind = row[0]
				break
		finds.append({"kind": kind, "pos": cell_center(cell) + _random_room_offset()})


## The map's residents, plus one more threat for every two rounds survived.
func _place_entities(round_number: int) -> void:
	var counts: Dictionary = theme.roster.duplicate()
	var growth: Array = theme.growth
	for extra in (round_number - 1) / 2:
		var kind: String = growth[extra % growth.size()]
		counts[kind] = counts.get(kind, 0) + 1
	var far_cells: Array[Vector2i] = []
	for cell in all_cells():
		if path(ENTRY_CELL, cell).size() >= MIN_ENTITY_ROOMS and cell != monster_spawn:
			far_cells.append(cell)
	var kinds: Array = counts.keys()
	kinds.sort()
	var used := 0
	for kind: String in kinds:
		for index in counts[kind]:
			var pos := Vector3.ZERO
			var cell := monster_spawn
			if kind in ["patch", "wisp"]:
				cell = ENTRY_CELL
			elif kind == "stalker" and index == 0:
				cell = monster_spawn
			else:
				cell = far_cells[(used + _rng.randi_range(0, far_cells.size() - 1)) % far_cells.size()]
				used += 1
			pos = cell_center(cell)
			var data := {"kind": kind, "index": entity_spawns.size(), "pos": pos}
			if kind == "mimic":
				var scrap_kinds: Array = common_scrap()
				data["pos"] = pos + _random_room_offset()
				data["scrap_kind"] = scrap_kinds[_rng.randi_range(0, scrap_kinds.size() - 1)]
			elif kind == "sentinel":
				data["pos"] = pos + Vector3(1.8, 0, 1.8)
			entity_spawns.append(data)
