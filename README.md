# Quotaphobia

A 1-4 player co-op game made with Godot 4.7. Gear up in your ship, land at an abandoned
facility, carry scrap back, fight off or escape what hunts you, and reach each level's goal
within 4 days.

## Controls

| Key | Action |
|---|---|
| WASD / mouse | Move and look |
| Shift / Space | Sprint / jump (when dead, Space switches which crewmate you watch) |
| E / G | Pick up, or use the console and terminal / drop |
| Left click | Use the gear in your hands (or take a photo with the phone up) |
| R / V | Record a clip / watch the footage, with the phone or camcorder |
| F | Flashlight |
| Esc | Menu |

## Play it now

Double-click **Quotaphobia** in this folder, then press **Play** on the title screen. You start in your ship, in
orbit. Buy gear at the terminal if you like, then walk to the console and press **E** to land.

The ship in orbit is the lobby. Friends can join any time it's in orbit: before the first
landing, and between days. They choose **Join a friend** and type the address shown in the
top-right corner of your screen. Nobody can join while the crew is down on a map.
For several windows on one Mac, run this command once per extra window:

```bash
tools/Godot.app/Contents/MacOS/Godot --path .
```

To play with someone on your home network, type the host's local IP address into the
join box. Over the internet this version needs the host to forward UDP port 24567. Step 6
below replaces that with Steam invites.

## Settings

Open **Settings** from the main menu or the pause menu. Every change applies straight away and
is remembered. Settings live in `scripts/autoload/settings.gd` and the screen in
`scripts/settings_menu.gd`.

| Tab | What's there |
|---|---|
| Display | Window mode and size, V-Sync, frame limit, render quality, anti-aliasing, flashlight shadows, brightness, field of view |
| Audio | Master, ambience and sound effects volume |
| Controls | Mouse sensitivity, invert mouse, rebind every key (mouse buttons work too) |
| Controller | Look sensitivity, invert look, stick dead zone, vibration, rebind every button |
| Gameplay | Creature hints, crosshair |

Controller defaults: left stick moves, right stick looks, A jumps, X picks up or uses, B drops,
Y is the flashlight, RT sprints, RB uses your gear, Start pauses. In menus, LB and RB switch
tabs and B goes back.

## Levels, days and the backpack

Each level has one money goal and up to **4 days** to reach it. A day is one trip, to a different
map. Scrap you bank adds up across days. Reach the goal and the next, harder level starts straight
away. Miss it after day 4 and the run ends. If the whole crew dies, that day and its scrap are lost,
but the run carries on. Tune these in `scripts/rules.gd`.

You can carry **6 items**: 1 in your hands and 5 in your backpack. **E** picks up, **G** drops the
one in your hands, and **Q** switches which one that is (D-pad left on a controller). The bar at the
bottom of the screen shows what you carry. A heavier load slows you down, though you can always
move at 40% speed or better. If you die, everything you carry falls to the floor.

## Gear, credits and the terminal

Every dollar of scrap the crew banks also becomes a **credit**. The crew shares one pot of
credits and starts each run with $60. Spend them at the **terminal** in the ship (walk up and
press **E**). What you buy appears on the **gear rack**. Gear takes a carry slot like scrap,
but it's worth nothing when sold.

| Gear | Price | What it does |
|---|---|---|
| Shovel | $30 | Left click to swing, once every 0.9 seconds. Each hit staggers a hunter for 0.6 seconds, so it always gets a moment to strike back. On level 1 a Stalker takes 4 hits, a Listener 3 and a Mimic 1. Nothing can hurt a Watcher. It also bonks crewmates (20 damage). |
| Stun grenade | $25 | Left click to throw it about 7 m. After 1.5 seconds it stuns every hunter within 9 m that can see it, for 6 seconds. Players who look at it get a white screen. One use. |
| Flashbang | $15 | Thrown like a stun grenade, but it bangs almost on landing (0.6 seconds) and reaches 13 m. It only stuns for 3.5 seconds, and blinds anyone looking for 4. One use. |
| Shotgun | $110 | Left click fires up to 18 m. One blast counts as 3 shovel hits, so a level 1 Stalker drops in two. A blast hurts a crewmate in the way for 60. A miss still uses a shell. 3 shells, refilled in orbit. |
| Adrenaline shot | $20 | Left click to inject: 12 seconds of 40% more speed and stamina that doesn't run out. One use. |
| Hover scooter | $80 | Left click to hop on and ride at 8 m/s with no stamina. You can't jump, it's as loud as sprinting, and dropping it puts you back on your feet. Click again to step off. |
| Recall beacon | $50 | Left click, and 2 seconds later you're beamed into the ship with everything you carry. Only on the ground, outside the ship. Dropping it while it charges cancels the beam. One use. |
| Zap gun | $70 | Aim and left click to freeze the hunter you're pointing at for 5 seconds, up to 15 m away. 3 charges, refilled every time you're back in orbit. A miss costs nothing. |
| Camcorder | $40 | Left click takes a photo, R films a clip of up to 5 seconds. It keeps your last 12, and V plays them back on its screen. See below. |

