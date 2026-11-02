class_name MapThemes
extends RefCounted
## Every map's look, sound, layout and residents. To add a map, add an entry here.
## Prop scales keep each prop inside its room corner (a test checks this).

const ORDER: Array[String] = ["foundry", "cryo", "biolab", "reactor"]

const MAPS := {
	"foundry": {
		"name": "Rust Foundry",
		"tagline": "The machines never stopped. Something still works here.",
		"rule": "Lots of side routes. Sentinels stun what hunts you.",
		"wall_tint": Color(0.78, 0.58, 0.46),
		"ceiling_tint": Color(0.42, 0.3, 0.24),
		"light_color": Color(1.0, 0.62, 0.3),
		"light_energy": 1.1,
		"light_chance": 0.55,
		"flicker": 0.25,
		"pulse": false,
		"ambient_color": Color(0.7, 0.45, 0.3),
		"ambient_energy": 0.16,
		"fog_color": Color(0.1, 0.05, 0.02),
		"fog_density": 0.025,
		"loop_chance": 0.3,
		"hall_scale": 1.0, # How many big open halls, compared with other maps.
		"prop_chance": 0.65,
		"props": {"machine": 1.3, "machine-fortified": 1.2, "robot-arm-a": 1.0, "hopper-round": 1.5, "box-large": 1.6, "piston-round": 1.3},
		"scrap_value": 1.0,
		"stamina_regen": 1.0,
		"hum_pitch": 1.0,
		"ambience": "amb_foundry",
		"roster": {"stalker": 1, "mimic": 2, "sentinel": 2},
		"growth": ["mimic", "stalker"],
	},
	"cryo": {
		"name": "Cryo Vault",
		"tagline": "Frozen fog. Pale figures. Don't look away.",
		"rule": "The cold slows your stamina recovery.",
		"wall_tint": Color(0.62, 0.8, 1.0),
		"ceiling_tint": Color(0.45, 0.6, 0.8),
		"light_color": Color(0.65, 0.85, 1.0),
		"light_energy": 0.8,
		"light_chance": 0.4,
		"flicker": 0.0,
		"pulse": false,
		"ambient_color": Color(0.6, 0.75, 1.0),
		"ambient_energy": 0.22,
		"fog_color": Color(0.55, 0.7, 0.85),
		"fog_density": 0.09,
		"loop_chance": 0.45,
		"hall_scale": 1.5,
		"prop_chance": 0.45,
		"props": {"pipe-glass-large": 1.6, "pipe-glass-large-valve": 1.6, "box-large": 1.6, "box-wide": 1.8},
		"scrap_value": 1.0,
		"stamina_regen": 0.5,
		"hum_pitch": 1.3,
		"ambience": "amb_cryo",
		"roster": {"watcher": 2, "patch": 1},
		"growth": ["watcher"],
	},
	"biolab": {
		"name": "Bio Lab",
		"tagline": "Something grew in here. The air isn't safe.",
		"rule": "Tight corridors. Toxic gas vents open and close, so time your crossing.",
		"wall_tint": Color(0.55, 0.78, 0.5),
		"ceiling_tint": Color(0.3, 0.42, 0.28),
		"light_color": Color(0.6, 1.0, 0.45),
		"light_energy": 0.9,
		"light_chance": 0.5,
		"flicker": 0.6,
		"pulse": false,
		"ambient_color": Color(0.45, 0.7, 0.35),
		"ambient_energy": 0.14,
		"fog_color": Color(0.08, 0.16, 0.05),
		"fog_density": 0.05,
		"loop_chance": 0.05,
		"hall_scale": 0.5,
		"prop_chance": 0.55,
		"props": {"pipe-glass-large": 1.6, "machine-bed": 0.9, "scanner-high": 1.2, "hopper-high-round": 1.5},
		"scrap_value": 1.1,
		"stamina_regen": 1.0,
		"hum_pitch": 0.8,
		"ambience": "amb_biolab",
		"roster": {"stalker": 1, "gas": 4, "mimic": 1, "patch": 1},
		"growth": ["gas", "mimic"],
	},
	"reactor": {
		"name": "Blackout Reactor",
		"tagline": "No power. Only the alarm lights. It hunts by sound.",
		"rule": "Scrap is worth 30% more. Sprinting gets you heard, so walk or stand still.",
		"wall_tint": Color(0.3, 0.3, 0.36),
		"ceiling_tint": Color(0.14, 0.14, 0.17),
		"light_color": Color(1.0, 0.12, 0.08),
		"light_energy": 1.3,
		"light_chance": 0.3,
		"flicker": 0.0,
		"pulse": true,
		"ambient_color": Color(0.3, 0.3, 0.45),
		"ambient_energy": 0.04,
		"fog_color": Color(0.01, 0.005, 0.01),
		"fog_density": 0.04,
		"loop_chance": 0.2,
		"hall_scale": 1.0,
		"prop_chance": 0.4,
		"props": {"machine-fortified": 1.2, "pipe-large": 1.4, "piston-round": 1.3, "hopper-high-round": 1.5},
		"scrap_value": 1.3,
		"stamina_regen": 1.0,
		"hum_pitch": 0.6,
		"ambience": "amb_reactor",
		"roster": {"listener": 2, "watcher": 1, "wisp": 1, "sentinel": 1},
		"growth": ["listener"],
	},
}


# The ship between jobs: calm, bright and safe. It isn't a map, so it's not in ORDER.
const ORBIT := {
	"name": "In orbit",
	"wall_tint": Color(1.0, 1.0, 1.0),
	"ceiling_tint": Color(0.7, 0.7, 0.7),
	"light_color": Color(0.85, 0.95, 1.0),
	"light_energy": 1.5,
	"flicker": 0.0,
	"pulse": false,
	"ambient_color": Color(0.6, 0.7, 0.9),
	"ambient_energy": 0.35,
	"fog_color": Color(0.0, 0.0, 0.0),
	"fog_density": 0.0,
	"stamina_regen": 1.0,
	"hum_pitch": 1.0,
	"ambience": "",
}


static func get_theme(map_id: String) -> Dictionary:
	return MAPS[map_id]


## A different map order each run, the same on every machine.
static func order_for_run(run_seed: int) -> Array[String]:
	var rng := RandomNumberGenerator.new()
	rng.seed = run_seed
	var order: Array[String] = ORDER.duplicate()
	for index in range(order.size() - 1, 0, -1):
		var other := rng.randi_range(0, index)
		var swap := order[index]
		order[index] = order[other]
		order[other] = swap
	return order
