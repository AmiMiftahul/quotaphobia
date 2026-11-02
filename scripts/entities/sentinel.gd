class_name Sentinel
extends Entity
## A friendly pylon fixed in place. It stuns the nearest hunter that comes into
## view, then needs time to recharge, so leading a chase past one saves your life.

const RANGE := 9.0
const STUN_SECONDS := 4.0
const RECHARGE_SECONDS := 12.0
const FLASH_SECONDS := 0.3
const READY := 0
const RECHARGING := 1

var _light: OmniLight3D
var _recharge := 0.0
var _flash := 0.0


func _build(_data: Dictionary) -> void:
	var model := Assets.instance(Assets.FACTORY % "warning-traffic")
	model.scale = Vector3.ONE * 1.6
	add_child(model)
	_light = _make_light(Color(0.35, 0.65, 1.0), 0.9, 6.0, 2.0)


func _on_state_changed(old_state: int) -> void:
	_light.light_color = Color(0.35, 0.65, 1.0) if net_state == READY else Color(0.5, 0.2, 0.1)
	if net_state == RECHARGING and old_state == READY:
		_flash = FLASH_SECONDS


func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash -= delta
		_light.light_energy = 6.0 if _flash > 0.0 else 0.9


func _host_tick(delta: float) -> void:
	if _recharge > 0.0:
		_recharge -= delta
		net_state = RECHARGING
		return
	net_state = READY
	var target := _nearest_hunter()
	if target != null:
		target.stun(STUN_SECONDS)
		_recharge = RECHARGE_SECONDS
		net_state = RECHARGING


func _nearest_hunter() -> Entity:
	var best: Entity = null
	var best_distance := RANGE
	var space := get_world_3d().direct_space_state
	var from := position + Vector3(0, 1.5, 0)
	for entity: Entity in Session.entity_root.get_children():
		# Mimics and vents aren't hunters.
		if not entity.is_hostile() or entity.kind in ["mimic", "gas"] or entity.net_stunned:
			continue
		var distance := position.distance_to(entity.position)
		if distance >= best_distance:
			continue
		var query := PhysicsRayQueryParameters3D.create(from, entity.position + Vector3(0, 1.5, 0), 1)
		if space.intersect_ray(query).is_empty():
			best_distance = distance
			best = entity
	return best
