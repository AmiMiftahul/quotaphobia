class_name Rules
extends RefCounted
## Every gameplay number and shared rule lives here so balancing is one-file work.

const MAX_PLAYERS := 4
const ROUND_SECONDS := 300.0
const RESULTS_SECONDS := 8.0
const MONSTER_GRACE_SECONDS := 20.0

const INTERACT_RANGE := 2.5 # What the player's own game offers.
const SERVER_RANGE := 3.5 # What the host accepts; a little wider to absorb lag.

const PLAYER_MAX_HP := 100
const MONSTER_DAMAGE := 50
const MONSTER_ATTACK_RANGE := 1.4
const MONSTER_ATTACK_COOLDOWN := 1.5

const CONSOLE_POS := Vector3(0.0, 0.0, -13.5)


## Scrap value the crew must bring back. More players means a higher target.
static func quota(round_number: int, crew: int) -> int:
	var base := 80.0 + 50.0 * (round_number - 1)
	return int(round(base * (0.4 + 0.25 * crew)))


## The facility grows for the first few rounds, then stays at 8 x 8 rooms.
static func grid_size(round_number: int) -> int:
	return mini(4 + round_number, 8)


## The ship is the safe room at cell (0, -1): x in [-5, 5], z in [-15, -5].
static func in_ship(pos: Vector3) -> bool:
	return absf(pos.x) < 5.0 and pos.z > -15.0 and pos.z < -5.0
