class_name GambleStation
extends Node3D
## Scrap Slots: put in a piece of scrap and it either vanishes or comes back worth more.
## The host rolls the result; this only shows it, the same on every machine.

const SYMBOLS := ["$", "7", "X", "?", "%", "#"]
const RESULT_SECONDS := 1.8
const IDLE_TEXT := "SCRAP SLOTS\nlose it, or win up to x6"
const IDLE_COLOR := Color(1.0, 0.75, 0.3)
const WIN_COLOR := Color(0.45, 1.0, 0.5)
const BUST_COLOR := Color(1.0, 0.25, 0.2)

var _screen: Label3D
var _light: OmniLight3D
var _spin_left := 0.0
var _tick := 0.0
var _result_left := 0.0
var _result_color := IDLE_COLOR
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	position = Rules.GAMBLE_POS
	# The machine faces into the ship (+X); its sign stands on top, facing the same way.
	_screen = Label3D.new()
	_screen.position = Vector3(0.2, 1.75, 0)
	_screen.rotation.y = PI * 0.5
	_screen.font_size = 56
	_screen.pixel_size = 0.0032
	_screen.outline_size = 10
	add_child(_screen)
	_light = OmniLight3D.new()
	_light.position = Vector3(1.0, 2.2, 0)
	_light.omni_range = 4.5
	add_child(_light)
	_show_idle()


func is_spinning() -> bool:
	return _spin_left > 0.0


func spin() -> void:
	_spin_left = Rules.GAMBLE_SECONDS
	_result_left = 0.0
	_tick = 0.0


func show_result(multiplier: float, value: int) -> void:
	_spin_left = 0.0
	_result_left = RESULT_SECONDS
	if multiplier <= 0.0:
		_result_color = BUST_COLOR
		_screen.text = "X  X  X\nBUST! The scrap is gone"
	else:
		_result_color = WIN_COLOR
		var headline := "JACKPOT!" if multiplier >= 3.0 else "WIN!"
		_screen.text = "%s  x%s\nNow worth $%d" % [headline, _multiplier_text(multiplier), value]
	_screen.modulate = _result_color
	_light.light_color = _result_color


static func _multiplier_text(multiplier: float) -> String:
	return str(int(multiplier)) if is_equal_approx(multiplier, roundf(multiplier)) else "%.1f" % multiplier


func _show_idle() -> void:
	_screen.text = IDLE_TEXT
	_screen.modulate = IDLE_COLOR
	_light.light_color = IDLE_COLOR
	_light.light_energy = 0.7


func _process(delta: float) -> void:
	if _spin_left > 0.0:
		_spin_left -= delta
		_tick -= delta
		if _tick <= 0.0:
			_tick = 0.09
			var reels := PackedStringArray()
			for reel in 3:
				reels.append(SYMBOLS[_rng.randi() % SYMBOLS.size()])
			_screen.text = "%s\nspinning..." % "  ".join(reels)
			_light.light_color = Color.from_hsv(_rng.randf(), 0.7, 1.0)
			_light.light_energy = 1.6
			Sfx.play_3d("click", global_position + Vector3(0, 1.2, 0), -10.0, 14.0)
	elif _result_left > 0.0:
		_result_left -= delta
		# The light blinks with the result, then the machine settles back.
		_light.light_energy = 3.0 if fmod(_result_left, 0.3) > 0.15 else 0.6
		if _result_left <= 0.0:
			_show_idle()
