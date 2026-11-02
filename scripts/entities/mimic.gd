class_name Mimic
extends Entity
## Looks like scrap, but never shows a pick-up prompt. It bites once when someone
## steps close, then scuttles off for good. Beat it by trusting the prompt.

const BITE_RANGE := 1.5
const DAMAGE := 34
const REVEALED := 1
const VANISH_SECONDS := 1.0

var _model: Node3D
var _vanish_timer := 0.0


func _build(data: Dictionary) -> void:
	grace = 5.0
	var path: String = Assets.FACTORY % FacilityLayout.SCRAP_MODELS[data.scrap_kind]
	_model = Assets.instance(path)
	_model.scale = Vector3.ONE * Scrap.MODEL_SCALE
	_model.position.y = -0.25 - Assets.bounds(path).position.y * Scrap.MODEL_SCALE
	add_child(_model)
	Scrap.add_glow(_model)


func _on_state_changed(_old_state: int) -> void:
	if net_state == REVEALED:
		Sfx.play_3d("mimic_bite", position, 2.0, 25.0)
		_model.scale = Vector3.ONE * Scrap.MODEL_SCALE * 1.8
		Session.show_hint("mimic")


func _host_tick(delta: float) -> void:
	if net_state == REVEALED:
		_vanish_timer -= delta
		if _vanish_timer <= 0.0:
			get_parent().remove_child(self)
			queue_free()
		return
	for player in _targets():
		var offset := player.net_pos - position
		offset.y = 0.0
		if offset.length() < BITE_RANGE:
			net_state = REVEALED
			_vanish_timer = VANISH_SECONDS
			Session.damage_player(player.peer_id, scaled_damage(DAMAGE))
			return
