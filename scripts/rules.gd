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

const CONSOLE_POS := Vector3(0.0, 0.0, -13.5)
const TERMINAL_POS := Vector3(3.7, 0.0, -11.5) # Where the crew buys gear.
const RACK_POS := Vector3(-3.7, 0.0, -12.6) # Where bought gear appears.

const STARTING_CREDITS := 60 # Every banked dollar of scrap also becomes a credit to spend.
const TOOL_LIMIT := 12 # Gear the crew can own at once.


## Scrap value the crew must bank within a level's days. More players means a higher target.
static func quota(level: int, crew: int) -> int:
	var base := 200.0 + 150.0 * (level - 1)
	return int(round(base * (0.4 + 0.25 * crew)))


## How tough a level's facilities are, which sets their size, scrap and threats.
static func difficulty(level: int) -> int:
	return level * 2 - 1


## The facility grows for the first few rounds, then stays at 8 x 8 rooms.
static func grid_size(difficulty_level: int) -> int:
	return mini(4 + difficulty_level, 8)


## The ship is the safe room at cell (0, -1): x in [-5, 5], z in [-15, -5].
static func in_ship(pos: Vector3) -> bool:
	return absf(pos.x) < 5.0 and pos.z > -15.0 and pos.z < -5.0
