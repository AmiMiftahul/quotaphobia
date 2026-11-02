class_name Rules
extends RefCounted
## Every gameplay number and shared rule lives here so balancing is one-file work.

const MAX_PLAYERS := 4
const ROUND_SECONDS := 300.0
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


## The ship is the safe room at cell (0, -1): x in [-5, 5], z in [-15, -5].
static func in_ship(pos: Vector3) -> bool:
	return absf(pos.x) < 5.0 and pos.z > -15.0 and pos.z < -5.0
