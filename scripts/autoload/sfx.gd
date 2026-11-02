extends Node
## All game audio. Every sound goes through here, so one call plays a random
## variation, and the tests can count which sounds each machine triggered.

const BANKS := {
	"step": ["footstep_concrete", 0, 4],
	"pickup": ["impactMetal_light", 0, 4],
	"drop": ["impactMetal_medium", 0, 4],
	"monster_step": ["impactPlate_heavy", 0, 4],
	"monster_growl": ["lowFrequency_explosion", 0, 1],
	"hit": ["impactPunch_heavy", 0, 4],
	"launch": ["thrusterFire", 0, 4],
	"round_start": ["doorOpen", 0, 2],
	"console": ["computerNoise", 0, 3],
	"click": ["click", 1, 5],
	"switch": ["switch", 1, 7],
	"win": ["confirmation", 1, 4],
	"lose": ["error", 1, 8],
	"stun": ["forceField", 0, 4],
	"gas": ["slime", 0, 1],
	"heal": ["glass", 1, 6],
	"wisp_warn": ["tick", 1, 2],
	"watcher_step": ["scratch", 1, 5],
	"listener_call": ["glitch", 1, 4],
	"mimic_bite": ["impactPunch_medium", 0, 4],
	"hint": ["pluck", 1, 2],
	"swing": ["switch", 1, 7],
	"bonk": ["impactMetal_heavy", 0, 4],
	"zap": ["glitch", 1, 4],
	"boom": ["lowFrequency_explosion", 0, 1],
	"buy": ["confirmation", 1, 4],
	"deny": ["error", 1, 8],
	"amb_foundry": ["impactMetal_heavy", 0, 4],
	"amb_cryo": ["glass", 1, 6],
	"amb_biolab": ["slime", 0, 1],
	"amb_reactor": ["engineCircular", 0, 4],
}
const AMBIENT_PATH := "res://assets/audio/ambient_hum.wav"
const SHIP_HUM_PATH := "res://assets/audio/spaceEngineLow_000.ogg"

var play_count := {}

var _streams := {}
var _ambient: AudioStreamPlayer
var _silent := false


func _ready() -> void:
	_silent = DisplayServer.get_name() == "headless"
	for bank: String in BANKS:
		var info: Array = BANKS[bank]
		_streams[bank] = []
		for index in range(info[1], info[2] + 1):
			_streams[bank].append(load("res://assets/audio/%s_%03d.ogg" % [info[0], index]))
	var hum: AudioStreamWAV = load(AMBIENT_PATH)
	hum.loop_mode = AudioStreamWAV.LOOP_FORWARD
	hum.loop_begin = 0
	hum.loop_end = int(hum.get_length() * hum.mix_rate)
	_ambient = AudioStreamPlayer.new()
	_ambient.stream = hum
	_ambient.volume_db = -14.0
	_ambient.bus = "Music"
	add_child(_ambient)


func play_2d(bank: String, volume_db: float = 0.0) -> void:
	var stream := _pick(bank)
	if _silent:
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	player.bus = "SFX"
	player.finished.connect(player.queue_free)
	add_child(player)
	player.play()


func play_3d(bank: String, pos: Vector3, volume_db: float = 0.0, max_distance: float = 30.0) -> void:
	var stream := _pick(bank)
	if _silent:
		return
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.volume_db = volume_db
	player.bus = "SFX"
	player.max_distance = max_distance
	player.position = pos
	player.finished.connect(player.queue_free)
	add_child(player)
	player.play()


func set_ambient(on: bool, pitch: float = 1.0) -> void:
	_ambient.pitch_scale = pitch
	if on and not _ambient.playing:
		if not _silent:
			_ambient.play()
	elif not on:
		_ambient.stop()


## A looping engine sound for the ship, so you can find it by ear.
func make_ship_hum(pos: Vector3) -> AudioStreamPlayer3D:
	var stream: AudioStreamOggVorbis = load(SHIP_HUM_PATH).duplicate()
	stream.loop = true
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.position = pos
	player.volume_db = -24.0
	player.bus = "SFX"
	player.max_distance = 16.0
	player.autoplay = not _silent
	return player


func missing_streams() -> Array:
	var missing := []
	for bank: String in _streams:
		for stream: Variant in _streams[bank]:
			if stream == null:
				missing.append(bank)
	return missing


func _pick(bank: String) -> AudioStream:
	play_count[bank] = play_count.get(bank, 0) + 1
	var options: Array = _streams[bank]
	return options[randi() % options.size()]