Hunters grow stronger each level, up to level 8. At full strength they move 21% faster,
hit 56% harder, shake off stuns 35% sooner, and take 2 more shovel hits (Mimics still go down
in one). Even then a sprint outruns a Stalker or a Listener, and no single hit kills a player at
full health. Helpers never change. The numbers are in `Rules.threat_power` in
`scripts/rules.gd`.

Gear that's on the ship's floor, or in the hands of someone who makes it back, when the ship
leaves is kept for the next day. Gear left outside is lost. A new run starts with $60 and no
gear. Toxic vents can't be fought, and friendly helpers are never hit. Prices and numbers are
in `scripts/tools.gd`.

## Scrap Slots

By the ship's door stands **Scrap Slots**. Once the ship has landed, hold a piece of scrap,
walk up to the machine and press **E**. It takes the scrap and spins for 2.5 seconds, then:

| Chance | Result |
|---|---|
| 50% | Bust: the scrap is gone |
| 28% | Worth 1.5 times as much |
| 14% | Worth 2 times as much |
| 6% | Jackpot: 3 times |
| 2% | Jackpot: 6 times |

On average a bet breaks even, so it's a real gamble: great for a crew a little short of its goal
on the last day, and painful when it busts. Winnings come back out on the tray and can be bet
again, up to $9,999 for one piece of scrap. Only scrap is accepted, never gear, and only one bet
runs at a time. The host rolls every bet, so nobody can cheat, and the whole crew sees and hears
the result. The odds are `GAMBLE_TABLE` in `scripts/rules.gd`.

## Scrap and things to find

There are 11 kinds of scrap. Small things like levers and gears are light and cheap; big ones
like pistons, cargo cases and glass valves are worth more but slow you down more. About 1 in 30
pieces is a **golden cog**, worth $160 to $260 and easy to spot by its gold glow. Mimics never
pretend to be one.

Every facility also has a few useful items lying around: 3 on the smallest sites and up to 6 on
the biggest. They're free, and they don't count toward the crew's 12 pieces of gear.

| Item | What it does |
|---|---|
| Med kit | Left click to heal 50. At full health it isn't used up |
| Flare | Left click to throw it. It burns bright red for 30 seconds, and Ghosts won't come within 8 m |
| Battery | Left click to refill every zap gun and shotgun you carry. With nothing to refill it isn't used up |

Value and weight ranges are `SCRAP_INFO` in `scripts/facility_layout.gd`; the items are in
`scripts/tools.gd`.

## The capsule gacha

Across the door from Scrap Slots stands the **capsule gacha**. Walk up and press **E** to pull
for $30 of the crew's credits, in orbit or on the ground. A capsule rolls out after 2 seconds:

| Chance | Capsule |
|---|---|
| 35% | Empty |
| 28% | $15 back |
| 22% | Everyday gear: a shovel, stun grenade, flashbang or adrenaline shot |
| 10% | Rare gear: a zap gun, shotgun, hover scooter, recall beacon or camcorder |
| 4% | Gold: $150 |
| 1% | **Jackpot: $750**, announced to the whole crew |

Gear rolls out on the machine's tray. If the crew already owns 12 pieces, you get its price in
credits instead. On average a pull returns about $29.65 of its $30, so it's a gamble, not free
money. A capsule still rolling when the ship takes off pays out anyway. The host rolls every
pull. The odds are `GACHA_TABLE` in `scripts/rules.gd`, and the prizes in `scripts/tools.gd`.

## The phone

Press **P** to raise your phone. **Left click** (the same button that uses gear) takes a photo
with the flash, and **R** records
5 seconds of video with no sound. Press **P** again to put it away. On a controller, use
D-pad up, RB and LB. All of these can be rebound in Settings.

Other players see the phone in your hand, the flash, and a red light while you record. Files
only ever go on your own computer: choose **My photos and videos** on the main menu to open the
folder. Photos are 1280 x 720 PNG files, and videos are 640 x 360 `.mov` files at 15 frames a
second.

## The camcorder

The camcorder is gear you buy at the terminal. Unlike the phone, what it films lives **inside
the game, on the camcorder itself**. Hand it to a crewmate, or leave it on the floor, and whoever
picks it up can watch everything on it.

