# Scrap Shift

A 1-4 player co-op game made with Godot 4.7. Land at an abandoned facility, carry
scrap back to the ship, avoid the monster, meet the quota, and survive as long as you can.

## Controls

| Key | Action |
|---|---|
| WASD / mouse | Move and look |
| Shift / Space | Sprint / jump (when dead, Space switches which crewmate you watch) |
| E / G | Pick up or use the console / drop |
| F | Flashlight |
| Esc | Menu |

## Play it now

Run this from the project folder:

```bash
tools/Godot.app/Contents/MacOS/Godot --path .
```

To play with several windows on one Mac, run that command again in another terminal.
In one window choose **Host a game**; in the others choose **Join a game**.

To play with someone on your home network, type the host's local IP address into the
join box. Over the internet this version needs the host to forward UDP port 24567. Step 6
below replaces that with Steam invites.

## How the work flows

**1. How the game is organised.** One player is the host, and their game is the referee.
Each player moves their own character so controls feel instant, while the host decides
everything that could be disputed: who holds what, who gets hurt, and when a round ends.

| File | Job |
|---|---|
| `scripts/rules.gd` | Every balance number. Start here to tune the game. |
| `scripts/autoload/net.gd` | Connections and the crew list. The only file that knows about ENet. |
| `scripts/autoload/session.gd` | Round flow, and checking every player request. |
| `scripts/facility_layout.gd` | Generates the map from a seed, so the host only sends one number. |
| `scripts/level.gd` | Turns that map into walls and lights. |
| `scripts/player.gd`, `monster.gd`, `scrap.gd` | The things in the world. |
| `scripts/main.gd` | Menus and HUD. |
| `scripts/autoload/sfx.gd` | Every sound, and how loud it plays. |
| `scripts/assets.gd`, `assets/` | Loading the models and sounds. |
| `scripts/autoload/cloud.gd`, `cloud/schema.sql` | The online database. |

**2. One round.** The host picks a seed > every machine builds the same facility > the host
creates players, scrap and the monster > players bank scrap in the ship > the round ends when
someone launches, time runs out, or everyone dies > quota met: next, harder round. Quota
missed: each player saves the run to the database and the crew returns to the lobby.

## Testing

Run these after every change. Both must report no problems.

```bash
python3 tests/run_tests.py
```

That runs rule checks plus a real session: four separate copies of the game on real network
connections, and a fifth player who must be refused. It covers cheating attempts, deaths,
disconnects, and a fake database.

```bash
tools/Godot.app/Contents/MacOS/Godot --path . res://tests/test_main.tscn -- role=ui
```

That opens a real window and uses the actual menus, keyboard, mouse and graphics.

## What's left

### 3. Connect the cloud database (you, about 10 minutes)

1. Create a free project at [supabase.com](https://supabase.com).
2. In **SQL Editor**, paste all of `cloud/schema.sql` and press Run.
3. Under **Authentication**, turn on **anonymous sign-ins**.
4. Under **Project Settings > API**, copy the project URL and the **publishable** key into
   `scripts/cloud_config.gd`. Never use the secret key.
5. Play a run and lose. The score should appear in the `runs` table and on the main menu.

### 4. Voice chat and more content

The art and sound are in (see `CREDITS.md` and `assets/licenses/`). Voice chat is the next
big feature, followed by more monsters, scrap and facility types.

To measure how loud each sound is after changing it:

```bash
tools/Godot.app/Contents/MacOS/Godot --path . res://tests/test_main.tscn -- role=levels
```

### 5. Playtest with friends

Play over a real connection and tune `rules.gd`. Automated tests can't tell you if it's
fun, or how it feels with real lag.

### 6. Steam

1. Sign up at [Steamworks](https://partner.steamgames.com), pay the $100 app fee, and finish
   the identity, bank and tax forms to get your App ID.
2. Add GodotSteam (a build for Godot 4.7.2 exists), and replace `net.gd`'s `host()` and
   `join()` with Steam lobbies, invites and networking. The rest of the game doesn't change.
3. Send scores through a server check that verifies the player's Steam identity. Today's
   scores come from the player's own game, so they can be faked.
4. Export for Windows, and test on a real Windows PC.
5. Upload the build, set up the store page and trailer, pass Valve's review, and release.
   Check your Steamworks account for the current waiting periods.
