class_name Rules
extends RefCounted
## Every gameplay number and shared rule lives here so balancing is one-file work.

const MAX_PLAYERS := 4
const ROUND_SECONDS := 300.0 # On a medium site; see SITE_INFO for the others.
const DAYS_PER_LEVEL := 4 # Each day is one trip. Miss the goal after the last one and the run ends.
const CARRY_LIMIT := 6 # One in your hands, plus five in the backpack.
const STOWED_WEIGHT_SHARE := 0.5 # A backpack carries weight better than your hands do.
const MAX_CARRY_SLOWDOWN := 0.6 # However full, you can always still move at 40% speed.
const RESULTS_SECONDS := 8.0
const MONSTER_GRACE_SECONDS := 20.0

const INTERACT_RANGE := 2.5 # What the player's own game offers.
const SERVER_RANGE := 3.5 # What the host accepts; a little wider to absorb lag.

const PLAYER_MAX_HP := 100
const MONSTER_DAMAGE := 50
const MONSTER_ATTACK_RANGE := 1.4
const MONSTER_ATTACK_COOLDOWN := 1.5
const MAX_THREAT_STEP := 7 # Hunters stop getting stronger after level 8.

const CONSOLE_POS := Vector3(0.0, 0.0, -13.5)
const TERMINAL_POS := Vector3(3.7, 0.0, -11.5) # Where the crew buys gear.
const RACK_POS := Vector3(-3.7, 0.0, -12.6) # Where bought gear appears.

const GAMBLE_POS := Vector3(-3.5, 0.0, -7.2) # Scrap Slots, by the ship's door.
const GAMBLE_SECONDS := 2.5
const GAMBLE_MAX_VALUE := 9999
# [chance, what the scrap's value is multiplied by]. Half the time it's gone; the rest
# pays out, up to six times. On average a bet breaks even (a test checks this).
const GAMBLE_TABLE := [[0.50, 0.0], [0.28, 1.5], [0.14, 2.0], [0.06, 3.0], [0.02, 6.0]]

const GACHA_POS := Vector3(3.5, 0.0, -7.4) # The capsule machine, across the door from Scrap Slots.
const GACHA_SECONDS := 2.0
const GACHA_PRICE := 30 # Credits per pull.
const GACHA_REFUND := 15
const GACHA_GOLD := 150
const GACHA_JACKPOT := 750
# [chance, prize]. A pull is worth a little less than it costs on average (a test checks
# this), so the gacha is a gamble, not a money printer.
const GACHA_TABLE := [[0.35, "dud"], [0.28, "refund"], [0.22, "gear"], [0.10, "rare"], [0.04, "gold"], [0.01, "jackpot"]]

const STARTING_CREDITS := 60 # Every banked dollar of scrap also becomes a credit to spend.
const TOOL_LIMIT := 12 # Gear the crew can own at once.


## Scrap value the crew must bank within a level's days. More players means a higher target.
static func quota(level: int, crew: int) -> int:
	var base := 200.0 + 150.0 * (level - 1)
	return int(round(base * (0.4 + 0.25 * crew)))


## How much stronger hunters are on a level. Level 1 is the baseline; each level after
## adds a little, and it stops growing at level 8 so a crew can always still win:
##   speed  1.00 -> 1.21  (a Stalker stays slower than a sprint, a Listener barely)
##   damage 1.00 -> 1.56  (a Stalker still needs two hits to kill a full-health player)
##   stun   1.00 -> 0.65  (stuns from gear and Sentinels wear off sooner)
##   extra_hits 0 -> 2    (shovel blows, for hunters that take more than one)
static func threat_power(level: int) -> Dictionary:
	var step := clampi(level - 1, 0, MAX_THREAT_STEP)
	return {
		"speed": 1.0 + 0.03 * step,
		"damage": 1.0 + 0.08 * step,
		"stun": 1.0 - 0.05 * step,
		"extra_hits": step / 3,
	}


## How tough a level's facilities are, which sets their size, scrap and threats.
static func difficulty(level: int) -> int:
	return level * 2 - 1


## The facility grows for the first few rounds, then stays at 8 x 8 rooms.
static func grid_size(difficulty_level: int) -> int:
	return mini(4 + difficulty_level, 8)


# Each day lands on a site of one of these sizes, so no two days in a row feel the same.
# "grid" changes the usual number of rooms per side, "halls" is how many big open halls
# it tries to fit, and "seconds" is how long the crew has before the ship leaves.
const SITES: Array[String] = ["small", "medium", "large"]
const SITE_INFO := {
	"small": {"name": "Small outpost", "grid": -1, "halls": 1, "seconds": 240.0},
	"medium": {"name": "Facility", "grid": 0, "halls": 2, "seconds": ROUND_SECONDS},
	"large": {"name": "Sprawling complex", "grid": 2, "halls": 4, "seconds": 390.0},
}
const MIN_GRID := 4
const MAX_GRID := 10


static func site_grid(difficulty_level: int, site: String) -> int:
	return clampi(grid_size(difficulty_level) + SITE_INFO[site].grid, MIN_GRID, MAX_GRID)


static func round_seconds(site: String) -> float:
	return SITE_INFO[site].seconds


## The site for a day: every three days hold one of each size, in a shuffled order,
## and the same size never comes up twice in a row.
static func site_for_day(run_seed: int, number: int) -> String:
	var block := (number - 1) / 3
	var order := _site_block(run_seed, block)
	if block > 0 and order[0] == _site_block(run_seed, block - 1)[2]:
		order = [order[1], order[0], order[2]]
	return order[(number - 1) % 3]


static func _site_block(run_seed: int, block: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([run_seed, "sites", block])
	var order: Array = SITES.duplicate()
	for index in range(order.size() - 1, 0, -1):
		var other := rng.randi_range(0, index)
		var swap: String = order[index]
		order[index] = order[other]
		order[other] = swap
	return order


## The ship is the safe room at cell (0, -1): x in [-5, 5], z in [-15, -5].
static func in_ship(pos: Vector3) -> bool:
	return absf(pos.x) < 5.0 and pos.z > -15.0 and pos.z < -5.0
