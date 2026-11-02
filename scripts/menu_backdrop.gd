class_name MenuBackdrop
extends Node3D
## What sits behind the main menu: the ship in orbit, the crew waiting, and a slow,
## drifting camera. It only exists while the menu is up, so it costs nothing in play.

const CAMERA_FROM := Vector3(2.2, 1.85, -13.4)
const LOOK_AT := Vector3(-1.4, 1.6, -6.0)
const DRIFT := Vector3(0.35, 0.12, 0.25)
# Where each crew member stands, and which way they face.
const CREW := [
	[Vector3(-1.6, 0.0, -8.0), PI * 0.85],
	[Vector3(0.1, 0.0, -9.0), PI],
	[Vector3(1.3, 0.0, -7.4), -PI * 0.15],
]

var _camera: Camera3D
var _time := 0.0


func _ready() -> void:
	var level := Level.new()
	add_child(level)
	level.build_orbit(MapThemes.get_theme(MapThemes.ORDER[randi() % MapThemes.ORDER.size()]))
	for index in CREW.size():
		var body := Assets.instance(Assets.CHARACTERS % Player.MODELS[index])
		body.scale = Vector3.ONE * Player.MODEL_SCALE
		body.position = CREW[index][0]
		body.rotation.y = CREW[index][1]
		add_child(body)
		var animator := Assets.find_animation_player(body)
		Assets.set_looping(animator, ["idle"])
		animator.play("idle")
		# Start each one at a different point, so they don't breathe in step.
		animator.seek(index * 0.7, true)
	_camera = Camera3D.new()
	_camera.fov = 68.0
	add_child(_camera)
	_camera.make_current()
	_place_camera()


func _process(delta: float) -> void:
	_time += delta
	_place_camera()


func _place_camera() -> void:
	var sway := Vector3(sin(_time * 0.11) * DRIFT.x, sin(_time * 0.17) * DRIFT.y, cos(_time * 0.09) * DRIFT.z)
	_camera.position = CAMERA_FROM + sway
	_camera.look_at(LOOK_AT)