| Button | While holding it | While watching |
|---|---|---|
| Left click | Take a photo, with the flash | Next recording |
| R | Start filming; press again to stop (it stops by itself at 5 seconds) | Previous recording |
| V | Watch what's on it | Stop watching |

On a controller these are RB, LB and D-pad down. All of them can be rebound in Settings.

It holds 12 recordings. A 13th records over the oldest. While you film, its screen shows what
it sees and other players see its red light. Each recording remembers who filmed it. Bring the
camcorder home and its footage is still on it the next day; leave it outside and the footage is
lost with it. The footage is kept by the host and only sent to the player holding the
camcorder, so the crew's connection isn't slowed down. Photos are 640 x 360, and clips are
320 x 180 at 12 pictures a second, with no sound. The numbers are in `scripts/tools.gd`.

## Maps and creatures

Each run visits the four maps in a random order, and threats grow as rounds pass. To change
a map, or add one, edit `scripts/map_themes.gd`.

Every day also lands on a site of a different **size**. Each three days bring one of each, in a
random order, and never the same size twice in a row. The console and the landing banner say
which one is next.

| Site | Rooms per side (level 1 / level 3+) | Big halls | Time on the clock |
|---|---|---|---|
| Small outpost | 4 / 7 | about 1 | 4 minutes |
| Facility | 5 / 8 | about 2 | 5 minutes |
| Sprawling complex | 7 / 10 | about 4, some 6 or 9 rooms big | 6.5 minutes |

A **hall** is a block of rooms with no walls between them, held up by pillars, with a big lamp
in the middle. Bigger sites also hold more scrap. The Cryo Vault has the most halls and the Bio
Lab the fewest. Sizes are in `SITE_INFO` in `scripts/rules.gd`.

| Map | Vibe | Its rule | Who's there |
|---|---|---|---|
| Rust Foundry | Hot orange light, heavy machines | Lots of side routes | Stalker, Gunner, Mimics, Sentinels |
| Cryo Vault | Thick pale-blue fog | Stamina recovers at half speed | Watchers, Ghost, Patch |
| Bio Lab | Sickly green, failing lights | Tight corridors, few loops | Stalker, Mud Crawler, toxic vents, Mimic, Patch |
| Blackout Reactor | Near-black, red alarm pulses | Scrap worth 30% more | Listeners, Watcher, Wisp, Sentinel (Ghosts on later days) |

| Threat | What it does | How to beat it |
|---|---|---|
| Stalker | Patrols, spots you and runs you down | Sprint away, or reach the ship |
| Watcher | Moves only when nobody can see it | Keep someone's eyes on it |
| Listener | Blind; rushes toward noise | Walk or stand still; never sprint nearby |
| Mimic | Looks like scrap, bites when you get close | Real scrap shows a pick-up prompt |
| Toxic vent | Fills a room with gas on a timer | Wait for it to close, then cross |
| Gunner | A soldier with a shotgun. When it sees you it aims a red laser for 1.2 seconds, then fires (45 damage) | Get out of its sight before it fires. 3 shovel hits drop it, and it leaves its shotgun behind with 2 shells |
| Ghost | Floats straight through walls toward the nearest player. Its touch does 30 damage, then it vanishes and comes back far away | Shine your flashlight on it to drive it back, or throw a flare: it won't come near one. Nothing can hurt it |
| Mud Crawler | A slow heap of mud that follows you and leaves puddles. Mud halves your speed, and touching it hurts | Keep out of its mud. 4 shovel hits break it up |

| Helper | What it does |
|---|---|
| Patch | A drone that flies to hurt players and heals them, with limited charge |
| Sentinel | A pylon that stuns the nearest hunter it can see, then recharges |
| Wisp | A light that leads you toward scrap and turns red near hunters |

The ship is always safe. The first time you meet each one, the HUD explains it.

