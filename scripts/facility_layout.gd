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
}
const PROP_MODELS := {
	"machine": 1.3,
	"machine-fortified": 1.2,
	"hopper-round": 1.5,
	"box-large": 1.6,
	"robot-arm-a": 1.0,
	"pipe-large": 1.4,
	"screen-wide": 1.3,
}
const PROP_CORNER := 3.2 # Props sit in room corners, clear of doors and walkways.
const SCRAP_CLEARANCE := 2.2 # Scrap never lands where a prop could be.

var size := 0
var monster_spawn := Vector2i.ZERO
var light_cells: Array[Vector2i] = []
var scrap_spawns: Array[Dictionary] = []
var props: Array[Dictionary] = []
var floor_details: Array[Vector3] = []
var _open := {}
var _rng := RandomNumberGenerator.new()


func _init(seed_value: int, grid_size: int, round_number: int, required_value: int) -> void:
	_rng.seed = seed_value
	size = grid_size
	_carve_maze()
	_add_loops()
	_open[_edge_key(SHIP_CELL, ENTRY_CELL)] = true
	monster_spawn = _farthest_cell_from_entry()
	for cell in all_cells():
		if _rng.randf() < 0.35:
			light_cells.append(cell)
	_place_props()
	_place_scrap(round_number, required_value)


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
	return hash([size, edges, scrap, monster_spawn, prop_data])


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
			if has_cell(next) and not is_open(cell, next) and _rng.randf() < 0.15:
				_open[_edge_key(cell, next)] = true


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
	var names: Array = PROP_MODELS.keys()
	for cell in all_cells():
		if cell == ENTRY_CELL:
			continue
		for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			if _rng.randf() < 0.45:
				var model: String = names[_rng.randi_range(0, names.size() - 1)]
				props.append({
					"model": model,
					"scale": PROP_MODELS[model],
					"pos": cell_center(cell) + Vector3(corner.x, 0, corner.y) * PROP_CORNER,
					"turns": _rng.randi_range(0, 3),
				})
		if _rng.randf() < 0.3:
			floor_details.append(cell_center(cell) + Vector3(_rng.randf_range(-2.0, 2.0), 0.01, _rng.randf_range(-2.0, 2.0)))


func _place_scrap(round_number: int, required_value: int) -> void:
	var total := 0
	var count := 8 + 2 * round_number
	var kinds: Array = SCRAP_MODELS.keys()
	# Always leave 50% more value than the quota, so every round can be won.
	while scrap_spawns.size() < count or total < int(required_value * 1.5):
		var cell := ENTRY_CELL
		while cell == ENTRY_CELL:
			cell = Vector2i(_rng.randi_range(0, size - 1), _rng.randi_range(0, size - 1))
		var offset := Vector3(_rng.randf_range(-3.5, 3.5), 0.25, _rng.randf_range(-3.5, 3.5))
		if absf(offset.x) > SCRAP_CLEARANCE and absf(offset.z) > SCRAP_CLEARANCE:
			continue
		var value := int(_rng.randi_range(15, 60) * (1.0 + 0.1 * (round_number - 1)))
		scrap_spawns.append({
			"pos": cell_center(cell) + offset,
			"value": value,
			"weight": _rng.randf_range(0.05, 0.35),
			"kind": kinds[_rng.randi_range(0, kinds.size() - 1)],
		})
		total += value
