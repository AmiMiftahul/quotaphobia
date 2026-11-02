class_name GachaStation
extends Node3D
## The capsule machine: pay credits, turn the crank, and a capsule rolls out. The host
## picks the prize; this only shows it, the same on every machine.

const RESULT_SECONDS := 2.2
const IDLE_TEXT := "CAPSULE GACHA\n$%d a pull. Jackpot: $%d!"
const IDLE_COLOR := Color(1.0, 0.45, 0.85)
const COLORS := {
	"dud": Color(0.6, 0.6, 0.65),
	"refund": Color(0.6, 0.85, 1.0),
	"gear": Color(0.45, 1.0, 0.55),
	"rare": Color(0.75, 0.5, 1.0),
	"gold": Color(1.0, 0.8, 0.25),
	"jackpot": Color(1.0, 0.9, 0.3),
}

var _screen: Label3D
var _light: OmniLight3D
var _spin_left := 0.0
var _tick := 0.0
var _result_left := 0.0
var _jackpot := false
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	position = Rules.GACHA_POS
	# The machine faces into the ship (-X); its sign stands on top, facing the same way.
	_screen = Label3D.new()
	_screen.position = Vector3(-0.2, 1.75, 0)
	_screen.rotation.y = -PI * 0.5
	_screen.font_size = 56
	_screen.pixel_size = 0.0032
	_screen.outline_size = 10
	add_child(_screen)
	_light = OmniLight3D.new()
	_light.position = Vector3(-1.0, 2.2, 0)
	_light.omni_range = 4.5
	add_child(_light)
	_show_idle()


func is_spinning() -> bool:
	return _spin_left > 0.0


func spin() -> void:
	_spin_left = Rules.GACHA_SECONDS
	_result_left = 0.0
	_tick = 0.0


func show_result(prize: String, text: String) -> void:
	_spin_left = 0.0
	_jackpot = prize == "jackpot"
	_result_left = RESULT_SECONDS * (2.0 if _jackpot else 1.0)
	_screen.text = text
	var color: Color = COLORS.get(prize, IDLE_COLOR)
	_screen.modulate = color
	_light.light_color = color


func _show_idle() -> void:
	_screen.text = IDLE_TEXT % [Rules.GACHA_PRICE, Rules.GACHA_JACKPOT]
	_screen.modulate = IDLE_COLOR
	_light.light_color = IDLE_COLOR
	_light.light_energy = 0.7


func _process(delta: float) -> void:
	if _spin_left > 0.0:
		_spin_left -= delta
		_tick -= delta
		if _tick <= 0.0:
			_tick = 0.12
			_screen.text = "CAPSULE GACHA\n" + ["( o )", "( O )", "( 0 )", "( * )"][_rng.randi() % 4]
			_light.light_color = Color.from_hsv(_rng.randf(), 0.6, 1.0)
			_light.light_energy = 1.4
			Sfx.play_3d("click", global_position + Vector3(0, 1.2, 0), -10.0, 14.0)
	elif _result_left > 0.0:
		_result_left -= delta
		if _jackpot:
			# A jackpot runs through every colour while it lasts.
			_light.light_color = Color.from_hsv(fmod(_result_left * 1.5, 1.0), 0.7, 1.0)
			_screen.modulate = _light.light_color
		_light.light_energy = 3.0 if fmod(_result_left, 0.3) > 0.15 else 0.6
		if _result_left <= 0.0:
			_show_idle()