**Deaths.** When a player or creature dies, the killing blow sends the body flying, cartoon
style, away from whatever struck it. It cartwheels head over heels with its arms and legs
flailing, stretches out as it flies, bonks its head on the ceiling if it was hit hard enough,
and squashes with a thud each time it bounces. When it lands it rights itself and flops over in
its death animation, then lies there until the ship leaves. Bigger hits throw further: a shovel
knocks a Stalker about 6 m, a shotgun about 9 m. Creatures with no death animation (Mud
Crawlers, Mimics) tumble and land squashed flat. The Gunner's corpse drops its shotgun as a
real one you can take. Every machine gets the same push and spin, so the whole crew sees the
same flight and the body lands in the same place. The code is `scripts/corpse.gd`; the push,
spin and bounce numbers are at the top of it.

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
| `scripts/player.gd`, `scrap.gd` | Players and items. |
| `scripts/tools.gd` | The gear sold at the terminal: prices, what each piece does, and how it looks. |
| `scripts/gamble_station.gd` | How Scrap Slots looks and spins. The betting itself is in `session.gd`. |
| `scripts/gacha_station.gd` | How the capsule gacha looks and rolls. The prizes are picked in `session.gd`. |
| `scripts/camcorder.gd` | Filming and playing back with the camcorder. Storing footage is in `session.gd`. |
| `scripts/phone_camera.gd` | The phone, which saves photos and videos to your computer. |
| `scripts/monster.gd`, `scripts/entities/` | Every creature and helper: one file each, like `gunner.gd`, `ghost.gd` and `mud.gd`. |
| `scripts/map_themes.gd` | Every map's look, sound, rules and residents. |
| `scripts/main.gd` | The title screen, menus and HUD, and the look they share. |
| `scripts/menu_backdrop.gd` | The ship scene behind the title screen. |
| `scripts/autoload/sfx.gd` | Every sound, and how loud it plays. |
| `scripts/autoload/store.gd` | The in-game shop. |
| `supabase/functions/`, `cloud/store_schema.sql` | The payment server and its tables. |
| `scripts/assets.gd`, `assets/` | Loading the models and sounds. |
| `scripts/autoload/cloud.gd`, `cloud/schema.sql` | The online database. |

**2. One day.** The crew waits in orbit, where friends can join and gear is bought > someone
pulls the lever > the host picks a seed > every machine builds the same facility > the host
creates scrap and creatures > players bank scrap in the ship > the day ends when someone
launches, time runs out, or everyone dies > the ship returns to orbit with the gear it kept.
When a level's last day ends short of the goal, each player saves the run to the database and
a fresh run starts in orbit.

## Testing

Run these after every change. Both must report no problems.

```bash
python3 tests/run_tests.py
```

That runs rule checks, a two-player camcorder test (one films, the other picks it up and
watches), and a real session: four separate copies of the game on real network
connections, a fifth player who must be refused, and a friend who joins late while the ship is
in orbit. It covers cheating attempts, deaths, disconnects, buying and using every piece of gear, every
gacha prize, and a fake database.

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

### Selling items with QRIS (non-Steam versions only)

[Steam requires in-game purchases to use the Steam Wallet](https://partner.steamgames.com/doc/features/microtransactions),
so QRIS must stay out of the Steam version. A build exported with the `steam` feature tag
hides the shop and refuses Midtrans orders. Selling on Steam needs Steam's own microtransaction
system, which isn't built yet.

How a purchase flows: the game asks `create-qris-order` for an item > the server looks up the
price and asks Midtrans for a QR code > the player pays > Midtrans notifies `midtrans-webhook`
> the server checks the signature, re-confirms with Midtrans, and unlocks the item > the game,
checking every 3 seconds, sees it. The game never decides that something is paid for.

**Test mode setup:**

1. Connect the cloud database first (step 3), then paste `cloud/store_schema.sql` into the
   Supabase SQL Editor and press Run. Product names and prices live in the `products` table.
2. Create a Midtrans account and switch its dashboard to **Sandbox**.
3. Install the [Supabase command line tool](https://supabase.com/docs/guides/cli), then run
   these yourself, typing your sandbox server key where shown. Never put this key in the game.

   ```bash
   supabase login
   ```

   ```bash
   supabase link --project-ref YOUR_PROJECT_REF
   ```

   ```bash
   supabase secrets set MIDTRANS_SERVER_KEY=YOUR_SANDBOX_SERVER_KEY
   ```

   ```bash
   supabase functions deploy create-qris-order
   ```

   ```bash
   supabase functions deploy midtrans-webhook --no-verify-jwt
   ```

4. In Midtrans, set the Payment Notification URL to
   `https://YOUR_PROJECT_REF.supabase.co/functions/v1/midtrans-webhook`.
5. Buy something in the game and complete it with Midtrans's sandbox payment simulator.

**Before taking real money, all of these must be done:**

- Pass every case in test mode: paid, expired, refunded, and paying two open QR codes.
- Add real account login. Purchases belong to an anonymous account stored on one computer, so
  today a player who reinstalls or changes computers loses what they bought.
- Add terms, a refund policy and a support contact, and check your tax duties.
- Confirm Midtrans approves your business for selling digital game items.
- Watch the function logs for `REFUND NEEDED` and `AMOUNT MISMATCH`. Refunds are done by hand.

Only then set your production key and `MIDTRANS_IS_PRODUCTION=true` with `supabase secrets set`.

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
